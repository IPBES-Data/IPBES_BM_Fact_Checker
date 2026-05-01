download_works <- function(
  assessment,
  zotero_path,
  refs_path,
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

  works_raw <- arrow::open_dataset(parquet_dir) |>
    dplyr::collect() |>
    dplyr::mutate(doi_norm = stringr::str_to_lower(doi))

  refs_km_bm <- arrow::open_dataset(refs_path) |>
    dplyr::select(km, bm, doi) |>
    dplyr::filter(!is.na(doi)) |>
    dplyr::collect() |>
    dplyr::mutate(doi_norm = stringr::str_to_lower(doi)) |>
    dplyr::select(km, bm, doi_norm) |>
    dplyr::distinct()

  assessment_id <- assessment$id
  works_with_km_bm <- works_raw |>
    dplyr::inner_join(refs_km_bm, by = "doi_norm", relationship = "many-to-many") |>
    dplyr::select(-doi_norm) |>
    dplyr::mutate(assessment = assessment_id)

  unlink(file.path(output_path, "json"),  recursive = TRUE, force = TRUE)
  unlink(file.path(output_path, "jsonl"), recursive = TRUE, force = TRUE)
  unlink(parquet_dir, recursive = TRUE, force = TRUE)

  arrow::write_dataset(
    dataset = works_with_km_bm,
    path = output_path,
    format = "parquet",
    partitioning = c("assessment", "km", "bm"),
    existing_data_behavior = "delete_matching"
  )

  output_path
}
