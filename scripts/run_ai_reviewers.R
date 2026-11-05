#!/usr/bin/env Rscript
# Run the blinded reviewer instrument past several LLMs, as a PILOT for the
# human round -- NOT as a gold standard. R/build_goldstandard.R exists because
# benchmarking against LLM labels measures fidelity to the judge rather than
# truth, and two models agreeing tells you they share priors. Output therefore
# goes to input/ai_goldstandard/, never input/goldstandard/, and carries a
# warning file.
#
# What it is actually good for:
#   - piloting REVIEWER_GUIDE.md. If independent strong models diverge on the
#     four-value verdict, the guide is ambiguous and the two humans will diverge
#     the same way -- and kappa will then measure the instrument, not the
#     judgement.
#   - a cheap prior on the REFUTES rate, which the synthetic round put at 1 in
#     100 drawn from the REFUTES stratum.
#
# Models are from THREE different labs deliberately. None is an OpenAI model:
# the labels under test came from gpt-4o-mini, so an OpenAI sibling as reviewer
# would inflate agreement with the judge through shared family priors.
#
# Usage (from the repo root):
#   Rscript scripts/run_ai_reviewers.R              # all three models
#   Rscript scripts/run_ai_reviewers.R gemini       # one, by slug substring
suppressPackageStartupMessages({library(dplyr)})

# A second instrument (input/ai_goldstandard_refutes/) exists for the same rows'
# worth of work on a REFUTES-enriched draw, so the paths are overridable rather
# than duplicated into a near-identical script. Defaults are the first
# instrument, so an existing invocation is unchanged.
#   NLI_REVIEW_TEMPLATE=... NLI_REVIEW_OUTDIR=... Rscript scripts/run_ai_reviewers.R
ASSESSMENT <- "GA1"
TEMPLATE   <- Sys.getenv("NLI_REVIEW_TEMPLATE",
                         file.path("input/goldstandard", sprintf("R1_%s_template.csv", ASSESSMENT)))
GUIDE      <- "input/goldstandard/REVIEWER_GUIDE.md"
OUTDIR     <- Sys.getenv("NLI_REVIEW_OUTDIR", "input/ai_goldstandard")
CACHE      <- file.path(OUTDIR, ".cache")
VERDICTS   <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO", "CANNOT_JUDGE")

# Three tiers, seven labs. gpt-4o-mini is included DELIBERATELY even though it
# is the judge whose labels are under test: re-running it on the same rows asks
# whether its own verdicts are self-consistent. Note it is not an exact
# reproduction -- the original labels came from the Phase 2 verification prompt,
# this run uses the reviewer guide -- so it measures "does the judge, given the
# human instrument, stand by its own Phase 2 calls".
MODELS <- list(
  # frontier
  list(slug = "claude-sonnet-4.6", model = "anthropic/claude-sonnet-4.6"),
  list(slug = "gemini-2.5-pro",    model = "google/gemini-2.5-pro"),
  list(slug = "deepseek-v4-pro",   model = "deepseek/deepseek-v4-pro"),
  # mid
  list(slug = "gpt-5-mini",        model = "openai/gpt-5-mini"),
  list(slug = "claude-haiku-4.5",  model = "anthropic/claude-haiku-4.5"),
  list(slug = "gemini-2.5-flash",  model = "google/gemini-2.5-flash"),
  list(slug = "mistral-medium-3",  model = "mistralai/mistral-medium-3"),
  # low / open weights
  list(slug = "gpt-4o-mini",       model = "openai/gpt-4o-mini"),
  list(slug = "llama-4-maverick",  model = "meta-llama/llama-4-maverick"),
  list(slug = "qwen3-235b",        model = "qwen/qwen3-235b-a22b-2507")
)

# Only ONE ordering is run, although the humans get two independently shuffled
# files. The shuffle exists so position and fatigue effects do not correlate
# between reviewers; with one independent call per row at temperature 0 there is
# no context carryover, so a second ordering would return identical verdicts and
# cost the same again.

source("R/build_llm_verification_parquet.R")   # build_llm_verification_chat(), load_text_file()

api_key <- Sys.getenv("API_openrouter")
if (!nzchar(api_key)) api_key <- keyring::key_get("API_openrouter")
if (!nzchar(api_key)) stop("API_openrouter not available", call. = FALSE)

rows  <- utils::read.csv(TEMPLATE, stringsAsFactors = FALSE)
guide <- load_text_file(GUIDE)
stopifnot(nrow(rows) > 0, nzchar(guide))

# The system prompt is the reviewers' own guide verbatim, plus the output
# contract. Rewriting the definitions for the model would pilot a DIFFERENT
# instrument from the one the humans are given, which defeats the purpose.
system_prompt <- paste(
  guide, "",
  "You are acting as one reviewer. Judge each paper independently, using only",
  "the title and abstract supplied. Return the verdict and one short sentence",
  "of reasoning. Do not explain your role or restate the claim.",
  sep = "\n"
)

out_type <- ellmer::type_object(
  verdict = ellmer::type_enum("One of the four verdicts.", values = VERDICTS),
  note    = ellmer::type_string("One sentence: why this verdict.")
)

want <- if (length(commandArgs(trailingOnly = TRUE))) {
  q <- commandArgs(trailingOnly = TRUE)[[1L]]
  Filter(function(m) grepl(q, m$slug, fixed = TRUE), MODELS)
} else MODELS
if (!length(want)) stop("no model matches that substring", call. = FALSE)

dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

for (m in want) {
  cache_dir <- file.path(CACHE, m$slug)
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  message(sprintf("\n=== %s (%s) ===", m$slug, m$model))

  # Per-row cache, same discipline as Phase 2's: an interrupted run is resumed
  # for free, and re-running after an edit elsewhere costs nothing.
  todo <- rows[!file.exists(file.path(cache_dir, paste0(rows$id, ".json"))), , drop = FALSE]
  message(sprintf("%d of %d rows cached, %d to do", nrow(rows) - nrow(todo), nrow(rows), nrow(todo)))

  if (nrow(todo)) {
    # max_tokens 8000, not the 1000 default. Two of these three are REASONING
    # models, and thinking tokens are billed against the same budget as the
    # visible JSON -- at 1000 every gemini-2.5-pro response truncated mid-object
    # ("premature EOF") and parsed to NA. Same value, same reason, as the
    # llm_verification configs in config.yaml. It is a cap, not a reservation,
    # so it costs nothing on the non-reasoning model.
    chat <- build_llm_verification_chat(list(model = m$model, temperature = 0, max_tokens = 8000L),
                                        system_prompt, api_key)
    prompts <- sprintf("CLAIM:\n%s\n\nPAPER TITLE:\n%s\n\nABSTRACT:\n%s",
                       todo$claim, todo$title, todo$abstract)
    res <- ellmer::parallel_chat_structured(chat, as.list(prompts), type = out_type,
                                            max_active = 8, include_tokens = TRUE)
    for (k in seq_len(nrow(todo))) {
      jsonlite::write_json(res[k, , drop = FALSE],
                           file.path(cache_dir, paste0(todo$id[[k]], ".json")), auto_unbox = TRUE)
    }
  }

  got <- lapply(rows$id, function(i) {
    j <- jsonlite::read_json(file.path(cache_dir, paste0(i, ".json")), simplifyVector = TRUE)
    data.frame(id = i,
               verdict = j$verdict %||% NA_character_,
               note    = j$note    %||% NA_character_,
               stringsAsFactors = FALSE)
  }) |> bind_rows()

  # Same schema as the human instrument, so build_goldstandard() could read it
  # unchanged -- which is exactly why these files live elsewhere and are named
  # after the model that produced them.
  filled <- rows |>
    select(id, claim, title, abstract, doi) |>
    left_join(got, by = "id") |>
    mutate(reviewer = m$model, date = as.character(Sys.Date()))

  path <- file.path(OUTDIR, sprintf("R1_%s_%s.csv", ASSESSMENT, m$slug))
  utils::write.csv(filled, path, row.names = FALSE, na = "")
  bad <- setdiff(stats::na.omit(unique(filled$verdict)), VERDICTS)
  if (length(bad)) warning(sprintf("%s: unrecognised verdict(s): %s", m$slug, paste(bad, collapse = ", ")))
  message(sprintf("wrote %s", path))
  print(filled |> count(verdict) |> mutate(pct = round(100 * n / sum(n), 1)))
}

writeLines(c(
  "# NOT A GOLD STANDARD",
  "",
  "These files are LLM output, produced by scripts/run_ai_reviewers.R as a PILOT",
  "of the reviewer instrument. They are not human labels and must never be",
  "copied into input/goldstandard/ or used as the benchmark's `human` reference.",
  "",
  "R/build_goldstandard.R exists precisely because a model that reproduced a",
  "wrong judge perfectly would score perfectly. Every NLI model benchmarked here",
  "was distilled from gpt-4o-mini's labels; scoring them against other LLMs'",
  "labels measures agreement between language models, not accuracy.",
  "",
  "What these ARE good for: checking whether REVIEWER_GUIDE.md is unambiguous",
  "enough that independent readers converge, and a cheap prior on how rare",
  "REFUTES really is, before two humans spend a week finding out."
), file.path(OUTDIR, "NOT_A_GOLD_STANDARD.md"))
message("\ndone")
