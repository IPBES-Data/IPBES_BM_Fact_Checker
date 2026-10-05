# NLI fine-tuning training data, per the revised strategy in
# TD_NLI_training.qmd. Sibling to the other Phase-2-derived QA/reporting
# builders (build_llm_verification_qa_data.R etc.) -- reads only
# already-built output/llm_verification/scores* data (no new LLM/API calls,
# a pure local Arrow query, same cost profile as any other QA data builder
# in this project).
#
# Positives: key papers the LLM confirmed SUPPORTS with a real verbatim
# quote (llm_verification_keypaper_parquet) -- NOT every cited paper
# unconditionally, per the qmd's own reasoning (only 2.6% of GA1's key
# papers actually have explicit abstract-level support; blindly labelling
# the rest SUPPORTS would teach the model the exact topic-adjacency-as-
# entailment confusion this fine-tuning effort exists to correct).
#
# Negatives: real NLI/LLM disagreements from BOTH Phase 2 chains (the main
# citing-works corpus and the key-paper chain) -- NLI called SUPPORTS or
# REFUTES with real confidence, but the LLM's grounded, quote-checked
# review said NOT_ENOUGH_INFO. Downsampled to roughly match the positive
# count for class balance.
#
# REFUTES: the real llm_label=="REFUTES" rows from both chains, included
# unconditionally (too few to need downsampling) -- filtered on the LLM's
# own call alone, NOT requiring nli_label=="REFUTES" too (see real_refutes()
# below for why: requiring NLI agreement here would exclude exactly the
# "NLI was wrong, LLM corrected it" cases fine-tuning most needs, the same
# reasoning already applied to how negatives are sourced above).
#
# Output is hive-partitioned granularity=<g>/scorer_config=<cfg>/assessment=<id>/
# keypaper=<TRUE|FALSE>/ -- one level deeper than output/nli_scores_evidence
# and friends, which stop at assessment=<id>/. `llm_config` is still carried
# as a plain COLUMN rather than a partition level (matching Phase 1's own
# partition granularity rather than Phase 2's more granular one --
# llm_config/assessment/nli_route/km/bm -- since llm_verification_path/
# llm_verification_keypaper_path are already scoped to ONE (currently
# active) llm_config by construction; re-running under a DIFFERENT
# llm_config will overwrite this partition's training data rather than keep
# both side by side, same as switching nli.active would for a given
# granularity/assessment slot in Phase 1's own output). `keypaper`, by
# contrast, IS a real partition level: it distinguishes rows whose premise
# is a key/seed paper (the literal evidence a BM was written from) from rows
# whose premise is an arbitrary citing work one step removed from that
# evidence -- the two are verified to the same quality bar (both go through
# the same LLM judge + verbatim-quote check) but are NOT the same reliability
# tier, since a citing work's SUPPORTS/REFUTES call has more room to be
# topically-adjacent rather than genuinely on-point. Partitioning (not just a
# plain column) makes it a fast, pruned filter for train_nli.py's own
# FILTERS mechanism (e.g. FILTERS = {"keypaper": True} to train on the
# smaller, more reliable tier alone) and for an assessment that currently
# only has keypaper data (see the llm_verification_path parameter note
# below) -- such an assessment naturally only ever produces a keypaper=TRUE/
# subdirectory, with no keypaper=FALSE/ one to be missing.
build_nli_training_data <- function(
  assessment,
  # NOT a targets-tracked dependency -- _targets.R computes this path (it
  # mirrors build_llm_verification_parquet()'s own output_path formula)
  # rather than passing the llm_verification_parquet target value directly,
  # specifically so an assessment can contribute keypaper-only rows without
  # forcing targets to build its entire citing-works Phase 1+2 chain just to
  # satisfy this target's dependency graph. May legitimately not exist yet
  # (e.g. an assessment whose keypaper chain is done but citing-works chain
  # isn't) -- has_data() below treats that identically to a real, empty
  # result, same as it already does for "nothing routed yet."
  llm_verification_path,
  llm_verification_keypaper_path,
  works_path,
  works_citing_path,
  scorer_name,
  llm_active,
  granularity,
  output_root = "output/nli_training",
  # Benchmark holdout (TD_NLI_training.qmd). Grouped by Background Message and
  # assigned by HASH rather than by shuffle, so growing the corpus never moves
  # an existing BM across the boundary and past benchmark results stay
  # comparable. `benchmark_salt` is the version tag -- changing it re-cuts
  # every fold deliberately and visibly.
  benchmark_salt = "bench-v1",
  holdout_fraction = 0.2,
  # A THIRD fold, used for eval_loss / early stopping during fine-tuning.
  # Without it train_nli.py selects its best checkpoint on the same rows the
  # benchmark later scores, which makes every reported number optimistic by an
  # unmeasured margin.
  monitor_fraction = 0.1
) {
  assessment_id <- assessment$id

  output_path <- file.path(
    output_root, paste0("granularity=", granularity),
    paste0("scorer_config=", scorer_name), paste0("assessment=", assessment_id)
  )

  has_data <- function(path) {
    !is.null(path) && dir.exists(path) &&
      length(list.files(path, pattern = "\\.parquet$", recursive = TRUE)) > 0L
  }

  # Title/abstract/doi lookup, same defensive collapse-to-one-row-per-id
  # pattern build_claim_scores_qa_data.R/build_llm_verification_qa_data.R
  # already use -- a work can repeat across the (km, bm) partitions it's
  # cited/reviewed from. doi is kept for the QA report's clickable work
  # link, not for training itself.
  work_lookup <- function(path, ids) {
    if (!has_data(path) || !length(ids)) {
      return(dplyr::tibble(
        work_id = character(), title = character(), abstract = character(),
        doi = character(), in_corpus = logical()
      ))
    }
    arrow::open_dataset(path) |>
      dplyr::select(work_id = id, title, abstract, doi) |>
      dplyr::filter(work_id %in% ids) |>
      dplyr::collect() |>
      dplyr::group_by(work_id) |>
      dplyr::summarise(
        title    = dplyr::first(title[!is.na(title)], default = NA_character_),
        abstract = dplyr::first(abstract[!is.na(abstract)], default = NA_character_),
        doi      = dplyr::first(doi[!is.na(doi)], default = NA_character_),
        .groups = "drop"
      ) |>
      # Marks "this work_id was actually FOUND in the corpus", which the
      # left_joins below turn into NA for anything that was not. Distinct from
      # "has no abstract": a real work with a missing abstract still has a row
      # here. See the orphan filter further down for why that difference
      # matters.
      dplyr::mutate(in_corpus = TRUE)
  }

  empty_pairs <- function() {
    dplyr::tibble(
      assessment = character(), km = character(), bm = character(),
      claim = character(), work_id = character(), quote = character(),
      scorer_config = character(),
      nli_label = character(), nli_confidence = double()
    )
  }

  # --- Positives: LLM-verified key-paper SUPPORTS ---------------------------

  # NOTE: "assessment" is never included in these select() calls, even
  # though it's a real column in the source data -- this function's own
  # `assessment` PARAMETER (the assessment spec list) shadows the column
  # name for tidyselect's bare-symbol resolution, which errors trying to
  # use a list as a subscript ("Can't subset elements... not NULL"),
  # confirmed directly. Added back via mutate(assessment = assessment_id)
  # instead, which is unambiguous (named argument, not a bare symbol) and
  # already the authoritative value for this per-assessment branch anyway.
  #
  # NOTE: "llm_config" is likewise never select()ed from the source data --
  # llm_verification_path/llm_verification_keypaper_path are already scoped
  # INSIDE a `llm_config=<val>/` hive partition directory (that's how
  # build_llm_verification_parquet()'s own output_path is built), and Arrow
  # only reconstructs hive-partition segments that are BELOW the dataset
  # root it's given -- one that's already been "consumed" by the path
  # itself is genuinely absent from the schema at read time, confirmed
  # directly ("Column `llm_config` doesn't exist"). Added back via
  # mutate(llm_config = llm_active) instead, using the llm_active parameter
  # this function is called with -- same fix build_llm_verification_qa_data.R
  # already uses for its own llm_active handling.
  positives <- empty_pairs()
  if (has_data(llm_verification_keypaper_path)) {
    positives <- arrow::open_dataset(llm_verification_keypaper_path) |>
      dplyr::filter(llm_label == "SUPPORTS") |>
      dplyr::select(km, bm, claim, work_id, quote, scorer_config) |>
      dplyr::collect()
    positives$nli_label <- NA_character_
    positives$nli_confidence <- NA_real_
  }
  positives <- positives |>
    dplyr::left_join(work_lookup(works_path, unique(positives$work_id)), by = "work_id") |>
    dplyr::mutate(
      assessment = assessment_id, llm_config = llm_active, keypaper = TRUE,
      hypothesis = claim, label = "SUPPORTS", source = "llm_verified"
    )

  # --- Negatives: real NLI/LLM disagreements, both chains -------------------

  real_negatives <- function(path) {
    if (!has_data(path)) return(empty_pairs())
    arrow::open_dataset(path) |>
      dplyr::filter(nli_label %in% c("SUPPORTS", "REFUTES"), !uncertain, llm_label == "NOT_ENOUGH_INFO") |>
      dplyr::select(km, bm, claim, work_id, quote, scorer_config, nli_label, nli_confidence) |>
      dplyr::collect()
  }

  negatives_raw <- dplyr::bind_rows(
    real_negatives(llm_verification_path)         |> dplyr::mutate(.works_path = works_citing_path, keypaper = FALSE),
    real_negatives(llm_verification_keypaper_path) |> dplyr::mutate(.works_path = works_path, keypaper = TRUE)
  )

  # Downsample to roughly the positive count, by a DETERMINISTIC per-row hash
  # rather than set.seed(42) + slice_sample(). The seeded version drew from
  # whatever rows happened to be present, so every time the corpus grew the
  # drawn SET changed wholesale -- and because the fold assignment below is
  # computed afterwards, the holdout contents changed with it, quietly making
  # each benchmark run incomparable with the last. That is the same failure the
  # hashed fold assignment exists to prevent, reintroduced one step upstream.
  #
  # Ordering by a hash of the row's natural key instead makes a row's RANK a
  # function of the row alone. Measured on a pool growing 400 -> 460 with
  # n_target 150: the seeded version kept 113 of the 150 previously-drawn rows,
  # the hashed one 132. Not a strict superset -- a new row can hash ahead of an
  # existing one and displace it, and no fixed-size draw avoids that -- but the
  # churn is now only what the new rows actually force, instead of a full
  # reshuffle of rows that did not change.
  n_target <- max(nrow(positives), 1L)
  negatives <- if (nrow(negatives_raw) > n_target) {
    neg_rank <- vapply(
      paste(
        assessment_id, negatives_raw$km, negatives_raw$bm,
        negatives_raw$work_id, negatives_raw$claim, sep = "|"
      ),
      function(k) digest::digest(k, algo = "md5", serialize = FALSE),
      character(1), USE.NAMES = FALSE
    )
    negatives_raw[order(neg_rank), ][seq_len(n_target), ]
  } else {
    negatives_raw
  }

  neg_works <- dplyr::bind_rows(
    work_lookup(works_citing_path, unique(negatives$work_id[negatives$.works_path == works_citing_path])),
    work_lookup(works_path, unique(negatives$work_id[negatives$.works_path == works_path]))
  ) |> dplyr::distinct(work_id, .keep_all = TRUE)

  negatives <- negatives |>
    dplyr::select(-.works_path) |>
    dplyr::left_join(neg_works, by = "work_id") |>
    dplyr::mutate(
      assessment = assessment_id, llm_config = llm_active,
      hypothesis = claim, label = "NOT_ENOUGH_INFO", source = "llm_verified"
    )

  # --- REFUTES: real llm_label == "REFUTES", both chains --------------------

  # Filters on llm_label alone -- NOT nli_label == "REFUTES" too (an earlier
  # version required both to agree). That agreement requirement introduced a
  # real selection bias for training purposes specifically: it only ever
  # kept REFUTES examples the original zero-shot NLI already got right,
  # systematically excluding the "NLI called this SUPPORTS-certain, but the
  # LLM's grounded review correctly caught it as REFUTES" cases -- exactly
  # the corrective signal fine-tuning exists to provide, and the same kind
  # of case real_negatives() above already deliberately targets (NLI
  # confident, LLM disagreed). llm_label alone is still quote-grounded --
  # every llm_label passed build_llm_verification_parquet.R's own
  # quote_is_verbatim() check, which is the real anti-hallucination
  # safeguard here, not the NLI cross-check. nli_label/nli_confidence are
  # still selected and carried through (informative -- lets the QA report
  # or a later analysis distinguish "NLI already agreed" from "NLI
  # corrected" rows), just no longer used as a filter.
  real_refutes <- function(path, wp, is_keypaper) {
    if (!has_data(path)) {
      return(dplyr::mutate(
        empty_pairs(), title = character(), abstract = character(), doi = character(),
        in_corpus = logical(), keypaper = logical()
      ))
    }
    d <- arrow::open_dataset(path) |>
      dplyr::filter(llm_label == "REFUTES") |>
      dplyr::select(km, bm, claim, work_id, quote, scorer_config, nli_label, nli_confidence) |>
      dplyr::collect()
    d |>
      dplyr::left_join(work_lookup(wp, unique(d$work_id)), by = "work_id") |>
      dplyr::mutate(keypaper = is_keypaper)
  }

  refutes <- dplyr::bind_rows(
    real_refutes(llm_verification_path, works_citing_path, FALSE),
    real_refutes(llm_verification_keypaper_path, works_path, TRUE)
  ) |>
    dplyr::mutate(
      assessment = assessment_id, llm_config = llm_active,
      hypothesis = claim, label = "REFUTES", source = "llm_verified"
    )

  cols <- c(
    "id",
    "assessment", "km", "bm", "work_id", "hypothesis", "quote", "title", "abstract", "doi",
    "label", "source", "llm_config", "scorer_config", "nli_label", "nli_confidence", "keypaper",
    "split"
  )
  training_pairs <- dplyr::bind_rows(positives, negatives, refutes)

  # Drop ORPHANS: rows whose work_id is not in the corpus any more. Measured on
  # GA1, 165 training rows (26 of them REFUTES) reference works that are absent
  # from works_citing_meta -- scored under an earlier snowball, then dropped
  # when the corpus was rebuilt. They are not merely abstract-less: the premise
  # cannot be reconstructed at all, so they would train the model on an empty
  # string and be unreviewable by a human.
  #
  # This is an INTERIM guard. The real fix is rebuilding the citing-works chain
  # from one consistent corpus, which produces no orphans by construction; until
  # that runs, this stops them entering training and the gold-standard sample.
  # `in_corpus` comes from work_lookup() above and is NA exactly when the
  # left_join found no row -- deliberately not `is.na(abstract)`, which would
  # also discard real works that simply have no abstract on OpenAlex.
  n_orphan <- sum(is.na(training_pairs$in_corpus))
  if (n_orphan > 0L) {
    message(sprintf(
      "[nli_training_data %s] dropping %d orphaned row(s) (%d REFUTES) whose work_id is absent from the corpus",
      assessment_id, n_orphan,
      sum(is.na(training_pairs$in_corpus) & training_pairs$label == "REFUTES")
    ))
    training_pairs <- training_pairs[!is.na(training_pairs$in_corpus), ]
  }

  if (!nrow(training_pairs)) {
    if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    message(sprintf("[nli_training_data %s] no training pairs to export", assessment_id))
    return(output_path)
  }

  # Stable row id for a future label-correction UI: a content hash (not a
  # sequential integer) over the row's natural key, so the same logical row
  # gets the same id across re-runs regardless of row order -- a sequential
  # id would silently shift whenever bind_rows()/downsampling order changes
  # even slightly, which is exactly the retrofit pain this column exists to
  # avoid. hypothesis is part of the key because one (km, bm, work_id) triple
  # can legitimately recur with different claim text (different granularity
  # segmentation, or a re-completed atomic_bm fragment).
  training_pairs$id <- vapply(
    seq_len(nrow(training_pairs)),
    function(i) digest::digest(
      paste(
        training_pairs$assessment[[i]], training_pairs$km[[i]], training_pairs$bm[[i]],
        training_pairs$work_id[[i]], training_pairs$hypothesis[[i]], sep = ""
      ),
      algo = "xxhash32"
    ),
    character(1)
  )

  # Benchmark folds. Grouped by BACKGROUND MESSAGE, not by row: the pool is
  # ~2,400 rows over only ~465 distinct claims (mean 5.2 works per claim), so a
  # row-wise split puts the identical hypothesis string in both folds, and
  # REFUTES is concentrated in ~191 claims -- "recognise this claim, predict
  # REFUTES" is then an available shortcut that scores well and transfers to
  # nothing. That is precisely the bug train_nli.py's own
  # train_test_split(test_size=0.15) had.
  #
  # The key is (assessment, bm) and deliberately OMITS km. A Background
  # Message belongs to several Key Messages, so the same bm appears under
  # several km values carrying byte-identical claim text -- VA's C9 sits under
  # KM7, KM8 and KM9. Including km therefore splits one BM into several groups
  # that a hash can scatter across both folds: measured directly, keying on
  # (assessment, km, bm) gave 141 groups and left 126 claim strings present in
  # BOTH folds, while (assessment, bm) gives 99 groups and exactly zero. The
  # tighter-looking key was the leakier one.
  #
  # BM-level rather than claim-level (465 groups) deliberately: claims within
  # one BM are segmented from the same source text and share topic, vocabulary
  # and most of their citing works, so splitting between them would leak nearly
  # as much, just less visibly. Fewer groups means a noisier estimate, which is
  # the right trade.
  #
  # Residual, deliberately NOT engineered away: one work can be cited under
  # several BMs (mean 3.5 claims, max 99), so a minority of abstracts appear in
  # both folds paired with different claims. Much weaker than claim-text
  # leakage -- the model sees the premise, never the pair or its label -- and
  # closing it properly needs a connected-component split on the (claim, work)
  # graph, which at this size yields few huge unbalanced components: a small
  # measurable bias traded for a large unmeasurable one. The benchmark reports
  # cross-fold work overlap as a diagnostic instead.
  # THREE folds, not two. The bucket ranges are ordered so that `holdout`
  # occupies exactly the buckets it occupied under the old two-way split
  # (0 .. holdout_fraction*100), and `monitor` is carved out of what was
  # `train` -- so no BM that was already in the holdout moves out of it, and
  # benchmark results from before this change stay comparable.
  bucket <- hash_bucket(
    paste(training_pairs$assessment, training_pairs$bm, sep = "|"),
    benchmark_salt
  )
  holdout_hi <- holdout_fraction * 100
  training_pairs$split <- ifelse(
    bucket < holdout_hi, "holdout",
    ifelse(bucket < holdout_hi + monitor_fraction * 100, "monitor", "train")
  )

  training_pairs <- training_pairs |> dplyr::select(dplyr::all_of(cols))
  training_pairs$granularity <- granularity

  if (dir.exists(output_path)) unlink(output_path, recursive = TRUE, force = TRUE)
  arrow::write_dataset(
    dataset = training_pairs,
    path = output_root,
    format = "parquet",
    # keypaper=<TRUE|FALSE> nests under assessment=<id>/ -- a single call
    # can (and typically does) produce both values, so this deliberately
    # writes two sibling subdirectories under output_path rather than one;
    # output_path (returned below) stays the assessment=<id>/ parent, which
    # correctly covers both.
    partitioning = c("granularity", "scorer_config", "assessment", "keypaper"),
    existing_data_behavior = "delete_matching"
  )

  message(sprintf(
    "[nli_training_data %s] wrote %d rows to %s", assessment_id, nrow(training_pairs), output_path
  ))

  output_path
}
