# Fact-checking pipeline -- citing works -> NLI -> LLM verification.
#
# One of four projects (see TODO_PIPELINE_SPLIT.md and _targets.yaml):
#
#   _targets.R             collection: LOD -> refs -> zotero -> works ->
#                          snowball -> works_citing. Keeps the ORIGINAL
#                          _targets/ store, so nothing re-downloads.
#   _targets_factcheck.R   this file
#   _targets_training.R    key papers -> NLI -> LLM -> training set -> fine-tune
#   _targets_reporting.R   renders everything, computes nothing that costs money
#
# WHAT THIS PROJECT IS FOR: the citing-works corpus -- every paper the snowball
# found citing a Background Message's key papers, scored against that BM's own
# claims by the zero-shot NLI pool (Phase 1), with the REFUTES/SUPPORTS-certain
# subset routed to a grounded LLM review (Phase 2). This is the expensive arm:
# millions of pairs, real GPU hours, real OpenRouter spend. Its sibling
# _targets_training.R scores the far smaller key-paper set instead.
#
# CREDENTIALS: API_openrouter only. Nothing here fetches from OpenAlex, so the
# collection project's key and its rate-limit preflight are both absent.
#
# THE ONE-TIME MIGRATION COST: a fresh store makes nli_ready_evidence_parquet
# outdated by definition, and 0bb6bb0 removed its early return, so the first
# run rebuilds the 163 GB atomic_bm cross-join. Hours of local compute, no
# money. The output already on disk is what every current score was computed
# against and is not endangered -- the rebuild reproduces it from the same
# inputs. Start it from a quiet point.
library(targets)

Sys.setenv(
  API_openrouter = keyring::key_get("API_openrouter")
)

tar_option_set(
  packages = c(
    "yaml", "dplyr", "arrow", "stringr", "xml2", "httr2",
    "jsonlite", "digest", "ellmer", "filelock", "crew", "keyring"
  ),
  # Sized to the active NLI pool's host count: score_one_claim() dispatches
  # claims across hosts by taking a per-host file lock, so local concurrency
  # has to match the host count or hosts sit idle. Read straight from
  # config.yaml at pipeline-definition time -- worker-pool sizing, not part of
  # the DAG's correctness.
  #
  # The lock directory (output/nli_scores/.locks/) is SHARED with the training
  # project. Deliberate, and not a collision: if both run at once they contend
  # for the same hosts, which is the behaviour wanted -- one pool, one queue.
  # It is, with the two append-only LLM caches, the cross-project state that no
  # DAG describes; see TODO_PIPELINE_SPLIT.md's "Cross-project contracts".
  controller = crew::crew_controller_local(
    workers = tryCatch({
      nli_cfg <- yaml::read_yaml("input/config.yaml")[["nli"]]
      n <- length(unlist(nli_cfg[["configs"]][[nli_cfg[["active"]]]][["host"]]))
      max(1L, n)
    }, error = function(e) 1L)
  )
)

list.files("./R", full.names = TRUE) |> lapply(source)

# ---------------------------------------------------------------------------
# Cross-project inputs: what the collection project (_targets.R) writes.
# Declared as format = "file" targets keeping the producing project's NAMES, so
# the scoring targets below move across verbatim and a genuine upstream change
# -- a refetched works_parquet, a new snowball -- still invalidates this chain
# through content hashing.
# ---------------------------------------------------------------------------

list(
  # DAG diagram for THIS project. build_pipeline_mmd() renders whatever DAG it
  # is run inside, so each project generates its own picture.
  tar_target(r_files, list.files("R", full.names = TRUE), format = "file"),
  tar_target(
    pipeline_mmd,
    build_pipeline_mmd(r_files, "input/mmd/pipeline_factcheck.mmd"),
    format = "file"
  ),
  tar_target(
    diagram_pipeline_factcheck,
    render_mmd(pipeline_mmd),
    format = "file"
  ),

  # ---- configuration (re-derived here; every project reads the same file) ---
  tar_target(config_file, "input/config.yaml", format = "file"),
  tar_target(nli_active, yaml::read_yaml(config_file)[["nli"]][["active"]]),
  tar_target(workers, yaml::read_yaml(config_file)[["workers"]]),
  tar_target(nli_config, {
    nli <- yaml::read_yaml(config_file)[["nli"]]
    nli[["configs"]][[nli[["active"]]]]
  }),
  tar_target(
    granularity,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["granularity"]] %||% "naive_bm"
  ),
  tar_target(
    max_length,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["max_length"]]
  ),
  tar_target(claim_completion_model, {
    cc <- yaml::read_yaml(config_file)[["nli"]][["claim_completion"]]
    cc[["configs"]][[cc[["active"]]]][["model"]]
  }),
  tar_target(
    assessments_list,
    lapply(yaml::read_yaml(config_file)[["assessments"]], function(a) {
      a[setdiff(names(a), "full_text")]
    })
  ),
  tar_target(
    assessment,
    {
      x <- assessments_list
      names(x) <- vapply(x, `[[`, character(1), "id")
      Map(function(a, i) c(a, list(index = i)), x, seq_along(x))
    },
    iteration = "list"
  ),
  tar_target(
    llm_verification_active,
    yaml::read_yaml(config_file)[["llm_verification"]][["active"]]
  ),
  tar_target(llm_verification_config, {
    lv <- yaml::read_yaml(config_file)[["llm_verification"]]
    lv[["configs"]][[lv[["active"]]]]
  }),
  tar_target(
    llm_verification_system_prompt_file,
    "input/prompts/llm_verification_system.md",
    format = "file"
  ),
  tar_target(
    llm_verification_user_prompt_file,
    "input/prompts/llm_verification_user.md",
    format = "file"
  ),

  # ---- inputs from the collection project (_targets.R) ----------------------
  tar_target(
    refs_parquet,
    file.path("output/refs", paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  tar_target(
    key_messages_parquet,
    file.path("output/key_messages", paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  tar_target(
    works_parquet,
    file.path("output/works", paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  # Three paths per branch (nodes / edges / keypaper), exactly as the
  # collection project's own target returns them.
  tar_target(
    snowball_parquet,
    c(
      file.path("output/snowball/nodes", paste0("assessment=", assessment$id)),
      file.path("output/snowball/edges", paste0("assessment=", assessment$id)),
      file.path("output/snowball/keypaper", paste0("assessment=", assessment$id))
    ),
    pattern = map(assessment), format = "file"
  ),
  # Two paths per branch (slim km/bm mapping, then deduplicated metadata), so
  # works_citing_map_paths()/works_citing_meta_paths() keep working unchanged.
  tar_target(
    works_citing_parquet,
    c(
      file.path("output/works_citing", paste0("assessment=", assessment$id)),
      file.path("output/works_citing_meta", paste0("assessment=", assessment$id))
    ),
    pattern = map(assessment), format = "file"
  ),

  # Target 2g' (NLI-ready, SECOND approach): identical to nli_ready_parquet but
  # BM text is cut into EVIDENCE-DELIMITED claims (split at braces that end a
  # sentence, {5.4.1, 5.4.2}) rather than per sentence -- or, under a
  # granularity: complete_bm NLI config, not split at all (whole
  # bm_description/bm_label as one claim each). Same column schema either
  # way; output root is hive-partitioned by granularity=<value>/ so naive_bm
  # (the default, byte-identical path to before this partition was added --
  # existing data was migrated under granularity=naive_bm/ rather than
  # recomputed) and complete_bm never collide. See NEXT_STEPS.md.
  tar_target(
    nli_ready_evidence_parquet,
    build_nli_ready_evidence_parquet(
      assessment,
      key_messages_parquet,
      works_citing_parquet,
      workers,
      file.path("output/nli_ready_evidence", paste0("granularity=", granularity)),
      granularity,
      claim_completion_model
    ),
    pattern = map(assessment, key_messages_parquet, works_citing_parquet),
    format = "file",
    # Same reasoning as nli_ready_parquet just above: internally forks its
    # own `workers` mclapply processes over a full-text cross-join, so
    # running its GA1/IAS branches on separate crew workers too stacks two
    # layers of parallelism on the pipeline's biggest in-memory data.
    deployment = "main",
    garbage_collection = TRUE
  ),
  # Target 2h (NLI): NLI alignement scores — classify each citing work against
  # each BM sentence (SUPPORTS / REFUTES / NOT_ENOUGH_INFO) via a zero-shot NLI
  # model served on a pool of RunPod hosts. Consumes nli_ready_parquet (work ×
  # BM sentence cross-join with approx_tokens). Every work of every scored
  # claim IS scored — pairs longer than max_length are TRUNCATED by the server
  # (truncation="longest_first", so the abstract tail is trimmed and the short
  # hypothesis is preserved), not skipped. approx_tokens is used only for
  # ordering/counting, never to drop rows. See NEXT_STEPS.md for the optional
  # abstract-chunking enhancement (score long abstracts in windows instead of
  # truncating) if lossless handling of long abstracts is ever needed.
  #
  # Claim-level dynamic dispatch (crew + file locks), not per-host static LPT
  # assignment: each (km, bm, sentence_source, sentence_number) claim is its
  # own target branch, so a) targets' own progress reporting shows a failing
  # claim live, by name, the moment it happens (previously: an mclapply fork
  # dying produced zero visible output until every other fork also finished),
  # b) one bad claim no longer costs an entire host's remaining backlog
  # (previously ~1/6th of all remaining work per lost host), and c) host
  # assignment happens when a worker actually becomes free (via
  # score_one_claim()'s lock-per-host loop), not from an upfront size
  # estimate — genuine work-stealing instead of static LPT balancing.

  # Target 2h0: Pool health check, once per pipeline build. Fails loudly if
  # any host is unreachable, or hosts report different models.
  tar_target(
    nli_pool_health,
    check_nli_pool_health(nli_config, nli_active)
  ),

  # ── SECOND approach (evidence-segmented) scoring chain ────────────────────
  # Reuses build_nli_claim_units() / score_one_claim() unchanged — only the
  # source path (nli_ready_evidence_parquet) and the scoring output_root
  # (output/nli_scores_evidence) differ. Shares the same nli_pool_health and,
  # via score_one_claim()'s default lock_dir, the same per-host locks, so the
  # two approaches never hit one host concurrently if run together.
  tar_target(
    nli_claim_units_evidence,
    build_nli_claim_units(assessment, nli_ready_evidence_parquet, max_length),
    pattern = map(assessment, nli_ready_evidence_parquet),
    iteration = "list"
  ),
  tar_target(
    nli_claim_units_evidence_flat,
    unlist(nli_claim_units_evidence, recursive = FALSE),
    iteration = "list"
  ),
  # NOT format = "file": each branch returns a small record, not a path. The
  # scored rows go to a per-claim scratch file, and the branches all feed
  # nli_scores_evidence_consolidated below, which merges them into one
  # parquet per (km, bm) and deletes the scratch. Returning the consolidated
  # path here instead would have every branch of a (km, bm) return the SAME
  # file, whose hash changes as sibling branches write — permanent
  # invalidation churn. See R/score_one_claim.R's header.
  tar_target(
    nli_scores_by_claim_evidence,
    score_one_claim(
      nli_claim_units_evidence_flat,
      nli_config,
      nli_active,
      nli_pool_health,
      output_root = file.path("output/nli_scores_evidence", paste0("granularity=", granularity))
    ),
    pattern = map(nli_claim_units_evidence_flat),
    error = "continue"
  ),
  # Merge this run's scratch files into one parquet per (nli_config,
  # assessment, km, bm), and prune claims no longer present upstream. Depends
  # on the scoring branches AGGREGATED (no pattern =), so it runs once after
  # they all finish. Everything downstream reads this, not the scoring target,
  # so nothing can observe a half-merged tree.
  tar_target(
    nli_scores_evidence_consolidated,
    consolidate_nli_scores(
      nli_scores_by_claim_evidence,
      nli_claim_units_evidence_flat,
      output_root = file.path("output/nli_scores_evidence", paste0("granularity=", granularity)),
      nli_active = nli_active
    ),
    format = "file",
    deployment = "main"
  ),
  # Cleanup: score_one_claim()'s per-host dispatch locks (output/nli_scores/
  # .locks_temp/host_NN.lock) are real files on disk for as long as any
  # claim branch might still try to acquire one -- deleting one mid-run
  # (e.g. inside score_one_claim() itself, right after unlock()) would race
  # with another branch's in-flight filelock::lock() on the same path: POSIX
  # lets a third branch create a fresh file there and lock IT while the
  # second branch still holds a valid lock on the now-unlinked original,
  # breaking the one-claim-per-host guarantee these locks exist for. So
  # cleanup only happens here, in a target that depends on the WHOLE
  # nli_scores_by_claim_evidence pattern (referenced only to establish that
  # DAG dependency) -- targets doesn't run this until every branch has
  # actually returned (success or error = "continue" failure), so nothing
  # can still be waiting on a lock by the time it fires. Naturally
  # self-limiting too: if nli_scores_by_claim_evidence is fully up to date
  # (nothing left to score), this target is too, and cleanup is skipped
  # rather than re-deleting an already-empty directory every tar_make().
  tar_target(nli_host_locks_cleanup, {
    nli_scores_by_claim_evidence
    lock_dir <- "output/nli_scores/.locks_temp"
    n <- length(list.files(lock_dir, pattern = "\\.lock$"))
    unlink(lock_dir, recursive = TRUE, force = TRUE)
    sprintf("removed %d lock file(s) from %s", n, lock_dir)
  }),

  # Target 2h4a: Per-claim evidence scope feeding Phase 2's
  # `direct_evidence_match` tag (see R/build_llm_candidate_scope_parquet.R
  # and TD_NLI_LLM_two_phase.qmd; this fed a candidate-narrowing FILTER
  # before that was retired -- real measured reduction was only ~14% for
  # GA1 atomic_bm, not worth the lost review coverage). Chains
  # refs_parquet's `sm` (sub-chapter id) -> seed doi -> seed OpenAlex work
  # id -> citing work (via the existing snowball edges) to produce, per
  # evidence-segmented claim, the set of citing works actually tied to its
  # own sub-chapter rather than the whole BM's. Supported for
  # naive_bm/atomic_bm; a no-op ("no restriction", i.e. every row tags
  # FALSE) sentinel for complete_bm, whose whole-field claims carry no
  # per-sub-claim evidence tokens. Reads only already-existing, unmodified
  # targets (key_messages_parquet, refs_parquet, works_parquet,
  # snowball_parquet, nli_ready_evidence_parquet, claim_completion_model) —
  # adding it does not invalidate any of Phase 1's NLI chain or the
  # download/snowball steps upstream of it. Under granularity ==
  # "atomic_bm" it DOES make a real (normally cache-hit only) OpenRouter
  # call via claim_completion_model/complete_bm_fragments(), to recover the
  # same surviving-fragment order the real atomic_bm build produced (see
  # extract_claim_evidence_tokens_atomic()'s own header) — a real atomic_bm
  # nli_ready_evidence_parquet build is a precondition for this to be
  # cheap. Always computed regardless of which llm_verification config is
  # active -- every config now reads its output to tag, not to filter.
  tar_target(
    llm_candidate_scope_parquet,
    build_llm_candidate_scope_parquet(
      assessment,
      key_messages_parquet,
      refs_parquet,
      works_parquet,
      snowball_parquet,
      nli_ready_evidence_parquet,
      "output/llm_candidate_scope",
      granularity,
      claim_completion_model
    ),
    pattern = map(
      assessment, key_messages_parquet, refs_parquet, works_parquet,
      snowball_parquet, nli_ready_evidence_parquet
    ),
    format = "file"
  ),
  # Target 2h4b: Phase 2 — LLM verification of NLI-flagged pairs. Reviews
  # only what NLI itself flagged as needing a second opinion (every REFUTES
  # call, and every call NLI marked `uncertain`) — see
  # R/build_llm_verification_parquet.R and TD_NLI_LLM_two_phase.qmd. One
  # target call per assessment loops internally over its own candidates
  # (ellmer's own parallel_chat_structured concurrency is enough here — no
  # crew/file-lock dispatch needed, since OpenRouter is a shared endpoint,
  # not a fixed host pool to load-balance across like the NLI RunPod pool).
  # nli_scores_by_claim_evidence is passed only to establish the DAG
  # dependency on Phase 1 scoring, same convention as nli_overview_data.
  tar_target(
    llm_verification_parquet,
    build_llm_verification_parquet(
      assessment,
      nli_ready_evidence_parquet,
      nli_active,
      llm_verification_active,
      llm_verification_config,
      llm_verification_system_prompt_file,
      llm_verification_user_prompt_file,
      llm_candidate_scope_parquet,
      granularity,
      nli_scores_evidence_consolidated
    ),
    pattern = map(assessment, nli_ready_evidence_parquet, llm_candidate_scope_parquet),
    format = "file",
    # select_llm_verification_candidates() collect()s both the routed NLI
    # scores AND the full nli_ready_evidence premise table (title+abstract
    # per work x claim) per assessment before joining in R — multi-GB for a
    # single assessment. Running GA1's and IAS's branches on separate crew
    # workers holds both in memory at once; deployment = "main" processes
    # them one at a time. ellmer's own max_active concurrency (OpenRouter
    # calls within one assessment) is unaffected. Contributed to an
    # observed OOM alongside nli_overview_data/nli_ready_parquet running
    # concurrently.
    deployment = "main",
    garbage_collection = TRUE
  ),  NULL
)
