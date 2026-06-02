# Build per-(KM, BM) truth prompts as structured JSON.
#
# Each row covers one (assessment, KM, BM) pair. The row carries flat metadata
# at KM/BM level plus a nested `sub_messages` list-column (one entry per SM
# under the BM); each SM has its own `sources` list-column of (section,
# subsection, content) rows pulled from the sections parquet via the new `sm`
# linkage.
#
# Why JSON for the prompt string: SubChapter content contains literal `#`
# characters and other markdown-collision artefacts. Wrapping in markdown
# breaks the outer structure; JSON treats each source as opaque text. Source
# cleaning is intentionally out of scope here.

build_prompts_truth_parquet <- function(
  assessment,
  key_messages_parquet,
  sections_parquet,
  output_root = "output/prompts/truth"
) {
  assessment_id <- assessment$id
  output_path <- branch_output_dir(output_root, assessment_id)

  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, recursive = TRUE, showWarnings = FALSE)

  km_root  <- unique(dirname(key_messages_parquet))[[1L]]
  sec_root <- unique(dirname(sections_parquet))[[1L]]

  km_raw <- arrow::open_dataset(km_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::collect()

  sec_raw <- arrow::open_dataset(sec_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, bm, sm, section, subsection, content) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::mutate(content = trimws(na_to_blank(content))) |>
    dplyr::filter(nzchar(content))

  km_bm <- km_raw |>
    dplyr::select(
      km, km_label, km_description,
      bm, bm_label, bm_description,
      bm_well_established, bm_established_incomplete
    ) |>
    dplyr::distinct() |>
    dplyr::arrange(km, bm)

  sm_meta <- km_raw |>
    dplyr::select(
      km, bm, sm_id, sm_description,
      sm_well_established, sm_established_incomplete
    ) |>
    dplyr::distinct() |>
    dplyr::filter(!is.na(sm_id))

  # Build per-(km, bm) nested sub_messages structures and the matching JSON.
  build_one <- function(i) {
    bm_row <- km_bm[i, , drop = FALSE]
    sm_rows <- sm_meta |>
      dplyr::filter(km == bm_row$km, bm == bm_row$bm) |>
      dplyr::arrange(sm_id)

    sources_for <- function(sm_value) {
      sec_raw |>
        dplyr::filter(km == bm_row$km, bm == bm_row$bm, sm == sm_value) |>
        dplyr::select(section, subsection, content) |>
        dplyr::arrange(section, subsection)
    }

    sub_messages <- if (nrow(sm_rows)) {
      sm_rows |>
        dplyr::mutate(
          sources = lapply(sm_id, sources_for)
        ) |>
        dplyr::select(
          sm_id, sm_description,
          sm_well_established, sm_established_incomplete,
          sources
        )
    } else {
      dplyr::tibble(
        sm_id                     = character(0),
        sm_description            = character(0),
        sm_well_established       = character(0),
        sm_established_incomplete = character(0),
        sources                   = list()
      )
    }

    payload <- list(
      assessment                = assessment_id,
      km                        = bm_row$km,
      km_label                  = na_to_null(bm_row$km_label),
      km_description            = na_to_null(bm_row$km_description),
      bm                        = bm_row$bm,
      bm_label                  = na_to_null(bm_row$bm_label),
      bm_description            = na_to_null(bm_row$bm_description),
      bm_well_established       = na_to_null(bm_row$bm_well_established),
      bm_established_incomplete = na_to_null(bm_row$bm_established_incomplete),
      sub_messages              = lapply(seq_len(nrow(sub_messages)), function(j) {
        sm <- sub_messages[j, , drop = FALSE]
        list(
          sm_id                     = sm$sm_id,
          sm_description            = na_to_null(sm$sm_description),
          sm_well_established       = na_to_null(sm$sm_well_established),
          sm_established_incomplete = na_to_null(sm$sm_established_incomplete),
          sources                   = lapply(seq_len(nrow(sm$sources[[1]])), function(k) {
            s <- sm$sources[[1]][k, , drop = FALSE]
            list(
              section    = na_to_null(s$section),
              subsection = na_to_null(s$subsection),
              content    = s$content
            )
          })
        )
      })
    )

    prompt <- jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null", na = "null")

    list(sub_messages = sub_messages, prompt = as.character(prompt))
  }

  built <- lapply(seq_len(nrow(km_bm)), build_one)

  out <- km_bm |>
    dplyr::mutate(
      assessment   = assessment_id,
      sub_messages = lapply(built, `[[`, "sub_messages"),
      prompt       = vapply(built, `[[`, character(1), "prompt")
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

# Small helpers — local because they only fit this builder.

na_to_blank <- function(x) {
  x <- as.character(x)
  ifelse(is.na(x), "", x)
}

# Used for JSON payloads: NA should serialize to `null`, not "" or "NA".
na_to_null <- function(x) {
  if (length(x) != 1L) return(x)
  if (is.na(x)) NULL else as.character(x)
}
