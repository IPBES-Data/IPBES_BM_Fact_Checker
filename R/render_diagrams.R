build_pipeline_mmd <- function(r_files, path = "input/mmd/pipeline_nli.mmd") {
  force(r_files)
  mmd <- targets::tar_mermaid(
    targets_only = TRUE,
    outdated = FALSE,
    legend = FALSE,
    exclude = c(
      "mmd_workflow_lm",
      "mmd_workflow_nli",
      "diagram_workflow_lm",
      "diagram_workflow_nli",
      "r_files",
      "pipeline_mmd",
      "diagram_pipeline_nli",
      "pipeline_lm",
      "diagram_pipeline_lm"
    )
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
