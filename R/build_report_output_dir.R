# Finish assembling the self-contained output/reports/ directory that
# .github/workflows/deploy-pages.yml publishes verbatim to gh-pages.
#
# The report + every TD doc + every per-assessment label funnel report +
# every QA BM-split report ALREADY render directly into output_dir (each
# one's own _targets.R target does the rendering and, since Quarto's
# embed-resources: true means its .html is the only artifact produced,
# a single file.rename() out of input/reports/ into here -- see
# td_doc_html's comment). This target no longer copies anything in; it
# only adds the two files nothing else produces (index.html, .nojekyll,
# both trivial to regenerate) and copies in CLAUDE.md (TD_targets.qmd
# links to it by a plain relative path).
#
# Deliberately NOT a wipe-then-rebuild (unlink(output_dir) then repopulate)
# the way this used to work when it was doing the copying itself -- that
# would delete the reports every upstream target just placed here, since
# this target runs AFTER them. Instead: prune only entries NOT in the
# expected set (computed from the arguments this target already receives),
# so a report/doc that's since been removed from the pipeline doesn't
# linger forever, without touching what's correctly already in place.
build_report_output_dir <- function(report_html, td_html, claude_md, output_dir = "output/reports") {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  html_paths <- c(report_html, td_html)
  expected <- c(
    basename(html_paths),
    paste0(tools::file_path_sans_ext(basename(html_paths)), "_files"),
    "index.html", ".nojekyll", basename(claude_md)
  )
  current <- list.files(output_dir, all.files = TRUE, no.. = TRUE)
  stale <- setdiff(current, expected)
  for (s in stale) {
    unlink(file.path(output_dir, s), recursive = TRUE, force = TRUE)
  }

  file.copy(claude_md, output_dir, overwrite = TRUE)

  # GitHub Pages needs an index page at the root; the main report is it. A
  # byte-identical copy, not a redirect -- its relative links to
  # IPBES_Fact_Checker_files/ still resolve since that directory sits
  # alongside it in the same output_dir.
  file.copy(report_html, file.path(output_dir, "index.html"), overwrite = TRUE)

  # Skip Jekyll processing entirely -- this tree is already plain static HTML.
  file.create(file.path(output_dir, ".nojekyll"))

  list.files(output_dir, recursive = TRUE, all.files = TRUE, full.names = TRUE)
}
