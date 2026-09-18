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
  # Collection branches per assessment, and each branch is an independent
  # multi-hour OpenAlex fetch (see snowball_parquet's error = "continue"), so
  # crew lets the assessments proceed concurrently instead of serially.
  #
  # Sized to the ASSESSMENT COUNT. It used to be sized to the active NLI
  # pool's host count, which was right while this script also held
  # score_one_claim()'s per-host lock dispatch -- that moved to
  # _targets_factcheck.R and _targets_training.R, which size their own
  # controllers that way. Nothing here talks to the NLI pool any more, so the
  # coupling would just be misleading; crew never spawns more workers than
  # there are ready branches anyway. Read directly from config.yaml at
  # pipeline-definition time, not via a cached target -- worker-pool sizing,
  # not part of the DAG's correctness. Falls back to 1 if config is missing
  # or malformed at parse time.
  controller = crew::crew_controller_local(
    workers = tryCatch({
      n <- length(yaml::read_yaml("input/config.yaml")[["assessments"]])
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
    diagram_pipeline_main,
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
  # ---------------------------------------------------------------------------
  # This project is now COLLECTION ONLY: LOD -> refs -> zotero -> works ->
  # snowball -> works_citing. Everything downstream lives in its own project
  # (see _targets.yaml and TODO_PIPELINE_SPLIT.md):
  #
  #   _targets_factcheck.R   citing works -> NLI -> LLM verification
  #   _targets_training.R    key papers -> NLI -> LLM -> training set -> fine-tune
  #   _targets_reporting.R   everything that renders
  #
  # It KEEPS THE ORIGINAL _targets/ store deliberately. A fresh store would
  # make every target outdated by definition, and download_works() unlink()s
  # its output before refetching while build_snowball_parquet() has no
  # existence check at all -- re-running them would cost days of OpenAlex time
  # AND produce a different corpus from the one every existing score was
  # computed against. So targets were DELETED from this script as they moved
  # out; the store's metadata survives untouched.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # PARKED: the original per-sentence segmentation arm.
  #
  # nli_ready_parquet / nli_claim_units / nli_claim_units_flat, plus their
  # consumer nli_scores_by_claim, are commented out below rather than deleted.
  # NEXT_STEPS.md documents this as a parallel SECOND approach to the
  # evidence segmentation -- "not a replacement" -- so the two can be scored
  # and compared side by side; TD_BM_NLI_approach.qmd does not cover this arm
  # at all, which makes NEXT_STEPS.md and this block its only record.
  #
  # Why parked here rather than moved to _targets_factcheck.R with the rest of
  # the scoring chain: nothing consumes them (nli_scores_by_claim has been
  # commented out for a long time, and output/nli_scores/ is 0 B), and
  # output/nli_ready/ does not exist at all -- so a fresh factcheck store would
  # build a second large cross-join for output no active target reads.
  #
  # To revive: move this block into _targets_factcheck.R, which already has
  # every target it needs (assessment, key_messages_parquet,
  # works_citing_parquet, max_length, nli_config, nli_pool_health).
  # build_nli_claim_units() and score_one_claim() are shared with the evidence
  # chain and were never removed; only R/build_nli_ready_parquet.R is otherwise
  # orphaned source.
  # ---------------------------------------------------------------------------
  # # Target 2g (NLI-ready): NLI-ready parquet — BM descriptions split into
  # # sentences (falling back to bm_label when bm_description is absent), crossed
  # # with the cleaned (premise = title + abstract) of each citing work.
  # # One row per (work × BM sentence); sentence_number preserves original order.
  # tar_target(
  # nli_ready_parquet,
  # build_nli_ready_parquet(
  # assessment,
  # key_messages_parquet,
  # works_citing_parquet,
  # workers,
  # "output/nli_ready"
  # ),
  # pattern = map(assessment, key_messages_parquet, works_citing_parquet),
  # format = "file",
  # # Already forks its own `workers` mclapply processes internally, each
  # # holding a work x sentence cross-join with full title+abstract text in
  # # memory. Dispatching the GA1 and IAS branches to separate crew workers
  # # ON TOP of that internal forking stacks two layers of parallelism on
  # # the most memory-hungry step in the pipeline -- observed to trigger OOM
  # # kills when it lands alongside nli_overview_data/llm_verification_parquet.
  # # deployment = "main" runs branches one at a time in the orchestrating
  # # process instead; NLI scoring's own crew concurrency (sized to the
  # # RunPod host count) is untouched. garbage_collection = TRUE forces a
  # # gc() after each branch so its memory is reclaimed before the next one
  # # starts, rather than accumulating across the sequential run.
  # deployment = "main",
  # garbage_collection = TRUE
  # ),
  # # Target 2h1: Claim-units to score, per assessment.
  # tar_target(
  # nli_claim_units,
  # build_nli_claim_units(assessment, nli_ready_parquet, max_length),
  # pattern = map(assessment, nli_ready_parquet),
  # iteration = "list"
  # ),
  # # Target 2h2: Flatten to one element per claim across ALL assessments, so
  # # the next target can branch one-target-per-claim.
  # tar_target(
  # nli_claim_units_flat,
  # unlist(nli_claim_units, recursive = FALSE),
  # iteration = "list"
  # ),
  # # Target 2h3: Score one claim per branch. error = "continue": a failing
  # # claim is reported live and marked failed; every other claim's branch
  # # proceeds independently. Re-running tar_make() only retries failed/new
  # # claims (plus targets' own branch caching skips already-succeeded ones
  # # whose inputs haven't changed).
  # # Commented out: this per-sentence chain isn't consumed by the report
  # # (nli_overview_data reads nli_scores_by_claim_evidence only — see that
  # # target's comment) and shares nli_config/nli_pool_health/score_one_claim
  # # with the evidence chain, so a bare tar_make() would dispatch both against
  # # the same live RunPod pool. Uncomment only if you deliberately want the
  # # per-sentence approach scored too.
  # # tar_target(
  # #   nli_scores_by_claim,
  # #   score_one_claim(nli_claim_units_flat, nli_config, nli_active, nli_pool_health),
  # #   pattern = map(nli_claim_units_flat),
  # #   format = "file",
  # #   error = "continue"
  # # ),
  #

  NULL
)