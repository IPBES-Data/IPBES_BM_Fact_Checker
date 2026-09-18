# Score ONE claim-unit (crew-dispatched target, one branch per claim).
#
# Dynamic host dispatch: tries every host's lock file in turn (non-blocking);
# whichever host is currently free gets this claim. This is what makes
# dispatch genuinely dynamic — assignment happens when a worker becomes
# free, not via an upfront estimate like the old LPT approach. crew manages
# LOCAL concurrency (how many claims run at once); the lock decides which
# REMOTE host a given claim uses.
#
# Output layout: each claim writes its rows to its OWN scratch file, and a
# separate consolidation pass (consolidate_nli_scores(),
# R/consolidate_nli_scores.R) merges every scratch file of a (km, bm) group
# into that group's single consolidated parquet once per run. `claim_id` is
# therefore a plain COLUMN here, not a partition level: partitioning down to
# claim_id produced ~1,276 files averaging 6 KB for the keypaper chain alone,
# where roughly 4.4 KB per file is pure parquet footer/schema/column-stats
# overhead. Writing per-claim scratch files keeps this function exactly as
# contention-free as the old per-claim partition directories (each branch
# owns a uniquely-named file, no locking), while paying the full read+rewrite
# of the larger consolidated file once per (km, bm) per run instead of once
# per claim.
#
# Resumable, at WORK granularity — not claim granularity. This function reads
# the work_id set already scored for this claim and sends only the works
# missing from it; a claim with nothing missing is skipped, a claim with new
# works gains exactly those. BOTH cache locations are read and unioned — the
# consolidated file and this claim's not-yet-merged scratch file — so a run
# interrupted before consolidation never re-pays for scoring it already did.
#
# It used to skip the whole claim the moment ANY output existed for it, which
# silently froze every already-scored claim at its first-run coverage. Citing
# works accrue continuously (papers keep being published that cite the seeds),
# so each snowball re-run grew nli_ready_evidence while the scores stood still:
# targets DID re-dispatch the branch (the claim unit's n_pairs had changed) and
# this function then returned "already scored" without ever consulting the work
# set. Measured on real data before the fix: GA1 A./A2 bm_description-05 held
# 28,825 scored works against 257,708 present, and nothing would ever have
# scored the other 228,883. That is the same broken-invalidation-contract shape
# removed from the two nli_ready builders in 0bb6bb0; the guard could not
# simply be deleted here the way theirs were, because a full rescore costs real
# GPU time, so it was narrowed to the delta instead.
#
# The cache is still content-guarded, and discarded outright on a mismatch:
# `claim_id` is a structural key (sentence_source + sentence_number), not a
# hash of the claim text, so the SAME claim_id can end up holding different
# text across runs (a re-segmented boundary, a re-completed atomic_bm
# fragment, ...). The cached output stores the exact claim text it was scored
# against (the `claim` column) and the model that produced it (`nli_model`);
# either differing from the current one forces a full rescore of the claim
# rather than a delta, so scores for stale text — or two models' scores merged
# under one claim — can never be served.
#
# The scratch file this writes therefore holds the claim's COMPLETE row set,
# cached rows included, because consolidate_nli_scores() supersedes every
# existing row whose claim_id appears in scratch.
#
# Un-migrated-state guard: a (km, bm) holding legacy `claim_id=*/` partition
# directories but no consolidated parquet means the one-time migration
# (R/migrate_nli_scores_consolidate.R) has not been run. Left undetected that
# state reads as "nothing scored yet" and would re-dispatch the entire
# corpus at real GPU cost, so it stop()s loudly instead.
#
# Failure isolation: this function does NOT catch-and-swallow errors from
# the classify call — it lets them propagate. Combined with
# `error = "continue"` on the nli_scores_by_claim target, a failing claim is
# reported live (by targets' own progress output) and marked failed, while
# every other claim's branch proceeds completely independently. Re-running
# tar_make() only retries the failed claims.
score_one_claim <- function(
  claim_unit,
  nli_config,
  nli_active,
  nli_model,
  lock_dir = "output/nli_scores/.locks_temp",
  output_root = "output/nli_scores"
) {
  cfg <- if (is.null(nli_config)) list() else nli_config
  assessment_id <- claim_unit$assessment

  this_claim_id <- claim_unit$claim_id

  output_path <- file.path(
    output_root, paste0("nli_config=", nli_active), paste0("assessment=", assessment_id)
  )
  bm_dir <- file.path(
    output_path, paste0("km=", claim_unit$km), paste0("bm=", claim_unit$bm)
  )
  scratch_dir <- file.path(
    output_root, ".scratch", paste0("nli_config=", nli_active),
    paste0("assessment=", assessment_id),
    paste0("km=", claim_unit$km), paste0("bm=", claim_unit$bm)
  )
  scratch_file <- file.path(scratch_dir, paste0(this_claim_id, ".parquet"))

  # The branch's return value: a small record, NOT a file path. Returning the
  # consolidated file path would make every branch of a (km, bm) return the
  # same path, whose hash changes as sibling branches write — permanent
  # invalidation churn under format = "file". A plain record also means
  # consolidation is free to delete the scratch file afterwards without
  # invalidating anything.
  # n_rows is the claim's TOTAL row count after this branch; n_new is how many
  # of those this branch actually scored. Keeping both makes a delta run
  # legible from tar_read() alone -- "skipped" with n_rows > 0 and n_new == 0
  # is a genuine no-op, whereas the old all-or-nothing skip looked identical
  # whether it had passed over 0 new works or 228,883. Nothing downstream
  # destructures this list (consolidate_nli_scores() rescans the disk and
  # never reads status/n_rows), so the extra field is safe to add.
  as_count <- function(x) if (length(x) != 1L || is.na(x)) 0L else as.integer(x)
  record <- function(status, n_rows = 0L, n_new = 0L) {
    list(
      nli_config = nli_active, assessment = assessment_id,
      km = claim_unit$km, bm = claim_unit$bm, claim_id = this_claim_id,
      claim = claim_unit$claim, scratch_file = scratch_file,
      status = status,
      n_rows = as_count(n_rows), n_new = as_count(n_new)
    )
  }

  # Read the consolidated file(s) by explicit path rather than open_dataset()
  # on bm_dir: any stray legacy claim_id=*/ subdirectory would otherwise be
  # picked up as a partition level and collide with the claim_id column.
  consolidated_files <- if (dir.exists(bm_dir)) {
    list.files(bm_dir, pattern = "\\.parquet$", full.names = TRUE)
  } else {
    character(0)
  }
  legacy_dirs <- if (dir.exists(bm_dir)) {
    grep("/claim_id=[^/]+$", list.dirs(bm_dir, recursive = FALSE), value = TRUE)
  } else {
    character(0)
  }

  if (!length(consolidated_files) && length(legacy_dirs)) {
    stop(sprintf(
      paste0(
        "[NLI %s] km=%s/bm=%s holds %d legacy claim_id=*/ partition director%s but no ",
        "consolidated parquet — the one-time migration has not been run for this group. ",
        "Run migrate_nli_scores_consolidate() (R/migrate_nli_scores_consolidate.R) before ",
        "scoring, or every already-scored claim here would be re-dispatched at real GPU cost."
      ),
      assessment_id, claim_unit$km, claim_unit$bm,
      length(legacy_dirs), if (length(legacy_dirs) == 1) "y" else "ies"
    ))
  }

  # ---- what has already been scored for THIS claim? ----------------------
  #
  # Both locations are read and UNIONED rather than checked in order. After a
  # delta run (below) the scratch file holds the claim's FULL row set while the
  # consolidated file still holds only the pre-delta rows, so a run interrupted
  # between scoring and consolidation would otherwise re-score the same delta
  # again. Scratch is the newer of the two and wins on any work_id in both.
  #
  # nli_config/assessment/km/bm are re-stamped as constants rather than read
  # back: consolidate_nli_scores() strips them (they live in the consolidated
  # file's own Hive path) and open_dataset() on explicit file paths does not
  # infer them again, while the scratch schema does carry them. Re-stamping
  # makes both sources schema-identical to `out` below, and they are constants
  # for this claim by construction.
  stamp_cols <- function(df) {
    if (is.null(df) || !nrow(df)) {
      return(NULL)
    }
    df$nli_config <- nli_active
    df$assessment <- assessment_id
    df$km <- claim_unit$km
    df$bm <- claim_unit$bm
    df
  }
  read_cached <- function(expr, src) {
    tryCatch(expr(), error = function(e) {
      message(sprintf(
        "[NLI %s] claim_id=%s: could not read %s (%s) - treating those rows as unscored",
        assessment_id, this_claim_id, src, conditionMessage(e)
      ))
      NULL
    })
  }

  cached <- NULL
  if (length(consolidated_files)) {
    cached <- stamp_cols(read_cached(function() {
      arrow::open_dataset(consolidated_files) |>
        dplyr::filter(claim_id == .env$this_claim_id) |>
        dplyr::collect()
    }, "consolidated parquet"))
  }
  if (file.exists(scratch_file)) {
    scr <- stamp_cols(read_cached(function() {
      arrow::read_parquet(scratch_file) |>
        dplyr::filter(claim_id == .env$this_claim_id)
    }, "scratch parquet"))
    if (!is.null(scr)) {
      if (!is.null(cached)) {
        cached <- cached[!(cached$work_id %in% scr$work_id), , drop = FALSE]
      }
      cached <- dplyr::bind_rows(cached, scr)
    }
  }
  if (!is.null(cached) && !nrow(cached)) cached <- NULL

  # A cached row set is reusable only if it was produced from the SAME claim
  # text AND by the same model. claim_id is a structural key (sentence_source +
  # sentence_number), not a hash of the text, so one claim_id can hold
  # different text across runs (a re-segmented boundary, a re-completed
  # atomic_bm fragment); and a pool re-deployed with a different model makes
  # old and new scores incomparable. Either case discards the cache outright
  # rather than leaving two incompatible halves merged under one claim.
  if (!is.null(cached)) {
    reason <- NULL
    if (!identical(cached$claim[[1L]], claim_unit$claim)) {
      reason <- "cached claim text differs from the current one"
    } else if (!is.null(nli_model) && !all(cached$nli_model == nli_model)) {
      reason <- sprintf(
        "cached rows were scored by a different model (%s, now %s)",
        paste(unique(cached$nli_model), collapse = "/"), nli_model
      )
    }
    if (!is.null(reason)) {
      message(sprintf(
        "[NLI %s] claim_id=%s (km=%s/bm=%s): %s - discarding %s cached row(s), rescoring in full",
        assessment_id, this_claim_id, claim_unit$km, claim_unit$bm,
        reason, format(nrow(cached), big.mark = ",")
      ))
      cached <- NULL
    }
  }

  already <- if (is.null(cached)) character(0) else unique(cached$work_id)

  # ---- delta dispatch -----------------------------------------------------
  #
  # Score the works NOT already scored for this claim, rather than skipping the
  # whole claim the moment any output exists. The old all-or-nothing skip froze
  # a claim at whatever coverage it had on the day it was first scored: every
  # snowball re-run adds citing works to an existing BM (papers keep being
  # published and citing the seeds), targets correctly re-dispatched the branch
  # because the claim unit's n_pairs had changed, and this function then
  # returned "already scored" without ever looking at the work set. Measured on
  # real data before this fix: GA1 A./A2 bm_description-05 held 28,825 scored
  # works against 257,708 in nli_ready_evidence, and would never have gained
  # the other 228,883.
  #
  # That is the same broken-invalidation-contract shape removed from the two
  # nli_ready builders, but the guard here cannot simply be deleted the way
  # theirs were: a full rescore costs real GPU time, so it is narrowed to the
  # delta instead of dropped.
  #
  # work_id is read on its own first. For an unchanged claim - the common case -
  # it is all that is needed to decide there is nothing to do, and the premise
  # column is large enough that reading it for a 250k-work claim only to
  # discard every row would make every no-op branch expensive.
  claim_rows <- function(cols) {
    arrow::open_dataset(claim_unit$nli_ready_path) |>
      dplyr::filter(
        km == claim_unit$km, bm == claim_unit$bm,
        sentence_number == claim_unit$sentence_number,
        sentence_source == claim_unit$sentence_source
      ) |>
      dplyr::select(dplyr::all_of(cols)) |>
      dplyr::collect()
  }

  work_ids <- unique(claim_rows("work_id")$work_id)

  if (!length(work_ids)) {
    message(sprintf(
      "[NLI %s] claim_id=%s (km=%s/bm=%s): no premises found - nothing to score",
      assessment_id, this_claim_id, claim_unit$km, claim_unit$bm
    ))
    return(record("no_premises"))
  }

  todo_ids <- setdiff(work_ids, already)

  if (!length(todo_ids)) {
    message(sprintf(
      "[NLI %s] claim_id=%s (km=%s/bm=%s): all %s work(s) already scored - skipping",
      assessment_id, this_claim_id, claim_unit$km, claim_unit$bm,
      format(length(work_ids), big.mark = ",")
    ))
    return(record("skipped", length(already), 0L))
  }

  if (length(already)) {
    message(sprintf(
      "[NLI %s] claim_id=%s (km=%s/bm=%s): %s of %s work(s) already scored - scoring %s new one(s)",
      assessment_id, this_claim_id, claim_unit$km, claim_unit$bm,
      format(length(already), big.mark = ","), format(length(work_ids), big.mark = ","),
      format(length(todo_ids), big.mark = ",")
    ))
  }

  # Premises for the delta only. Subsetting happens in R rather than via an
  # Arrow `work_id %in% todo_ids` filter: these id sets routinely reach 100k+,
  # which is exactly where arrow's %in% has already been found to break in this
  # project (see build_works_citing_parquet.R).
  cw <- claim_rows(c("work_id", "premise"))
  cw <- cw[cw$work_id %in% todo_ids, , drop = FALSE]

  if (!nrow(cw)) {
    message(sprintf(
      "[NLI %s] claim_id=%s (km=%s/bm=%s): no premises found - nothing to score",
      assessment_id, this_claim_id, claim_unit$km, claim_unit$bm
    ))
    return(record("no_premises"))
  }

  candidate_labels <- as.character(nli_cfg_get(
    cfg, "candidate_labels", c("supports", "refutes", "is not relevant to")
  ))
  lab_supports <- candidate_labels[[1L]]
  lab_refutes  <- candidate_labels[[2L]]
  lab_nei      <- candidate_labels[[3L]]

  template_fmt        <- nli_cfg_get(cfg, "hypothesis_template",
                                     "This paper {} the following claim: %s")
  batch_size          <- as.integer(nli_cfg_get(cfg, "batch_size", 32L))
  http_chunk          <- as.integer(nli_cfg_get(cfg, "http_chunk", 256L))
  multi_label         <- isTRUE(nli_cfg_get(cfg, "multi_label", FALSE))
  # passes: 3 (default) = zero-shot, one forward pass per reformulated
  # candidate label, cross-normalized server-side (the only scheme this
  # project used before fine-tuning entered the picture). passes: 1 = a
  # directly fine-tuned classifier -- one forward pass on (premise, raw
  # claim text), server reads its native N-way softmax directly. Either way
  # the response is keyed by the same candidate_labels strings, so nothing
  # below this point (pick()/p_supports/p_refutes/p_nei/output schema) needs
  # to know which mode produced it.
  passes              <- as.integer(nli_cfg_get(cfg, "passes", 3L))
  uncertain_threshold <- as.numeric(nli_cfg_get(cfg, "uncertain_threshold", 0.60))
  max_length          <- nli_cfg_get(cfg, "max_length", NULL)
  if (!is.null(max_length)) max_length <- as.integer(max_length)

  auth_token <- NULL
  token_entry <- cfg[["auth_token_keyring"]]
  if (!is.null(token_entry) && is.character(token_entry) && nzchar(token_entry)) {
    auth_token <- keyring::key_get(token_entry)
  }

  hosts <- nli_hosts(cfg)

  if (passes == 1L) {
    # Direct mode: the raw claim text is sent to the server as a literal
    # hypothesis (server.py applies no .format() to it), so it must NOT be
    # brace-escaped the way the zero-shot template path needs (that escaping
    # exists only to protect literal "{5.4.1}"-style braces in the claim
    # from Python's per-label .format() call, which doesn't happen here).
    hyp_tmpl   <- NULL
    hypothesis <- claim_unit$claim
  } else {
    claim_safe <- gsub("\\{", "{{", gsub("\\}", "}}", claim_unit$claim))
    hyp_tmpl   <- sprintf(template_fmt, claim_safe)
    hypothesis <- NULL
  }

  # Acquire whichever host is free first (non-blocking try-each-host loop).
  # Scan the hosts in a RANDOM order each attempt rather than always starting
  # at host_01: a fixed scan order biases work toward low indices and can
  # starve the "last in line" host of all traffic — which then trips its
  # RunPod idle watchdog (IDLE_MIN) and stops the pod. Shuffling per attempt
  # keeps every host's traffic fresh (watchdog reset) and spreads load evenly
  # even when fewer crew workers than hosts are momentarily active.
  dir.create(lock_dir, recursive = TRUE, showWarnings = FALSE)
  lock <- NULL
  host_idx <- NULL
  while (is.null(lock)) {
    for (h in sample(seq_along(hosts))) {
      lock_file <- file.path(lock_dir, sprintf("host_%02d.lock", h))
      lock <- filelock::lock(lock_file, timeout = 0)
      if (!is.null(lock)) {
        host_idx <- h
        break
      }
    }
    if (is.null(lock)) Sys.sleep(0.5)
  }
  on.exit(filelock::unlock(lock), add = TRUE)

  cfg_h <- cfg
  cfg_h$host <- hosts[[host_idx]]
  base_url <- nli_classify_url(cfg_h)

  premises <- cw$premise
  chunks <- split(
    seq_along(premises),
    ceiling(seq_along(premises) / max(1L, http_chunk))
  )
  n_chunks    <- length(chunks)
  scores_list <- vector("list", length(premises))

  for (chunk_i in seq_along(chunks)) {
    idx <- chunks[[chunk_i]]
    message(sprintf(
      "[NLI %s host=%d/%d] km=%s / bm=%s / claim_id=%s: chunk %d/%d (%d works)",
      assessment_id, host_idx, length(hosts), claim_unit$km, claim_unit$bm,
      claim_unit$claim_id, chunk_i, n_chunks, length(idx)
    ))
    res <- tryCatch(
      nli_classify_request(
        base_url            = base_url,
        sequences           = premises[idx],
        candidate_labels    = candidate_labels,
        hypothesis_template = hyp_tmpl,
        hypothesis          = hypothesis,
        multi_label         = multi_label,
        batch_size          = batch_size,
        passes              = passes,
        max_length          = max_length,
        auth_token          = auth_token
      ),
      error = function(e) {
        stop(sprintf(
          "[NLI %s host=%d/%d] claim_id=%s chunk %d/%d FAILED against %s: %s",
          assessment_id, host_idx, length(hosts), claim_unit$claim_id,
          chunk_i, n_chunks, base_url, conditionMessage(e)
        ))
      }
    )
    if (length(res) != length(idx)) {
      stop(sprintf(
        "NLI server returned %d results for %d sequences (km=%s/bm=%s/claim_id=%s)",
        length(res), length(idx), claim_unit$km, claim_unit$bm, claim_unit$claim_id
      ))
    }
    scores_list[idx] <- res
  }

  pick <- function(sc, lab) {
    v <- sc[[lab]]
    if (is.null(v) || is.na(v)) NA_real_ else as.numeric(v)
  }
  p_supports <- vapply(scores_list, pick, numeric(1), lab_supports)
  p_refutes  <- vapply(scores_list, pick, numeric(1), lab_refutes)
  p_nei      <- vapply(scores_list, pick, numeric(1), lab_nei)

  probs  <- cbind(p_supports, p_refutes, p_nei)
  label_levels <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")
  argmax <- apply(probs, 1L, function(r) {
    if (all(is.na(r))) NA_integer_ else which.max(r)
  })
  label      <- ifelse(is.na(argmax), NA_character_, label_levels[argmax])
  confidence <- apply(probs, 1L, function(r) {
    if (all(is.na(r))) NA_real_ else max(r, na.rm = TRUE)
  })

  out <- dplyr::tibble(
    nli_config      = nli_active,
    nli_model       = nli_model,
    assessment      = assessment_id,
    km              = claim_unit$km,
    bm              = claim_unit$bm,
    claim_id        = claim_unit$claim_id,
    sentence_number = claim_unit$sentence_number,
    sentence_source = claim_unit$sentence_source,
    claim           = claim_unit$claim,
    work_id         = cw$work_id,
    label           = label,
    p_supports      = p_supports,
    p_refutes       = p_refutes,
    p_nei           = p_nei,
    confidence      = confidence,
    uncertain       = !is.na(confidence) & confidence < uncertain_threshold
  )

  # The scratch file must carry this claim's COMPLETE row set, not just the
  # rows scored above: consolidate_nli_scores() supersedes every existing row
  # whose claim_id appears in scratch
  #   old <- old[!(old$claim_id %in% unique(new$claim_id)), ]
  # so writing only the delta would DELETE the previously-scored rows it was
  # meant to extend. Carrying them forward here keeps that merge rule -- and
  # its orphan-pruning guards -- untouched.
  #
  # Cached rows keep their own nli_model: they really were scored by it, and
  # the guard above has already established it matches the current one (any
  # mismatch discarded the cache and forced a full rescore instead).
  final <- if (is.null(cached)) {
    out
  } else {
    dplyr::bind_rows(cached, out) |> dplyr::select(dplyr::all_of(names(out)))
  }

  # Scratch write only — consolidate_nli_scores() merges this into the (km,
  # bm) group's single parquet and deletes the scratch file. nli_config /
  # assessment / km / bm stay in the frame here purely so a stray scratch
  # file is self-describing if a run dies mid-way; consolidation drops them
  # again, since they live in the consolidated file's own Hive path.
  dir.create(scratch_dir, recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(scratch_file, ".tmp")
  arrow::write_parquet(final, tmp)
  file.rename(tmp, scratch_file)

  record("scored", nrow(final), nrow(out))
}
