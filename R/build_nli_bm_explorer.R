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
# threshold + selected label — a clickable DOI (or OpenAlex link, if no DOI)
# / confidence / alignment, sorted by confidence descending, capped to
# `table_row_cap` rows (flagged in its caption rather than silently
# truncated) — plus a "Download table (CSV)" button. The download is NOT
# limited to the rows on screen: it exports its own higher-capped row set
# (`download_row_cap`, independently precomputed from the same sorted data),
# with Assessment and BM added as explicit columns (BM per-row, since under
# "All BMs" each row belongs to a different actual BM) — and, like the
# table, flags in a trailing comment line if even that higher cap truncated
# the true match count.
#
# The table is a plain HTML <div>/<table> swapped into the DOM below the
# chart, NOT a plotly `type = "table"` trace: plotly table cells render any
# HTML they're given as escaped plain text (confirmed by isolated repro —
# an `<a href=...>` shows up as literal angle-bracket text, not a clickable
# link), so DOI links would not have been clickable there.
#
# Every (bm, threshold) cell's six bar/histogram traces (2 per panel), and
# every (bm, threshold, label) cell's one table HTML string, are precomputed
# once in R (not recomputed client-side) — this is the standard, reliable
# plotly.js updatemenu/slider pattern and works offline in a static Quarto
# HTML render (no Shiny/server needed). The three controls are combined with
# a small JS handler (see combine_js below): plotly's declarative
# button/step `args` can only set a fixed payload and can't reference the
# OTHER controls' current position, so all three are set to method="skip"
# (native dropdown/slider UI and active-index tracking still work, but no
# automatic restyle) and a tiny onRender() callback reads all three current
# indices from the rendered widget's own layout and applies the one
# combined visibility+annotation+table update. This avoids the controls
# fighting over/resetting each other.
#
# `raw` is the per-row (km, bm, work_id, doi, label, confidence, alignment)
# data frame already produced by build_nli_overview_data() (its $raw
# element) — no new target/data source required.
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
  # The CSV download intentionally allows far more rows than the on-screen
  # table (which stays capped at table_row_cap for readability) — but not
  # truly unlimited: the full raw dataset is ~1-2M rows, and some (bm,
  # threshold, label) combinations (e.g. "All BMs" at a low threshold) match
  # hundreds of thousands of them. Embedding all of those in the
  # self-contained widget would balloon file size by 5-10x. 5000 is a
  # practical ceiling — comfortably more than a human will inspect — with
  # the true match count always reported so truncation is never silent.
  download_row_cap <- 5000L

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
  # combination gets its own precomputed HTML snippet (like the bar panels
  # above), so uncapped rows would multiply the file size by however many
  # rows the single largest cell has. n_match (pre-cap) is always shown in
  # the caption so the cap is never silent.
  #
  # Rendered as a plain HTML <table> (built here as one big string per
  # cell, swapped into a DOM element below the chart — see combine_js)
  # rather than a plotly `type = "table"` trace: plotly table cells render
  # any HTML they're given as ESCAPED PLAIN TEXT (confirmed by isolated
  # repro — an <a href=...> shows up as literal angle-bracket text, not a
  # clickable link), so DOI/OpenAlex links would not be clickable there. A
  # real DOM table also sidesteps two plotly/htmlwidgets quirks found while
  # building the first version of this feature: add_trace() called
  # repeatedly on an already-subplot()-merged figure leaves each new
  # trace's internal "attrs" bookkeeping unnamed, which crashes
  # htmlwidgets::saveWidget()'s shouldEval() validation once mixed with the
  # properly-named bar-trace attrs at realistic scale; and a plotly table
  # trace needs its own `domain`, which meant compressing the bar panels
  # and fighting their axis-label spacing. A plain DOM table needs none of
  # that — it just flows in the page below the chart.
  work_link <- function(work_id, doi) {
    id_short <- sub("^https://openalex\\.org/", "", work_id)
    if (!is.na(doi) && nzchar(doi)) {
      doi_short <- sub("^https://doi\\.org/", "", doi)
      sprintf('<a href="%s" target="_blank" rel="noopener">%s</a>', doi, doi_short)
    } else {
      sprintf('<a href="%s" target="_blank" rel="noopener">%s (OpenAlex)</a>', work_id, id_short)
    }
  }
  # Plain-text counterpart of work_link() for the CSV download (no HTML
  # markup — an identifier, not a link).
  work_text <- function(work_id, doi) {
    id_short <- sub("^https://openalex\\.org/", "", work_id)
    if (!is.na(doi) && nzchar(doi)) sub("^https://doi\\.org/", "", doi) else id_short
  }
  table_stat_for <- function(bm, thr, label) {
    d <- if (identical(bm, "All BMs")) raw else raw[raw$bm == bm, , drop = FALSE]
    d <- d[!is.na(d$confidence) & d$confidence >= thr & d$label == label, , drop = FALSE]
    n_match <- nrow(d)
    d <- d[order(-d$confidence), , drop = FALSE]

    d_display <- utils::head(d, table_row_cap)
    capped_note <- if (n_match > nrow(d_display)) {
      sprintf(" (showing top %d of %s by confidence)", nrow(d_display), format(n_match, big.mark = ",", trim = TRUE))
    } else {
      ""
    }
    caption <- sprintf(
      "%s works labeled %s at confidence ≥ %.1f for %s%s",
      format(n_match, big.mark = ",", trim = TRUE), label, thr, bm, capped_note
    )
    # CSS classes (defined once, injected into <head> by combine_js) rather
    # than inline `style=` on every cell — at up to 50 rows x ~900 cells,
    # repeating a style string per <td> roughly doubled the saved file size
    # in an earlier version of this function; classes cut that back down.
    if (!nrow(d_display)) {
      html <- sprintf('<p class="nli-cap">%s</p><p class="nli-empty">No matching works.</p>', caption)
    } else {
      rows <- sprintf(
        '<tr><td>%s</td><td class="num">%.3f</td><td class="num">%.3f</td></tr>',
        mapply(work_link, d_display$work_id, d_display$doi), d_display$confidence, d_display$alignment
      )
      html <- sprintf(
        paste0(
          '<p class="nli-cap">%s</p>',
          '<div class="nli-tbl-wrap"><table class="nli-tbl">',
          '<thead><tr><th>Work</th><th class="num">Confidence</th><th class="num">Alignment</th></tr></thead>',
          "<tbody>%s</tbody></table></div>"
        ),
        caption, paste(rows, collapse = "")
      )
    }
    list(bm = bm, thr = thr, label = label, html = html)
  }
  # Download data lives in a SEPARATE, much coarser grid — see
  # download_data_for() below — rather than one array per (bm, threshold,
  # label) cell here: a threshold is just a `confidence >=` cutoff on an
  # already-confidence-sorted list, so storing it once per (bm, label) and
  # filtering client-side avoids re-embedding the same rows once per
  # threshold step (10x blowup — confirmed the naive per-cell version
  # produced a 166MB file for GA1 alone).
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
  table_htmls <- lapply(table_flat, `[[`, "html")

  # Exact match counts per (bm, threshold, label) — cheap (just integers),
  # reused so the download button can report/flag truncation accurately
  # without needing the full row data at every threshold. lab_above_n is
  # already in label_levels order (SUPPORTS, NOT_ENOUGH_INFO, REFUTES); this
  # re-indexes to label_sel_options order (REFUTES, SUPPORTS,
  # NOT_ENOUGH_INFO) so a JS dropdown index lines up directly.
  match_counts_flat <- lapply(stats_flat, function(s) unname(s$lab_above_n[label_sel_options]))

  # Download data — one array per (bm, label), NOT per threshold (see note
  # above table_stat_for). Capped at download_row_cap and pre-sorted by
  # confidence descending, so a given threshold's matches are always a
  # PREFIX of the stored array — JS just filters the leading run.
  download_data_for <- function(bm, label) {
    d <- if (identical(bm, "All BMs")) raw else raw[raw$bm == bm, , drop = FALSE]
    d <- d[!is.na(d$confidence) & d$label == label, , drop = FALSE]
    d <- d[order(-d$confidence), , drop = FALSE]
    d <- utils::head(d, download_row_cap)
    list(
      bm = d$bm,
      work = mapply(work_text, d$work_id, d$doi),
      confidence = round(d$confidence, 3),
      alignment = round(d$alignment, 3)
    )
  }
  # Row-major bm-outer / label-inner grid — matches iBm * n_label + iLabel
  # indexing on the JS side.
  download_grid <- lapply(seq_len(n_bm), function(i_bm) {
    lapply(seq_len(n_label), function(i_lab) {
      download_data_for(bm_options[[i_bm]], label_sel_options[[i_lab]])
    })
  })
  download_flat <- unlist(download_grid, recursive = FALSE)

  # ── Panel 1: label distribution (%), stacked above/below threshold ──────
  p_label <- plotly::plot_ly(height = 650)
  for (i in seq_len(n_cell)) {
    s <- stats_flat[[i]]
    p_label <- plotly::add_trace(
      p_label,
      x = label_levels, y = unname(s$lab_above), type = "bar",
      marker = list(color = unname(label_colors[label_levels])),
      # y is already a percentage (0-100); default plotly hover would show
      # the raw number ("REFUTES, 12.97044") with no unit — spell out what
      # it is and append "%".
      hovertemplate = "%{x}<br>≥ threshold: %{y:.2f}%<extra></extra>",
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
      # trim = TRUE: format() right-pads elements of a vector to a common
      # width by default (so a 4-digit and a 6-digit count in the same call
      # get aligned with leading spaces) — without it, the shorter numbers
      # in lab_above_n/lab_total_n grow stray leading/trailing spaces here.
      text = sprintf(
        "%s/%s",
        format(s$lab_above_n, big.mark = ",", trim = TRUE),
        format(s$lab_total_n, big.mark = ",", trim = TRUE)
      ),
      textposition = "outside", cliponaxis = FALSE,
      textfont = list(size = 10, color = "#333"),
      hovertemplate = "%{x}<br>< threshold: %{y:.2f}%<extra></extra>",
      visible = (i == default_cell), showlegend = FALSE
    )
  }
  p_label <- plotly::layout(
    p_label,
    xaxis = list(title = ""), yaxis = list(title = "% of works", range = c(0, 100))
  )

  # ── Panel 2: confidence distribution, stacked above/below threshold ─────
  p_conf <- plotly::plot_ly(height = 650)
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
  p_aln <- plotly::plot_ly(height = 650)
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
    annotations = c(static_annotations, list(cell_annotations[[default_cell]])),
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
  # panels' traces, the threshold marker, and the stats annotation — plus
  # swap the drill-down table's HTML into a plain <div> appended right after
  # the chart (not a plotly trace — see the drill-down table comment above)
  # and wire a "Download CSV" button that reads whatever table is currently
  # showing at click time (so it always matches the on-screen selection).
  #
  # The threshold-marker `shapes` are set ONLY here (via Plotly.relayout),
  # never via R's plotly::layout(shapes = ...) — confirmed by isolated repro
  # that plotly::subplot() silently drops a `shapes` layout key set that way
  # (annotations survive the same call; shapes don't). Calling apply() once
  # immediately on render (not just on future events) is what puts the
  # initial threshold line — and the initial table content — on the page.
  combine_js <- "
    function(el, x, data) {
      var nThr = data.nThr, nLabel = data.nLabel, total = data.nCell;
      var staticAnn = data.staticAnnotations;
      var cellAnn = data.cellAnnotations;
      var cellShapes = data.cellShapes;
      var tableHtmls = data.tableHtmls;
      var matchCounts = data.matchCounts;
      var downloadData = data.downloadData;
      var thrValues = data.thrValues;
      var assessmentId = data.assessmentId;

      if (!document.getElementById('nli-tbl-style')) {
        var styleEl = document.createElement('style');
        styleEl.id = 'nli-tbl-style';
        styleEl.textContent =
          '.nli-cap{color:#555;font-size:12px;margin:4px 0 8px;}' +
          '.nli-empty{color:#888;font-style:italic;font-size:13px;}' +
          '.nli-tbl-wrap{max-height:280px;overflow-y:auto;border:1px solid #ddd;}' +
          '.nli-tbl{width:100%;border-collapse:collapse;font-size:13px;}' +
          '.nli-tbl th{text-align:left;padding:4px 8px;background:#f2f2f2;position:sticky;top:0;}' +
          '.nli-tbl td{padding:4px 8px;border-bottom:1px solid #eee;}' +
          '.nli-tbl .num{text-align:right;}';
        document.head.appendChild(styleEl);
      }

      var tableDiv = document.createElement('div');
      tableDiv.style.marginTop = '8px';
      el.parentNode.insertBefore(tableDiv, el.nextSibling);

      var dlBtn = document.createElement('button');
      dlBtn.textContent = 'Download table (CSV)';
      dlBtn.style.cssText = 'margin:4px 0 8px;padding:4px 12px;cursor:pointer;font-size:12px;';
      el.parentNode.insertBefore(dlBtn, tableDiv);

      function currentTableIndex() {
        var iBm = el.layout.updatemenus[0].active;
        var iThr = el.layout.sliders[0].active;
        var iLabel = el.layout.updatemenus[1].active;
        return iBm * nThr * nLabel + iThr * nLabel + iLabel;
      }

      function apply() {
        var iBm = el.layout.updatemenus[0].active;
        var iThr = el.layout.sliders[0].active;
        var g = iBm * nThr + iThr;
        var vis = new Array(total * 6).fill(false);
        for (var k = 0; k < 6; k++) vis[k * total + g] = true;
        Plotly.restyle(el, {visible: vis});
        Plotly.relayout(el, {
          annotations: staticAnn.concat([cellAnn[g]]),
          shapes: cellShapes[g]
        });
        tableDiv.innerHTML = tableHtmls[currentTableIndex()];
      }

      // CSV built from the precomputed download data — one array per (bm,
      // label), NOT per threshold (storing it per threshold too would
      // re-embed the same rows ~10x, which is what produced a 166MB file
      // in an earlier version of this widget). Each array is pre-sorted by
      // confidence descending and capped at download_row_cap, so the
      // current threshold's matches are always a leading prefix — sliced
      // off here rather than re-filtered from scratch. This is NOT limited
      // to what's visible on screen (the table stays capped at
      // table_row_cap for readability). Includes Assessment and BM as
      // explicit columns (BM per-row, since under \"All BMs\" each row
      // belongs to a different actual BM).
      function downloadRowsFor(iBm, iThr, iLabel) {
        var arr = downloadData[iBm * nLabel + iLabel];
        var thr = thrValues[iThr];
        var cut = arr.confidence.length;
        for (var i = 0; i < arr.confidence.length; i++) {
          if (arr.confidence[i] < thr) { cut = i; break; }
        }
        return {
          bm: arr.bm.slice(0, cut),
          work: arr.work.slice(0, cut),
          confidence: arr.confidence.slice(0, cut),
          alignment: arr.alignment.slice(0, cut)
        };
      }

      dlBtn.onclick = function() {
        var iBm = el.layout.updatemenus[0].active;
        var iThr = el.layout.sliders[0].active;
        var iLabel = el.layout.updatemenus[1].active;
        var nMatch = matchCounts[iBm * nThr + iThr][iLabel];
        var d = downloadRowsFor(iBm, iThr, iLabel);
        if (!d.work.length) return;
        var esc = function(v) {
          v = String(v).replace(/\\s+/g, ' ').trim();
          return (v.indexOf(',') !== -1 || v.indexOf('\"') !== -1)
            ? '\"' + v.replace(/\"/g, '\"\"') + '\"' : v;
        };
        var lines = ['Assessment,BM,Work,Confidence,Alignment'];
        for (var i = 0; i < d.work.length; i++) {
          lines.push([esc(assessmentId), esc(d.bm[i]), esc(d.work[i]), d.confidence[i], d.alignment[i]].join(','));
        }
        if (nMatch > d.work.length) {
          lines.push('# truncated: showing ' + d.work.length + ' of ' + nMatch + ' matching works, sorted by confidence descending');
        }
        var blob = new Blob([lines.join('\\n')], {type: 'text/csv;charset=utf-8;'});
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        var bmLabel = el.layout.updatemenus[0].buttons[iBm].label.replace(/[^A-Za-z0-9]+/g, '_');
        var labelLabel = el.layout.updatemenus[1].buttons[iLabel].label.replace(/[^A-Za-z0-9]+/g, '_');
        a.href = url;
        a.download = 'nli_table_' + assessmentId + '_' + bmLabel + '_' + labelLabel + '.csv';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
      };

      el.on('plotly_buttonclicked', apply);
      el.on('plotly_sliderchange', apply);
      apply();
    }
  "
  fig <- htmlwidgets::onRender(
    fig, combine_js,
    data = list(
      nBm = n_bm, nThr = n_thr, nLabel = n_label, nCell = n_cell,
      staticAnnotations = static_annotations,
      cellAnnotations = cell_annotations,
      cellShapes = cell_shapes,
      tableHtmls = table_htmls,
      matchCounts = match_counts_flat,
      downloadData = download_flat,
      thrValues = thr_values,
      assessmentId = assessment_id
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
  fn <- file.path(
    output_root,
    paste0(
      "nli_bm_explorer_", x$assessment,
      nli_model_suffix(x$nli_active %||% "deberta_zeroshot"),
      granularity_suffix(x$granularity %||% "naive_bm"), ".html"
    )
  )

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
