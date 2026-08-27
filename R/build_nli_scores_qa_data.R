# QA data for Phase 1 (NLI scoring) — one assessment x granularity
# combination, resolved to whichever nli_config actually produced that
# granularity's scores (see nli_config_for_granularity(), R/branch_helpers.R
# -- nli_config passed in here is already resolved that way by the caller,
# not assumed to be nli.active). Sibling to build_bm_split_highlighted.R
# (which QAs the segmentation step); this QAs the scoring step itself.
#
# nli_scores_evidence never stores title/abstract/doi (only work_id) --
# those live in works_citing_parquet, joined in AFTER capping so the join
# only ever touches the rows that survive (not the full ~1-2M row scored
# table).
#
# per_claim_cap default (50) was chosen by direct measurement against real
# GA1 x complete_bm data (60 claims, ~594K scored rows): 200/claim rendered
# a 30.6MB self-contained HTML (comparable to nli_bm_explorer_html's own
# ~37MB, but still large for a single file); 50/claim renders ~8.5MB -- a
# more comfortable size while still giving a substantial per-claim sample.
# This is a QA/spot-check view, not a full corpus browser (that's what
# nli_bm_explorer_html already is).
#
build_nli_scores_qa_data <- function(
  assessment,
  nli_scores_path,
  works_citing_path,
  nli_config,
  granularity,
  output_root = "output/tables",
  per_claim_cap = 50L,
  keypaper_scores_path = NULL,
  nli_scores_keypaper_evidence = NULL # unused -- establishes the DAG dependency on the key-paper scoring chain, same convention as build_llm_verification_parquet()'s own nli_scores_by_claim_evidence argument
) {
  assessment_id <- assessment$id
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

  fn <- file.path(
    output_root,
    sprintf(
      "nli_scores_qa_%s%s%s.rds",
      assessment_id, nli_model_suffix(nli_config), granularity_suffix(granularity)
    )
  )

  # Same reasoning as build_nli_overview_data.R/build_label_funnel_data.R:
  # not every (assessment, granularity) combination has been scored yet --
  # treat a missing directory as an empty result rather than erroring.
  if (!dir.exists(nli_scores_path)) {
    saveRDS(
      list(assessment = assessment_id, granularity = granularity, nli_config = nli_config, empty = TRUE),
      file = fn
    )
    return(fn)
  }

  d <- arrow::open_dataset(nli_scores_path) |>
    dplyr::select(
      km, bm, claim_id, claim, work_id, label,
      p_supports, p_refutes, p_nei, confidence, uncertain
    ) |>
    dplyr::collect()

  if (!nrow(d)) {
    saveRDS(
      list(assessment = assessment_id, granularity = granularity, nli_config = nli_config, empty = TRUE),
      file = fn
    )
    return(fn)
  }

  # Confusion matrix: label x confidence-decile, on the FULL (uncapped)
  # data -- this must reflect the true distribution, not whatever survives
  # the per-claim cap below. cut() isn't Arrow-lazy-safe (same failure mode
  # as sprintf() inside a lazy mutate() -- see R/find_orphaned_nli_scores.R),
  # so this runs on the already-collect()ed tibble.
  label_levels <- c("SUPPORTS", "NOT_ENOUGH_INFO", "REFUTES")
  decile_levels <- sprintf("%.1f-%.1f", seq(0, 0.9, 0.1), seq(0.1, 1, 0.1))
  matrix_tbl <- d |>
    dplyr::mutate(
      decile = cut(
        confidence, breaks = seq(0, 1, 0.1), include.lowest = TRUE,
        labels = decile_levels
      )
    ) |>
    dplyr::count(label, decile) |>
    tidyr::pivot_wider(names_from = decile, values_from = n, values_fill = 0) |>
    dplyr::select(label, dplyr::any_of(decile_levels)) |>
    dplyr::arrange(factor(label, levels = label_levels))

  # Cap per (km, bm, claim_id) -- the claim is the natural QA unit here, so
  # capping at this level (rather than per BM) means one work-heavy claim
  # never crowds out every other claim's rows within the same BM. Keep the
  # highest-confidence rows first; carry the group's TRUE size as
  # n_total_claim so truncation is never silent (same ethos as
  # build_nli_bm_explorer.R's table_row_cap/download_row_cap).
  capped <- d |>
    dplyr::group_by(km, bm, claim_id) |>
    dplyr::mutate(n_total_claim = dplyr::n()) |>
    dplyr::arrange(dplyr::desc(confidence), .by_group = TRUE) |>
    dplyr::slice_head(n = per_claim_cap) |>
    dplyr::ungroup()

  # Join title/abstract/doi only for the rows that survived capping --
  # works_citing's own id/doi/title/abstract can repeat across the
  # (km, bm) partitions a work is cited from, so collapse to one row per id
  # first (picking any non-NA field), same defensive pattern
  # build_nli_overview_data.R's doi_lookup already uses.
  work_lookup <- arrow::open_dataset(works_citing_path) |>
    dplyr::select(work_id = id, doi, title, abstract) |>
    dplyr::filter(work_id %in% unique(capped$work_id)) |>
    dplyr::collect() |>
    dplyr::group_by(work_id) |>
    dplyr::summarise(
      doi      = dplyr::first(doi[!is.na(doi)], default = NA_character_),
      title    = dplyr::first(title[!is.na(title)], default = NA_character_),
      abstract = dplyr::first(abstract[!is.na(abstract)], default = NA_character_),
      .groups = "drop"
    )

  capped <- dplyr::left_join(capped, work_lookup, by = "work_id") |>
    dplyr::arrange(km, bm, claim_id, dplyr::desc(confidence))

  # Build the DT widget itself HERE, in the targets session, and cache the
  # widget object (not the raw data frame) -- quarto::quarto_render() runs
  # QA_NLI_Scores_Report.qmd in its own fresh session that never sources
  # R/*.R (same reasoning IPBES_Label_Funnel_Report.qmd's setup chunk gives
  # for inlining gran_suffix()/nli_model_suffix() rather than sourcing
  # R/branch_helpers.R there), so nli_scores_qa_datatable() must not be
  # called from the qmd itself. A DT::datatable() object is a plain,
  # self-contained htmlwidget (no captured R closures) -- saveRDS()/
  # readRDS() then auto-printing it in any session with the DT package
  # installed renders identically, so caching the built widget here avoids
  # both the source() problem and duplicating this function's logic a
  # second time inline in the qmd.
  widget <- nli_scores_qa_datatable(capped)

  # % of rows actually won by each label -- for the ternary figure's corner
  # labels (R/build_nli_scores_qa_figures.R). Computed here (label is already
  # in `d`) rather than re-derived from probs there, so it can never drift
  # from the label column score_one_claim() itself assigned. `label_n`
  # (raw counts, same names) is kept alongside for the key-paper
  # significance test below -- prop.test() needs counts, not percentages.
  label_n <- d |>
    dplyr::count(label) |>
    tibble::deframe()
  # Reindex to all 3 levels (a label with zero rows would otherwise be
  # silently absent from deframe()'s output) so downstream code can always
  # index label_n[[lab]] for any of nli_label_levels without an NA/missing
  # surprise.
  label_n <- label_n[nli_label_levels]
  label_n[is.na(label_n)] <- 0L
  names(label_n) <- nli_label_levels
  label_pct <- 100 * label_n / sum(label_n)

  # Key papers (the actual seed/reference works IPBES cites as evidence for
  # a BM, scored against that same BM's claim -- see
  # R/build_nli_ready_evidence_keypaper_parquet.R) overlaid on the ternary
  # figure as a QA sanity check: since a key paper IS the evidence a BM was
  # written from, it should overwhelmingly land in the SUPPORTS region.
  # Optional -- keypaper_scores_path won't exist until that (separate,
  # RunPod-calling) chain has actually been run; NULL/missing degrades to
  # "no overlay" rather than erroring, same empty-state convention as the
  # rest of this function.
  keypaper_points <- NULL
  if (!is.null(keypaper_scores_path) && dir.exists(keypaper_scores_path)) {
    kp <- arrow::open_dataset(keypaper_scores_path) |>
      dplyr::select(km, bm, work_id, p_supports, p_refutes, p_nei) |>
      dplyr::collect()

    if (nrow(kp)) {
      # Collapse to one point per (paper, BM) -- a key paper is evidence for
      # the BM as a whole, not for one specific claim within it (we don't
      # have claim-level evidence-to-paper mapping yet; that would need
      # finer, e.g. atomic_bm-level, segmentation tied back to which
      # specific evidence brace cites which reference). Under complete_bm
      # a BM can have 2 claims (bm_description + bm_label), so without this
      # a single (paper, BM) reference relationship would otherwise show as
      # two near-duplicate overlapping points rather than one.
      keypaper_points <- kp |>
        dplyr::group_by(work_id, km, bm) |>
        dplyr::summarise(
          p_supports = mean(p_supports),
          p_refutes = mean(p_refutes),
          p_nei = mean(p_nei),
          .groups = "drop"
        ) |>
        dplyr::mutate(
          x = p_refutes + p_supports * 0.5,
          y = p_supports * sqrt(3) / 2
        )
    }
  }

  # Validation summary for the report text -- what fraction of key papers
  # actually landed in SUPPORTS (the expected outcome), so a QA reader
  # doesn't have to eyeball the figure to get the headline number.
  keypaper_summary <- NULL
  keypaper_label_pct <- NULL
  keypaper_label_pvalue <- NULL
  if (!is.null(keypaper_points)) {
    keypaper_summary <- keypaper_points |>
      dplyr::summarise(
        n = dplyr::n(),
        pct_supports = round(100 * mean(p_supports >= p_refutes & p_supports >= p_nei), 1)
      )

    # Same shape as `label_pct` above (% of rows by argmax label), but for
    # key papers instead of all scored citing works -- lets the ternary
    # figure's corner labels show both side by side (e.g. "REFUTES (12.3%)
    # [8.0%]"): the full-corpus share next to the key-paper share, so a QA
    # reader can see at a glance whether key papers land in each region
    # proportionally more or less than citing works do. No `label` column
    # on `keypaper_points` (it's an average across a paper's claims, not a
    # single scored row), so the winning label is the argmax of the
    # averaged probabilities directly.
    keypaper_label_n <- keypaper_points |>
      dplyr::mutate(
        label = nli_label_levels[max.col(cbind(p_supports, p_nei, p_refutes), ties.method = "first")]
      ) |>
      dplyr::count(label) |>
      tibble::deframe()
    # tibble::deframe() drops any label with zero key papers -- restore it as
    # 0 so keypaper_label_pct/the significance test below always have an
    # entry for all three labels, matching label_n's shape.
    keypaper_label_n <- keypaper_label_n[nli_label_levels]
    keypaper_label_n[is.na(keypaper_label_n)] <- 0L
    names(keypaper_label_n) <- nli_label_levels
    n_keypapers <- sum(keypaper_label_n)
    keypaper_label_pct <- 100 * keypaper_label_n / n_keypapers

    # Is the key-paper share in each corner significantly different from the
    # full-corpus share, or could it plausibly be the same underlying rate
    # just sampled at n=573? Two-proportion test (prop.test(), Yates
    # continuity-corrected) per label: key-paper count/n_keypapers vs.
    # full-corpus count/n_total. Full-corpus n so dwarfs n_keypapers that
    # this is effectively "is the key-paper rate different from a fixed
    # reference rate," which is exactly the comparison the ternary figure's
    # bracketed corner percentages are already making visually.
    keypaper_label_pvalue <- vapply(nli_label_levels, function(lab) {
      tryCatch(
        stats::prop.test(
          x = c(keypaper_label_n[[lab]], label_n[[lab]]),
          n = c(n_keypapers, sum(label_n))
        )$p.value,
        error = function(e) NA_real_
      )
    }, numeric(1))
    names(keypaper_label_pvalue) <- nli_label_levels
  }

  saveRDS(
    list(
      assessment     = assessment_id,
      granularity    = granularity,
      nli_config     = nli_config,
      empty          = FALSE,
      n_total        = nrow(d),
      n_shown        = nrow(capped),
      per_claim_cap  = per_claim_cap,
      matrix         = matrix_tbl,
      label_pct      = label_pct,
      # Raw class probabilities only (no text columns) -- kept for the
      # ternary density figure, which needs the full uncapped distribution,
      # not a decile summary. ~14MB for 594K rows, small next to the
      # widget already cached here.
      probs          = d |> dplyr::select(p_supports, p_refutes, p_nei),
      keypaper_points = keypaper_points,
      keypaper_summary = keypaper_summary,
      keypaper_label_pct = keypaper_label_pct,
      keypaper_label_pvalue = keypaper_label_pvalue,
      widget         = widget
    ),
    file = fn
  )

  fn
}

# DT table for the claims x scores view. Called from build_nli_scores_qa_data()
# above (in the targets session, where this file is already sourced) -- the
# resulting widget object is what gets cached, not called again later.
#
# Bypasses IPBES.R::table_dt() for the same reason build_label_funnel_tables.R
# does -- filter = "top" is a top-level datatable() arg its wrapper can't
# forward. Same column-curation reasoning too: filter = "top" puts a filter
# widget on every displayed column, so only columns worth filtering/reading
# per row are included.
nli_scores_qa_datatable <- function(df) {
  work_link <- function(work_id, doi) {
    id_short <- sub("^https://openalex\\.org/", "", work_id)
    if (!is.na(doi) && nzchar(doi)) {
      doi_short <- sub("^https://doi\\.org/", "", doi)
      sprintf('<a href="%s" target="_blank" rel="noopener">%s</a>', doi, doi_short)
    } else {
      sprintf('<a href="%s" target="_blank" rel="noopener">%s (OpenAlex)</a>', work_id, id_short)
    }
  }

  disp <- df |>
    dplyr::mutate(
      km    = factor(km),
      bm    = factor(bm),
      label = factor(label),
      work  = mapply(work_link, work_id, doi),
      confidence = round(confidence, 3),
      p_supports = round(p_supports, 3),
      p_refutes  = round(p_refutes, 3),
      p_nei      = round(p_nei, 3)
    ) |>
    dplyr::select(
      km, bm, claim_id, claim, work, title, abstract,
      label, confidence, p_supports, p_refutes, p_nei,
      n_total_claim
    )

  DT::datatable(
    data = disp,
    extensions = c("Buttons", "FixedColumns", "Scroller"),
    filter = "top",
    rownames = FALSE,
    options = list(
      dom = "Bfrtip",
      buttons = list(
        list(extend = "csv", filename = "nli_scores_qa"),
        list(extend = "excel", filename = "nli_scores_qa"),
        "print"
      ),
      scroller = TRUE,
      scrollY = DT::JS("window.innerHeight * 0.7 + 'px'"),
      scrollX = TRUE,
      fixedColumns = list(leftColumns = 3)
    ),
    escape = FALSE
  )
}
