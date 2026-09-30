# Compare a second LLM judge against the one that produced the training labels.
#
#   Rscript scripts/benchmark/compare_llm_judge.R [N]        # default 200 pairs
#
# WHY: every number in this project measures agreement with gpt-4o-mini --
# Phase 2's verdicts are the training labels, and the benchmark scores how well
# the fine-tuned NLI model reproduces them. If that judge is systematically
# wrong, the whole chain inherits it and no amount of held-out discipline shows
# it. ~95% of its verdicts are NOT_ENOUGH_INFO; whether that is caution or the
# truth about abstracts is unmeasured.
#
# This runs TypeSafe's Jev over pairs gpt-4o-mini has already labelled and
# reports where they disagree. Jev is a "decisions" model: it answers typed
# questions with calibrated per-option probabilities rather than free text.
#
# WHAT JEV CANNOT DO, and why this is a comparison rather than a replacement:
# the decisions API (POST /api/alpha/decisions) offers boolean, choice and
# score questions only -- there is no free-text output, so it cannot return the
# verbatim quote that quote_is_verbatim() checks. That check demoted 36 verdicts
# in the GA1 key-paper run alone. Swapping it in wholesale would trade a
# VERIFIED anti-hallucination guarantee for an ASSERTED one.
#
# Where it could earn a place instead: a cheap first pass over the ~1.23M
# NOT_ENOUGH_INFO pairs nobody has ever reviewed, with whatever it flags sent to
# a quoting LLM for grounded confirmation. Its calibrated probabilities are the
# right shape for that, and this script measures whether they are trustworthy
# enough to route on.
suppressMessages({library(dplyr); library(arrow); library(httr2); library(jsonlite)})

n_pairs <- as.integer(commandArgs(trailingOnly = TRUE)[1] %||% "200")
if (is.na(n_pairs)) n_pairs <- 200L
model <- "typesafe/jev-1.13"
out_path <- "output/tables/llm_judge_comparison.parquet"

key <- keyring::key_get("API_openrouter")

# The model that produced the labels being compared against. Read from config
# rather than hardcoded, so the table says what it actually measured -- the
# reference is a CHOICE, not a constant, and a later re-run under a different
# llm_verification config must not silently look like this one.
cfg <- yaml::read_yaml("input/config.yaml")
reference_model <- cfg$llm_verification$configs[[cfg$training$llm]]$model

# Stratified, not random: REFUTES is ~0.5% of verdicts, so a uniform sample of
# 200 would contain one or two and say nothing about the class that matters.
# Equal draws per label, reweighted at read time if a corpus-level estimate is
# ever wanted.
pool <- open_dataset("output/nli_training") |> collect() |>
  filter(!is.na(abstract), nchar(abstract) > 200)
set.seed(13)
sample_df <- pool |> group_by(label) |> slice_sample(n = ceiling(n_pairs / 3)) |> ungroup()

cat(sprintf("comparing %d pairs against %s\n", nrow(sample_df), model))
print(as.data.frame(count(sample_df, label)))

ask_jev <- function(claim, premise) {
  body <- list(
    model = model,
    state = list(claim = claim, premise = premise),
    questions = list(
      # RELEVANCE SCREEN, asked alongside the verdict in the same request.
      #
      # Reading the disagreements showed gpt-4o-mini labelling REFUTES on papers
      # that are merely ADJACENT to the claim -- flow regulation and exotic
      # invasion against a claim about climate change driving invasion spread --
      # rather than contradicting it. quote_is_verbatim() cannot catch that: the
      # quote is genuinely present, it just does not bear on the claim.
      #
      # If this separates such pairs cheaply, it belongs BEFORE the expensive
      # quoting LLM: fewer pairs reviewed and fewer spurious REFUTES produced.
      # What would disqualify it is scoring low on real SUPPORTS -- a screen
      # that discards genuine findings is worse than a noisy label.
      addresses = list(
        type = "noul",
        instructions = paste(
          "Does the paper address the specific subject of the claim closely",
          "enough that its findings bear on whether the claim is true?"
        ),
        criteria = list(
          "true"  = "the paper studies the same phenomenon, taxa, driver or region the claim is about, and its findings speak to the claim",
          "false" = "the paper is about a related but different topic, so its findings cannot settle the claim either way"
        )
      ),
      verdict = list(
      type = "choice",
      instructions = paste(
        "Does the paper (premise) support or refute the claim?",
        "Judge ONLY from the premise text, not from background knowledge."
      ),
      criteria = list(
        SUPPORTS        = "The premise provides evidence that the claim is true.",
        REFUTES         = "The premise provides evidence that the claim is false.",
        NOT_ENOUGH_INFO = "The premise does not contain enough information to judge the claim."
      )
    ))
  )
  resp <- request("https://openrouter.ai/api/alpha/decisions") |>
    req_auth_bearer_token(key) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_retry(max_tries = 3) |>
    req_perform()
  j <- resp_body_json(resp)
  a <- j$answers$verdict
  list(
    addresses = j$answers$addresses$noul %||% NA_real_,
    # j$model is the RESOLVED id (e.g. typesafe/jev-1.13-20260917), which is
    # more specific than the one requested -- worth keeping, since a dated
    # build is what the numbers actually describe.
    judge_model = j$model %||% model,
    choice = a$choice,
    p_supports = a$probabilities$SUPPORTS %||% NA_real_,
    p_refutes  = a$probabilities$REFUTES %||% NA_real_,
    p_nei      = a$probabilities$NOT_ENOUGH_INFO %||% NA_real_,
    confidence = a$confidence %||% NA_real_,
    cost       = j$usage$cost %||% NA_real_
  )
}

res <- vector("list", nrow(sample_df))
for (i in seq_len(nrow(sample_df))) {
  r <- sample_df[i, ]
  res[[i]] <- tryCatch(
    ask_jev(r$hypothesis, paste0(r$title, ". ", r$abstract)),
    error = function(e) list(choice = NA_character_, p_supports = NA_real_,
                             p_refutes = NA_real_, p_nei = NA_real_,
                             confidence = NA_real_, cost = NA_real_)
  )
  if (i %% 25 == 0) cat(sprintf("  %d/%d\n", i, nrow(sample_df)))
}

cmp <- bind_cols(
  sample_df |> select(id, assessment, km, bm, hypothesis, label, nli_label, keypaper),
  bind_rows(lapply(res, as_tibble))
) |>
  rename(reference_label = label, judge_label = choice) |>
  mutate(reference_model = reference_model, .after = reference_label)

dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
write_parquet(cmp, out_path)

ok <- cmp |> filter(!is.na(judge_label))
cat(sprintf("\n=== %d/%d answered | total cost $%.4f ===\n",
            nrow(ok), nrow(cmp), sum(ok$cost, na.rm = TRUE)))

cat(sprintf("\n=== agreement: %s (rows) x %s (cols) ===\n",
            reference_model, paste(unique(ok$judge_model), collapse = ", ")))
print(as.data.frame(ok |> count(reference_label, judge_label) |>
  tidyr::pivot_wider(names_from = judge_label, values_from = n, values_fill = 0)))

cat(sprintf("\noverall agreement: %.1f%%\n", 100 * mean(ok$judge_label == ok$reference_label)))
cat(sprintf("\n=== per class (%s as reference, NOT as truth) ===\n", reference_model))
print(as.data.frame(ok |> group_by(reference_label) |>
  summarise(n = n(), agree = sprintf("%.1f%%", 100 * mean(judge_label == reference_label)), .groups = "drop")))

# The decision-relevant question for a cheap-prefilter role: when Jev is
# confident, is it right? If confidence is informative, a threshold on it routes
# work; if it is flat, the probabilities are decoration.
cat("\n=== is jev's confidence informative? (agreement by confidence tercile) ===\n")
print(as.data.frame(ok |> filter(!is.na(confidence)) |>
  mutate(band = cut(confidence, quantile(confidence, 0:3/3), include.lowest = TRUE)) |>
  group_by(band) |> summarise(n = n(), agree = sprintf("%.1f%%", 100 * mean(judge_label == reference_label)),
                              .groups = "drop")))

cat("\n=== RELEVANCE SCREEN: P(paper addresses the claim) by reference label ===\n")
print(as.data.frame(ok |> filter(!is.na(addresses)) |> group_by(reference_label) |>
  summarise(n = n(), median = sprintf("%.2f", median(addresses)),
            mean = sprintf("%.2f", mean(addresses)),
            below_0.5 = sprintf("%.0f%%", 100 * mean(addresses < 0.5)), .groups = "drop")))

cat("\n=== what a screen at each threshold would do ===\n")
cat("   kept = pairs that would still go to the expensive quoting LLM\n")
for (t in c(0.3, 0.5, 0.7)) {
  k <- ok |> filter(!is.na(addresses)) |> group_by(reference_label) |>
    summarise(kept = sprintf("%.0f%%", 100 * mean(addresses >= t)), .groups = "drop")
  cat(sprintf("  threshold %.1f  ", t))
  cat(paste(sprintf("%s %s", k$reference_label, k$kept), collapse = "   "), "\n")
}

cat(sprintf("\nwrote %s\n", out_path))
