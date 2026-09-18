# How much NLI scoring is actually outstanding, per assessment and per claim.
#
# Read-only and free: no RunPod pool, no API keys, no pipeline run. It compares
# the claim list's own `n_pairs` (what nli_ready_evidence_parquet currently
# holds for each claim) against the row count already in nli_scores_evidence.
# Nothing else in the pipeline answers this question -- score_one_claim() only
# ever inspects the one claim it was handed, and find_orphaned_nli_scores()
# looks the other way (scored claims with no upstream), so a claim that is
# scored but INCOMPLETE is invisible to both.
#
# Deliberately not wired into _targets.R, same as find_orphaned_nli_scores():
# it is an operator report, not a pipeline input, and the number it prints is
# a spend decision rather than a build artifact.
#
# Why it exists: before delta dispatch was added to score_one_claim(), a claim
# was skipped outright once it had ANY output, so every snowball re-run froze
# already-scored claims at their old coverage with no signal at all. Delta
# dispatch fixes the scoring; this reports what the accumulated backlog is, and
# what the next run will therefore cost. Run it after any snowball/works
# re-fetch, and before starting the pool.
#
#   source("R/report_nli_backlog.R"); nli_backlog_report()
#
# `pairs_per_sec` is per pod -- the measured 33.6 for bge-m3 at batch_size 64
# on one L4 (see input/config.yaml). `n_pods` defaults to the active config's
# own host count so the time estimate tracks the pool actually configured.
nli_backlog_report <- function(
  granularity = "atomic_bm",
  nli_config_name = NULL,
  claim_units_object = "_targets/objects/nli_claim_units_evidence_flat",
  scores_root = "output/nli_scores_evidence",
  config_file = "input/config.yaml",
  pairs_per_sec = 33.6,
  n_pods = NULL,
  top_n = 10L
) {
  cfg_all <- yaml::read_yaml(config_file)[["nli"]]

  # Resolve the config that actually PRODUCED this granularity, not whichever
  # one nli.active currently points at -- same reasoning as
  # nli_config_for_granularity() in R/branch_helpers.R.
  if (is.null(nli_config_name)) {
    nli_config_name <- unname(nli_config_for_granularity(
      cfg_all[["configs"]], granularity, cfg_all[["active"]]
    ))
  }
  if (is.null(n_pods)) {
    n_pods <- max(1L, length(unlist(cfg_all[["configs"]][[nli_config_name]][["host"]])))
  }

  units <- readRDS(claim_units_object)
  root <- file.path(
    scores_root, paste0("granularity=", granularity),
    paste0("nli_config=", nli_config_name)
  )

  enum <- dplyr::tibble(
    assessment = vapply(units, `[[`, character(1), "assessment"),
    km         = vapply(units, `[[`, character(1), "km"),
    bm         = vapply(units, `[[`, character(1), "bm"),
    claim_id   = vapply(units, `[[`, character(1), "claim_id"),
    n_enum     = vapply(units, function(u) as.numeric(u$n_pairs), numeric(1))
  )

  # An assessment with no scored output at all simply has no directory yet;
  # that is "nothing scored", not an error.
  scored <- if (dir.exists(root)) {
    dplyr::bind_rows(lapply(list.files(root), function(a) {
      arrow::open_dataset(file.path(root, a)) |>
        dplyr::count(km, bm, claim_id, name = "n_scored") |>
        dplyr::collect() |>
        dplyr::mutate(assessment = sub("^assessment=", "", a))
    }))
  } else {
    dplyr::tibble(km = character(), bm = character(), claim_id = character(),
                  n_scored = numeric(), assessment = character())
  }

  cmp <- enum |>
    dplyr::left_join(scored, by = c("assessment", "km", "bm", "claim_id")) |>
    dplyr::mutate(
      n_scored = dplyr::coalesce(as.numeric(n_scored), 0),
      n_todo   = pmax(n_enum - n_scored, 0)
    )

  by_assessment <- cmp |>
    dplyr::group_by(assessment) |>
    dplyr::summarise(
      claims           = dplyr::n(),
      claims_untouched = sum(n_scored == 0),
      claims_partial   = sum(n_scored > 0 & n_todo > 0),
      claims_complete  = sum(n_scored > 0 & n_todo == 0),
      scored           = sum(n_scored),
      todo             = sum(n_todo),
      .groups = "drop"
    )

  total_todo <- sum(cmp$n_todo)
  pool_days <- total_todo / (pairs_per_sec * n_pods) / 86400

  message(sprintf(
    "[NLI backlog] granularity=%s nli_config=%s -- %s pair(s) outstanding across %d claim(s); ~%.1f day(s) on %d pod(s)",
    granularity, nli_config_name, format(round(total_todo), big.mark = ","),
    sum(cmp$n_todo > 0), pool_days, n_pods
  ))

  list(
    granularity   = granularity,
    nli_config    = nli_config_name,
    by_assessment = by_assessment,
    by_claim      = dplyr::arrange(cmp, dplyr::desc(n_todo)),
    largest_partial = cmp |>
      dplyr::filter(n_scored > 0, n_todo > 0) |>
      dplyr::arrange(dplyr::desc(n_todo)) |>
      head(top_n),
    total_todo    = total_todo,
    n_pods        = n_pods,
    pool_days     = pool_days
  )
}
