# ---------------------------------------------------------------------------
# OUTPUT ROOTS, one per targets project.
#
# output/ used to be a flat list of ~18 directories with no indication of which
# pipeline owned which. These three helpers name the owner, so the layout
# matches _targets.yaml's projects:
#
#   output/collection/   main       LoD refs key_messages zotero works
#                                   snowball works_citing works_citing_meta
#   output/factchecker/  factcheck  claim_work_pairs claim_scores
#                                   llm_candidate_scope llm_relevance
#                                   llm_verification claim_completion
#   output/reporting/    reporting  tables figures
#   output/reports/      reporting  the rendered site -- DELIBERATELY NOT under
#                                   reporting/, because .github/workflows/
#                                   deploy-pages.yml rsyncs it to the gh-pages
#                                   root and moving it would publish tables/
#                                   and figures/ too.
#
# Call these rather than writing "output/<root>/..." literally. They exist
# because the same path formula had already been hand-rolled five separate
# times across _targets_reporting.R and the Phase 2 builders, and the copies
# drifted -- one of them silently read the wrong tree. A root is now one edit.
#
# NOTE for .qmd authors: Quarto renders in a fresh session that never sources
# R/*.R, so report bodies keep plain literals. Same reason
# _IPBES_Label_Funnel_Report_body.qmd inlines granularity_suffix().
out_collection <- function(...) file.path("output/collection", ...)
out_factcheck <- function(...) file.path("output/factchecker", ...)
out_reporting <- function(...) file.path("output/reporting", ...)

# The assessment list moved under `collection:` on 2026-10-07, so that
# input/config.yaml groups by targets project the way output/ and _targets.yaml
# now do. Read it through here rather than reaching into the structure: it was
# accessed from six places, and a silent NULL would read as "no assessments"
# -- every branched target would simply produce nothing, which looks like a
# successful empty run rather than a broken config.
config_assessments <- function(config) {
  a <- config[["collection"]][["assessments"]]
  if (is.null(a)) {
    stop("input/config.yaml: no `collection: assessments:` block. It moved under ",
         "`collection:` on 2026-10-07; a top-level `assessments:` is no longer read.",
         call. = FALSE)
  }
  a
}

assessment_ids <- function(config) {
  vapply(config_assessments(config), `[[`, character(1), "id")
}

# Shared SUPPORTS/REFUTES/NOT_ENOUGH_INFO palette for every NLI-label figure
# (ggplot2 and plotly alike) -- Okabe-Ito, the standard colorblind-safe
# reference palette, chosen for high distinguishability between all three
# colors, not just accessibility (the previous per-file muted-earth-tone
# palette was hard to tell apart even for non-colorblind viewers). A single
# shared definition, rather than one copy per figure file: before this,
# build_claim_scores_bm_explorer.R's own copy had already drifted to different hex
# values than build_claim_scores_overview_figures.R's, and
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
# was produced under), "_<scorer_name>" for anything else (e.g.
# "_bge_m3_zeroshot"). Without this, switching nli.active and re-running
# would silently overwrite another model's same-named report cache/HTML --
# these reporting-layer filenames were only ever suffixed by granularity,
# not by which model scored the data.
nli_model_suffix <- function(scorer_name) {
  if (identical(scorer_name, "deberta_zeroshot")) "" else paste0("_", scorer_name)
}

# Resolves, for each value in `granularities`, the nli.configs.<name> entry
# that actually PRODUCED that granularity's scores -- i.e. whichever config
# has a matching `granularity:` field -- rather than assuming it's whichever
# config is currently `nli.active`. Needed because `active` is a single
# global choice but naive_bm/complete_bm/atomic_bm are each scored under
# their own dedicated config (bge_m3_zeroshot_naive_bm/_complete_bm/
# _atomic_bm); without this, switching `active` makes the reporting layer
# (nli_overview_data, the REFUTES/SUPPORTS funnel reports) look for a
# not-currently-active granularity's data under the wrong scorer_config=
# subdirectory and silently report it as unscored, even when real scored
# data for that granularity sits on disk under its own config's name.
# Falls back to `fallback` (scorer_name) for any granularity with no config
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
    # FIRST MATCH WINS, and that is now order-dependent in a way it was not when
    # each granularity had exactly one config. Three configs declare atomic_bm
    # (the zero-shot one that produced every existing score, the fine-tune, and
    # the jev backend), so a reordering of the yaml would silently repoint every
    # atomic_bm report at a different scorer_config= directory and make scored data
    # look unscored -- the precise failure this helper exists to prevent.
    #
    # So it warns when a granularity is ambiguous, naming what it picked and
    # what it passed over. It does NOT stop: resolving to the first declaration
    # is correct for the reporting layer, which wants whichever config actually
    # produced the bulk of the scores, and a hard error here would make adding a
    # second backend impossible without editing this function.
    if (length(hit) > 1L) {
      warning(sprintf(
        "nli_config_for_granularity: granularity '%s' is declared by %d configs (%s); using '%s'. Reordering input/config.yaml would change which scores the reports read.",
        g, length(hit), paste(hit, collapse = ", "), hit[[1L]]
      ), call. = FALSE)
    }
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
  block <- cfg[[purpose]]
  if (is.null(block)) {
    stop(sprintf(
      "config.yaml has no `%s:` block (expected one of: fact_checking, training)",
      purpose
    ), call. = FALSE)
  }

  # TWO SHAPES, deliberately. A purpose block is either the config itself (flat,
  # what `training:` still uses) or a LIBRARY of named configs with `active:`
  # naming which one runs -- the same "definitions select nothing themselves"
  # discipline `nli:` and `llm_verification:` already use, so a definition left
  # lying around cannot surprise anyone with N times the cost.
  #
  # Detected by the presence of `configs:`, not by a version key: a flat block
  # has no `configs:` and a library block always does.
  selected <- purpose           # how to name this block in error messages
  if (!is.null(block[["configs"]])) {
    active <- block[["active"]]
    if (is.null(active) || !length(active)) {
      stop(sprintf(
        "config.yaml: `%s:` has `configs:` but no `active:` naming which one to run (defined: %s)",
        purpose, paste(names(block[["configs"]]), collapse = ", ")
      ), call. = FALSE)
    }
    active <- as.character(active)
    if (length(active) != 1L) {
      stop(sprintf(
        "config.yaml: `%s.active` must name exactly ONE config, got %d (%s)",
        purpose, length(active), paste(active, collapse = ", ")
      ), call. = FALSE)
    }
    if (!active %in% names(block[["configs"]])) {
      stop(sprintf(
        "config.yaml: `%s.active: %s` is not a defined config (defined: %s)",
        purpose, active, paste(names(block[["configs"]]), collapse = ", ")
      ), call. = FALSE)
    }
    p <- block[["configs"]][[active]]
    selected <- paste0(purpose, ".configs.", active)
  } else {
    p <- block
  }

  pick <- function(field, library, required = TRUE) {
    name <- p[[field]]
    if (is.null(name) || !length(name)) {
      if (!required) return(NULL)
      stop(sprintf("config.yaml: `%s:` is missing `%s:`", selected, field), call. = FALSE)
    }
    # STOPS on a list rather than silently taking its head. It used to do
    # `as.character(name)[[1L]]`, so `nli: [a, b]` resolved to `a` with no
    # complaint -- naming the wrong model is exactly the error class that reads
    # as "nothing scored yet" and re-dispatches a corpus at real GPU cost.
    # `km` is legitimately a vector and does NOT come through here.
    name <- as.character(name)
    if (length(name) != 1L) {
      stop(sprintf(
        "config.yaml: `%s.%s` must name exactly ONE config, got %d (%s)",
        selected, field, length(name), paste(name, collapse = ", ")
      ), call. = FALSE)
    }
    known <- names(library)
    if (!name %in% known) {
      stop(sprintf(
        "config.yaml: `%s.%s: %s` is not a known config (known: %s)",
        selected, field, name, paste(known, collapse = ", ")
      ), call. = FALSE)
    }
    name
  }

  nli_name <- pick("nli", cfg[["nli"]][["configs"]])
  llm_name <- pick("llm", cfg[["llm_verification"]][["configs"]])
  cc_name  <- pick("claim_completion", cfg[["claim_completion"]][["configs"]])

  ids <- as.character(unlist(p[["assessments"]], use.names = FALSE))
  known_ids <- vapply(config_assessments(cfg), `[[`, character(1), "id")
  unknown <- setdiff(ids, known_ids)
  if (length(unknown)) {
    stop(sprintf(
      "config.yaml: `%s.assessments` names unknown assessment(s): %s (known: %s)",
      selected, paste(unknown, collapse = ", "), paste(known_ids, collapse = ", ")
    ), call. = FALSE)
  }

  # Key Message scope. NULL (the key omitted) means every KM -- so an existing
  # config is unscoped and unchanged. Values cannot be validated here: KMs come
  # from key_messages_parquet, a target, not from config. build_claim_units()
  # does that, where the data is in hand.
  km <- p[["km"]]
  km <- if (is.null(km) || !length(km)) NULL else as.character(unlist(km, use.names = FALSE))

  list(
    assessments            = ids,
    km                     = km,
    nli                    = nli_name,
    llm                    = llm_name,
    claim_completion       = cc_name,
    claim_completion_model = cfg[["claim_completion"]][["configs"]][[cc_name]][["model"]],
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
  out <- lapply(config_assessments(cfg), function(a) a[setdiff(names(a), "full_text")])
  out[vapply(out, `[[`, character(1), "id") %in% ids]
}

# Deterministic fold assignment for the benchmark holdout (TD_NLI_training.qmd).
#
# Returns a bucket 0-99 per key. Two properties are the whole point:
#
#   * HASH, not shuffle. A group's bucket is a pure function of its own
#     identity, so adding an assessment, re-running Phase 2 or growing the
#     citing-works corpus never moves an existing group across the train/test
#     boundary. A shuffled split would silently invalidate every previously
#     recorded benchmark result the moment the corpus grew -- and this corpus
#     grows continuously, which is exactly when shuffling is worst.
#   * serialize = FALSE. digest() defaults to hashing an R SERIALISATION of
#     the value rather than the string bytes; the serialisation carries
#     version attributes, so the default would make fold assignment depend on
#     the R/digest versions in use. A benchmark meant to outlive several of
#     both needs the bytes.
#
# `salt` is the benchmark version tag (config.yaml's `benchmark.salt`).
# Changing it re-cuts every fold, which is the only way the benchmark should
# ever change -- and it shows up in a diff and can be quoted in a result table.
hash_bucket <- function(key, salt) {
  vapply(
    paste(key, salt, sep = "|"),
    function(k) strtoi(substr(digest::digest(k, algo = "md5", serialize = FALSE), 1, 6), 16L) %% 100L,
    integer(1),
    USE.NAMES = FALSE
  )
}
