build_works_citing_parquet <- function(assessment, snowball_path,
                                       output_root = "output/works_citing") {
  assessment_id <- assessment$id
  output_path   <- file.path(output_root, paste0("assessment=", assessment_id))

  unlink(output_path, recursive = TRUE, force = TRUE)
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)
  dir.create(output_root, showWarnings = FALSE, recursive = TRUE)

  nodes_root <- dirname(snowball_path[grepl("nodes", snowball_path)])
  assessment_dir <- file.path(nodes_root, paste0("assessment=", assessment_id))

  # Each km/bm went through a separate `pro_snowball` call which infers its
  # own schema, so columns can be VARCHAR in one batch and STRUCT in another.
  # Neither Arrow nor DuckDB's union_by_name can unify those types across
  # batches — but within a single km/bm relation=citing file the schema is
  # internally consistent. Copy file-by-file.
  km_dirs <- list.dirs(assessment_dir, recursive = FALSE)

  for (km_dir in km_dirs) {
    km_val <- sub("^km=", "", basename(km_dir))
    bm_dirs <- list.dirs(km_dir, recursive = FALSE)
    for (bm_dir in bm_dirs) {
      bm_val <- sub("^bm=", "", basename(bm_dir))
      citing_files <- list.files(
        file.path(bm_dir, "relation=citing"),
        pattern = "\\.parquet$",
        full.names = TRUE
      )
      if (!length(citing_files)) next

      dest_dir <- file.path(
        output_root,
        paste0("assessment=", assessment_id),
        paste0("km=", km_val),
        paste0("bm=", bm_val)
      )
      dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
      file.copy(citing_files, dest_dir, overwrite = TRUE)
    }
  }

  output_path
}
