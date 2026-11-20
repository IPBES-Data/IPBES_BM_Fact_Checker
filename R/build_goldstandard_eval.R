# Scores Jev stage 1, Phase 2 and the combined pipeline against the human
# labels. Hand-run, like build_goldstandard_sample.R. Free: it only reads what
# is already on disk (manifests, reviewer files, Phase 2 output).
#
# Weighting: every row carries w = 1/p_include from its sample manifest, so
# precision/recall are corpus-level estimates rather than sample-level ones.
# Set A is balanced (40 per stage-1 cell), so UNWEIGHTED figures would describe
# the sample's design, not the corpus.
#
# References are scored three ways: `gold` (agreement only, the pre-registered
# rule), and each reviewer alone. The reviewers differ systematically in how
# much an abstract must show before it SUPPORTS (R1 102 vs R2 35 in set A), so
# a model's figures against gold alone would hide which standard it matches.
# Caveat: gold drops disagreed rows, which are not missing at random (they are
# mostly the hard SUPPORTS/NEI boundary), so figures against gold are optimistic.
#
# The pipeline's final call: SUPPORTS/REFUTES only when stage 1 routed the pair
# (label certain) AND Phase 2 agreed; NOT_ENOUGH_INFO otherwise. Unrouted pairs
# are NEI by construction, which is exactly what the 160 unrouted rows of set A
# measure the recall cost of. Key papers (set B) are not routed: Phase 2's
# verdict is final for every one.
#
# Read n_hit next to every rate. Weights are huge on the NEI stratum (~99% of
# the corpus), so ONE human REFUTES among stage-1 NEI rows outweighs every
# REFUTES stage 1 caught, and recall swings from 1.00 to ~0 on a handful of rows.

goldstandard_eval <- function(goldstandard_dir = "input/goldstandard",
                              llm_scores = "output/factchecker/llm_verification/scores/llm_config=openrouter_cheap",
                              assessment = "GA1") {
  # Adjudicate into a temp dir: goldstandard_dir is a format = "file" input in
  # reporting, and writing gold_*.csv into it would change its own hash every run.
  g <- build_goldstandard(goldstandard_dir, output_dir = tempfile("gold_"))
  man <- dplyr::bind_rows(lapply(
    list.files(goldstandard_dir, sprintf("^sample_manifest_%s_[^_]+\\.csv$", assessment), full.names = TRUE),
    utils::read.csv, stringsAsFactors = FALSE))

  llm <- arrow::open_dataset(llm_scores) |>
    dplyr::filter(assessment == !!assessment) |>
    dplyr::select(keypaper, km, bm, claim_id, work_id, llm_label, llm_agrees) |>
    dplyr::collect() |>
    dplyr::mutate(keypaper = as.logical(keypaper)) |>
    dplyr::distinct(keypaper, km, bm, claim_id, work_id, .keep_all = TRUE)

  d <- man |>
    dplyr::inner_join(dplyr::select(g$reviews, id, R1, R2, gold = verdict), by = "id") |>
    dplyr::left_join(llm, by = c("keypaper", "km", "bm", "claim_id", "work_id")) |>
    dplyr::mutate(
      w = 1 / p_include,
      routed = jev_label %in% c("SUPPORTS", "REFUTES") & !jev_uncertain,
      # Key papers skip routing: Phase 2 reviews every one, so its verdict IS
      # the final call there.
      pipeline = dplyr::case_when(
        keypaper ~ llm_label,
        routed & llm_agrees %in% TRUE ~ jev_label,
        TRUE ~ "NOT_ENOUGH_INFO")
    )
  if (any(d$routed & is.na(d$llm_label))) {
    warning(sprintf("%d routed row(s) have no Phase 2 verdict on disk",
                    sum(d$routed & is.na(d$llm_label))))
  }

  # One reference x one predictor x one label. CANNOT_JUDGE and NA reference
  # rows are not scorable; NA predictions (Phase 2 on unrouted rows) are dropped,
  # so the phase2 rows describe the routed subset only.
  score <- function(dd, pred, ref) {
    dd <- dd[!is.na(dd[[ref]]) & dd[[ref]] != "CANNOT_JUDGE" & !is.na(dd[[pred]]), ]
    p <- dd[[pred]]; r <- dd[[ref]]; w <- dd$w
    do.call(rbind, lapply(c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO"), function(L) data.frame(
      set = dd$set[1], predictor = pred, reference = ref, label = L, n = nrow(dd),
      n_pred = sum(p == L), n_ref = sum(r == L), n_hit = sum(p == L & r == L),
      precision = sum(w[p == L & r == L]) / sum(w[p == L]),
      recall = sum(w[p == L & r == L]) / sum(w[r == L]))))
  }
  res <- do.call(rbind, lapply(split(d, d$set), function(dd)
    do.call(rbind, lapply(c("jev_label", "llm_label", "pipeline"), function(pr)
      do.call(rbind, lapply(c("gold", "R1", "R2"), function(rf) score(dd, pr, rf)))))))
  res$predictor <- c(jev_label = "jev_stage1", llm_label = "phase2_routed", pipeline = "pipeline")[res$predictor]
  # Per-reviewer kappa and agreement per set, for the report's header table.
  agreement <- do.call(rbind, lapply(split(g$reviews, g$reviews$set), function(w) {
    both <- !is.na(w$R1) & !is.na(w$R2)
    data.frame(set = w$set[1], n = sum(both), agreement = mean(w$R1[both] == w$R2[both]),
               kappa = cohens_kappa(w$R1[both], w$R2[both]), n_gold = sum(w$agreed),
               n_scorable = sum(w$agreed & w$verdict != "CANNOT_JUDGE"))
  }))
  # Human-vs-human against model-vs-human, same rows, so the model's agreement
  # is read against the ceiling the humans set. Unweighted on purpose: this is
  # a like-for-like comparison on the sample, not a corpus estimate. Rows either
  # reviewer marked CANNOT_JUDGE are dropped for every pair alike.
  # ponytail: percentile bootstrap, 2000 reps; fine at n ~ 80-220.
  kpairs <- list(c("R1", "R2"), c("jev_label", "R1"), c("jev_label", "R2"),
                 c("llm_label", "R1"), c("llm_label", "R2"),
                 c("pipeline", "R1"), c("pipeline", "R2"))
  set.seed(20261120)
  subsets <- list(
    "A: all" = d$set == "A", "A: routed" = d$set == "A" & d$routed,
    "A: not routed" = d$set == "A" & !d$routed, "B: all" = d$set == "B")
  kappas <- do.call(rbind, lapply(names(subsets), function(s) {
    dd <- d[subsets[[s]] & !is.na(d$R1) & !is.na(d$R2) &
              d$R1 != "CANNOT_JUDGE" & d$R2 != "CANNOT_JUDGE", ]
    do.call(rbind, lapply(kpairs, function(p) {
      x <- dd[[p[1]]]; y <- dd[[p[2]]]; ok <- !is.na(x) & !is.na(y); x <- x[ok]; y <- y[ok]
      # Phase 2 exists only on routed rows in A, so "A: all" would repeat "A: routed".
      if (length(x) < 10L || (p[1] == "llm_label" && s == "A: all")) return(NULL)
      b <- replicate(2000, { i <- sample(length(x), replace = TRUE); cohens_kappa(x[i], y[i]) })
      data.frame(subset = s, rater = p[1], reviewer = p[2], n = length(x),
                 agreement = mean(x == y), kappa = cohens_kappa(x, y),
                 lo = stats::quantile(b, .025, na.rm = TRUE, names = FALSE),
                 hi = stats::quantile(b, .975, na.rm = TRUE, names = FALSE))
    }))
  }))
  kappas$rater <- c(R1 = "R1 (human)", jev_label = "Jev stage 1", llm_label = "Phase 2",
                    pipeline = "Pipeline")[kappas$rater]

  # Reviewer notes, for the guide-contradiction section: how many SUPPORTS
  # verdicts carry a note saying the support was partial or scope-limited.
  notes <- dplyr::bind_rows(lapply(
    list.files(goldstandard_dir, sprintf("^R[12]_%s_[^_]+\\.xlsx$", assessment), full.names = TRUE),
    function(f) {
      x <- openxlsx::read.xlsx(f, sheet = "Review", na.strings = c("", "NA"))
      p <- strsplit(sub("\\.xlsx$", "", basename(f)), "_")[[1]]
      data.frame(reviewer = p[1], set = p[3], id = as.character(x$id),
                 verdict = x$verdict, note = if ("note" %in% names(x)) x$note else NA)
    }))
  notes$partial <- grepl("\\bpart\\b|\\bpartial|\\bonly\\b|\\bthough\\b|\\bbut\\b|\\bnot\\b",
                         notes$note, ignore.case = TRUE)

  list(rows = d, metrics = dplyr::as_tibble(res), agreement = agreement,
       kappas = dplyr::as_tibble(kappas), notes = dplyr::as_tibble(notes), kappa = g$kappa)
}
