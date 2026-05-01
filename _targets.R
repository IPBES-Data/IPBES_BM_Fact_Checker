library(targets)

Sys.setenv(
  openalexPro.apikey = keyring::key_get("API_openalex")
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
    "jsonlite"
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
  tar_target(assessments_list, config[["assessments"]]),
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
    analysis,
    {
      x <- analysis_list
      names(x) <- vapply(x, `[[`, character(1), "assessment_id")
      x
    },
    iteration = "list"
  ),

  # Target 1: Download TTL files to output/LoD/ (cached on disk)
  tar_target(
    ttl_path,
    download_ttl(assessment),
    pattern = map(assessment),
    format = "file"
  ),

  # SPARQL query files — tracked so downstream targets invalidate when queries change
  tar_target(refs_sparql,         "queries/refs.sparql",         format = "file"),
  tar_target(sections_sparql,     "queries/sections.sparql",     format = "file"),
  tar_target(key_messages_sparql, "queries/key_messages.sparql", format = "file"),

  # Target 2a: DB1 — refs written directly to output/refs/
  tar_target(
    refs_parquet,
    build_refs_parquet(sparql_url, assessment, ttl_path, refs_sparql, "output/refs"),
    pattern = map(assessment, ttl_path),
    format = "file"
  ),

  # Target 2b: DB2 — section content written directly to output/sections/
  tar_target(
    sections_parquet,
    build_sections_parquet(sparql_url, assessment, ttl_path, sections_sparql, "output/sections"),
    pattern = map(assessment, ttl_path),
    format = "file"
  ),

  # Target 2b2: DB3 — KM, BM, and SM descriptive text written directly to output/key_messages/
  tar_target(
    key_messages_parquet,
    build_key_messages_parquet(sparql_url, assessment, ttl_path, key_messages_sparql, "output/key_messages"),
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
    build_works_citing_parquet(assessment, snowball_parquet, "output/works_citing"),
    pattern = map(assessment, snowball_parquet),
    format = "file"
  ),

  # Target 3: Resolved sections — (Author, Year) citations → [WID] OpenAlex IDs
  tar_target(
    resolved_sections_parquet,
    resolve_citations(
      assessment,
      sections_parquet,
      works_parquet,
      zotero_parquet
    ),
    pattern = map(assessment, sections_parquet, works_parquet, zotero_parquet),
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
