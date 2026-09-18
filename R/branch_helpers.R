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

# ---------------------------------------------------------------------------
# Purpose blocks: which named config each pipeline actually uses.
#
# input/config.yaml keeps `nli:` and `llm_verification:` as LIBRARIES of named
# definitions, and puts the SELECTION in a per-purpose block (`fact_checking:`,
# `training:`). That split exists because "active" is a single global answer to
# a question each project answers for itself: fact checking may score one
# assessment with one model while training pools five with another. While there
# was one DAG the conflation was invisible; with four projects it is wrong.
#
# It also keeps scope out of `assessments:`. Per-assessment `training: true` /
# `fact_checking: false` flags would change `assessments_list`'s value and so
# invalidate `assessment`, and with it ttl_path, works_parquet,
# snowball_parquet and everything downstream. A purpose block avoids that
# hazard rather than defusing it.
#
# Returns a list: assessments (character, the ids this purpose is scoped to),
# nli, llm, claim_completion (config NAMES), claim_completion_model (resolved),
# finetune_enabled, downsample_seed.
#
# Validates loudly. A name that does not exist in the corresponding library is
# a typo that would otherwise read as "nothing has been scored yet" and quietly
# re-dispatch a corpus at real GPU cost, so every one is checked here.
purpose_config <- function(cfg, purpose) {
  p <- cfg[[purpose]]
  if (is.null(p)) {
    stop(sprintf(
      "config.yaml has no `%s:` block (expected one of: fact_checking, training)",
      purpose
    ), call. = FALSE)
  }

  pick <- function(field, library, required = TRUE) {
    name <- p[[field]]
    if (is.null(name) || !length(name)) {
      if (!required) return(NULL)
      stop(sprintf("config.yaml: `%s:` is missing `%s:`", purpose, field), call. = FALSE)
    }
    name <- as.character(name)[[1L]]
    known <- names(library)
    if (!name %in% known) {
      stop(sprintf(
        "config.yaml: `%s.%s: %s` is not a known config (known: %s)",
        purpose, field, name, paste(known, collapse = ", ")
      ), call. = FALSE)
    }
    name
  }

  nli_name <- pick("nli", cfg[["nli"]][["configs"]])
  llm_name <- pick("llm", cfg[["llm_verification"]][["configs"]])
  cc_name  <- pick("claim_completion", cfg[["nli"]][["claim_completion"]][["configs"]])

  ids <- as.character(unlist(p[["assessments"]], use.names = FALSE))
  known_ids <- vapply(cfg[["assessments"]], `[[`, character(1), "id")
  unknown <- setdiff(ids, known_ids)
  if (length(unknown)) {
    stop(sprintf(
      "config.yaml: `%s.assessments` names unknown assessment(s): %s (known: %s)",
      purpose, paste(unknown, collapse = ", "), paste(known_ids, collapse = ", ")
    ), call. = FALSE)
  }

  list(
    assessments            = ids,
    nli                    = nli_name,
    llm                    = llm_name,
    claim_completion       = cc_name,
    claim_completion_model = cfg[["nli"]][["claim_completion"]][["configs"]][[cc_name]][["model"]],
    finetune_enabled       = isTRUE(p[["finetune"]][["enabled"]]),
    downsample_seed        = p[["finetune"]][["downsample_seed"]]
  )
}

# Scope `assessments:` to one purpose block, preserving the exact element shape
# `assessments_list` has always produced (the `full_text` strip included), so a
# purpose listing every assessment yields a byte-identical value and invalidates
# nothing downstream.
purpose_assessments_list <- function(cfg, purpose) {
  ids <- purpose_config(cfg, purpose)$assessments
  out <- lapply(cfg[["assessments"]], function(a) a[setdiff(names(a), "full_text")])
  out[vapply(out, `[[`, character(1), "id") %in% ids]
}
