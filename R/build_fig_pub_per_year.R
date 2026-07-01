# Number of new publications per year, grouped by background message, among
# papers CITING the key papers (the forward/discovery direction of the
# snowball search). Reads works_citing_parquet directly — relation == "citing"
# is already the forward direction, so no further filtering is needed.
#
# works_citing_path arrives as a vector — one directory per assessment branch
# (works_citing_parquet is pattern = map(assessment, ...) upstream, consumed
# here without a pattern, so targets aggregates all branches into one vector).
# Each element's own root is "assessment=<id>", which Arrow does NOT surface
# as a column when it's the dataset's own root (only discovered subdirectories
# below it are) — so `assessment` is parsed back out of the path per element.
build_fig_pub_per_year <- function(works_citing_path, output_root = "output/figures") {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  figname <- file.path(output_root, "fig_pub_per_year")

  counts <- dplyr::bind_rows(lapply(works_citing_path, function(p) {
    assessment_id <- sub("^assessment=", "", basename(p))
    arrow::open_dataset(p) |>
      dplyr::filter(!is.na(publication_year)) |>
      dplyr::count(km, bm, publication_year) |>
      dplyr::collect() |>
      dplyr::mutate(assessment = assessment_id)
  })) |>
    dplyr::arrange(assessment, bm, publication_year)

  fig <- counts |>
    ggplot2::ggplot(ggplot2::aes(
      x = publication_year, y = n, group = bm, color = bm
    )) +
    ggplot2::geom_line() +
    ggplot2::geom_point() +
    ggplot2::geom_vline(xintercept = 2019, linetype = "dashed") +
    ggplot2::facet_wrap(~assessment, ncol = 1) +
    ggplot2::theme_minimal() +
    ggplot2::labs(
      title = "Number of New Citing Publications per Year by Background Message",
      x = "Publication Year",
      y = "Number of Publications",
      color = "Background Message"
    ) +
    ggplot2::theme(legend.position = "bottom", legend.title = ggplot2::element_blank()) +
    ggplot2::xlim(2000, 2025) +
    ggplot2::scale_y_log10()

  paths <- paste0(figname, c(".png", ".pdf", ".svg"))
  for (p in paths) {
    ggplot2::ggsave(filename = p, plot = fig, width = 10, height = 20)
  }
  paths
}
