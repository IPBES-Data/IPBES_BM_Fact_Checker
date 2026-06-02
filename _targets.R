library(targets)

Sys.setenv(
  API_openalex = keyring::key_get("API_openalex")
)
Sys.setenv(
  API_openrouter = keyring::key_get("API_openrouter")
)

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
    "future.apply"
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
  # Diagrams — re-render SVGs whenever .mmd source files change
  tar_target(
    mmd_workflow,
    "input/mmd/workflow.mmd",
    format = "file"
  ),
  tar_target(
    diagram_workflow,
    render_mmd(mmd_workflow),
    format = "file"
  ),

  # Pipeline diagram — auto-generated from tar_mermaid(), TD layout, no status colours
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
    diagram_pipeline,
    render_mmd(pipeline_mmd),
    format = "file"
  ),

  # Config — split into fine-grained targets so unrelated changes don't cascade
  tar_target(config_file, "input/config.yaml", format = "file"),
  tar_target(config, yaml::read_yaml(config_file)),
  tar_target(sparql_url, config[["sparql_url"]]),
  tar_target(
    assessments_list,
    lapply(config[["assessments"]], function(a) {
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
  tar_target(analysis_list, config[["analysis"]]),
  tar_target(
    fulltext_list,
    lapply(config[["assessments"]], function(a) {
      list(assessment_id = a[["id"]], enabled = isTRUE(a[["full_text"]]))
    })
  ),
  tar_target(
    system_prompt_file,
    "input/prompts/system_prompt.md",
    format = "file"
  ),
  tar_target(
    truth_wrapper_file,
    "input/prompts/truth_wrapper.md",
    format = "file"
  ),
  tar_target(
    citing_wrapper_file,
    "input/prompts/citing_wrapper.md",
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

  # Target 2g: Truth prompts — one structured-JSON prompt per (assessment, KM, BM).
  # Each row carries a nested `sub_messages` list-column (one entry per SM under
  # the BM); each SM has its own `sources` of (section, subsection, content).
  # The `prompt` column is the same data serialised to JSON for the LLM.
  tar_target(
    prompts_truth_parquet,
    build_prompts_truth_parquet(
      assessment,
      key_messages_parquet,
      sections_parquet,
      "output/prompts/truth"
    ),
    pattern = map(assessment, key_messages_parquet, sections_parquet),
    format = "file"
  ),

  # Target 2h: Citing prompts — one structured-JSON prompt per citing work.
  # Flat payload (no nested lists); work-level fields plus KM/BM as ids. The
  # `prompt` column is the JSON string the LLM sees.
  tar_target(
    prompts_citing_parquet,
    build_prompts_citing_parquet(
      assessment,
      works_citing_parquet,
      "output/prompts/citing"
    ),
    pattern = map(assessment, works_citing_parquet),
    format = "file"
  ),

  # Target 2i: Alignement run specs — per-run config expanded into a list
  # of specs (one per analysis.runs[] entry), used to branch the scores target.
  tar_target(
    alignement_scores_run_specs,
    build_alignement_scores_run_specs(
      analysis_list,
      assessment,
      prompts_truth_parquet,
      prompts_citing_parquet
    ),
    iteration = "list"
  ),

  # Target 2j: Alignement scores — score citing prompts against truth prompts
  # via OpenRouter / ellmer. One branch per spec. The wrappers + system prompt
  # form the cached prefix; only the citing JSON varies per call.
  tar_target(
    alignement_scores_parquet,
    build_alignement_scores_parquet(
      alignement_scores_run_specs,
      system_prompt_file,
      truth_wrapper_file,
      citing_wrapper_file,
      output_root = "output/alignement_scores"
    ),
    pattern = map(alignement_scores_run_specs),
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
