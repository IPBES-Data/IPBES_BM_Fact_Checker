# Relevance score for each already-reviewed (claim, work) pair.
#
# WHAT PROBLEM THIS ADDRESSES. quote_is_verbatim() checks that the LLM's cited
# quote EXISTS in the premise. It does not check that the quote BEARS on the
# claim, and reading real disagreements showed that gap is not theoretical: five
# REFUTES verdicts whose quotes were genuinely present and genuinely irrelevant
# -- a paper on flow regulation and exotic riparian plants cited against a claim
# about climate change extending invasive species' range. Every one passed the
# verbatim check.
#
# A second model is asked one narrow question per pair -- does this paper bear
# on this claim at all? -- and the answer is STORED, not acted on. Measured on
# 300 stratified pairs, P(addresses) medians were NOT_ENOUGH_INFO 0.12,
# REFUTES 0.36, SUPPORTS 0.49. REFUTES sitting nearer NEI than SUPPORTS is the
# quantitative form of what the quotes showed.
#
# A COLUMN, NOT A FILTER. Same discipline Phase 1 already applies: score_one_claim()
# stores the full probability distribution and every threshold decision happens
# downstream in dplyr. Persisting the score means changing your mind about a
# cutoff costs nothing; baking a filter in here would make it cost another run.
# Nothing in the pipeline reads this yet -- deliberately. Whether 0.3 discards
# real findings is unknown until a human has read the cases, and a screen that
# silently drops a genuine refutation is worse than a noisy label.
#
# NO LLM RE-RUN. This annotates pairs Phase 2 has already reviewed; the money is
# spent and the verdicts stand. It touches neither the prompts nor the output
# schema, so the Phase 2 cache key -- a hash over system prompt + user template
# + output schema -- is unaffected and nothing re-reviews. (Contrast the other
# proposed fix, having the LLM PICK a quote from enumerated candidates rather
# than generate one: that changes the schema, so it starts a fresh cache
# namespace and every pair is re-reviewed at full price.)
#
# BATCHED ONE CLAIM AT A TIME. The decisions API takes many questions per
# request against shared `state`, so one request carries a claim plus its
# candidate works -- the shape score_one_claim() already dispatches in.
# Measured: $0.0000172/pair batched against $0.0000377 per-pair, and answers
# correlate 0.904 with the per-pair run.

RELEVANCE_ENDPOINT <- "https://openrouter.ai/api/alpha/decisions"

# Free-standing so a future screen can move to another model without touching
# callers; the model id is recorded per row either way.
relevance_question <- function(work_id) {
  list(
    type = "noul",
    instructions = paste(
      "Does this paper address the specific subject of the claim closely enough",
      "that its findings bear on whether the claim is true?"
    ),
    criteria = list(
      "true"  = "the paper studies the same phenomenon, taxa, driver or region the claim is about, and its findings speak to the claim",
      "false" = "the paper is about a related but different topic, so its findings cannot settle the claim either way"
    )
  )
}

# Split a claim's works into requests by TOKEN BUDGET, not by a fixed count.
#
# The decisions API caps `state` plus the longest question at 32,000 tokens
# (docs.typesafe.ai/models), and `state` here carries the claim plus every
# premise in the chunk. Premise length is wildly uneven -- measured on GA1's
# key-paper corpus, 290 tokens at the median but 5,875 at the maximum -- so a
# fixed batch of 20 ranges from ~10k tokens at p90 to ~117k in the worst case,
# i.e. 3.7x over the limit and a hard 400 partway through a long run.
#
# Budgeting instead gives LARGER chunks for short premises (~46 per request at
# p90, so fewer requests) and smaller ones where abstracts are long. A single
# premise over budget still gets its own chunk rather than being dropped: the
# server truncates, which is lossy but recoverable, where dropping is neither.
#
# 4 chars/token is the usual English approximation and is deliberately rough --
# the budget below is 75% of the real limit, so the estimate has room to be
# wrong without failing.
RELEVANCE_STATE_BUDGET <- 24000L

chunk_by_tokens <- function(works, budget = RELEVANCE_STATE_BUDGET) {
  est <- nchar(works$premise) / 4
  grp <- integer(nrow(works))
  g <- 1L
  used <- 0
  for (i in seq_len(nrow(works))) {
    if (used > 0 && used + est[i] > budget) {
      g <- g + 1L
      used <- 0
    }
    grp[i] <- g
    used <- used + est[i]
  }
  split(works, grp)
}

# One request per claim. `works` is a data frame with work_id / premise.
#
# CONCURRENT, not sequential. Each request carries batch_size questions against
# one shared `state`, and the requests themselves go out max_active at a time
# via httr2::req_perform_parallel() -- the same shape Phase 2 next door uses
# (ellmer's own max_active, 24 on every shipped llm_verification config).
#
# This matters more than it looks. The work is almost entirely waiting on the
# network: ~239,000 already-reviewed pairs at batch 20 is ~11,950 requests, and
# at the ~0.5-1 s each measured that is 3-5 HOURS sequentially for something
# that should take minutes. Batching alone does not fix it; batching reduces
# the NUMBER of requests, concurrency reduces the time spent blocked on each.
score_one_claim_relevance <- function(claim, works, model, api_key,
                                      batch_size = NULL, max_active = 12L) {
  # batch_size is accepted and ignored, so existing callers keep working; the
  # token budget supersedes it. Chunking by count cannot respect a token limit.
  chunks <- chunk_by_tokens(works)

  reqs <- lapply(chunks, function(chunk) {
    body <- list(
      model = model,
      state = list(
        description = "One assessment claim and the papers cited against it. Judge only from the papers.",
        claim = claim,
        papers = lapply(seq_len(nrow(chunk)), function(i) {
          list(id = chunk$work_id[i], text = chunk$premise[i])
        })
      ),
      questions = setNames(lapply(chunk$work_id, relevance_question), chunk$work_id)
    )
    httr2::request(RELEVANCE_ENDPOINT) |>
      httr2::req_auth_bearer_token(api_key) |>
      httr2::req_body_json(body, auto_unbox = TRUE) |>
      # 429 is in httr2's default is_transient set and Retry-After is honoured
      # automatically. Deliberately NO client-side rate limiter: the published
      # limits (100K tokens/sec, 40 req/sec) "adjust dynamically" and "can
      # change without notice", so any hardcoded ceiling is wrong eventually.
      # Backoff finds the real one.
      httr2::req_retry(max_tries = 5)
  })

  # on_error = "continue" so one bad chunk cannot abandon the rest; failures
  # come back as condition objects and are turned into NA rows below.
  resps <- httr2::req_perform_parallel(reqs, max_active = max_active,
                                       on_error = "continue")

  dplyr::bind_rows(Map(function(chunk, resp) {
    parsed <- tryCatch(httr2::resp_body_json(resp), error = function(e) NULL)
    if (is.null(parsed) || is.null(parsed$answers)) {
      # A failed chunk yields NA rather than dropped rows: a pair silently
      # missing from the output would later read as "not scored yet" and be
      # re-paid for, and NA is distinguishable from a real low score.
      return(dplyr::tibble(
        work_id = chunk$work_id, addresses = NA_real_,
        relevance_model = NA_character_, relevance_cost = NA_real_
      ))
    }
    dplyr::tibble(
      work_id = chunk$work_id,
      addresses = vapply(chunk$work_id, function(w) {
        v <- parsed$answers[[w]]$noul
        if (is.null(v)) NA_real_ else as.numeric(v)
      }, numeric(1)),
      relevance_model = parsed$model %||% model,
      # Per-pair share of the batch's cost, so summing the column gives the
      # true total whatever batch size was used.
      relevance_cost = (parsed$usage$cost %||% NA_real_) / nrow(chunk)
    )
  }, chunks, resps))
}

# TWO USES, ONE QUESTION. `pairs_path` decides which:
#
#   ANNOTATE (retroactive) -- point it at an llm_verification/scores* directory.
#     Scores pairs Phase 2 has ALREADY reviewed. Saves nothing; the money is
#     spent. What it buys is a relevance score beside each existing verdict, so
#     a threshold can be chosen later without re-running anything.
#
#   SCREEN (prospective) -- point it at the ROUTED candidates, before Phase 2
#     runs. This is the placement in input/mmd/overview.mmd: between Phase 1 and
#     Phase 2, filtering pairs before the LLM spends on them at 8.7x the price.
#
# The scoring call itself needs only claim + premise -- nothing the NLI or the
# LLM produces -- so the same function serves both. Only the pair list differs.
# Getting this wrong is easy: the first version of this file hardcoded the
# Phase 2 path, which quietly made the "screen" impossible to run before Phase 2.
#
# `premise_path` is the matching nli_ready_evidence(_keypaper) root, because
# neither the routed candidates nor Phase 2's own output stores premise text.
build_llm_relevance_screen <- function(
  assessment,
  # EITHER a path (annotate: an llm_verification/scores* directory of pairs
  # already reviewed) OR a data frame of candidates (screen: what
  # select_llm_verification_candidates() returns, before Phase 2 runs). The
  # prospective use cannot take a path, because the routed candidate set is a
  # function's return value and is never written to disk -- an omission in the
  # first version of this file that would have made the screen impossible to
  # run in the position input/mmd/overview.mmd draws it.
  pairs,
  premise_path = NULL,
  # Which chain these pairs came from. A REAL PARTITION LEVEL, not a column,
  # for the same reason nli_training partitions on it: the two chains score
  # DIFFERENT pairs (claims x key papers vs claims x citing works) and each
  # must be able to run, re-run and be deleted without touching the other.
  #
  # Sharing one store across both was considered and is not worth it: measured
  # on GA1, the two chains share 399 of 29,496 key-paper pairs (1.35%), so
  # deduplicating would save under a cent and cost a lookup on every write.
  # Those 399 are simply scored twice.
  keypaper,
  model = "typesafe/jev-1.13",
  output_root = "output/llm_relevance",
  api_key = Sys.getenv("API_openrouter"),
  batch_size = 20L,
  max_active = 12L
) {
  assessment_id <- assessment$id
  output_path <- file.path(output_root, paste0("assessment=", assessment_id),
                           paste0("keypaper=", tolower(as.character(keypaper))))

  has_data <- function(p) {
    !is.null(p) && dir.exists(p) &&
      length(list.files(p, pattern = "\\.parquet$", recursive = TRUE)) > 0L
  }
  if (is.character(pairs)) {
    if (!has_data(pairs)) {
      message(sprintf("[relevance %s keypaper=%s] nothing at %s", assessment_id, keypaper, pairs))
      dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
      return(output_path)
    }
    pairs <- arrow::open_dataset(pairs) |>
      dplyr::select(km, bm, claim_id, claim, work_id) |>
      dplyr::distinct() |>
      dplyr::collect()
  }
  if (!nrow(pairs)) {
    message(sprintf("[relevance %s keypaper=%s] no pairs", assessment_id, keypaper))
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    return(output_path)
  }
  if (!nzchar(api_key)) stop("API_openrouter not set")

  # Candidates from select_llm_verification_candidates() already carry premise;
  # rows read from a Phase 2 directory do not, because Phase 2's own output
  # stores no premise text -- the same reason that function joins it back from
  # the nli_ready tree.
  if (!"premise" %in% names(pairs)) {
    if (is.null(premise_path)) stop("pairs carry no premise column and premise_path is NULL")
    premises <- arrow::open_dataset(premise_path) |>
      dplyr::select(work_id, premise) |>
      dplyr::distinct(work_id, .keep_all = TRUE) |>
      dplyr::collect()
    pairs <- pairs |> dplyr::inner_join(premises, by = "work_id")
  }
  claims <- split(pairs, list(pairs$km, pairs$bm, pairs$claim_id), drop = TRUE)
  message(sprintf("[relevance %s] %d pairs across %d claims",
                  assessment_id, nrow(pairs), length(claims)))

  scored <- vector("list", length(claims))
  for (i in seq_along(claims)) {
    g <- claims[[i]]
    r <- score_one_claim_relevance(g$claim[1], g, model, api_key, batch_size, max_active)
    scored[[i]] <- g |>
      dplyr::select(km, bm, claim_id, work_id) |>
      dplyr::left_join(r, by = "work_id")
    if (i %% 25 == 0) message(sprintf("  %d/%d claims", i, length(claims)))
  }
  res <- dplyr::bind_rows(scored)
  res$assessment <- assessment_id
  res$keypaper <- as.logical(keypaper)

  # Unlink only THIS chain's subtree. Clearing assessment=<id>/ wholesale would
  # delete the other chain's scores -- the collision this partition exists to
  # prevent.
  if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)
  arrow::write_dataset(res, output_root, format = "parquet",
                       partitioning = c("assessment", "keypaper"),
                       existing_data_behavior = "delete_matching")
  message(sprintf(
    "[relevance %s] wrote %d rows (%d NA) to %s, cost $%.4f",
    assessment_id, nrow(res), sum(is.na(res$addresses)), output_path,
    sum(res$relevance_cost, na.rm = TRUE)
  ))
  output_path
}

# Drop candidates a relevance screen scored below `threshold` (TD: the Jev
# screen, input/mmd/overview.mmd). Returns `candidates` unchanged when either
# argument is absent, which is the DEFAULT -- the threshold is deliberately
# null in config.yaml until a human has validated it.
#
# Why off by default: measured on 300 stratified pairs, a 0.3 cutoff keeps 76%
# of true SUPPORTS -- so it also discards ~24% of them, and nobody has yet
# checked whether those are marginal cases or real findings. A screen that
# wrongly drops a pair leaves NO TRACE: the LLM never sees it, so there is no
# verdict, no failed quote check, nothing to audit. That is the one failure
# mode in this design with no error and no signal, which is why turning it on
# is a deliberate config edit rather than a default.
apply_relevance_screen <- function(candidates, relevance_path, threshold) {
  if (is.null(relevance_path) || is.null(threshold) || !nrow(candidates)) return(candidates)
  if (!dir.exists(relevance_path) ||
      !length(list.files(relevance_path, pattern = "\\.parquet$", recursive = TRUE))) {
    warning(sprintf("relevance screen requested but nothing at %s -- not filtering", relevance_path))
    return(candidates)
  }
  rel <- arrow::open_dataset(relevance_path) |>
    dplyr::select(km, bm, claim_id, work_id, addresses) |>
    dplyr::collect()
  before <- nrow(candidates)
  out <- candidates |>
    dplyr::left_join(rel, by = c("km", "bm", "claim_id", "work_id")) |>
    # An unscored pair (NA) is KEPT. A pair the screen never reached must not
    # be silently dropped: that would turn a scoring gap into data loss.
    dplyr::filter(is.na(addresses) | addresses >= threshold) |>
    dplyr::select(-addresses)
  message(sprintf(
    "[relevance screen] %d -> %d candidates at threshold %.2f (%d dropped)",
    before, nrow(out), threshold, before - nrow(out)
  ))
  out
}
