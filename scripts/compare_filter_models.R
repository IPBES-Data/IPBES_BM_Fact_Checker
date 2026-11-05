#!/usr/bin/env Rscript
# Can a SELF-HOSTABLE open-weight model match Jev as the first-stage filter?
#
# Jev's advantage over the NLI is established (AUC 0.74-0.79 vs 0.50 on the
# probe's confirmed refutations), but it is served from an unversioned alpha
# endpoint -- which is the whole reason design_notes.md point 8 keeps the
# distillation chain alive as a deferred option. If an 8-14B open model matches
# it, the dependency disappears without needing to distil anything: pull the
# weights, serve them on the RunPod pool that already exists.
#
# Every model here is OPEN WEIGHT and fits one L4/L40S, so a win on OpenRouter
# translates directly into something servable. Scored on the SAME 179 probe rows
# against the SAME target, so the numbers are comparable to Jev's and the NLI's.
#
# A SCORE is requested, not a label: AUC needs a ranking, and a filter's cutoff
# is the thing being calibrated. Models are poor at absolute calibration but
# usable at ordering, which is all a filter needs.
suppressPackageStartupMessages({library(dplyr)})
source("R/build_llm_verification_parquet.R")   # build_llm_verification_chat()

OUTDIR <- "input/ai_filter_comparison"
# NON-REASONING MODELS FIRST, deliberately. qwen3-8b and qwen3-14b are HYBRID
# reasoning models: they think by default, so each row generates a long trace
# before the two-field JSON. A first attempt stalled on qwen3-8b at ~16% of one
# model after ten minutes and never reached the other five. The instruct-tuned
# qwen3-30b-a3b-instruct-2507 does not think, which is why it is kept and the
# two hybrids are last -- a filter that needs a reasoning trace per pair is not a
# cheap first stage anyway, so if they are slow here that is itself a finding.
MODELS <- list(
  list(slug = "llama-3.1-8b",    model = "meta-llama/llama-3.1-8b-instruct", note = "8B, one L4"),
  list(slug = "gemma-3-12b",     model = "google/gemma-3-12b-it",            note = "12B, one L4"),
  list(slug = "phi-4",           model = "microsoft/phi-4",                  note = "14B, one L4"),
  list(slug = "qwen3-30b-a3b",   model = "qwen/qwen3-30b-a3b-instruct-2507", note = "30B MoE, 3B active, one L40S"),
  list(slug = "qwen3-14b",       model = "qwen/qwen3-14b",                   note = "14B hybrid, thinks by default"),
  list(slug = "qwen3-8b",        model = "qwen/qwen3-8b",                    note = "8B hybrid, thinks by default")
)

# Deliberately the same wording as the Jev screen (scripts/build_refutes_candidates.R),
# so the comparison is of models rather than of prompts. No quote is shown --
# Jev never saw one either.
system_prompt <- paste(
  "You judge whether a scientific paper contradicts a claim from an IPBES assessment.",
  "",
  "A contradiction means the abstract reports a result inconsistent with the claim, or",
  "pointing in the opposite direction. It is NOT a contradiction if the paper supports the",
  "claim, is unrelated, or reports nothing bearing on it.",
  "",
  "Count a contradiction even if it is partial, or holds only for a particular region,",
  "taxon, time period or scale.",
  "",
  "Return a probability between 0 and 1, where 1 means certainly contradicts. Use the whole",
  "range -- most papers will be near 0, and the ordering matters more than the exact value.",
  sep = "\n")

out_type <- ellmer::type_object(
  p_contradicts = ellmer::type_number("Probability between 0 and 1 that the paper contradicts the claim."),
  note = ellmer::type_string("One short sentence of reasoning.")
)

rows <- read.csv("input/ai_refutes_probe/probe_GA1_claude-sonnet-4.6.csv", stringsAsFactors = FALSE) |>
  select(id, km, bm, claim_id, work_id, keypaper, claim, title, abstract)
message(sprintf("%d probe rows", nrow(rows)))

api_key <- Sys.getenv("API_openrouter")
if (!nzchar(api_key)) api_key <- keyring::key_get("API_openrouter")
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

for (mm in MODELS) {
  cd <- file.path(OUTDIR, ".cache", mm$slug); dir.create(cd, recursive = TRUE, showWarnings = FALSE)
  todo <- rows[!file.exists(file.path(cd, paste0(rows$id, ".json"))), , drop = FALSE]
  message(sprintf("\n=== %s (%s) === %d to do", mm$slug, mm$note, nrow(todo)))
  if (nrow(todo)) {
    chat <- build_llm_verification_chat(list(model = mm$model, temperature = 0, max_tokens = 8000L),
                                        system_prompt, api_key)
    pr <- sprintf("CLAIM:\n%s\n\nPAPER TITLE:\n%s\n\nABSTRACT:\n%s", todo$claim, todo$title, todo$abstract)
    res <- try(ellmer::parallel_chat_structured(chat, as.list(pr), type = out_type, max_active = 8), silent = TRUE)
    if (inherits(res, "try-error")) { message("  FAILED: ", conditionMessage(attr(res, "condition"))); next }
    for (k in seq_len(nrow(todo)))
      jsonlite::write_json(res[k, , drop = FALSE], file.path(cd, paste0(todo$id[[k]], ".json")), auto_unbox = TRUE)
  }
  got <- lapply(rows$id, function(i) {
    f <- file.path(cd, paste0(i, ".json"))
    if (!file.exists(f)) return(data.frame(id = i, p_contradicts = NA_real_, note = NA_character_))
    j <- jsonlite::read_json(f, simplifyVector = TRUE)
    data.frame(id = i, p_contradicts = as.numeric(j$p_contradicts %||% NA), note = j$note %||% NA_character_)
  }) |> bind_rows()
  o <- rows |> left_join(got, by = "id") |> mutate(reviewer = mm$model, date = as.character(Sys.Date()))
  write.csv(o, file.path(OUTDIR, sprintf("filter_GA1_%s.csv", mm$slug)), row.names = FALSE, na = "")
  message(sprintf("  wrote %d rows, %d scored, median %.3f", nrow(o), sum(!is.na(o$p_contradicts)),
                  median(o$p_contradicts, na.rm = TRUE)))
}
