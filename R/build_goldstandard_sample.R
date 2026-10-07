# Draws the human-review sample and writes the blinded reviewer instruments.
#
# NO TARGET -- run by hand, same discipline as R/find_orphaned_claim_scores.R and
# for a sharper reason: a target re-runs whenever anything upstream changes,
# which here would regenerate the instruments underneath whatever a reviewer had
# already filled in. The instruments need to be FROZEN once drawn, and a file in
# a tracked directory is what freezes them. Hence also the refuse-to-overwrite
# guard below, which refuses on a FILLED file as well as a template.
#
#   source("R/build_goldstandard_sample.R")
#   build_goldstandard_sample_sets()     # draws both sets
#
# WHY THIS EXISTS: every number this project reports comes from models judging
# models. Human labels are the only thing that breaks the circularity.
#
# ---------------------------------------------------------------------------
# VERSION HISTORY -- both earlier designs failed for reasons worth keeping
# ---------------------------------------------------------------------------
#
# v1 (deep_archive/2026-10-07_goldstandard_v1_phase2_conditioned/) drew from
# PHASE 2's reviewed subset, stratified on gpt-4o-mini's own verdict, out of a
# set produced by zero-shot routing. Of its 200 rows, 16 had a Jev score and NONE
# was a citing work: the deliverable arm had zero gold coverage under the model
# being chosen. Structural, not a bad draw -- conditioning the instrument on a
# model DOWNSTREAM of the one being measured confines it to that model's reach.
#
# v2 drew from the Phase 1 THREE-WAY COMMON SET (Jev inner-joined with the two
# retired NLI backends), stratified on patterns of agreement between the three.
# That answered "which of three models is right" -- but two of the three no
# longer run, so most of the instrument's power was spent on a question that had
# already been settled by removing them.
#
# v3 (this file) draws from JEV STAGE 1 ALONE, which is what the pipeline
# actually runs, and balances on Jev's own label.
#
# ---------------------------------------------------------------------------
# WHY PHASE 2 IS NOT A STRATUM, AND WHY IT IS STILL MEASURABLE
# ---------------------------------------------------------------------------
# Routing into Phase 2 is a DETERMINISTIC function of the stage-1 label and
# confidence band (llm_verification config: nli_labels + nli_certainty). So in a
# design balanced over 3 labels x 2 bands, exactly two of the six cells ARE the
# routed set -- a third of set A arrives with a Phase 2 verdict attached, at no
# extra reviewing cost. Stratifying ON Phase 2 would instead confine the whole
# instrument to the 0.5% of rows it covers and make stage-1 RECALL unmeasurable,
# which is the blind spot input/mmd/overview.mmd flags as the main open question.
#
# ---------------------------------------------------------------------------
# THE TWO SETS
# ---------------------------------------------------------------------------
#   A  citing works (keypaper=false)  BALANCED, 40 per cell over
#      3 labels x {certain, uncertain} = 240 rows.
#      Balanced because the labels are wildly unequal (REFUTES is ~0.1% of the
#      corpus) and a proportional draw would contain almost no REFUTES at all.
#      Spanning both confidence bands is what lets the round CALIBRATE
#      uncertain_threshold, which config.yaml marks UNCALIBRATED for this model.
#
#   B  key papers (keypaper=true)     PROPORTIONAL to the key-paper label ratio,
#      100 rows. Proportional, not balanced, deliberately: a key paper IS the
#      evidence its BM was written from, so the SHAPE of the distribution is the
#      finding under test. Balancing would erase exactly what set B exists to
#      measure.
#
# Sets are named A and B, never "citing" and "keypaper", and nothing in the
# instrument says which is which. A reviewer who knew set B was key papers would
# expect SUPPORTS and drift toward it -- and since 92% of set B is rows Jev calls
# NOT_ENOUGH_INFO, that drift would land precisely on the disputed cell.
#
# STRATIFICATION IS ON THE MODEL'S LABEL, NOT ON TRUTH. The sample is therefore
# skewed WITHIN each truth class, not just between classes, so corpus-level
# precision AND recall are recoverable only by 1/p_include weighting. Every
# stratum's inclusion probability is recorded in its manifest.

GOLDSTANDARD_VERDICTS <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO", "CANNOT_JUDGE")

goldstandard_template_cols <- function() {
  c("id", "claim", "title", "abstract", "doi", "verdict", "note", "reviewer", "date")
}

goldstandard_labels <- function() c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")

# Reads one side of the merged Phase 1 tree. `keypaper` is PINNED by the caller,
# never inferred: since the two chains merged into one tree an unpinned read
# would mix key papers into the citing instrument silently, in the one artifact
# whose entire purpose is to be trustworthy.
goldstandard_read_scores <- function(scores_root, granularity, scorer_config,
                                     assessment, km, keypaper) {
  path <- file.path(
    scores_root, paste0("granularity=", granularity),
    paste0("scorer_config=", scorer_config),
    paste0("keypaper=", tolower(as.character(isTRUE(keypaper)))),
    paste0("assessment=", assessment)
  )
  if (!dir.exists(path)) {
    stop(sprintf("build_goldstandard_sample: no scores at %s", path), call. = FALSE)
  }
  d <- arrow::open_dataset(path) |>
    dplyr::select("km", "bm", "claim_id", "claim", "work_id", "label",
                  "confidence", "uncertain")
  if (!is.null(km) && length(km)) d <- dplyr::filter(d, km %in% !!km)
  dplyr::collect(d)
}

# Key papers are SEED works and are NOT in the citing-works dataset, so the two
# sets take different metadata sources. Getting this wrong yields an empty join
# and an empty instrument, which looks like "nothing to review" rather than a bug.
goldstandard_meta <- function(keypaper, assessment) {
  # Assigned, not piped straight out of the if/else: `if (a) X else Y |> f()`
  # parses as `if (a) X else (Y |> f())`, so piping the branch directly would
  # select() only the citing side and hand back an unselected Dataset for keypaper.
  ds <- if (isTRUE(keypaper)) {
    arrow::open_dataset(out_collection("works"))
  } else {
    arrow::open_dataset(file.path(out_collection("works_citing_meta"),
                                  paste0("assessment=", assessment)))
  }
  ds |>
    dplyr::select("id", "title", "abstract", "doi") |>
    dplyr::collect() |>
    dplyr::distinct(.data$id, .keep_all = TRUE)
}

build_goldstandard_sample <- function(
  set,
  keypaper,
  design = c("balanced", "proportional"),
  n = 240L,
  assessment = "GA1",
  granularity = "atomic_bm",
  scorer_config = "jev_atomic_bm",
  km = NULL,
  scores_root = out_factcheck("claim_scores"),
  output_dir = "input/goldstandard",
  reviewers = c("R1", "R2"),
  # A reviewer cannot judge what they cannot read. Applied BEFORE the draw, so
  # p_include stays a true inclusion probability.
  min_abstract_chars = 50L,
  seed = 1L,
  force = FALSE
) {
  design <- match.arg(design)
  stopifnot(is.character(set), length(set) == 1L, nzchar(set))

  pool <- goldstandard_read_scores(scores_root, granularity, scorer_config,
                                   assessment, km, keypaper)
  if (!nrow(pool)) stop("build_goldstandard_sample: no scored rows", call. = FALSE)

  meta <- goldstandard_meta(keypaper, assessment)
  before <- nrow(pool)
  pool <- pool |>
    dplyr::inner_join(meta, by = c("work_id" = "id")) |>
    dplyr::filter(
      !is.na(.data$abstract), nchar(.data$abstract) >= min_abstract_chars,
      !is.na(.data$claim), nchar(.data$claim) > 0L
    )
  message(sprintf(
    "[goldstandard %s] %s of %s rows reviewable (%.1f%% dropped: no usable abstract)",
    set, format(nrow(pool), big.mark = ","), format(before, big.mark = ","),
    100 * (1 - nrow(pool) / before)
  ))
  if (!nrow(pool)) stop("build_goldstandard_sample: nothing reviewable", call. = FALSE)

  # ---- strata -----------------------------------------------------------
  # Balanced: label x confidence band, so the two routed cells fall out exactly
  # and the threshold can be calibrated. Proportional: label only -- the band
  # would fragment an already thin REFUTES cell for no gain, since the point of
  # a proportional draw is the label shape.
  pool <- pool |>
    dplyr::mutate(
      band = ifelse(.data$uncertain, "uncertain", "certain"),
      stratum = if (design == "balanced") paste(.data$label, .data$band, sep = "/")
                else .data$label
    )

  want_by <- if (design == "balanced") {
    cells <- as.vector(outer(goldstandard_labels(), c("certain", "uncertain"),
                             paste, sep = "/"))
    stats::setNames(rep(ceiling(n / length(cells)), length(cells)), cells)
  } else {
    share <- table(pool$stratum) / nrow(pool)
    stats::setNames(as.integer(round(n * as.numeric(share))), names(share))
  }

  set.seed(seed)
  picked <- list()
  for (st in names(want_by)) {
    avail <- pool[pool$stratum == st, , drop = FALSE]
    want <- min(nrow(avail), want_by[[st]])
    if (!want) {
      message(sprintf("[goldstandard %s] stratum %-28s EMPTY -- 0 drawn of %d wanted",
                      set, st, want_by[[st]]))
      next
    }
    if (want < want_by[[st]]) {
      message(sprintf("[goldstandard %s] stratum %-28s only %d available, wanted %d",
                      set, st, want, want_by[[st]]))
    }
    picked[[st]] <- avail |>
      dplyr::slice_sample(n = want) |>
      dplyr::mutate(p_include = want / nrow(avail))
  }
  sample_df <- dplyr::bind_rows(picked) |>
    dplyr::mutate(id = sprintf("%s-%s-%04d", assessment, set, dplyr::row_number()))
  if (!nrow(sample_df)) stop("build_goldstandard_sample: nothing drawn", call. = FALSE)

  # ---- refuse to clobber ------------------------------------------------
  manifest_path <- file.path(output_dir, sprintf("sample_manifest_%s_%s.csv", assessment, set))
  paths <- c(
    manifest_path,
    file.path(output_dir, sprintf("%s_%s_%s_template.csv", reviewers, assessment, set)),
    file.path(output_dir, sprintf("%s_%s_%s.csv", reviewers, assessment, set))
  )
  clash <- paths[file.exists(paths)]
  if (length(clash) && !force) {
    stop(sprintf(
      "build_goldstandard_sample: refusing to overwrite existing file(s):\n  %s\nPass force = TRUE only if you are certain no reviewer work is lost.",
      paste(clash, collapse = "\n  ")
    ), call. = FALSE)
  }
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  # Manifest: everything needed to weight and audit, and everything a reviewer
  # must NOT see. Never handed out. `keypaper` is recorded here so the two sets
  # can be told apart at analysis time -- which is exactly where that is wanted
  # and exactly where the instrument must stay silent about it.
  utils::write.csv(
    sample_df |>
      dplyr::transmute(
        id = .data$id, set = set, assessment = assessment, granularity = granularity,
        scorer_config = scorer_config, keypaper = isTRUE(keypaper),
        km = .data$km, bm = .data$bm, claim_id = .data$claim_id, work_id = .data$work_id,
        stratum = .data$stratum, design = design, p_include = .data$p_include,
        jev_label = .data$label, jev_confidence = .data$confidence,
        jev_uncertain = .data$uncertain, doi = .data$doi
      ),
    manifest_path, row.names = FALSE, na = ""
  )

  instrument <- sample_df |>
    dplyr::transmute(
      id = .data$id, claim = .data$claim, title = .data$title,
      abstract = .data$abstract, doi = .data$doi,
      verdict = NA_character_, note = NA_character_,
      reviewer = NA_character_, date = NA_character_
    )

  for (r in reviewers) {
    # Shuffled INDEPENDENTLY per reviewer, so order and fatigue effects do not
    # correlate between them: two reviewers tiring on the same row would inflate
    # agreement without either being more right, and agreement is the measurement.
    set.seed(seed + match(r, reviewers))
    utils::write.csv(
      instrument[sample.int(nrow(instrument)), goldstandard_template_cols()],
      file.path(output_dir, sprintf("%s_%s_%s_template.csv", r, assessment, set)),
      row.names = FALSE, na = ""
    )
  }

  message(sprintf(
    "[goldstandard %s] %d rows over %d claims / %d BMs -- %s",
    set, nrow(sample_df),
    dplyr::n_distinct(paste(sample_df$bm, sample_df$claim_id)),
    dplyr::n_distinct(sample_df$bm),
    paste(sprintf("%s=%d", names(table(sample_df$stratum)),
                  as.integer(table(sample_df$stratum))), collapse = ", ")
  ))
  invisible(sample_df)
}

# Draws BOTH sets. Run this, not the single-set function, so the two can never
# drift apart in scope, scorer or seed.
build_goldstandard_sample_sets <- function(
  assessment = "GA1",
  granularity = "atomic_bm",
  scorer_config = "jev_atomic_bm",
  km = NULL,
  n_a = 240L,
  n_b = 100L,
  output_dir = "input/goldstandard",
  seed = 1L,
  force = FALSE
) {
  a <- build_goldstandard_sample(
    set = "A", keypaper = FALSE, design = "balanced", n = n_a,
    assessment = assessment, granularity = granularity,
    scorer_config = scorer_config, km = km,
    output_dir = output_dir, seed = seed, force = force
  )
  b <- build_goldstandard_sample(
    set = "B", keypaper = TRUE, design = "proportional", n = n_b,
    assessment = assessment, granularity = granularity,
    scorer_config = scorer_config, km = km,
    # A different seed per set, so the two draws cannot share a shuffle order.
    output_dir = output_dir, seed = seed + 100L, force = force
  )
  invisible(list(A = a, B = b))
}
