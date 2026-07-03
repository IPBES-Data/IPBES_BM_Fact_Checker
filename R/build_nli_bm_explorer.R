# Interactive per-BM NLI explorer widget for one assessment.
#
# Builds a single plotly figure with a "select BM" dropdown (defaulting to
# "All BMs") that swaps between three precomputed panels for the chosen BM:
#   1. label distribution (SUPPORTS / NOT_ENOUGH_INFO / REFUTES, % of works)
#   2. confidence distribution, with mean/median reported in the panel title
#   3. alignment (p_supports - p_refutes) distribution
#
# Traces for every BM are precomputed once in R (not recomputed client-side),
# and the dropdown just toggles which group of traces/annotations is visible
# — this is the standard, reliable plotly.js updatemenu pattern and works
# offline in a static Quarto HTML render (no Shiny/server needed).
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

  bm_choices <- sort(unique(raw$bm))
  options <- c("All BMs", bm_choices)
  n_opt <- length(options)

  stat_for <- function(bm) {
    d <- if (identical(bm, "All BMs")) raw else raw[raw$bm == bm, , drop = FALSE]
    lab_pct <- vapply(
      label_levels,
      function(l) if (nrow(d)) 100 * mean(d$label == l, na.rm = TRUE) else 0,
      numeric(1L)
    )
    conf_h <- graphics::hist(d$confidence, breaks = conf_breaks, plot = FALSE)
    aln_h  <- graphics::hist(d$alignment, breaks = aln_breaks, plot = FALSE)
    list(
      bm = bm,
      n = nrow(d),
      lab_pct = lab_pct,
      conf_mean = if (nrow(d)) mean(d$confidence, na.rm = TRUE) else NA_real_,
      conf_median = if (nrow(d)) stats::median(d$confidence, na.rm = TRUE) else NA_real_,
      conf_mids = conf_h$mids,
      conf_counts = conf_h$counts,
      aln_mean = if (nrow(d)) mean(d$alignment, na.rm = TRUE) else NA_real_,
      aln_mids = aln_h$mids,
      aln_counts = aln_h$counts
    )
  }
  stats_list <- lapply(options, stat_for)

  # ── Panel 1: label distribution (%) ─────────────────────────────────────
  p_label <- plotly::plot_ly()
  for (i in seq_len(n_opt)) {
    s <- stats_list[[i]]
    p_label <- plotly::add_trace(
      p_label,
      x = label_levels, y = unname(s$lab_pct), type = "bar",
      marker = list(color = unname(label_colors[label_levels])),
      visible = (i == 1), showlegend = FALSE
    )
  }
  p_label <- plotly::layout(
    p_label,
    xaxis = list(title = ""), yaxis = list(title = "% of works", range = c(0, 100))
  )

  # ── Panel 2: confidence distribution ────────────────────────────────────
  p_conf <- plotly::plot_ly()
  for (i in seq_len(n_opt)) {
    s <- stats_list[[i]]
    p_conf <- plotly::add_trace(
      p_conf,
      x = s$conf_mids, y = s$conf_counts, type = "bar",
      marker = list(color = "#3a6ea5"), visible = (i == 1), showlegend = FALSE
    )
  }
  p_conf <- plotly::layout(
    p_conf, xaxis = list(title = "Confidence"), yaxis = list(title = "Works")
  )

  # ── Panel 3: alignment distribution ─────────────────────────────────────
  p_aln <- plotly::plot_ly()
  for (i in seq_len(n_opt)) {
    s <- stats_list[[i]]
    p_aln <- plotly::add_trace(
      p_aln,
      x = s$aln_mids, y = s$aln_counts, type = "bar",
      marker = list(color = "#e08e45"), visible = (i == 1), showlegend = FALSE
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

  # Static per-panel titles + one dynamic annotation per panel (updated by
  # the dropdown) — plotly::subplot() drops each sub-plot's own layout(title=),
  # so panel titles have to be explicit paper-relative annotations.
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
    list(
      text = sprintf(
        "n = %s · mean conf %.2f · median conf %.2f · mean align %.2f",
        format(s$n, big.mark = ","), s$conf_mean, s$conf_median, s$aln_mean
      ),
      showarrow = FALSE, xref = "paper", yref = "paper",
      x = 0.5, y = 1.22, xanchor = "center", font = list(size = 12, color = "#555")
    )
  }

  buttons <- lapply(seq_len(n_opt), function(i) {
    vis <- rep(FALSE, 3L * n_opt)
    vis[i] <- TRUE                # label panel trace
    vis[n_opt + i] <- TRUE        # confidence panel trace
    vis[2L * n_opt + i] <- TRUE   # alignment panel trace
    s <- stats_list[[i]]
    list(
      method = "update",
      args = list(
        list(visible = vis),
        list(annotations = c(static_annotations, list(dynamic_annotation(s))))
      ),
      label = sprintf("%s (n=%s)", s$bm, format(s$n, big.mark = ","))
    )
  })

  fig <- plotly::layout(
    fig,
    annotations = c(static_annotations, list(dynamic_annotation(stats_list[[1L]]))),
    updatemenus = list(list(
      type = "dropdown", active = 0L, x = 0, y = 1.32, xanchor = "left",
      buttons = buttons
    )),
    margin = list(t = 110)
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
