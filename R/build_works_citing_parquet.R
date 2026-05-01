build_works_citing_parquet <- function(assessment, snowball_path,
                                       output_root = "output/works_citing") {
  assessment_id <- assessment$id
  output_path   <- file.path(output_root, paste0("assessment=", assessment_id))

  unlink(output_path, recursive = TRUE, force = TRUE)
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

  nodes_root <- dirname(snowball_path[grepl("nodes", snowball_path)])

  citing <- arrow::open_dataset(nodes_root) |>
    dplyr::filter(assessment == assessment_id, relation == "citing") |>
    dplyr::select(-relation) |>
    dplyr::collect()

  if (nrow(citing) > 0L) {
    arrow::write_dataset(
      citing, output_root,
      partitioning           = c("assessment", "km", "bm"),
      existing_data_behavior = "delete_matching"
    )
  }

  output_path
}
