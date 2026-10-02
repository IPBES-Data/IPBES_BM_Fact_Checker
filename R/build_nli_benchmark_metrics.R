# Benchmark metrics across every scored model (TD_NLI_training.qmd).
#
# Sibling to the other QA data builders (build_nli_scores_qa_data.R,
# build_llm_verification_qa_data.R): reads what is already on disk, computes
# everything the report needs, and caches ONE rds -- the qmd renders in a fresh
# session that never sources R/*.R, so nothing here can be deferred to it.
#
# The default classification_report headline is deliberately NOT the centrepiece:
#
#   * Accuracy is excluded outright. After --downsample-seed the training fold is
#     balanced three ways and the holdout is near-balanced; deployment is 0.2-3%
#     REFUTES. A balanced-set accuracy flatters every model equally and predicts
#     nothing about the real stream.
#   * REFUTES precision and recall are reported SEPARATELY, never folded into F1
#     for the headline. The project's tolerance for the two errors is not
#     symmetric -- a missed refutation is a finding that never surfaces, a false
#     one is a claim a human discards in seconds -- and F1 assumes it is.
#   * The primary number is the SUPPORTS->REFUTES recovery rate (see below).

# Per-class precision/recall/F1 without bringing in a modelling package for
# three lines of counting.
prf <- function(truth, pred, labels) {
  do.call(rbind, lapply(labels, function(l) {
    tp <- sum(pred == l & truth == l)
    fp <- sum(pred == l & truth != l)
    fn <- sum(pred != l & truth == l)
    precision <- if (tp + fp > 0) tp / (tp + fp) else NA_real_
    recall    <- if (tp + fn > 0) tp / (tp + fn) else NA_real_
    f1 <- if (!is.na(precision) && !is.na(recall) && precision + recall > 0) {
      2 * precision * recall / (precision + recall)
    } else NA_real_
    data.frame(label = l, precision = precision, recall = recall, f1 = f1,
               support = sum(truth == l), stringsAsFactors = FALSE)
  }))
}

# Percentile bootstrap CI for each per-class figure. Worth the lines: with ~80
# REFUTES rows in a human-labelled holdout an F1 of 0.60 carries roughly +/-0.15,
# so two models differing by 0.05 are indistinguishable -- and a point estimate
# alone invites reading that difference as a result.
prf_boot <- function(truth, pred, labels, B = 1000L, seed = 1L) {
  n <- length(truth)
  if (n < 2L) return(NULL)
  set.seed(seed)
  draws <- lapply(seq_len(B), function(b) {
    i <- sample.int(n, n, replace = TRUE)
    prf(truth[i], pred[i], labels)
  })
  all <- do.call(rbind, draws)
  stats <- do.call(rbind, lapply(labels, function(l) {
    d <- all[all$label == l, ]
    q <- function(v) stats::quantile(v, c(0.025, 0.975), na.rm = TRUE)
    data.frame(
      label = l,
      precision_lo = q(d$precision)[[1]], precision_hi = q(d$precision)[[2]],
      recall_lo    = q(d$recall)[[1]],    recall_hi    = q(d$recall)[[2]],
      f1_lo        = q(d$f1)[[1]],        f1_hi        = q(d$f1)[[2]],
      stringsAsFactors = FALSE
    )
  }))
  stats
}

build_nli_benchmark_metrics <- function(
  score_paths,
  training_data_path = "output/nli_training",
  nli_active = NULL,
  benchmark_config = NULL,
  # The human labels, as returned by build_goldstandard(). REQUIRED: without
  # them every table below measures agreement with gpt-4o-mini, and a model that
  # perfectly reproduced a wrong judge would score perfectly. That is the
  # failure this benchmark exists to detect, so making the reference optional
  # would defeat it.
  goldstandard = NULL,
  bootstrap_B = 1000L,
  output_path = "output/tables/nli_benchmark_qa.rds"
) {
  if (is.null(goldstandard) || !nrow(goldstandard$gold)) {
    stop(
      "build_nli_benchmark_metrics: no gold standard -- refusing to report model scores.\n",
      goldstandard_gate_message()
    )
  }
  labels <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")

  scores <- dplyr::bind_rows(lapply(score_paths, arrow::read_parquet))
  if (!nrow(scores)) stop("no benchmark scores found -- build benchmark_scores first")

  # --- per-model provenance -------------------------------------------------
  #
  # split_aware is the single most important column here. A checkpoint trained
  # BEFORE the holdout existed was trained on rows drawn from the whole pool --
  # including what is now the test fold -- so its score on that fold is recall
  # on memorised rows, not generalisation. Measured on the two pre-split runs:
  # the larger used 558 of the corpus's 562 REFUTES rows, so ~169 of the test
  # fold's 170 were in its training data, and it duly posts the best numbers in
  # the table. Detected from run_results.json's `holdout` key, which only runs
  # made after the split was implemented write.
  #
  # This is flagged rather than filtered: the contaminated runs are exactly the
  # evidence for how badly a leaking split flatters a model, which is the
  # finding that motivated the benchmark. But nothing should ever read that
  # table as a ranking without this column next to it.
  split_aware_of <- function(model) {
    if (!dir.exists(model)) return(NA)          # the zero-shot baseline: untrained
    rr <- file.path(dirname(model), "run_results.json")
    if (!file.exists(rr)) return(NA)
    "holdout" %in% names(jsonlite::fromJSON(rr))
  }

  meta <- scores |>
    dplyr::group_by(model) |>
    dplyr::summarise(
      model_id = nli_benchmark_model_id(dplyr::first(model)),
      mode = dplyr::first(mode), max_length = dplyr::first(max_length),
      n_truncated = dplyr::first(n_truncated), n_rows = dplyr::n(),
      .groups = "drop"
    ) |>
    dplyr::mutate(split_aware = vapply(model, split_aware_of, logical(1)))

  # --- the human reference --------------------------------------------------
  #
  # Two references, computed over the same tables so the gap between them is
  # readable at a glance:
  #   reference = "llm"   -- truth is `label`, i.e. gpt-4o-mini's Phase 2 verdict.
  #                          This is what every earlier benchmark reported, and
  #                          it measures FIDELITY TO THE JUDGE, not correctness.
  #   reference = "human" -- truth is the adjudicated reviewer verdict. This is
  #                          the one to quote.
  gold <- goldstandard$gold
  gold <- gold[gold$scorable, c("id", "verdict")]

  # Stratum inclusion probabilities, written by build_goldstandard_sample().
  #
  # BOTH precision AND recall are biased here, and an earlier version of this
  # file claimed recall was not. The claim would hold if the sample were
  # stratified on the TRUE label; it is stratified on the LLM's label, which is
  # the very thing under question -- and every NLI model scored here was
  # distilled from that same LLM, so its predictions correlate with the
  # stratification variable. Within a truth class the sample is therefore
  # skewed toward rows the LLM labelled one particular way, which moves recall.
  #
  # Measured on the real GA1 sample, gpt-4o-mini's SUPPORTS recall: 40.4%
  # unweighted against 75.4% inverse-probability weighted. That is a different
  # conclusion, not a rounding difference.
  #
  # Between-model RANKING on identical rows is still fine unweighted; any
  # corpus-level RATE is not.
  manifest <- {
    f <- list.files(goldstandard$dir, pattern = "^sample_manifest_.*\\.csv$", full.names = TRUE)
    if (length(f)) {
      m <- dplyr::bind_rows(lapply(f, utils::read.csv, stringsAsFactors = FALSE))
      m[, intersect(c("id", "stratum", "p_include"), names(m)), drop = FALSE]
    } else NULL
  }

  # Under human truth, gpt-4o-mini stops being the reference and becomes just
  # another predictor -- so it gets per-class precision/recall/F1 for the first
  # time, on the same rows as every NLI model. Its prediction IS `label`.
  judge_model <- benchmark_config$judge_label %||% "gpt-4o-mini (Phase 2 judge)"
  judge_rows <- scores |>
    dplyr::filter(model == dplyr::first(model)) |>
    dplyr::mutate(model = judge_model, pred_label = label,
                  p_refutes = NA_real_, p_supports = NA_real_, p_nei = NA_real_)

  scored_human <- dplyr::bind_rows(scores, judge_rows) |>
    dplyr::inner_join(gold, by = "id") |>
    dplyr::rename(truth_human = verdict)

  n_gold_matched <- dplyr::n_distinct(scored_human$id)
  if (!n_gold_matched) {
    stop(
      "build_nli_benchmark_metrics: none of the gold standard's ids appear in the benchmark scores. ",
      "The gold sample must be drawn from the SAME (granularity, nli_config, split) slot the ",
      "benchmark scores -- see R/build_goldstandard_sample.R."
    )
  }
  if (!is.null(manifest)) {
    scored_human <- dplyr::left_join(scored_human, manifest, by = "id")

    # A stratum that was DRAWN but has no matched row is not a class the models
    # got wrong -- it is a class they were never scored on, and it shows up as a
    # flat 0% recall that reads like a finding. Weighting cannot repair it
    # either: there is no sampled row to carry the weight.
    #
    # The usual cause is stale benchmark scores. Changing which rows are in the
    # training set (the negatives are selected by hash, so any change to the
    # positive count reshuffles them) leaves previously scored ids that no
    # longer exist and new ids never scored. Re-run benchmark_scores.
    drawn <- sort(unique(manifest$stratum))
    matched <- sort(unique(stats::na.omit(scored_human$stratum)))
    missing_strata <- setdiff(drawn, matched)
    if (length(missing_strata)) {
      warning(sprintf(
        paste0("build_nli_benchmark_metrics: stratum/strata %s were drawn for review but have ",
               "NO matched rows in the benchmark scores. Their per-class rates are undefined, ",
               "not zero, and weighting cannot fix it. Re-run benchmark_scores against the ",
               "current nli_training_data."),
        paste(sQuote(missing_strata), collapse = ", ")
      ), call. = FALSE)
    }
  }

  # --- per-class precision / recall / F1, both references -------------------
  per_class_for <- function(d, truth_col, reference) {
    d |>
      dplyr::group_by(model) |>
      dplyr::group_modify(~ {
        est <- prf(.x[[truth_col]], .x$pred_label, labels)
        ci <- prf_boot(.x[[truth_col]], .x$pred_label, labels, B = bootstrap_B)
        if (is.null(ci)) est else dplyr::left_join(est, ci, by = "label")
      }) |>
      dplyr::ungroup() |>
      dplyr::mutate(reference = reference, .before = 1)
  }

  per_class <- dplyr::bind_rows(
    per_class_for(scores, "label", "llm"),
    per_class_for(scored_human, "truth_human", "human")
  )

  # Inverse-inclusion-probability weighted precision, RECALL and F1, human
  # reference only -- the correction is only meaningful against a truth the
  # sample was stratified away from. These are the corpus-level numbers to
  # quote; the unweighted per_class table above describes the SAMPLE, which is
  # deliberately not representative.
  #
  # `support_weighted` is each class's estimated share of the holdout, so a
  # class whose weighted support is tiny is one the sample barely saw -- read
  # its rates with that in mind rather than as precise estimates.
  per_class_weighted <- if (!is.null(manifest) && "p_include" %in% names(scored_human)) {
    scored_human |>
      dplyr::filter(!is.na(p_include), p_include > 0) |>
      dplyr::group_by(model) |>
      dplyr::group_modify(~ do.call(rbind, lapply(labels, function(l) {
        w <- 1 / .x$p_include
        flagged <- .x$pred_label == l
        actual <- .x$truth_human == l
        prec <- if (sum(w[flagged]) > 0) sum(w[flagged & actual]) / sum(w[flagged]) else NA_real_
        rec  <- if (sum(w[actual])  > 0) sum(w[flagged & actual]) / sum(w[actual])  else NA_real_
        f1 <- if (!is.na(prec) && !is.na(rec) && prec + rec > 0) {
          2 * prec * rec / (prec + rec)
        } else NA_real_
        data.frame(
          label = l,
          precision_weighted = prec,
          recall_weighted = rec,
          f1_weighted = f1,
          support_weighted = sum(w[actual]),
          stringsAsFactors = FALSE
        )
      }))) |>
      dplyr::ungroup()
  } else NULL

  confusion <- dplyr::bind_rows(
    scores |> dplyr::count(model, label, pred_label, name = "n") |>
      dplyr::mutate(reference = "llm", truth = label, .before = 1) |>
      dplyr::select(-label),
    scored_human |> dplyr::count(model, truth_human, pred_label, name = "n") |>
      dplyr::mutate(reference = "human", .before = 1) |>
      dplyr::rename(truth = truth_human)
  )

  # --- agreement matrix, including the human ceiling ------------------------
  #
  # R1 vs R2 is the ceiling: no model should be expected to agree with the gold
  # standard more often than two domain experts agreed with each other. Every
  # per-class figure above is read against it.
  pairwise <- function(x, y, lab) {
    ok <- !is.na(x) & !is.na(y)
    data.frame(
      pair = lab, n = sum(ok),
      agreement = if (any(ok)) mean(x[ok] == y[ok]) else NA_real_,
      kappa = cohens_kappa(x[ok], y[ok]),
      stringsAsFactors = FALSE
    )
  }
  agreement <- dplyr::bind_rows(
    data.frame(
      pair = "R1 vs R2 (human ceiling)",
      n = goldstandard$n_double_reviewed,
      agreement = goldstandard$raw_agreement,
      kappa = goldstandard$kappa,
      stringsAsFactors = FALSE
    ),
    dplyr::bind_rows(lapply(split(scored_human, scored_human$model), function(d) {
      dplyr::bind_rows(
        pairwise(d$truth_human, d$pred_label, sprintf("human vs %s", d$model[[1]])),
        pairwise(d$label, d$pred_label, sprintf("llm vs %s", d$model[[1]]))
      )
    }))
  )

  # --- THE headline: SUPPORTS -> REFUTES recovery ---------------------------
  #
  # 60% of every confirmed refutation in this corpus is a pair the zero-shot
  # model called SUPPORTS and the LLM overturned -- it did not merely miss
  # them, it got them backwards. So the question that decides whether
  # fine-tuning did this project's job is: of the holdout rows where NLI said
  # SUPPORTS and the truth is REFUTES, how many does each model now call
  # REFUTES? A checkpoint that does not move this has not earned deployment,
  # whatever its macro-F1 says.
  recovery <- function(d, truth_col, reference) {
    d |>
      dplyr::filter(nli_label == "SUPPORTS", .data[[truth_col]] == "REFUTES") |>
      dplyr::group_by(model) |>
      dplyr::summarise(
        reference = reference,
        n_subset = dplyr::n(),
        n_recovered = sum(pred_label == "REFUTES"),
        recovery_rate = mean(pred_label == "REFUTES"),
        .groups = "drop"
      )
  }
  # Computed under BOTH references. Under "llm" the subset is "the LLM
  # overturned NLI"; under "human" it is "a reviewer overturned NLI", which is
  # the version that actually answers whether fine-tuning did this project's
  # job -- the LLM-referenced one can only ever reward reproducing the judge's
  # own overturns, right or wrong.
  flip <- dplyr::bind_rows(
    recovery(scores, "label", "llm"),
    recovery(scored_human, "truth_human", "human")
  )

  # --- threshold sweep ------------------------------------------------------
  #
  # Phase 1 stores the full probability distribution and every threshold
  # decision is made downstream in dplyr, so a single argmax operating point
  # would describe neither the model nor the deployment. Framed as a REFUTES
  # detector (predict REFUTES iff p_refutes >= t), which is what the pipeline
  # actually uses these scores for, and which also yields the re-calibrated
  # deployment threshold a balanced-set argmax cannot.
  thresholds <- seq(0.05, 0.95, by = 0.05)
  threshold_sweep <- dplyr::bind_rows(lapply(thresholds, function(t) {
    scores |>
      dplyr::group_by(model) |>
      dplyr::summarise(
        threshold = t,
        n_flagged = sum(p_refutes >= t),
        precision = ifelse(sum(p_refutes >= t) > 0,
                           sum(p_refutes >= t & label == "REFUTES") / sum(p_refutes >= t), NA_real_),
        recall    = sum(p_refutes >= t & label == "REFUTES") / sum(label == "REFUTES"),
        .groups = "drop"
      )
  }))

  # --- per assessment -------------------------------------------------------
  #
  # 558 of 562 REFUTES in the pool come from GA1 and IAS, so a pooled number
  # mostly measures those two. TCA and VA are reported separately even though
  # their counts are tiny: "we cannot tell" is a legitimate result.
  by_assessment <- scores |>
    dplyr::group_by(model, assessment) |>
    dplyr::summarise(
      n = dplyr::n(),
      n_refutes = sum(label == "REFUTES"),
      refutes_recall = ifelse(sum(label == "REFUTES") > 0,
                              sum(pred_label == "REFUTES" & label == "REFUTES") / sum(label == "REFUTES"), NA_real_),
      refutes_precision = ifelse(sum(pred_label == "REFUTES") > 0,
                                 sum(pred_label == "REFUTES" & label == "REFUTES") / sum(pred_label == "REFUTES"), NA_real_),
      .groups = "drop"
    )

  # --- fold composition + the leakage diagnostics ---------------------------
  #
  # Reported, not hidden: the BM-level grouping blocks claim-text leakage
  # completely (verified: zero claims in both folds), but a work cited under
  # several BMs can still appear on both sides paired with DIFFERENT claims.
  # That is much weaker -- the model sees the premise, never the pair or its
  # label -- and closing it needs a connected-component split that at this size
  # yields few huge unbalanced components, trading a small measurable bias for
  # a large unmeasurable one. So it is quantified instead.
  pool <- arrow::open_dataset(training_data_path) |> dplyr::collect()
  if (!is.null(nli_active)) pool <- pool |> dplyr::filter(nli_config == nli_active)

  # Leakage is now checked across THREE folds, not two -- `monitor` matters as
  # much as `holdout`: it is what the fine-tune selects its best checkpoint on,
  # so a claim shared between train and monitor flatters early stopping just as
  # one shared with holdout flatters the benchmark.
  shared_claims <- pool |> dplyr::distinct(split, hypothesis) |>
    dplyr::count(hypothesis) |> dplyr::filter(n > 1) |> nrow()
  shared_works <- pool |> dplyr::distinct(split, work_id) |>
    dplyr::count(work_id) |> dplyr::filter(n > 1) |> dplyr::pull(work_id)
  holdout_pool <- pool |> dplyr::filter(split == "holdout")

  n_groups <- function(x) nrow(dplyr::distinct(x, assessment, bm))
  fold_summary <- list(
    salt = benchmark_config$salt,
    holdout_fraction = benchmark_config$holdout_fraction,
    monitor_fraction = benchmark_config$monitor_fraction,
    group_key = "assessment + bm (km deliberately omitted -- one BM spans several KMs)",
    n_train = sum(pool$split == "train"),
    n_monitor = sum(pool$split == "monitor"),
    n_holdout = nrow(holdout_pool),
    n_groups_train = n_groups(dplyr::filter(pool, split == "train")),
    n_groups_monitor = n_groups(dplyr::filter(pool, split == "monitor")),
    n_groups_holdout = n_groups(holdout_pool),
    label_counts = pool |> dplyr::count(split, label),
    # Must be 0, across all three folds. If it is ever not, the grouping key
    # has drifted.
    claims_in_both_folds = shared_claims,
    works_in_both_folds = length(shared_works),
    works_total = dplyr::n_distinct(pool$work_id),
    holdout_rows_with_shared_work = sum(holdout_pool$work_id %in% shared_works),
    # How much of the holdout a human has actually labelled. Every
    # human-referenced figure rests on this many rows, and nothing else.
    n_gold = nrow(gold),
    n_gold_matched = n_gold_matched
  )

  out <- list(
    generated_at = Sys.time(),
    nli_config = nli_active,
    fold = fold_summary,
    models = meta,
    per_class = per_class,
    per_class_weighted = per_class_weighted,
    agreement = agreement,
    human_ceiling = list(
      kappa = goldstandard$kappa,
      raw_agreement = goldstandard$raw_agreement,
      n_double_reviewed = goldstandard$n_double_reviewed,
      n_disagreements = nrow(goldstandard$disagreements)
    ),
    scores_human = scored_human,
    confusion = confusion,
    flip = flip,
    threshold_sweep = threshold_sweep,
    by_assessment = by_assessment,
    # Kept so the report can show examples without re-reading the parquets.
    scores = scores
  )

  dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
  saveRDS(out, output_path)
  message(sprintf(
    "[nli_benchmark_metrics] %d models x %d holdout rows (%d human-labelled, kappa %.3f) -> %s",
    nrow(meta), fold_summary$n_holdout, n_gold_matched, goldstandard$kappa, output_path
  ))
  output_path
}
