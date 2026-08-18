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

list(
  # Diagrams — re-render SVGs whenever .mmd source files change.
  # workflow_nli.mmd is the active, hand-authored conceptual workflow;
  # its parked `_lm` counterpart (the earlier single-phase LLM-comparison
  # approach) was removed once that approach's source was deleted outright
  # rather than kept parked — see TD_LLM_approach.qmd for the design record.
  tar_target(
    mmd_workflow_nli,
    "input/mmd/workflow_nli.mmd",
    format = "file"
  ),
  tar_target(
    diagram_workflow_nli,
    render_mmd(mmd_workflow_nli),
    format = "file"
  ),

  # Pipeline diagram — auto-generated from the live tar_mermaid() DAG (TD
  # layout, no status colours). Writes input/mmd/pipeline_nli.mmd.
  tar_target(
    r_files,
    c("_targets.R", list.files("R", full.names = TRUE)),
    format = "file"
  ),
  tar_target(
    pipeline_mmd,
    build_pipeline_mmd(r_files),
    format = "file"
  ),
  tar_target(
    diagram_pipeline_nli,
    render_mmd(pipeline_mmd),
    format = "file"
  ),

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
  tar_target(sections_sparql, "queries/sections.sparql", format = "file"),
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

  # Target 2b: DB2 — section content written directly to output/sections/
  tar_target(
    sections_parquet,
    build_sections_parquet(
      sparql_url,
      assessment,
      ttl_path,
      sections_sparql,
      "output/sections"
    ),
    pattern = map(assessment, ttl_path),
    format = "file"
  ),

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
    format = "file"
  ),

  # Target 2f: Citing works — papers citing the seed works, fetched per km/bm
  tar_target(
    works_citing_parquet,
    build_works_citing_parquet(
      assessment,
      snowball_parquet,
      "output/works_citing"
    ),
    pattern = map(assessment, snowball_parquet),
    format = "file"
  ),

  # Target 2f2: Publications-per-year-by-BM figure — aggregated across every
  # assessment's works_citing branches (no `pattern =` here: targets combines
  # all dynamic branches of works_citing_parquet into one vector).
  tar_target(
    fig_pub_per_year,
    build_fig_pub_per_year(works_citing_parquet, "output/figures"),
    format = "file"
  ),

  # Target 2f3: Key-paper overlap table — key/seed papers (works_parquet)
  # referenced in more than one background message. Aggregated across every
  # assessment's works branches, same aggregation pattern as fig_pub_per_year.
  tar_target(
    overlap_key_paper_table,
    build_overlap_key_paper_table(works_parquet, "output/tables"),
    format = "file"
  ),

  # Target 2f4/2f5: Citing-paper overlap tables — citing papers
  # (works_citing_parquet) published after 2018, referenced from more than 5
  # background messages. "sub_messages" and "background_messages" group
  # identically under the active schema (no sub-message level) — kept as two
  # targets only for report-section continuity with the legacy qmd; the
  # background_messages variant additionally carries the abstract column.
  tar_target(
    overlap_after_2018_sub_messages_table,
    build_overlap_after_2018_sub_messages_table(works_citing_parquet, 2018, "output/tables"),
    format = "file"
  ),
  tar_target(
    overlap_after_2018_background_messages_table,
    build_overlap_after_2018_background_messages_table(works_citing_parquet, 2018, "output/tables"),
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
  # sentence, {5.4.1, 5.4.2}) rather than per sentence. Same column schema and
  # separate output root (output/nli_ready_evidence), so the same claim-unit
  # and scoring machinery consumes it unchanged. See NEXT_STEPS.md.
  tar_target(
    nli_ready_evidence_parquet,
    build_nli_ready_evidence_parquet(
      assessment,
      key_messages_parquet,
      works_citing_parquet,
      workers,
      "output/nli_ready_evidence"
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
    build_nli_claim_units(assessment, nli_ready_parquet, nli_config),
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
    build_nli_claim_units(assessment, nli_ready_evidence_parquet, nli_config),
    pattern = map(assessment, nli_ready_evidence_parquet),
    iteration = "list"
  ),
  tar_target(
    nli_claim_units_evidence_flat,
    unlist(nli_claim_units_evidence, recursive = FALSE),
    iteration = "list"
  ),
  tar_target(
    nli_scores_by_claim_evidence,
    score_one_claim(
      nli_claim_units_evidence_flat,
      nli_config,
      nli_active,
      nli_pool_health,
      output_root = "output/nli_scores_evidence"
    ),
    pattern = map(nli_claim_units_evidence_flat),
    format = "file",
    error = "continue"
  ),

  # Target 2h4: NLI overview data — per-assessment label/confidence/alignment
  # summary tables, for the report and its BM explorer. Deliberately wired to
  # the EVIDENCE-segmentation scoring chain (nli_scores_by_claim_evidence /
  # output/nli_scores_evidence), not the original per-sentence one
  # (nli_scores_by_claim / output/nli_scores): the two scoring targets share
  # score_one_claim(), so any change to that file marks BOTH outdated
  # regardless of which approach is actually being run, and the per-sentence
  # chain is far less complete (14/725 claims scored at time of writing).
  # Wiring the report to it meant tar_make(report_fact_checker) could
  # transitively try to dispatch ~700 unscored per-sentence claims through
  # the same host pool as a live evidence scoring run — see git history for
  # the incident this comment is warning about. Reads directly from the
  # on-disk output path rather than individual per-claim file paths;
  # nli_scores_by_claim_evidence is listed as an argument purely to
  # establish the DAG dependency (so this target waits for evidence scoring
  # and invalidates when its output changes).
  tar_target(
    nli_overview_data,
    build_nli_overview_data(
      assessment,
      file.path(
        "output/nli_scores_evidence",
        paste0("nli_config=", nli_active),
        paste0("assessment=", assessment$id)
      ),
      nli_active,
      works_citing_parquet,
      "output/tables",
      nli_scores_by_claim_evidence
    ),
    pattern = map(assessment, works_citing_parquet),
    format = "file",
    # collect()s the entire per-assessment nli_scores_evidence table (every
    # row, not just REFUTES/uncertain) to build the summary tables — for GA1
    # alone that's ~1.9M rows. Running GA1's and IAS's branches on separate
    # crew workers doubles that peak; deployment = "main" processes them one
    # at a time instead. Contributed to an observed OOM alongside
    # llm_verification_parquet/nli_ready_parquet running concurrently.
    deployment = "main",
    garbage_collection = TRUE
  ),

  # Target 2h4a: Per-claim candidate scope for Phase 2's `subset: "sm"`
  # configs — see R/build_llm_candidate_scope_parquet.R and
  # TD_NLI_LLM_two_phase.qmd. Chains refs_parquet's `sm` (sub-chapter id) ->
  # seed doi -> seed OpenAlex work id -> citing work (via the existing
  # snowball edges) to produce, per evidence-segmented claim, an allow-list
  # of citing works actually tied to its own sub-chapter rather than the
  # whole BM's. Reads only already-existing, unmodified targets
  # (key_messages_parquet, refs_parquet, works_parquet, snowball_parquet,
  # nli_ready_evidence_parquet) and makes no network/API calls of its own —
  # adding it does not invalidate any of Phase 1's NLI chain or the
  # download/snowball steps upstream of it. Always computed regardless of
  # which llm_verification config is active; `subset: "all"` configs simply
  # never read its output.
  tar_target(
    llm_candidate_scope_parquet,
    build_llm_candidate_scope_parquet(
      assessment,
      key_messages_parquet,
      refs_parquet,
      works_parquet,
      snowball_parquet,
      nli_ready_evidence_parquet,
      "output/llm_candidate_scope"
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
      nli_scores_by_claim_evidence
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

  # Target 2h3: NLI overview figures — label split (overall/per-KM/per-BM),
  # confidence density, alignment density, per assessment.
  tar_target(
    nli_overview_figures,
    build_nli_overview_figures(nli_overview_data, "output/figures"),
    pattern = map(nli_overview_data),
    format = "file"
  ),

  # Target 2h5: NLI BM explorer — one interactive plotly widget per
  # assessment with a BM-selector dropdown (label distribution, confidence
  # distribution with mean/median, alignment distribution). Written as a
  # self-contained standalone HTML file (embedded via <iframe> in the report)
  # rather than printed in-place, since Quarto's HTML format does not
  # propagate htmlwidget JS dependencies out of a manually cat()-ed
  # knit_print() call inside a results:asis loop — see R/build_nli_bm_explorer.R.
  tar_target(
    nli_bm_explorer_html,
    save_nli_bm_explorer(nli_overview_data, "output/tables"),
    pattern = map(nli_overview_data),
    format = "file"
  ),

  # Target 2h6: REFUTES funnel — a 4-level sieve of distinct citing works per
  # (km, bm): snowball corpus -> NLI REFUTES-certain -> LLM-confirmed REFUTES
  # -> + sufficient evidence, each a subset of the previous. Pure local
  # arrow/dplyr over already-scored parquet (no network/GPU calls); reads
  # llm_verification_parquet only as an already-built dependency, same
  # DAG-dependency-only convention as nli_scores_by_claim_evidence elsewhere.
  # See R/build_refutes_funnel_data.R and IPBES_REFUTES_Report.qmd.
  tar_target(
    refutes_funnel_data,
    build_refutes_funnel_data(
      assessment,
      works_citing_parquet,
      file.path(
        "output/nli_scores_evidence",
        paste0("nli_config=", nli_active),
        paste0("assessment=", assessment$id)
      ),
      llm_verification_parquet,
      "output/tables"
    ),
    pattern = map(assessment, works_citing_parquet, llm_verification_parquet),
    format = "file",
    # collect()s a full per-assessment nli_scores_evidence table, same OOM
    # caution as nli_overview_data.
    deployment = "main",
    garbage_collection = TRUE
  ),

  tar_target(
    refutes_funnel_figures,
    build_refutes_funnel_figures(refutes_funnel_data, "output/figures"),
    pattern = map(refutes_funnel_data),
    format = "file"
  ),

  tar_target(
    refutes_funnel_tables,
    build_refutes_funnel_tables(refutes_funnel_data, "output/tables"),
    pattern = map(refutes_funnel_data),
    format = "file"
  ),

  tar_target(
    qmd_refutes_funnel,
    "IPBES_REFUTES_Report.qmd",
    format = "file"
  ),

  # Rendered once per assessment via Quarto's params:/execute_params=
  # mechanism (this project's first use of it — every other multi-output
  # render, td_doc_html, branches over distinct source files instead of one
  # file rendered N times). deployment = "main" avoids two quarto_render()
  # calls against the same source .qmd racing on separate crew workers.
  tar_target(
    report_refutes_funnel_html,
    {
      # Bare references only to establish DAG edges — the qmd re-reads
      # everything via tar_read()/readRDS(); quarto_render() re-reads the
      # qmd from disk.
      qmd_refutes_funnel
      refutes_funnel_data
      refutes_funnel_figures
      refutes_funnel_tables
      out <- paste0("IPBES_REFUTES_Report_", assessment$id, ".html")
      quarto::quarto_render(
        "IPBES_REFUTES_Report.qmd",
        output_file = out,
        execute_params = list(assessment_id = assessment$id)
      )
      out
    },
    pattern = map(assessment, refutes_funnel_data, refutes_funnel_figures, refutes_funnel_tables),
    format = "file",
    deployment = "main"
  ),

  tar_target(
    qmd_fact_checker,
    "IPBES_Fact_Checker.qmd",
    format = "file"
  ),

  tar_target(
    claude_md,
    "CLAUDE.md",
    format = "file"
  ),

  # Technical Design (TD_<name>.qmd) documents — each is a single
  # self-contained file (Quarto YAML header + prose in the same file) so
  # they render with consistent styling and are openable as standalone
  # HTML pages linked from the report. Branched over td_doc_names rather
  # than six hand-written targets so adding a new TD doc is a one-line
  # change (plus the new .qmd file itself).
  tar_target(
    td_doc_names,
    c(
      "TD_targets",
      "TD_BM_NLI_approach",
      "TD_LLM_approach",
      "TD_NLI_LLM_two_phase",
      "TD_NLI_training",
      "TD_formatting"
    )
  ),

  tar_target(
    td_doc_qmd,
    paste0(td_doc_names, ".qmd"),
    pattern = map(td_doc_names),
    format = "file"
  ),

  tar_target(
    td_doc_html,
    {
      # diagram_workflow_nli/diagram_pipeline_nli are referenced only to
      # establish a DAG dependency: TD_targets.qmd embeds these rendered
      # figures via a plain markdown image link, which targets can't see
      # into — without this, regenerating a diagram would silently NOT
      # invalidate the HTML that embeds it. Broadcast to every branch (not
      # mapped), since only one of the several TD docs actually uses them.
      diagram_workflow_nli
      diagram_pipeline_nli
      quarto::quarto_render(td_doc_qmd)
      sub("\\.qmd$", ".html", td_doc_qmd)
    },
    pattern = map(td_doc_qmd),
    format = "file"
  ),

  tar_target(
    report_fact_checker,
    {
      # All referenced only to establish DAG dependencies (targets detects
      # deps by static-scanning this expression) — the qmd itself re-reads
      # nli_bm_explorer_html's and td_doc_html's actual values via
      # tar_read(), and quarto_render() re-reads the qmd from disk by path.
      # Without nli_bm_explorer_html/td_doc_html/report_refutes_funnel_html,
      # tar_make() would happily render the report against stale/missing
      # dependents rather than building them first. Without qmd_fact_checker
      # (file-hash tracked), targets has no visibility into the qmd's own
      # content — editing the qmd (prose, code chunks, or YAML header, e.g.
      # embed-resources) would silently NOT invalidate this target.
      nli_bm_explorer_html
      report_refutes_funnel_html
      qmd_fact_checker
      td_doc_html
      quarto::quarto_render("IPBES_Fact_Checker.qmd")
      "IPBES_Fact_Checker.html"
    },
    format = "file"
  ),

  # Deployable copy: the report + every TD doc + every per-assessment
  # REFUTES funnel report, each with its _files/ sidecar if it has one, plus
  # CLAUDE.md (TD_targets.qmd links to it by a plain relative path),
  # collected into one self-contained directory. deploy-pages.yml publishes
  # this directory's contents verbatim to the gh-pages branch — it doesn't
  # need its own logic to find which htmls exist or pair them with a
  # _files/ folder.
  tar_target(
    report_output_dir,
    build_report_output_dir(
      report_fact_checker,
      c(td_doc_html, report_refutes_funnel_html),
      claude_md,
      "output/reports"
    ),
    format = "file"
  ),

  NULL
)
