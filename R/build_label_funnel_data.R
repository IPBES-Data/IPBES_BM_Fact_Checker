# Label funnel counts for one assessment: a 3-level sieve of distinct
# citing works per (km, bm), for a given NLI label ("REFUTES" or
# "SUPPORTS") --
#   1. snowball corpus     -- every citing work in works_citing
#   2. NLI <label>-certain -- label == target_label & uncertain == FALSE
#   3. LLM-confirmed       -- of (2), llm_agrees == TRUE
# Each level is a subset of the previous one. A fourth level, "+ sufficient
# evidence" (sufficient_evidence == TRUE), was considered for the original
# REFUTES-only version and dropped: Phase 2's own parser forces llm_label to
# NOT_ENOUGH_INFO whenever sufficient_evidence is FALSE (see
# select_llm_verification_candidates()'s caller in
# build_llm_verification_parquet.R), so llm_agrees == TRUE already implies
# sufficient_evidence == TRUE by construction -- a fourth level would always
# be identical to the third, never narrowing anything further. Consumed by
# build_label_funnel_figures()/build_label_funnel_tables() and by
# IPBES_Label_Funnel_Report.qmd, mirroring build_nli_overview_data()'s
# read-once-cache-everything shape so downstream targets never re-collect()
# the raw parquet.
build_label_funnel_data <- function(
  assessment,
  target_label,
  works_citing_path,
  nli_scores_evidence_path,
  llm_verification_path,
  output_root = "output/tables",
  granularity = "naive_bm",
  nli_active = "deberta_zeroshot"
) {
  assessment_id <- assessment$id
  label_stem <- tolower(target_label)
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  fn <- file.path(
    output_root,
    sprintf(
      "%s_funnel_data_%s%s%s.rds", label_stem, assessment_id,
      nli_model_suffix(nli_active), granularity_suffix(granularity)
    )
  )

  empty_result <- function() {
    saveRDS(
      list(
        assessment = assessment_id, label = target_label, granularity = granularity,
        nli_active = nli_active, empty = TRUE
      ),
      file = fn
    )
    fn
  }

  # Level 1 requires works_citing_parquet, which is always present once the
  # snowball has run; levels 2-3 require NLI scoring and Phase 2 LLM
  # verification, which may not have reached this assessment yet -- treat
  # either missing directory as "nothing to show" rather than erroring, same
  # convention as build_nli_overview_data().
  if (!dir.exists(works_citing_path) || !dir.exists(nli_scores_evidence_path) ||
    !dir.exists(llm_verification_path)) {
    return(empty_result())
  }

  level1 <- arrow::open_dataset(works_citing_path) |>
    dplyr::select(km, bm, work_id = id) |>
    dplyr::distinct() |>
    dplyr::collect()

  level2 <- arrow::open_dataset(nli_scores_evidence_path) |>
    dplyr::select(km, bm, work_id, label, uncertain) |>
    dplyr::filter(label == .env$target_label, !uncertain) |>
    dplyr::distinct(km, bm, work_id) |>
    dplyr::collect()

  # Defensive: llm_verification/scores may contain rows from several routes
  # (e.g. REFUTES-certain and SUPPORTS-certain both present once both are
  # routed) -- filter to this label's own route explicitly rather than
  # assuming it's the only value present.
  route <- paste0(target_label, "-certain")
  lv <- arrow::open_dataset(llm_verification_path) |>
    dplyr::filter(nli_route == .env$route) |>
    dplyr::select(km, bm, work_id, claim_id, claim, nli_confidence, llm_agrees, quote, explanation) |>
    dplyr::collect()

  # DOI lookup, same pattern as build_nli_overview_data.R: works_citing's id
  # is the same "https://openalex.org/W..." string as work_id elsewhere; a
  # work can appear once per km/bm partition it's cited from, so collapse to
  # one row per work_id before joining to avoid fan-out.
  doi_lookup <- arrow::open_dataset(works_citing_path) |>
    dplyr::select(work_id = id, doi) |>
    dplyr::collect() |>
    dplyr::group_by(work_id) |>
    dplyr::summarise(doi = dplyr::first(doi[!is.na(doi)], default = NA_character_), .groups = "drop")

  level3_detail <- lv |>
    dplyr::filter(llm_agrees) |>
    dplyr::left_join(doi_lookup, by = "work_id")

  if (!nrow(level1)) {
    return(empty_result())
  }

  # "Distinct citing works" is scoped to each (km, bm) group throughout, not
  # deduped globally across BMs within the assessment -- a work matching two
  # different BMs is two findings, not one, matching how every other table
  # in this project (works_parquet, nli_overview_data's n_total) treats
  # (km, bm, work) as the natural row unit. funnel_overall's counts are
  # therefore the SUM of funnel_by_bm's per-BM counts, computed from the same
  # by_bm() tables so the two views are consistent by construction.
  by_bm <- function(d, col) {
    d |>
      dplyr::distinct(km, bm, work_id) |>
      dplyr::count(km, bm, name = col)
  }
  funnel_by_bm <- by_bm(level1, "n1") |>
    dplyr::full_join(by_bm(level2, "n2"), by = c("km", "bm")) |>
    dplyr::full_join(by_bm(level3_detail, "n3"), by = c("km", "bm")) |>
    dplyr::mutate(dplyr::across(c(n1, n2, n3), ~ tidyr::replace_na(.x, 0L))) |>
    dplyr::mutate(
      pct_2of1 = round(100 * n2 / n1, 1),
      pct_3of2 = round(100 * dplyr::if_else(n2 > 0, n3 / n2, NA_real_), 1)
    ) |>
    dplyr::arrange(km, bm)

  level_labels <- c(
    level1 = "Snowball corpus",
    level2 = sprintf("NLI %s (certain)", target_label),
    level3 = sprintf("LLM-confirmed %s", target_label)
  )
  funnel_overall <- tibble::tibble(
    level = names(level_labels),
    label = unname(level_labels),
    n = c(sum(funnel_by_bm$n1), sum(funnel_by_bm$n2), sum(funnel_by_bm$n3))
  )

  saveRDS(
    list(
      assessment = assessment_id,
      label = target_label,
      granularity = granularity,
      nli_active = nli_active,
      empty = FALSE,
      funnel_overall = funnel_overall,
      funnel_by_bm = funnel_by_bm,
      level3_detail = level3_detail
    ),
    file = fn
  )

  fn
}
