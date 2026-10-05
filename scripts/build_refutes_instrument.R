#!/usr/bin/env Rscript
# Build a SECOND reviewer instrument, enriched for refutations by an independent
# signal, so the architecture question becomes measurable. The first instrument
# cannot answer it: 200 rows yielded 1-3 real REFUTES by any reviewer, because it
# was stratified on gpt-4o-mini's own REFUTES label and that label is mostly
# wrong (see input/ai_goldstandard/AI_REVIEWER_COMPARISON.md).
#
# Output goes to input/ai_goldstandard_refutes/ -- a SEPARATE folder. The first
# instrument and its 12 reviewer files are not touched.
#
# Three strata, so the enrichment methods are compared on identical footing:
#   jev_top      top of Jev's contradiction ranking, from the REFUTES-CERTAIN
#                bucket Phase 2 already reviews
#   jev_unrouted top of the same ranking from REFUTES-UNCERTAIN -- 316,059 pairs
#                the router drops and Phase 2 has never seen. The gold-standard
#                sample cannot reach these at all, since it is drawn FROM Phase 2
#                output, so this is the only way to ask whether the bucket holds
#                anything
#   judge        drawn the old way, from gpt-4o-mini's REFUTES verdicts, as the
#                control: its real rate is already measured at ~3%
suppressPackageStartupMessages({library(arrow); library(dplyr)})

ASSESSMENT <- "GA1"; GRAN <- "atomic_bm"; NLI_CONFIG <- "bge_m3_zeroshot_atomic_bm"
OUTDIR <- "input/ai_goldstandard_refutes"
N <- c(jev_top = 75L, jev_unrouted = 75L, judge = 50L)   # 200 total
SEED <- 11L

jev <- open_dataset(file.path("output/refutes_candidates", paste0("assessment=", ASSESSMENT), "keypaper=false")) |>
  collect() |> rename(p_contradicts = addresses) |> filter(!is.na(p_contradicts))
sc <- open_dataset(file.path("output/nli_scores_evidence", paste0("granularity=", GRAN),
                             paste0("nli_config=", NLI_CONFIG), paste0("assessment=", ASSESSMENT))) |>
  filter(label == "REFUTES") |> select(km, bm, claim_id, claim, work_id, uncertain, p_refutes, confidence) |>
  collect() |> distinct(km, bm, claim_id, work_id, .keep_all = TRUE)
jev <- jev |> inner_join(sc, by = c("km","bm","claim_id","work_id"), relationship = "one-to-one")

# Metadata FIRST, then rank. Picking the top N and filtering afterwards threw
# away two thirds of the draw -- a row with no usable abstract is not a
# candidate at all (a reviewer cannot judge what they cannot read), so it must
# not occupy a slot in the ranking.
meta_all <- open_dataset(file.path("output/works_citing_meta", paste0("assessment=", ASSESSMENT))) |>
  select(id, title, abstract, doi) |> collect() |> distinct(id, .keep_all = TRUE) |>
  filter(!is.na(abstract), nzchar(trimws(abstract)))
jev <- jev |> inner_join(meta_all, by = c("work_id" = "id"))
message(sprintf("candidates with a usable abstract: %s of %s",
                format(nrow(jev), big.mark=","), format(nrow(jev), big.mark=",")))

pick <- function(d, n, lab) d |> arrange(desc(p_contradicts)) |> head(n) |> mutate(stratum = lab)
a <- pick(jev |> filter(!uncertain), N[["jev_top"]],      "jev_top")
b <- pick(jev |> filter(uncertain),  N[["jev_unrouted"]], "jev_unrouted")

ver <- open_dataset(file.path("output/llm_verification/scores",
        "llm_config=openrouter_cheap", paste0("assessment=", ASSESSMENT))) |>
  filter(llm_label == "REFUTES") |> select(km, bm, claim_id, claim, work_id, nli_label, nli_confidence) |>
  collect() |> distinct(km, bm, claim_id, work_id, .keep_all = TRUE)
set.seed(SEED)
c0 <- ver[sample.int(nrow(ver), min(N[["judge"]], nrow(ver))), ] |>
  mutate(stratum = "judge", p_contradicts = NA_real_, uncertain = NA, p_refutes = NA_real_, confidence = nli_confidence)

keep <- c("km","bm","claim_id","claim","work_id","stratum","p_contradicts","uncertain","p_refutes","confidence")
c0 <- c0 |> inner_join(meta_all, by = c("work_id" = "id"))
cand <- bind_rows(a[c(keep,"title","abstract","doi")], b[c(keep,"title","abstract","doi")],
                  c0[c(keep,"title","abstract","doi")]) |>
  distinct(km, bm, claim_id, work_id, .keep_all = TRUE)

cand$id <- substr(apply(cand[c("km","bm","claim_id","work_id")], 1,
                        function(r) digest::digest(paste(r, collapse="\r"), algo="md5", serialize=FALSE)), 1, 8)
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

# The blinded instrument: no model columns at all, same discipline as
# build_goldstandard_sample(). Showing a reviewer the scores anchors the
# judgement being measured.
set.seed(SEED)
tmpl <- cand[sample.int(nrow(cand)), c("id","claim","title","abstract","doi")] |>
  mutate(verdict = "", note = "", reviewer = "", date = "")
write.csv(tmpl, file.path(OUTDIR, sprintf("R1_%s_refutes_template.csv", ASSESSMENT)), row.names = FALSE)
# The manifest keeps every score, for scoring the instrument afterwards.
write.csv(cand |> select(id, km, bm, claim_id, work_id, stratum, p_contradicts, uncertain, p_refutes, confidence),
          file.path(OUTDIR, sprintf("sample_manifest_%s_refutes.csv", ASSESSMENT)), row.names = FALSE)

message(sprintf("wrote %d rows to %s", nrow(tmpl), OUTDIR))
print(cand |> group_by(stratum) |> summarise(n = n(),
        median_jev = round(median(p_contradicts, na.rm = TRUE), 3),
        min_jev = round(min(p_contradicts, na.rm = TRUE), 3), .groups = "drop") |> as.data.frame())
