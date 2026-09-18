# Training pipeline -- key papers -> NLI -> LLM -> training set -> fine-tune.
#
# One of four projects (see TODO_PIPELINE_SPLIT.md and _targets.yaml):
#
#   _targets.R             collection: LOD -> refs -> zotero -> works ->
#                          snowball -> works_citing. Keeps the ORIGINAL
#                          _targets/ store, so nothing re-downloads.
#   _targets_factcheck.R   citing works -> NLI -> LLM
#   _targets_training.R    this file
#   _targets_reporting.R   renders everything, computes nothing that costs money
#
# WHAT THIS PROJECT IS FOR: the key-paper arm. A key paper IS the evidence a
# Background Message was written from, so scoring one against its own BM is
# both a QA sanity check (it should overwhelmingly land in SUPPORTS) and the
# source of the positive class for fine-tuning. That makes it a genuinely
# separate concern from fact checking, which scores the citing-works corpus --
# orders of magnitude larger, and gated on a separate spend decision.
#
# It is also the arm that can run for an assessment whose citing-works chain
# has not: IAS and VA/TCA have key-paper Phase 2 output with no citing-works
# Phase 2 output at all. build_nli_training_data() is built to tolerate exactly
# that (its main-corpus input path is computed rather than taken from the
# fact-checking target, so it carries no dependency on it), and keeping the two
# arms in separate projects makes that independence structural rather than a
# property of one carefully-written argument.
#
# CREDENTIALS: API_openrouter only. Two paths spend it -- Phase 2 key-paper
# review (llm_verification_keypaper_parquet) and, under granularity:
# atomic_bm, claim completion inside nli_ready_evidence_keypaper_parquet. It
# needs no API_openalex: nothing here fetches from OpenAlex, so the collection
# project's key and its rate-limit preflight are both absent.
#
# ALSO NEEDED, for nli_finetuned_model only: the Python venv at
# ~/.venvs/specter2-merge/bin/python3 (see R/build_nli_finetuned_model.R),
# and that target only runs when config.yaml's `training.finetune.enabled` is true.
library(targets)

Sys.setenv(
  API_openrouter = keyring::key_get("API_openrouter")
)

tar_option_set(
  packages = c(
    "yaml", "dplyr", "arrow", "stringr", "xml2", "httr2",
    "jsonlite", "digest", "ellmer", "filelock", "crew", "keyring"
  ),
  # Same sizing as the collection project's own controller, and for the same
  # reason: score_one_claim() dispatches claims across the NLI pool selected by `training.nli`'s
  # hosts by taking a per-host file lock, so local concurrency has to match the
  # host count or hosts sit idle. Read straight from config.yaml at
  # pipeline-definition time rather than via a target -- this is worker-pool
  # sizing, not part of the DAG's correctness.
  #
  # NOTE the lock directory (output/nli_scores/.locks/) is shared with the
  # fact-checking project. That is deliberate and not a collision: if both
  # projects run at once they contend for the same hosts, which is exactly the
  # behaviour wanted -- one pool, one queue. It is, however, the one piece of
  # cross-project state that no DAG describes, alongside the two LLM caches
  # named in TODO_PIPELINE_SPLIT.md's "Cross-project contracts".
  controller = crew::crew_controller_local(
    workers = tryCatch({
      cfg <- yaml::read_yaml("input/config.yaml")
      sel <- cfg[["training"]][["nli"]]
      n <- length(unlist(cfg[["nli"]][["configs"]][[sel]][["host"]]))
      max(1L, n)
    }, error = function(e) 1L)
  )
)

list.files("./R", full.names = TRUE) |> lapply(source)

# ---------------------------------------------------------------------------
# Cross-project inputs.
#
# Declared as format = "file" targets pointing at what the collection project
# writes, keeping the NAMES that project uses so the training targets below
# move across verbatim. targets hashes them, so a genuine upstream change --
# a refetched works_parquet, a new snowball -- still invalidates this chain.
#
# The sizes make that affordable here: output/works, output/key_messages and
# output/snowball together are a few GB, against the 140 GB
# nli_ready_evidence tree that forced the reporting project to leave two of
# its inputs untracked.
# ---------------------------------------------------------------------------

list(
  # DAG diagram for THIS project. build_pipeline_mmd() renders whatever DAG it
  # is run inside, so each project generates its own picture rather than one
  # file that silently depicts whichever project last owned the target -- see
  # the same comment in _targets_reporting.R for how that actually went wrong.
  tar_target(r_files, list.files("R", full.names = TRUE), format = "file"),
  tar_target(
    pipeline_mmd,
    build_pipeline_mmd(r_files, "input/mmd/pipeline_training.mmd"),
    format = "file"
  ),
  tar_target(
    diagram_pipeline_training,
    render_mmd(pipeline_mmd),
    format = "file"
  ),

  # ---- configuration (re-derived here; every project reads the same file) ---
  # Same fine-grained split as the other projects: each target reads only its
  # own field, so editing an unrelated one does not cascade. That matters more
  # here than anywhere else -- nli_train_enabled and nli_downsample_seed gate a
  # real ~25 min local CPU run, and routing them through the coarse nli_config
  # blob would let a host-list edit re-trigger one.
  tar_target(config_file, "input/config.yaml", format = "file"),
  # Selections come from config.yaml's `training:` purpose block.
  tar_target(purpose, purpose_config(yaml::read_yaml(config_file), "training")),
  tar_target(nli_active, purpose$nli),
  tar_target(workers, yaml::read_yaml(config_file)[["workers"]]),
  tar_target(nli_config, yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]]),
  tar_target(
    granularity,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["granularity"]] %||% "naive_bm"
  ),
  tar_target(
    max_length,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["max_length"]]
  ),
  # training.finetune, not a `train:` field on the serving config -- how a
  # model is served and whether this project trains one are different things.
  tar_target(nli_train_enabled, purpose$finetune_enabled),
  tar_target(nli_downsample_seed, purpose$downsample_seed),
  tar_target(claim_completion_model, purpose$claim_completion_model),
  tar_target(
    assessments_list,
    purpose_assessments_list(yaml::read_yaml(config_file), "training")
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
    key_messages_parquet,
    file.path("output/key_messages", paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  tar_target(
    works_parquet,
    file.path("output/works", paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  # Three paths per branch, exactly as the collection project's own target
  # returns them (nodes / edges / keypaper), so
  # build_nli_ready_evidence_keypaper_parquet()'s own path handling is
  # unchanged. Partitioned by assessment only since the snowball was unified
  # to one pro_snowball() call per assessment.
  tar_target(
    snowball_parquet,
    c(
      file.path("output/snowball/nodes", paste0("assessment=", assessment$id)),
      file.path("output/snowball/edges", paste0("assessment=", assessment$id)),
      file.path("output/snowball/keypaper", paste0("assessment=", assessment$id))
    ),
    pattern = map(assessment), format = "file"
  ),
  # Read only for works_citing_meta_paths() inside nli_training_data, which
  # joins title/abstract back onto the training rows. Two paths per branch,
  # matching the collection project's own return shape.
  tar_target(
    works_citing_parquet,
    c(
      file.path("output/works_citing", paste0("assessment=", assessment$id)),
      file.path("output/works_citing_meta", paste0("assessment=", assessment$id))
    ),
    pattern = map(assessment), format = "file"
  ),

  # ---- key-paper NLI scoring -----------------------------------------------
  # Pool health check, once per pipeline build. Fails loudly if any host is
  # unreachable, or if hosts report different models (which would silently
  # corrupt result provenance).
  #
  # MIGRATION NOTE: with a fresh store every target below is outdated by
  # definition, so even a no-op pass -- one that will delta-skip every claim --
  # has to satisfy this check first, and therefore needs a live pool. One pod
  # in the active config's host: list is enough.
  tar_target(
    nli_pool_health,
    check_nli_pool_health(nli_config, nli_active)
  ),
  # Scores the actual seed/reference papers IPBES cites as evidence for a BM
  # (relation == "keypaper" in the snowball nodes) against their OWN BM's claim
  # text. Mirrors the citing-works chain exactly -- same
  # build_nli_claim_units()/score_one_claim() reused unchanged -- with only the
  # premise source and the output roots differing, so it can never collide with
  # or invalidate that chain.
  tar_target(
    nli_ready_evidence_keypaper_parquet,
    build_nli_ready_evidence_keypaper_parquet(
      assessment,
      key_messages_parquet,
      works_parquet,
      snowball_parquet,
      workers,
      file.path("output/nli_ready_evidence_keypaper", paste0("granularity=", granularity)),
      granularity,
      claim_completion_model
    ),
    pattern = map(assessment, key_messages_parquet, works_parquet, snowball_parquet),
    format = "file",
    deployment = "main",
    garbage_collection = TRUE
  ),
  tar_target(
    nli_claim_units_evidence_keypaper,
    build_nli_claim_units(assessment, nli_ready_evidence_keypaper_parquet, max_length),
    pattern = map(assessment, nli_ready_evidence_keypaper_parquet),
    iteration = "list"
  ),
  tar_target(
    nli_claim_units_evidence_keypaper_flat,
    unlist(nli_claim_units_evidence_keypaper, recursive = FALSE),
    iteration = "list"
  ),
  # Same scratch-then-consolidate split as the citing-works chain.
  tar_target(
    nli_scores_keypaper_evidence,
    score_one_claim(
      nli_claim_units_evidence_keypaper_flat,
      nli_config,
      nli_active,
      nli_pool_health,
      output_root = file.path("output/nli_scores_evidence_keypaper", paste0("granularity=", granularity))
    ),
    pattern = map(nli_claim_units_evidence_keypaper_flat),
    error = "continue"
  ),
  tar_target(
    nli_scores_keypaper_evidence_consolidated,
    consolidate_nli_scores(
      nli_scores_keypaper_evidence,
      nli_claim_units_evidence_keypaper_flat,
      output_root = file.path("output/nli_scores_evidence_keypaper", paste0("granularity=", granularity)),
      nli_active = nli_active
    ),
    format = "file",
    deployment = "main"
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
      nli_ready_evidence_keypaper_parquet,
      file.path(
        "output/nli_scores_evidence_keypaper", paste0("granularity=", granularity),
        paste0("nli_config=", nli_active), paste0("assessment=", assessment$id)
      ),
      nli_active,
      llm_verification_active,
      llm_verification_config,
      llm_verification_system_prompt_file,
      llm_verification_user_prompt_file,
      nli_scores_keypaper_evidence_consolidated
    ),
    pattern = map(assessment, nli_ready_evidence_keypaper_parquet),
    format = "file",
    deployment = "main",
    garbage_collection = TRUE
  ),

  # ---- training set + fine-tuning ------------------------------------------
  # Reads only already-built output/llm_verification/scores* data -- a pure
  # local Arrow query, no new LLM/API calls.
  #
  # The main-corpus (citing-works) input path is COMPUTED here, mirroring
  # build_llm_verification_parquet()'s own output_path formula, rather than
  # taken from the fact-checking project's target. That was already true before
  # the split, for a reason the split now makes structural: an assessment can
  # have real keypaper data long before its citing-works corpus has been scored
  # (a much bigger, separately-gated spend). Taking the fact-checking output as
  # a tracked dependency would force that assessment's entire citing-works
  # chain to build just to compute this -- confirmed it would for IAS.
  # build_nli_training_data()'s own has_data() check treats a not-yet-existing
  # path exactly like an empty one.
  tar_target(
    nli_training_data,
    build_nli_training_data(
      assessment,
      file.path(
        "output/llm_verification/scores",
        paste0("llm_config=", llm_verification_active),
        paste0("assessment=", assessment$id)
      ),
      llm_verification_keypaper_parquet,
      works_parquet,
      works_citing_meta_paths(works_citing_parquet),
      nli_active,
      llm_verification_active,
      granularity,
      "output/nli_training"
    ),
    pattern = map(
      assessment, llm_verification_keypaper_parquet,
      works_parquet, works_citing_parquet
    ),
    format = "file",
    deployment = "main",
    garbage_collection = TRUE
  ),
  # Fine-tune the active nli config's model, IFF that config's own train: field
  # is true (default false). A real local CPU training run (~25 min), opt-in per
  # config so a bare tar_make() never triggers one by surprise.
  #
  # nli_training_data is passed as a bare (non-pattern) argument purely to
  # establish the DAG dependency: it branches per assessment while this target
  # does not, so a real pattern= dependency isn't possible.
  # build_nli_finetuned_model() never reads the value -- train_nli.py reads
  # output/nli_training off disk itself -- it exists only so that editing
  # R/build_nli_training_data.R, or rebuilding it for any assessment, correctly
  # marks this outdated rather than silently training on stale data.
  tar_target(
    nli_finetuned_model,
    build_nli_finetuned_model(
      nli_train_enabled, nli_active,
      downsample_seed = nli_downsample_seed,
      nli_training_data_dep = nli_training_data
    ),
    format = "file",
    deployment = "main"
  ),
  NULL
)
