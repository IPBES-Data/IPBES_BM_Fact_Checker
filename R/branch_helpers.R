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

sanitize_partition_value <- function(x) {
  x <- as.character(x)
  x <- gsub("[/\\\\]+", "__", x)
  x <- gsub("[^A-Za-z0-9._-]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  ifelse(nzchar(x), x, "unknown")
}

alignement_branch_dir <- function(output_root, assessment_id, run_id) {
  file.path(
    output_root,
    paste0("assessment=", sanitize_partition_value(assessment_id)),
    paste0("run_id=", sanitize_partition_value(run_id))
  )
}
