#!/usr/bin/env Rscript
# THIRD run: are there really almost no refutations in GA1, or is the near-zero
# rate an artefact of how the reviewers were asked?
#
# Two earlier runs both came up empty -- the 200-row gold-standard instrument
# (1-3 REFUTES by any reviewer) and the Jev-enriched 195-row instrument (2
# majority REFUTES from the top of a 67,588-pair contradiction ranking). Three
# different enrichment signals, nearly nothing found. That is either a finding
# about the corpus or a property of the instrument.
#
# This probe separates the two by changing BOTH the population and the question:
#
# POPULATION -- the 181 TRIPLE-POSITIVE rows, the strongest evidence that exists
# anywhere in this project: gpt-4o-mini said REFUTES, the NLI independently said
# REFUTES, and quote_is_verbatim() confirmed the cited sentence really occurs in
# the paper. If refutations exist at all, they are disproportionately here.
#
# QUESTION -- two, neither of them the four-way instrument:
#   contradicts_any  deliberately PERMISSIVE. The reviewer guide makes
#                    NOT_ENOUGH_INFO the safe default and every model leans on
#                    it; this asks whether there is ANY inconsistency, even
#                    partial or in a limited setting. If the earlier near-zero
#                    was the guide's conservatism, this is where it shows.
#   quote_supports_refutation
#                    puts the judge's OWN cited sentence on trial: here is the
#                    quote it used, does that sentence actually contradict the
#                    claim? quote_is_verbatim() only ever checked the sentence
#                    EXISTS, never that it bears on the claim -- the exact gap
#                    the Jev screen was built for, asked directly.
#
# A permissive question on the best candidates still finding nothing is strong
# evidence the corpus genuinely holds almost none. Finding plenty means the
# earlier runs measured the instrument, not the corpus.
suppressPackageStartupMessages({library(arrow); library(dplyr)})

A <- "GA1"; OUTDIR <- "input/ai_refutes_probe"
MODELS <- list(
  list(slug = "claude-sonnet-4.6", model = "anthropic/claude-sonnet-4.6"),
  list(slug = "gemini-2.5-pro",    model = "google/gemini-2.5-pro"),
  list(slug = "deepseek-v4-pro",   model = "deepseek/deepseek-v4-pro"),
  # The judge itself, on its OWN REFUTES verdicts. On the first instrument it
  # reproduced only 53% of its Phase 2 calls; this asks the same of the subset
  # it was most confident about.
  list(slug = "gpt-4o-mini",       model = "openai/gpt-4o-mini")
)

source("R/build_llm_verification_parquet.R")   # build_llm_verification_chat()

grab <- function(root, keypaper) {
  p <- file.path(root, "llm_config=openrouter_cheap", paste0("assessment=", A))
  if (!dir.exists(p)) return(NULL)
  open_dataset(p) |>
    filter(llm_label == "REFUTES", nli_label == "REFUTES", quote_verbatim) |>
    select(km, bm, claim_id, claim, work_id, quote, explanation) |> collect() |>
    mutate(keypaper = keypaper)
}
cand <- bind_rows(grab(out_factcheck("llm_verification/scores"), FALSE),
                  grab(out_factcheck("llm_verification/scores_keypaper"), TRUE)) |>
  distinct(km, bm, claim_id, work_id, .keep_all = TRUE)

meta <- function(root, ids) open_dataset(root) |> filter(id %in% !!ids) |>
  select(id, title, abstract, doi) |> collect() |> distinct(id, .keep_all = TRUE)
m <- bind_rows(meta(file.path(out_collection("works_citing_meta"), paste0("assessment=", A)), unique(cand$work_id)),
               meta(file.path(out_collection("works"), paste0("assessment=", A)), unique(cand$work_id))) |>
  distinct(id, .keep_all = TRUE)
cand <- cand |> inner_join(m, by = c("work_id" = "id")) |>
  filter(!is.na(abstract), nzchar(trimws(abstract)))
cand$id <- substr(vapply(seq_len(nrow(cand)), function(i)
  digest::digest(paste(cand$km[i], cand$bm[i], cand$claim_id[i], cand$work_id[i], sep = "\r"),
                 algo = "md5", serialize = FALSE), ""), 1, 8)
message(sprintf("triple-positive rows with a usable abstract: %d", nrow(cand)))

api_key <- Sys.getenv("API_openrouter")
if (!nzchar(api_key)) api_key <- keyring::key_get("API_openrouter")

system_prompt <- paste(
  "You are checking whether a scientific paper contradicts a claim from an IPBES assessment.",
  "",
  "Be DELIBERATELY PERMISSIVE about what counts as a contradiction. Earlier reviewers",
  "defaulted heavily to 'not enough information', and the purpose here is to find out",
  "whether that default was hiding real disagreements. Count a contradiction even if it is",
  "partial, holds only in a particular region, taxon, time period or scale, or qualifies",
  "the claim rather than overturning it outright.",
  "",
  "You are also shown one sentence QUOTED from the paper by a previous reviewer, who used it",
  "as its evidence that the paper contradicts the claim. Judge that sentence on its merits:",
  "it has been verified to appear in the paper, but not to be relevant.",
  sep = "\n")

out_type <- ellmer::type_object(
  contradicts_any = ellmer::type_boolean("TRUE if the abstract contains ANY finding inconsistent with the claim, even partial or limited in scope."),
  quote_supports_refutation = ellmer::type_boolean("TRUE if the QUOTED sentence itself genuinely contradicts the claim."),
  strength = ellmer::type_enum("How strong the contradiction is.", values = c("none","weak","moderate","strong")),
  note = ellmer::type_string("One sentence of reasoning.")
)

dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)
for (mm in MODELS) {
  cd <- file.path(OUTDIR, ".cache", mm$slug); dir.create(cd, recursive = TRUE, showWarnings = FALSE)
  todo <- cand[!file.exists(file.path(cd, paste0(cand$id, ".json"))), , drop = FALSE]
  message(sprintf("\n=== %s === %d of %d to do", mm$slug, nrow(todo), nrow(cand)))
  if (nrow(todo)) {
    chat <- build_llm_verification_chat(list(model = mm$model, temperature = 0, max_tokens = 8000L),
                                        system_prompt, api_key)
    pr <- sprintf("CLAIM:\n%s\n\nPAPER TITLE:\n%s\n\nABSTRACT:\n%s\n\nSENTENCE QUOTED AS EVIDENCE OF CONTRADICTION:\n%s",
                  todo$claim, todo$title, todo$abstract, todo$quote)
    res <- ellmer::parallel_chat_structured(chat, as.list(pr), type = out_type, max_active = 8)
    for (k in seq_len(nrow(todo)))
      jsonlite::write_json(res[k, , drop = FALSE], file.path(cd, paste0(todo$id[[k]], ".json")), auto_unbox = TRUE)
  }
  got <- lapply(cand$id, function(i) {
    j <- jsonlite::read_json(file.path(cd, paste0(i, ".json")), simplifyVector = TRUE)
    data.frame(id = i, contradicts_any = j$contradicts_any %||% NA,
               quote_supports_refutation = j$quote_supports_refutation %||% NA,
               strength = j$strength %||% NA_character_, note = j$note %||% NA_character_)
  }) |> bind_rows()
  o <- cand |> select(id, km, bm, claim_id, work_id, keypaper, claim, title, abstract, doi, quote) |>
    left_join(got, by = "id") |> mutate(reviewer = mm$model, date = as.character(Sys.Date()))
  write.csv(o, file.path(OUTDIR, sprintf("probe_%s_%s.csv", A, mm$slug)), row.names = FALSE, na = "")
  message(sprintf("  contradicts_any TRUE: %d/%d   quote genuinely refutes: %d/%d",
                  sum(o$contradicts_any, na.rm = TRUE), nrow(o),
                  sum(o$quote_supports_refutation, na.rm = TRUE), nrow(o)))
  print(table(o$strength, useNA = "ifany"))
}
