# ONE-TIME migration: fold the key-paper trees into the citing trees under a
# `keypaper=true|false` hive partition level.
#
# NOT A TARGET, deliberately -- same discipline as
# R/migrate_nli_scores_consolidate.R and R/find_orphaned_claim_scores.R: it
# moves and rewrites real scored data, which a target would re-run whenever
# anything upstream changed.
#
#   source("scripts/migrate_keypaper_fold.R")
#   inv <- kpf_inventory()                 # BEFORE -- save this
#   kpf_migrate(dry_run = TRUE)            # review the plan
#   kpf_migrate(dry_run = FALSE)
#   kpf_verify(inv)                        # parity against the before-inventory
#
# WHY `keypaper=` SITS ABOVE `assessment=`. Two things depend on it and neither
# is cosmetic:
#
#   1. consolidate_claim_scores() globs with a $-ANCHORED regex,
#      "/assessment=[^/]+/km=[^/]+/bm=[^/]+$". Inserting keypaper= between
#      assessment= and km= makes it match nothing; the consolidator then sees
#      zero on-disk groups and its own prune guard stop()s. Above assessment=,
#      those terminal three levels are untouched.
#   2. Each chain keeps its OWN disk root and .scratch root. score_one_claim()
#      and score_one_claim_jev() name scratch files <claim_id>.parquet, so under
#      a shared root a citing branch and a key-paper branch for the same claim
#      would race on the same filename. Separate roots make that impossible with
#      no change to either scorer.
#
# The two sets are disjoint BY DEFINITION under the adopted rule (keypaper =
# every paper tagged relation == "keypaper"; citing = citing AND NOT keypaper),
# so nothing is de-duplicated. kpf_verify() asserts the disjointness rather than
# assuming it -- note that 1,492 of GA1's 2,137 key papers DO cite another key
# paper (5,924 keypaper->keypaper edges), they are simply never tagged `citing`.

KPF_BACKUP <- ".premigration_keypaper_fold"

# Source roots already carry a `.premigration` from earlier migrations; they are
# not part of any dataset and must never be walked or moved.
kpf_is_internal <- function(paths) {
  grepl("(^|/)\\.(premigration|premigration_keypaper_fold|scratch)(/|$)", paths)
}

# The six trees. `levels` is what the SOURCE surfaces below the directory we
# open; `dest_partitioning` is what the merged tree must be written with.
kpf_trees <- function() {
  list(
    list(
      name = "claim_work_pairs", mode = "move",
      src = out_factcheck("claim_work_pairs"), dest = out_factcheck("claim_work_pairs"),
      keypaper = FALSE, above = "granularity"
    ),
    list(
      name = "claim_work_pairs_keypaper", mode = "rewrite",
      src = "output/claim_work_pairs_keypaper", dest = out_factcheck("claim_work_pairs"),
      keypaper = TRUE, above = "granularity",
      dest_partitioning = c("assessment", "km", "bm")
    ),
    list(
      name = "claim_scores", mode = "move",
      src = out_factcheck("claim_scores"), dest = out_factcheck("claim_scores"),
      keypaper = FALSE, above = "scorer_config"
    ),
    list(
      name = "claim_scores_keypaper", mode = "move",
      src = "output/claim_scores_keypaper", dest = out_factcheck("claim_scores"),
      keypaper = TRUE, above = "scorer_config"
    ),
    list(
      name = "llm_verification_scores", mode = "move",
      src = out_factcheck("llm_verification/scores"), dest = out_factcheck("llm_verification/scores"),
      keypaper = FALSE, above = "llm_config"
    ),
    list(
      name = "llm_verification_scores_keypaper", mode = "rewrite",
      src = out_factcheck("llm_verification/scores_keypaper"), dest = out_factcheck("llm_verification/scores"),
      keypaper = TRUE, above = "llm_config",
      dest_partitioning = c("assessment", "nli_route", "km", "bm")
    )
  )
}

kpf_label <- function(keypaper) paste0("keypaper=", tolower(as.character(keypaper)))

# Every directory one level below which the keypaper= level is inserted, e.g.
# every granularity=*/ under claim_work_pairs, every
# granularity=*/scorer_config=*/ under claim_scores.
kpf_anchor_dirs <- function(root, above) {
  if (!dir.exists(root)) return(character(0))
  depth <- switch(above, granularity = 1L, scorer_config = 2L, llm_config = 1L,
                  stop("unknown anchor level: ", above))
  dirs <- root
  for (i in seq_len(depth)) {
    dirs <- unlist(lapply(dirs, function(d) list.dirs(d, recursive = FALSE, full.names = TRUE)))
    dirs <- dirs[!kpf_is_internal(dirs)]
  }
  dirs
}

# Row counts come from parquet metadata via open_dataset(), not by reading the
# data -- claim_work_pairs alone is 165 GB.
kpf_count <- function(dir) {
  files <- list.files(dir, pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE)
  files <- files[!kpf_is_internal(files)]
  if (!length(files)) return(c(n_files = 0L, n_rows = 0L))
  n <- tryCatch(nrow(arrow::open_dataset(files)), error = function(e) NA_integer_)
  c(n_files = length(files), n_rows = n)
}

#' Row/file counts per tree, before or after. Save the BEFORE result.
kpf_inventory <- function(trees = kpf_trees()) {
  rows <- lapply(trees, function(t) {
    anchors <- kpf_anchor_dirs(t$src, t$above)
    if (!length(anchors)) {
      return(data.frame(tree = t$name, anchor = NA_character_,
                        n_files = 0L, n_rows = 0L, stringsAsFactors = FALSE))
    }
    do.call(rbind, lapply(anchors, function(a) {
      cnt <- kpf_count(a)
      data.frame(tree = t$name, anchor = sub("^output/", "", a),
                 n_files = as.integer(cnt[["n_files"]]), n_rows = as.integer(cnt[["n_rows"]]),
                 stringsAsFactors = FALSE)
    }))
  })
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

#' @param dry_run TRUE (default) prints the plan and touches nothing.
kpf_migrate <- function(trees = kpf_trees(), dry_run = TRUE) {
  for (t in trees) {
    if (!dir.exists(t$src)) {
      message(sprintf("[%s] source absent -- skipped", t$name))
      next
    }
    anchors <- kpf_anchor_dirs(t$src, t$above)
    for (a in anchors) {
      rel <- substring(a, nchar(t$src) + 2L)
      dest_anchor <- file.path(t$dest, rel, kpf_label(t$keypaper))

      if (identical(t$mode, "move")) {
        # Children of the anchor (assessment=*) move wholesale. For a 165 GB
        # tree this is a rename, not a copy.
        kids <- list.dirs(a, recursive = FALSE, full.names = TRUE)
        kids <- kids[!kpf_is_internal(kids)]
        # IDEMPOTENCY. A second run would otherwise see the keypaper= level this
        # one created and nest it: keypaper=false/keypaper=false/. Skipping any
        # child that is already a keypaper= level makes a re-run a no-op.
        already <- grepl("/keypaper=(true|false)$", kids)
        if (any(already)) {
          message(sprintf("[%s] %s already folded -- skipped", t$name, rel))
          next
        }
        if (!length(kids)) next
        message(sprintf("[%s] %s -> %s  (%d dirs, move)",
                        t$name, rel, sub("^output/", "", dest_anchor), length(kids)))
        if (dry_run) next
        dir.create(dest_anchor, recursive = TRUE, showWarnings = FALSE)
        for (k in kids) {
          ok <- file.rename(k, file.path(dest_anchor, basename(k)))
          if (!ok) stop(sprintf("move failed: %s", k), call. = FALSE)
        }
      } else {
        # Rewrite: km/bm (and nli_route) are ordinary columns in the source and
        # must become partition levels. Tiny trees only -- GA1 key papers.
        files <- list.files(a, pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE)
        files <- files[!kpf_is_internal(files)]
        if (!length(files)) next
        message(sprintf("[%s] %s -> %s  (%d files, rewrite, partition %s)",
                        t$name, rel, sub("^output/", "", dest_anchor),
                        length(files), paste(t$dest_partitioning, collapse = "/")))
        if (dry_run) next
        # Read file-by-file and RE-ATTACH the hive levels from each path.
        # open_dataset() on a bare file list does NOT surface them -- the same
        # trap build_llm_relevance_screen.R:359-363 documents -- and opening the
        # directory instead would pull in the pre-existing .premigration/ tree.
        d <- dplyr::bind_rows(lapply(files, function(f) {
          one <- arrow::read_parquet(f) |> dplyr::collect()
          rel_f <- substring(f, nchar(a) + 2L)
          segs <- strsplit(dirname(rel_f), "/", fixed = TRUE)[[1L]]
          segs <- segs[grepl("^[^=]+=", segs)]
          for (s in segs) {
            kv <- strsplit(s, "=", fixed = TRUE)[[1L]]
            one[[kv[[1L]]]] <- kv[[2L]]
          }
          one
        }))
        missing <- setdiff(t$dest_partitioning, names(d))
        if (length(missing)) {
          stop(sprintf("[%s] cannot partition by %s -- column(s) absent from %s",
                       t$name, paste(missing, collapse = ", "), rel), call. = FALSE)
        }
        dir.create(dest_anchor, recursive = TRUE, showWarnings = FALSE)
        arrow::write_dataset(d, dest_anchor, format = "parquet",
                             partitioning = t$dest_partitioning,
                             existing_data_behavior = "overwrite")
      }
    }

    # Retire the old root only when it is no longer the destination. Moved, not
    # deleted: rollback stays available. It must leave the dataset tree, or
    # every open_dataset() would read both layouts and double-count.
    if (!identical(t$src, t$dest) && !dry_run) {
      backup <- file.path(KPF_BACKUP, basename(t$src))
      dir.create(dirname(backup), recursive = TRUE, showWarnings = FALSE)
      if (file.rename(t$src, backup)) {
        message(sprintf("[%s] old root -> %s", t$name, backup))
      } else {
        warning(sprintf("[%s] could not retire %s -- move it by hand", t$name, t$src))
      }
    }
  }
  invisible(TRUE)
}

#' Parity against the before-inventory, plus the disjointness assertion.
kpf_verify <- function(before) {
  stopifnot(is.data.frame(before))
  ok <- TRUE

  totals <- tapply(before$n_rows, before$tree, sum, na.rm = TRUE)
  merged <- list(
    claim_work_pairs = c("claim_work_pairs", "claim_work_pairs_keypaper"),
    claim_scores = c("claim_scores", "claim_scores_keypaper"),
    `llm_verification/scores` = c("llm_verification_scores", "llm_verification_scores_keypaper")
  )
  for (root in names(merged)) {
    want <- sum(totals[merged[[root]]], na.rm = TRUE)
    path <- file.path("output", root)
    got <- if (dir.exists(path)) {
      f <- list.files(path, pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE)
      f <- f[!kpf_is_internal(f)]
      if (length(f)) nrow(arrow::open_dataset(f)) else 0L
    } else 0L
    hit <- isTRUE(want == got)
    ok <- ok && hit
    message(sprintf("%-26s before %s  after %s  %s", root,
                    format(want, big.mark = ","), format(got, big.mark = ","),
                    if (hit) "OK" else "** MISMATCH **"))
  }

  # DISJOINTNESS, scoped per (granularity, assessment).
  #
  # The invariant is that a (claim, work) pair never appears under both keypaper
  # values *within one assessment*. Two things make a naive check wrong, and
  # both were hit while writing this:
  #
  #   - `keypaper` is a per-ASSESSMENT property. A GA1 seed is legitimately a
  #     citing work in VA/TCA/BBA/IAS. The key is assessment-scoped so those
  #     never collide -- but a live-set pooled across assessments makes them
  #     look as though they do.
  #   - A score can outlive its corpus. Measured here: 273 GA1 key papers carry
  #     bge_m3_zeroshot scores while being absent from GA1's current atomic_bm
  #     claim_work_pairs entirely -- orphans from an earlier snowball, the class
  #     find_orphaned_claim_scores.R exists to find and build_nli_training_data.R
  #     already documented. Counting those as violations would fail the
  #     migration on pre-existing debris it did not create.
  #
  # So a key counts as a violation only when its work is still in the live
  # citing corpus for its OWN (granularity, assessment). Everything else is
  # reported separately.
  sp <- out_factcheck("claim_scores")
  if (dir.exists(sp)) {
    keys_for <- function(kp) {
      dirs <- list.dirs(sp, recursive = TRUE, full.names = TRUE)
      dirs <- dirs[grepl(paste0("/", kpf_label(kp), "$"), dirs)]
      out <- lapply(dirs, function(d0) {
        if (!length(list.files(d0, pattern = "\\.parquet$", recursive = TRUE))) return(NULL)
        d1 <- arrow::open_dataset(d0) |>
          dplyr::select("assessment", "km", "bm", "claim_id", "work_id") |>
          dplyr::collect()
        d1$granularity <- sub(".*/granularity=([^/]+)/.*", "\\1", d0)
        d1$key <- paste(d1$assessment, d1$km, d1$bm, d1$claim_id, d1$work_id)
        d1
      })
      dplyr::bind_rows(Filter(Negate(is.null), out))
    }
    kt <- keys_for(TRUE)
    kf <- keys_for(FALSE)
    both <- if (nrow(kt) && nrow(kf)) dplyr::semi_join(
      dplyr::distinct(kt, granularity, assessment, work_id, key),
      dplyr::distinct(kf, granularity, assessment, work_id, key),
      by = c("granularity", "assessment", "key")
    ) else kt[0, c("granularity", "assessment", "work_id", "key")]

    # Live citing corpus, per (granularity, assessment).
    live_for <- function(g, a) {
      d0 <- file.path(out_factcheck("claim_work_pairs"), paste0("granularity=", g),
                      "keypaper=false", paste0("assessment=", a))
      if (!dir.exists(d0)) return(character(0))
      f <- list.files(d0, pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE)
      if (!length(f)) return(character(0))
      unique(unlist(lapply(f, function(x) {
        as.data.frame(arrow::read_parquet(x, col_select = "work_id"))$work_id
      })))
    }

    if (!nrow(both)) {
      message("disjointness                 overlaps 0  OK")
    } else {
      combos <- unique(both[, c("granularity", "assessment")])
      viol <- 0L
      orph <- 0L
      detail <- character(0)
      for (i in seq_len(nrow(combos))) {
        g <- combos$granularity[[i]]; a <- combos$assessment[[i]]
        sub <- both[both$granularity == g & both$assessment == a, ]
        lv <- live_for(g, a)
        v <- sum(sub$work_id %in% lv)
        viol <- viol + v
        orph <- orph + (nrow(sub) - v)
        detail <- c(detail, sprintf("  %-12s %-5s  %5d overlaps: %d live%s",
                                    g, a, nrow(sub), v,
                                    if (v) " ** VIOLATION **" else " (all orphaned scores)"))
      }
      ok <- ok && (viol == 0L)
      message(sprintf("disjointness                 overlaps %d -> %d live violations, %d orphaned  %s",
                      nrow(both), viol, orph, if (viol) "** FAIL **" else "OK"))
      for (d0 in detail) message(d0)
      if (orph && !viol) {
        message("        orphans are pre-existing, not caused by this migration --")
        message("        see find_orphaned_claim_scores_all() to review and prune")
      }
    }
  }

  invisible(ok)
}
