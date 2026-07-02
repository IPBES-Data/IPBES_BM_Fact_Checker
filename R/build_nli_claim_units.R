# One list element per (km, bm, sentence_source, sentence_number) claim
# remaining to be scored for one assessment — the unit of work for
# crew-based dynamic dispatch (one target branch per claim). Carries only
# identifying keys + pair count, NOT premises — those are re-read from
# nli_ready_parquet at claim-scoring time (via partition-pruned filtering)
# so this target's cached branch values stay small regardless of how many
# works a claim has.
build_nli_claim_units <- function(assessment, nli_ready_path, nli_config) {
  assessment_id <- assessment$id
  max_length <- nli_cfg_get(nli_config, "max_length", NULL)
  filter_limit <- if (!is.null(max_length)) as.integer(max_length) else 512L

  ready <- arrow::open_dataset(nli_ready_path) |>
    dplyr::filter(approx_tokens <= filter_limit) |>
    dplyr::select(km, bm, sentence_number, sentence_source, claim) |>
    dplyr::collect()

  if (!nrow(ready)) {
    return(list())
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
