# Reconciliation utility for Phase 1 (NLI scoring) output — NOT wired into
# _targets.R as a target. Nothing in the pipeline prunes scored claims that
# no longer correspond to anything in the current nli_ready_evidence_parquet
# input (a since-changed segmentation boundary, a renumbered sentence, ...),
# and score_one_claim()'s own resumability check has no way to notice this
# either — it only ever looks at ITS OWN claim_id, never at what else exists
# on disk. Run this by hand (e.g. from an interactive R session) when you
# want to check for or clean up orphans; it never deletes anything unless
# `delete = TRUE` is passed explicitly.
#
# claim_id alone is not globally unique — the same claim_id string (e.g.
# "bm_description-01") is reused across every BM in an assessment — so the
# comparison is always on the full (km, bm, claim_id) triple, matching how
# score_one_claim() itself partitions its output.

# One (assessment, granularity, nli_config) combination. nli_ready_path and
# nli_scores_path are the same assessment-scoped directories the pipeline
# itself uses (see nli_ready_evidence_parquet / nli_scores_by_claim_evidence
# in _targets.R) — pass them in already resolved, same convention as the
# rest of R/build_*.R.
find_orphaned_nli_scores <- function(nli_ready_path, nli_scores_path, delete = FALSE) {
  empty <- dplyr::tibble(
    km = character(), bm = character(), claim_id = character(), path = character()
  )

  if (!dir.exists(nli_ready_path) || !dir.exists(nli_scores_path)) {
    return(empty)
  }

  # sprintf() isn't supported inside an Arrow-lazy dplyr::mutate() -- collect
  # the (already small) distinct km/bm/sentence_source/sentence_number keys
  # first, then derive claim_id in plain R, same formula as
  # build_nli_claim_units() (R/build_nli_claim_units.R).
  expected <- arrow::open_dataset(nli_ready_path) |>
    dplyr::distinct(km, bm, sentence_source, sentence_number) |>
    dplyr::collect() |>
    dplyr::mutate(claim_id = sprintf("%s-%02d", sentence_source, sentence_number)) |>
    dplyr::distinct(km, bm, claim_id)
  expected_key <- paste(expected$km, expected$bm, expected$claim_id, sep = "")

  claim_dirs <- list.files(
    nli_scores_path,
    recursive = TRUE, include.dirs = TRUE, full.names = TRUE,
    pattern = "^claim_id="
  )
  claim_dirs <- claim_dirs[
    dir.exists(claim_dirs) & lengths(lapply(claim_dirs, list.files, pattern = "\\.parquet$")) > 0
  ]

  if (!length(claim_dirs)) {
    return(empty)
  }

  parse_one <- function(path) {
    parts <- strsplit(path, "/", fixed = TRUE)[[1]]
    km_part    <- parts[grepl("^km=", parts)]
    bm_part    <- parts[grepl("^bm=", parts)]
    claim_part <- parts[grepl("^claim_id=", parts)]
    if (!length(km_part) || !length(bm_part) || !length(claim_part)) {
      return(NULL)
    }
    dplyr::tibble(
      km       = sub("^km=", "", km_part[[1L]]),
      bm       = sub("^bm=", "", bm_part[[1L]]),
      claim_id = sub("^claim_id=", "", claim_part[[length(claim_part)]]),
      path     = path
    )
  }
  on_disk <- dplyr::bind_rows(lapply(claim_dirs, parse_one))
  if (!nrow(on_disk)) {
    return(empty)
  }
  on_disk_key <- paste(on_disk$km, on_disk$bm, on_disk$claim_id, sep = "")

  orphaned <- on_disk[!(on_disk_key %in% expected_key), , drop = FALSE]

  if (nrow(orphaned)) {
    message(sprintf(
      "[NLI orphan-check] %d/%d scored claim director%s under %s have no matching claim in %s",
      nrow(orphaned), nrow(on_disk), if (nrow(orphaned) == 1) "y" else "ies",
      nli_scores_path, nli_ready_path
    ))
    for (i in seq_len(nrow(orphaned))) {
      message(sprintf(
        "  - km=%s bm=%s claim_id=%s (%s)",
        orphaned$km[i], orphaned$bm[i], orphaned$claim_id[i], orphaned$path[i]
      ))
    }
    if (delete) {
      for (p in orphaned$path) unlink(p, recursive = TRUE, force = TRUE)
      message(sprintf(
        "[NLI orphan-check] deleted %d orphaned director%s",
        nrow(orphaned), if (nrow(orphaned) == 1) "y" else "ies"
      ))
    }
  } else {
    message(sprintf(
      "[NLI orphan-check] no orphans found under %s (%d claim%s checked)",
      nli_scores_path, nrow(on_disk), if (nrow(on_disk) == 1) "" else "s"
    ))
  }

  orphaned
}

# Convenience wrapper: runs find_orphaned_nli_scores() across every
# (assessment x granularity) combination this project tracks, resolving
# each granularity's own nli_config via nli_config_for_granularity()
# (R/branch_helpers.R) rather than assuming nli.active — same reasoning as
# the nli_overview_data/refutes_funnel_data/supports_funnel_data fix: each
# granularity is normally scored under its OWN dedicated config, not
# whichever one happens to be active right now. Read-only by default; pass
# delete = TRUE to remove every orphan found across every combination in
# one go (there is no undo — prefer running once with the default first and
# reviewing the report).
find_orphaned_nli_scores_all <- function(
  config_path = "input/config.yaml",
  nli_granularities = c("naive_bm", "complete_bm", "atomic_bm"),
  delete = FALSE
) {
  cfg <- yaml::read_yaml(config_path)
  assessment_ids <- vapply(cfg[["assessments"]], `[[`, character(1), "id")
  nli_active <- cfg[["nli"]][["active"]]
  nli_configs_all <- cfg[["nli"]][["configs"]]

  combos <- expand.grid(
    assessment_id = assessment_ids,
    granularity   = nli_granularities,
    stringsAsFactors = FALSE
  )

  results <- lapply(seq_len(nrow(combos)), function(i) {
    assessment_id <- combos$assessment_id[[i]]
    granularity   <- combos$granularity[[i]]
    nli_config_name <- nli_config_for_granularity(nli_configs_all, granularity, nli_active)

    nli_ready_path <- file.path(
      "output/nli_ready_evidence", paste0("granularity=", granularity),
      paste0("assessment=", assessment_id)
    )
    nli_scores_path <- file.path(
      "output/nli_scores_evidence", paste0("granularity=", granularity),
      paste0("nli_config=", nli_config_name), paste0("assessment=", assessment_id)
    )

    out <- find_orphaned_nli_scores(nli_ready_path, nli_scores_path, delete = delete)
    if (nrow(out)) {
      out$assessment  <- assessment_id
      out$granularity <- granularity
      out$nli_config  <- nli_config_name
    }
    out
  })

  dplyr::bind_rows(results)
}
