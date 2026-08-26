# Figure for build_nli_scores_qa_data()'s prob_conf_curve: three lines
# (SUPPORTS/REFUTES/NOT_ENOUGH_INFO), x = that label's own class probability
# (binned into deciles), y = mean confidence of rows in that bin, plus a
# dashed horizontal line at the active config's own uncertain_threshold
# marking the certain/uncertain split. Reads the rds produced by
# build_nli_scores_qa_data() rather than re-collecting the raw parquet --
# same convention as build_nli_overview_figures.R/build_label_funnel_figures.R.
build_nli_scores_qa_figures <- function(nli_scores_qa_data_path, output_root = "output/figures") {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  x <- readRDS(nli_scores_qa_data_path)

  if (isTRUE(x$empty)) {
    return(character(0))
  }

  # Shared across every NLI-label figure -- see R/branch_helpers.R.
  label_levels <- nli_label_levels
  label_cols <- nli_label_colors

  fig <- x$prob_conf_curve |>
    dplyr::mutate(prob_type = factor(prob_type, levels = label_levels)) |>
    ggplot2::ggplot(ggplot2::aes(x = decile_mid, y = mean_confidence, colour = prob_type)) +
    ggplot2::geom_line(linewidth = 0.7) +
    ggplot2::geom_point(ggplot2::aes(size = n), alpha = 0.7) +
    ggplot2::geom_hline(yintercept = x$uncertain_threshold, linetype = "dashed", linewidth = 0.5) +
    ggplot2::annotate(
      "text", x = 0.02, y = x$uncertain_threshold, vjust = -0.6, hjust = 0,
      label = sprintf("uncertain_threshold = %.2f", x$uncertain_threshold), size = 3
    ) +
    ggplot2::scale_colour_manual(values = label_cols) +
    ggplot2::scale_x_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::scale_size_continuous(labels = scales::comma, guide = ggplot2::guide_legend(order = 2)) +
    ggplot2::labs(
      x = "class probability (binned, decile midpoint)",
      y = "mean confidence of rows in that bin",
      colour = NULL, size = "rows in bin"
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(legend.position = "bottom", legend.box = "vertical")

  fn <- file.path(
    output_root,
    sprintf(
      "nli_scores_qa_prob_confidence_%s%s%s.png",
      x$assessment, nli_model_suffix(x$nli_config), granularity_suffix(x$granularity)
    )
  )
  ggplot2::ggsave(fn, fig, width = 7.5, height = 4.5)

  fn_ternary <- file.path(
    output_root,
    sprintf(
      "nli_scores_qa_ternary_%s%s%s.png",
      x$assessment, nli_model_suffix(x$nli_config), granularity_suffix(x$granularity)
    )
  )
  ggplot2::ggsave(
    fn_ternary,
    nli_scores_qa_ternary_plot(x$probs, x$label_pct, x$keypaper_points, x$keypaper_label_pct),
    width = 8.2, height = 6.8, bg = "white"
  )

  c(fn, fn_ternary)
}

# Ternary (simplex) density plot of (p_supports, p_refutes, p_nei) -- each
# row's three class probabilities sum to 1, so they live on a 2D triangular
# surface, not filling a 3D volume; a literal 3D scatter would mostly just
# show that flat triangle from some angle with the usual 3D problems
# (occlusion, no interactivity in a static PNG) on top. This is the
# standard visualization for exactly this kind of 3-part compositional
# data (a de Finetti / simplex plot).
#
# Design, worked out interactively against real GA1 x complete_bm data:
# - Density via MASS::kde2d() on the Cartesian projection, log1p-transformed
#   before contouring -- a plain linear density scale left almost the whole
#   triangle (e.g. the entire REFUTES-heavy region) in a single flat lowest
#   bin, hiding real structure there under the handful of much taller peaks
#   elsewhere; log1p compresses the tall peaks and expands the low end so
#   that structure is visible everywhere, not just at the hot spots.
# - The three decision-boundary lines (where the argmax label flips) are
#   drawn from the CENTROID to each edge's midpoint only, not from the
#   vertices -- verified geometrically (see the session this was built in:
#   sampled points exactly along a vertex-to-centroid segment and confirmed
#   the whole segment stays inside a single already-winning region, i.e.
#   it's not actually a boundary between two regions at all). Drawing the
#   vertex-to-centroid halves too would be geometrically valid lines but
#   visually misleading -- they'd look like they're delineating something
#   when they're entirely inside one region.
# - Each corner label carries the real % of rows actually won by that
#   label (from `label_pct`, computed in build_nli_scores_qa_data() from
#   the same `label` column score_one_claim() assigned -- not re-derived
#   here from the probabilities, so it can't drift from the real label).
# - `keypaper_points` (optional, NULL until the separate key-paper scoring
#   chain -- R/build_nli_ready_evidence_keypaper_parquet.R -- has actually
#   been run) overlays the seed/reference papers a BM was written FROM,
#   scored against their own BM's claim: a QA sanity check, since these
#   should overwhelmingly land in the SUPPORTS region. Small white-filled,
#   black-bordered points (kept deliberately small -- a larger version
#   visibly obscured the density surface underneath), chosen for contrast
#   against the full viridis range behind them (purple through yellow).
# - `keypaper_label_pct` (optional, same availability as `keypaper_points`)
#   adds the key papers' own % for that label in square brackets next to
#   the full-corpus one already in each corner label (e.g. "REFUTES
#   (12.3%) [8.0%]"), so the two can be compared at a glance.
nli_scores_qa_ternary_plot <- function(probs, label_pct, keypaper_points = NULL, keypaper_label_pct = NULL) {
  s3 <- sqrt(3)
  # Barycentric -> Cartesian. Vertices: NOT_ENOUGH_INFO=(0,0) bottom-left,
  # REFUTES=(1,0) bottom-right, SUPPORTS=(0.5, sqrt(3)/2) top.
  x <- probs$p_refutes + probs$p_supports * 0.5
  y <- probs$p_supports * s3 / 2

  kd <- MASS::kde2d(x, y, n = 220, lims = c(0, 1, 0, s3 / 2))
  grid <- expand.grid(x = kd$x, y = kd$y)
  grid$z <- as.vector(kd$z)
  # mask grid cells outside the triangle (inverse barycentric transform)
  c_ <- grid$y / (s3 / 2)
  b_ <- grid$x - c_ * 0.5
  a_ <- 1 - b_ - c_
  grid$z[!(a_ >= -1e-6 & b_ >= -1e-6 & c_ >= -1e-6)] <- NA
  grid$zlog <- log1p(grid$z)

  tri <- data.frame(x = c(0, 1, 0.5, 0), y = c(0, 0, s3 / 2, 0))

  centroid <- c(0.5, s3 / 6)
  mid_bc <- c(0.5, 0)        # opposite SUPPORTS
  mid_ac <- c(0.25, s3 / 4)  # opposite REFUTES
  mid_ab <- c(0.75, s3 / 4)  # opposite NOT_ENOUGH_INFO
  boundaries <- rbind(
    data.frame(grp = "REFUTES vs NEI",      x = c(centroid[1], mid_bc[1]), y = c(centroid[2], mid_bc[2])),
    data.frame(grp = "SUPPORTS vs NEI",     x = c(centroid[1], mid_ac[1]), y = c(centroid[2], mid_ac[2])),
    data.frame(grp = "SUPPORTS vs REFUTES", x = c(centroid[1], mid_ab[1]), y = c(centroid[2], mid_ab[2]))
  )
  boundary_cols <- c(
    "REFUTES vs NEI" = nli_label_colors[["NOT_ENOUGH_INFO"]],
    "SUPPORTS vs NEI" = nli_label_colors[["SUPPORTS"]],
    "SUPPORTS vs REFUTES" = nli_label_colors[["REFUTES"]]
  )

  levels_pct <- seq(0.2, 0.8, 0.2)
  gridline_df <- function(levels) {
    do.call(rbind, lapply(seq_along(levels), function(i) {
      v <- levels[i]
      rbind(
        data.frame(grp = paste0("a", i), x = c(0.5 * v, 1 - 0.5 * v), y = c(v * s3 / 2, v * s3 / 2)),
        data.frame(grp = paste0("b", i), x = c(v, 0.5 + 0.5 * v),     y = c(0, (1 - v) * s3 / 2)),
        data.frame(grp = paste0("c", i), x = c(1 - v, 0.5 * (1 - v)), y = c(0, (1 - v) * s3 / 2))
      )
    }))
  }
  glines <- gridline_df(levels_pct)
  lab_a <- data.frame(x = 0.5 * levels_pct - 0.035, y = levels_pct * s3 / 2, label = levels_pct * 100)
  lab_b <- data.frame(x = levels_pct, y = -0.045, label = levels_pct * 100)
  lab_c <- data.frame(x = 1 - 0.5 * (1 - levels_pct) + 0.06, y = (1 - levels_pct) * s3 / 2, label = rev(levels_pct * 100))

  fmt_pct <- function(lab) {
    main <- sprintf("%.1f%%", label_pct[[lab]] %||% 0)
    if (is.null(keypaper_label_pct)) {
      return(main)
    }
    sprintf("%s [%.1f%%]", main, keypaper_label_pct[[lab]] %||% 0)
  }

  has_keypapers <- !is.null(keypaper_points) && nrow(keypaper_points) > 0L

  p <- ggplot2::ggplot() +
    ggplot2::geom_contour_filled(data = grid, ggplot2::aes(x = x, y = y, z = zlog), na.rm = TRUE, alpha = 0.95, bins = 14) +
    ggplot2::geom_contour(data = grid, ggplot2::aes(x = x, y = y, z = zlog), colour = "black", linewidth = 0.12, na.rm = TRUE, bins = 14) +
    ggplot2::geom_line(data = glines, ggplot2::aes(x = x, y = y, group = grp), colour = "grey55", linewidth = 0.3, linetype = "dotted") +
    ggplot2::geom_line(data = boundaries, ggplot2::aes(x = x, y = y, colour = grp), linewidth = 1) +
    ggplot2::geom_path(data = tri, ggplot2::aes(x = x, y = y), linewidth = 0.7, colour = "black") +
    ggplot2::geom_text(data = lab_a, ggplot2::aes(x = x, y = y, label = label), size = 2.8, colour = "grey30") +
    ggplot2::geom_text(data = lab_b, ggplot2::aes(x = x, y = y, label = label), size = 2.8, colour = "grey30") +
    ggplot2::geom_text(data = lab_c, ggplot2::aes(x = x, y = y, label = label), size = 2.8, colour = "grey30") +
    ggplot2::annotate("text", x = 0.5, y = s3 / 2 + 0.05, label = paste0("SUPPORTS (", fmt_pct("SUPPORTS"), ")"),
                       fontface = "bold", colour = nli_label_colors[["SUPPORTS"]], size = 4.2) +
    ggplot2::annotate("text", x = -0.09, y = -0.09, label = paste0("NOT_ENOUGH_INFO (", fmt_pct("NOT_ENOUGH_INFO"), ")"),
                       fontface = "bold", colour = nli_label_colors[["NOT_ENOUGH_INFO"]], hjust = 0, size = 4.2) +
    ggplot2::annotate("text", x = 1.09, y = -0.09, label = paste0("REFUTES (", fmt_pct("REFUTES"), ")"),
                       fontface = "bold", colour = nli_label_colors[["REFUTES"]], hjust = 1, size = 4.2) +
    ggplot2::scale_fill_viridis_d(name = "density", labels = function(v) {
      n <- length(v); out <- rep("", n); out[1] <- "low"; out[n] <- "high"; out
    }) +
    ggplot2::scale_colour_manual(name = "decision\nboundary", values = boundary_cols) +
    ggplot2::coord_fixed(clip = "off") +
    ggplot2::theme_void(base_size = 11) +
    ggplot2::theme(legend.position = "right", plot.margin = ggplot2::margin(25, 25, 25, 25))

  if (has_keypapers) {
    p <- p +
      ggplot2::geom_point(
        data = keypaper_points, ggplot2::aes(x = x, y = y),
        shape = 21, colour = "black", fill = "white", stroke = 0.35, size = 0.6
      )
  }

  p
}
