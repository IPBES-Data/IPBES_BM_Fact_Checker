build_pipeline_mmd <- function(r_files, path = "input/mmd/pipeline_main.mmd") {
  force(r_files)
  # Omit the diagram machinery itself, so a pipeline picture never depicts the
  # targets that draw it. Derived by PATTERN from the live manifest rather than
  # listed by name: each project names these differently
  # (diagram_pipeline_main / _reporting / _training, mmd_workflow_main /
  # _reporting), and a hardcoded list silently stops excluding anything the
  # moment one is renamed -- which is exactly what happened when the pipeline
  # was split and this list still said "..._nli", leaving
  # diagram_pipeline_reporting, diagram_workflow_reporting and
  # mmd_workflow_reporting drawn into pipeline_reporting.mmd.
  self <- grep(
    "^(r_files|pipeline_mmd|mmd_workflow_.*|diagram_.*)$",
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

render_mmd <- function(mmd_path, output_dir = "output/figures") {
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
