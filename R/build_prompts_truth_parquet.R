build_prompts_truth_parquet <- function(
  assessment,
  key_messages_parquet,
  sections_parquet,
  truth_prompt_file,
  output_root = "output/prompts/truth"
) {
  assessment_id <- assessment$id
  output_path <- branch_output_dir(output_root, assessment_id)

  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, recursive = TRUE, showWarnings = FALSE)

  template <- load_text_file(truth_prompt_file)

  km_root <- unique(dirname(key_messages_parquet))[[1L]]
  sec_root <- unique(dirname(sections_parquet))[[1L]]

  km_raw <- arrow::open_dataset(km_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::collect()

  km_bm <- km_raw |>
    dplyr::select(
      km, km_label, km_description,
      bm, bm_label, bm_description,
      bm_well_established, bm_established_incomplete
    ) |>
    dplyr::distinct()

  sm_text <- km_raw |>
    dplyr::select(km, bm, sm_id, sm_description) |>
    dplyr::distinct() |>
    dplyr::filter(!is.na(sm_id) | !is.na(sm_description)) |>
    dplyr::mutate(
      sm_line = paste0(
        "- ",
        ifelse(is.na(sm_id), "", paste0(sm_id, ": ")),
        ifelse(is.na(sm_description), "", sm_description)
      )
    ) |>
    dplyr::group_by(km, bm) |>
    dplyr::summarise(
      sm_descriptions = paste(sm_line, collapse = "\n"),
      .groups = "drop"
    )

  section_text <- arrow::open_dataset(sec_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, bm, section, subsection, content) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::filter(!is.na(content) & nzchar(content)) |>
    dplyr::mutate(
      block = paste0(
        "### ",
        ifelse(is.na(subsection), "(section)", subsection),
        if_else_section_label(section),
        "\n\n",
        content
      )
    ) |>
    dplyr::group_by(km, bm) |>
    dplyr::summarise(
      section_content = paste(block, collapse = "\n\n"),
      .groups = "drop"
    )

  joined <- km_bm |>
    dplyr::left_join(sm_text, by = c("km", "bm")) |>
    dplyr::left_join(section_text, by = c("km", "bm"))

  prompts <- vapply(
    seq_len(nrow(joined)),
    function(i) {
      row <- joined[i, , drop = FALSE]
      render_template(
        template,
        list(
          ASSESSMENT_ID             = assessment_id,
          KM_ID                     = na_to_blank(row$km),
          KM_LABEL                  = na_to_blank(row$km_label),
          KM_DESCRIPTION            = na_to_blank(row$km_description),
          BM_ID                     = na_to_blank(row$bm),
          BM_LABEL                  = na_to_blank(row$bm_label),
          BM_DESCRIPTION            = na_to_blank(row$bm_description),
          BM_WELL_ESTABLISHED       = na_to_blank(row$bm_well_established),
          BM_ESTABLISHED_INCOMPLETE = na_to_blank(row$bm_established_incomplete),
          SM_DESCRIPTIONS           = na_to_blank(row$sm_descriptions),
          SECTION_CONTENT           = na_to_blank(row$section_content)
        )
      )
    },
    character(1)
  )

  out <- joined |>
    dplyr::mutate(
      assessment = assessment_id,
      prompt     = prompts
    )

  arrow::write_dataset(
    dataset = out,
    path = output_root,
    format = "parquet",
    partitioning = c("assessment"),
    existing_data_behavior = "delete_matching"
  )

  output_path
}

# Tiny helpers — kept local because they don't fit cleanly anywhere else and
# aren't reused outside the truth-prompt builder.

na_to_blank <- function(x) {
  x <- as.character(x)
  ifelse(is.na(x), "", x)
}

if_else_section_label <- function(section) {
  ifelse(is.na(section) | !nzchar(section), "", paste0(" (section ", section, ")"))
}
