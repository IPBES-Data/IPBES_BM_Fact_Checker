# Fact-checking pipeline -- citing works -> Jev scoring -> LLM verification.
#
# One of three projects (see TD_targets.qmd and _targets.yaml):
#
#   _targets_collection.R             collection: LOD -> refs -> zotero -> works ->
#                          snowball -> works_citing. Keeps the ORIGINAL
#                          _targets_collection/ store, so nothing re-downloads.
#   _targets_factcheck.R   this file -- citing works AND key papers
#   _targets_reporting.R   renders everything, computes nothing that costs money
#
# WHAT THIS PROJECT IS FOR: the citing-works corpus -- every paper the snowball
# found citing a Background Message's key papers, scored against that BM's own
# claims by Jev (Phase 1), with the REFUTES/SUPPORTS-certain subset routed to a
# grounded LLM review (Phase 2). This is the expensive arm: millions of pairs,
# real OpenRouter spend. The far smaller key-paper set is scored by the
# key-paper QA chain further down this same file, which moved here when the
# training project was retired on 2026-10-05.
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
    "jsonlite", "digest", "ellmer", "crew", "keyring"
  ),
  # Claim-level concurrency. Four is a deliberate compromise: enough to keep
  # the Jev API busy across claims, few enough that four claims' premise frames
  # are not all in memory at once. Concurrency WITHIN a claim is separate and
  # lives in score_one_claim_jev() (httr2 max_active), which is where the real
  # throughput comes from.
  #
  # A fixed literal, not derived from config: the RunPod backend sized this from
  # the active pool's host count, because score_one_claim() dispatched claims by
  # taking a per-host file lock and under-sizing left pods idle while billing.
  # That backend is gone from this branch (see the scoring target below), and
  # with it the host count, the lock directory and the silent-fallback hazard
  # the old block guarded against.
  controller = crew::crew_controller_local(workers = 4L)
)

list.files("./R", full.names = TRUE) |> lapply(source)

# ---------------------------------------------------------------------------
# Cross-project inputs: what the collection project (_targets_collection.R) writes.
# Declared as format = "file" targets keeping the producing project's NAMES, so
# the scoring targets below move across verbatim and a genuine upstream change
# -- a refetched works_parquet, a new snowball -- still invalidates this chain
# through content hashing.
# ---------------------------------------------------------------------------

list(
  # DAG diagram for THIS project. build_pipeline_mmd() renders whatever DAG it
  # is run inside, so each project generates its own picture.
  # Hand-authored conceptual workflow for THIS project (one per targets
  # project; see input/mmd/workflow_collection.mmd's own header for the set).
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
  tar_target(targets_script, "_targets_factcheck.R", format = "file"),
  tar_target(
    pipeline_mmd,
    build_pipeline_mmd(targets_script, "input/mmd/pipeline_factcheck.mmd"),
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
  tar_target(relevance_config, yaml::read_yaml(config_file)[["fact_checking"]][["relevance_screen"]]),
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

  # ---- inputs from the collection project (_targets_collection.R) ----------------------
  tar_target(
    refs_parquet,
    file.path(out_collection("refs"), paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  tar_target(
    key_messages_parquet,
    file.path(out_collection("key_messages"), paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  tar_target(
    works_parquet,
    file.path(out_collection("works"), paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  # Three paths per branch (nodes / edges / keypaper), exactly as the
  # collection project's own target returns them.
  tar_target(
    snowball_parquet,
    c(
      file.path(out_collection("snowball/nodes"), paste0("assessment=", assessment$id)),
      file.path(out_collection("snowball/edges"), paste0("assessment=", assessment$id)),
      file.path(out_collection("snowball/keypaper"), paste0("assessment=", assessment$id))
    ),
    pattern = map(assessment), format = "file"
  ),
  # Two paths per branch (slim km/bm mapping, then deduplicated metadata), so
  # works_citing_map_paths()/works_citing_meta_paths() keep working unchanged.
  tar_target(
    works_citing_parquet,
    c(
      file.path(out_collection("works_citing"), paste0("assessment=", assessment$id)),
      file.path(out_collection("works_citing_meta"), paste0("assessment=", assessment$id))
    ),
    pattern = map(assessment), format = "file"
  ),

  # Target 2g' (claim/work pairs, evidence-segmented): same schema as the
  # per-sentence approach it replaced, but
  # BM text is cut into EVIDENCE-DELIMITED claims (split at braces that end a
  # sentence, {5.4.1, 5.4.2}) rather than per sentence -- or, under a
  # granularity: complete_bm config, not split at all (whole
  # bm_description/bm_label as one claim each). Same column schema either
  # way; output root is hive-partitioned by granularity=<value>/ so naive_bm
  # (the default, byte-identical path to before this partition was added --
  # existing data was migrated under granularity=naive_bm/ rather than
  # recomputed) and complete_bm never collide. See NEXT_STEPS.md.
  # ONE target for BOTH chains since 2026-10-07 -- it returns two roots, the same
  # "one target, several paths, split by name" convention snowball_parquet and
  # works_citing_parquet already use. Split with claim_work_pairs_path(x, keypaper=).
  #
  # The two sides still call DIFFERENT builders, because they genuinely read
  # different work sources: citing works come from works_citing_parquet, key
  # papers from works_parquet + the snowball's keypaper nodes. What was duplicated
  # and is now gone is the target declaration, which is where the drift was.
  tar_target(
    claim_work_pairs,
    c(
      build_claim_work_pairs(
        assessment,
        key_messages_parquet,
        works_citing_parquet,
        workers,
        file.path(out_factcheck("claim_work_pairs"), paste0("granularity=", granularity), "keypaper=false"),
        granularity,
        claim_completion_model
      ),
      build_claim_work_pairs_keypaper(
        assessment,
        key_messages_parquet,
        works_parquet,
        snowball_parquet,
        workers,
        file.path(out_factcheck("claim_work_pairs"), paste0("granularity=", granularity), "keypaper=true"),
        granularity,
        claim_completion_model
      )
    ),
    pattern = map(assessment, key_messages_parquet, works_citing_parquet, works_parquet, snowball_parquet),
    format = "file",
    # Same reasoning as nli_ready_parquet just above: internally forks its
    # own `workers` mclapply processes over a full-text cross-join, so
    # running its GA1/IAS branches on separate crew workers too stacks two
    # layers of parallelism on the pipeline's biggest in-memory data.
    deployment = "main",
    garbage_collection = TRUE
  ),
  # Target 2h: Phase 1 scoring — classify each citing work against each of its
  # BM's claims (SUPPORTS / REFUTES / NOT_ENOUGH_INFO) with Jev. Consumes
  # claim_work_pairs (work × claim cross-join with approx_tokens). Every work
  # of every scored
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
  # The pool check is GONE, not merely unwired. check_nli_pool_health() and the
  # RunPod-only machinery around it were deleted on 2026-10-05 with the rest of
  # the NLI stage; it is in git history and on the `NLI_dirty` branch if the
  # RunPod path is ever revived. What it did that this target does not: catch an
  # unreachable host, a pool serving mixed models, and an expect_model mismatch.
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
  # Both chains' claims in one list, each unit tagged with its own `keypaper`.
  # km_scope applies to BOTH -- it did not when the key-paper arm lived in the
  # training project (no km: field there to thread), so `km: ["C."]` scoped the
  # citing works while silently scoring every key paper of every KM. Cheap but
  # wrong, and wrong in the direction that is hard to notice: the extra rows look
  # like legitimate output.
  tar_target(
    claim_units,
    c(
      build_claim_units(assessment, claim_work_pairs_path(claim_work_pairs, FALSE),
                        max_length, km_scope, keypaper = FALSE),
      build_claim_units(assessment, claim_work_pairs_path(claim_work_pairs, TRUE),
                        max_length, km_scope, keypaper = TRUE)
    ),
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
    # JEV ONLY on this branch. The RunPod/NLI backend (score_one_claim(),
    # per-host file locks, pool health checks) is on `NLI_dirty`; it was
    # measured at or below chance for this task -- AUC 0.50 REFUTES, 0.38
    # SUPPORTS against refutations confirmed by three independent reviewers --
    # see design_notes.md points 6 and 8.
    #
    # The guard is kept even though config.yaml no longer defines any non-jev
    # scorer (the bge_m3_* entries were removed 2026-10-07): restoring one from
    # NLI_dirty is a paste, and without this check it would hand a
    # RunPod-shaped config (host:, passes:, batch_size:) to the Jev scorer and
    # score a whole corpus against the wrong thing, under the right
    # scorer_config= name.
    {
      if (!identical(scorer_config$backend, "jev")) {
        stop(sprintf(
          "nli.configs.%s has backend '%s'; this branch only scores with 'jev'. Switch fact_checking.active to a jev config, or use the NLI_dirty branch.",
          scorer_name, scorer_config$backend %||% "<unset>"
        ), call. = FALSE)
      }
      # keypaper is NOT passed: score_one_claim_jev() defaults it to the unit's
      # own tag, so one branch set covers both chains and no branch can be sent
      # to the wrong partition by a stale literal here.
      score_one_claim_jev(
        claim_units_flat, scorer_config, scorer_name, scorer_model,
        output_root = file.path(out_factcheck("claim_scores"), paste0("granularity=", granularity)),
        questions_file = jev_questions_file
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
    consolidate_claim_scores_both(
      claim_scores_by_claim,
      claim_units_flat,
      output_root = file.path(out_factcheck("claim_scores"), paste0("granularity=", granularity)),
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
  # adding it does not invalidate any of Phase 1's scoring chain or the
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
      out_factcheck("llm_candidate_scope"),
      granularity,
      claim_completion_model
    ),
    pattern = map(
      assessment, key_messages_parquet, refs_parquet, works_parquet,
      snowball_parquet, claim_work_pairs
    ),
    format = "file"
  ),
  # Target 2h4b: Phase 2 — LLM verification of the pairs Phase 1 flagged.
  # Reviews only what the scorer itself marked as needing a second opinion
  # (what the active llm config's nli_labels/nli_certainty select) — see
  # R/build_llm_verification_parquet.R and TD_NLI_LLM_two_phase.qmd. One
  # target call per assessment loops internally over its own candidates
  # (ellmer's own parallel_chat_structured concurrency is enough here — no
  # crew/file-lock dispatch needed, since OpenRouter is a shared endpoint,
  # not a fixed host pool to load-balance across as the retired RunPod backend
  # required).
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
    # BOTH sides, with DIFFERENT routing, which is the whole reason this cannot
    # be one undifferentiated call: citing works are screened only over the
    # routed subset (what nli_labels/nli_certainty select -- 190,759 of GA1's
    # 2.43M, ~$3), key papers over everything, because Phase 2 reviews every
    # key-paper pair unconditionally and so has no upstream routing to narrow.
    #
    # claim_scores_consolidated IS this tree's root; taking it as the path rather
    # than recomputing the formula is what puts a real edge from Phase 1 scoring
    # into this target. Without it the screen depended only on config and ran
    # BEFORE scoring, against an empty tree, writing 0 bytes that targets then
    # recorded as up to date and would never re-dispatch.
    relevance_screen_both(
      assessment,
      consolidated = claim_scores_consolidated,
      pairs_roots = claim_work_pairs,
      llm_config = llm_verification_config,
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
    # BOTH sides. The two builders stay separate functions with their own
    # explicit routing -- citing works filtered by nli_labels/nli_certainty, key
    # papers reviewed in full -- rather than being merged behind a conditional
    # candidate filter. That conditional was the single highest-risk line in this
    # whole change: wrong one way and key papers silently stop being reviewed,
    # wrong the other and 2.43M citing pairs go to full OpenRouter coverage.
    # llm_verification_both() asserts the routed count per side afterwards, so
    # neither mistake can be silent. See R/claim_chain.R.
    llm_verification_both(
      assessment,
      pairs_roots = claim_work_pairs,
      consolidated = claim_scores_consolidated,
      scope_path = llm_candidate_scope_parquet,
      scorer_name = scorer_name,
      llm_active = llm_verification_active,
      llm_config = llm_verification_config,
      system_prompt_file = llm_verification_system_prompt_file,
      user_prompt_file = llm_verification_user_prompt_file,
      granularity = granularity,
      relevance_roots = relevance_screen,
      relevance_threshold = relevance_config$threshold
    ),
    pattern = map(assessment, claim_work_pairs, llm_candidate_scope_parquet, relevance_screen),
    format = "file",
    # select_llm_verification_candidates() collect()s both the routed Phase 1
    # scores AND the full premise table per assessment before joining in R --
    # multi-GB for one assessment. deployment = "main" processes branches one at
    # a time; ellmer's own max_active concurrency within an assessment is
    # unaffected. Contributed to an observed OOM when run concurrently.
    deployment = "main",
    garbage_collection = TRUE
  ),

  # ══ KEY PAPERS ═══════════════════════════════════════════════════════════
  # NO TARGETS OF THEIR OWN since 2026-10-07. The key-paper QA chain asks the
  # inverse question to the citing-works one -- do the papers IPBES itself cites
  # as evidence for a Background Message actually support it? A key paper IS that
  # evidence, so it should land overwhelmingly in SUPPORTS; when it does not,
  # that is the signal worth chasing. Measured 2026-10-05: 77.8% of key papers
  # confirmed against 18.9% of citing works, on the same claims.
  #
  # It used to be seven duplicate targets alongside their citing twins. Phase 1
  # of the fold made keypaper=<true|false> a hive partition level above
  # assessment= in all three trees; phase 2, here, removed the duplicate targets.
  # Each stage above now handles both sides and returns both roots, split with
  # claim_work_pairs_path() / claim_scores_consolidated_path() /
  # claim_relevance_path() from R/claim_chain.R.
  #
  # The requirement the separation protected still holds and is still met: the
  # two score DIFFERENT pairs (1.35% overlap -- 399 of 29,496 on GA1) and must be
  # runnable, re-runnable and deletable independently. The partition level does
  # that, and gives each side its own .scratch root, which is what stops a citing
  # branch and a key-paper branch for the same claim racing on one
  # <claim_id>.parquet.
  #
  # What the duplication cost while it lasted: claim_scores_keypaper_consolidated
  # passed neither assessments= nor km=, so its prune glob visited every group
  # under the scorer root; and claim_units_keypaper needed km_scope retro-fitted
  # after the move out of the training project, until which `km: ["C."]` scoped
  # the citing works and silently scored every key paper of every KM.
  #
  # ONE BEHAVIOUR CHANGE from the 2026-10-05 move still applies: key papers now
  # follow fact_checking's nli config rather than training's. The reason they were
  # pinned to zero-shot -- "avoid training on labels the model itself shaped" --
  # was about protecting a training set that no longer exists.

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
  # error = "continue" so an unreviewed round does not fail the whole pipeline.
  # Verified 2026-10-07: NOTHING depends on this target -- the fine-tune and
  # benchmark it used to gate were retired 2026-10-05, and reporting does not
  # declare it. So its stop() could only turn "the humans have not reviewed yet",
  # which is the ordinary state between drawing the instruments and getting them
  # back, into a failed tar_make() that hides whatever else the run did.
  # It still errors visibly in the run summary; it just no longer takes the
  # pipeline down with it.
  tar_target(goldstandard, build_goldstandard(goldstandard_dir), error = "continue")
)
