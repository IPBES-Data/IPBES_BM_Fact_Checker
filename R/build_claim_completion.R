# LLM-based completion of elliptical `atomic_bm` fragments.
#
# segment_bm_atomic() (R/build_nli_ready_evidence_parquet.R) splits a BM
# field at EVERY evidence brace, which routinely produces fragments that
# only make grammatical sense as a continuation of an earlier fragment
# (e.g. "can help to regulate disease and the immune system" has no
# subject of its own -- it was elided from an earlier, semicolon-joined
# clause sharing the same subject). This module resolves each such
# fragment into a single, self-contained claim by asking an LLM to either
# return it unchanged (already complete) or rewrite it using only words
# already present in the fragments that precede it -- never introducing
# new facts. See input/prompts/claim_completion_system.md and
# claim_completion_user.md for the exact contract given to the model.
#
# Reuses build_llm_verification_chat()/load_text_file()/render_template()
# from R/build_llm_verification_parquet.R rather than duplicating them --
# both files are sourced into the same environment by _targets.R's
# lapply(list.files("R", ...), source), same convention every other R/*.R
# file in this project relies on for cross-file helpers.

`%||%` <- function(x, y) if (is.null(x)) y else x

claim_completion_output_type <- function() {
  ellmer::type_object(
    .description = paste(
      "Assessment of whether one Background Message fragment is already a",
      "complete, self-contained claim, or needs completion using only",
      "words already present in the fragments that precede it."
    ),
    needs_completion = ellmer::type_boolean(
      "TRUE if the fragment was rewritten, FALSE if returned unchanged."
    ),
    completed_claim = ellmer::type_string(
      "The fragment, unchanged or rewritten, as one complete sentence."
    ),
    explanation = ellmer::type_string(
      paste(
        "One sentence: 'Already a complete claim', or a brief note on what",
        "was carried forward and from where."
      )
    ),
    .required = TRUE
  )
}

# Faithfulness guard, same spirit as quote_is_verbatim()
# (R/build_llm_verification_parquet.R): every substantive (>=4-letter) word
# in the completed claim must already appear somewhere in the BM field's
# own original (uncompleted) fragments. Short/common connective words
# ("the", "and", "to") are excluded from the check by length alone --
# restoring grammatical glue is expected and fine; inventing new content
# words is not. That length cutoff isn't enough on its own, though: a real
# completion joining a carried-forward subject to an elliptical
# continuation needs relative pronouns/conjunctions that are often exactly
# 4+ letters ("...clean water THAT can help..."), so an explicit stopword
# list catches those regardless of length. Caught via a real case: "that"
# was flagged as fabricated and silently discarded an otherwise faithful,
# correct completion (see git history/session notes).
claim_completion_connective_stopwords <- c(
  "that", "which", "this", "these", "those", "such", "than", "then",
  "when", "with", "from", "also", "both", "have", "were", "been",
  "will", "would", "could", "should", "shall", "must", "into", "upon",
  "onto", "whose", "whom"
)

claim_completion_is_faithful <- function(completed, source_fragments_text) {
  norm_words <- function(x) {
    x <- tolower(as.character(x))
    x <- gsub("[^a-z0-9 ]", " ", x)
    unique(unlist(strsplit(x, "\\s+")))
  }
  completed_words <- norm_words(completed)
  completed_words <- completed_words[nchar(completed_words) >= 4L]
  completed_words <- setdiff(completed_words, claim_completion_connective_stopwords)
  if (!length(completed_words)) {
    return(TRUE)
  }
  source_words <- norm_words(source_fragments_text)
  all(completed_words %in% source_words)
}

# One BM field's worth of atomic fragments (in order, from
# segment_bm_atomic()) -> a tibble of completion results, one row per
# fragment: original_fragment, needs_completion, completed_claim,
# faithfulness_flagged, explanation. Callers building claim text
# (build_nli_ready_evidence_parquet()) use $completed_claim; the
# atomic_bm validation report (Atomic_BM_Split_Report.qmd) uses every
# column.
#
# `cfg` needs at least $model (same shape as an llm_verification config
# block); `api_key` is the OpenRouter key (Sys.getenv("API_openrouter"),
# same convention as build_llm_verification_parquet()). Resumable: one
# JSON per fragment under
# <cache_dir>/model=<model>/prompt=<hash of system+user prompt+schema>/,
# skipped on re-run.
complete_bm_fragments <- function(
  fragments,
  cfg,
  api_key,
  confidence = NA_character_,
  system_prompt_file = "input/prompts/claim_completion_system.md",
  user_prompt_file = "input/prompts/claim_completion_user.md",
  cache_dir = "output/claim_completion/raw"
) {
  # `confidence` (e.g. "well established", from segment_bm_atomic()'s own
  # extraction) is pure passthrough metadata here -- never shown to the LLM,
  # never touched by completion or the faithfulness guard, just carried
  # alongside each fragment through to the output so the final
  # (claim, confidence) pairing survives filtering below. Recycled to match
  # `fragments`' length if given as a single/short vector.
  confidence <- rep_len(confidence, length(fragments))

  empty <- dplyr::tibble(
    original_fragment = character(0), needs_completion = logical(0),
    completed_claim = character(0), faithfulness_flagged = logical(0),
    confidence = character(0), explanation = character(0)
  )
  if (!length(fragments)) {
    return(empty)
  }
  if (length(fragments) == 1L) {
    # Nothing can be an elliptical continuation of itself -- skip the LLM.
    return(dplyr::tibble(
      original_fragment = fragments, needs_completion = FALSE,
      completed_claim = fragments, faithfulness_flagged = FALSE,
      confidence = confidence,
      explanation = "Only fragment in this BM field -- nothing to complete against"
    ))
  }

  system_prompt <- load_text_file(system_prompt_file)
  user_template <- load_text_file(user_prompt_file)
  type <- claim_completion_output_type()

  prompt_hash <- substr(
    digest::digest(
      list(
        system_prompt, user_template,
        paste(utils::capture.output(print(type)), collapse = "\n")
      ),
      algo = "xxhash64"
    ),
    1, 12
  )
  model_part <- gsub("[^A-Za-z0-9._-]", "_", cfg$model)
  model_cache <- file.path(cache_dir, paste0("model=", model_part), paste0("prompt=", prompt_hash))
  dir.create(model_cache, recursive = TRUE, showWarnings = FALSE)

  preceding_ctx <- vapply(seq_along(fragments), function(i) {
    if (i == 1L) {
      "(none -- this is the first fragment)"
    } else {
      paste(fragments[seq_len(i - 1L)], collapse = "\n\n")
    }
  }, character(1))

  frag_hash <- vapply(seq_along(fragments), function(i) {
    substr(digest::digest(list(preceding_ctx[[i]], fragments[[i]]), algo = "xxhash64"), 1, 16)
  }, character(1))
  cache_path <- file.path(model_cache, paste0(frag_hash, ".json"))
  cached <- file.exists(cache_path)

  if (any(!cached)) {
    todo_idx <- which(!cached)
    prompts <- vapply(todo_idx, function(i) {
      render_template(user_template, list(
        PRECEDING_FRAGMENTS = preceding_ctx[[i]],
        TARGET_FRAGMENT = fragments[[i]]
      ))
    }, character(1))

    chat <- build_llm_verification_chat(cfg, system_prompt, api_key)
    res <- tryCatch(
      ellmer::parallel_chat_structured(
        chat, as.list(prompts), type = type, convert = TRUE,
        max_active = as.integer(cfg$max_active %||% 4L), on_error = "continue"
      ),
      error = function(e) {
        message("  claim completion batch call failed: ", conditionMessage(e))
        NULL
      }
    )

    for (j in seq_along(todo_idx)) {
      i <- todo_idx[[j]]
      raw <- NULL
      if (!is.null(res) && nrow(res) >= j) {
        raw <- tryCatch(as.list(res[j, , drop = FALSE]), error = function(e) NULL)
      }
      err <- NULL
      if (!is.null(raw) && ".error" %in% names(raw)) {
        e <- raw[[".error"]]
        if (is.list(e) && length(e) == 1L) e <- e[[1]]
        if (!is.null(e)) {
          err <- tryCatch(conditionMessage(e), error = function(...) "error")
        }
      }
      parsed <- if (!is.null(err) && nzchar(err)) {
        list(
          needs_completion = FALSE, completed_claim = fragments[[i]],
          explanation = paste("LLM call failed:", err), failed = TRUE
        )
      } else if (is.null(raw)) {
        list(
          needs_completion = FALSE, completed_claim = fragments[[i]],
          explanation = "no response", failed = TRUE
        )
      } else {
        list(
          needs_completion = isTRUE(as.logical(raw$needs_completion[[1]] %||% FALSE)),
          completed_claim = as.character(raw$completed_claim[[1]] %||% fragments[[i]]),
          explanation = as.character(raw$explanation[[1]] %||% ""),
          failed = FALSE
        )
      }
      jsonlite::write_json(parsed, cache_path[[i]], auto_unbox = TRUE, na = "null")
    }
  }

  source_fragments_text <- paste(fragments, collapse = " ")
  out <- dplyr::bind_rows(lapply(seq_along(fragments), function(i) {
    parsed <- jsonlite::read_json(cache_path[[i]], simplifyVector = TRUE)
    claim <- as.character(parsed$completed_claim %||% fragments[[i]])
    needs_completion <- isTRUE(parsed$needs_completion)
    faithful <- if (needs_completion) claim_completion_is_faithful(claim, source_fragments_text) else TRUE
    if (needs_completion && !faithful) {
      claim <- fragments[[i]]
    }
    dplyr::tibble(
      original_fragment = fragments[[i]],
      needs_completion = needs_completion,
      completed_claim = claim,
      faithfulness_flagged = needs_completion && !faithful,
      confidence = confidence[[i]],
      explanation = as.character(parsed$explanation %||% "")
    )
  }))

  # Post-completion length/validity floor (deliberately NOT applied in
  # segment_bm_atomic() -- see that function's own comment for why).
  out[nchar(out$completed_claim) > 20L, ]
}
