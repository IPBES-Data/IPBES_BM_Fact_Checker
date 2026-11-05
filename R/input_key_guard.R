# Content-key guards for the collection pipeline's expensive external fetches.
#
# WHY THIS EXISTS
#
# `targets` invalidates on the hash of a target's command AND of every function
# body it reaches. That is the right default for derived data, but it is the
# wrong question to ask about a download: editing a path literal inside
# download_works() does not mean OpenAlex has new records. On 2026-10-07 the
# output/ restructure edited exactly such a literal in all seven collection
# builders and left 16 of 18 targets outdated, with every network target queued
# to refetch a corpus that had not changed -- days of OpenAlex time, 16 GB of
# snowball deleted, and a different corpus from the one every existing score was
# computed against.
#
# So each expensive fetch additionally records WHAT IT FETCHED FOR -- the set of
# identifiers that actually determine its output -- and skips when that set is
# unchanged. This is not an existence guard. An existence guard ("the directory
# is there, skip") breaks the invalidation contract outright: a genuinely new
# TTL or a new Zotero item would be silently ignored, which is the bug class
# commit 0bb6bb0 removed from two nli_ready builders. A content key keeps the
# contract -- a real upstream change moves the key and the work re-runs -- while
# making function-body edits and directory moves free.
#
# WHERE EACH KEY COMES FROM
#
# The collection chain is a single line, not two independent roots:
#
#   ttl_path -> refs_parquet -> zotero_parquet -> works_parquet
#                            -> key_messages_parquet      |
#                                                         v
#              works_citing_parquet <- snowball_parquet <-+
#
# TTL and Zotero are both external services, but Zotero sits BELOW refs and
# takes only the group id from it (download_zotero.R's infer_zotero_group_id()),
# and the DOI set that drives OpenAlex comes from zotero_parquet, not refs
# (download_works.R). So:
#
#   target              key                                   cost if it runs
#   ------------------  ------------------------------------  ---------------
#   ttl_path            GitHub blob SHA                        seconds
#                       (already done in download_ttls.R --
#                        this file generalises that idea)
#   refs/key_messages   none; local SPARQL over the TTL        minutes
#   zotero_parquet      group id + Zotero library version      minutes
#   works_parquet       the DOI set + the refs (doi,km,bm) map hours
#   snowball_parquet    the seed work-id set                   DAYS, 16 GB
#   works_citing        none; local DuckDB over the above      minutes
#
# Only the three with a real external cost are guarded. The locally-derived
# targets are left alone deliberately: they are cheap, and every guard is a
# place where a stale skip can hide.
#
# ESCAPE HATCH
#
# Every guarded builder takes `force`, defaulting to the COLLECTION_FORCE_REFRESH
# environment variable, so a refetch can always be demanded without editing code:
#
#   COLLECTION_FORCE_REFRESH=1 Rscript -e 'targets::tar_make()'

# Key files live in their own hidden directory, never inside a dataset tree.
# Arrow does skip dot-prefixed files, but putting state a builder depends on
# inside the data it reads is how the .premigration directories became a trap.
input_key_dir <- function(root = out_collection(".inputkeys")) root

input_key_file <- function(target, assessment_id, root = input_key_dir()) {
  file.path(root, paste0(target, "_", assessment_id, ".key"))
}

# Hash the STRING form with serialize = FALSE, the same discipline hash_bucket()
# uses in branch_helpers.R: a serialized R object's bytes are not guaranteed
# stable across R or digest upgrades, and a key that silently changes on a
# package update would trigger exactly the refetch this exists to prevent.
input_key <- function(...) {
  parts <- lapply(list(...), function(x) paste(sort(unique(as.character(x))), collapse = "\n"))
  digest::digest(paste(unlist(parts), collapse = "\n\036\n"),
                 algo = "sha256", serialize = FALSE)
}

input_key_read <- function(target, assessment_id, root = input_key_dir()) {
  f <- input_key_file(target, assessment_id, root)
  if (!file.exists(f)) return(NA_character_)
  v <- readLines(f, warn = FALSE)
  if (!length(v)) NA_character_ else v[[1L]]
}

input_key_write <- function(target, assessment_id, key, root = input_key_dir()) {
  dir.create(root, showWarnings = FALSE, recursive = TRUE)
  writeLines(key, input_key_file(target, assessment_id, root))
  invisible(key)
}

input_key_clear <- function(target, assessment_id, root = input_key_dir()) {
  unlink(input_key_file(target, assessment_id, root), force = TRUE)
}

# TRUE only when the recorded key matches AND every output path still holds
# data. The outputs are re-checked rather than trusted because a key file
# outliving its data would turn one stale skip into a silently empty pipeline --
# the failure mode config_assessments() exists to prevent one level up.
input_key_is_current <- function(target, assessment_id, key, outputs,
                                 force = collection_force_refresh(),
                                 root = input_key_dir()) {
  if (isTRUE(force)) return(FALSE)
  if (is.na(key)) return(FALSE)
  if (!identical(input_key_read(target, assessment_id, root), key)) return(FALSE)
  all(vapply(outputs, dir_has_data, logical(1)))
}

dir_has_data <- function(path) {
  dir.exists(path) &&
    length(list.files(path, pattern = "\\.parquet$", recursive = TRUE)) > 0L
}

collection_force_refresh <- function() {
  v <- Sys.getenv("COLLECTION_FORCE_REFRESH", "")
  nzchar(v) && !identical(tolower(v), "false") && !identical(v, "0")
}

input_key_skip_message <- function(target, assessment_id, what) {
  message(sprintf(
    "[%s %s] %s unchanged -- skipping fetch (set COLLECTION_FORCE_REFRESH=1 to override)",
    target, assessment_id, what
  ))
}
