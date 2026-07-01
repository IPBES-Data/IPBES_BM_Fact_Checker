# Derived summary tables for one assessment's NLI scores (label distribution,
# confidence, alignment), consumed by build_nli_overview_figures() and by
# IPBES_Fact_Checker.qmd's "NLI Alignment Scores" section. Reads the whole
# per-assessment nli_scores_parquet branch once and caches every summary
# table needed downstream in a single rds, so neither the figures target nor
# the report re-collect() the (potentially large) raw dataset repeatedly.
build_nli_overview_data <- function(
  assessment,
  nli_scores_path,
  nli_active,
  output_root = "output/tables"
) {
  assessment_id <- assessment$id
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  fn <- file.path(output_root, paste0("nli_overview_data_", assessment_id, ".rds"))

  # Not every assessment has been scored yet (e.g. no host pool has run for
  # it) — treat a missing directory the same as an empty dataset rather than
  # erroring, so one un-scored assessment doesn't break the whole target.
  if (!dir.exists(nli_scores_path)) {
    saveRDS(
      list(assessment = assessment_id, nli_active = nli_active, empty = TRUE),
      file = fn
    )
    return(fn)
  }

  d <- arrow::open_dataset(nli_scores_path) |>
    dplyr::select(km, bm, label, p_supports, p_refutes, confidence, uncertain) |>
    dplyr::mutate(alignment = p_supports - p_refutes) |>
    dplyr::collect()

  if (!nrow(d)) {
    saveRDS(
      list(assessment = assessment_id, nli_active = nli_active, empty = TRUE),
      file = fn
    )
    return(fn)
  }

  label_levels <- c("SUPPORTS", "NOT_ENOUGH_INFO", "REFUTES")

  label_overall <- d |>
    dplyr::count(label) |>
    dplyr::mutate(pct = round(100 * n / sum(n), 1))

  label_km <- d |>
    dplyr::count(km, label) |>
    dplyr::group_by(km) |>
    dplyr::mutate(pct = round(100 * n / sum(n), 1)) |>
    dplyr::ungroup() |>
    dplyr::select(km, label, pct) |>
    tidyr::pivot_wider(names_from = label, values_from = pct, values_fill = 0) |>
    dplyr::select(km, dplyr::any_of(label_levels)) |>
    dplyr::arrange(km)

  table_bm <- d |>
    dplyr::count(km, bm, label) |>
    dplyr::group_by(km, bm) |>
    dplyr::mutate(pct = round(100 * n / sum(n), 1)) |>
    dplyr::ungroup() |>
    dplyr::select(km, bm, label, pct) |>
    tidyr::pivot_wider(names_from = label, values_from = pct, values_fill = 0) |>
    dplyr::select(km, bm, dplyr::any_of(label_levels)) |>
    dplyr::arrange(km, bm)

  conf_table <- d |>
    dplyr::group_by(label) |>
    dplyr::summarise(
      n = dplyr::n(),
      mean = round(mean(confidence, na.rm = TRUE), 3),
      median = round(stats::median(confidence, na.rm = TRUE), 3),
      p25 = round(stats::quantile(confidence, 0.25, na.rm = TRUE), 3),
      p75 = round(stats::quantile(confidence, 0.75, na.rm = TRUE), 3),
      .groups = "drop"
    ) |>
    dplyr::arrange(factor(label, levels = label_levels))

  align_table <- d |>
    dplyr::group_by(km, bm) |>
    dplyr::summarise(
      n = dplyr::n(),
      mean_aln = round(mean(alignment, na.rm = TRUE), 3),
      sd_aln = round(stats::sd(alignment, na.rm = TRUE), 3),
      pct_supp = round(100 * mean(label == "SUPPORTS"), 1),
      pct_ref = round(100 * mean(label == "REFUTES"), 1),
      pct_nei = round(100 * mean(label == "NOT_ENOUGH_INFO"), 1),
      pct_unc = round(100 * mean(uncertain), 1),
      .groups = "drop"
    ) |>
    dplyr::arrange(km, bm)

  saveRDS(
    list(
      assessment    = assessment_id,
      nli_active    = nli_active,
      empty         = FALSE,
      n_total       = nrow(d),
      n_bm          = dplyr::n_distinct(d$bm),
      n_km          = dplyr::n_distinct(d$km),
      pct_unc       = round(100 * mean(d$uncertain), 1),
      label_overall = label_overall,
      label_km      = label_km,
      table_bm      = table_bm,
      conf_table    = conf_table,
      align_table   = align_table,
      # Trimmed raw rows — only what plot-conf/plot-aln's density plots need.
      raw           = d |> dplyr::select(km, bm, label, confidence, alignment)
    ),
    file = fn
  )

  fn
}
