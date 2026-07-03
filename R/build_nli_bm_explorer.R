# Interactive per-BM NLI explorer widget for one assessment.
#
# Builds a single plotly figure with three linked controls:
#   - a "select BM" dropdown (defaulting to "All BMs")
#   - a "minimum confidence" slider (default 0.5)
#   - a "table label" dropdown (REFUTES / SUPPORTS / NOT_ENOUGH_INFO,
#     defaulting to REFUTES)
# The BM dropdown and slider jointly pick one precomputed (bm, threshold)
# cell. ALL works are always shown (no filtering) — the threshold instead
# splits every bar into two STACKED segments: "confidence >= threshold"
# (solid fill, on the bottom) and "confidence < threshold" (hollow/
# outline-only, on top), so moving the slider re-partitions the same totals
# rather than hiding data:
#   1. label distribution (SUPPORTS / NOT_ENOUGH_INFO / REFUTES, % of
#      works), each label split into its above/below-threshold share, with
#      "n / N" printed above each bar (n = works with that label AND
#      confidence >= threshold; N = all works with that label)
#   2. confidence distribution: a histogram over confidence itself, so the
#      split is just "bin mid >= threshold" vs "< threshold" — plus a dashed
#      line marking the threshold
#   3. alignment (p_supports - p_refutes) distribution, each alignment bin
#      split by how many of its works meet the confidence threshold
#
# All three controls together additionally drive a 4th element below the
# three panels: a drill-down TABLE of the actual works for the current BM +
# threshold + selected label (work_id / confidence / alignment, sorted by
# confidence descending, capped to `table_row_cap` rows — flag the cap in
# its caption rather than silently truncating).
#
# Every (bm, threshold) cell's six bar/histogram traces (2 per panel), and
# every (bm, threshold, label) cell's one table trace, are precomputed once
# in R (not recomputed client-side) — this is the standard, reliable
# plotly.js updatemenu/slider pattern and works offline in a static Quarto
# HTML render (no Shiny/server needed). The three controls are combined with
# a small JS handler (see combine_js below): plotly's declarative
# button/step `args` can only set a fixed payload and can't reference the
# OTHER controls' current position, so all three are set to method="skip"
# (native dropdown/slider UI and active-index tracking still work, but no
# automatic restyle) and a tiny onRender() callback reads all three current
# indices from the rendered widget's own layout and applies the one
# combined visibility+annotation update. This avoids the controls fighting
# over/resetting each other.
#
# `raw` is the per-row (km, bm, work_id, label, confidence, alignment) data
# frame already produced by build_nli_overview_data() (its $raw element) —
# no new target/data source required.
build_nli_bm_explorer <- function(raw, assessment_id) {
  label_levels <- c("SUPPORTS", "NOT_ENOUGH_INFO", "REFUTES")
  label_colors <- c(
    SUPPORTS = "#2a9d5c", NOT_ENOUGH_INFO = "#9aa5b1", REFUTES = "#d1495b"
  )
  conf_breaks <- seq(0, 1, by = 0.05)
  aln_breaks  <- seq(-1, 1, by = 0.1)
  hollow <- function(border_color) {
    list(color = "rgba(0,0,0,0)", line = list(color = border_color, width = 1.5))
  }

  bm_choices <- sort(unique(raw$bm))
  bm_options <- c("All BMs", bm_choices)
  n_bm <- length(bm_options)

  thr_values <- seq(0, 0.9, by = 0.1)
  n_thr <- length(thr_values)
  # Default: All BMs, min. confidence 0.5.
  default_bm_idx  <- 1L
  default_thr_idx <- which.min(abs(thr_values - 0.5))

  # Drill-down table label selector — REFUTES first/default per request.
  label_sel_options <- c("REFUTES", "SUPPORTS", "NOT_ENOUGH_INFO")
  n_label <- length(label_sel_options)
  default_label_idx <- 1L
  table_row_cap <- 50L

  safe_hist <- function(v, breaks) {
    if (!length(v)) {
      return(list(mids = (breaks[-1] + breaks[-length(breaks)]) / 2, counts = rep(0L, length(breaks) - 1L)))
    }
    h <- graphics::hist(v, breaks = breaks, plot = FALSE)
    list(mids = h$mids, counts = h$counts)
  }

  stat_for <- function(bm, thr) {
    d <- if (identical(bm, "All BMs")) raw else raw[raw$bm == bm, , drop = FALSE]
    above <- !is.na(d$confidence) & d$confidence >= thr
    below <- !is.na(d$confidence) & d$confidence < thr
    n <- nrow(d)

    lab_above <- vapply(label_levels, function(l) if (n) 100 * mean(d$label == l & above) else 0, numeric(1L))
    lab_below <- vapply(label_levels, function(l) if (n) 100 * mean(d$label == l & below) else 0, numeric(1L))
    # Exact counts for the "n / N" bar labels: n = works with that label AND
    # confidence >= threshold; N = all works with that label (regardless of
    # confidence).
    lab_above_n <- vapply(label_levels, function(l) sum(d$label == l & above, na.rm = TRUE), integer(1L))
    lab_total_n <- vapply(label_levels, function(l) sum(d$label == l, na.rm = TRUE), integer(1L))

    # Confidence panel: one full (unfiltered) histogram over confidence, then
    # split each bin by whether its OWN mid is above/below the threshold —
    # the x-axis variable here IS confidence, so the bin position already
    # determines the split; no cross-tabulation needed.
    conf_h <- safe_hist(d$confidence, conf_breaks)
    conf_above <- ifelse(conf_h$mids >= thr, conf_h$counts, 0L)
    conf_below <- ifelse(conf_h$mids < thr, conf_h$counts, 0L)

    # Alignment panel: x-axis variable is alignment, a DIFFERENT variable
    # from confidence, so each bin's above/below split has to be computed by
    # histogramming the above- and below-threshold subsets separately (same
    # breaks, so their mids line up for stacking).
    aln_h_above <- safe_hist(d$alignment[above], aln_breaks)
    aln_h_below <- safe_hist(d$alignment[below], aln_breaks)

    list(
      bm = bm,
      thr = thr,
      n = n,
      n_above = sum(above),
      lab_above = lab_above,
      lab_below = lab_below,
      lab_above_n = lab_above_n,
      lab_total_n = lab_total_n,
      conf_mids = conf_h$mids,
      conf_above = conf_above,
      conf_below = conf_below,
      aln_mids = aln_h_above$mids,
      aln_above = aln_h_above$counts,
      aln_below = aln_h_below$counts,
      # Baseline stats over the FULL (unfiltered) bm subset — constant
      # across thresholds for a given bm; only pct_above (below) varies.
      conf_mean = if (n) mean(d$confidence, na.rm = TRUE) else NA_real_,
      conf_median = if (n) stats::median(d$confidence, na.rm = TRUE) else NA_real_,
      aln_mean = if (n) mean(d$alignment, na.rm = TRUE) else NA_real_
    )
  }

  # Row-major bm-outer / threshold-inner grid, 1-indexed in R; the same
  # linear order is reused 0-indexed on the JS side, so no offset math is
  # needed there beyond `bm_idx * n_thr + thr_idx`.
  stats_grid <- lapply(seq_len(n_bm), function(i_bm) {
    lapply(seq_len(n_thr), function(i_thr) stat_for(bm_options[[i_bm]], thr_values[[i_thr]]))
  })
  stats_flat <- unlist(stats_grid, recursive = FALSE)
  n_cell <- length(stats_flat)
  default_cell <- (default_bm_idx - 1L) * n_thr + default_thr_idx

  # ── Drill-down table: works for (bm, threshold, selected label) ─────────
  # Sorted by confidence descending (most-confidently-labeled first) and
  # capped at table_row_cap rows — a full unfiltered listing is not the
  # point of a drill-down/inspection table, and every (bm, threshold, label)
  # combination gets its own precomputed trace (like the bar panels above),
  # so uncapped rows would multiply the file size by however many rows the
  # single largest cell has. n_match (pre-cap) is always shown in the
  # caption so the cap is never silent.
  table_stat_for <- function(bm, thr, label) {
    d <- if (identical(bm, "All BMs")) raw else raw[raw$bm == bm, , drop = FALSE]
    d <- d[!is.na(d$confidence) & d$confidence >= thr & d$label == label, , drop = FALSE]
    n_match <- nrow(d)
    d <- d[order(-d$confidence), , drop = FALSE]
    d <- utils::head(d, table_row_cap)
    list(
      bm = bm, thr = thr, label = label,
      n_match = n_match,
      n_shown = nrow(d),
      work_id = d$work_id,
      confidence = round(d$confidence, 3),
      alignment = round(d$alignment, 3)
    )
  }
  # Row-major bm-outer / threshold-middle / label-inner grid (one level
  # deeper than stats_grid, hence unlist() twice to fully flatten).
  table_grid <- lapply(seq_len(n_bm), function(i_bm) {
    lapply(seq_len(n_thr), function(i_thr) {
      lapply(seq_len(n_label), function(i_lab) {
        table_stat_for(bm_options[[i_bm]], thr_values[[i_thr]], label_sel_options[[i_lab]])
      })
    })
  })
  table_flat <- unlist(unlist(table_grid, recursive = FALSE), recursive = FALSE)
  n_table_cell <- length(table_flat)
  default_table_cell <- (default_bm_idx - 1L) * n_thr * n_label +
    (default_thr_idx - 1L) * n_label + default_label_idx

  # ── Panel 1: label distribution (%), stacked above/below threshold ──────
  p_label <- plotly::plot_ly(height = 1000)
  for (i in seq_len(n_cell)) {
    s <- stats_flat[[i]]
    p_label <- plotly::add_trace(
      p_label,
      x = label_levels, y = unname(s$lab_above), type = "bar",
      marker = list(color = unname(label_colors[label_levels])),
      visible = (i == default_cell), showlegend = FALSE
    )
  }
  for (i in seq_len(n_cell)) {
    s <- stats_flat[[i]]
    p_label <- plotly::add_trace(
      p_label,
      x = label_levels, y = unname(s$lab_below), type = "bar",
      marker = hollow(unname(label_colors[label_levels])),
      # n / N above each stacked bar: n = works with that label AND
      # confidence >= threshold, N = all works with that label. Set on the
      # topmost ("below") trace so textposition="outside" places it above
      # the FULL stack (this trace's own bar ends exactly at the stack top).
      text = sprintf("%s/%s", format(s$lab_above_n, big.mark = ","), format(s$lab_total_n, big.mark = ",")),
      textposition = "outside", cliponaxis = FALSE,
      textfont = list(size = 10, color = "#333"),
      visible = (i == default_cell), showlegend = FALSE
    )
  }
  p_label <- plotly::layout(
    p_label,
    xaxis = list(title = ""), yaxis = list(title = "% of works", range = c(0, 100))
  )

  # ── Panel 2: confidence distribution, stacked above/below threshold ─────
  p_conf <- plotly::plot_ly(height = 1000)
  for (i in seq_len(n_cell)) {
    s <- stats_flat[[i]]
    p_conf <- plotly::add_trace(
      p_conf,
      x = s$conf_mids, y = s$conf_above, type = "bar",
      marker = list(color = "#3a6ea5"), visible = (i == default_cell), showlegend = FALSE
    )
  }
  for (i in seq_len(n_cell)) {
    s <- stats_flat[[i]]
    p_conf <- plotly::add_trace(
      p_conf,
      x = s$conf_mids, y = s$conf_below, type = "bar",
      marker = hollow("#3a6ea5"), visible = (i == default_cell), showlegend = FALSE
    )
  }
  p_conf <- plotly::layout(
    p_conf, xaxis = list(title = "Confidence"), yaxis = list(title = "Works")
  )

  # ── Panel 3: alignment distribution, stacked above/below threshold ──────
  p_aln <- plotly::plot_ly(height = 1000)
  for (i in seq_len(n_cell)) {
    s <- stats_flat[[i]]
    p_aln <- plotly::add_trace(
      p_aln,
      x = s$aln_mids, y = s$aln_above, type = "bar",
      marker = list(color = "#e08e45"), visible = (i == default_cell), showlegend = FALSE
    )
  }
  for (i in seq_len(n_cell)) {
    s <- stats_flat[[i]]
    p_aln <- plotly::add_trace(
      p_aln,
      x = s$aln_mids, y = s$aln_below, type = "bar",
      marker = hollow("#e08e45"), visible = (i == default_cell), showlegend = FALSE
    )
  }
  p_aln <- plotly::layout(
    p_aln,
    xaxis = list(title = "Alignment (p_supports - p_refutes)"),
    yaxis = list(title = "Works")
  )

  fig <- plotly::subplot(
    p_label, p_conf, p_aln,
    nrows = 1, titleX = TRUE, titleY = TRUE, margin = 0.06
  )
  fig <- plotly::layout(fig, barmode = "stack")

  # Compress the three bar/histogram panels into the TOP ~48% of the plot
  # area, leaving the bottom for the drill-down table below. Confirmed by
  # isolated repro that overriding just `domain` here preserves each axis's
  # already-set title/range (plotly::layout() merges per-axis, unlike its
  # `shapes` key which plotly::subplot() drops entirely — see the shapes
  # comment further down).
  fig <- plotly::layout(
    fig,
    yaxis = list(domain = c(0.68, 1)),
    yaxis2 = list(domain = c(0.68, 1)),
    yaxis3 = list(domain = c(0.68, 1))
  )

  # ── Drill-down table trace, one per (bm, threshold, label) cell ─────────
  # Occupies the bottom of the plot area (domain, not an x/y axis pair —
  # plotly table traces are laid out independently of the bar panels above).
  #
  # Built on its OWN fresh plot_ly() object, then spliced into `fig`'s
  # trace/attrs lists directly (rather than repeated add_trace(fig, ...)
  # calls on the already-subplot()-merged figure). Confirmed by isolated
  # repro: add_trace() called many times on a subplot()-merged object leaves
  # each new trace's internal plotly "attrs" bookkeeping entry UNNAMED
  # (independent of `inherit`), and once that unnamed-attrs list is mixed
  # with the ~1800 properly-named bar-trace attrs entries, htmlwidgets' own
  # shouldEval() validation ("must be a fully named list, or have no names")
  # fails at save time. A fresh plot_ly() object with the same repeated
  # add_trace() calls names every attrs entry correctly — splicing its
  # already-correct data/attrs into `fig` avoids the bug entirely, since
  # table traces don't need subplot()'s x/y-axis remapping anyway (their
  # position comes from the absolute `domain` set on each trace below).
  table_header <- list(
    values = c("Work ID", "Confidence", "Alignment"),
    align = "left", fill = list(color = "#eee"), font = list(size = 11)
  )
  p_table <- plotly::plot_ly()
  for (i in seq_len(n_table_cell)) {
    t <- table_flat[[i]]
    p_table <- plotly::add_trace(
      p_table,
      type = "table",
      domain = list(x = c(0, 1), y = c(0, 0.40)),
      header = table_header,
      cells = list(
        values = list(t$work_id, sprintf("%.3f", t$confidence), sprintf("%.3f", t$alignment)),
        align = "left", font = list(size = 10)
      ),
      visible = (i == default_table_cell)
    )
  }
  # p_table$x$attrs[[1]] is a phantom placeholder from the bare plot_ly()
  # base call itself (no type/x/y — resolves to a spurious default scatter
  # trace at build time, confirmed by inspecting it directly). Dropping it
  # is required for correctness, not just tidiness: left in, it silently
  # shifts every table trace's built index by one, which would make the JS
  # visibility math in combine_js below select the WRONG table for every
  # (bm, threshold, label) selection.
  fig$x$data <- c(fig$x$data, p_table$x$data)
  fig$x$attrs <- c(fig$x$attrs, p_table$x$attrs[-1])

  # Static per-panel titles — plotly::subplot() drops each sub-plot's own
  # layout(title=), so panel titles have to be explicit paper-relative
  # annotations.
  panel_title <- function(text, xref) {
    list(
      text = text, showarrow = FALSE, xref = "paper", yref = "paper",
      x = switch(xref, x = 0.10, x2 = 0.50, x3 = 0.90),
      y = 1.10, xanchor = "center", font = list(size = 13)
    )
  }
  static_annotations <- list(
    panel_title("Label distribution", "x"),
    panel_title("Confidence distribution", "x2"),
    panel_title("Alignment distribution", "x3")
  )
  dynamic_annotation <- function(s) {
    pct_above <- if (s$n) 100 * s$n_above / s$n else 0
    list(
      text = sprintf(
        "n = %s · %.0f%% ≥ %.1f confidence (solid) · mean conf %.2f · median conf %.2f · mean align %.2f",
        format(s$n, big.mark = ","), pct_above, s$thr, s$conf_mean, s$conf_median, s$aln_mean
      ),
      showarrow = FALSE, xref = "paper", yref = "paper",
      x = 0.5, y = 1.20, xanchor = "center", font = list(size = 12, color = "#555")
    )
  }
  # One per cell, JS-indexed 0-based in the same bm-outer/thr-inner order as
  # stats_flat (an R list serializes to a JSON array in that same order).
  cell_annotations <- lapply(stats_flat, dynamic_annotation)

  # Table caption — sits in the small gap between the compressed bar panels
  # (domain bottom 0.55) and the table (domain top 0.40), using ordinary
  # "paper" coordinates (these still span the whole plot area regardless of
  # how far down individual trace domains reach).
  table_caption <- function(t) {
    capped_note <- if (t$n_match > t$n_shown) {
      sprintf(" (showing top %d of %s by confidence)", t$n_shown, format(t$n_match, big.mark = ","))
    } else {
      ""
    }
    list(
      text = sprintf(
        "%s works labeled %s at confidence ≥ %.1f for %s%s",
        format(t$n_match, big.mark = ","), t$label, t$thr, t$bm, capped_note
      ),
      showarrow = FALSE, xref = "paper", yref = "paper",
      x = 0.5, y = 0.47, xanchor = "center", font = list(size = 12, color = "#555")
    )
  }
  # One per (bm, threshold, label) cell, same bm-outer/thr-middle/label-inner
  # order as table_flat.
  table_annotations <- lapply(table_flat, table_caption)

  # Threshold marker line on the confidence panel (x2/y2 axes) — one per
  # cell, so it moves with the slider even though the underlying histogram
  # x-range doesn't change.
  threshold_shape <- function(thr) {
    list(
      type = "line", xref = "x2", yref = "y2 domain",
      x0 = thr, x1 = thr, y0 = 0, y1 = 1,
      line = list(color = "#444", dash = "dot", width = 1.5)
    )
  }
  cell_shapes <- lapply(stats_flat, function(s) list(threshold_shape(s$thr)))

  bm_buttons <- lapply(seq_len(n_bm), function(i) {
    list(method = "skip", label = bm_options[[i]], args = list(list()))
  })
  thr_steps <- lapply(seq_len(n_thr), function(i) {
    list(method = "skip", label = sprintf("≥%.1f", thr_values[[i]]), args = list(list()))
  })
  label_buttons <- lapply(seq_len(n_label), function(i) {
    list(method = "skip", label = paste("Table:", label_sel_options[[i]]), args = list(list()))
  })

  fig <- plotly::layout(
    fig,
    annotations = c(
      static_annotations,
      list(cell_annotations[[default_cell]]),
      list(table_annotations[[default_table_cell]])
    ),
    updatemenus = list(
      list(
        type = "dropdown", active = default_bm_idx - 1L, x = 0, y = 1.85, xanchor = "left",
        buttons = bm_buttons
      ),
      list(
        type = "dropdown", active = default_label_idx - 1L, x = 0, y = 1.70, xanchor = "left",
        buttons = label_buttons
      )
    ),
    sliders = list(list(
      active = default_thr_idx - 1L, x = 0.30, y = 1.65, len = 0.68, xanchor = "left",
      currentvalue = list(prefix = "Min. confidence: ", font = list(size = 12)),
      pad = list(t = 10),
      steps = thr_steps
    )),
    margin = list(t = 260)
  )

  # Combine the three controls: read all three current indices from the
  # widget's own layout (the authoritative source, regardless of event
  # payload shape) and apply one restyle + relayout covering the bar
  # panels' traces, the table trace, the threshold marker, and both
  # annotations (bar-panel stats + table caption).
  #
  # The threshold-marker `shapes` are set ONLY here (via Plotly.relayout),
  # never via R's plotly::layout(shapes = ...) — confirmed by isolated repro
  # that plotly::subplot() silently drops a `shapes` layout key set that way
  # (annotations survive the same call; shapes don't). Calling apply() once
  # immediately on render (not just on future events) is what puts the
  # initial threshold line on the page at all.
  #
  # Table traces were add_trace()-d onto `fig` AFTER the 6 bar-panel trace
  # blocks, so their global trace indices start at `total * 6`.
  combine_js <- "
    function(el, x, data) {
      var nThr = data.nThr, nLabel = data.nLabel;
      var total = data.nCell, totalTable = data.nTableCell;
      var staticAnn = data.staticAnnotations;
      var cellAnn = data.cellAnnotations;
      var tableAnn = data.tableAnnotations;
      var cellShapes = data.cellShapes;
      function apply() {
        var iBm = el.layout.updatemenus[0].active;
        var iLabel = el.layout.updatemenus[1].active;
        var iThr = el.layout.sliders[0].active;
        var g = iBm * nThr + iThr;
        var gt = iBm * nThr * nLabel + iThr * nLabel + iLabel;

        // 6 bar-panel trace blocks of `total` traces each (label-above,
        // label-below, conf-above, conf-below, aln-above, aln-below),
        // followed by `totalTable` table traces (one per bm/thr/label cell).
        var vis = new Array(total * 6 + totalTable).fill(false);
        for (var k = 0; k < 6; k++) vis[k * total + g] = true;
        vis[total * 6 + gt] = true;

        Plotly.restyle(el, {visible: vis});
        Plotly.relayout(el, {
          annotations: staticAnn.concat([cellAnn[g], tableAnn[gt]]),
          shapes: cellShapes[g]
        });
      }
      el.on('plotly_buttonclicked', apply);
      el.on('plotly_sliderchange', apply);
      apply();
    }
  "
  fig <- htmlwidgets::onRender(
    fig, combine_js,
    data = list(
      nBm = n_bm, nThr = n_thr, nLabel = n_label,
      nCell = n_cell, nTableCell = n_table_cell,
      staticAnnotations = static_annotations,
      cellAnnotations = cell_annotations,
      tableAnnotations = table_annotations,
      cellShapes = cell_shapes
    )
  )

  fig
}

# Build the explorer for one assessment's nli_overview_data rds and write it
# out as a self-contained standalone HTML file (targets `format = "file"`
# output), matching the existing convention for interactive/heavy report
# artifacts (e.g. build_overlap_key_paper_table's htmlwidgets::saveWidget()
# call) — embedded into the report via <iframe>, not printed in-place.
#
# In-place embedding (`cat(knitr::knit_print(widget))` inside a `results:
# asis` loop) was tried first and rejected: Quarto's HTML format does not
# propagate htmlwidget JS dependencies (plotly.js itself) out of a manually
# cat()-ed knit_print() call, so the widget rendered as an empty div with no
# chart. saveWidget(selfcontained = TRUE) sidesteps that entirely by bundling
# the JS inline in its own standalone page.
save_nli_bm_explorer <- function(nli_overview_data_path, output_root = "output/tables") {
  x <- readRDS(nli_overview_data_path)
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  fn <- file.path(output_root, paste0("nli_bm_explorer_", x$assessment, ".html"))

  if (isTRUE(x$empty)) {
    writeLines(
      "<html><body><p>No NLI scores available yet for this assessment.</p></body></html>",
      fn
    )
    return(fn)
  }

  fig <- build_nli_bm_explorer(x$raw, x$assessment)
  htmlwidgets::saveWidget(fig, file = fn, selfcontained = TRUE)
  fn
}
