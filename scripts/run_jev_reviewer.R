#!/usr/bin/env Rscript
# Jev as a FOURTH kind of reviewer on the same 200 rows -- a decision model, not
# a chat model, so it cannot emit the instrument's four-value verdict. It answers
# ONE yes/no question per row and returns a probability, which is exactly the
# right shape for the question this sample turns out to be about: of the 100 rows
# gpt-4o-mini called REFUTES, how many actually contradict their claim?
#
# Worth having precisely because it is not another chat model: a different
# architecture agreeing with the chat models is far stronger evidence than a
# fourth chat model agreeing, and at $0.0000172/pair the whole run costs ~$0.01.
#
# Two questions are asked per row:
#   refutes  -- does the abstract contradict the claim?
#   supports -- does it support the claim?
# Asking both separately, rather than one three-way question, keeps each in the
# binary shape the model is built for, and the pair is informative where a single
# probability is not: low on both is NOT_ENOUGH_INFO.
#
# Usage:  Rscript scripts/run_jev_reviewer.R
suppressPackageStartupMessages(library(dplyr))
source("R/build_llm_relevance_screen.R")   # chunk_by_tokens(), RELEVANCE_ENDPOINT, budget

# Paths overridable for the same reason run_ai_reviewers.R's are: a second,
# REFUTES-enriched instrument lives in input/ai_goldstandard_refutes/.
ASSESSMENT <- "GA1"
TEMPLATE <- Sys.getenv("NLI_REVIEW_TEMPLATE",
                       file.path("input/goldstandard", sprintf("R1_%s_template.csv", ASSESSMENT)))
OUTDIR   <- Sys.getenv("NLI_REVIEW_OUTDIR", "input/ai_goldstandard")
MODEL    <- "typesafe/jev-1.13"

api_key <- Sys.getenv("API_openrouter")
if (!nzchar(api_key)) api_key <- keyring::key_get("API_openrouter")
if (!nzchar(api_key)) stop("API_openrouter not available", call. = FALSE)

rows <- utils::read.csv(TEMPLATE, stringsAsFactors = FALSE)

QUESTIONS <- list(
  refutes = list(
    instructions = "Does this paper report a finding that CONTRADICTS the claim -- that makes the claim less likely to be true?",
    criteria = list(
      "true"  = "the abstract reports a result inconsistent with the claim, or in the opposite direction",
      "false" = "the abstract does not contradict the claim, whether it supports it, is unrelated, or says nothing either way")),
  supports = list(
    instructions = "Does this paper report a finding that SUPPORTS the claim -- that makes the claim more likely to be true?",
    criteria = list(
      "true"  = "the abstract reports a result consistent with the claim and bearing on it",
      "false" = "the abstract does not support the claim, whether it contradicts it, is unrelated, or says nothing either way"))
)

# One request per row, carrying BOTH questions. The decisions API keys
# `questions` by id (an object, not an array -- an array is a 400) and they
# share the row's `state`, so asking both in one call halves the requests at no
# extra token cost. `auto_unbox = TRUE` is required, as in the relevance screen.
ask <- function(claim, title, abstract) {
  body <- list(
    model = MODEL,
    state = sprintf("CLAIM:\n%s\n\nPAPER TITLE:\n%s\n\nABSTRACT:\n%s", claim, title, abstract),
    questions = lapply(QUESTIONS, function(q)
      list(type = "noul", instructions = q$instructions, criteria = q$criteria))
  )
  r <- httr2::request(RELEVANCE_ENDPOINT) |>
    httr2::req_auth_bearer_token(api_key) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_retry(max_tries = 5) |>
    httr2::req_timeout(90) |>
    httr2::req_perform()
  p <- httr2::resp_body_json(r)
  list(refutes  = p$answers[["refutes"]]$noul  %||% NA_real_,
       supports = p$answers[["supports"]]$noul %||% NA_real_,
       cost     = as.numeric(p$usage$cost %||% 0))
}

res <- vector("list", nrow(rows))
for (k in seq_len(nrow(rows))) {
  a <- ask(rows$claim[k], rows$title[k], rows$abstract[k])
  res[[k]] <- data.frame(id = as.character(rows$id[k]),
                         p_refutes = a$refutes, p_supports = a$supports,
                         cost = a$cost, stringsAsFactors = FALSE)
  if (k %% 25 == 0) message(sprintf("  %d/%d", k, nrow(rows)))
}
out <- bind_rows(res)

# Collapse the two probabilities into the instrument's vocabulary so the file
# can sit beside the chat models' and be compared directly. The 0.5 cut is the
# obvious first choice and nothing has calibrated it -- the raw probabilities
# are kept in the file so a better cut can be applied without re-running.
out$verdict <- with(out, ifelse(p_refutes >= 0.5 & p_refutes > p_supports, "REFUTES",
                         ifelse(p_supports >= 0.5, "SUPPORTS", "NOT_ENOUGH_INFO")))
filled <- rows |> select(id, claim, title, abstract, doi) |>
  mutate(id = as.character(id)) |>
  left_join(out, by = "id") |>
  mutate(note = sprintf("p_refutes=%.3f p_supports=%.3f", p_refutes, p_supports),
         reviewer = MODEL, date = as.character(Sys.Date()))

dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)
path <- file.path(OUTDIR, sprintf("R1_%s_jev-1.13.csv", ASSESSMENT))
utils::write.csv(filled, path, row.names = FALSE, na = "")
message(sprintf("wrote %s  (cost $%.4f)", path, sum(out$cost, na.rm = TRUE)))
print(filled |> count(verdict))
