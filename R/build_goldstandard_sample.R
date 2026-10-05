# Draws the human-review sample and writes the blinded reviewer instruments.
#
# NO TARGET -- run by hand, same discipline as R/migrate_nli_scores_consolidate.R
# and R/find_orphaned_claim_scores.R, and for a sharper reason than either: a
# target re-runs whenever anything upstream changes, which here would regenerate
# the instruments underneath whatever a reviewer had already filled in. The
# instruments need to be FROZEN once drawn, and a file in a tracked directory is
# what freezes them. Hence also the refuse-to-overwrite guard below.
#
#   source("R/build_goldstandard_sample.R"); build_goldstandard_sample()
#
# WHY this exists at all: every number this project reports measures agreement
# with gpt-4o-mini. Its Phase 2 verdicts are the training labels and the
# benchmark scores how faithfully a fine-tuned model reproduces them, so a model
# that perfectly reproduced a wrong judge would score perfectly. Reading real
# disagreements showed it IS wrong in a specific way -- REFUTES verdicts citing
# quotes that are verbatim but topically adjacent, which quote_is_verbatim()
# cannot catch because it checks a quote EXISTS, never that it BEARS ON the
# claim. Nothing resolves that except human labels.
#
# The two reviewer files are deliberately BLINDED: id, claim, title, abstract,
# doi and empty verdict columns, and nothing else. No nli_label, no llm_label,
# no relevance score, no llm_quote. output/tables/refutes_review.csv shows all of
# those and is the right diagnostic to read, but showing them to a reviewer
# anchors the judgement being measured.

GOLDSTANDARD_VERDICTS <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO", "CANNOT_JUDGE")

# Columns a reviewer sees, in this order. CANNOT_JUDGE is deliberately a fourth
# verdict rather than folded into NOT_ENOUGH_INFO: "the abstract is in another
# language" and "the claim is ambiguous" are failures of the INSTRUMENT, while
# NEI is a real finding about the paper. Merging them silently corrupts the one
# class that already dominates the corpus.
goldstandard_template_cols <- function() {
  c("id", "claim", "title", "abstract", "doi", "verdict", "note", "reviewer", "date")
}

build_goldstandard_sample <- function(
  n = 200L,
  assessments = NULL,
  reviewers = c("R1", "R2"),
  granularity = NULL,
  scorer_config = NULL,
  training_root = "output/nli_training",
  output_dir = "input/goldstandard",
  config_file = "input/config.yaml",
  # Oversample REFUTES relative to its share of the holdout: it is ~2% of the
  # corpus, so a proportional draw of 200 would contain a handful and say
  # nothing about the one class this project exists to find. The manifest
  # records each stratum's inclusion probability so corpus-level rates can be
  # recovered by inverse-probability weighting.
  #
  # BOTH precision and recall need that weighting. The stratification variable
  # is the LLM's label -- the thing under question -- not the true label, and
  # the models being scored were distilled from that same LLM, so their
  # predictions correlate with it. Measured: gpt-4o-mini's SUPPORTS recall came
  # out 40.4% unweighted against 75.4% weighted on the real GA1 sample.
  #
  # KNOWN LIMIT of this scheme, found on the first real pass: stratifying on a
  # label that turns out to be mostly wrong is not an enrichment. 100 rows drawn
  # from the REFUTES stratum yielded ONE adjudicated REFUTES, because the
  # judge's REFUTES precision is a few per cent. That is a real result about the
  # judge, and it also means REFUTES *recall* and per-class REFUTES model scores
  # are out of reach at any feasible sample size here -- finding REFUTES the
  # judge MISSED means reviewing the ~95% NOT_ENOUGH_INFO mass instead. What
  # this sample does measure well is the judge's REFUTES precision.
  strata_weights = c(REFUTES = 0.5, SUPPORTS = 0.25, NOT_ENOUGH_INFO = 0.25),
  min_abstract_chars = 50L,
  seed = 1L,
  force = FALSE
) {
  cfg <- yaml::read_yaml(config_file)
  if (is.null(granularity)) {
    granularity <- cfg[["nli"]][["configs"]][[cfg[["training"]][["nli"]]]][["granularity"]]
  }
  if (is.null(scorer_config)) scorer_config <- cfg[["training"]][["nli"]]
  if (is.null(assessments)) assessments <- unlist(cfg[["training"]][["assessments"]], use.names = FALSE)

  root <- file.path(
    training_root, paste0("granularity=", granularity), paste0("scorer_config=", scorer_config)
  )
  if (!dir.exists(root)) {
    stop(sprintf(
      "build_goldstandard_sample: no training data at %s -- run the training project's nli_training_data target first",
      root
    ))
  }

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  all_pool <- arrow::open_dataset(root) |> dplyr::collect()

  if (!"split" %in% names(all_pool)) {
    stop("build_goldstandard_sample: no `split` column -- rebuild nli_training_data (R/build_nli_training_data.R adds it)")
  }
  if (!"holdout" %in% unique(all_pool$split)) {
    stop(
      "build_goldstandard_sample: `split` has no 'holdout' value, so this is the OLD two-way split. ",
      "Rebuild nli_training_data before drawing a sample -- a sample drawn from the old `test` fold ",
      "would overlap the rows fine-tuning selected its checkpoint on."
    )
  }

  out <- list()
  for (aid in assessments) {
    pool <- all_pool |>
      dplyr::filter(assessment == aid, split == "holdout") |>
      # A reviewer cannot judge what they cannot read. Measured on the current
      # holdout: 25% of rows have no usable abstract.
      dplyr::filter(!is.na(abstract), nchar(abstract) >= min_abstract_chars)

    if (!nrow(pool)) {
      message(sprintf("[goldstandard %s] no reviewable holdout rows -- skipped", aid))
      next
    }

    # Draw per stratum. The draw is seeded, which is fine here precisely
    # BECAUSE the result is written once and then frozen as a file -- unlike
    # the negatives downsampling in build_nli_training_data.R, which is
    # recomputed on every build and therefore had to be hash-stable instead.
    set.seed(seed)
    picked <- list()
    for (lab in names(strata_weights)) {
      avail <- pool |> dplyr::filter(label == lab)
      want <- min(nrow(avail), ceiling(n * strata_weights[[lab]]))
      if (!want) next
      picked[[lab]] <- avail |>
        dplyr::slice_sample(n = want) |>
        dplyr::mutate(
          stratum = lab,
          # P(a row of this stratum is drawn). The weighting factor for any
          # corpus-level rate is 1/p_include.
          p_include = want / nrow(avail)
        )
    }
    sample_df <- dplyr::bind_rows(picked)
    if (!nrow(sample_df)) {
      message(sprintf("[goldstandard %s] nothing drawn -- skipped", aid))
      next
    }

    manifest_path <- file.path(output_dir, sprintf("sample_manifest_%s.csv", aid))
    paths <- c(manifest_path, vapply(
      reviewers,
      function(r) file.path(output_dir, sprintf("%s_%s_template.csv", r, aid)),
      character(1), USE.NAMES = FALSE
    ))
    # Also refuse if a FILLED file exists, not just a template: regenerating a
    # sample on top of completed review work is the one unrecoverable mistake
    # available here, and a reviewer's copy is the thing actually worth
    # protecting.
    filled <- file.path(output_dir, sprintf("%s_%s.csv", reviewers, aid))
    clash <- c(paths, filled)[file.exists(c(paths, filled))]
    if (length(clash) && !force) {
      stop(sprintf(
        "build_goldstandard_sample: refusing to overwrite existing file(s):\n  %s\nPass force = TRUE only if you are certain no reviewer work is lost.",
        paste(clash, collapse = "\n  ")
      ))
    }

    # Manifest: everything the benchmark needs to weight and to audit, and
    # everything a reviewer must NOT see. Never handed out.
    utils::write.csv(
      sample_df |> dplyr::select(dplyr::any_of(c(
        "id", "assessment", "km", "bm", "work_id", "stratum", "p_include",
        "label", "source", "keypaper", "nli_label", "nli_confidence",
        "llm_config", "scorer_config", "quote"
      ))),
      manifest_path, row.names = FALSE, na = ""
    )

    instrument <- sample_df |>
      dplyr::transmute(
        id = id, claim = hypothesis, title = title, abstract = abstract, doi = doi,
        verdict = NA_character_, note = NA_character_,
        reviewer = NA_character_, date = NA_character_
      )

    for (r in reviewers) {
      # Shuffled INDEPENDENTLY per reviewer, so order and fatigue effects do
      # not correlate between them -- two reviewers tiring on the same row
      # would inflate agreement without either being more right.
      set.seed(seed + match(r, reviewers))
      utils::write.csv(
        instrument[sample.int(nrow(instrument)), goldstandard_template_cols()],
        file.path(output_dir, sprintf("%s_%s_template.csv", r, aid)),
        row.names = FALSE, na = ""
      )
    }

    message(sprintf(
      "[goldstandard %s] %d pairs (%s) -> %s",
      aid, nrow(sample_df),
      paste(sprintf("%s %d", names(table(sample_df$stratum)), as.integer(table(sample_df$stratum))), collapse = ", "),
      output_dir
    ))
    out[[aid]] <- sample_df
  }

  if (!length(out)) stop("build_goldstandard_sample: nothing drawn for any assessment")
  invisible(out)
}
