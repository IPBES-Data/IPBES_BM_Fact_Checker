#!/usr/bin/env Rscript
# Put the zero-shot NLI model's own verdicts on the 200 sampled rows beside the
# LLM reviewers', in the same file shape, so it can be compared directly.
#
# It is NOT one tree: 85 of the 200 rows are key papers, scored by the keypaper
# chain into output/nli_scores_evidence_keypaper/, and 115 are citing works in
# output/nli_scores_evidence/. Both are read and concatenated.
#
# The join key is the FULL (km, bm, work_id, claim). claim_id strings repeat
# across every BM, and a work can be cited under several BMs, so anything
# shorter fans out or matches the wrong row -- the same key discipline the
# Phase 2 cache documents.
#
# Unlike the chat models this writes the full probability distribution too
# (p_supports/p_refutes/p_nei, confidence, uncertain). The argmax `verdict` is
# what the comparison needs, but the distribution is what any re-thresholding
# would use, and it costs nothing to carry.
suppressPackageStartupMessages({library(arrow); library(dplyr)})

ASSESSMENT <- "GA1"
NLI_CONFIG <- "bge_m3_zeroshot_atomic_bm"
GRAN       <- "atomic_bm"
OUTDIR     <- "input/ai_goldstandard"

tmpl <- read.csv(sprintf("input/goldstandard/R1_%s_template.csv", ASSESSMENT), stringsAsFactors = FALSE) |>
  mutate(id = as.character(id))
man <- read.csv(sprintf("input/goldstandard/sample_manifest_%s.csv", ASSESSMENT), stringsAsFactors = FALSE) |>
  transmute(id = as.character(id), km, bm, work_id, keypaper = as.logical(keypaper),
            manifest_nli_label = nli_label)
key <- tmpl |> select(id, claim) |> left_join(man, by = "id")

read_tree <- function(root) {
  p <- file.path(root, paste0("granularity=", GRAN), paste0("nli_config=", NLI_CONFIG),
                 paste0("assessment=", ASSESSMENT))
  if (!dir.exists(p)) { message("absent: ", p); return(NULL) }
  open_dataset(p) |>
    filter(work_id %in% !!unique(key$work_id)) |>
    select(km, bm, work_id, claim, label, p_supports, p_refutes, p_nei, confidence, uncertain) |>
    collect()
}
scored <- bind_rows(read_tree("output/nli_scores_evidence"),
                    read_tree("output/nli_scores_evidence_keypaper")) |>
  distinct(km, bm, work_id, claim, .keep_all = TRUE)
message(sprintf("scored rows available: %s", format(nrow(scored), big.mark = ",")))

got <- key |> left_join(scored, by = c("km", "bm", "work_id", "claim"))
message(sprintf("matched %d of %d sampled rows", sum(!is.na(got$label)), nrow(got)))

# Cross-check against the manifest's own nli_label, which was written at sampling
# time from the same scores. A mismatch means the join is wrong, not that the
# model changed its mind.
both <- !is.na(got$label) & !is.na(got$manifest_nli_label) & nzchar(got$manifest_nli_label)
if (any(both)) {
  bad <- sum(got$label[both] != got$manifest_nli_label[both])
  message(sprintf("agreement with the manifest's nli_label: %d/%d%s", sum(both) - bad, sum(both),
                  if (bad) sprintf("  -- %d MISMATCH, join is suspect", bad) else ""))
}

filled <- tmpl |>
  select(id, claim, title, abstract, doi) |>
  left_join(got |> select(id, verdict = label, p_supports, p_refutes, p_nei, confidence, uncertain),
            by = "id") |>
  mutate(note = ifelse(is.na(verdict), NA_character_,
                       sprintf("p_sup=%.3f p_ref=%.3f p_nei=%.3f conf=%.3f %s",
                               p_supports, p_refutes, p_nei, confidence,
                               ifelse(uncertain, "uncertain", "certain"))),
         reviewer = NLI_CONFIG, date = as.character(Sys.Date()))

dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)
path <- file.path(OUTDIR, sprintf("R1_%s_nli-zeroshot.csv", ASSESSMENT))
utils::write.csv(filled, path, row.names = FALSE, na = "")
message("wrote ", path)
print(filled |> count(verdict))
