# Collect the rendered report and TD design docs — each with its sibling
# <name>_files/ sidecar directory, if one exists — into a single,
# self-contained output/reports/ directory. This is the exact tree
# scripts/deploy_gh_pages.sh publishes to the gh-pages branch root, so the
# deploy script itself never needs to know which htmls exist or have a
# _files/ sidecar.
build_report_output_dir <- function(report_html, td_html, output_dir = "output/reports") {
  if (dir.exists(output_dir)) {
    unlink(output_dir, recursive = TRUE, force = TRUE)
  }
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  html_paths <- c(report_html, td_html)
  for (html_path in html_paths) {
    file.copy(html_path, output_dir, overwrite = TRUE)
    files_dir <- paste0(tools::file_path_sans_ext(html_path), "_files")
    if (dir.exists(files_dir)) {
      file.copy(files_dir, output_dir, recursive = TRUE, overwrite = TRUE)
    }
  }

  # GitHub Pages needs an index page at the root; the main report is it. A
  # byte-identical copy, not a redirect — its relative links to
  # IPBES_Fact_Checker_files/ still resolve since that directory sits
  # alongside it in the same output_dir.
  file.copy(
    file.path(output_dir, basename(report_html)),
    file.path(output_dir, "index.html"),
    overwrite = TRUE
  )

  # Skip Jekyll processing entirely — this tree is already plain static HTML.
  file.create(file.path(output_dir, ".nojekyll"))

  list.files(output_dir, recursive = TRUE, full.names = TRUE, all.files = TRUE)
}
