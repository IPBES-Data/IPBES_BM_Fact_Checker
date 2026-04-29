assessment_ids <- function(config) {
  vapply(config$assessments, `[[`, character(1), "id")
}

assessment_index <- function(config, assessment_id) {
  ids <- assessment_ids(config)
  idx <- match(assessment_id, ids)
  if (is.na(idx)) {
    stop("Unknown assessment id: ", assessment_id)
  }
  idx
}

branch_output_dir <- function(output_root, assessment_id) {
  file.path(output_root, paste0("assessment=", assessment_id))
}
