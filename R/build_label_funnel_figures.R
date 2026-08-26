# Figures for one assessment's label funnel (overall 3-level bar, per-BM
# breakdown faceted by KM, and a normalized per-BM variant). Reads the rds
# produced by build_label_funnel_data() rather than re-collecting the raw
# parquet, same convention as build_nli_overview_figures().
build_label_funnel_figures <- function(label_funnel_data_path, output_root = "output/figures") {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  x <- readRDS(label_funnel_data_path)
  assessment_id <- x$assessment
  label_stem <- tolower(x$label)
  gran_suffix <- granularity_suffix(x$granularity %||% "naive_bm")
  model_suffix <- nli_model_suffix(x$nli_active %||% "deberta_zeroshot")
  stem <- function(name) {
    file.path(output_root, sprintf("fig_%s_funnel_%s_%s%s%s.png", label_stem, name, assessment_id, model_suffix, gran_suffix))
  }

  if (isTRUE(x$empty)) {
    return(character(0))
  }

  level_order <- rev(x$funnel_overall$label)

  paths <- character(0)

  # ── overall funnel ───────────────────────────────────────────────────────
  fig_overall <- x$funnel_overall |>
    dplyr::mutate(
      label = factor(label, levels = level_order),
      pct = round(100 * n / n[level == "level1"], 1)
    ) |>
    ggplot2::ggplot(ggplot2::aes(x = n, y = label)) +
    # nli_label_colors (R/branch_helpers.R) keyed by this funnel's own
    # label -- previously hardcoded to the REFUTES color regardless of
    # x$label, so a SUPPORTS funnel report's bar rendered in red too.
    ggplot2::geom_col(fill = nli_label_colors[[x$label]], width = 0.6) +
    ggplot2::geom_text(
      ggplot2::aes(label = sprintf("%s (%s%%)", format(n, big.mark = ","), pct)),
      hjust = -0.05, size = 3.5
    ) +
    ggplot2::scale_x_continuous(expand = ggplot2::expansion(mult = c(0, 0.25))) +
    ggplot2::labs(x = "distinct citing works", y = NULL) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.grid.major.y = ggplot2::element_blank())
  p <- stem("overall")
  ggplot2::ggsave(p, fig_overall, width = 7, height = 2.8)
  paths <- c(paths, p)

  # ── per-BM funnel, faceted by KM ─────────────────────────────────────────
  # pivot_longer's names_to column holds the literal column names ("n1".."n3"),
  # not "level1".."level3" -- the recode map must be keyed the same way.
  level_key <- stats::setNames(x$funnel_overall$label, sub("^level", "n", x$funnel_overall$level))
  by_bm_long <- x$funnel_by_bm |>
    tidyr::pivot_longer(c(n1, n2, n3), names_to = "level", values_to = "n") |>
    dplyr::mutate(
      level = factor(dplyr::recode(level, !!!level_key), levels = x$funnel_overall$label),
      bm = factor(bm)
    )

  fig_by_bm <- by_bm_long |>
    ggplot2::ggplot(ggplot2::aes(x = bm, y = pmax(n, 0.5), fill = level)) +
    ggplot2::geom_col(position = "dodge", width = 0.8) +
    ggplot2::facet_grid(. ~ km, scales = "free_x", space = "free_x") +
    ggplot2::scale_y_log10() +
    ggplot2::scale_fill_brewer(palette = "OrRd") +
    ggplot2::labs(x = NULL, y = "distinct citing works (log scale)", fill = NULL) +
    ggplot2::theme_bw(base_size = 10) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1),
      legend.position = "bottom"
    )
  p <- stem("by_bm")
  ggplot2::ggsave(p, fig_by_bm, width = 10, height = 5)
  paths <- c(paths, p)

  # ── per-BM funnel, normalized so each BM's own corpus (level 1) reads 1 ──
  level1_label <- x$funnel_overall$label[x$funnel_overall$level == "level1"]
  fig_by_bm_norm <- by_bm_long |>
    dplyr::group_by(km, bm) |>
    dplyr::mutate(frac = n / n[level == level1_label]) |>
    dplyr::ungroup() |>
    ggplot2::ggplot(ggplot2::aes(x = bm, y = frac, fill = level)) +
    ggplot2::geom_col(position = "dodge", width = 0.8) +
    ggplot2::geom_hline(yintercept = 1, linetype = "dashed", linewidth = 0.4) +
    ggplot2::facet_grid(. ~ km, scales = "free_x", space = "free_x") +
    ggplot2::scale_y_continuous(limits = c(0, 1), expand = ggplot2::expansion(mult = c(0, 0.05))) +
    ggplot2::scale_fill_brewer(palette = "OrRd") +
    ggplot2::labs(x = NULL, y = "fraction of BM's own snowball corpus", fill = NULL) +
    ggplot2::theme_bw(base_size = 10) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1),
      legend.position = "bottom"
    )
  p <- stem("by_bm_normalized")
  ggplot2::ggsave(p, fig_by_bm_norm, width = 10, height = 5)
  paths <- c(paths, p)

  paths
}
