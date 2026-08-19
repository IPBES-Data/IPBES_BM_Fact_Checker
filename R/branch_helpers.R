assessment_ids <- function(config) {
  vapply(config$assessments, `[[`, character(1), "id")
}

# Per-assessment named-graph IRI. Single point of change if IPBES picks a
# different convention for the shared SPARQL endpoint.
assessment_graph_iri <- function(assessment_id) {
  paste0("http://ontology.ipbes.net/report/", assessment_id)
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

# Filename suffix for the reporting layer's (assessment, granularity)
# outputs: always "_<granularity>", explicit for every value including
# "naive_bm" -- deliberately changed from the original "naive_bm gets no
# suffix" convention (kept in git history) so every granularity's output
# is equally explicit and comparable side by side. This DOES change
# previously-unsuffixed published filenames (e.g.
# IPBES_REFUTES_Report_GA1.html -> ..._naive_bm.html) -- accepted
# knowingly, since regenerating these reports is cheap regardless of which
# granularity is active.
granularity_suffix <- function(granularity) {
  paste0("_", granularity)
}

# Same convention, for which NLI model (nli.active) produced the output:
# "" for "deberta_zeroshot" (the original model every existing filename/link
# was produced under), "_<nli_active>" for anything else (e.g.
# "_bge_m3_zeroshot"). Without this, switching nli.active and re-running
# would silently overwrite another model's same-named report cache/HTML --
# these reporting-layer filenames were only ever suffixed by granularity,
# not by which model scored the data.
nli_model_suffix <- function(nli_active) {
  if (identical(nli_active, "deberta_zeroshot")) "" else paste0("_", nli_active)
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
