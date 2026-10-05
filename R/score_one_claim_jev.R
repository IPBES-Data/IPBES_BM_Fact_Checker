# Phase 1 scored by Jev instead of the NLI pool.
#
# WHY THIS EXISTS. The zero-shot NLI was measured on 2026-10-05 against
# refutations confirmed by three independent reviewers: AUC 0.50 for REFUTES and
# 0.38 for SUPPORTS -- chance and below -- while Jev reached 0.737 [0.63, 0.84]
# on the same rows, handicapped (the reviewers saw the cited quote, Jev did not).
# Worse, the population the NLI routes on is DEPLETED of refutations: 0.058% of
# its REFUTES bucket score high on an independent contradiction question against
# 0.693% of the SUPPORTS-uncertain bucket it discards, so 97.7% of candidates lie
# where Phase 2 never looks. See design_notes.md points 6 and 8.
#
# THE OUTPUT SCHEMA IS IDENTICAL to score_one_claim()'s, deliberately. Jev
# answers typed binary questions, not a 3-way softmax, so three questions are
# asked per pair and CROSS-NORMALISED into (p_supports, p_refutes, p_nei). That
# is not a workaround -- it is exactly what the zero-shot head already does:
# `passes: 3` runs one forward pass per reformulated hypothesis and
# cross-normalises three entailment logits. Same operation, different model.
#
# Because the schema is unchanged, `uncertain_threshold`, the `nli_route=`
# partitions, the funnel's three-level sieve, consolidate_nli_scores() and every
# report downstream keep working untouched. Selecting it is a config edit:
# `backend: jev` on an `nli.configs.<name>` entry, which also gives it its own
# `nli_config=` output tree, so it scores BESIDE the NLI on identical rows
# rather than instead of it. That matters -- the human review round has not
# happened, every measurement above comes from models judging models, and
# comparing the two on the same rows afterwards is the whole point of waiting.
#
# WHAT IS DUPLICATED FROM score_one_claim(), and why. The resumability block
# (consolidated ∪ scratch, delta on work_id, content guard, complete-row-set
# scratch write) is reproduced rather than shared. Same reasoning
# build_llm_verification_keypaper_parquet.R already documents for its own
# duplication: score_one_claim() is delicate, carries a bug history worth not
# disturbing, and is still the production path for every existing score. An
# edit here cannot invalidate a single already-scored row there.
#
# WHAT IS NOT DUPLICATED. No host locking, no pool health, no crew sizing by
# host count: there is no pod. Concurrency is httr2's, per request, so a single
# target branch saturates the API on its own.

JEV_ENDPOINT <- "https://openrouter.ai/api/alpha/decisions"

# The three questions live in input/prompts/jev_claim_questions.json, not here.
#
# Same convention as llm_verification_system.md and claim_completion_system.md:
# a prompt is DATA, tracked as a format = "file" target, so editing it
# invalidates what it produced. That is exactly right here -- different
# questions give different scores, and a tree scored under two question sets
# would be meaningless. The file carries its own rationale, including why
# p_nei is derived from `addresses` rather than asked directly and why that
# question is word-for-word the relevance screen's own.
#
# The slot ORDER is fixed by jev_normalise() below, not by the file: a new slot
# would need code, so the file holds wording, not structure. Validated on read
# rather than trusted, because a typo in a key here would otherwise surface as
# an all-NA score column several hours into a paid run.
jev_claim_questions <- function(path = "input/prompts/jev_claim_questions.json") {
  if (!file.exists(path)) stop(sprintf("jev questions file not found: %s", path), call. = FALSE)
  q <- jsonlite::read_json(path, simplifyVector = FALSE)$questions
  want <- c("supports", "refutes", "addresses")
  missing <- setdiff(want, names(q))
  if (length(missing)) {
    stop(sprintf("%s is missing question slot(s): %s", path, paste(missing, collapse = ", ")), call. = FALSE)
  }
  for (k in want) {
    if (!identical(q[[k]]$type, "noul")) {
      stop(sprintf("%s: question '%s' must have type 'noul', got '%s'", path, k, q[[k]]$type %||% "NULL"), call. = FALSE)
    }
    if (!nzchar(q[[k]]$instructions %||% "")) {
      stop(sprintf("%s: question '%s' has no instructions", path, k), call. = FALSE)
    }
  }
  q[want]
}

# Cross-normalise three independent probabilities into a distribution.
#
# `addresses` acts as a GATE on the two directional answers rather than as a
# third competing option:
#
#   e_supports = supports x addresses
#   e_refutes  = refutes  x addresses
#   e_nei      = 1 - addresses x max(supports, refutes)
#
# then divide by the sum. The gate is what makes the triple behave sensibly in
# the two cases that matter and that a naive 1-addresses formulation gets wrong:
#
#   addresses ~ 0                 -> both directional terms collapse, e_nei ~ 1.
#                                    A paper that does not bear on the claim
#                                    cannot support or contradict it. This is the
#                                    topical-adjacency failure the whole Jev
#                                    screen exists to catch.
#   addresses ~ 1, neither fires  -> e_nei ~ 1 again. A RELEVANT paper with no
#                                    directional finding is still NOT_ENOUGH_INFO.
#                                    An earlier version of this function wrote
#                                    p_nei = 1 - addresses and divided by the sum,
#                                    which made exactly this case 0/0 and returned
#                                    NA -- scoring a real and common outcome as
#                                    "unscored". Caught before any paid run.
#
# The sum cannot reach zero: e_nei is 0 only when addresses x max(supports,
# refutes) is 1, which forces one directional term to 1. So no epsilon guard is
# needed and none is used -- NA here means the REQUEST failed, nothing else.
jev_normalise <- function(supports, refutes, addresses) {
  e_sup <- supports * addresses
  e_ref <- refutes * addresses
  e_nei <- 1 - addresses * pmax(supports, refutes)
  m <- cbind(e_sup, e_ref, e_nei)
  out <- m / rowSums(m)
  colnames(out) <- c("p_supports", "p_refutes", "p_nei")
  out
}

# ONE PAPER PER REQUEST, three requests (one per question type).
#
# This is the expensive choice and it is deliberate. The relevance screen next
# door batches ~80 papers into one request against a shared `state`, and its own
# comment records the measurement that justified it: $0.0000172/pair batched
# against $0.0000377 per-pair, "answers correlate 0.904 with the per-pair run".
#
# That correlation is across claims. WITHIN a claim it does not hold, which is
# the only thing a filter needs. Measured 2026-10-05 on 8 works of one GA1
# claim, same question, same premises:
#
#   individually   0.01 0.05 0.03 0.04 0.03 0.03 0.01 0.05   -> 4 distinct
#   batched        0.06 0.07 0.07 0.06 0.07 0.06 0.07 0.06   -> 2 distinct
#
# and a controlled triple (one paper that plainly supports a claim, one that
# plainly refutes it, one about GPU kernels) came back 0.750 / 0.750 / 0.750 on
# `supports` and 0.890 / 0.880 / 0.890 on `refutes` when batched -- the
# supporting paper scored 0.89 for CONTRADICTS. Batched, the model answers about
# the chunk, not the paper. A first-stage filter whose job is to RANK papers
# within a claim cannot use that.
#
# Cost: ~$0.000113/pair (3 x $0.0000377), so ~$275 for GA1's 2.43M citing-work
# pairs rather than the ~$120 the batched estimate implied, plus ~$3.30 for the
# 29,511 key-paper pairs. `papers_per_request` is left as an argument so the
# trade-off can be revisited with evidence rather than re-litigated from
# memory; raising it above 1 reintroduces the compression above.
jev_requests <- function(claim, chunk, model, api_key, qs, papers_per_request = 1L) {
  grp <- ceiling(seq_len(nrow(chunk)) / max(1L, papers_per_request))
  out <- list()
  for (g in unique(grp)) {
    part <- chunk[grp == g, , drop = FALSE]
    state <- list(
      description = "One assessment claim and the papers cited against it. Judge only from the papers.",
      claim = claim,
      papers = lapply(seq_len(nrow(part)), function(i) list(id = part$work_id[i], text = part$premise[i]))
    )
    for (slot in names(qs)) {
      body <- list(model = model, state = state,
                   questions = setNames(rep(list(qs[[slot]]), nrow(part)), part$work_id))
      out[[length(out) + 1L]] <- list(
        slot = slot, ids = part$work_id,
        req = httr2::request(JEV_ENDPOINT) |>
          httr2::req_auth_bearer_token(api_key) |>
          httr2::req_body_json(body, auto_unbox = TRUE) |>
          # No client-side rate limiter, same reasoning as the relevance screen:
          # the published limits adjust dynamically and "can change without
          # notice", so backoff finds the real ceiling.
          httr2::req_retry(max_tries = 5) |>
          httr2::req_timeout(120)
      )
    }
  }
  out
}

score_one_claim_jev <- function(
  claim_unit,
  nli_config,
  nli_active,
  nli_model,
  output_root = "output/nli_scores",
  questions_file = "input/prompts/jev_claim_questions.json",
  api_key = Sys.getenv("API_openrouter"),
  max_active = 12L,
  state_budget = 24000L,
  papers_per_request = 1L
) {
  cfg <- if (is.null(nli_config)) list() else nli_config
  assessment_id <- claim_unit$assessment
  this_claim_id <- claim_unit$claim_id
  model <- cfg$model %||% "typesafe/jev-1.13"
  uncertain_threshold <- as.numeric(cfg$uncertain_threshold %||% 0.60)

  output_path <- file.path(output_root, paste0("nli_config=", nli_active),
                           paste0("assessment=", assessment_id))
  bm_dir <- file.path(output_path, paste0("km=", claim_unit$km), paste0("bm=", claim_unit$bm))
  scratch_dir <- file.path(output_root, ".scratch", paste0("nli_config=", nli_active),
                           paste0("assessment=", assessment_id),
                           paste0("km=", claim_unit$km), paste0("bm=", claim_unit$bm))
  scratch_file <- file.path(scratch_dir, paste0(this_claim_id, ".parquet"))

  record <- function(status, n_rows = 0L, n_new = 0L) {
    list(nli_config = nli_active, assessment = assessment_id,
         km = claim_unit$km, bm = claim_unit$bm, claim_id = this_claim_id,
         claim = claim_unit$claim, scratch_file = scratch_file,
         status = status, n_rows = as.integer(n_rows), n_new = as.integer(n_new))
  }

  if (!nzchar(api_key)) stop("API_openrouter is required to score with the jev backend", call. = FALSE)

  # ---- resumability: consolidated ∪ scratch, scratch wins ------------------
  # Mirrors score_one_claim()'s contract exactly. The cache is discarded
  # OUTRIGHT on a model or claim-text mismatch rather than delta'd: claim_id is
  # a structural key (sentence_source-sentence_number), not a hash of the text,
  # so the same id can legitimately hold different text across runs, and scores
  # from a different model are not comparable.
  cons_files <- if (dir.exists(bm_dir)) list.files(bm_dir, "[.]parquet$", full.names = TRUE) else character(0)
  read_one <- function(f) tryCatch(
    arrow::open_dataset(f) |> dplyr::filter(claim_id == this_claim_id) |> dplyr::collect(),
    error = function(e) NULL)
  cached <- NULL
  if (length(cons_files)) cached <- dplyr::bind_rows(lapply(cons_files, read_one))
  if (file.exists(scratch_file)) {
    scr <- tryCatch(arrow::read_parquet(scratch_file), error = function(e) NULL)
    if (!is.null(scr) && nrow(scr)) {
      if (!is.null(cached) && nrow(cached)) cached <- cached[!(cached$work_id %in% scr$work_id), , drop = FALSE]
      cached <- dplyr::bind_rows(cached, scr)
    }
  }
  if (!is.null(cached) && nrow(cached)) {
    bad_model <- !all(cached$nli_model == nli_model, na.rm = TRUE)
    bad_claim <- "claim" %in% names(cached) && !all(cached$claim == claim_unit$claim, na.rm = TRUE)
    if (bad_model || bad_claim) {
      message(sprintf("[jev %s] claim_id=%s: cache discarded (%s changed) -- full rescore",
                      assessment_id, this_claim_id, if (bad_model) "model" else "claim text"))
      cached <- NULL
    }
  }
  already <- if (is.null(cached)) character(0) else unique(cached$work_id)

  claim_rows <- function(cols) {
    arrow::open_dataset(claim_unit$nli_ready_path) |>
      dplyr::filter(km == claim_unit$km, bm == claim_unit$bm,
                    sentence_number == claim_unit$sentence_number,
                    sentence_source == claim_unit$sentence_source) |>
      dplyr::select(dplyr::all_of(cols)) |> dplyr::collect()
  }
  work_ids <- unique(claim_rows("work_id")$work_id)
  if (!length(work_ids)) return(record("no_premises"))
  todo_ids <- setdiff(work_ids, already)
  if (!length(todo_ids)) return(record("already_scored", nrow(cached), 0L))

  cw <- claim_rows(c("work_id", "premise")) |>
    dplyr::distinct(work_id, .keep_all = TRUE) |>
    dplyr::filter(work_id %in% todo_ids)
  message(sprintf("[jev %s] claim_id=%s (km=%s/bm=%s): %d of %d works to score",
                  assessment_id, this_claim_id, claim_unit$km, claim_unit$bm,
                  nrow(cw), length(work_ids)))

  # ---- score ---------------------------------------------------------------
  qs <- jev_claim_questions(questions_file)
  # chunk_by_tokens() still bounds `state` for the batched path; at the default
  # one-paper-per-request it is a no-op beyond ordering.
  chunks <- chunk_by_tokens(cw, budget = state_budget)
  plan <- unlist(lapply(chunks, function(ch)
    jev_requests(claim_unit$claim, ch, model, api_key, qs, papers_per_request)), recursive = FALSE)
  resps <- httr2::req_perform_parallel(lapply(plan, `[[`, "req"),
                                       max_active = max_active, on_error = "continue")

  # A failed request yields NA for its (papers, question), not dropped rows: a
  # pair silently missing would later read as "never scored" and be re-paid for,
  # and NA is distinguishable from a real low score.
  long <- dplyr::bind_rows(lapply(seq_along(plan), function(k) {
    parsed <- tryCatch(httr2::resp_body_json(resps[[k]]), error = function(e) NULL)
    ids <- plan[[k]]$ids
    dplyr::tibble(work_id = ids, slot = plan[[k]]$slot,
                  value = vapply(ids, function(w) {
                    a <- parsed$answers[[w]]$noul
                    if (is.null(a)) NA_real_ else as.numeric(a)
                  }, numeric(1), USE.NAMES = FALSE))
  }))
  got <- long |>
    tidyr::pivot_wider(names_from = slot, values_from = value) |>
    dplyr::rename(q_sup = supports, q_ref = refutes, q_add = addresses)

  n_failed <- sum(is.na(got$q_sup))
  if (n_failed) message(sprintf("[jev %s] claim_id=%s: %d of %d works unscored (chunk failures)",
                                assessment_id, this_claim_id, n_failed, nrow(got)))

  probs <- jev_normalise(got$q_sup, got$q_ref, got$q_add)
  lvl <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")
  argmax <- apply(probs, 1L, function(r) if (all(is.na(r))) NA_integer_ else which.max(r))
  confidence <- apply(probs, 1L, function(r) if (all(is.na(r))) NA_real_ else max(r, na.rm = TRUE))

  out <- dplyr::tibble(
    nli_model       = nli_model,
    sentence_number = claim_unit$sentence_number,
    sentence_source = claim_unit$sentence_source,
    claim           = claim_unit$claim,
    work_id         = got$work_id,
    label           = lvl[argmax],
    p_supports      = probs[, "p_supports"],
    p_refutes       = probs[, "p_refutes"],
    p_nei           = probs[, "p_nei"],
    confidence      = confidence,
    uncertain       = !is.na(confidence) & confidence < uncertain_threshold,
    claim_id        = this_claim_id,
    assessment      = assessment_id,
    km              = claim_unit$km,
    bm              = claim_unit$bm
  )

  # The scratch file must carry the claim's COMPLETE row set:
  # consolidate_nli_scores() supersedes every row whose claim_id appears in
  # scratch, so writing only the delta would delete the rows it was meant to
  # extend. Same rule as score_one_claim().
  final <- if (is.null(cached) || !nrow(cached)) out else
    dplyr::bind_rows(cached[, intersect(names(cached), names(out)), drop = FALSE], out) |>
      dplyr::select(dplyr::all_of(names(out)))

  dir.create(scratch_dir, recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(scratch_file, ".tmp")
  arrow::write_parquet(final, tmp)
  file.rename(tmp, scratch_file)
  record("scored", nrow(final), nrow(out))
}
