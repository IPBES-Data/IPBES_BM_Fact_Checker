#!/usr/bin/env Rscript
# Find candidate REFUTES pairs with an INDEPENDENT signal, so a second reviewer
# instrument can be enriched for refutations that the first one failed to find.
#
# Why not just draw more from gpt-4o-mini's REFUTES verdicts: that is what
# build_goldstandard_sample() already does, and the 11-model pilot put the real
# rate in that stratum at ~3%. The whole 568-row pool would yield maybe 17.
# Stratifying on a label that is mostly wrong is not enrichment.
#
# So Jev ranks a much wider pool instead, with a contradiction question. Two
# things fall out of the same run:
#   1. candidates for the instrument, from the top of the ranking;
#   2. a first look at NLI REFUTES-UNCERTAIN -- 316,059 pairs the router drops
#      and Phase 2 has never seen. The gold-standard sample cannot reach them
#      (it is drawn from Phase 2 output), so this is the only way to ask whether
#      that bucket holds anything.
#
# Reuses build_llm_relevance_screen() wholesale -- chunking by token budget,
# concurrency, retries, resumability, cost accounting are all already there and
# tested. Only the question is swapped, by shadowing relevance_question() after
# sourcing, and the output goes to its own root so the real relevance scores are
# untouched.
suppressPackageStartupMessages({library(arrow); library(dplyr)})
source("R/build_llm_relevance_screen.R")

ASSESSMENT  <- "GA1"
GRAN        <- "atomic_bm"
NLI_CONFIG  <- "bge_m3_zeroshot_atomic_bm"
N_UNCERTAIN <- 60000L      # sampled from the 316,059 never-reviewed rows
OUT_ROOT    <- "output/refutes_candidates"
SEED        <- 11L

# Deliberately NOT the relevance question. That one asks whether a paper BEARS
# on the claim; this asks for the direction of the finding.
relevance_question <- function(work_id) {
  list(type = "noul",
       instructions = "Does this paper report a finding that CONTRADICTS the claim -- a result that makes the claim less likely to be true?",
       criteria = list(
         "true"  = "the abstract reports a result inconsistent with the claim, or pointing in the opposite direction",
         "false" = "the abstract does not contradict the claim -- whether it supports it, is unrelated, or reports nothing bearing on it"))
}

scores <- open_dataset(file.path("output/nli_scores_evidence", paste0("granularity=", GRAN),
                                 paste0("nli_config=", NLI_CONFIG), paste0("assessment=", ASSESSMENT)))
certain <- scores |> filter(label == "REFUTES", !uncertain) |>
  select(km, bm, claim_id, claim, work_id, p_refutes, confidence) |> collect() |> mutate(bucket = "certain")
unc <- scores |> filter(label == "REFUTES", uncertain) |>
  select(km, bm, claim_id, claim, work_id, p_refutes, confidence) |> collect()
set.seed(SEED)
unc <- unc[sample.int(nrow(unc), min(N_UNCERTAIN, nrow(unc))), ] |> mutate(bucket = "uncertain")
# distinct() on the full key: the scored tree can hold more than one row per
# (km, bm, claim_id, work_id) -- consolidation supersedes by claim_id, not by
# work -- and a duplicate here fans out the join at the end AND pays Jev twice.
pool <- bind_rows(certain, unc) |> distinct(km, bm, claim_id, work_id, .keep_all = TRUE)
message(sprintf("pool: %s certain + %s of %s uncertain = %s pairs",
                format(nrow(certain), big.mark=","), format(nrow(unc), big.mark=","),
                format(scores |> filter(label=="REFUTES", uncertain) |> nrow(), big.mark=","),
                format(nrow(pool), big.mark=",")))

# Premise comes from the cross-join, filtered by work_id BEFORE collecting --
# the tree is 18M rows for GA1 and carries full abstracts.
prem <- open_dataset(file.path("output/nli_ready_evidence", paste0("granularity=", GRAN),
                               paste0("assessment=", ASSESSMENT))) |>
  filter(work_id %in% !!unique(pool$work_id)) |>
  select(work_id, premise) |> collect() |> distinct(work_id, .keep_all = TRUE)
pool <- pool |> inner_join(prem, by = "work_id")
message(sprintf("with premise: %s pairs", format(nrow(pool), big.mark=",")))

api_key <- Sys.getenv("API_openrouter")
if (!nzchar(api_key)) api_key <- keyring::key_get("API_openrouter")

out <- build_llm_relevance_screen(
  assessment = list(id = ASSESSMENT), pairs = pool, keypaper = FALSE,
  model = "typesafe/jev-1.13", output_root = OUT_ROOT, api_key = api_key
)

r <- open_dataset(out) |> collect() |> left_join(pool |> select(km, bm, claim_id, work_id, bucket, nli_p_refutes = p_refutes),
                                                 by = c("km","bm","claim_id","work_id"), relationship = "one-to-one")
# `addresses` is build_llm_relevance_screen()'s column name for whatever noul it
# was asked; here it is P(contradicts), not P(relevant).
message("\nJev P(contradicts) by NLI bucket:")
print(r |> group_by(bucket) |> summarise(n = n(),
        median = round(median(addresses, na.rm = TRUE), 3),
        p90 = round(quantile(addresses, .90, na.rm = TRUE), 3),
        over_0.5 = sum(addresses >= .5, na.rm = TRUE),
        over_0.7 = sum(addresses >= .7, na.rm = TRUE), .groups = "drop") |> as.data.frame())
message(sprintf("\ncorrelation with the NLI's own p_refutes: %.3f (Spearman)",
        suppressWarnings(cor(r$addresses, r$nli_p_refutes, method = "spearman", use = "complete.obs"))))
