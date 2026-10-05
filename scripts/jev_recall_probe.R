#!/usr/bin/env Rscript
# Q1: does Jev find refutations the NLI did NOT label REFUTES?
#
# Every Jev screen so far ran on a pool the NLI had already called REFUTES --
# the certain bucket, the uncertain bucket, the triple-positives. So we know Jev
# RANKS well inside the NLI's positives (AUC 0.74-0.79 against confirmed
# refutations, where the NLI itself scores 0.50). We do not know its RECALL,
# and recall is the whole question for a first-stage filter: a screen that only
# re-ranks another model's positives cannot replace that model.
#
# So this screens a random sample of pairs the NLI called SUPPORTS or
# NOT_ENOUGH_INFO, with the same contradiction question, and compares the score
# distribution against the REFUTES pool already screened.
#
#   if the rate of high scores here is NEGLIGIBLE -> the NLI's REFUTES label is
#     a useful prefilter and Jev is a precision stage on top of it;
#   if it is COMPARABLE or higher -> the NLI's label adds nothing, Jev alone
#     would find at least as much, and the 1.2M NEI pairs nobody has ever looked
#     at are hiding refutations.
suppressPackageStartupMessages({library(arrow); library(dplyr)})
source("R/build_llm_relevance_screen.R")

A <- "GA1"; GRAN <- "atomic_bm"; NLI_CONFIG <- "bge_m3_zeroshot_atomic_bm"
N_PER_CELL <- 5000L            # 4 cells (SUPPORTS/NEI x certain/uncertain) = 20,000
OUT_ROOT <- "output/jev_recall_probe"
SEED <- 23L

# Same question as scripts/build_refutes_candidates.R, deliberately verbatim --
# a different wording would make the two screens incomparable, which is the
# whole point of running this one.
relevance_question <- function(work_id) {
  list(type = "noul",
       instructions = "Does this paper report a finding that CONTRADICTS the claim -- a result that makes the claim less likely to be true?",
       criteria = list(
         "true"  = "the abstract reports a result inconsistent with the claim, or pointing in the opposite direction",
         "false" = "the abstract does not contradict the claim -- whether it supports it, is unrelated, or reports nothing bearing on it"))
}

sc <- open_dataset(file.path("output/nli_scores_evidence", paste0("granularity=", GRAN),
                             paste0("nli_config=", NLI_CONFIG), paste0("assessment=", A)))
set.seed(SEED)
cells <- expand.grid(label = c("SUPPORTS", "NOT_ENOUGH_INFO"), unc = c(FALSE, TRUE),
                     stringsAsFactors = FALSE)
pool <- bind_rows(lapply(seq_len(nrow(cells)), function(i) {
  L <- cells$label[i]; U <- cells$unc[i]
  d <- sc |> filter(label == L, uncertain == U) |>
    select(km, bm, claim_id, claim, work_id, p_refutes, confidence) |> collect() |>
    distinct(km, bm, claim_id, work_id, .keep_all = TRUE)
  d <- d[sample.int(nrow(d), min(N_PER_CELL, nrow(d))), ]
  d$cell <- paste0(L, if (U) "-uncertain" else "-certain")
  d
}))
message(sprintf("pool: %s pairs across %d cells", format(nrow(pool), big.mark = ","), nrow(cells)))

prem <- open_dataset(file.path("output/nli_ready_evidence", paste0("granularity=", GRAN),
                               paste0("assessment=", A))) |>
  filter(work_id %in% !!unique(pool$work_id)) |> select(work_id, premise) |> collect() |>
  distinct(work_id, .keep_all = TRUE)
pool <- pool |> inner_join(prem, by = "work_id")
message(sprintf("with premise: %s", format(nrow(pool), big.mark = ",")))

api_key <- Sys.getenv("API_openrouter")
if (!nzchar(api_key)) api_key <- keyring::key_get("API_openrouter")
out <- build_llm_relevance_screen(assessment = list(id = A), pairs = pool, keypaper = FALSE,
                                  model = "typesafe/jev-1.13", output_root = OUT_ROOT, api_key = api_key)

r <- open_dataset(out) |> collect() |>
  inner_join(pool |> select(km, bm, claim_id, work_id, cell), by = c("km","bm","claim_id","work_id"),
             relationship = "one-to-one") |> rename(p_con = addresses)
message("\nJev P(contradicts) on pairs the NLI did NOT call REFUTES:")
print(r |> group_by(cell) |> summarise(n = n(), median = round(median(p_con, na.rm=TRUE),3),
        p99 = round(quantile(p_con, .99, na.rm=TRUE),3),
        over_0.5 = sum(p_con >= .5, na.rm=TRUE), over_0.7 = sum(p_con >= .7, na.rm=TRUE),
        rate_0.7 = sprintf("%.3f%%", 100*mean(p_con >= .7, na.rm=TRUE)), .groups="drop") |> as.data.frame())

ref <- open_dataset(file.path("output/refutes_candidates", paste0("assessment=", A), "keypaper=false")) |>
  collect() |> rename(p_con = addresses)
message("\nfor comparison, the NLI-REFUTES pool screened earlier:")
cat(sprintf("  n=%s  median %.3f  >=0.7 %d (%.3f%%)\n", format(nrow(ref), big.mark=","),
    median(ref$p_con, na.rm=TRUE), sum(ref$p_con >= .7, na.rm=TRUE), 100*mean(ref$p_con >= .7, na.rm=TRUE)))
