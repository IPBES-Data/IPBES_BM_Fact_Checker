# Adjudicates the two reviewers' files into the gold standard.
#
# IT GATES NOTHING AUTOMATICALLY ANY MORE. It was the hard gate on the expensive
# half of the training project -- nli_finetuned_model and nli_benchmark_qa_data
# both took it as a required argument -- and both were retired on 2026-10-05.
# Verified 2026-10-07: no target in factcheck depends on it and reporting does
# not declare it. So its stop() could only fail the whole tar_make(), which is
# why the target now carries error = "continue": an unreviewed round is the
# ordinary state between drawing the instruments and getting them back, not a
# pipeline failure.
#
# It is kept because it is now the ONLY thing that can test the decision that
# removed those targets. Every other comparison in this project is models
# judging models.
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

# stop()'s message is truncated at getOption("warning.length"), which defaults to
# 1000 -- against ~2,600 here, so 62% of the guidance was being cut mid-sentence
# and the draw instructions were exactly the part that disappeared.
#
# message() is not truncated, but targets SWALLOWS it when the target errors, and
# erroring through targets is how anyone actually meets this. So raise the limit
# instead (8170 is R's maximum, comfortably above this text) and put the whole
# thing in stop(), restoring the option afterwards so nothing else inherits it.
goldstandard_stop <- function(reason, goldstandard_dir, reviewers) {
  stop(sprintf("%s\n\n%s", reason,
               goldstandard_gate_message(goldstandard_dir, reviewers)), call. = FALSE)
}

build_goldstandard <- function(
  goldstandard_dir = "input/goldstandard",
  reviewers = c("R1", "R2"),
  output_dir = NULL
) {
  if (is.null(output_dir)) output_dir <- goldstandard_dir
  if (!dir.exists(goldstandard_dir)) {
    goldstandard_stop(
      sprintf("build_goldstandard: %s does not exist", goldstandard_dir),
      goldstandard_dir, reviewers
    )
  }

  # Accepts BOTH namings: Rx_<assessment>.csv (v1/v2, one set) and
  # Rx_<assessment>_<set>.csv (v3, sets A and B). The old pattern required
  # exactly one token after the reviewer, so it silently matched nothing once the
  # v3 instruments arrived -- the round would have read as "no reviews" forever
  # while the filled files sat right there.
  #
  # _template.csv is excluded explicitly rather than by token count, because
  # counting tokens is what broke when the set letter was added.
  filled <- list.files(
    goldstandard_dir,
    pattern = sprintf("^(%s)_[^_]+(_[^_]+)?\\.csv$", paste(reviewers, collapse = "|")),
    full.names = TRUE
  )
  filled <- filled[!grepl("_template\\.csv$", filled)]
  if (!length(filled)) {
    goldstandard_stop(
      sprintf("build_goldstandard: no completed reviewer files in %s",
              goldstandard_dir),
      goldstandard_dir, reviewers
    )
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
      # Sets A and B are different populations (citing works vs key papers) and
      # must never be pooled into one kappa: B is ~92% NOT_ENOUGH_INFO by
      # construction, so pooling would drag the agreement baseline and make the
      # combined figure meaningless.
      set = if (length(parts) >= 3L) parts[[3]] else NA_character_,
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
    dplyr::select(assessment, set, id, reviewer_file, verdict) |>
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

  gold <- wide[wide$agreed, c("assessment", "set", "id", "verdict")]
  # CANNOT_JUDGE is a property of the instrument, not of the paper -- both
  # reviewers agreeing that a row is unjudgeable is a real finding about the
  # SAMPLE, worth keeping in the file, but it is not a label any model can be
  # scored against. Flagged here; the benchmark drops it.
  gold$scorable <- gold$verdict != "CANNOT_JUDGE"

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  for (aid in unique(gold$assessment)) {
    for (st in unique(gold$set[gold$assessment == aid])) {
      sel <- gold$assessment == aid & (if (is.na(st)) is.na(gold$set) else
                                       !is.na(gold$set) & gold$set == st)
      utils::write.csv(
        gold[sel, ], file.path(output_dir,
          if (is.na(st)) sprintf("gold_%s.csv", aid) else sprintf("gold_%s_%s.csv", aid, st)),
        row.names = FALSE, na = ""
      )
    }
  }

  # Per-set kappa as well as the pooled figure, for the reason given at parse_one.
  for (st in unique(wide$set)) {
    sel <- both & (if (is.na(st)) is.na(wide$set) else !is.na(wide$set) & wide$set == st)
    if (sum(sel) > 1L) {
      message(sprintf("[goldstandard] set %s: %d double-reviewed | agreement %.1f%% | kappa %.3f",
                      if (is.na(st)) "-" else st, sum(sel),
                      100 * mean(a[sel] == b[sel]), cohens_kappa(a[sel], b[sel])))
    }
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

# What to do next, kept SHORT on purpose.
#
# targets truncates an error message with its own limit, on top of R's
# getOption("warning.length"). A 2,600-char version lost 62% to R and was still
# cut by targets after raising that -- and the draw instructions were the part
# that disappeared both times. So this stays under ~900 characters and the long
# form lives in REVIEWER_GUIDE.md, which is where a reviewer looks anyway.
#
# It leads with whichever step is actually next, because telling someone to
# re-draw when the templates are already sitting there is how a half-finished
# round gets thrown away.
goldstandard_gate_message <- function(goldstandard_dir = "input/goldstandard",
                                      reviewers = c("R1", "R2")) {
  templates <- if (dir.exists(goldstandard_dir)) {
    list.files(goldstandard_dir,
               pattern = sprintf("^(%s)_.*_template\\.csv$", paste(reviewers, collapse = "|")))
  } else character(0)
  # A template with no set letter predates the A/B split and cannot be
  # adjudicated -- gold is written per (assessment, set).
  current <- templates[grepl("^[^_]+_[^_]+_[^_]+_template\\.csv$", templates)]

  draw <- paste(
    "DRAW (by hand -- NOT a target: a target would redraw over reviewer work):",
    "    source(\"R/build_goldstandard_sample.R\")",
    "    build_goldstandard_sample_sets(force = TRUE)   # force only to replace templates",
    "  -> Rx_<id>_A_template.csv  240 citing works, balanced 40 x (3 labels x 2 bands)",
    "     Rx_<id>_B_template.csv  100 key papers, proportional to their own label ratio",
    "  Draw ONLY once the pipeline is final for the scope you want: the sample is",
    "  frozen on write, the pipeline is not.",
    sep = "\n")

  fill <- paste(
    "FILL: each reviewer copies Rx_<id>_<set>_template.csv -> Rx_<id>_<set>.csv and",
    sprintf("  fills `verdict` with one of: %s.", paste(GOLDSTANDARD_VERDICTS, collapse = ", ")),
    "  Both reviewers must do the SAME set. Re-run this target to adjudicate into",
    "  gold_<id>_<set>.csv. Definitions: input/goldstandard/REVIEWER_GUIDE.md",
    sep = "\n")

  head <- if (length(current)) {
    sprintf("Templates are drawn (%s); no filled copy has come back yet.",
            paste(current, collapse = ", "))
  } else if (length(templates)) {
    sprintf("Found template(s) from BEFORE the A/B split (%s) -- these cannot be\nadjudicated. Re-draw with force = TRUE.",
            paste(templates, collapse = ", "))
  } else {
    "No templates have been drawn yet."
  }

  body <- if (length(current)) paste(fill, "", draw, sep = "\n")
          else paste(draw, "", fill, sep = "\n")
  paste(head, "", body, sep = "\n")
}
