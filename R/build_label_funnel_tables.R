# DT table for level 3 (LLM-confirmed <label>) of a label funnel, one
# BM-filterable table per assessment. Reads the rds produced by
# build_label_funnel_data() rather than re-collecting the raw parquet, same
# convention as build_label_funnel_figures(). (A level-4 table,
# "+ sufficient evidence", was dropped for the original REFUTES-only
# version: Phase 2's own parser makes sufficient_evidence == TRUE implied
# by llm_agrees == TRUE, so it was always identical to level 3 -- see
# build_label_funnel_data.R.)
#
# Calls DT::datatable() directly instead of going through IPBES.R::table_dt()
# -- that wrapper's `...` lands inside `options = list(...)`, but `filter` is
# a top-level datatable() argument, so `filter = "top"` (needed for the BM
# dropdown) can't be threaded through it. The extensions/options shape below
# is copied from table_dt() by hand to stay visually consistent with the
# project's other DT tables (build_overlap_key_paper_table.R).
#
# DT's filter = "top" renders a filter widget for EVERY column passed to
# datatable() (a <select> for factor columns, incl. km/bm here), not just
# the one column you want a dropdown for -- so the column set below is
# deliberately curated down to only what's useful to filter/read per row,
# rather than including every column build_label_funnel_data() carries.
build_label_funnel_tables <- function(label_funnel_data_path, output_root = "output/tables") {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  x <- readRDS(label_funnel_data_path)
  assessment_id <- x$assessment
  label_stem <- tolower(x$label)
  gran_suffix <- granularity_suffix(x$granularity %||% "naive_bm")
  model_suffix <- nli_model_suffix(x$nli_active %||% "deberta_zeroshot")

  if (isTRUE(x$empty)) {
    return(character(0))
  }

  # Same DOI-preferred/OpenAlex-fallback link builder as
  # build_nli_bm_explorer.R's drill-down table.
  work_link <- function(work_id, doi) {
    id_short <- sub("^https://openalex\\.org/", "", work_id)
    if (!is.na(doi) && nzchar(doi)) {
      doi_short <- sub("^https://doi\\.org/", "", doi)
      sprintf('<a href="%s" target="_blank" rel="noopener">%s</a>', doi, doi_short)
    } else {
      sprintf('<a href="%s" target="_blank" rel="noopener">%s (OpenAlex)</a>', work_id, id_short)
    }
  }

  label_funnel_datatable <- function(data, fn) {
    DT::datatable(
      data = data,
      extensions = c("Buttons", "FixedColumns", "Scroller"),
      filter = "top",
      rownames = FALSE,
      options = list(
        dom = "Bfrtip",
        buttons = list(
          list(extend = "csv", filename = fn),
          list(extend = "excel", filename = fn),
          "print"
        ),
        scroller = TRUE,
        scrollY = DT::JS("window.innerHeight * 0.7 + 'px'"),
        scrollX = TRUE,
        fixedColumns = list(leftColumns = 2)
      ),
      escape = FALSE
    )
  }

  l3 <- x$level3_detail |>
    dplyr::mutate(
      km = factor(km),
      bm = factor(bm),
      work = mapply(work_link, work_id, doi),
      nli_confidence = round(nli_confidence, 3)
    ) |>
    dplyr::select(km, bm, work, claim, nli_confidence, quote, explanation)

  fn_l3_rds <- file.path(output_root, sprintf("%s_funnel_table_l3_%s%s%s.rds", label_stem, assessment_id, model_suffix, gran_suffix))
  fn_l3_html <- file.path(output_root, sprintf("%s_funnel_table_l3_%s%s%s.html", label_stem, assessment_id, model_suffix, gran_suffix))
  saveRDS(l3, file = fn_l3_rds)
  label_funnel_datatable(l3, sprintf("%s_funnel_l3", label_stem)) |>
    htmlwidgets::saveWidget(file = fn_l3_html, selfcontained = TRUE)

  c(fn_l3_rds, fn_l3_html)
}
