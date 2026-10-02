# Adjudicates the two reviewers' files into the gold standard, and is the HARD
# GATE on the expensive half of the training project: nli_finetuned_model and
# nli_benchmark_qa_data both take it as a required argument, so neither can run
# against an unreviewed corpus.
#
# R1_*.csv and R2_*.csv are NOT the gold standard -- they are the blinded
# instruments (R/build_goldstandard_sample.R writes the templates). The gold
# standard is what survives adjudication.
#
# ADJUDICATION RULE, fixed here before any reviewing happens: rows where both
# reviewers agree become gold; rows where they disagree are REPORTED (they are
# the human ceiling -- no model can be expected to beat the rate at which two
# domain experts agree with each other) and excluded from model scoring.
# Deciding this rule afterwards would mean picking whichever variant flatters
# the result.
#
# Cohen's kappa, not raw agreement: ~95% of this corpus is NOT_ENOUGH_INFO, so
# two reviewers who both default to NEI agree over 90% of the time while
# carrying no information at all. Kappa prices that baseline in.

build_goldstandard <- function(
  goldstandard_dir = "input/goldstandard",
  reviewers = c("R1", "R2"),
  output_dir = NULL
) {
  if (is.null(output_dir)) output_dir <- goldstandard_dir
  if (!dir.exists(goldstandard_dir)) {
    stop(sprintf(
      "build_goldstandard: %s does not exist.\n%s",
      goldstandard_dir, goldstandard_gate_message()
    ))
  }

  filled <- list.files(
    goldstandard_dir,
    pattern = sprintf("^(%s)_[^_]+\\.csv$", paste(reviewers, collapse = "|")),
    full.names = TRUE
  )
  # _template.csv files are excluded by the pattern above (they carry a second
  # underscore-separated token), so an un-started round reads as "no reviews",
  # which is exactly what it is.
  if (!length(filled)) {
    stop(sprintf(
      "build_goldstandard: no completed reviewer files in %s.\n%s",
      goldstandard_dir, goldstandard_gate_message()
    ))
  }

  parse_one <- function(path) {
    stem <- sub("\\.csv$", "", basename(path))
    parts <- strsplit(stem, "_", fixed = TRUE)[[1]]
    d <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = c("", "NA"))
    missing_cols <- setdiff(c("id", "verdict"), names(d))
    if (length(missing_cols)) {
      stop(sprintf("build_goldstandard: %s is missing column(s): %s",
                   path, paste(missing_cols, collapse = ", ")))
    }
    bad <- setdiff(stats::na.omit(unique(d$verdict)), GOLDSTANDARD_VERDICTS)
    if (length(bad)) {
      stop(sprintf(
        "build_goldstandard: %s has unrecognised verdict(s): %s (allowed: %s)",
        path, paste(bad, collapse = ", "), paste(GOLDSTANDARD_VERDICTS, collapse = ", ")
      ))
    }
    dplyr::tibble(
      reviewer_file = parts[[1]], assessment = parts[[2]],
      id = as.character(d$id), verdict = d$verdict,
      note = if ("note" %in% names(d)) d$note else NA_character_
    )
  }

  reviews <- dplyr::bind_rows(lapply(filled, parse_one))

  n_blank <- sum(is.na(reviews$verdict))
  if (n_blank) {
    message(sprintf("[goldstandard] %d row(s) still blank across all reviewer files", n_blank))
  }
  reviews <- reviews[!is.na(reviews$verdict), ]

  wide <- reviews |>
    dplyr::select(assessment, id, reviewer_file, verdict) |>
    tidyr::pivot_wider(names_from = reviewer_file, values_from = verdict)

  present <- intersect(reviewers, names(wide))
  if (length(present) < 2L) {
    stop(sprintf(
      "build_goldstandard: need both reviewers to adjudicate, found only: %s",
      paste(present, collapse = ", ")
    ))
  }
  a <- wide[[present[[1]]]]
  b <- wide[[present[[2]]]]
  both <- !is.na(a) & !is.na(b)

  wide$agreed <- both & a == b
  wide$verdict <- ifelse(wide$agreed, a, NA_character_)

  gold <- wide[wide$agreed, c("assessment", "id", "verdict")]
  # CANNOT_JUDGE is a property of the instrument, not of the paper -- both
  # reviewers agreeing that a row is unjudgeable is a real finding about the
  # SAMPLE, worth keeping in the file, but it is not a label any model can be
  # scored against. Flagged here; the benchmark drops it.
  gold$scorable <- gold$verdict != "CANNOT_JUDGE"

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  for (aid in unique(gold$assessment)) {
    utils::write.csv(
      gold[gold$assessment == aid, ],
      file.path(output_dir, sprintf("gold_%s.csv", aid)),
      row.names = FALSE, na = ""
    )
  }

  k <- cohens_kappa(a[both], b[both])
  message(sprintf(
    "[goldstandard] %d double-reviewed rows | raw agreement %.1f%% | Cohen's kappa %.3f | %d gold (%d scorable)",
    sum(both), 100 * mean(a[both] == b[both]), k, nrow(gold), sum(gold$scorable)
  ))

  list(
    dir = output_dir,
    gold = gold,
    reviews = wide,
    n_double_reviewed = sum(both),
    raw_agreement = if (any(both)) mean(a[both] == b[both]) else NA_real_,
    kappa = k,
    # The human ceiling: rows two experts could not agree on are rows no model
    # should be expected to get "right", so every per-class model figure is read
    # against this.
    disagreements = wide[both & !wide$agreed, ]
  )
}

# Cohen's kappa for two unweighted categorical ratings. Hand-rolled rather than
# adding irr/psych for one formula -- six lines, and the project has no
# DESCRIPTION/renv.lock to record a new dependency in.
cohens_kappa <- function(a, b) {
  if (!length(a)) return(NA_real_)
  lev <- union(unique(a), unique(b))
  m <- table(factor(a, lev), factor(b, lev))
  p_obs <- sum(diag(m)) / sum(m)
  p_exp <- sum(rowSums(m) * colSums(m)) / sum(m)^2
  if (isTRUE(all.equal(p_exp, 1))) return(NA_real_)
  (p_obs - p_exp) / (1 - p_exp)
}

goldstandard_gate_message <- function() {
  paste(
    "The gold standard is a REQUIRED input to fine-tuning and benchmarking: without human",
    "labels, every reported number measures only agreement with gpt-4o-mini, which is the",
    "thing being questioned. To produce it:",
    "  1. source(\"R/build_goldstandard_sample.R\"); build_goldstandard_sample()",
    "  2. each reviewer copies Rx_<assessment>_template.csv to Rx_<assessment>.csv and fills in `verdict`",
    "  3. commit the filled files; this target then writes gold_<assessment>.csv",
    "See input/goldstandard/REVIEWER_GUIDE.md and TD_NLI_training.qmd.",
    sep = "\n"
  )
}
