library(targets)

# Sys.setenv(
#   API_openalex = keyring::key_get("API_openalex")
# )

Sys.setenv(
  API_openrouter = keyring::key_get("API_openrouter")
)

Sys.setenv(
  openalexPro.apikey = keyring::key_get("API_openalex")
)

if (Sys.getenv("openalexPro.apikey", unset = "") == "") {
  stop("OpenAlex API Key not set!")
}
rl <- openalexPro::pro_rate_limit_status()
if (rl$rate_limit$daily_remaining_usd < 0.1) {
  warning("Daily limit below 0.1US$ - fail likely!")
}

tar_option_set(
  packages = c(
    "yaml",
    "dplyr",
    "arrow",
    "tictoc",
    "processx",
    "httr2",
    "readr",
    "openalexPro",
    "openalexSnowball",
    "jsonlite",
    "digest",
    "ellmer",
    "future",
    "future.apply",
    "xml2",
    "stringr",
    "ggplot2",
    "IPBES.R",
    "htmlwidgets",
    "tidyr",
    "crew",
    "filelock"
  ),
  # NLI claim-level scoring (score_one_claim) dispatches dynamically across
  # the active nli pool's hosts via file locks — crew supplies genuine LOCAL
  # concurrency so multiple claims can be in flight at once. Sized to the
  # current host count (read directly from config.yaml at pipeline-definition
  # time, not via a cached target — this is a worker-pool sizing decision,
  # not part of the DAG's correctness). Falls back to 1 if config is missing
  # or malformed at parse time.
  controller = crew::crew_controller_local(
    workers = tryCatch({
      nli_cfg <- yaml::read_yaml("input/config.yaml")[["nli"]]
      n <- length(unlist(nli_cfg[["configs"]][[nli_cfg[["active"]]]][["host"]]))
      max(1L, n)
    }, error = function(e) 1L)
  )
)

list.files(
  "./R",
  full.names = TRUE
) |>
  lapply(
    source
  )

# Report wrapper generation and every render/deploy target now live in
# _targets_reporting.R (see _targets.yaml and TODO_PIPELINE_SPLIT.md).
# They were moved out so that rendering a report cannot reach a paid
# target: this script still holds the scoring chains, which spend RunPod
# GPU time and OpenRouter money, and the reporting project holds nothing
# that does.

list(
  # Hand-authored conceptual workflow for THIS project. Split out of the single
  # workflow_nli.mmd along its existing subgraph boundaries when the pipeline
  # became several projects: every qa_*/report_* node went to
  # workflow_reporting.mmd (because those targets did), the rest stayed here.
  # All 34 clickable node ids were accounted for across the two files -- 25
  # here, 9 there, none lost. The force-ordering linkStyle indices were
  # recomputed programmatically rather than by hand; the original file's own
  # comment warned that they must be recounted whenever edges change, and
  # removing the reporting edges invalidated every one of them.
  tar_target(
    mmd_workflow_main,
    "input/mmd/workflow_main.mmd",
    format = "file"
  ),
  tar_target(
    diagram_workflow_main,
    render_mmd(mmd_workflow_main),
    format = "file"
  ),

  # DAG-derived diagram targets. These live in THIS project, not the reporting
  # one, because build_pipeline_mmd() renders whatever DAG it is run inside:
  # moved to reporting during the split, it silently regenerated
  # pipeline_nli.mmd as a picture of the 52-target REPORTING graph --
  # snowball_parquet and nli_scores_by_claim_evidence vanished, while
  # works_citing_parquet and llm_verification_parquet survived only as the
  # input stubs the reporting project declares. Caught by reading the diff.
  #
  # Splitting the pipeline means there is no longer ONE dag for a
  # "pipeline diagram" to describe, so wherever this target lives it depicts
  # only its own project. It sits here because this is the graph with the
  # substantive computation in it. See TODO_PIPELINE_SPLIT.md -- this needs a
  # real decision (rename per project, combine the stores, or drop it in
  # favour of the hand-authored workflow_nli.mmd) before the remaining
  # extractions make this graph partial too.
  # Pipeline diagram — auto-generated from the live tar_mermaid() DAG (TD
  # layout, no status colours). Writes input/mmd/pipeline_nli.mmd.
  tar_target(
    r_files,
    c("_targets.R", list.files("R", full.names = TRUE)),
    format = "file"
  ),
  tar_target(
    pipeline_mmd,
    build_pipeline_mmd(r_files, "input/mmd/pipeline_main.mmd"),
    format = "file"
  ),
  tar_target(
    diagram_pipeline_nli,
    render_mmd(pipeline_mmd),
    format = "file"
  ),
  # Diagrams — re-render SVGs whenever .mmd source files change.
  # workflow_nli.mmd is the active, hand-authored conceptual workflow;
  # its parked `_lm` counterpart (the earlier single-phase LLM-comparison
  # approach) was removed once that approach's source was deleted outright
  # rather than kept parked — see TD_LLM_approach.qmd for the design record.
  # Config — split into fine-grained targets so unrelated changes don't cascade
  tar_target(config_file, "input/config.yaml", format = "file"),
  # Fine-grained config targets: each reads only its own section from config_file.
  # This means changing e.g. nli.host only invalidates nli_config (and thus
  # nli_scores_parquet), not sparql_url, assessments_list, or any upstream target.
  tar_target(sparql_url, yaml::read_yaml(config_file)[["sparql_url"]]),
  tar_target(nli_active, yaml::read_yaml(config_file)[["nli"]][["active"]]),
  tar_target(workers, yaml::read_yaml(config_file)[["workers"]]),
  tar_target(nli_config, {
    nli <- yaml::read_yaml(config_file)[["nli"]]
    nli[["configs"]][[nli[["active"]]]]
  }),
  # ALL named nli configs (not just the active one) -- needed by
  # nli_config_for_granularity() (R/branch_helpers.R) so the reporting layer
  # can resolve which config actually produced a given granularity's scores,
  # independent of whichever config `nli.active` currently points to. Read
  # directly from config_file (not derived from nli_config) so an edit to
  # the active config's own fields doesn't spuriously invalidate this.
  tar_target(
    nli_configs_all,
    yaml::read_yaml(config_file)[["nli"]][["configs"]]
  ),
  # The active config's own claim-granularity setting ("naive_bm" default /
  # "complete_bm") -- drives nli_ready_evidence_parquet/
  # nli_scores_by_claim_evidence's own output_root (they run against
  # whichever granularity is actually active). Deliberately reads
  # config_file directly rather than depending on nli_config (the whole
  # active block: host/port/max_length/... bundled together) -- granularity
  # is the ONLY field of the active NLI config that nli_ready_evidence_parquet
  # actually needs, so routing through the full nli_config blob would mean
  # any unrelated field edit (e.g. a host list) forces this target to be
  # rechecked too. Not the same as nli_granularities below, which the
  # reporting layer uses to enumerate BOTH values regardless of which one
  # is active.
  tar_target(
    granularity,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["granularity"]] %||% "naive_bm"
  ),
  # Same reasoning as granularity just above: build_nli_claim_units() only
  # ever reads max_length off the config it's handed (to filter which rows
  # count toward the largest-first scoring order) -- nothing else in it
  # touches host/port/scheme/uncertain_threshold/etc. Reading it directly
  # here means nli_claim_units/nli_claim_units_evidence no longer get
  # rechecked on an unrelated nli_config field edit.
  tar_target(
    max_length,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["max_length"]]
  ),
  # Same reasoning again: whether to fine-tune the active config's model
  # (scripts/training/train_nli.py, via nli_finetuned_model below) is its
  # own field, read directly rather than through the full nli_config blob,
  # so an unrelated field edit (host list, uncertain_threshold, ...) never
  # spuriously re-triggers a real ~25min local training run. Defaults to
  # FALSE -- every existing config leaves train: false explicitly in
  # input/config.yaml, but %||% covers a config that omits the field entirely.
  tar_target(
    nli_train_enabled,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["train"]] %||% FALSE
  ),
  # Same reasoning again: NULL (the default) trains nli_finetuned_model on
  # the full pooled dataset as-is; a seed downsamples every label class down
  # to the smallest class's count first, for class balance -- see
  # scripts/training/train_nli.py's own downsample_seed handling and the
  # comment on `train` above for why this is read directly rather than
  # through the full nli_config blob.
  tar_target(
    nli_downsample_seed,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["downsample_seed"]]
  ),
  # Fixed, not read from config: the reporting layer (nli_overview_data,
  # the label funnel reports, etc.) renders one output per (assessment,
  # granularity) combination via cross() so both are always visible,
  # falling back to an empty state for whichever hasn't been scored yet.
  tar_target(nli_granularities, c("naive_bm", "complete_bm", "atomic_bm")),
  # granularity: atomic_bm's own model choice for LLM-completing elliptical
  # fragments (R/build_claim_completion.R). Same active/configs shape as
  # nli:/llm_verification: below, and same fine-grained-target reasoning as
  # granularity/max_length above: reads straight through to the one field
  # (model) this needs rather than depending on a coarse blob. Falls back
  # to complete_bm_fragments()'s own default (not duplicated here) if
  # input/config.yaml ever has no claim_completion: section.
  tar_target(
    claim_completion_model,
    {
      cc <- yaml::read_yaml(config_file)[["nli"]][["claim_completion"]]
      cc[["configs"]][[cc[["active"]]]][["model"]]
    }
  ),
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
  # Parked: fulltext_list has no downstream consumer (R/build_fulltext.R is
  # not wired into any target — see CLAUDE.md's orphaned-files note), so it
  # was computing per-assessment full_text flags for nothing. Uncomment only
  # once a real fulltext_* target reads it.
  # tar_target(
  #   fulltext_list,
  #   lapply(yaml::read_yaml(config_file)[["assessments"]], function(a) {
  #     list(assessment_id = a[["id"]], enabled = isTRUE(a[["full_text"]]))
  #   })
  # ),

  # Phase 2 (LLM verification) config + prompt files — see the llm_verification_*
  # targets below, after the NLI scoring chain they consume. Same fine-grained
  # active/config split as nli_active/nli_config: changing which named config
  # is active only invalidates llm_verification_config (and thus
  # llm_verification_parquet), not unrelated targets.
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
  # Target 1: Download TTL files to output/LoD/ (cached on disk).
  # Required when sparql_url == "fuseki" (the TTL is POSTed into the local
  # Fuseki named graph). For a remote endpoint the file is unused, but the
  # download is cheap and keeps the parquet builders' map() patterns valid.
  tar_target(
    ttl_path,
    download_ttl(assessment),
    pattern = map(assessment),
    format = "file"
  ),
  # SPARQL query files — tracked so downstream targets invalidate when queries change
  tar_target(refs_sparql, "queries/refs.sparql", format = "file"),
  tar_target(
    key_messages_sparql,
    "queries/key_messages.sparql",
    format = "file"
  ),
  # Target 2a: DB1 — refs written directly to output/refs/
  tar_target(
    refs_parquet,
    build_refs_parquet(
      sparql_url,
      assessment,
      ttl_path,
      refs_sparql,
      "output/refs"
    ),
    pattern = map(assessment, ttl_path),
    format = "file"
  ),
  # Target 2b: DB2 — section content. DISABLED 2026-09-15.
  #
  # Nothing consumed it. No target took sections_parquet as an argument and no
  # qmd read output/sections/; its only ever consumer was resolve_citations.R,
  # which has itself been orphaned (no active target) for some time. It was
  # therefore paying a full SPARQL extraction + Fuseki round trip per
  # assessment on every rebuild for output nothing read, and output/sections/
  # was deleted along with this.
  #
  # Kept here commented rather than removed outright, same convention as the
  # orphaned builders left in R/ (build_fulltext.R, resolve_citations.R):
  # R/write_sections_parquet.R and queries/sections.sparql both still exist, so
  # re-enabling is uncommenting the two tar_target() calls below (the
  # sections_sparql file target moved in here with it, having no other
  # consumer). NEXT_STEPS.md still floats joining claim evidence-references
  # against this dataset to fetch the backing text — that is the one thing that
  # would bring it back.
  #
  # tar_target(sections_sparql, "queries/sections.sparql", format = "file"),
  # tar_target(
  #   sections_parquet,
  #   build_sections_parquet(
  #     sparql_url,
  #     assessment,
  #     ttl_path,
  #     sections_sparql,
  #     "output/sections"
  #   ),
  #   pattern = map(assessment, ttl_path),
  #   format = "file"
  # ),

  # Target 2b2: DB3 — KM, BM, and SM descriptive text written directly to output/key_messages/
  tar_target(
    key_messages_parquet,
    build_key_messages_parquet(
      sparql_url,
      assessment,
      ttl_path,
      key_messages_sparql,
      "output/key_messages"
    ),
    pattern = map(assessment, ttl_path),
    format = "file"
  ),
  # Target 2c: Zotero items per assessment
  tar_target(
    zotero_parquet,
    download_zotero(assessment, refs_parquet),
    pattern = map(assessment, refs_parquet),
    format = "file"
  ),
  # Target 2d: OpenAlex works per assessment — partitioned by assessment/km/bm
  tar_target(
    works_parquet,
    download_works(assessment, zotero_parquet, refs_parquet, workers = 8),
    pattern = map(assessment, zotero_parquet, refs_parquet),
    format = "file"
  ),
  # Target 2e: Snowball search — citing/cited papers per assessment/km/bm
  tar_target(
    snowball_parquet,
    build_snowball_parquet(assessment, works_parquet, "output/snowball"),
    pattern = map(assessment, works_parquet),
    format = "file",
    # One assessment's OpenAlex fetch failing must not abort the others.
    # Without this, the 2026-09-15 api.openalex.org stall on the IAS branch
    # aborted the whole pipeline and killed GA1's and BBA's branches while
    # they were still running. Each branch is an independent multi-hour
    # fetch, so a failure is reported and marked while every other branch
    # proceeds -- same reasoning as the NLI scoring targets, where one bad
    # claim used to cost a host its entire remaining backlog.
    error = "continue"
  ),
  # Target 2f: Citing works — papers citing the seed works, fetched per km/bm
  tar_target(
    works_citing_parquet,
    build_works_citing_parquet(
      assessment,
      works_parquet,
      snowball_parquet,
      "output/works_citing"
    ),
    pattern = map(assessment, works_parquet, snowball_parquet),
    format = "file"
  ),
  # Target 2g (NLI-ready): NLI-ready parquet — BM descriptions split into
  # sentences (falling back to bm_label when bm_description is absent), crossed
  # with the cleaned (premise = title + abstract) of each citing work.
  # One row per (work × BM sentence); sentence_number preserves original order.
  tar_target(
    nli_ready_parquet,
    build_nli_ready_parquet(
      assessment,
      key_messages_parquet,
      works_citing_parquet,
      workers,
      "output/nli_ready"
    ),
    pattern = map(assessment, key_messages_parquet, works_citing_parquet),
    format = "file",
    # Already forks its own `workers` mclapply processes internally, each
    # holding a work x sentence cross-join with full title+abstract text in
    # memory. Dispatching the GA1 and IAS branches to separate crew workers
    # ON TOP of that internal forking stacks two layers of parallelism on
    # the most memory-hungry step in the pipeline -- observed to trigger OOM
    # kills when it lands alongside nli_overview_data/llm_verification_parquet.
    # deployment = "main" runs branches one at a time in the orchestrating
    # process instead; NLI scoring's own crew concurrency (sized to the
    # RunPod host count) is untouched. garbage_collection = TRUE forces a
    # gc() after each branch so its memory is reclaimed before the next one
    # starts, rather than accumulating across the sequential run.
    deployment = "main",
    garbage_collection = TRUE
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
  # Target 2h1: Claim-units to score, per assessment.
  tar_target(
    nli_claim_units,
    build_nli_claim_units(assessment, nli_ready_parquet, max_length),
    pattern = map(assessment, nli_ready_parquet),
    iteration = "list"
  ),
  # Target 2h2: Flatten to one element per claim across ALL assessments, so
  # the next target can branch one-target-per-claim.
  tar_target(
    nli_claim_units_flat,
    unlist(nli_claim_units, recursive = FALSE),
    iteration = "list"
  ),
  # Target 2h3: Score one claim per branch. error = "continue": a failing
  # claim is reported live and marked failed; every other claim's branch
  # proceeds independently. Re-running tar_make() only retries failed/new
  # claims (plus targets' own branch caching skips already-succeeded ones
  # whose inputs haven't changed).
  # Commented out: this per-sentence chain isn't consumed by the report
  # (nli_overview_data reads nli_scores_by_claim_evidence only — see that
  # target's comment) and shares nli_config/nli_pool_health/score_one_claim
  # with the evidence chain, so a bare tar_make() would dispatch both against
  # the same live RunPod pool. Uncomment only if you deliberately want the
  # per-sentence approach scored too.
  # tar_target(
  #   nli_scores_by_claim,
  #   score_one_claim(nli_claim_units_flat, nli_config, nli_active, nli_pool_health),
  #   pattern = map(nli_claim_units_flat),
  #   format = "file",
  #   error = "continue"
  # ),

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
  # Target 2h3' (QA, key papers): scores the actual seed/reference papers
  # IPBES cites as evidence for a BM (relation == "keypaper" in the
  # snowball nodes -- same set as works_parquet, one row per (paper, km,
  # bm) it's evidence for) against their OWN BM's claim text. Not part of
  # the main scoring corpus -- a sanity check: a key paper IS the evidence
  # a BM was written from, so it should overwhelmingly land in the
  # SUPPORTS region; if it doesn't, that's a signal worth investigating; see
  # the ternary figure in nli_scores_qa_figures, which overlays these
  # points on the citing-works density. Mirrors nli_ready_evidence_parquet
  # -> nli_claim_units_evidence -> ..._flat -> nli_scores_by_claim_evidence
  # exactly (same reuse-build_nli_claim_units()/score_one_claim()-unchanged
  # pattern that chain's own comment documents) -- only the premise source
  # (R/build_nli_ready_evidence_keypaper_parquet.R, a separate file so as
  # not to touch the delicate, already-scored citing-works builder) and the
  # output roots differ, so this can never collide with or invalidate the
  # existing citing-works chain. Single-active-granularity, same as that
  # chain (not cross()'d over nli_granularities) -- nli_scores_qa_data
  # below resolves whichever granularities actually have data the same way
  # it already does for citing-works scores.
  #
  # RUNS AS PART OF A BARE tar_make() -- nli_scores_qa_data below takes
  # nli_scores_keypaper_evidence as a bare (non-pattern) argument purely to
  # establish the DAG dependency (same convention llm_verification_parquet
  # already uses for nli_scores_by_claim_evidence), so it flows into the QA
  # report automatically. This calls the same live RunPod host pool as the
  # citing-works chain -- a plain tar_make()/tar_make(names="report_fact_checker")
  # now dispatches real key-paper NLI classification calls too, not just the
  # main citing-works corpus. Use tar_make(names = ..., shortcut = TRUE) to
  # render against on-disk data without triggering a fresh run, same escape
  # hatch documented for llm_verification_parquet.
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
  # Same scratch-then-consolidate split as the citing-works chain above.
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
  ),
  # Target 2h4b' (QA, key papers): full-coverage LLM verification of key
  # papers — QA sanity check, NOT the main Phase 2 corpus. Reviews EVERY key
  # paper's NLI-scored pair (the same relation == "keypaper" snowball set
  # nli_scores_keypaper_evidence itself scores), irrespective of NLI's own
  # label/confidence — unlike the main citing-works chain above, which is
  # routed by nli_labels/nli_certainty purely for cost control, key papers
  # are a small, bounded, high-importance set where every one is worth an
  # independent LLM check. See R/build_llm_verification_keypaper_parquet.R
  # for the full design (in particular why it duplicates the orchestration
  # loop rather than calling build_llm_verification_parquet() — that
  # function was only just stabilized against a pair_id collision bug and
  # shouldn't be touched again for an unrelated variant). Writes to its own
  # output/llm_verification/scores_keypaper/ root — never collides with or
  # invalidates the main citing-works output tree.
  #
  # NEW PAID API SURFACE, same caution as llm_verification_parquet and
  # nli_scores_keypaper_evidence themselves: a plain tar_make()/
  # tar_make(names = "report_fact_checker") now also dispatches real
  # OpenRouter calls for every key paper, not just the routed citing-works
  # subset. Use tar_make(names = ..., shortcut = TRUE) to render against
  # on-disk data without triggering a fresh run.
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
  # Target 2h4d: NLI fine-tuning training data (TD_NLI_training.qmd) — reads
  # only already-built output/llm_verification/scores* data (no new LLM/API
  # calls). Single-active-granularity, same scope as llm_verification_parquet
  # itself (not cross()'d over nli_granularities). Hive-partitioned
  # granularity=<g>/nli_config=<cfg>/assessment=<id>/ — the SAME scheme
  # output/nli_scores_evidence and friends already use, not Phase 2's own
  # (llm_config/assessment/nli_route/km/bm); llm_config is carried through
  # as a plain column instead, passed in explicitly as llm_verification_active
  # rather than read back from llm_verification_parquet/
  # llm_verification_keypaper_parquet's own data — those paths are already
  # scoped INSIDE a `llm_config=<val>/` partition directory, so Arrow does
  # not reconstruct that segment as a column when reading at that path
  # level (confirmed directly: "Column `llm_config` doesn't exist"), same
  # fix build_llm_verification_qa_data.R already uses for its own llm_active
  # handling. See R/build_nli_training_data.R.
  #
  # Deliberately does NOT take llm_verification_parquet (the main citing-works
  # Phase 2 chain) as a tracked pattern dependency, only
  # llm_verification_keypaper_parquet -- an assessment can have real
  # snowball/keypaper data (and be worth pulling keypaper-derived training
  # rows from) long before its full citing-works corpus has been scored
  # through Phase 1 + Phase 2 (a much bigger, separately-gated spend; see
  # TD_NLI_training.qmd). Taking llm_verification_parquet as a real pattern
  # dependency would force targets to build that assessment's ENTIRE
  # citing-works chain (Phase 1 NLI scoring of every citing work, then Phase
  # 2 LLM review of whatever gets flagged) just to compute this target, even
  # for an assessment nobody has asked to score that way yet -- confirmed
  # this would happen for IAS specifically (its refs/works/snowball,
  # including the keypaper partition, already exist on disk; nothing
  # NLI/LLM-related does). Instead the main-corpus path is *computed*
  # (mirrors build_llm_verification_parquet()'s own output_path formula)
  # rather than taken from the tracked target, so it carries no targets
  # dependency at all -- build_nli_training_data()'s own has_data() check
  # (already needed for the ordinary "nothing routed yet" case) handles a
  # not-yet-existing path exactly the same as an empty one. An assessment
  # whose citing-works chain already exists (GA1) still gets full benefit
  # from it once built; one that doesn't (IAS, for now) simply contributes
  # keypaper-only rows until/unless its citing-works chain is run later.
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
  # Target 2h4e: fine-tune the active nli config's model, IFF that config's
  # own train: field is true (default false) -- see R/build_nli_finetuned_model.R
  # for the full "why a real train:true/false gate, not just running
  # train_nli.py by hand" reasoning. A real local CPU training run (~tens of
  # minutes; see scripts/training/train_nli.py's own module docstring),
  # opt-in per config so a bare tar_make() never triggers one by surprise.
  #
  # nli_training_data is passed as a bare (non-pattern) argument purely to
  # establish the DAG dependency -- same convention nli_scores_qa_data/
  # llm_verification_qa_data already use for their own upstream
  # dependencies, needed here because nli_training_data branches per
  # assessment (pattern = map(assessment, ...)) while nli_finetuned_model is
  # a single, non-branching target, so a real pattern= dependency isn't
  # possible. build_nli_finetuned_model() never reads this argument's value
  # -- train_nli.py reads output/nli_training directly off disk at runtime
  # -- it exists only so editing R/build_nli_training_data.R (e.g. the
  # real_refutes() filter) or re-running nli_training_data for any
  # assessment correctly marks nli_finetuned_model outdated too, rather than
  # silently training on stale data the next time train:true triggers it.
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
