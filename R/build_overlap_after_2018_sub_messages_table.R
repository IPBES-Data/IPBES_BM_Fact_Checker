# Overlap table: citing papers (works_citing_parquet) published after
# `cutoff_year`, referenced from more than 5 background messages. Named
# "sub_messages" for continuity with the legacy report; the active pipeline
# has no sub-message level, so this and the background-message variant group
# identically (by km/bm) — kept as a separate target only for report-section
# continuity, not because the two computations differ.
#
# works_citing_path arrives as a vector — one directory per assessment branch
# (works_citing_parquet is pattern = map(assessment, ...) upstream).
#
# No `author` column here: works_citing's `authorships` struct column has
# inconsistent nested schemas across different (km, bm) batches within the
# same assessment (each pro_snowball() call infers its own schema — see
# build_snowball_parquet.R), so collecting it across batches errors ("Some
# attributes are incompatible" from vctrs). works_parquet doesn't have this
# problem (one pro_fetch() call per assessment), which is why
# overlap_key_paper_table can safely include an author column.
build_overlap_after_2018_sub_messages_table <- function(
  works_citing_path,
  cutoff_year = 2018,
  output_root = "output/tables"
) {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  fn_rds  <- file.path(output_root, "overlap_after_2018_sub_messages.rds")
  fn_html <- file.path(output_root, "overlap_after_2018_sub_messages.html")

  works_citing <- dplyr::bind_rows(lapply(works_citing_path, function(p) {
    arrow::open_dataset(p) |>
      dplyr::select(id, doi, title, km, bm, publication_year) |>
      dplyr::filter(!is.na(id), publication_year > cutoff_year) |>
      dplyr::collect()
  }))

  after_2018_overlap <- works_citing |>
    dplyr::mutate(bm_group = paste(km, bm, sep = "/")) |>
    dplyr::select(id, doi, title, bm_group) |>
    dplyr::distinct() |>
    dplyr::summarise(
      n     = dplyr::n(),
      doi   = dplyr::first(doi),
      title = dplyr::first(title),
      sms   = list(bm_group),
      .by   = id
    ) |>
    dplyr::filter(n > 5) |>
    dplyr::arrange(dplyr::desc(n)) |>
    dplyr::mutate(
      id_short  = sub("^https://openalex\\.org/", "", id),
      doi_short = sub("^https://doi\\.org/", "", doi),
      id  = paste0('<a href="https://openalex.org/', id_short, '" target="_blank">', id_short, "</a>"),
      doi = paste0('<a href="https://doi.org/', doi_short, '" target="_blank">', doi_short, "</a>")
    ) |>
    dplyr::select(n, id, title, doi, sms)

  saveRDS(after_2018_overlap, file = fn_rds)

  after_2018_overlap |>
    IPBES.R::table_dt(fixedColumns = list(leftColumns = 2)) |>
    htmlwidgets::saveWidget(file = fn_html, selfcontained = TRUE)

  c(fn_rds, fn_html)
}
