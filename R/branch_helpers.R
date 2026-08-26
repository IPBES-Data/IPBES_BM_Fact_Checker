assessment_ids <- function(config) {
  vapply(config$assessments, `[[`, character(1), "id")
}

# Shared SUPPORTS/REFUTES/NOT_ENOUGH_INFO palette for every NLI-label figure
# (ggplot2 and plotly alike) -- Okabe-Ito, the standard colorblind-safe
# reference palette, chosen for high distinguishability between all three
# colors, not just accessibility (the previous per-file muted-earth-tone
# palette was hard to tell apart even for non-colorblind viewers). A single
# shared definition, rather than one copy per figure file: before this,
# build_nli_bm_explorer.R's own copy had already drifted to different hex
# values than build_nli_overview_figures.R's, and
# build_label_funnel_figures.R hardcoded the REFUTES color as its funnel
# bar's fill regardless of which label that funnel was actually built for
# (so a SUPPORTS funnel report rendered its bar in the REFUTES color) --
# exactly the kind of drift a shared constant prevents.
nli_label_levels <- c("SUPPORTS", "NOT_ENOUGH_INFO", "REFUTES")
nli_label_colors <- c(
  SUPPORTS = "#009E73",         # bluish green
  NOT_ENOUGH_INFO = "#0072B2",  # blue
  REFUTES = "#D55E00"           # vermillion
)

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

# Resolves, for each value in `granularities`, the nli.configs.<name> entry
# that actually PRODUCED that granularity's scores -- i.e. whichever config
# has a matching `granularity:` field -- rather than assuming it's whichever
# config is currently `nli.active`. Needed because `active` is a single
# global choice but naive_bm/complete_bm/atomic_bm are each scored under
# their own dedicated config (bge_m3_zeroshot_naive_bm/_complete_bm/
# _atomic_bm); without this, switching `active` makes the reporting layer
# (nli_overview_data, the REFUTES/SUPPORTS funnel reports) look for a
# not-currently-active granularity's data under the wrong nli_config=
# subdirectory and silently report it as unscored, even when real scored
# data for that granularity sits on disk under its own config's name.
# Falls back to `fallback` (nli_active) for any granularity with no config
# declaring it, so an unmapped/legacy setup degrades to the old
# single-config behaviour instead of erroring.
nli_config_for_granularity <- function(nli_configs, granularities, fallback) {
  gran_of <- vapply(nli_configs, function(cfg) {
    g <- cfg[["granularity"]]
    if (is.null(g) || !nzchar(g)) NA_character_ else as.character(g)
  }, character(1))
  names(gran_of) <- names(nli_configs)

  vapply(granularities, function(g) {
    hit <- names(gran_of)[!is.na(gran_of) & gran_of == g]
    if (length(hit)) hit[[1L]] else fallback
  }, character(1))
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
