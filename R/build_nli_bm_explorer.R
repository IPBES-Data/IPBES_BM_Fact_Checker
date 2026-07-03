# Interactive per-BM NLI explorer widget for one assessment.
#
# Builds a single plotly figure with two linked controls:
#   - a "select BM" dropdown (defaulting to "All BMs")
#   - a "minimum confidence" slider (default 0.5)
# that jointly pick one precomputed (bm, threshold) cell. ALL works are
# always shown (no filtering) — the threshold instead splits every bar into
# two STACKED segments: "confidence >= threshold" (solid fill, on the
# bottom) and "confidence < threshold" (hollow/outline-only, on top), so
# moving the slider re-partitions the same totals rather than hiding data:
#   1. label distribution (SUPPORTS / NOT_ENOUGH_INFO / REFUTES, % of works),
#      each label split into its above/below-threshold share
#   2. confidence distribution: a histogram over confidence itself, so the
#      split is just "bin mid >= threshold" vs "< threshold" — plus a dashed
#      line marking the threshold
#   3. alignment (p_supports - p_refutes) distribution, each alignment bin
#      split by how many of its works meet the confidence threshold
#
# Every (bm, threshold) cell's six traces (2 per panel) are precomputed once
# in R (not recomputed client-side) — this is the standard, reliable
# plotly.js updatemenu/slider pattern and works offline in a static Quarto
# HTML render (no Shiny/server needed). The two controls are combined with a
# small JS handler (see combine_js below): plotly's declarative button/step
# `args` can only set a fixed payload and can't reference the OTHER
# control's current position, so both are set to method="skip" (native
# dropdown/slider UI and active-index tracking still work, but no automatic
# restyle) and a tiny onRender() callback reads BOTH current indices from
# the rendered widget's own layout and applies the one combined
# visibility+annotation update. This avoids the two controls fighting
# over/resetting each other.
#
# `raw` is the per-row (km, bm, label, confidence, alignment) data.frame
# already produced by build_nli_overview_data() (its $raw element) — no new
# target/data source required.
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

  # ── Panel 1: label distribution (%), stacked above/below threshold ──────
  p_label <- plotly::plot_ly()
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
      visible = (i == default_cell), showlegend = FALSE
    )
  }
  p_label <- plotly::layout(
    p_label,
    xaxis = list(title = ""), yaxis = list(title = "% of works", range = c(0, 100))
  )

  # ── Panel 2: confidence distribution, stacked above/below threshold ─────
  p_conf <- plotly::plot_ly()
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
  p_aln <- plotly::plot_ly()
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

  # Static per-panel titles — plotly::subplot() drops each sub-plot's own
  # layout(title=), so panel titles have to be explicit paper-relative
  # annotations.
  panel_title <- function(text, xref) {
    list(
      text = text, showarrow = FALSE, xref = "paper", yref = "paper",
      x = switch(xref, x = 0.10, x2 = 0.50, x3 = 0.90),
      y = 1.12, xanchor = "center", font = list(size = 13)
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
      x = 0.5, y = 1.22, xanchor = "center", font = list(size = 12, color = "#555")
    )
  }
  # One per cell, JS-indexed 0-based in the same bm-outer/thr-inner order as
  # stats_flat (an R list serializes to a JSON array in that same order).
  cell_annotations <- lapply(stats_flat, dynamic_annotation)

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

  fig <- plotly::layout(
    fig,
    annotations = c(static_annotations, list(cell_annotations[[default_cell]])),
    updatemenus = list(list(
      type = "dropdown", active = default_bm_idx - 1L, x = 0, y = 1.32, xanchor = "left",
      buttons = bm_buttons
    )),
    sliders = list(list(
      active = default_thr_idx - 1L, x = 0.30, y = 1.30, len = 0.68, xanchor = "left",
      currentvalue = list(prefix = "Min. confidence: ", font = list(size = 12)),
      pad = list(t = 10),
      steps = thr_steps
    )),
    margin = list(t = 110)
  )

  # Combine the two controls: read both current indices from the widget's
  # own layout (the authoritative source, regardless of event payload
  # shape) and apply one restyle + relayout covering both panels' traces,
  # the threshold marker, and the dynamic annotation.
  #
  # The threshold-marker `shapes` are set ONLY here (via Plotly.relayout),
  # never via R's plotly::layout(shapes = ...) — confirmed by isolated repro
  # that plotly::subplot() silently drops a `shapes` layout key set that way
  # (annotations survive the same call; shapes don't). Calling apply() once
  # immediately on render (not just on future events) is what puts the
  # initial threshold line on the page at all.
  combine_js <- "
    function(el, x, data) {
      var nThr = data.nThr, total = data.nCell;
      var staticAnn = data.staticAnnotations;
      var cellAnn = data.cellAnnotations;
      var cellShapes = data.cellShapes;
      function apply() {
        var iBm = el.layout.updatemenus[0].active;
        var iThr = el.layout.sliders[0].active;
        var g = iBm * nThr + iThr;
        // 6 trace blocks of `total` traces each, in the order the R code
        // built them: label-above, label-below, conf-above, conf-below,
        // aln-above, aln-below.
        var vis = new Array(total * 6).fill(false);
        for (var k = 0; k < 6; k++) vis[k * total + g] = true;
        Plotly.restyle(el, {visible: vis});
        Plotly.relayout(el, {
          annotations: staticAnn.concat([cellAnn[g]]),
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
      nBm = n_bm, nThr = n_thr, nCell = n_cell,
      staticAnnotations = static_annotations,
      cellAnnotations = cell_annotations,
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
