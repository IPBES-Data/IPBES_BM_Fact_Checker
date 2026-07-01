# Overlap table: key/seed papers (works_parquet) referenced in more than one
# background message. works_parquet has one row per (paper, km, bm)
# combination (a paper cited in N BMs appears N times, via a many-to-many
# join against refs), so grouping by id and counting distinct km/bm pairs
# directly gives the overlap count — no snowball data needed.
#
# works_path arrives as a vector — one directory per assessment branch
# (works_parquet is pattern = map(assessment, ...) upstream).
build_overlap_key_paper_table <- function(works_path, output_root = "output/tables") {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  fn_rds  <- file.path(output_root, "overlap_key_paper.rds")
  fn_html <- file.path(output_root, "overlap_key_paper.html")

  works <- dplyr::bind_rows(lapply(works_path, function(p) {
    arrow::open_dataset(p) |>
      dplyr::select(id, doi, title, authorships, km, bm) |>
      dplyr::filter(!is.na(id)) |>
      dplyr::collect()
  }))

  first_author_et_al <- function(a) {
    if (is.null(a) || !nrow(a)) {
      return(NA_character_)
    }
    first_author <- a$author$display_name[[1]]
    if (nrow(a) > 1) paste(first_author, "et al.") else first_author
  }

  overlap_keypapers <- works |>
    dplyr::mutate(
      author   = vapply(authorships, first_author_et_al, character(1)),
      bm_group = paste(km, bm, sep = "/")
    ) |>
    dplyr::select(id, doi, title, author, bm_group) |>
    dplyr::distinct() |>
    dplyr::summarise(
      n     = dplyr::n(),
      doi   = dplyr::first(doi),
      title = dplyr::first(title),
      author = dplyr::first(author),
      bms   = list(bm_group),
      .by   = id
    ) |>
    dplyr::filter(n > 1) |>
    dplyr::arrange(dplyr::desc(n)) |>
    dplyr::mutate(
      id_short  = sub("^https://openalex\\.org/", "", id),
      doi_short = sub("^https://doi\\.org/", "", doi),
      id  = paste0('<a href="https://openalex.org/', id_short, '" target="_blank">', id_short, "</a>"),
      doi = paste0('<a href="https://doi.org/', doi_short, '" target="_blank">', doi_short, "</a>")
    ) |>
    dplyr::select(n, id, author, title, doi, bms)

  saveRDS(overlap_keypapers, file = fn_rds)

  overlap_keypapers |>
    IPBES.R::table_dt(fixedColumns = list(leftColumns = 2)) |>
    htmlwidgets::saveWidget(file = fn_html, selfcontained = TRUE)

  c(fn_rds, fn_html)
}
