# One-time bootstrap for the collection pipeline's content-key guards.
#
#   Rscript scripts/seed_collection_input_keys.R            # dry run, reports only
#   Rscript scripts/seed_collection_input_keys.R --write    # write the key files
#
# WHY THIS IS NEEDED ONCE
#
# The guards in R/input_key_guard.R skip a fetch when the recorded input key
# matches the current one. On 2026-10-07 there were no recorded keys at all --
# the data on disk predates the mechanism -- so the first tar_make() would see
# "no key" and refetch everything, which is the exact outcome the guards exist
# to prevent. This asserts that the outputs already on disk correspond to the
# inputs already on disk, and records that fact.
#
# WHAT IT DELIBERATELY DOES NOT SEED
#
# `zotero`. Its key includes the LIVE Zotero library version, and seeding it
# from the current remote version would assert something this script cannot
# check: that the on-disk copy was downloaded at that version. If the group has
# changed since, that assertion is false and the staleness would propagate
# silently into works and snowball -- the one failure mode with no error and no
# signal. Zotero is minutes to refetch, so it refetches. If nothing changed, the
# DOI set comes out identical, the works key matches, and works skips anyway.
#
# `ttl_path` needs nothing: download_ttl() has always been SHA-checked.
#
# SAFETY
#
# Refuses to seed any target whose output is missing or empty, and refuses to
# overwrite an existing key unless --force is passed. Seeding a key for data
# that is not there would turn one wrong skip into a silently empty pipeline.

suppressMessages({
  library(arrow)
  library(dplyr)
})
invisible(lapply(list.files("R", full.names = TRUE, pattern = "\\.R$"), source))

args     <- commandArgs(trailingOnly = TRUE)
do_write <- "--write" %in% args
do_force <- "--force" %in% args

config      <- yaml::read_yaml("input/config.yaml")
assessments <- config_assessments(config)

cat(sprintf("Seeding collection input keys for %d assessment(s): %s\n",
            length(assessments),
            paste(vapply(assessments, function(a) a$id, character(1)), collapse = ", ")))
cat(sprintf("Mode: %s%s\n\n",
            if (do_write) "WRITE" else "DRY RUN (pass --write to apply)",
            if (do_force) " --force (will overwrite existing keys)" else ""))

problems <- character(0)

for (a in assessments) {
  id <- a$id
  cat(sprintf("== %s ==\n", id))

  zotero_path <- branch_output_dir(out_collection("zotero"), id)
  refs_path   <- branch_output_dir(out_collection("refs"), id)
  works_path  <- branch_output_dir(out_collection("works"), id)
  nodes_path  <- file.path(out_collection("snowball"), "nodes", paste0("assessment=", id))
  edges_path  <- file.path(out_collection("snowball"), "edges", paste0("assessment=", id))

  seed_one <- function(target, key_fn, outputs, describe) {
    missing <- outputs[!vapply(outputs, dir_has_data, logical(1))]
    if (length(missing)) {
      cat(sprintf("  %-9s SKIP -- output missing or empty: %s\n",
                  target, paste(missing, collapse = ", ")))
      problems <<- c(problems, sprintf("%s/%s: no output to vouch for", id, target))
      return(invisible(NULL))
    }
    existing <- input_key_read(target, id)
    key <- tryCatch(key_fn(), error = function(e) {
      cat(sprintf("  %-9s SKIP -- cannot compute key: %s\n", target, conditionMessage(e)))
      problems <<- c(problems, sprintf("%s/%s: %s", id, target, conditionMessage(e)))
      NULL
    })
    if (is.null(key)) return(invisible(NULL))

    if (!is.na(existing) && identical(existing, key)) {
      cat(sprintf("  %-9s already current (%s)\n", target, describe))
      return(invisible(NULL))
    }
    if (!is.na(existing) && !do_force) {
      cat(sprintf("  %-9s REFUSING -- a different key is already recorded; pass --force\n", target))
      problems <<- c(problems, sprintf("%s/%s: key differs from recorded", id, target))
      return(invisible(NULL))
    }
    if (do_write) {
      input_key_write(target, id, key)
      cat(sprintf("  %-9s WROTE  %s  (%s)\n", target, substr(key, 1, 16), describe))
    } else {
      cat(sprintf("  %-9s would write %s  (%s)\n", target, substr(key, 1, 16), describe))
    }
  }

  # works: the DOI set from zotero + the refs (doi, km, bm) mapping
  seed_one(
    "works",
    function() {
      dois <- works_input_dois(zotero_path)
      if (!length(dois)) stop("no DOIs in ", zotero_path)
      works_input_key(dois, refs_path)
    },
    outputs  = works_path,
    describe = sprintf("%d DOIs", length(tryCatch(works_input_dois(zotero_path), error = function(e) character(0))))
  )

  # snowball: the seed work-id set from works
  seed_one(
    "snowball",
    function() snowball_input_key(snowball_input_seeds(works_path)),
    outputs  = c(nodes_path, edges_path),
    describe = sprintf("%d seeds", length(tryCatch(snowball_input_seeds(works_path), error = function(e) character(0))))
  )

  cat("\n")
}

if (length(problems)) {
  cat("Not everything could be seeded:\n")
  for (p in problems) cat("  - ", p, "\n", sep = "")
  cat("\nThose targets will fetch for real on the next run.\n")
} else if (do_write) {
  cat("All keys recorded. The next collection run should skip works and snowball.\n")
  cat("Verify first with:  TAR_PROJECT=collection Rscript -e 'targets::tar_outdated()'\n")
} else {
  cat("Dry run only -- nothing written. Re-run with --write to apply.\n")
}
