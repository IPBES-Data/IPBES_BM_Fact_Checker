# Per-claim candidate scope for Phase 2 LLM verification (`subset: "sm"` in
# an `llm_verification` config — see TD_NLI_LLM_two_phase.qmd).
#
# NLI (and the `subset: "all"` Phase 2 default) treats every citing work
# found anywhere under a Background Message as a candidate for every claim
# segmented out of that BM's text. This file derives a tighter, principled
# scope instead: each evidence-segmented claim ends with a brace group like
# `{5.4.1, 5.4.2}` naming the specific IPBES sub-chapter(s) it draws on, and
# `refs_parquet`'s `sm` column already links specific references (dois) to
# those same sub-chapter identifiers. Chaining sm -> seed doi -> seed
# OpenAlex work id -> citing work (via the existing snowball edges) gives,
# per claim, an allow-list of citing works actually tied to its own
# evidentiary basis rather than the whole BM's.
#
# Deliberately reads ONLY already-existing, unmodified targets
# (key_messages_parquet, refs_parquet, works_parquet, the snowball edges
# dataset, nli_ready_evidence_parquet) and writes to its own new output root.
# Nothing here edits or invalidates download_works.R, build_snowball_parquet.R,
# build_works_citing_parquet.R, build_nli_ready_evidence_parquet.R, or the NLI
# scoring chain -- `targets` invalidation only flows forward from something
# that actually changes, and none of those files or their targets change.
#
# In particular, this file does NOT call or edit
# segment_bm_by_evidence() (R/build_nli_ready_evidence_parquet.R): `targets`
# hashes function BODIES as dependencies, so even a behavior-preserving edit
# there would mark nli_ready_evidence_parquet -- and everything downstream of
# it, including nli_scores_by_claim_evidence -- outdated. Instead,
# extract_claim_evidence_tokens() below duplicates the small amount of
# sentence-splitting/terminal-brace/buffer logic needed, byte-for-byte, so
# segment boundaries (and therefore claim_id numbering) land on the exact
# same claims. If segment_bm_by_evidence() is ever changed, this function
# must be updated to match, or claim_id attribution here will silently drift
# out of sync -- build_llm_candidate_scope_parquet() cross-checks this at
# build time (see step 6) and warns (not stops) on a mismatch.

# ---- Duplicated (see file header) segmentation, extracting instead of stripping braces ----

# Mirrors segment_bm_by_evidence()'s sentence-split regex, terminal-brace
# regex, buffer accumulate/flush behavior, and nchar > 20 filter (applied to
# the STRIPPED text, exactly as the original does, so that a short segment
# being dropped shifts subsequent sentence_number values down the same way
# in both places). Returns a list, one element per SURVIVING segment (so
# seq_along() reproduces the original's sentence_number exactly); each
# element is the character vector of raw `{...}` group contents in that
# segment (possibly empty, when the segment's terminal brace was its only
# content and stripping it left nothing else, or -- more commonly -- for the
# trailing non-terminal-brace synthesizing segment rule 2 keeps around).
extract_claim_evidence_tokens <- function(text) {
  if (is.na(text) || !nzchar(text)) {
    return(list())
  }

  sentences <- stringr::str_squish(
    stringr::str_split(text, "(?<=[.!?])\\s+")[[1L]]
  )
  sentences <- sentences[nzchar(sentences)]
  if (!length(sentences)) {
    return(list())
  }

  ends_with_ref <- stringr::str_detect(sentences, "\\}[)]?[.!?…]*\\s*$")

  segments <- character(0)
  buffer <- character(0)
  for (i in seq_along(sentences)) {
    buffer <- c(buffer, sentences[[i]])
    if (ends_with_ref[[i]]) {
      segments <- c(segments, paste(buffer, collapse = " "))
      buffer <- character(0)
    }
  }
  if (length(buffer)) {
    segments <- c(segments, paste(buffer, collapse = " "))
  }
  if (!length(segments)) {
    return(list())
  }

  stripped <- stringr::str_squish(stringr::str_remove_all(segments, "\\s*\\{[^}]*\\}"))
  segments <- segments[nchar(stripped) > 20L]
  if (!length(segments)) {
    return(list())
  }

  lapply(segments, function(seg) {
    m <- stringr::str_match_all(seg, "\\{([^}]*)\\}")[[1L]]
    if (!nrow(m)) character(0) else m[, 2L]
  })
}

# ---- Sub-chapter token normalization / matching ----------------------------

# The `sm` field (and brace content) is messy free text: comma- AND
# semicolon-separated lists, "box"/"Box"/"table"/"Table"/"SPM Table" prefixes
# with inconsistent casing, trailing letter suffixes ("5.4.2.1.a"),
# parenthetical annotations ("3.3.2.2 (Sustainable Development Goal 3)"), and
# occasional malformed strings with unbalanced parentheses. This normalizer
# is deliberately best-effort, not exhaustive -- residual gaps (e.g. the
# malformed cases) are an accepted, disclosed limitation: `subset: "all"`
# remains available as the exhaustive fallback.
normalize_evidence_token <- function(x) {
  x <- tolower(x)
  x <- sub("^\\s*(spm\\s+table|box|boxes|table|tables)[.:\\s]*", "", x)
  x <- gsub("\\([^)]*\\)", "", x)
  x <- gsub("\\s+", " ", x)
  trimws(x)
}

tokenize_evidence_field <- function(x) {
  toks <- unlist(strsplit(x, "[,;]"))
  toks <- vapply(toks, normalize_evidence_token, character(1), USE.NAMES = FALSE)
  toks[nzchar(toks)]
}

# TRUE if two normalized tokens could refer to the same sub-chapter -- either
# is a string-prefix of the other. Handles "5.4.2.1" <-> "5.4.2.1.a" (a
# lettered sub-part of a numbered subsection) and a bare "4" <-> any "4.x.y"
# (a whole-chapter reference covering all its subsections).
evidence_tokens_match <- function(a, b) {
  nzchar(a) && nzchar(b) && (startsWith(a, b) || startsWith(b, a))
}

# For one (km, bm) group: claim_df has one row per (claim_id, evidence_token);
# sm_seed_df has one row per (sm_token, seed_work_id). Returns one row per
# (claim_id, seed_work_id) where some token pair prefix-matches. Small group
# sizes (a handful of claim tokens, low hundreds of sm/seed rows per BM) make
# the nested scan cheap in practice.
match_claim_tokens_to_seeds <- function(claim_df, sm_seed_df) {
  out <- lapply(seq_len(nrow(claim_df)), function(i) {
    ct <- claim_df$evidence_token[[i]]
    hit <- vapply(sm_seed_df$sm_token, evidence_tokens_match, logical(1), b = ct)
    if (!any(hit)) return(NULL)
    dplyr::tibble(
      km = claim_df$km[[i]], bm = claim_df$bm[[i]],
      claim_id = claim_df$claim_id[[i]],
      seed_work_id = unique(sm_seed_df$seed_work_id[hit])
    )
  })
  dplyr::bind_rows(out)
}

# Main entry point, one call per assessment.
build_llm_candidate_scope_parquet <- function(
  assessment,
  key_messages_parquet,
  refs_parquet,
  works_parquet,
  snowball_parquet, # unused directly -- edges path reconstructed below (same
                     # convention as build_nli_overview_data.R's nli_scores_path);
                     # establishes the DAG dependency only.
  nli_ready_evidence_parquet,
  output_root = "output/llm_candidate_scope",
  nli_granularity = "naive_bm"
) {
  assessment_id <- assessment$id
  output_path <- file.path(output_root, paste0("assessment=", assessment_id))
  if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)

  # A directory that exists but holds no parquet files is the "no
  # restriction available" sentinel build_llm_verification_parquet() checks
  # for -- `arrow::write_dataset()` on a genuinely empty tibble would not
  # create the partition directory at all, so writing one out here (via
  # dir.create(), not write_dataset()) is what makes that check reliable.
  empty_result <- function(reason) {
    message(sprintf(
      "[LLM scope %s] %s -- no restriction will be applied for any claim",
      assessment_id, reason
    ))
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    output_path
  }

  # extract_claim_evidence_tokens() below duplicates segment_bm_by_evidence()
  # (see file header) and has no complete_bm counterpart -- per-sub-claim
  # evidence scoping isn't supported for complete_bm's whole-field claims,
  # so fall back to the same "no restriction available" sentinel used
  # elsewhere rather than silently producing wrong scope data.
  if (identical(nli_granularity, "complete_bm")) {
    return(empty_result("granularity is complete_bm -- per-sub-claim evidence scoping is not supported"))
  }

  # ---- 1. Per-claim evidence-reference tokens, derived directly from BM text
  bm_info <- arrow::open_dataset(key_messages_parquet) |>
    dplyr::select(km, bm, bm_label, bm_description) |>
    dplyr::distinct() |>
    dplyr::collect()

  claim_tokens <- dplyr::bind_rows(lapply(seq_len(nrow(bm_info)), function(i) {
    row <- bm_info[i, , drop = FALSE]
    sources <- list()
    if (!is.na(row$bm_description) && nzchar(row$bm_description)) {
      sources[["bm_description"]] <- row$bm_description
    }
    if (!is.na(row$bm_label) && nzchar(row$bm_label)) {
      sources[["bm_label"]] <- row$bm_label
    }
    if (!length(sources)) return(NULL)

    dplyr::bind_rows(lapply(names(sources), function(src) {
      per_segment <- extract_claim_evidence_tokens(sources[[src]])
      if (!length(per_segment)) return(NULL)
      dplyr::bind_rows(lapply(seq_along(per_segment), function(sn) {
        toks <- unique(unlist(lapply(per_segment[[sn]], tokenize_evidence_field)))
        if (!length(toks)) return(NULL)
        dplyr::tibble(
          km = row$km, bm = row$bm,
          claim_id = sprintf("%s-%02d", src, sn),
          evidence_token = toks
        )
      }))
    }))
  }))

  if (!nrow(claim_tokens)) {
    return(empty_result("no evidence-reference tokens found in any BM"))
  }

  # ---- 2. refs' sm column, exploded + normalized, joined to doi -----------
  refs_sm <- arrow::open_dataset(refs_parquet) |>
    dplyr::filter(!is.na(sm), !is.na(doi)) |>
    dplyr::select(km, bm, sm, doi) |>
    dplyr::collect()

  if (!nrow(refs_sm)) {
    return(empty_result("refs_parquet has no sm/doi rows for this assessment"))
  }

  sm_doi <- dplyr::bind_rows(lapply(seq_len(nrow(refs_sm)), function(i) {
    toks <- tokenize_evidence_field(refs_sm$sm[[i]])
    if (!length(toks)) return(NULL)
    dplyr::tibble(
      km = refs_sm$km[[i]], bm = refs_sm$bm[[i]],
      sm_token = toks, doi = refs_sm$doi[[i]]
    )
  }))

  if (!nrow(sm_doi)) {
    return(empty_result("no sm value in refs_parquet tokenized to anything usable"))
  }

  # ---- 3. seed OpenAlex work id for each doi -------------------------------
  works <- arrow::open_dataset(works_parquet) |>
    dplyr::select(km, bm, id, doi) |>
    dplyr::filter(!is.na(doi)) |>
    dplyr::collect() |>
    dplyr::mutate(doi_norm = stringr::str_to_lower(doi))

  sm_seed <- sm_doi |>
    dplyr::mutate(doi_norm = stringr::str_to_lower(doi)) |>
    dplyr::inner_join(
      works |> dplyr::select(km, bm, doi_norm, seed_work_id = id),
      by = c("km", "bm", "doi_norm"),
      relationship = "many-to-many"
    ) |>
    dplyr::select(km, bm, sm_token, seed_work_id) |>
    dplyr::distinct()

  if (!nrow(sm_seed)) {
    return(empty_result("no sm-tokenized reference matched a seed work by doi"))
  }

  # ---- 4. match claim tokens to seed works, per (km, bm) -------------------
  claim_groups <- split(claim_tokens, paste(claim_tokens$km, claim_tokens$bm, sep = ""))
  seed_groups  <- split(sm_seed,      paste(sm_seed$km,      sm_seed$bm,      sep = ""))

  claim_seed <- dplyr::bind_rows(lapply(names(claim_groups), function(key) {
    sg <- seed_groups[[key]]
    if (is.null(sg) || !nrow(sg)) return(NULL)
    match_claim_tokens_to_seeds(claim_groups[[key]], sg)
  }))

  if (!nrow(claim_seed)) {
    return(empty_result("no claim evidence-token matched any seed reference's sub-chapter"))
  }

  # ---- 5. seed work -> citing work, via the existing snowball edges -------
  edges_path <- file.path("output/snowball/edges", paste0("assessment=", assessment_id))
  if (!dir.exists(edges_path)) {
    return(empty_result(sprintf("no snowball edges found at %s", edges_path)))
  }

  seed_ids <- unique(claim_seed$seed_work_id)
  edges <- arrow::open_dataset(edges_path) |>
    dplyr::filter(to %in% seed_ids) |>
    dplyr::select(from, to) |>
    dplyr::distinct() |>
    dplyr::collect()

  if (!nrow(edges)) {
    return(empty_result("no snowball edge cites any in-scope seed work"))
  }

  out <- claim_seed |>
    dplyr::inner_join(edges, by = c("seed_work_id" = "to"), relationship = "many-to-many") |>
    dplyr::transmute(assessment = assessment_id, km, bm, claim_id, work_id = from) |>
    dplyr::distinct()

  if (!nrow(out)) {
    return(empty_result("no citing work traced back to an in-scope seed work"))
  }

  # ---- 6. non-fatal drift check against nli_ready_evidence_parquet's own claim_ids
  actual_claim_ids <- tryCatch(
    arrow::open_dataset(nli_ready_evidence_parquet) |>
      dplyr::select(claim_id) |>
      dplyr::distinct() |>
      dplyr::collect() |>
      dplyr::pull(claim_id),
    error = function(e) NULL
  )
  if (!is.null(actual_claim_ids)) {
    drifted <- setdiff(unique(claim_tokens$claim_id), actual_claim_ids)
    if (length(drifted)) {
      warning(sprintf(
        paste(
          "[LLM scope %s] %d evidence-derived claim_id(s) (e.g. %s) do not appear in",
          "nli_ready_evidence_parquet -- extract_claim_evidence_tokens() in",
          "R/build_llm_candidate_scope_parquet.R may have drifted out of sync with",
          "segment_bm_by_evidence() in R/build_nli_ready_evidence_parquet.R."
        ),
        assessment_id, length(drifted), paste(utils::head(drifted, 3), collapse = ", ")
      ), call. = FALSE)
    }
  }

  arrow::write_dataset(
    dataset = out,
    path = output_root,
    format = "parquet",
    partitioning = c("assessment", "km", "bm"),
    existing_data_behavior = "delete_matching"
  )

  message(sprintf(
    "[LLM scope %s] wrote %d (claim, work) allow-list row(s) for %d claim(s) to %s",
    assessment_id, nrow(out), dplyr::n_distinct(out$claim_id), output_path
  ))
  output_path
}
