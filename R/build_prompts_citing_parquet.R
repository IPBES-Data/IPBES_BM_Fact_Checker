build_prompts_citing_parquet <- function(
  assessment,
  works_citing_parquet,
  citing_prompt_file,
  output_root = "output/prompts/citing"
) {
  assessment_id <- assessment$id
  output_path <- branch_output_dir(output_root, assessment_id)

  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

  template <- load_text_file(citing_prompt_file)

  # works_citing_parquet is `output/works_citing/assessment=<id>` (per-branch).
  # Schemas can differ across km/bm parquet files, so iterate file-by-file.
  km_dirs <- list.dirs(works_citing_parquet, recursive = FALSE)

  scalar_cols <- c("id", "doi", "title", "abstract", "publication_year")

  rows_acc <- list()

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
            assessment      = assessment_id,
            km              = km_val,
            bm              = bm_val,
            relation        = "citing"
          )
      })
      partition <- dplyr::bind_rows(partition_rows)

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

      partition$prompt <- vapply(
        seq_len(nrow(partition)),
        function(i) {
          row <- partition[i, , drop = FALSE]
          render_template(
            template,
            list(
              ASSESSMENT_ID          = assessment_id,
              KM_ID                  = km_val,
              BM_ID                  = bm_val,
              WORK_ID                = na_to_blank(row$work_id),
              WORK_DOI               = na_to_blank(row$doi),
              WORK_PUBLICATION_YEAR  = na_to_blank(row$publication_year),
              WORK_TITLE             = na_to_blank(row$title),
              WORK_ABSTRACT          = na_to_blank(row$abstract),
              WORK_RELATION          = "citing"
            )
          )
        },
        character(1)
      )

      rows_acc[[length(rows_acc) + 1L]] <- partition
    }
  }

  if (!length(rows_acc)) {
    return(output_path)
  }

  out <- dplyr::bind_rows(rows_acc) |>
    dplyr::select(
      assessment, km, bm,
      work_id, doi, title, abstract, publication_year, relation,
      prompt
    )

  arrow::write_dataset(
    dataset = out,
    path = output_root,
    format = "parquet",
    partitioning = c("assessment", "km", "bm"),
    existing_data_behavior = "delete_matching"
  )

  output_path
}
