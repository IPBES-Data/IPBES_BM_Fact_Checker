# Figures for one assessment's NLI overview (label split overall/per-KM/
# per-BM, confidence density, alignment density). Reads the rds produced by
# build_nli_overview_data() rather than re-collecting the raw parquet.
build_nli_overview_figures <- function(nli_overview_data_path, output_root = "output/figures") {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  x <- readRDS(nli_overview_data_path)
  assessment_id <- x$assessment
  stem <- function(name) file.path(output_root, sprintf("nli_overview_%s_%s.png", name, assessment_id))

  if (isTRUE(x$empty)) {
    return(character(0))
  }

  label_levels <- c("SUPPORTS", "NOT_ENOUGH_INFO", "REFUTES")
  label_cols <- c(
    SUPPORTS = "#2E6B4F",
    NOT_ENOUGH_INFO = "#A8896A",
    REFUTES = "#8B2E2E"
  )
  raw <- x$raw |>
    dplyr::mutate(label = factor(label, levels = label_levels))

  paths <- character(0)

  # ── overall label split ──────────────────────────────────────────────────
  fig_overall <- x$label_overall |>
    dplyr::mutate(label = factor(label, levels = label_levels)) |>
    dplyr::arrange(label) |>
    ggplot2::ggplot(ggplot2::aes(x = pct, y = assessment_id, fill = label)) +
    ggplot2::geom_col(width = 0.55) +
    ggplot2::geom_text(
      ggplot2::aes(label = paste0(pct, "%")),
      position = ggplot2::position_stack(vjust = 0.5),
      colour = "white", size = 3.5, fontface = "bold"
    ) +
    ggplot2::scale_fill_manual(values = label_cols) +
    ggplot2::labs(x = NULL, y = NULL, fill = NULL) +
    ggplot2::theme_void(base_size = 11) +
    ggplot2::theme(legend.position = "bottom")
  p <- stem("plot_overall")
  ggplot2::ggsave(p, fig_overall, width = 7, height = 2.2)
  paths <- c(paths, p)

  # ── per-KM label split ───────────────────────────────────────────────────
  fig_km <- raw |>
    dplyr::count(km, label) |>
    dplyr::group_by(km) |>
    dplyr::mutate(pct = 100 * n / sum(n)) |>
    dplyr::ungroup() |>
    ggplot2::ggplot(ggplot2::aes(x = pct, y = km, fill = label)) +
    ggplot2::geom_col(width = 0.65) +
    ggplot2::geom_text(
      ggplot2::aes(label = paste0(round(pct), "%")),
      position = ggplot2::position_stack(vjust = 0.5),
      colour = "white", size = 3.2, fontface = "bold"
    ) +
    ggplot2::scale_fill_manual(values = label_cols) +
    ggplot2::labs(x = "% of citing works", y = NULL, fill = NULL) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.grid.major.y = ggplot2::element_blank(), legend.position = "bottom")
  p <- stem("plot_km")
  ggplot2::ggsave(p, fig_km, width = 7, height = 3)
  paths <- c(paths, p)

  # ── per-BM label split, faceted by KM ────────────────────────────────────
  fig_bm <- raw |>
    dplyr::count(km, bm, label) |>
    dplyr::group_by(km, bm) |>
    dplyr::mutate(pct = 100 * n / sum(n)) |>
    dplyr::ungroup() |>
    dplyr::mutate(bm = factor(bm)) |>
    ggplot2::ggplot(ggplot2::aes(x = bm, y = pct, fill = label)) +
    ggplot2::geom_col(width = 0.8) +
    ggplot2::facet_grid(. ~ km, scales = "free_x", space = "free_x") +
    ggplot2::scale_fill_manual(values = label_cols) +
    ggplot2::labs(x = NULL, y = "% of citing works", fill = NULL) +
    ggplot2::theme_bw(base_size = 10) +
    ggplot2::theme(axis.text.x = ggplot2::element_text(angle = 45, hjust = 1), legend.position = "bottom")
  p <- stem("plot_bm")
  ggplot2::ggsave(p, fig_bm, width = 10, height = 5)
  paths <- c(paths, p)

  # ── confidence density by label ──────────────────────────────────────────
  fig_conf <- ggplot2::ggplot(raw, ggplot2::aes(x = confidence, fill = label, colour = label)) +
    ggplot2::geom_density(alpha = 0.30, linewidth = 0.6) +
    ggplot2::geom_vline(xintercept = 0.60, linetype = "dashed", linewidth = 0.5) +
    ggplot2::scale_fill_manual(values = label_cols) +
    ggplot2::scale_colour_manual(values = label_cols) +
    ggplot2::labs(x = "confidence", y = "density", fill = NULL, colour = NULL) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(legend.position = "bottom")
  p <- stem("plot_conf")
  ggplot2::ggsave(p, fig_conf, width = 7, height = 3.5)
  paths <- c(paths, p)

  # ── alignment density by label ───────────────────────────────────────────
  fig_aln <- ggplot2::ggplot(raw, ggplot2::aes(x = alignment, fill = label, colour = label)) +
    ggplot2::geom_density(alpha = 0.30, linewidth = 0.6) +
    ggplot2::geom_vline(xintercept = 0, linetype = "dashed", linewidth = 0.5) +
    ggplot2::scale_fill_manual(values = label_cols) +
    ggplot2::scale_colour_manual(values = label_cols) +
    ggplot2::labs(
      x = "alignment score (p_supports - p_refutes)", y = "density",
      fill = NULL, colour = NULL
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(legend.position = "bottom")
  p <- stem("plot_aln")
  ggplot2::ggsave(p, fig_aln, width = 7, height = 3.5)
  paths <- c(paths, p)

  paths
}
