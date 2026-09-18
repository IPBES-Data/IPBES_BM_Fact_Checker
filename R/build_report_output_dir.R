# Deploy extras for output/reports/ that Quarto itself does not produce.
#
# .github/workflows/deploy-pages.yml rsyncs output/reports/ verbatim to the
# gh-pages branch, so that directory needs three things Quarto knows nothing
# about: a .nojekyll, an index.html, and the CLAUDE.md that TD_targets.qmd
# links to by a plain relative path.
#
# This is all that survives of the former, much larger version of this
# function. It used to also PRUNE -- diffing the directory against an
# `expected` list and unlink()ing anything else -- which had two problems:
# the expected list was assembled by hand from the render targets' return
# values and silently omitted two of them (nli_training_qa_report_html and
# nli_finetuned_model_qa_report_html), so those two reports were deleted on
# every run; and it was the only thing clearing stale outputs from earlier
# naming conventions.
#
# The first problem is fixed by dropping it. The second is NOT: Quarto's
# project render was measured not to touch files it does not manage (a stray
# file and a .nojekyll both survived one), so stale html from an earlier
# naming convention persists until removed by hand. Deliberate for now --
# deleting files out of a git-tracked, auto-deployed directory is what made
# the old version dangerous.
#
# Ordering still matters (reports_project -> report_fact_checker -> here),
# because the main report copies its siblings' rendered html into its own
# _files/ sidecar.
build_report_output_dir <- function(
  report_html,
  reports_project,
  claude_md,
  output_dir = "output/reports"
) {
  # Taken only to establish the dependency edges that order this target after
  # both renders. reports_project's own outputs really are already in
  # output_dir (the Quarto project's output-dir puts them there); the MAIN
  # report's are not -- see the copy below.
  force(reports_project)

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  # tar_quarto() returns a vector (rendered output, sources, inputs), not a
  # single path, so pick the report itself rather than assuming element one.
  html <- report_html[grepl("IPBES_Fact_Checker\\.html$", report_html)]
  if (length(html) != 1L) {
    stop(sprintf(
      "build_report_output_dir(): expected exactly one IPBES_Fact_Checker.html in the report_fact_checker target's value, found %d (%s)",
      length(html), paste(report_html, collapse = ", ")
    ), call. = FALSE)
  }

  file.copy(claude_md, output_dir, overwrite = TRUE)

  # The main report is NOT written to output_dir by Quarto, unlike every
  # document in reports_project. _quarto.yml's `output-dir` only applies to
  # files Quarto renders AS PART OF the project, and IPBES_Fact_Checker.qmd is
  # deliberately excluded from its `render:` list so that it runs after the
  # others (it copies their rendered html into its own sidecar). Rendering it
  # as a single file therefore picks up the project's `format:` but NOT its
  # `output-dir`, leaving the html next to the source in input/reports/.
  #
  # Verified directly rather than assumed: `quarto render <file>
  # --output-dir ...` is rejected ("The --output-dir flag can only be used
  # when rendering projects"), and re-listing the file after the exclusion in
  # `render:` does not re-include it -- the exclusion wins and the document is
  # not rendered at all. So one copy step survives here for this one document.
  # This is the single remaining instance of the file-moving the rest of the
  # refactor removed; it is a copy, not a move, so report_fact_checker's own
  # tracked file stays where targets recorded it.
  #
  # The _files/ sidecar has to come too: this is the only report with
  # embed-resources: false (deliberate, for size), so its html is useless
  # without it -- and index.html below is a byte-identical copy that relies on
  # the same relative IPBES_Fact_Checker_files/ links resolving.
  if (!identical(normalizePath(dirname(html), mustWork = FALSE),
                 normalizePath(output_dir, mustWork = FALSE))) {
    file.copy(html, output_dir, overwrite = TRUE)
    sidecar <- file.path(dirname(html), "IPBES_Fact_Checker_files")
    if (dir.exists(sidecar)) {
      unlink(file.path(output_dir, "IPBES_Fact_Checker_files"),
             recursive = TRUE, force = TRUE)
      file.copy(sidecar, output_dir, recursive = TRUE)
    }
  }

  # A byte-identical copy rather than a redirect, so index.html's relative
  # IPBES_Fact_Checker_files/ links still resolve.
  file.copy(file.path(output_dir, basename(html)),
            file.path(output_dir, "index.html"), overwrite = TRUE)
  file.create(file.path(output_dir, ".nojekyll"))

  list.files(output_dir, recursive = TRUE, all.files = TRUE, full.names = TRUE)
}
