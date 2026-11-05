#!/usr/bin/env Rscript
# Build the comparison report from whatever input/ai_goldstandard/ holds.
# Pure analysis of files already on disk -- no API calls, so it is free to re-run.
suppressPackageStartupMessages({library(dplyr)})
source("R/build_goldstandard.R")   # cohens_kappa()
`%||%` <- function(x, y) if (is.null(x)) y else x

OUT <- "input/ai_goldstandard/AI_REVIEWER_COMPARISON.md"
LAB <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")

man <- read.csv("input/goldstandard/sample_manifest_GA1.csv", stringsAsFactors = FALSE) |>
  transmute(id = as.character(id), judge = label, nli = nli_label, stratum, km, bm)

f <- list.files("input/ai_goldstandard", pattern = "^R1_GA1_.*[.]csv$", full.names = TRUE)
d <- lapply(f, function(p) {
  x <- read.csv(p, stringsAsFactors = FALSE)
  data.frame(id = as.character(x$id),
             v = ifelse(is.na(x$verdict) | !nzchar(x$verdict), NA, x$verdict),
             m = sub("[.]csv$", "", sub("^R1_GA1_", "", basename(p))), stringsAsFactors = FALSE)
}) |> bind_rows()
w <- tidyr::pivot_wider(d, names_from = m, values_from = v) |> inner_join(man, by = "id")
ms <- sort(setdiff(names(w), c("id", "judge", "nli", "stratum", "km", "bm")))

# The zero-shot NLI's verdicts come from the EXTRACTED file when it exists, not
# from the manifest's nli_label column: the manifest leaves 50 of the 200 blank,
# while scripts/extract_nli_reviewer.R recovers all 200 from the two scored trees
# (and cross-checks the 150 the manifest does carry). It stays in `ms` as well,
# so it appears in the distribution table and the pairwise matrix like any other
# reviewer -- but it is dropped from the "agreement with the NLI" table below,
# where it would only ever score 1.0 against itself.
NLI_SLUG <- "nli-zeroshot"
if (NLI_SLUG %in% ms) w$nli <- w[[NLI_SLUG]]

# measured spend: chat models from their per-row cache, jev from its own column
spend <- function(slug) {
  if (grepl("^jev", slug)) {
    x <- read.csv(sprintf("input/ai_goldstandard/R1_GA1_%s.csv", slug), stringsAsFactors = FALSE)
    return(list(cost = sum(x$cost, na.rm = TRUE), inp = NA, out = NA))
  }
  dir <- file.path("input/ai_goldstandard/.cache", slug)
  if (!dir.exists(dir)) return(list(cost = NA, inp = NA, out = NA))
  j <- lapply(list.files(dir, full.names = TRUE), jsonlite::read_json, simplifyVector = TRUE)
  i <- sum(vapply(j, function(x) as.numeric(x$input_tokens %||% 0), 0))
  o <- sum(vapply(j, function(x) as.numeric(x$output_tokens %||% 0), 0))
  pr <- PRICES[[slug]]
  list(cost = if (is.null(pr)) NA else i * pr[1] / 1e6 + o * pr[2] / 1e6, inp = i, out = o)
}
PRICES <- list(
  "claude-sonnet-4.6" = c(3.00, 15.00), "gemini-2.5-pro" = c(1.25, 10.00),
  "deepseek-v4-pro" = c(0.348, 0.696),  "gpt-5-mini" = c(0.25, 2.00),
  "claude-haiku-4.5" = c(1.00, 5.00),   "gemini-2.5-flash" = c(0.30, 2.50),
  "mistral-medium-3" = c(0.40, 2.00),   "gpt-4o-mini" = c(0.15, 0.60),
  "llama-4-maverick" = c(0.188, 0.652), "qwen3-235b" = c(0.087, 0.350)
  # nli-zeroshot has no entry deliberately: it is GPU time already spent, not a
  # per-token cost, so it shows "—" in the cost column rather than a wrong number.
)

agree_vs <- function(a, b) {   # on rows both answered with one of the 3 labels
  ok <- !is.na(a) & !is.na(b) & a %in% LAB & b %in% LAB
  if (sum(ok) < 10) return(c(n = sum(ok), agree = NA, kappa = NA))
  c(n = sum(ok), agree = 100 * mean(a[ok] == b[ok]), kappa = cohens_kappa(a[ok], b[ok]))
}

con <- file(OUT, "w"); wr <- function(...) writeLines(c(...), con)

wr("# LLM reviewers vs the gpt-4o-mini labels — GA1 gold-standard sample",
   "", sprintf("Generated %s by `scripts/ai_reviewer_report.R`. ", Sys.Date()),
   "**Not a gold standard** — see `NOT_A_GOLD_STANDARD.md` beside this file.", "",
   sprintf("%d rows, %d reviewers.", nrow(w), length(ms)), "",
   "## The sample", "",
   "200 rows drawn from the `holdout` fold by `build_goldstandard_sample()`,",
   "stratified on **the LLM's own label** with REFUTES over-sampled:", "")
wr("| gpt-4o-mini said | n | share of sample |", "|---|---:|---:|")
jt <- w |> count(judge)
for (i in seq_len(nrow(jt))) wr(sprintf("| %s | %d | %.1f%% |", jt$judge[i], jt$n[i], 100*jt$n[i]/sum(jt$n)))

wr("", "## What each reviewer said", "",
   "| reviewer | SUPPORTS | REFUTES | NEI | CANNOT_JUDGE | unparsed | cost (200 rows) |",
   "|---|---:|---:|---:|---:|---:|---:|")
for (m in ms) {
  v <- w[[m]]; s <- spend(m)
  wr(sprintf("| `%s` | %d | **%d** | %d | %d | %d | %s |", m,
      sum(v == "SUPPORTS", na.rm = TRUE), sum(v == "REFUTES", na.rm = TRUE),
      sum(v == "NOT_ENOUGH_INFO", na.rm = TRUE), sum(v == "CANNOT_JUDGE", na.rm = TRUE),
      sum(is.na(v)), if (is.na(s$cost)) "—" else sprintf("$%.3f", s$cost)))
}

wr("", "## Agreement with gpt-4o-mini (the judge whose labels the training set carries)", "",
   "| reviewer | n | agreement | Cohen's kappa |", "|---|---:|---:|---:|")
for (m in ms) { a <- agree_vs(w[[m]], w$judge)
  wr(sprintf("| `%s` | %d | %.1f%% | %.3f |", m, a[["n"]], a[["agree"]], a[["kappa"]])) }

wr("", "## Agreement with the zero-shot NLI model", "",
   "| reviewer | n | agreement | Cohen's kappa |", "|---|---:|---:|---:|")
for (m in setdiff(ms, NLI_SLUG)) { a <- agree_vs(w[[m]], w$nli)
  wr(sprintf("| `%s` | %d | %.1f%% | %.3f |", m, a[["n"]], a[["agree"]], a[["kappa"]])) }
a <- agree_vs(w$judge, w$nli)
wr("", sprintf("For reference, gpt-4o-mini vs the zero-shot NLI on the same rows: %.1f%% agreement, kappa %.3f.",
               a[["agree"]], a[["kappa"]]))

wr("", "## Reviewers against each other", "",
   "Cohen's kappa, lower triangle:", "",
   paste0("| | ", paste(sprintf("`%s`", ms[-length(ms)]), collapse = " | "), " |"),
   paste0("|---|", paste(rep("---:", length(ms) - 1), collapse = "|"), "|"))
for (i in 2:length(ms)) {
  cells <- vapply(seq_len(length(ms) - 1), function(j) {
    if (j >= i) return("")
    k <- agree_vs(w[[ms[i]]], w[[ms[j]]])[["kappa"]]
    if (is.na(k)) "" else sprintf("%.2f", k)
  }, "")
  wr(sprintf("| `%s` | %s |", ms[i], paste(cells, collapse = " | ")))
}

maj <- apply(w[ms], 1, function(r) { r <- r[!is.na(r) & r %in% LAB]
  if (length(r) < 3) return(NA_character_)
  t <- table(r); if (max(t) > length(r)/2) names(t)[which.max(t)] else NA_character_ })
wr("", "## The REFUTES question", "",
   sprintf("Of the **%d** rows gpt-4o-mini called REFUTES, the reviewers' majority verdict was:",
           sum(w$judge == "REFUTES")), "")
sub <- w[w$judge == "REFUTES", ]; mj <- maj[w$judge == "REFUTES"]
tb <- table(factor(mj, levels = LAB, exclude = NULL))
nm <- ifelse(is.na(names(tb)), "no majority", names(tb))
wr("| majority verdict | n |", "|---|---:|")
for (i in seq_along(tb)) wr(sprintf("| %s | %d |", nm[i], as.integer(tb[i])))
wr("", sprintf("REFUTES count per reviewer, out of %d rows: %s.", nrow(w),
    paste(sprintf("`%s` %d", ms, vapply(ms, function(m) sum(w[[m]] == "REFUTES", na.rm = TRUE), 0L)), collapse = ", ")))
wr(sprintf("Rows where **every** reviewer said REFUTES: **%d**.",
    sum(apply(w[ms], 1, function(r) all(r[!is.na(r)] == "REFUTES") && sum(!is.na(r)) == length(ms)))))

wr("", "## Cost to run a reviewer over all of GA1", "",
   "Measured per-row cost from this run, scaled to two corpus sizes.", "",
   "- **Zero-shot routing** — 78,922 pairs, the REFUTES+SUPPORTS-certain set for all five KMs",
   "  under `bge_m3_zeroshot_atomic_bm` (measured, recorded in `config.yaml`).",
   "- **Fine-tune routing** — ~6,140,000 pairs, scaling KM C's measured 787,215 routed of",
   "  2,307,101 scored across GA1's 18,010,940. The 78x gap IS the calibration problem:",
   "  the fine-tune routes 18.9% of the corpus where the zero-shot model routes 0.4%.", "",
   "| reviewer | $/row | all GA1, zero-shot routing | all GA1, fine-tune routing |",
   "|---|---:|---:|---:|")
for (m in ms) { s <- spend(m); if (is.na(s$cost)) next
  pr <- s$cost / nrow(w)
  wr(sprintf("| `%s` | $%.5f | $%s | $%s |", m, pr,
      formatC(pr*78922, format="f", big.mark=",", digits=0),
      formatC(pr*6140000, format="f", big.mark=",", digits=0))) }
wr("", "Add OpenRouter's 5.5% credit fee. Phase 2 also caches per pair, so a re-run after",
   "an unrelated change costs nothing.")
close(con)
message("wrote ", OUT)
