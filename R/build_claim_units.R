# One list element per (km, bm, sentence_source, sentence_number) claim
# remaining to be scored for one assessment — the unit of work for
# crew-based dynamic dispatch (one target branch per claim). Carries only
# identifying keys + pair count, NOT premises — those are re-read from
# nli_ready_parquet at claim-scoring time (via partition-pruned filtering)
# so this target's cached branch values stay small regardless of how many
# works a claim has.
# `km` scopes which Key Messages are enumerated; NULL (the default) means every
# one, so the key-paper arm in _targets_training.R -- which passes nothing -- is
# unaffected. This is the ONLY filter point the fact-checking chain needs: every
# later stage reads from the one before it, so fewer units here means fewer
# scoring branches, fewer consolidated rows, and fewer candidates reaching the
# relevance screen and Phase 2.
#
# Deliberately NOT applied further upstream: output/claim_work_pairs/ carries
# no scorer_config= level, so the cross-join is shared by every config, and
# build_claim_work_pairs() unlink()s the whole assessment= subtree
# before writing -- filtering there would delete out-of-scope premises outright.
build_claim_units <- function(assessment, nli_ready_path, max_length, km = NULL) {
  assessment_id <- assessment$id
  filter_limit <- if (!is.null(max_length)) as.integer(max_length) else 512L

  ready <- arrow::open_dataset(nli_ready_path) |>
    dplyr::filter(approx_tokens <= filter_limit) |>
    dplyr::select(km, bm, sentence_number, sentence_source, claim) |>
    dplyr::collect()

  if (!nrow(ready)) {
    return(list())
  }

  # Scope validation lives here, not in purpose_config(): Key Messages come from
  # key_messages_parquet, a target, so config cannot check its own values. A
  # silent miss is the dangerous outcome -- `"A"` for `"A."` would enumerate zero
  # claims, score nothing, and look exactly like a completed run.
  if (!is.null(km) && length(km)) {
    km <- as.character(km)
    available <- sort(unique(ready$km))
    missing <- setdiff(km, available)
    if (length(missing)) {
      stop(sprintf(
        "build_claim_units(%s): km scope names %s, which %s not exist in this assessment. Available: %s",
        assessment_id, paste(sQuote(missing), collapse = ", "),
        if (length(missing) == 1L) "does" else "do",
        paste(available, collapse = ", ")
      ), call. = FALSE)
    }
    ready <- ready[ready$km %in% km, , drop = FALSE]
    if (!nrow(ready)) {
      return(list())
    }
  }

  claim_counts <- ready |>
    dplyr::mutate(claim_id = sprintf("%s-%02d", sentence_source, sentence_number)) |>
    dplyr::count(km, bm, sentence_number, sentence_source, claim, claim_id, name = "n_pairs") |>
    dplyr::arrange(dplyr::desc(n_pairs))

  lapply(seq_len(nrow(claim_counts)), function(i) {
    row <- claim_counts[i, ]
    list(
      assessment      = assessment_id,
      nli_ready_path  = nli_ready_path,
      km              = row$km,
      bm              = row$bm,
      sentence_number = row$sentence_number,
      sentence_source = row$sentence_source,
      claim           = row$claim,
      claim_id        = row$claim_id,
      n_pairs         = row$n_pairs
    )
  })
}
