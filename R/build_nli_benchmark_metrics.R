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

build_nli_benchmark_metrics <- function(
  score_paths,
  training_data_path = "output/nli_training",
  nli_active = NULL,
  benchmark_config = NULL,
  output_path = "output/tables/nli_benchmark_qa.rds"
) {
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

  # --- per-class precision / recall / F1 ------------------------------------
  per_class <- scores |>
    dplyr::group_by(model) |>
    dplyr::group_modify(~ prf(.x$label, .x$pred_label, labels)) |>
    dplyr::ungroup()

  confusion <- scores |> dplyr::count(model, label, pred_label, name = "n")

  # --- THE headline: SUPPORTS -> REFUTES recovery ---------------------------
  #
  # 60% of every confirmed refutation in this corpus is a pair the zero-shot
  # model called SUPPORTS and the LLM overturned -- it did not merely miss
  # them, it got them backwards. So the question that decides whether
  # fine-tuning did this project's job is: of the holdout rows where NLI said
  # SUPPORTS and the truth is REFUTES, how many does each model now call
  # REFUTES? A checkpoint that does not move this has not earned deployment,
  # whatever its macro-F1 says.
  flip_subset <- scores |> dplyr::filter(nli_label == "SUPPORTS", label == "REFUTES")
  flip <- flip_subset |>
    dplyr::group_by(model) |>
    dplyr::summarise(
      n_subset = dplyr::n(),
      n_recovered = sum(pred_label == "REFUTES"),
      recovery_rate = mean(pred_label == "REFUTES"),
      .groups = "drop"
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

  shared_claims <- pool |> dplyr::distinct(split, hypothesis) |>
    dplyr::count(hypothesis) |> dplyr::filter(n > 1) |> nrow()
  shared_works <- pool |> dplyr::distinct(split, work_id) |>
    dplyr::count(work_id) |> dplyr::filter(n > 1) |> dplyr::pull(work_id)
  test_pool <- pool |> dplyr::filter(split == "test")

  fold_summary <- list(
    salt = benchmark_config$salt,
    holdout_fraction = benchmark_config$holdout_fraction,
    group_key = "assessment + bm (km deliberately omitted -- one BM spans several KMs)",
    n_train = sum(pool$split == "train"),
    n_test = nrow(test_pool),
    n_groups_train = nrow(dplyr::distinct(dplyr::filter(pool, split == "train"), assessment, bm)),
    n_groups_test = nrow(dplyr::distinct(test_pool, assessment, bm)),
    label_counts = pool |> dplyr::count(split, label),
    # Must be 0. If it is ever not, the grouping key has drifted.
    claims_in_both_folds = shared_claims,
    works_in_both_folds = length(shared_works),
    works_total = dplyr::n_distinct(pool$work_id),
    test_rows_with_shared_work = sum(test_pool$work_id %in% shared_works)
  )

  out <- list(
    generated_at = Sys.time(),
    nli_config = nli_active,
    fold = fold_summary,
    models = meta,
    per_class = per_class,
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
    "[nli_benchmark_metrics] %d models x %d holdout rows -> %s",
    nrow(meta), fold_summary$n_test, output_path
  ))
  output_path
}
