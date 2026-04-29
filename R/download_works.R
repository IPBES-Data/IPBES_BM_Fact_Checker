download_works <- function(
  assessment,
  zotero_path,
  output_root = "output/works",
  workers = 8
) {
  output_path <- branch_output_dir(output_root, assessment$id)
  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

  dois <- arrow::open_dataset(zotero_path) |>
    dplyr::select(doi) |>
    dplyr::filter(!is.na(doi)) |>
    dplyr::collect() |>
    dplyr::pull(doi) |>
    openalexPro::extract_doi(non_doi_value = "", normalize = TRUE, what = "doi")
  dois <- unique(dois[nzchar(dois)])

  if (!length(dois)) {
    stop("No DOIs found for assessment ", assessment$id)
  }
  message("Querying OpenAlex for ", length(dois), " DOIs [", assessment$id, "]")

  query_url <- openalexPro::pro_query(
    entity = "works",
    doi = dois
  )

  parquet_dir <- openalexPro::pro_fetch(
    query_url = query_url,
    project_folder = output_path,
    overwrite = TRUE,
    workers = workers,
    verbose = FALSE,
    progress = TRUE
  )

  if (!length(list.files(parquet_dir, pattern = "\\.parquet$", recursive = TRUE))) {
    stop("pro_fetch wrote no parquet files for ", assessment$id)
  }

  unlink(file.path(output_path, "json"),  recursive = TRUE, force = TRUE)
  unlink(file.path(output_path, "jsonl"), recursive = TRUE, force = TRUE)

  for (item in list.files(parquet_dir, full.names = TRUE)) {
    file.rename(item, file.path(output_path, basename(item)))
  }
  unlink(parquet_dir, recursive = TRUE, force = TRUE)

  output_path
}
