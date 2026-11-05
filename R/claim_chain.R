# Helpers for the MERGED citing / key-paper chain.
#
# Phase 1 of the fold (2026-10-07) made `keypaper=<true|false>` a hive partition
# level above `assessment=` in all three fact-check trees. Phase 2, here, removed
# the seven duplicate targets that wrote into the two sides of it:
#
#   claim_work_pairs_keypaper  claim_units_keypaper       claim_units_keypaper_flat
#   claim_scores_keypaper      claim_scores_keypaper_consolidated
#   relevance_screen_keypaper  llm_verification_keypaper_parquet
#
# WHY THE DUPLICATION WAS WORTH REMOVING, beyond the target count: it had already
# drifted. claim_scores_keypaper_consolidated passed neither `assessments=` nor
# `km=`, so its prune glob visited every group under the scorer root -- the exact
# failure its citing twin's comment calls "not a hypothetical". claim_units_keypaper
# had to have km_scope retro-fitted after the move from the training project,
# where there was no km: field to thread, and until then `km: ["C."]` scoped the
# citing works while silently scoring every key paper of every KM. Each of those
# is a one-line divergence between two declarations that were meant to be the
# same shape.
#
# WHAT IS NOT MERGED, deliberately: the two Phase 2 BUILDERS
# (build_llm_verification_parquet / build_llm_verification_keypaper_parquet) are
# still separate functions, called side by side from one target. The plan for
# this phase proposed merging them behind a conditional candidate filter,
#
#     keypaper | (label %in% nli_labels & uncertain %in% allowed)
#
# and named that the single highest-risk line in the whole change: wrong one way
# and key papers silently stop being reviewed, wrong the other and 2.43M citing
# pairs go to full OpenRouter coverage. Calling the two functions with their own
# explicit routing removes the duplicate TARGET without ever writing that line.
# Merging the two functions remains worth doing -- the real duplication is their
# shared chunking/retry/cache/assembly loop -- but it is a refactor of two large
# functions, not a target-graph change, and it does not have to happen here.


# Units and scored records both carry their own `keypaper` tag (set by
# build_claim_units(), echoed by score_one_claim_jev()'s record). Filtering on
# the tag rather than re-deriving it from a path is what keeps the two sides from
# being mixed up by a formula that drifts.
# All three merged targets return BOTH sides' roots, and every one of those roots
# ends in its own `keypaper=<t|f>` level -- claim_work_pairs' two output dirs,
# consolidate_claim_scores()' disk_root, build_llm_relevance_screen()'s
# output_path. So one splitter serves all of them.
#
# Split by the PARTITION LEVEL IN THE PATH, never by position. Position would
# work today and would silently pick the wrong side the first time a builder
# returned its paths in a different order -- and "the wrong side" here means key
# papers scored into the citing partition under a correct-looking name.
keypaper_path <- function(paths, keypaper = FALSE, what = "path") {
  want <- paste0("keypaper=", tolower(as.character(isTRUE(keypaper))))
  # Match the keypaper= SEGMENT anywhere in the path, not basename(). The three
  # builders put it at different depths and only two of them end on it:
  #   claim_work_pairs          .../keypaper=false/assessment=GA1
  #   consolidate_claim_scores  .../scorer_config=jev_atomic_bm/keypaper=false
  #   relevance screen          .../assessment=GA1/keypaper=false
  # A basename() test passed a hand-built fixture and then found 0 of 2 paths on
  # the first real run, because the fixture was what I assumed the builder
  # returned rather than what it returns.
  hit <- paths[vapply(
    strsplit(paths, .Platform$file.sep, fixed = TRUE),
    function(parts) want %in% parts,
    logical(1)
  )]
  if (length(hit) != 1L) {
    stop(sprintf(
      "%s: expected exactly one path ending in %s, found %d in: %s",
      what, want, length(hit), paste(paths, collapse = ", ")
    ), call. = FALSE)
  }
  hit
}

claim_work_pairs_path <- function(paths, keypaper = FALSE) {
  keypaper_path(paths, keypaper, "claim_work_pairs_path")
}

claim_scores_consolidated_path <- function(paths, keypaper = FALSE) {
  keypaper_path(paths, keypaper, "claim_scores_consolidated_path")
}

claim_relevance_path <- function(paths, keypaper = FALSE) {
  keypaper_path(paths, keypaper, "claim_relevance_path")
}

claim_side <- function(x, keypaper = FALSE) {
  Filter(function(e) is.list(e) && identical(isTRUE(e$keypaper), isTRUE(keypaper)), x)
}

# Consolidate both subtrees in one call, returning both roots.
#
# The two sides MUST be consolidated separately rather than in one pass: each has
# its own disk root and its own .scratch root under the keypaper= level, and
# consolidate_claim_scores() prunes by comparing a subtree against the claim list
# it was given. Handing it the combined list while pointing at one subtree would
# make every one of the other side's claims look like an orphan -- and that
# function deletes.
consolidate_claim_scores_both <- function(scored_records, claim_units, output_root,
                                          scorer_name, assessments = NULL, km = NULL) {
  vapply(c(FALSE, TRUE), function(kp) {
    consolidate_claim_scores(
      claim_side(scored_records, kp),
      claim_side(claim_units, kp),
      output_root = output_root,
      scorer_name = scorer_name,
      assessments = assessments,
      km = km,
      keypaper = kp
    )
  }, character(1), USE.NAMES = FALSE)
}

# Relevance screen for both sides, returning both roots.
#
# The ROUTING DIFFERS and that difference is the point. Citing works are screened
# only over what the active llm config's nli_labels/nli_certainty select (190,759
# of GA1's 2.43M). Key papers are screened over everything, because Phase 2
# reviews every key-paper pair unconditionally -- there is no routing upstream of
# them to narrow the set.
relevance_screen_both <- function(assessment, consolidated, pairs_roots, llm_config,
                                  model, questions_file, batch_size) {
  vapply(c(FALSE, TRUE), function(kp) {
    build_llm_relevance_screen(
      assessment,
      pairs = select_llm_verification_candidates(
        file.path(claim_scores_consolidated_path(consolidated, kp),
                  paste0("assessment=", assessment$id)),
        claim_work_pairs_path(pairs_roots, kp),
        nli_labels    = if (kp) NULL else llm_config$nli_labels,
        nli_certainty = if (kp) NULL else llm_config$nli_certainty
      ),
      keypaper = kp,
      model = model,
      questions_file = questions_file,
      batch_size = batch_size
    )
  }, character(1), USE.NAMES = FALSE)
}


# Phase 2 over both sides, returning both output roots.
#
# ⚠ COVERAGE ASSERTION. Getting the two sides' coverage wrong is the one failure
# in this merge that produces no error: key papers silently dropping out of
# review looks exactly like a run where none were routed, and the opposite
# mistake spends real OpenRouter money on 2.43M pairs. So the routed counts are
# checked against what each side's rules imply, not assumed from the fact that
# the call returned.
llm_verification_both <- function(assessment, pairs_roots, consolidated, scope_path,
                                  scorer_name, llm_active, llm_config,
                                  system_prompt_file, user_prompt_file,
                                  granularity, relevance_roots, relevance_threshold) {
  citing <- build_llm_verification_parquet(
    assessment,
    claim_work_pairs_path(pairs_roots, FALSE),
    scorer_name, llm_active, llm_config,
    system_prompt_file, user_prompt_file,
    scope_path, granularity,
    claim_scores_consolidated_path(consolidated, FALSE),
    relevance_path = claim_relevance_path(relevance_roots, FALSE),
    relevance_threshold = relevance_threshold,
    keypaper = FALSE
  )

  keypaper <- build_llm_verification_keypaper_parquet(
    assessment,
    claim_work_pairs_path(pairs_roots, TRUE),
    file.path(
      out_factcheck("claim_scores"), paste0("granularity=", granularity),
      paste0("scorer_config=", scorer_name), "keypaper=true",
      paste0("assessment=", assessment$id)
    ),
    scorer_name, llm_active, llm_config,
    system_prompt_file, user_prompt_file,
    claim_scores_consolidated_path(consolidated, TRUE),
    relevance_path = claim_relevance_path(relevance_roots, TRUE),
    relevance_threshold = relevance_threshold,
    keypaper = TRUE
  )

  assert_phase2_coverage(assessment, consolidated, llm_config, scorer_name, granularity)
  c(citing, keypaper)
}


# Counts, per side, how many scored pairs each side's rules SHOULD route, and
# warns loudly when a side routes nothing. A warning rather than a stop: "no
# candidates" is a legitimate outcome for a narrow KM scope, and this target is
# deployment = "main", so stopping here takes the whole run down. The point is
# that it can never be silent.
assert_phase2_coverage <- function(assessment, consolidated, llm_config, scorer_name, granularity) {
  for (kp in c(FALSE, TRUE)) {
    root <- file.path(claim_scores_consolidated_path(consolidated, kp),
                      paste0("assessment=", assessment$id))
    if (!dir.exists(root)) next
    n <- tryCatch({
      d <- arrow::open_dataset(root)
      if (kp) {
        nrow(d)
      } else {
        lab <- llm_config$nli_labels
        cert <- llm_config$nli_certainty
        q <- d
        if (!is.null(lab)) q <- dplyr::filter(q, label %in% !!lab)
        if (!is.null(cert)) {
          if (identical(cert, "certain")) q <- dplyr::filter(q, !uncertain)
          if (identical(cert, "uncertain")) q <- dplyr::filter(q, uncertain)
        }
        nrow(q)
      }
    }, error = function(e) NA_integer_)
    message(sprintf("[phase2 coverage] %s keypaper=%s -- %s pair(s) match this side's routing rules",
                    assessment$id, tolower(as.character(kp)),
                    if (is.na(n)) "could not count" else format(n, big.mark = ",")))
    if (!is.na(n) && n == 0L) {
      warning(sprintf(
        "[phase2 coverage] %s keypaper=%s routed ZERO pairs. For keypaper=true that means key papers are not being reviewed at all -- check that claim_scores_consolidated holds a keypaper=true subtree.",
        assessment$id, tolower(as.character(kp))
      ), call. = FALSE)
    }
  }
}
