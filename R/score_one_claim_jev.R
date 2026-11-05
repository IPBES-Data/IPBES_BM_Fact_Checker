# Phase 1 scored by Jev instead of the NLI pool.
#
# WHY THIS EXISTS. The zero-shot NLI was measured on 2026-10-05 against
# refutations confirmed by three independent reviewers: AUC 0.50 for REFUTES and
# 0.38 for SUPPORTS -- chance and below -- while Jev reached 0.737 [0.63, 0.84]
# on the same rows. See design_notes.md points 6 and 8.
#
# THE OUTPUT SCHEMA IS IDENTICAL to score_one_claim()'s, so uncertain_threshold,
# the nli_route= partitions, the funnel sieve, consolidate_claim_scores() and every
# report downstream keep working untouched. Selecting it is a config edit --
# `backend: jev` on an nli.configs.<name> entry -- which also gives it its own
# scorer_config= tree, so it scores BESIDE the NLI on identical rows rather than
# instead of it. The human round has not happened, every measurement above comes
# from models judging models, and comparing the two afterwards is the point of
# waiting.
#
# WHAT IS DUPLICATED FROM score_one_claim(), and why. The resumability block
# (consolidated U scratch, delta on work_id, content guard, complete-row-set
# scratch write) is reproduced rather than shared -- the same reasoning
# build_llm_verification_keypaper_parquet.R documents for its own duplication.
# score_one_claim() is delicate, carries a bug history worth not disturbing, and
# is still the production path for every existing score.
#
# WHAT IS NOT DUPLICATED. No host locking, no pool health, no crew sizing by host
# count: there is no pod.

JEV_ENDPOINT <- "https://openrouter.ai/api/alpha/decisions"

# The question lives in input/prompts/jev_claim_questions.json, not here.
#
# Same convention as llm_verification_system.md: a prompt is DATA, tracked as a
# format = "file" target, so editing it invalidates what it produced. The file
# carries its own rationale -- why Choice rather than three Nouls, and why the
# item goes inside the question rather than in the shared state.
jev_question_spec <- function(path = "input/prompts/jev_claim_questions.json") {
  if (!file.exists(path)) stop(sprintf("jev question file not found: %s", path), call. = FALSE)
  spec <- jsonlite::read_json(path, simplifyVector = FALSE)
  q <- spec$question
  if (!identical(q$type, "choice")) {
    stop(sprintf("%s: question type must be 'choice', got '%s'", path, q$type %||% "NULL"), call. = FALSE)
  }
  missing <- setdiff(c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO"), names(q$criteria))
  if (length(missing)) stop(sprintf("%s: criteria missing %s", path, paste(missing, collapse = ", ")), call. = FALSE)
  spec
}

# ONE request carries the claim once in `state` and up to `papers_per_request`
# questions, each with its OWN paper inline.
#
# THE ITEM MUST BE IN THE QUESTION, NOT IN THE STATE. "Question IDs are for code
# and are not sent to the model", so a question keyed by work_id against a state
# holding many papers cannot say which paper it means, and the model answers
# about the blob. Measured before this was understood: 40 papers in state
# collapsed to 3 distinct answers, and a controlled triple returned
# 0.750/0.750/0.750 on a supports question with the SUPPORTING paper scoring
# 0.89 on refutes. With the item inline the effect disappears -- Spearman against
# per-paper scoring is 0.91 at 10 per request, 0.85 at 20, 0.88 at 40, against a
# 0.87 run-to-run baseline. Batch size is a throughput knob, not a quality one.
#
# NOTE for build_llm_relevance_screen.R: it still batches the OLD way (papers in
# state, questions keyed by work_id) and has the same defect -- 7,889 works under
# one claim share 23 distinct values. Nothing has been filtered on those scores
# (threshold is `~`), but they are not per-paper rankings.
jev_request <- function(claim, part, spec, model, api_key) {
  q <- spec$question
  questions <- setNames(lapply(seq_len(nrow(part)), function(i) list(
    type = "choice",
    instructions = list(paper = part$premise[i], question = q$instructions_question),
    criteria = q$criteria
  )), part$work_id)
  httr2::request(JEV_ENDPOINT) |>
    httr2::req_auth_bearer_token(api_key) |>
    httr2::req_body_json(list(model = model, state = list(claim = claim), questions = questions),
                         auto_unbox = TRUE) |>
    # No client-side rate limiter, same reasoning as the relevance screen: the
    # published limits adjust dynamically and "can change without notice".
    httr2::req_retry(max_tries = 5) |>
    httr2::req_timeout(180)
}

score_one_claim_jev <- function(
  claim_unit,
  scorer_config,
  scorer_name,
  scorer_model,
  output_root = out_factcheck("claim_scores"),
  questions_file = "input/prompts/jev_claim_questions.json",
  api_key = Sys.getenv("API_openrouter"),
  max_active = 100L,
  # ACCEPTED AND IGNORED since 2026-10-09, the same way build_llm_relevance_screen()
  # treats its own batch_size: chunking by count cannot respect a token limit, and
  # respecting the token limit is the whole point. Kept so existing call sites and
  # the signature stay valid.
  papers_per_request = 20L,
  # Which chain this is. A HIVE PARTITION LEVEL above assessment=, not a
  # column, and not below assessment= -- consolidate_claim_scores() globs with a
  # $-anchored "/assessment=/km=/bm=$" regex that an inserted level would break,
  # and the two chains need separate .scratch roots because scratch files are
  # named <claim_id>.parquet and would otherwise collide between a citing and a
  # key-paper branch for the same claim.
  #
  # Defaults to the unit's OWN tag, set by build_claim_units(). One merged
  # claim_scores_by_claim target branches over both chains' units, so a fixed
  # argument here would send every branch to the same partition.
  keypaper = isTRUE(claim_unit$keypaper)
) {
  cfg <- if (is.null(scorer_config)) list() else scorer_config
  assessment_id <- claim_unit$assessment
  this_claim_id <- claim_unit$claim_id
  model <- cfg$model %||% "typesafe/jev-1.13"
  uncertain_threshold <- as.numeric(cfg$uncertain_threshold %||% 0.60)

  kp_level <- paste0("keypaper=", tolower(as.character(isTRUE(keypaper))))
  output_path <- file.path(output_root, paste0("scorer_config=", scorer_name), kp_level,
                           paste0("assessment=", assessment_id))
  bm_dir <- file.path(output_path, paste0("km=", claim_unit$km), paste0("bm=", claim_unit$bm))
  scratch_dir <- file.path(output_root, ".scratch", paste0("scorer_config=", scorer_name), kp_level,
                           paste0("assessment=", assessment_id),
                           paste0("km=", claim_unit$km), paste0("bm=", claim_unit$bm))
  scratch_file <- file.path(scratch_dir, paste0(this_claim_id, ".parquet"))

  record <- function(status, n_rows = 0L, n_new = 0L) {
    list(scorer_config = scorer_name, assessment = assessment_id,
         keypaper = isTRUE(keypaper),
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
    bad_model <- !all(cached$scorer_model == scorer_model, na.rm = TRUE)
    bad_claim <- "claim" %in% names(cached) && !all(cached$claim == claim_unit$claim, na.rm = TRUE)
    if (bad_model || bad_claim) {
      message(sprintf("[jev %s] claim_id=%s: cache discarded (%s changed) -- full rescore",
                      assessment_id, this_claim_id, if (bad_model) "model" else "claim text"))
      cached <- NULL
    }
  }
  # A work with NO SCORE was never scored, so it must NOT count as done.
  #
  # Failed requests deliberately yield NA rows rather than dropped ones (see the
  # failure path below), so that a pair missing from the output cannot later read
  # as "never scored" and be re-dispatched. But the resume check used to take
  # every work_id in the cache, NA scores included -- which meant any request
  # failure marked its pairs complete FOREVER. The run reported no error: the
  # claim finished, the rows were written, and the gap was invisible except for
  # one "N of M works unscored" line in a long log.
  #
  # That is survivable for a transient blip and not survivable for the case it
  # was most likely to meet: OpenRouter credit running out mid-run, which fails
  # every remaining request and so silently freezes the corpus at wherever the
  # money stopped.
  #
  # Filtering on p_supports costs at most a second attempt at pairs that were
  # probably never billed anyway -- a 402 or an exhausted retry returns no usage
  # -- and trades that against a permanent, silent coverage hole.
  # Drop unscored rows from `cached` ENTIRELY, not just from `already`.
  #
  # The first version of this fix filtered only `already`, so the failed pairs
  # were correctly re-sent -- but `cached` still held their NA rows, and the
  # scratch write below binds `cached` to the new scores. Every recovered pair
  # therefore landed TWICE: once NA, once scored. Measured on 2026-10-09: the
  # corpus grew by exactly the NA count (A. +580, B. +2,280) while the NA count
  # itself did not move, which is the signature of that duplication.
  #
  # One filter, one source of truth: a row with no score is not evidence of
  # anything and must not survive into the output.
  if (!is.null(cached) && nrow(cached)) {
    cached <- cached[!is.na(cached$p_supports), , drop = FALSE]
    if (!nrow(cached)) cached <- NULL
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
  spec <- jev_question_spec(questions_file)
  # CHUNK BY TOKEN BUDGET, not by a fixed count. chunk_by_tokens() is the one
  # build_llm_relevance_screen.R already uses against this same endpoint, and it
  # is here for the reason that file documents: premise length is wildly uneven,
  # so a fixed batch of 20 carries ~8k tokens at the median and breaches the
  # API's 32k `state` limit whenever it happens to collect a few long ones. The
  # request then 400s, on_error = "continue" turns the whole batch into NA rows,
  # and because the batching is deterministic it fails identically on every
  # retry and every re-run.
  #
  # That was not hypothetical: 2,860 pairs across 28 claims and 7 BMs sat
  # permanently unscored on 2026-10-09, in counts that were all exact multiples
  # of 20 -- whole requests, never individual pairs. Their premises were of
  # ordinary length (median 378 against the corpus's 392); it took only a couple
  # of the 0.29% above 1,600 tokens to push one batch over.
  #
  # A single over-budget premise still gets its own chunk rather than being
  # dropped -- the server truncates, which is lossy but recoverable, where
  # dropping is neither.
  #
  # Side effect: at a ~390-token median the budget fits ~60 papers per request
  # rather than 20, so this makes ~3x FEWER requests. The screen measured the
  # same thing (15 requests -> 3 on a 294-work claim) and got faster.
  parts <- chunk_by_tokens(cw)
  resps <- httr2::req_perform_parallel(
    lapply(parts, function(part) jev_request(claim_unit$claim, part, spec, model, api_key)),
    max_active = max_active, on_error = "continue")

  # Choice returns the distribution and the confidence DIRECTLY, so there is
  # nothing to cross-normalise -- unlike the zero-shot head, which needs three
  # forward passes folded together. A failed request yields NA rows rather than
  # dropped ones: a pair silently missing would later read as "never scored" and
  # be re-paid for, and NA is distinguishable from a real low score.
  got <- dplyr::bind_rows(Map(function(part, resp) {
    parsed <- tryCatch(httr2::resp_body_json(resp), error = function(e) NULL)
    num <- function(x) if (is.null(x)) NA_real_ else as.numeric(x)
    v <- vapply(part$work_id, function(w) {
      a <- parsed$answers[[w]]
      c(num(a$probabilities$SUPPORTS), num(a$probabilities$REFUTES),
        num(a$probabilities$NOT_ENOUGH_INFO), num(a$confidence))
    }, numeric(4), USE.NAMES = FALSE)
    dplyr::tibble(work_id = part$work_id, p_supports = v[1, ], p_refutes = v[2, ],
                  p_nei = v[3, ], confidence = v[4, ])
  }, parts, resps))

  n_failed <- sum(is.na(got$p_supports))
  if (n_failed) message(sprintf("[jev %s] claim_id=%s: %d of %d works unscored (request failures)",
                                assessment_id, this_claim_id, n_failed, nrow(got)))

  lvl <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")
  argmax <- apply(as.matrix(got[, c("p_supports", "p_refutes", "p_nei")]), 1L,
                  function(r) if (all(is.na(r))) NA_integer_ else which.max(r))

  out <- dplyr::tibble(
    scorer_model       = scorer_model,
    sentence_number = claim_unit$sentence_number,
    sentence_source = claim_unit$sentence_source,
    claim           = claim_unit$claim,
    work_id         = got$work_id,
    label           = lvl[argmax],
    p_supports      = got$p_supports,
    p_refutes       = got$p_refutes,
    p_nei           = got$p_nei,
    # Choice's own confidence, not max(p): "Choice/Score confidence summarizes
    # distribution concentration", which is what uncertain_threshold has always
    # meant here.
    confidence      = got$confidence,
    uncertain       = !is.na(got$confidence) & got$confidence < uncertain_threshold,
    claim_id        = this_claim_id,
    assessment      = assessment_id,
    km              = claim_unit$km,
    bm              = claim_unit$bm
  )

  # The scratch file must carry the claim's COMPLETE row set:
  # consolidate_claim_scores() supersedes every row whose claim_id appears in
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
