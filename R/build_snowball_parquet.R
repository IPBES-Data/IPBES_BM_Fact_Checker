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

    # Stay in Arrow end-to-end: OpenAlex `nodes` carries list/struct columns
    # (authorships, topics, locations, mesh, ...) that don't round-trip through
    # an R data.frame — `collect() |> write_dataset()` fails with "Degenerated
    # data frame". `mutate()` on a Dataset is lazy and works fine.
    nodes_ds <- arrow::open_dataset(file.path(sb_dir, "nodes")) |>
      dplyr::mutate(assessment = assessment_id, km = km_val, bm = bm_val)

    edges_ds <- arrow::open_dataset(file.path(sb_dir, "edges")) |>
      dplyr::mutate(assessment = assessment_id, km = km_val, bm = bm_val)

    # openalexSnowball >= 0.1.1 no longer emits a standalone keypaper directory;
    # keypapers are inside `nodes` with relation = "keypaper".
    keypaper_ds <- nodes_ds |> dplyr::filter(relation == "keypaper")

    arrow::write_dataset(
      nodes_ds, nodes_root,
      partitioning           = c("assessment", "km", "bm", "relation"),
      existing_data_behavior = "delete_matching"
    )
    arrow::write_dataset(
      edges_ds, edges_root,
      partitioning           = c("assessment", "km", "bm", "edge_type"),
      existing_data_behavior = "delete_matching"
    )
    arrow::write_dataset(
      keypaper_ds, keypaper_root,
      partitioning           = c("assessment", "km", "bm"),
      existing_data_behavior = "delete_matching"
    )

    unlink(sb_dir, recursive = TRUE, force = TRUE)
  }

  c(nodes_assessment_dir, edges_assessment_dir, keypaper_assessment_dir)
}
