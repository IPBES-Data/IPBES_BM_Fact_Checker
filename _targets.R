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
    "ellmer",
    "future",
    "future.apply",
    "xml2",
    "stringr"
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
  # Two hand-authored conceptual workflows are kept: `_nli` is the active NLI
  # scoring approach; `_lm` is the parked LLM-comparison approach (reference).
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
  tar_target(
    mmd_workflow_lm,
    "input/mmd/workflow_lm.mmd",
    format = "file"
  ),
  tar_target(
    diagram_workflow_lm,
    render_mmd(mmd_workflow_lm),
    format = "file"
  ),

  # Pipeline diagram — auto-generated from the live tar_mermaid() DAG (TD
  # layout, no status colours). Writes input/mmd/pipeline_nli.mmd. The parked
  # LLM-comparison DAG is kept as a frozen snapshot in pipeline_lm.mmd.
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
  tar_target(
    pipeline_lm,
    "input/mmd/pipeline_lm.mmd",
    format = "file"
  ),
  tar_target(
    diagram_pipeline_lm,
    render_mmd(pipeline_lm),
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
  # PARKED (LLM-comparison approach): consumed only by alignement_scores_run_specs.
  # tar_target(analysis_list, yaml::read_yaml(config_file)[["analysis"]]),
  tar_target(
    fulltext_list,
    lapply(yaml::read_yaml(config_file)[["assessments"]], function(a) {
      list(assessment_id = a[["id"]], enabled = isTRUE(a[["full_text"]]))
    })
  ),
  # PARKED (LLM-comparison approach): prompt files feed only the alignement targets.
  # tar_target(
  #   system_prompt_file,
  #   "input/prompts/system_prompt.md",
  #   format = "file"
  # ),
  # tar_target(
  #   truth_wrapper_file,
  #   "input/prompts/truth_wrapper.md",
  #   format = "file"
  # ),
  # tar_target(
  #   citing_wrapper_file,
  #   "input/prompts/citing_wrapper.md",
  #   format = "file"
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

  # ==========================================================================
  # PARKED — LLM-comparison approach (truth/citing prompts + ellmer/OpenRouter
  # alignement scoring). Superseded by the NLI approach (nli_scores_parquet
  # below). Source files (R/build_prompts_*.R, R/build_alignement_*.R,
  # R/alignement_schema.R) and the input/prompts/*.md files are kept on disk so
  # this chain can be un-parked by uncommenting these targets (plus the
  # analysis_list, system_prompt_file, truth_wrapper_file, citing_wrapper_file
  # targets above and the analysis: block in input/config.yaml).
  # --------------------------------------------------------------------------
  # # Target 2g: Truth prompts — one structured-JSON prompt per (assessment, KM, BM).
  # tar_target(
  #   prompts_truth_parquet,
  #   build_prompts_truth_parquet(
  #     assessment,
  #     key_messages_parquet,
  #     sections_parquet,
  #     "output/prompts/truth"
  #   ),
  #   pattern = map(assessment, key_messages_parquet, sections_parquet),
  #   format = "file"
  # ),
  #
  # # Target 2h: Citing prompts — one structured-JSON prompt per citing work.
  # tar_target(
  #   prompts_citing_parquet,
  #   build_prompts_citing_parquet(
  #     assessment,
  #     works_citing_parquet,
  #     "output/prompts/citing"
  #   ),
  #   pattern = map(assessment, works_citing_parquet),
  #   format = "file"
  # ),
  #
  # # Target 2i: Alignement run specs — per-run config expanded into a list.
  # tar_target(
  #   alignement_scores_run_specs,
  #   build_alignement_scores_run_specs(
  #     analysis_list,
  #     assessment,
  #     prompts_truth_parquet,
  #     prompts_citing_parquet
  #   ),
  #   iteration = "list"
  # ),
  #
  # # Target 2j: Alignement scores — score citing prompts against truth prompts.
  # tar_target(
  #   alignement_scores_parquet,
  #   build_alignement_scores_parquet(
  #     alignement_scores_run_specs,
  #     system_prompt_file,
  #     truth_wrapper_file,
  #     citing_wrapper_file,
  #     output_root = "output/alignement_scores"
  #   ),
  #   pattern = map(alignement_scores_run_specs),
  #   format = "file"
  # ),
  # ==========================================================================

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
    format = "file"
  ),

  # Target 2h (NLI): NLI alignement scores — classify each citing work against
  # each BM sentence (SUPPORTS / REFUTES / NOT_ENOUGH_INFO) via a zero-shot NLI
  # model served on RunPod. Consumes nli_ready_parquet (work × BM sentence
  # cross-join with approx_tokens). Rows where approx_tokens > max_length are
  # skipped; see NEXT_STEPS.md for the planned chunking approach.
  tar_target(
    nli_scores_parquet,
    build_nli_scores_parquet(
      assessment,
      nli_ready_parquet,
      nli_config,
      nli_active,
      "output/nli_scores"
    ),
    pattern = map(assessment, nli_ready_parquet),
    format = "file"
  ),

  # Commented out: render report once QMD is migrated to consume output/refs/ and output/sections/
  # tar_target(
  #   report,
  #   {
  #     quarto::quarto_render("IPBES_KnowledgsDiscovery.qmd")
  #     "IPBES_KnowledgsDiscovery.html"
  #   },
  #   format = "file"
  # )

  NULL
)
