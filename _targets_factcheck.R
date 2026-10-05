# Fact-checking pipeline -- citing works -> NLI -> LLM verification.
#
# One of four projects (see TD_targets.qmd and _targets.yaml):
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
# THE ONE-TIME MIGRATION COST: a fresh store makes claim_work_pairs
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
  # DAG describes; see TD_targets.qmd's "Cross-project contracts".
  controller = crew::crew_controller_local(
    #
    # Resolved inline rather than via purpose_config(), which lives in R/ and is
    # sourced AFTER this block. It must handle both purpose-block shapes: the
    # flat one and the library+active: one fact_checking: now uses. It did not,
    # and the failure was silent -- `fact_checking$nli` became NULL, tryCatch
    # swallowed the subscript error and sized the pool at ONE worker, so every
    # pod past the first sat idle while being billed. Hence the warning on the
    # fallback path: one worker is a legitimate value and an indistinguishable
    # symptom, so it must not be reached quietly.
    workers = tryCatch({
      cfg <- yaml::read_yaml("input/config.yaml")
      fc <- cfg[["fact_checking"]]
      sel <- if (!is.null(fc[["configs"]])) fc[["configs"]][[fc[["active"]]]][["nli"]] else fc[["nli"]]
      if (is.null(sel)) stop("could not resolve fact_checking's nli config name")
      nc <- cfg[["nli"]][["configs"]][[sel]]
      # The jev backend has no hosts to size against. Its concurrency is
      # per-request inside score_one_claim_jev() (httr2, max_active), so crew
      # workers here only decide how many CLAIMS are in flight at once. Four is
      # a deliberate compromise: enough to keep the API busy across claims,
      # few enough that four claims' premise frames are not all in memory.
      if (identical(nc[["backend"]], "jev")) return(4L)
      n <- length(unlist(nc[["host"]]))
      if (n < 1L) stop(sprintf("nli.configs.%s.host is empty -- start the pool first", sel))
      n
    }, error = function(e) {
      warning(sprintf(
        "crew workers falling back to 1: %s. Every host past the first will sit idle.",
        conditionMessage(e)
      ), call. = FALSE)
      1L
    })
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
  # Hand-authored conceptual workflow for THIS project (one per targets
  # project; see input/mmd/workflow_main.mmd's own header for the set).
  tar_target(
    mmd_workflow_factcheck,
    "input/mmd/workflow_factcheck.mmd",
    format = "file"
  ),
  tar_target(
    diagram_workflow_factcheck,
    render_mmd(mmd_workflow_factcheck),
    format = "file"
  ),
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
  # Selections come from config.yaml's `fact_checking:` purpose block, not a
  # global `active:` -- see purpose_config() in R/branch_helpers.R for why.
  tar_target(purpose, purpose_config(yaml::read_yaml(config_file), "fact_checking")),
  tar_target(scorer_name, purpose$nli),
  # NULL = every KM, which is the pre-existing behaviour. Validated against the
  # assessment's real key messages inside build_claim_units(), not here:
  # KMs live in key_messages_parquet, so config cannot check them.
  tar_target(km_scope, purpose$km),
  tar_target(workers, yaml::read_yaml(config_file)[["workers"]]),
  tar_target(scorer_config, yaml::read_yaml(config_file)[["nli"]][["configs"]][[scorer_name]]),
  tar_target(
    granularity,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[scorer_name]][["granularity"]] %||% "naive_bm"
  ),
  tar_target(
    max_length,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[scorer_name]][["max_length"]]
  ),
  tar_target(claim_completion_model, purpose$claim_completion_model),
  # Scoped to fact_checking.assessments -- this is the expensive arm, so it is
  # deliberately narrower than training. purpose_assessments_list() preserves
  # the element shape assessments_list has always produced, so a purpose
  # listing every assessment yields a byte-identical value.
  tar_target(
    assessments_list,
    purpose_assessments_list(yaml::read_yaml(config_file), "fact_checking")
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
  tar_target(llm_verification_active, purpose$llm),
  tar_target(
    llm_verification_config,
    yaml::read_yaml(config_file)[["llm_verification"]][["configs"]][[llm_verification_active]]
  ),
  tar_target(relevance_config, yaml::read_yaml(config_file)[["relevance_screen"]]),
  # Tracked like the other prompts: editing the questions invalidates whatever
  # the jev backend scored, which is correct -- different questions, different
  # scores, and a tree scored under two question sets would be meaningless.
  tar_target(
    jev_questions_file,
    "input/prompts/jev_claim_questions.json",
    format = "file"
  ),
  tar_target(
    jev_relevance_question_file,
    "input/prompts/jev_relevance_question.json",
    format = "file"
  ),
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
    claim_work_pairs,
    build_claim_work_pairs(
      assessment,
      key_messages_parquet,
      works_citing_parquet,
      workers,
      file.path("output/claim_work_pairs", paste0("granularity=", granularity)),
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

  # The model name the scored rows are stamped with.
  #
  # This REPLACED `nli_pool_health` on 2026-10-05. That target existed because
  # the RunPod pool had to be checked before a run -- every host reachable, all
  # reporting the same model, matching expect_model -- and it returned the common
  # model name as a side effect, which is what downstream actually consumed.
  #
  # There is no pool to check with the jev backend, and no equivalent for an HTTP
  # API: OpenRouter is a shared endpoint, there is nothing to be half-up. So the
  # health check is no longer a pipeline stage, and what remains is the one thing
  # scoring needs: a name for the scorer_model column.
  #
  # check_nli_pool_health() is KEPT in R/ and is still worth running by hand
  # before a RunPod-backed run -- it catches an unreachable host, a pool serving
  # mixed models, and an expect_model mismatch, none of which this target does:
  #
  #   check_nli_pool_health(tar_read(scorer_config), tar_read(scorer_name))
  #
  # It is not wired in because the backend that needs it is on its way out, and a
  # target that silently does nothing for the active backend is worse than an
  # explicit call.
  tar_target(
    scorer_model,
    {
      m <- scorer_config$model
      if (is.null(m) || !nzchar(m)) {
        stop(sprintf("nli.configs.%s has no model:", scorer_name), call. = FALSE)
      }
      if (identical(scorer_config$backend, "jev") && !nzchar(Sys.getenv("API_openrouter"))) {
        stop(sprintf("nli.configs.%s uses backend jev but API_openrouter is not set", scorer_name),
             call. = FALSE)
      }
      m
    }
  ),

  # ── SECOND approach (evidence-segmented) scoring chain ────────────────────
  # Reuses build_claim_units() / score_one_claim() unchanged — only the
  # source path (claim_work_pairs) and the scoring output_root
  # (output/claim_scores) differ. Shares the same scorer_model and,
  # via score_one_claim()'s default lock_dir, the same per-host locks, so the
  # two approaches never hit one host concurrently if run together.
  tar_target(
    claim_units,
    build_claim_units(assessment, claim_work_pairs, max_length, km_scope),
    pattern = map(assessment, claim_work_pairs),
    iteration = "list"
  ),
  tar_target(
    claim_units_flat,
    unlist(claim_units, recursive = FALSE),
    iteration = "list"
  ),
  # NOT format = "file": each branch returns a small record, not a path. The
  # scored rows go to a per-claim scratch file, and the branches all feed
  # claim_scores_consolidated below, which merges them into one
  # parquet per (km, bm) and deletes the scratch. Returning the consolidated
  # path here instead would have every branch of a (km, bm) return the SAME
  # file, whose hash changes as sibling branches write — permanent
  # invalidation churn. See R/score_one_claim.R's header.
  tar_target(
    claim_scores_by_claim,
    # BACKEND DISPATCH. `backend: jev` on the active nli config scores with
    # Jev's decisions API instead of the RunPod pool -- same output schema, its
    # own scorer_config= tree, so it scores BESIDE the NLI on identical rows rather
    # than instead of it. score_one_claim() itself is untouched, deliberately:
    # it is the production path for every existing score and carries a bug
    # history worth not disturbing. See R/score_one_claim_jev.R.
    if (identical(scorer_config$backend, "jev")) {
      score_one_claim_jev(
        claim_units_flat, scorer_config, scorer_name, scorer_model,
        output_root = file.path("output/claim_scores", paste0("granularity=", granularity)),
        questions_file = jev_questions_file
      )
    } else {
      score_one_claim(
        claim_units_flat, scorer_config, scorer_name, scorer_model,
        output_root = file.path("output/claim_scores", paste0("granularity=", granularity))
      )
    },
    pattern = map(claim_units_flat),
    error = "continue"
  ),
  # Merge this run's scratch files into one parquet per (scorer_config,
  # assessment, km, bm), and prune claims no longer present upstream. Depends
  # on the scoring branches AGGREGATED (no pattern =), so it runs once after
  # they all finish. Everything downstream reads this, not the scoring target,
  # so nothing can observe a half-merged tree.
  tar_target(
    claim_scores_consolidated,
    consolidate_claim_scores(
      claim_scores_by_claim,
      claim_units_flat,
      output_root = file.path("output/claim_scores", paste0("granularity=", granularity)),
      scorer_name = scorer_name,
      # Scope the groups it visits. Without this it globs every
      # assessment=*/km=*/bm=* under the scorer_config= root and stops dead on any
      # group the current claim list no longer covers -- which is not a
      # hypothetical: assessment=IAS still holds 9 scored groups from before
      # the GA1 rescope. Out-of-scope groups are left untouched, not pruned.
      assessments = vapply(assessments_list, function(a) a$id, character(1)),
      km = km_scope
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
  # claim_scores_by_claim pattern (referenced only to establish that
  # DAG dependency) -- targets doesn't run this until every branch has
  # actually returned (success or error = "continue" failure), so nothing
  # can still be waiting on a lock by the time it fires. Naturally
  # self-limiting too: if claim_scores_by_claim is fully up to date
  # (nothing left to score), this target is too, and cleanup is skipped
  # rather than re-deleting an already-empty directory every tar_make().
  tar_target(scorer_host_locks_cleanup, {
    claim_scores_by_claim
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
  # snowball_parquet, claim_work_pairs, claim_completion_model) —
  # adding it does not invalidate any of Phase 1's NLI chain or the
  # download/snowball steps upstream of it. Under granularity ==
  # "atomic_bm" it DOES make a real (normally cache-hit only) OpenRouter
  # call via claim_completion_model/complete_bm_fragments(), to recover the
  # same surviving-fragment order the real atomic_bm build produced (see
  # extract_claim_evidence_tokens_atomic()'s own header) — a real atomic_bm
  # claim_work_pairs build is a precondition for this to be
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
      claim_work_pairs,
      "output/llm_candidate_scope",
      granularity,
      claim_completion_model
    ),
    pattern = map(
      assessment, key_messages_parquet, refs_parquet, works_parquet,
      snowball_parquet, claim_work_pairs
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
  # claim_scores_by_claim is passed only to establish the DAG
  # ---- relevance screen ----------------------------------------------------
  # Screens only the ROUTED subset -- what cfg$nli_labels/nli_certainty select,
  # currently 190,759 of GA1's 2.43M pairs. That is the cheap placement (~$3),
  # and it does NOT touch the 2.24M pairs Phase 2 has never seen: 1.23M
  # NOT_ENOUGH_INFO plus ~1.01M SUPPORTS/REFUTES-uncertain. Closing that recall
  # blind spot means screening more than the routed set (~$39 for everything
  # unreviewed), which is a separate, larger decision.
  #
  # Duplicated from _targets_training.R deliberately -- see the note there.
  tar_target(
    relevance_screen,
    build_llm_relevance_screen(
      assessment,
      pairs = select_llm_verification_candidates(
        file.path("output/claim_scores", paste0("granularity=", granularity),
                  paste0("scorer_config=", scorer_name), paste0("assessment=", assessment$id)),
        claim_work_pairs,
        nli_labels = llm_verification_config$nli_labels,
        nli_certainty = llm_verification_config$nli_certainty
      ),
      keypaper = FALSE,
      model = relevance_config$model,
      questions_file = jev_relevance_question_file,
      batch_size = relevance_config$batch_size
    ),
    pattern = map(assessment, claim_work_pairs),
    format = "file", deployment = "main"
  ),

  # dependency on Phase 1 scoring, same convention as nli_overview_data.
  tar_target(
    llm_verification_parquet,
    build_llm_verification_parquet(
      assessment,
      claim_work_pairs,
      scorer_name,
      llm_verification_active,
      llm_verification_config,
      llm_verification_system_prompt_file,
      llm_verification_user_prompt_file,
      llm_candidate_scope_parquet,
      granularity,
      claim_scores_consolidated,
      relevance_path = relevance_screen,
      relevance_threshold = relevance_config$threshold
    ),
    pattern = map(assessment, claim_work_pairs, llm_candidate_scope_parquet, relevance_screen),
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
  ),

  # ══ KEY-PAPER QA CHAIN ═══════════════════════════════════════════════════
  # Moved here from _targets_training.R on 2026-10-05, when the fine-tuning arm
  # was retired (design_notes.md points 3, 6, 7, 8). It never belonged to
  # training logically: it asks whether the papers IPBES itself cites as
  # evidence for a Background Message actually support it, which is a
  # fact-checking sanity check. It lived there because that is where the
  # training set's positive class came from.
  #
  # DELIBERATELY SEPARATE from the citing-works chain beside it: its own
  # premise root (output/claim_work_pairs_keypaper/), its own scores root
  # (output/claim_scores_keypaper/), its own Phase 2 output
  # (scores_keypaper/) and its own relevance partition (keypaper=true). The two
  # score DIFFERENT pairs and must be runnable, re-runnable and deletable
  # independently.
  #
  # ONE BEHAVIOUR CHANGE in the move: it now follows fact_checking's nli config
  # rather than training's. The reason it was pinned to zero-shot -- "avoid
  # training on labels the model itself shaped" -- was about protecting the
  # training set, which no longer exists. A QA check on the fact-checking
  # pipeline should use the model that pipeline actually runs.
  # Scores the actual seed/reference papers IPBES cites as evidence for a BM
  # (relation == "keypaper" in the snowball nodes) against their OWN BM's claim
  # text. Mirrors the citing-works chain exactly -- same
  # build_claim_units()/score_one_claim() reused unchanged -- with only the
  # premise source and the output roots differing, so it can never collide with
  # or invalidate that chain.
  tar_target(
    claim_work_pairs_keypaper,
    build_claim_work_pairs_keypaper(
      assessment,
      key_messages_parquet,
      works_parquet,
      snowball_parquet,
      workers,
      file.path("output/claim_work_pairs_keypaper", paste0("granularity=", granularity)),
      granularity,
      claim_completion_model
    ),
    pattern = map(assessment, key_messages_parquet, works_parquet, snowball_parquet),
    format = "file",
    deployment = "main",
    garbage_collection = TRUE
  ),
  tar_target(
    claim_units_keypaper,
    # km_scope applies here too, which it did NOT when this chain lived in the
    # training project -- that block had no km: field, so there was nothing to
    # thread. Moving it into factcheck without this made the two chains
    # inconsistent under the same config: `km: ["C."]` scoped the citing works
    # and silently scored every key paper of every KM. Cheap (29,511 pairs for
    # all of GA1) but wrong, and wrong in the direction that is hard to notice,
    # since the extra rows look like legitimate output.
    build_claim_units(assessment, claim_work_pairs_keypaper, max_length, km_scope),
    pattern = map(assessment, claim_work_pairs_keypaper),
    iteration = "list"
  ),
  tar_target(
    claim_units_keypaper_flat,
    unlist(claim_units_keypaper, recursive = FALSE),
    iteration = "list"
  ),
  # Same scratch-then-consolidate split as the citing-works chain.
  tar_target(
    claim_scores_keypaper,
    # Same backend dispatch as the citing-works chain above. The key-paper
    # corpus is 29,511 pairs against 2.43M, so it costs ~$1.50 at jev rates --
    # and it is the control: key papers ARE the evidence a BM was written from,
    # so a first-stage model that cannot separate them from citing works is
    # telling you something. The NLI separates the two by 9 points where the
    # reviewers separate them by 49.
    if (identical(scorer_config$backend, "jev")) {
      score_one_claim_jev(
        claim_units_keypaper_flat, scorer_config, scorer_name, scorer_model,
        output_root = file.path("output/claim_scores_keypaper", paste0("granularity=", granularity)),
        questions_file = jev_questions_file
      )
    } else {
      score_one_claim(
        claim_units_keypaper_flat, scorer_config, scorer_name, scorer_model,
        output_root = file.path("output/claim_scores_keypaper", paste0("granularity=", granularity))
      )
    },
    pattern = map(claim_units_keypaper_flat),
    error = "continue"
  ),
  tar_target(
    claim_scores_keypaper_consolidated,
    consolidate_claim_scores(
      claim_scores_keypaper,
      claim_units_keypaper_flat,
      output_root = file.path("output/claim_scores_keypaper", paste0("granularity=", granularity)),
      scorer_name = scorer_name
    ),
    format = "file",
    deployment = "main"
  ),

  # ---- relevance screen ----------------------------------------------------
  # Screens EVERY key-paper pair, because this chain has no routing: Phase 2
  # here reviews every pair unconditionally. That was right while key papers
  # were "a small, bounded, high-importance set"; at 968,534 pairs (945k still
  # unreviewed, ~$140 at gpt-4o-mini rates) it is no longer small, which is
  # what a screen is for.
  #
  # Duplicated rather than shared with the fact-checking project, deliberately:
  # the two chains score DIFFERENT pairs (claims x key papers vs claims x
  # citing works, 1.35% overlap), their claim sets depend on each purpose
  # block's own granularity, and after deployment they run different NLI models
  # -- fact checking on the fine-tune, this chain left on zero-shot to avoid
  # training on labels the model itself shaped. Only the ~8-line declaration is
  # duplicated; the function lives once in R/.
  tar_target(
    relevance_screen_keypaper,
    build_llm_relevance_screen(
      assessment,
      pairs = select_llm_verification_candidates(
        file.path("output/claim_scores_keypaper", paste0("granularity=", granularity),
                  paste0("scorer_config=", scorer_name), paste0("assessment=", assessment$id)),
        claim_work_pairs_keypaper,
        nli_labels = NULL, nli_certainty = NULL
      ),
      keypaper = TRUE,
      model = relevance_config$model,
      questions_file = jev_relevance_question_file,
      batch_size = relevance_config$batch_size
    ),
    pattern = map(assessment, claim_work_pairs_keypaper),
    format = "file", deployment = "main"
  ),

  # ---- key-paper Phase 2 LLM verification ----------------------------------
  # Reviews EVERY key paper's NLI-scored pair, irrespective of
  # nli_labels/nli_certainty -- unlike the citing-works chain, which routes by
  # those fields purely for cost control. Key papers are a small, bounded,
  # high-importance set where every one is worth an independent check.
  tar_target(
    llm_verification_keypaper_parquet,
    build_llm_verification_keypaper_parquet(
      assessment,
      claim_work_pairs_keypaper,
      file.path(
        "output/claim_scores_keypaper", paste0("granularity=", granularity),
        paste0("scorer_config=", scorer_name), paste0("assessment=", assessment$id)
      ),
      scorer_name,
      llm_verification_active,
      llm_verification_config,
      llm_verification_system_prompt_file,
      llm_verification_user_prompt_file,
      claim_scores_keypaper_consolidated,
      relevance_path = relevance_screen_keypaper,
      relevance_threshold = relevance_config$threshold
    ),
    pattern = map(assessment, claim_work_pairs_keypaper),
    format = "file",
    deployment = "main",
    garbage_collection = TRUE
  ),

  # ══ GOLD STANDARD ════════════════════════════════════════════════════════
  # Moved here from _targets_training.R on 2026-10-05. It used to gate
  # fine-tuning and the benchmark; both are gone, and it is kept because it is
  # now the ONLY thing that can test the decision that removed them. Every
  # conclusion in design_notes.md points 5-8 comes from models judging models,
  # with Jev and the review panel on one side and the NLI alone on the other.
  # Human labels are what break that circularity.
  # Hand-maintained input, same format = "file" + path convention as
  # config_file and the prompt files. The DIRECTORY is tracked rather than
  # individual files, so adding an assessment's reviews invalidates downstream
  # without anyone editing the pipeline.
  #
  # The sample itself is drawn by R/build_goldstandard_sample.R, which is
  # deliberately NOT a target: a target would regenerate the instruments
  # whenever upstream changed and destroy reviewer work in progress. Ordering is
  # nli_training_data (defines the holdout) -> hand-run draw -> humans -> gold.
  # nli_training_data is gone with the rest of the training arm, so the holdout
  # it defined now survives only as the `split` column inside the archived
  # dataset and as the id set in input/goldstandard/sample_manifest_*.csv --
  # which is enough to adjudicate and score the instrument that was already
  # drawn, but a NEW sample would need that fold definition rebuilding.
  tar_target(goldstandard_dir, "input/goldstandard", format = "file"),
  tar_target(goldstandard, build_goldstandard(goldstandard_dir)),
  NULL
)
