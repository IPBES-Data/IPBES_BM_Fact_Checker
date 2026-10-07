build_pipeline_mmd <- function(targets_script, path = "input/mmd/pipeline_collection.mmd") {
  # `targets_script` is this project's own _targets_*.R, declared by the caller
  # as a format = "file" target. It is never read here -- it is the dependency
  # that decides WHEN to redraw, and the graph can only change when that script
  # does, because tar_mermaid(targets_only = TRUE) draws target-to-target edges
  # taken from each target's command expression. Editing a function body in R/
  # cannot move an edge.
  #
  # It used to be `r_files`, the whole R/ listing, which was wrong in both
  # directions and measurably so. Too sensitive: any edit to any of ~60 files
  # redrew a byte-identical picture. Not sensitive enough, and this is the one
  # that bit: targets does NOT track the pipeline script as a dependency of the
  # targets it defines, so adding, removing or renaming a target left this
  # diagram untouched. Both symptoms were on disk on 2026-10-07 --
  # pipeline_factcheck.mmd still named nli_ready_evidence_parquet and
  # nli_scores_by_claim_evidence after the rename to claim_*, and
  # pipeline_reporting.mmd held a byte-identical copy of COLLECTION's graph
  # with not one reporting target in it.
  force(targets_script)
  # Omit the diagram machinery itself, so a pipeline picture never depicts the
  # targets that draw it. Derived by PATTERN from the live manifest rather than
  # listed by name: each project names these differently
  # (diagram_pipeline_collection / _reporting / _training, mmd_workflow_collection /
  # _reporting, mmd_overview), and a hardcoded list silently stops excluding
  # anything the
  # moment one is renamed -- which is exactly what happened when the pipeline
  # was split and this list still said "..._nli", leaving
  # diagram_pipeline_reporting, diagram_workflow_reporting and
  # mmd_workflow_reporting drawn into pipeline_reporting.mmd.
  self <- grep(
    "^(targets_script|pipeline_mmd|mmd_.*|diagram_.*)$",
    targets::tar_manifest(fields = "name")$name,
    value = TRUE
  )
  mmd <- targets::tar_mermaid(
    targets_only = TRUE,
    outdated = FALSE,
    legend = FALSE,
    exclude = self
  )

  # Top-down layout at both levels
  mmd <- sub("^graph LR", "graph TD", mmd)
  mmd <- sub("direction LR", "direction TD", mmd)

  # Strip status class annotations (:::queued, :::dispatched, etc.)
  mmd <- gsub(
    ":::(?:queued|dispatched|completed|uptodate|outdated|none|started|errored|cancelled|skipped)",
    "",
    mmd,
    perl = TRUE
  )

  # Remove style and classDef lines — let Mermaid use its defaults
  mmd <- mmd[!grepl("^\\s*(style|classDef)\\s", mmd)]

  writeLines(mmd, path)
  path
}

render_mmd <- function(mmd_path, output_dir = out_reporting("figures")) {
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  stem <- sub("\\.mmd$", "", basename(mmd_path))
  out_svg <- file.path(output_dir, paste0(stem, ".svg"))
  out_png <- file.path(output_dir, paste0(stem, ".png"))

  for (out in c(out_svg, out_png)) {
    result <- processx::run(
      "npx",
      args = c("-y", "@mermaid-js/mermaid-cli", "-i", mmd_path, "-o", out),
      timeout = 120,
      error_on_status = TRUE
    )
  }

  c(out_svg, out_png)
}
