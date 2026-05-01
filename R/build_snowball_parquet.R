build_snowball_parquet <- function(assessment, works_path, output_root = "output/snowball") {
  assessment_id <- assessment$id
  nodes_root    <- file.path(output_root, "nodes")
  edges_root    <- file.path(output_root, "edges")
  keypaper_root <- file.path(output_root, "keypaper")

  nodes_assessment_dir    <- file.path(nodes_root,    paste0("assessment=", assessment_id))
  edges_assessment_dir    <- file.path(edges_root,    paste0("assessment=", assessment_id))
  keypaper_assessment_dir <- file.path(keypaper_root, paste0("assessment=", assessment_id))

  unlink(nodes_assessment_dir,    recursive = TRUE, force = TRUE)
  unlink(edges_assessment_dir,    recursive = TRUE, force = TRUE)
  unlink(keypaper_assessment_dir, recursive = TRUE, force = TRUE)
  dir.create(nodes_root,    showWarnings = FALSE, recursive = TRUE)
  dir.create(edges_root,    showWarnings = FALSE, recursive = TRUE)
  dir.create(keypaper_root, showWarnings = FALSE, recursive = TRUE)

  works <- arrow::open_dataset(works_path) |>
    dplyr::select(km, bm, id) |>
    dplyr::collect() |>
    dplyr::mutate(w_id = sub("^https://openalex\\.org/", "", id))

  km_bm_groups <- dplyr::distinct(works, km, bm)

  for (i in seq_len(nrow(km_bm_groups))) {
    km_val <- km_bm_groups$km[[i]]
    bm_val <- km_bm_groups$bm[[i]]
    ids <- unique(works$w_id[works$km == km_val & works$bm == bm_val])
    if (!length(ids)) next

    message("Snowball [", assessment_id, " / ", km_val, " / ", bm_val,
            "]: ", length(ids), " seeds")

    sb_dir <- openalexSnowball::pro_snowball(
      identifier = ids,
      output     = tempfile(fileext = ".snowball"),
      verbose    = FALSE
    )

    nodes <- arrow::open_dataset(file.path(sb_dir, "nodes")) |>
      dplyr::collect() |>
      dplyr::mutate(assessment = assessment_id, km = km_val, bm = bm_val)

    edges <- arrow::open_dataset(file.path(sb_dir, "edges")) |>
      dplyr::collect() |>
      dplyr::mutate(assessment = assessment_id, km = km_val, bm = bm_val)

    keypaper <- arrow::open_dataset(file.path(sb_dir, "keypaper")) |>
      dplyr::collect() |>
      dplyr::mutate(assessment = assessment_id, km = km_val, bm = bm_val)

    arrow::write_dataset(
      nodes, nodes_root,
      partitioning           = c("assessment", "km", "bm", "relation"),
      existing_data_behavior = "delete_matching"
    )
    arrow::write_dataset(
      edges, edges_root,
      partitioning           = c("assessment", "km", "bm", "edge_type"),
      existing_data_behavior = "delete_matching"
    )
    arrow::write_dataset(
      keypaper, keypaper_root,
      partitioning           = c("assessment", "km", "bm"),
      existing_data_behavior = "delete_matching"
    )

    unlink(sb_dir, recursive = TRUE, force = TRUE)
  }

  c(nodes_assessment_dir, edges_assessment_dir, keypaper_assessment_dir)
}
