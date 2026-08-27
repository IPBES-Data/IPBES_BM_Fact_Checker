# Ternary (p_supports, p_refutes, p_nei) density figure for
# build_nli_scores_qa_data()'s output, as a static PNG. Reads the rds
# produced by build_nli_scores_qa_data() rather than re-collecting the raw
# parquet -- same convention as
# build_nli_overview_figures.R/build_label_funnel_figures.R.
build_nli_scores_qa_figures <- function(nli_scores_qa_data_path, output_root = "output/figures") {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  x <- readRDS(nli_scores_qa_data_path)

  if (isTRUE(x$empty)) {
    return(character(0))
  }

  fn_ternary <- file.path(
    output_root,
    sprintf(
      "nli_scores_qa_ternary_%s%s%s.png",
      x$assessment, nli_model_suffix(x$nli_config), granularity_suffix(x$granularity)
    )
  )
  ggplot2::ggsave(
    fn_ternary,
    nli_scores_qa_ternary_plot(
      x$probs, x$label_pct, x$keypaper_points, x$keypaper_label_pct,
      x$keypaper_label_pvalue, x$uncertain_threshold %||% 0.60
    ),
    width = 8.2, height = 6.8, bg = "white"
  )

  fn_ternary
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
# - `keypaper_label_pvalue` (optional, same availability) adds the p-value
#   from a two-proportion test (key-paper share vs. full-corpus share for
#   that label, stats::prop.test() in build_nli_scores_qa_data.R) right
#   after the key-paper %, so a reader can tell whether a visually
#   different bracketed share is actually statistically distinguishable
#   from the full-corpus one or could plausibly be the same underlying rate
#   sampled at n=~500-1000 key papers. Formatted "p<0.001" below that
#   threshold, else "p=0.023" to 3 decimals -- not reduced to significance
#   stars, so the reader sees the actual number rather than a threshold
#   judgement call baked into the figure.
# - `uncertain_threshold` draws the certain/uncertain boundary implied by
#   score_one_claim.R's own `uncertain = confidence < uncertain_threshold`
#   (confidence = max(p_supports, p_refutes, p_nei), i.e. whichever
#   probability won). Geometrically that's THREE lines, each parallel to
#   the edge opposite one vertex, at that vertex's threshold value -- the
#   exact same construction as the plain 20/40/60/80% gridlines below
#   (gridline_df() is reused directly for a single-level vector), just
#   drawn in a distinct dashed style with its own linetype legend entry so
#   it doesn't read as just another generic gridline. The three small
#   corner regions beyond this boundary are "certain" (that label's own
#   probability cleared the bar); the hexagonal middle region is
#   "uncertain" regardless of which label technically won there.
nli_scores_qa_ternary_plot <- function(probs, label_pct, keypaper_points = NULL, keypaper_label_pct = NULL, keypaper_label_pvalue = NULL, uncertain_threshold = 0.60) {
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

  # certain/uncertain boundary -- same construction as glines above, just
  # for the single uncertain_threshold level, with its own `kind` column
  # (constant across all three segments) so linetype maps them to ONE
  # legend entry while `grp` (a1/b1/c1, from gridline_df()) still keeps
  # the three segments from being connected into one wrong zigzag path.
  uncertain_lines <- gridline_df(uncertain_threshold)
  uncertain_lines$kind <- sprintf("certain / uncertain boundary\n(confidence = %.2f)", uncertain_threshold)
  lab_a <- data.frame(x = 0.5 * levels_pct - 0.035, y = levels_pct * s3 / 2, label = levels_pct * 100)
  lab_b <- data.frame(x = levels_pct, y = -0.045, label = levels_pct * 100)
  lab_c <- data.frame(x = 1 - 0.5 * (1 - levels_pct) + 0.06, y = (1 - levels_pct) * s3 / 2, label = rev(levels_pct * 100))

  fmt_pvalue <- function(p) {
    if (is.na(p)) {
      return("")
    }
    if (p < 0.001) {
      return(", p<0.001")
    }
    sprintf(", p=%.3f", p)
  }

  # Full corner label, `lab (XX.X%)` on its own line and, when key-paper
  # data is present, `[YY.Y%, p<0.001]` wrapped onto a SECOND line below it
  # -- the p-value addition made the single-line version wide enough that
  # the two bottom corners' labels visibly overlapped each other (confirmed
  # directly: rendered and looked at the PNG before this fix). `lab` is
  # both the lookup key into label_pct/keypaper_label_pct/
  # keypaper_label_pvalue AND the display name shown (nli_label_levels'
  # values already read as human labels, e.g. "SUPPORTS").
  fmt_corner_label <- function(lab) {
    main <- sprintf("%s (%.1f%%)", lab, label_pct[[lab]] %||% 0)
    if (is.null(keypaper_label_pct)) {
      return(main)
    }
    pval <- if (!is.null(keypaper_label_pvalue)) fmt_pvalue(keypaper_label_pvalue[[lab]] %||% NA_real_) else ""
    sprintf("%s\n[%.1f%%%s]", main, keypaper_label_pct[[lab]] %||% 0, pval)
  }

  has_keypapers <- !is.null(keypaper_points) && nrow(keypaper_points) > 0L

  p <- ggplot2::ggplot() +
    ggplot2::geom_contour_filled(data = grid, ggplot2::aes(x = x, y = y, z = zlog), na.rm = TRUE, alpha = 0.95, bins = 14) +
    ggplot2::geom_contour(data = grid, ggplot2::aes(x = x, y = y, z = zlog), colour = "black", linewidth = 0.12, na.rm = TRUE, bins = 14) +
    ggplot2::geom_line(data = glines, ggplot2::aes(x = x, y = y, group = grp), colour = "grey55", linewidth = 0.3, linetype = "dotted") +
    ggplot2::geom_line(data = uncertain_lines, ggplot2::aes(x = x, y = y, group = grp, linetype = kind), colour = "black", linewidth = 0.6) +
    ggplot2::geom_line(data = boundaries, ggplot2::aes(x = x, y = y, colour = grp), linewidth = 1) +
    ggplot2::geom_path(data = tri, ggplot2::aes(x = x, y = y), linewidth = 0.7, colour = "black") +
    ggplot2::geom_text(data = lab_a, ggplot2::aes(x = x, y = y, label = label), size = 2.8, colour = "grey30") +
    ggplot2::geom_text(data = lab_b, ggplot2::aes(x = x, y = y, label = label), size = 2.8, colour = "grey30") +
    ggplot2::geom_text(data = lab_c, ggplot2::aes(x = x, y = y, label = label), size = 2.8, colour = "grey30") +
    ggplot2::annotate("text", x = 0.5, y = s3 / 2 + 0.05, label = fmt_corner_label("SUPPORTS"),
                       fontface = "bold", colour = nli_label_colors[["SUPPORTS"]], size = 4.2, lineheight = 0.9) +
    ggplot2::annotate("text", x = -0.09, y = -0.09, label = fmt_corner_label("NOT_ENOUGH_INFO"),
                       fontface = "bold", colour = nli_label_colors[["NOT_ENOUGH_INFO"]], hjust = 0, vjust = 1, size = 4.2, lineheight = 0.9) +
    ggplot2::annotate("text", x = 1.09, y = -0.09, label = fmt_corner_label("REFUTES"),
                       fontface = "bold", colour = nli_label_colors[["REFUTES"]], hjust = 1, vjust = 1, size = 4.2, lineheight = 0.9) +
    ggplot2::scale_fill_viridis_d(name = "density", labels = function(v) {
      n <- length(v); out <- rep("", n); out[1] <- "low"; out[n] <- "high"; out
    }) +
    ggplot2::scale_colour_manual(name = "decision\nboundary", values = boundary_cols) +
    ggplot2::scale_linetype_manual(name = NULL, values = stats::setNames("dashed", unique(uncertain_lines$kind))) +
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
