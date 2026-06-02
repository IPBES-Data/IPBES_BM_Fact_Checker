build_prompts_citing_parquet <- function(
  assessment,
  works_citing_parquet,
  output_root = "output/prompts/citing"
) {
  assessment_id <- assessment$id
  output_path <- branch_output_dir(output_root, assessment_id)

  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

  # works_citing_parquet is `output/works_citing/assessment=<id>` (per-branch).
  # Schemas can differ across km/bm parquet files, so iterate file-by-file.
  # We also write each (km, bm) partition as soon as it's built — keeping only
  # one partition in memory at a time, instead of accumulating the whole
  # assessment (~hundreds of MB to GB for the larger assessments).
  km_dirs <- list.dirs(works_citing_parquet, recursive = FALSE)
  scalar_cols <- c("id", "doi", "title", "abstract", "publication_year")
  wrote_any <- FALSE

  for (km_dir in km_dirs) {
    km_val <- sub("^km=", "", basename(km_dir))
    bm_dirs <- list.dirs(km_dir, recursive = FALSE)
    for (bm_dir in bm_dirs) {
      bm_val <- sub("^bm=", "", basename(bm_dir))
      files <- list.files(bm_dir, pattern = "\\.parquet$", full.names = TRUE)
      if (!length(files)) next

      partition_rows <- lapply(files, function(f) {
        works <- arrow::read_parquet(f)
        works |>
          dplyr::select(dplyr::any_of(scalar_cols)) |>
          dplyr::mutate(
            assessment = assessment_id,
            km         = km_val,
            bm         = bm_val,
            relation   = "citing"
          )
      })
      partition <- dplyr::bind_rows(partition_rows)
      rm(partition_rows)

      if (!nrow(partition)) next

      missing_cols <- setdiff(scalar_cols, names(partition))
      for (mc in missing_cols) partition[[mc]] <- NA_character_

      partition <- partition |>
        dplyr::mutate(
          dplyr::across(
            dplyr::any_of(c("id", "doi", "title", "abstract")),
            as.character
          ),
          publication_year = suppressWarnings(as.integer(publication_year))
        ) |>
        dplyr::rename(work_id = id)

      # JSON payload per row. The `prompt` column is the LLM-facing string;
      # the scalar columns alongside it stay for slicing without re-parsing.
      partition$prompt <- vapply(
        seq_len(nrow(partition)),
        function(i) {
          row <- partition[i, , drop = FALSE]
          payload <- list(
            assessment       = assessment_id,
            km               = km_val,
            bm               = bm_val,
            work_id          = na_to_null(row$work_id),
            doi              = na_to_null(row$doi),
            publication_year = if (is.na(row$publication_year)) NULL else as.integer(row$publication_year),
            relation         = "citing",
            title            = na_to_null(row$title),
            abstract         = na_to_null(row$abstract)
          )
          as.character(jsonlite::toJSON(
            payload, auto_unbox = TRUE, null = "null", na = "null"
          ))
        },
        character(1)
      )

      partition <- partition |>
        dplyr::select(
          assessment, km, bm,
          work_id, doi, title, abstract, publication_year, relation,
          prompt
        )

      # The branch dir was unlinked at the start, so no collisions are expected.
      # `overwrite` is the cheapest option for arrow (no pre-scan to identify
      # matching files like `delete_matching` does).
      arrow::write_dataset(
        dataset = partition,
        path = output_root,
        format = "parquet",
        partitioning = c("assessment", "km", "bm"),
        existing_data_behavior = "overwrite"
      )
      wrote_any <- TRUE
      rm(partition)
    }
  }

  if (!wrote_any) {
    return(output_path)
  }

  output_path
}
