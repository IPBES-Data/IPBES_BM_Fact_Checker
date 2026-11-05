# One-off repair: remove duplicate rows left by a half-fixed resume rule.
#
# WHAT HAPPENED (2026-10-09)
#
# score_one_claim_jev() writes a claim's COMPLETE row set to scratch --
# `bind_rows(cached, out)` -- because consolidate_claim_scores() supersedes every
# row whose claim_id appears in scratch, so writing only the delta would delete
# the rows it was meant to extend.
#
# A first attempt at making the resume rule NA-aware filtered only `already` (the
# work_ids to SKIP) and not `cached` itself. The failed pairs were therefore
# correctly re-sent and scored, but their stale NA rows were still in `cached`
# and were bound to the new scores. Every recovered pair landed TWICE: once NA,
# once scored. The signature: the corpus grew by exactly the NA count (A. +580,
# B. +2,280) while the NA count itself did not move.
#
# The source is fixed -- `cached` now drops unscored rows outright -- but the
# rows already written need removing, and a re-run will not do it: the scorer
# would read the duplicated cache, see every work_id as scored, and write it back.
#
# WHAT THIS REMOVES
#
# Only a row that is BOTH unscored (p_supports is NA) AND has a scored row for
# the same (claim_id, work_id). An NA with no scored twin is a genuine failure,
# not a duplicate, and is left alone -- deleting it would hide a real coverage
# gap, which is the failure mode this whole episode was about.
#
#   Rscript scripts/repair_duplicate_claim_scores.R           # dry run
#   Rscript scripts/repair_duplicate_claim_scores.R --write

suppressMessages({ library(arrow); library(dplyr) })
invisible(lapply(list.files("R", full.names = TRUE, pattern = "\\.R$"), source))

args     <- commandArgs(trailingOnly = TRUE)
do_write <- "--write" %in% args

GRAN <- "atomic_bm"; SCORER <- "jev_atomic_bm"
root <- file.path(out_factcheck("claim_scores"), paste0("granularity=", GRAN),
                  paste0("scorer_config=", SCORER))

cat(sprintf("Repairing %s\nMode: %s\n\n", root,
            if (do_write) "WRITE" else "DRY RUN (pass --write to apply)"))

# Every leaf that actually holds parquet. Walking the tree rather than guessing
# the partition shape, so a keypaper= or km= level that differs cannot be missed.
leaves <- unique(dirname(list.files(root, pattern = "\\.parquet$",
                                    recursive = TRUE, full.names = TRUE)))
leaves <- leaves[!grepl("/[.]", leaves)]          # skip .scratch / .premigration
cat(sprintf("%d leaf director(ies) with data\n\n", length(leaves)))

tot_rows <- tot_dupe <- tot_orphan <- 0L
touched <- character(0)

for (d in leaves) {
  dat <- tryCatch(arrow::open_dataset(d) |> dplyr::collect(), error = function(e) NULL)
  if (is.null(dat) || !nrow(dat)) next
  tot_rows <- tot_rows + nrow(dat)
  if (!any(is.na(dat$p_supports))) next

  key    <- paste(dat$claim_id, dat$work_id, sep = "\r")
  has_ok <- key %in% key[!is.na(dat$p_supports)]
  dupe   <- is.na(dat$p_supports) & has_ok        # NA with a scored twin
  orphan <- is.na(dat$p_supports) & !has_ok       # NA with none -- keep

  tot_dupe   <- tot_dupe + sum(dupe)
  tot_orphan <- tot_orphan + sum(orphan)
  if (!sum(dupe)) next

  cat(sprintf("  %-72s  %7s rows  -%s dupe  (%s genuine NA kept)\n",
              sub(root, "<root>", d, fixed = TRUE), format(nrow(dat), big.mark = ","),
              format(sum(dupe), big.mark = ","), format(sum(orphan), big.mark = ",")))
  touched <- c(touched, d)

  if (do_write) {
    keep <- dat[!dupe, , drop = FALSE]
    stopifnot(nrow(keep) == nrow(dat) - sum(dupe),
              !any(duplicated(paste(keep$claim_id, keep$work_id, sep = "\r")[
                     !is.na(keep$p_supports)])))
    # Temp-then-replace, so an interrupted write cannot leave a leaf half-gone.
    # Opening a LEAF directly (not the dataset root) means arrow never sees the
    # hive levels, so km/bm/assessment/keypaper are absent from `dat` -- they
    # live in the path. Writing `keep` back therefore preserves exactly the
    # columns the file had. Asserted rather than assumed: silently dropping or
    # adding a column here would corrupt the dataset schema for every reader.
    before_cols <- names(arrow::open_dataset(d)$schema)
    stopifnot(identical(sort(names(keep)), sort(before_cols)))
    tmp <- file.path(d, ".repair.tmp.parquet")
    arrow::write_parquet(keep, tmp)
    stopifnot(identical(sort(names(arrow::read_parquet(tmp, as_data_frame = FALSE))),
                        sort(before_cols)))
    old <- setdiff(list.files(d, pattern = "\\.parquet$", full.names = TRUE), tmp)
    file.rename(tmp, file.path(d, "part-0.parquet.new"))
    unlink(old, force = TRUE)
    file.rename(file.path(d, "part-0.parquet.new"), file.path(d, "part-0.parquet"))
  }
}

cat(sprintf("\n  scanned      %s rows across %d leaves\n", format(tot_rows, big.mark = ","), length(leaves)))
cat(sprintf("  duplicates   %s  (NA rows whose pair was re-scored)\n", format(tot_dupe, big.mark = ",")))
cat(sprintf("  genuine NA   %s  (kept -- a real coverage gap, not a duplicate)\n", format(tot_orphan, big.mark = ",")))
if (do_write) {
  cat(sprintf("\n  REWROTE %d leaf director(ies).\n", length(touched)))
  cat("  Re-run the pipeline: Phase 1 will be a cache pass, Phase 2 a replay.\n")
} else {
  cat("\n  Dry run only -- nothing written. Re-run with --write to apply.\n")
}
