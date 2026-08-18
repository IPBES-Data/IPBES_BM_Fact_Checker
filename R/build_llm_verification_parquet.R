# Phase 2 of the two-phase NLI -> LLM pipeline (TD_NLI_LLM_two_phase.qmd).
#
# Architecture ported from the sibling Categorisation_Literature project's
# R/llm_epistemology.R (LLM epistemology classification): one independent
# ellmer::chat_openrouter() call per (claim, work) pair, temperature 0, a
# resumable per-pair JSON cache keyed on a hash of (system prompt, user
# template, output schema), and a post-hoc verbatim-quote check that demotes
# any assessment whose cited evidence does not actually appear in the
# supplied premise text. That quote check is the piece worth having ported
# rather than reinvented: on the sibling project's corpus it caught fabricated
# citations in ~2-4% of otherwise well-formed responses.
#
# Scope: NLI (Phase 1, score_one_claim.R) already scores every (claim, work)
# pair cheaply. Phase 2 does not re-score everything -- each llm_verification
# config picks its own routed set via `nli_labels`/`nli_certainty` in
# input/config.yaml (e.g. REFUTES-at-high-confidence only), rather than a
# single fixed rule -- see select_llm_verification_candidates().
#
# Unlike Phase 1, this needs no crew/file-lock dispatch: ellmer's own
# parallel_chat_structured() concurrency (max_active) is enough, since
# OpenRouter is a shared multi-tenant endpoint, not a fixed pool of hosts to
# load-balance across. One target call per assessment loops over its own
# candidates internally.

`%||%` <- function(x, y) if (is.null(x)) y else x

load_text_file <- function(path) {
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

render_template <- function(template, replacements) {
  out <- template
  for (nm in names(replacements)) {
    out <- gsub(paste0("{{", nm, "}}"), replacements[[nm]], out, fixed = TRUE)
  }
  out
}

# Root must be an object (not a bare scalar/array): OpenAI-compatible strict
# structured-output modes reject a top-level non-object.
llm_verification_output_type <- function() {
  ellmer::type_object(
    .description = paste(
      "LLM verification of one NLI-flagged (claim, work) pair: does the",
      "paper's title/abstract support, refute, or say nothing about the claim?"
    ),
    sufficient_evidence = ellmer::type_boolean(
      paste(
        "TRUE only if the title/abstract contains real evidence bearing on",
        "the claim, in either direction. FALSE is an expected and useful",
        "answer when the text is off-topic or too thin to judge -- do not",
        "feel obliged to find something."
      )
    ),
    llm_label = ellmer::type_string(
      paste(
        "One of SUPPORTS, REFUTES, NOT_ENOUGH_INFO. Must be NOT_ENOUGH_INFO",
        "whenever sufficient_evidence is FALSE."
      )
    ),
    quote = ellmer::type_string(
      paste(
        "Verbatim quote copied exactly from the supplied title or abstract",
        "supporting llm_label. Empty string when sufficient_evidence is FALSE."
      )
    ),
    explanation = ellmer::type_string(
      paste(
        "One or two sentences justifying llm_label, referencing the quote.",
        "Begins with 'Not enough data' when sufficient_evidence is FALSE."
      )
    ),
    .required = TRUE
  )
}

build_llm_verification_chat <- function(cfg, system_prompt, api_key) {
  # max_tokens must be set explicitly, same reasoning as the sibling
  # project's build_epistemology_chat(): left to the provider default, long
  # responses truncate mid-JSON on some models. A single-verdict response
  # here is far shorter than epistemology's per-tradition array, so the
  # default cap (1000) is generous already.
  ellmer::chat_openrouter(
    system_prompt = system_prompt,
    credentials = function() list(Authorization = paste("Bearer", api_key)),
    model = cfg$model,
    params = ellmer::params(
      temperature = cfg$temperature %||% 0,
      max_tokens = as.integer(cfg$max_tokens %||% 1000L)
    ),
    echo = "none",
    # Without these, OpenRouter's dashboard attributes usage to the default
    # User-Agent ("ellmer") instead of this project, making per-project cost
    # tracking impossible across the multiple projects that call OpenRouter.
    api_headers = c(
      "HTTP-Referer" = "https://github.com/IPBES-Data/IPBES_BM_Fact_Checker",
      "X-Title" = "IPBES_BM_Fact_Checker"
    )
  )
}

# Selects the (claim, work) pairs Phase 2 reviews for one assessment, per
# the active llm_verification config's OWN `nli_labels`/`nli_certainty`
# fields (input/config.yaml) -- not a fixed rule. Both are optional filters
# combined with AND, and both accept either a single value or a list:
#   nli_labels    -- NULL (any label, no filter) or one/more labels to
#                    restrict `label` to, e.g. "REFUTES" or c("REFUTES", "SUPPORTS").
#   nli_certainty -- NULL (any), or one/more of "certain" (uncertain == FALSE)
#                    / "uncertain" (uncertain == TRUE), e.g. "certain" or
#                    c("certain", "uncertain") (equivalent to NULL, but
#                    spelled out explicitly).
# So nli_labels = "REFUTES", nli_certainty = "certain" routes only
# high-confidence REFUTES pairs; leaving both NULL routes every scored pair
# (rarely what you want -- that's the full NLI-scored corpus, millions of
# rows). Each ROW keeps its own actual label/certainty regardless of how
# many values a config's fields list -- see nli_route_label() below, which
# partitions by the row's own outcome, not by the filter that let it through.
#
# nli_scores_path is the on-disk output directory for ONE assessment (same
# path construction as build_nli_overview_data.R); nli_ready_path is the
# per-assessment nli_ready_evidence_parquet value, which carries `premise`
# (cleaned title + abstract) -- score_one_claim() does not store premise text
# in its output, only work_id, so the two are joined back here.
select_llm_verification_candidates <- function(nli_scores_path, nli_ready_path,
                                                nli_labels = NULL, nli_certainty = NULL) {
  if (!dir.exists(nli_scores_path)) {
    return(dplyr::tibble())
  }

  ds <- arrow::open_dataset(nli_scores_path)

  if (!is.null(nli_labels)) {
    # yaml::read_yaml() parses a YAML flow-style list as an R list, not an
    # atomic vector -- same gotcha nli_hosts() (R/nli_http_helpers.R) guards
    # against for `nli.configs.<active>.host`.
    nli_labels <- unlist(nli_labels, use.names = FALSE)
    ds <- ds |> dplyr::filter(label %in% nli_labels)
  }
  if (!is.null(nli_certainty)) {
    nli_certainty <- unlist(nli_certainty, use.names = FALSE)
    bad <- setdiff(nli_certainty, c("certain", "uncertain"))
    if (length(bad)) {
      stop(
        'nli_certainty must be "certain", "uncertain", a list of both, or',
        ' NULL/absent (any); got: "', paste(bad, collapse = '", "'), '"'
      )
    }
    # certain -> uncertain == FALSE, uncertain -> uncertain == TRUE; listing
    # both is equivalent to NULL (no filter) but lets a config spell that
    # out explicitly rather than by omission.
    allowed <- c(certain = FALSE, uncertain = TRUE)[nli_certainty]
    ds <- ds |> dplyr::filter(uncertain %in% allowed)
  }

  scored <- ds |>
    dplyr::select(
      km, bm, claim_id, sentence_number, sentence_source, claim, work_id,
      nli_label = label, nli_confidence = confidence,
      p_supports, p_refutes, p_nei, uncertain
    ) |>
    dplyr::collect()

  if (!nrow(scored)) {
    return(dplyr::tibble())
  }

  premises <- arrow::open_dataset(nli_ready_path) |>
    dplyr::select(km, bm, sentence_number, sentence_source, work_id, premise) |>
    dplyr::collect()

  out <- dplyr::inner_join(
    scored, premises,
    by = c("km", "bm", "sentence_number", "sentence_source", "work_id"),
    relationship = "many-to-many"
  )
  out$pair_id <- paste(out$claim_id, out$work_id, sep = "__")
  out$nli_route <- nli_route_label(out$nli_label, out$uncertain)

  # Both `scored` and `premises` can carry duplicate (km, bm, sentence_number,
  # sentence_source, work_id) rows for a small number of BMs -- confirmed on
  # the real corpus: 6,277 duplicated (km, bm, work_id) keys (2.2%) in
  # nli_ready_evidence_parquet, concentrated in 4 BMs, most likely inherited
  # from works_citing_parquet's own snowball edges (a work cited under more
  # than one edge_type). score_one_claim() propagates the same duplication
  # into nli_scores_evidence, since it scores every row of its input
  # unchanged. Left alone, the join above fans out many-to-many for those
  # keys, and duplicate pair_id rows race to write the SAME cache file
  # concurrently. Collapsing to one row per pair_id here fixes Phase 2
  # regardless of whether the upstream duplication itself ever gets
  # deduplicated at the source.
  out <- dplyr::distinct(out, pair_id, .keep_all = TRUE)
  out
}

# Per-ROW, hive-partition-safe identifier for which NLI outcome a pair
# actually has -- e.g. "REFUTES-certain", "SUPPORTS-uncertain". Vectorized
# over label/uncertain (a pair's OWN NLI outcome), not the config's
# nli_labels/nli_certainty filter fields -- a config listing several labels
# or certainties (e.g. nli_labels = c("REFUTES", "SUPPORTS")) still splits
# its routed pairs across one partition per outcome actually present
# (e.g. "REFUTES-certain" and "SUPPORTS-certain" as two separate hive
# partitions), rather than lumping them into one combined string. Kept as
# its own column/path segment so a routed slice is queryable directly, e.g.
# filter(nli_route == "REFUTES-certain") regardless of which config or
# nli_labels/nli_certainty setting produced it.
nli_route_label <- function(label, uncertain) {
  paste(label, ifelse(uncertain, "uncertain", "certain"), sep = "-")
}

# Narrows `candidates` to the sm-derived candidate scope
# (llm_candidate_scope_parquet, see R/build_llm_candidate_scope_parquet.R),
# for `subset: "sm"` configs. A claim with NO entries in the scope table --
# because it had no evidence-reference braces at all, or because the scope
# target itself found nothing to write for this assessment -- falls back to
# unrestricted (keeps every one of that claim's routed candidates), rather
# than being silently excluded. `subset: "all"` never calls this.
#
# Matches on the full (km, bm, claim_id) key, NOT claim_id alone -- claim_id
# is only unique WITHIN one BM (it's derived from sentence_source/number,
# e.g. every BM's first bm_description claim is "bm_description-01"), and is
# reused across 30-49 different (km, bm) pairs per assessment in practice.
# An earlier version of this function matched on claim_id + work_id only,
# which silently let one BM's scope entries authorize candidates for any
# other BM sharing the same claim_id string -- a real over-inclusion bug
# caught by comparing measured call counts against expectations.
apply_candidate_scope <- function(candidates, scope_path) {
  if (!dir.exists(scope_path) || !length(list.files(scope_path, pattern = "\\.parquet$", recursive = TRUE))) {
    return(candidates)
  }

  scope <- arrow::open_dataset(scope_path) |>
    dplyr::select(km, bm, claim_id, work_id) |>
    dplyr::collect()
  if (!nrow(scope)) {
    return(candidates)
  }

  claims_with_scope <- dplyr::distinct(scope, km, bm, claim_id)
  restricted <- candidates |>
    dplyr::semi_join(claims_with_scope, by = c("km", "bm", "claim_id")) |>
    dplyr::semi_join(scope, by = c("km", "bm", "claim_id", "work_id"))
  unrestricted <- candidates |>
    dplyr::anti_join(claims_with_scope, by = c("km", "bm", "claim_id"))

  dplyr::bind_rows(restricted, unrestricted)
}

# Coerce whatever ellmer hands back for one pair into a one-row tibble, and
# enforce the contract the prompt asks for. Unlike the sibling project's
# epistemology schema, this one has no nested array field, so there is no
# list-column to unwrap -- every field here is a plain scalar.
normalise_llm_verification <- function(raw, reason = "LLM call failed") {
  empty <- function(reason, failed = TRUE) {
    dplyr::tibble(
      sufficient_evidence = FALSE,
      llm_label = "NOT_ENOUGH_INFO",
      quote = "",
      explanation = reason,
      failed = failed
    )
  }

  if (is.null(raw)) return(empty(reason))

  scalar <- function(x, default) {
    if (is.null(x) || !length(x)) return(default)
    v <- x
    while (is.list(v) && length(v) == 1L) v <- v[[1]]
    if (is.null(v) || !length(v)) return(default)
    v[[1]]
  }

  sufficient_evidence <- isTRUE(as.logical(scalar(raw$sufficient_evidence, FALSE)))
  llm_label <- as.character(scalar(raw$llm_label, "NOT_ENOUGH_INFO"))
  if (is.na(llm_label) || !llm_label %in% c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")) {
    llm_label <- "NOT_ENOUGH_INFO"
  }
  quote <- as.character(scalar(raw$quote, ""))
  quote <- if (is.na(quote)) "" else quote
  explanation <- as.character(scalar(raw$explanation, ""))
  explanation <- if (is.na(explanation)) "" else explanation

  # Contract enforcement: a claimed assessment without a verbatim quote is
  # not an assessment. Demote it rather than trusting the model's own flag.
  no_quote <- !nzchar(trimws(quote))
  if (sufficient_evidence && no_quote) {
    sufficient_evidence <- FALSE
    explanation <- paste("Not enough data (no verbatim quote supplied).", explanation)
  }
  if (!sufficient_evidence) llm_label <- "NOT_ENOUGH_INFO"

  dplyr::tibble(
    sufficient_evidence = sufficient_evidence,
    llm_label = llm_label,
    quote = quote,
    explanation = explanation,
    failed = FALSE
  )
}

# Verify a quote actually occurs in the premise text the model was shown.
# Ported from the sibling project's verify_quotes(): comparison is on
# lowercased, punctuation-stripped, whitespace-collapsed text so quoting
# differences (smart quotes, spacing) don't cause false alarms; a quote
# containing an ellipsis is treated as several fragments, all of which must
# be present. Returns NA when there is nothing to check (empty quote or
# missing source), so callers can distinguish "not applicable" from "failed".
quote_is_verbatim <- function(quote, source_text) {
  if (!nzchar(trimws(quote)) || is.na(source_text)) return(NA)
  norm <- function(x) {
    x <- tolower(as.character(x))
    x <- gsub("[^a-z0-9 ]", " ", x)
    trimws(gsub("[[:space:]]+", " ", x))
  }
  h <- norm(source_text)
  parts <- unlist(strsplit(quote, "\\.{3}|\u2026"))
  parts <- norm(parts)
  parts <- parts[nzchar(parts)]
  if (!length(parts)) return(NA)
  all(vapply(parts, function(p) grepl(p, h, fixed = TRUE), logical(1)))
}

# Main entry point, one call per assessment. Resumable: one JSON per pair
# under <cache_dir>/model=<model>/prompt=<hash>/, skipped on re-run.
build_llm_verification_parquet <- function(
  assessment,
  nli_ready_path,
  nli_active,
  llm_active,
  cfg,
  system_prompt_file,
  user_prompt_file,
  llm_candidate_scope_path,
  nli_scores_by_claim_evidence = NULL, # unused -- establishes the DAG dependency on Phase 1 scoring
  cache_dir = "output/llm_verification/raw",
  output_root = "output/llm_verification/scores"
) {
  assessment_id <- assessment$id
  subset_val <- as.character(cfg$subset %||% "all")

  # llm_config in the output path/columns is the SELECTED config's NAME
  # (e.g. "openrouter_cheap"), distinct from llm_model (the actual model
  # string) -- same distinction nli_config/nli_model make for Phase 1. Keeping
  # each named config's output on its own path means switching `active` in
  # input/config.yaml, or running two configs side by side for comparison,
  # never overwrites another config's already-scored rows. `subset` gets the
  # same treatment, nested deeper, for the same reason. `nli_route` (e.g.
  # "REFUTES-certain") is NOT part of this fixed prefix -- it's derived per
  # ROW from that row's own NLI outcome (see nli_route_label()), so a single
  # call can write several nli_route= subdirectories nested under this one
  # assessment-scoped path; this path is what gets fully deleted and
  # rewritten each call (below), and what's returned as this target's value.
  output_path <- file.path(
    output_root, paste0("llm_config=", llm_active),
    paste0("subset=", subset_val), paste0("assessment=", assessment_id)
  )

  # Same reasoning as build_nli_overview_data.R: this path is reconstructed
  # rather than taken from nli_scores_by_claim_evidence's own (per-claim,
  # not per-assessment) branch values, which come from the dynamic scoring
  # chain and can't be sliced by assessment directly.
  nli_scores_path <- file.path(
    "output/nli_scores_evidence", paste0("nli_config=", nli_active),
    paste0("assessment=", assessment_id)
  )

  candidates <- select_llm_verification_candidates(
    nli_scores_path, nli_ready_path,
    nli_labels = cfg$nli_labels, nli_certainty = cfg$nli_certainty
  )
  if (subset_val == "sm" && nrow(candidates)) {
    n_before <- nrow(candidates)
    candidates <- apply_candidate_scope(candidates, llm_candidate_scope_path)
    message(sprintf(
      "[LLM verify %s] subset=sm: %d pair(s) after candidate-scope narrowing (was %d)",
      assessment_id, nrow(candidates), n_before
    ))
  }
  if (!nrow(candidates)) {
    message(sprintf("[LLM verify %s] no candidate pairs to review", assessment_id))
    return(output_path)
  }

  api_key <- Sys.getenv("API_openrouter")
  if (!nzchar(api_key)) {
    stop("API_openrouter environment variable is required (set from keyring in _targets.R)")
  }

  system_prompt <- load_text_file(system_prompt_file)
  user_template <- load_text_file(user_prompt_file)

  # Same discipline as the sibling project's cache: the hash covers the
  # prompts AND the schema, so editing either starts a fresh cache namespace
  # rather than silently reusing answers computed under a different contract.
  prompt_hash <- substr(
    digest::digest(
      list(
        system_prompt, user_template,
        paste(utils::capture.output(print(llm_verification_output_type())), collapse = "\n")
      ),
      algo = "xxhash64"
    ),
    1, 12
  )
  model_part <- gsub("[^A-Za-z0-9._-]", "_", cfg$model)
  model_cache <- file.path(cache_dir, paste0("model=", model_part), paste0("prompt=", prompt_hash))
  dir.create(model_cache, recursive = TRUE, showWarnings = FALSE)
  message(sprintf("[LLM verify %s] cache namespace: %s", assessment_id, model_cache))

  # `id` is pair_id = "<claim_id>__<work_id>", and work_id is a full
  # "https://openalex.org/W..." URL -- its embedded "/" characters, used
  # unsanitized, silently turn one filename into an unwritable multi-level
  # path (the parent directories never get created), failing every write
  # with "cannot open the connection". sanitize_partition_value()
  # (R/branch_helpers.R) is this project's existing fix for exactly this
  # class of problem; reused here rather than duplicated. Sanitizing only
  # the FILE PATH, not `pair_id` itself, which stays the original string
  # for joins (candidates/verdicts `by = "pair_id"`).
  cache_path <- function(id) file.path(model_cache, paste0(sanitize_partition_value(id), ".json"))
  cached <- file.exists(cache_path(candidates$pair_id))
  route_counts <- table(candidates$nli_route)
  message(sprintf(
    "[LLM verify %s] %d pair(s) across route(s) %s, %d already cached, %d to call",
    assessment_id, nrow(candidates),
    paste(sprintf("%s=%d", names(route_counts), route_counts), collapse = ", "),
    sum(cached), sum(!cached)
  ))

  chat <- build_llm_verification_chat(cfg, system_prompt, api_key)
  type <- llm_verification_output_type()
  max_active <- as.integer(cfg$max_active %||% 8L)
  chunk_size <- max(1L, max_active * 10L)

  # Score a subset of candidates (by row index) and write each result to the
  # cache. Factored out so the retry pass below can reuse it verbatim.
  run_pairs <- function(idx) {
    prompts <- vapply(idx, function(i) {
      render_template(user_template, list(
        BM_TEXT        = candidates$claim[[i]],
        TITLE_ABSTRACT = candidates$premise[[i]],
        NLI_LABEL      = candidates$nli_label[[i]],
        NLI_CONFIDENCE = sprintf("%.2f", candidates$nli_confidence[[i]]),
        P_SUPPORTS     = sprintf("%.2f", candidates$p_supports[[i]]),
        P_REFUTES      = sprintf("%.2f", candidates$p_refutes[[i]]),
        P_NEI          = sprintf("%.2f", candidates$p_nei[[i]])
      ))
    }, character(1))

    starts <- seq(1, length(prompts), by = chunk_size)
    for (ci in seq_along(starts)) {
      lo <- starts[[ci]]
      hi <- min(lo + chunk_size - 1L, length(prompts))
      message(sprintf(
        "[LLM verify %s]   chunk %d/%d (pairs %d-%d of %d)",
        assessment_id, ci, length(starts), lo, hi, length(prompts)
      ))

      res <- tryCatch(
        ellmer::parallel_chat_structured(
          chat, as.list(prompts[lo:hi]),
          type = type, convert = TRUE, max_active = max_active, on_error = "continue"
        ),
        error = function(e) {
          message("    parallel_chat_structured failed: ", conditionMessage(e))
          NULL
        }
      )

      for (j in seq_len(hi - lo + 1L)) {
        i <- idx[[lo + j - 1L]]
        raw <- NULL
        if (!is.null(res) && nrow(res) >= j) {
          raw <- tryCatch(as.list(res[j, , drop = FALSE]), error = function(e) NULL)
        }
        # parallel_chat_structured(on_error = "continue") adds a `.error`
        # column holding the actual condition when a request failed. That
        # text is what turns "no parseable response" into something
        # diagnosable later, rather than a silent blank verdict.
        err <- NULL
        if (!is.null(raw) && ".error" %in% names(raw)) {
          e <- raw[[".error"]]
          if (is.list(e) && length(e) == 1L) e <- e[[1]]
          if (!is.null(e)) {
            err <- tryCatch(conditionMessage(e), error = function(...) {
              paste(utils::capture.output(print(e)), collapse = " ")
            })
          }
          raw[[".error"]] <- NULL
        }
        parsed <- if (!is.null(err) && nzchar(err)) {
          normalise_llm_verification(NULL, reason = paste("LLM call failed:", err))
        } else {
          normalise_llm_verification(raw)
        }
        jsonlite::write_json(parsed, cache_path(candidates$pair_id[[i]]), auto_unbox = TRUE, na = "null")
      }
    }
  }

  todo <- which(!cached)
  if (length(todo)) run_pairs(todo)

  failed_ids <- function() {
    which(vapply(candidates$pair_id, function(id) {
      p <- cache_path(id)
      if (!file.exists(p)) return(FALSE)
      r <- tryCatch(jsonlite::read_json(p, simplifyVector = TRUE), error = function(e) NULL)
      is.null(r) || !("failed" %in% names(r)) || isTRUE(any(as.logical(r$failed)))
    }, logical(1)))
  }

  # Retry failures -- usually transient provider errors, not anything wrong
  # with the request (see the sibling project's assess_epistemology() for
  # the measured recovery rate). Without this pass a transient failure sits
  # in the cache as a permanent one until someone deletes the file by hand.
  max_retries <- as.integer(cfg$max_retries %||% 2L)
  for (attempt in seq_len(max_retries)) {
    bad <- failed_ids()
    if (!length(bad)) break
    message(sprintf(
      "[LLM verify %s]   retry %d/%d: %d pair(s) failed -- usually transient",
      assessment_id, attempt, max_retries, length(bad)
    ))
    run_pairs(bad)
  }

  verdicts <- dplyr::bind_rows(lapply(candidates$pair_id, function(id) {
    p <- cache_path(id)
    if (!file.exists(p)) return(NULL)
    r <- tryCatch(jsonlite::read_json(p, simplifyVector = TRUE), error = function(e) NULL)
    if (is.null(r)) return(NULL)
    r$pair_id <- id
    dplyr::as_tibble(r)
  }))

  if (!nrow(verdicts)) {
    stop(sprintf("[LLM verify %s] no verdicts were produced.", assessment_id))
  }

  # Guard against the silent-failure mode: if a model ignores the
  # JSON-schema request, every call fails to parse and the run looks like
  # 100% honest NOT_ENOUGH_INFO. Fail loudly instead of shipping an empty
  # result that reads as conservative rather than broken.
  failed_n <- sum(verdicts$failed)
  if (failed_n) {
    frac <- failed_n / nrow(verdicts)
    msg <- sprintf(
      "[LLM verify %s] %d of %d pair(s) (%.0f%%) produced no parseable response from '%s'.",
      assessment_id, failed_n, nrow(verdicts), 100 * frac, cfg$model
    )
    if (frac >= 0.5) {
      stop(msg, " This is a model/plumbing failure, not conservative abstention.", call. = FALSE)
    }
    warning(msg, " Recorded with failed = TRUE and NOT counted as abstentions.", call. = FALSE)
  }

  out <- dplyr::inner_join(candidates, verdicts, by = "pair_id")

  out$quote_verbatim <- mapply(quote_is_verbatim, out$quote, out$premise)
  bogus <- out$sufficient_evidence & !is.na(out$quote_verbatim) & !out$quote_verbatim
  if (any(bogus)) {
    message(sprintf(
      "[LLM verify %s]   %d quote(s) not found verbatim in the source text -- demoted",
      assessment_id, sum(bogus)
    ))
    out$sufficient_evidence[bogus] <- FALSE
    out$llm_label[bogus] <- "NOT_ENOUGH_INFO"
    out$explanation[bogus] <- paste(
      "Not enough data (cited quote does not appear in the supplied text).",
      out$explanation[bogus]
    )
  }

  out$llm_agrees <- out$llm_label == out$nli_label
  out$llm_config <- llm_active
  # nli_route already exists on `out` -- computed per row inside
  # select_llm_verification_candidates() from that row's own nli_label/
  # uncertain, and carried through the inner_join with verdicts above.
  out$subset <- subset_val
  out$llm_model <- cfg$model
  out$nli_config <- nli_active
  out$assessment <- assessment_id

  out <- out |>
    dplyr::select(
      llm_config, subset, nli_config, assessment, nli_route, km, bm, claim_id, work_id, claim,
      nli_label, uncertain, nli_confidence, p_supports, p_refutes, p_nei,
      llm_model, llm_label, llm_agrees, sufficient_evidence,
      quote, quote_verbatim, explanation
    )

  if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)
  arrow::write_dataset(
    dataset = out,
    path = output_root,
    format = "parquet",
    partitioning = c("llm_config", "subset", "assessment", "nli_route", "km", "bm"),
    existing_data_behavior = "delete_matching"
  )

  message(sprintf(
    "[LLM verify %s] wrote %d verified row(s) to %s", assessment_id, nrow(out), output_path
  ))
  output_path
}
