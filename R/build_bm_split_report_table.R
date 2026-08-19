# QA table for how nli_ready_evidence_parquet actually split each BM into
# claims -- one row per (BM, claim), showing the original bm_description/
# bm_label text alongside every resulting claim (and, for naive_bm/
# atomic_bm, the confidence qualifier extracted out of it -- see
# R/build_nli_ready_evidence_parquet.R's segment_bm_confidence_pattern).
# Works for any granularity: complete_bm's output has no `confidence`
# column at all, handled gracefully via dplyr::any_of() the same way
# build_nli_ready_evidence_parquet()'s own cross-join does.
#
# Deliberately reads nli_ready_evidence_parquet's ACTUAL on-disk output
# (distinct()-ed back down to one row per claim, undoing the per-citing-work
# cross-join) rather than recomputing segmentation separately -- this is a
# downstream QA step over what the real target produced, not an independent
# pre-check, so it can never drift from what actually got scored.
#
# Calls DT::datatable() directly rather than through IPBES.R::table_dt(),
# same reasoning as build_label_funnel_tables.R: filter = "top" is a
# top-level datatable() argument that wrapper's `...` can't reach.
build_bm_split_report_table <- function(
  assessment,
  nli_ready_evidence_parquet,
  key_messages_parquet,
  granularity,
  output_root = "output/tables"
) {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  assessment_id <- assessment$id
  # Deliberately NOT granularity_suffix() (which omits the suffix for the
  # "naive_bm" default, to keep other reports' pre-existing published
  # filenames unchanged) -- this report has no legacy filenames to protect,
  # and always naming the granularity explicitly is clearer for a QA
  # artifact meant to be compared across granularities side by side.
  gran_suffix <- paste0("_", granularity)

  # Arrow's dplyr backend doesn't support any_of() as a lazy selection
  # (errors "Expression not supported in Arrow") -- resolve the real column
  # set in plain R first (select() only the columns actually present, cheap
  # to do before collect() since it avoids pulling premise/token columns
  # into memory just to distinct() them away), then collect before any
  # any_of()-based logic, which works fine once the data is a plain tibble.
  ds <- arrow::open_dataset(nli_ready_evidence_parquet)
  base_cols <- c("km", "bm", "sentence_source", "sentence_number", "claim")
  cols <- if ("confidence" %in% names(ds)) c(base_cols, "confidence") else base_cols

  claims <- ds |>
    dplyr::select(dplyr::all_of(cols)) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::arrange(km, bm, sentence_source, sentence_number)

  km_root <- unique(dirname(key_messages_parquet))[[1L]]
  bm_info <- arrow::open_dataset(km_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, bm, bm_description, bm_label) |>
    dplyr::distinct() |>
    dplyr::collect()

  joined <- claims |>
    dplyr::left_join(bm_info, by = c("km", "bm")) |>
    dplyr::mutate(
      original_text = dplyr::if_else(
        sentence_source == "bm_description", bm_description, bm_label
      ),
      km = factor(km),
      bm = factor(bm),
      sentence_source = factor(sentence_source)
    ) |>
    dplyr::select(
      km, bm, sentence_source, original_text, sentence_number, claim,
      dplyr::any_of("confidence")
    )

  fn_stem <- sprintf("bm_split_report_table_%s%s", assessment_id, gran_suffix)

  dt <- DT::datatable(
    data = joined,
    extensions = c("Buttons", "FixedColumns", "Scroller"),
    filter = "top",
    rownames = FALSE,
    options = list(
      dom = "Bfrtip",
      buttons = list(
        list(extend = "csv", filename = fn_stem),
        list(extend = "excel", filename = fn_stem),
        "print"
      ),
      scroller = TRUE,
      scrollY = DT::JS("window.innerHeight * 0.7 + 'px'"),
      scrollX = TRUE,
      fixedColumns = list(leftColumns = 3)
    ),
    escape = FALSE
  )

  fn_rds <- file.path(output_root, paste0(fn_stem, ".rds"))
  fn_html <- file.path(output_root, paste0(fn_stem, ".html"))
  saveRDS(
    list(assessment = assessment_id, granularity = granularity, data = joined),
    file = fn_rds
  )
  htmlwidgets::saveWidget(dt, file = fn_html, selfcontained = TRUE)

  c(fn_rds, fn_html)
}
