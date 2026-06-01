# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an R/Quarto project for IPBES (Intergovernmental Science-Policy Platform on Biodiversity and Ecosystem Services) knowledge discovery. It uses the IPBES Linked Open Data (LOD) to extract the reference hierarchy from assessments, and snowball searching via the OpenAlex API to discover literature published after GA1 (2018).

## Build System

### targets Pipeline (primary)

```r
targets::tar_make()          # run all outdated targets
targets::tar_visnetwork()    # visualise dependency graph
targets::tar_outdated()      # list what needs re-running
```

See [targets.md](targets.md) for full pipeline documentation.

**System dependency:** `fuseki-server` must be on `PATH` when `sparql_url: fuseki` (default). Install with `brew install fuseki`.

**Credentials:** `_targets.R` reads `API_openalex` and `API_openrouter` from the macOS keyring at startup via `keyring::key_get()`. Set them before running `tar_make()`:

```r
keyring::key_set("API_openalex")
keyring::key_set("API_openrouter")
```

**Currently commented out in `_targets.R`:** `fulltext_files`, `alignement_run_specs`, `alignement_parquet`, and the QMD `report` target. These need their commented blocks restored to run end-to-end.

### Quarto Report (legacy)

```bash
quarto render IPBES_KnowledgsDiscovery.qmd
```

The QMD is not yet integrated into the `targets` pipeline (a commented-out render target exists in `_targets.R` for when the migration is complete).

## Architecture

### targets Pipeline Data Flow

```
input/config.yaml
    → output/LoD/<id>.ttl                    (downloaded IPBES LOD Turtle files, gitignored)
    → output/refs/assessment=<id>/           (partitioned by assessment, gitignored)
    → output/sections/assessment=<id>/       (partitioned by assessment, gitignored)
    → output/key_messages/assessment=<id>/   (partitioned by assessment, gitignored)
    → output/zotero/assessment=<id>/         (partitioned by assessment/group id/page, gitignored)
    → output/works/assessment=<id>/km=<km>/bm=<bm>/  (partitioned by assessment/km/bm, gitignored)
    → output/snowball/nodes/assessment=<id>/km=<km>/bm=<bm>/     (partitioned by assessment/km/bm/relation, gitignored)
    → output/snowball/edges/assessment=<id>/km=<km>/bm=<bm>/     (partitioned by assessment/km/bm/edge_type, gitignored)
    → output/snowball/keypaper/assessment=<id>/km=<km>/bm=<bm>/  (partitioned by assessment/km/bm, gitignored)
    → output/works_citing/assessment=<id>/km=<km>/bm=<bm>/       (partitioned by assessment/km/bm, gitignored)
    → output/prompts/truth/assessment=<id>/                      (one rendered prompt per (KM, BM), gitignored)
    → output/prompts/citing/assessment=<id>/km=<km>/bm=<bm>/      (one rendered prompt per citing work, gitignored)
    → output/alignement_scores/assessment=<id>/run_id=<run_id>/   (LLM alignement scores per citing work, gitignored)
    → output/fulltext/assessment=<id>/                            (XML/PDF/missing files per work, gitignored)
    → output/resolved_sections/assessment=<id>/ (partitioned by assessment, gitignored)
    → output/alignement/assessment=<id>/run_id=<run_id>/  (partitioned by assessment/run_id/km/model/temperature/relation/replicate, gitignored)
```

The `sparql_url` key in `input/config.yaml` controls the SPARQL backend:
- `"fuseki"` — each parquet builder starts an in-memory Fuseki session on a deterministic port and POSTs the assessment's TTL into the named graph returned by `assessment_graph_iri(id)`
- Any URL — the parquet builders query that endpoint directly; no Fuseki lifecycle needed

Config is split into fine-grained targets (`sparql_url`, `assessments_list`, `analysis_list`) so that adding new config sections or changing one entry does not invalidate other targets. Each top-level config key maps to its own intermediate target.

**Per-assessment named graphs:** All three SPARQL queries wrap their patterns in `GRAPH <%GRAPH_IRI%> { ... }`. The placeholder is substituted at query time by `read_sparql_query()` in [R/extract_lod.R](R/extract_lod.R) using `assessment_graph_iri()` from [R/branch_helpers.R](R/branch_helpers.R) (currently `http://ontology.ipbes.net/report/<id>`). The same code path works against local Fuseki (TTL loaded into that graph at startup) and a shared IPBES endpoint hosting all assessments under the same IRI convention — switching backends is just a `sparql_url:` change in [input/config.yaml](input/config.yaml). If IPBES adopts a different convention, edit `assessment_graph_iri()` in one place.

### Legacy QMD Data Flow

```
input/Query_Submessage_ref_GA.csv
    → output/key_works.rds          (OpenAlex metadata for GA1 reference list)
    → output/snowballs/<id>.rds     (per-paper snowball results, gitignored)
    → output/nodes/ (parquet)       (all papers found, partitioned by bm/sm, gitignored)
    → output/edges/ (parquet)       (citation edges, partitioned by bm/sm, gitignored)
    → output/overlap_*.rds/.html    (overlap analysis results)
```

### Key Design Patterns

- **targets caching**: each target is re-run only when its inputs change. Delete `_targets/` to force a full rebuild.
- **Fine-grained config**: `config` is split into `sparql_url`, `assessments_list`, and `analysis_list` targets so unrelated config sections don't cascade invalidation.
- **Fuseki lifecycle**: started and stopped inside the parquet builders; cleanup is idempotent and handled by `on.exit()`.
- **Assessment branching**: `assessment` is the branch key, so adding a new assessment only computes the new branch.
- **Separated materialization**: refs, sections, key_messages, Zotero, works, fulltext, and alignement scores are all built independently; there is no cached combined `lod_data` object.
- **Parquet databases**: partitioned by assessment only, queried lazily with `arrow::open_dataset()` + `dplyr` verbs, collected into memory only when needed.
- **SPARQL queries as files**: all three SPARQL queries live in `queries/*.sparql` and are tracked as `format = "file"` targets (`refs_sparql`, `sections_sparql`, `key_messages_sparql`) — editing a query file invalidates only its downstream parquet target.
- **Legacy QMD caching**: uses `file.exists(fn)` checks. Delete the relevant `.rds` or parquet directory to force recomputation.

### R Files (targets pipeline)

| File | Target(s) | Purpose |
|------|-----------|---------|
| `R/download_works.R` | `works_parquet` | Fetch OpenAlex works via `openalexPro::pro_fetch()`, join with refs on DOI to assign km/bm, write to `output/works/assessment=<id>/km=<km>/bm=<bm>/` |
| `R/build_snowball_parquet.R` | `snowball_parquet` | Snowball search via `openalexSnowball::pro_snowball()` per km/bm; writes nodes and edges to `output/snowball/` |
| `R/build_works_citing_parquet.R` | `works_citing_parquet` | Filter snowball nodes to `relation == "citing"`; write to `output/works_citing/` partitioned by assessment/km/bm |
| `R/download_zotero.R` | `zotero_parquet` | Download Zotero group items to `output/zotero/assessment=<id>/` using refs parquet |
| `R/download_ttls.R` | `ttl_path` | Download TTL files to `output/LoD/`; SHA-checked against GitHub to skip re-download |
| `R/manage_fuseki.R` | helpers | Start/stop Fuseki sessions and resolve endpoints |
| `R/branch_helpers.R` | helpers | Assessment IDs and branch output paths |
| `R/render_diagrams.R` | `mmd_workflow`, `diagram_workflow`, `pipeline_mmd`, `diagram_pipeline` | Render Mermaid `.mmd` sources to SVG; `build_pipeline_mmd()` auto-generates a TD pipeline diagram from `tar_mermaid()` |
| `R/alignement_schema.R` | helpers for `alignement_parquet` | `ellmer` structured-output schema for OpenRouter alignment scoring |
| `R/extract_lod.R` | `refs_parquet`, `sections_parquet`, `key_messages_parquet` | SPARQL extraction helpers; reads queries from `queries/*.sparql` |
| `R/write_refs_parquet.R` | `refs_parquet` | Build DB1 directly into `output/refs/assessment=<id>/` |
| `R/write_sections_parquet.R` | `sections_parquet` | Build DB2 directly into `output/sections/assessment=<id>/` |
| `R/write_key_messages_parquet.R` | `key_messages_parquet` | Build DB3 directly into `output/key_messages/assessment=<id>/` |
| `R/resolve_citations.R` | `resolved_sections_parquet` | Replace `(Author, Year)` citations with OpenAlex W-IDs |
| `R/build_prompts_truth_parquet.R` | `prompts_truth_parquet` | Render one "truth document" prompt per `(assessment, KM, BM)` from `input/prompts/truth.md`; aggregates KM/BM/SM text + section content into a parquet at `output/prompts/truth/assessment=<id>/` |
| `R/build_prompts_citing_parquet.R` | `prompts_citing_parquet` | Render one candidate-paper prompt per row of `works_citing_parquet` from `input/prompts/citing.md`; work-level placeholders only (KM/BM passed as ids). Writes to `output/prompts/citing/assessment=<id>/km=<km>/bm=<bm>/` |
| `R/build_alignement_scores_parquet.R` | `alignement_scores_run_specs`, `alignement_scores_parquet` | Per `analysis.runs[]` config, score the first `n_citing` (or all, if `0`) citing prompts against the matching truth prompt via OpenRouter / ellmer. Uses shared `(system + truth)` prefix so the provider's automatic prefix caching kicks in. Writes to `output/alignement_scores/assessment=<id>/run_id=<run_id>/` |
| `R/build_fulltext.R` | `fulltext_files` *(currently commented out)* | Download Grobid XML or PDF for each work in `works_citing`; gated by per-assessment `full_text:` flag in config (surfaced via the `fulltext_list` target); validates content before writing; pre-flight credit check via `openalexPro::pro_rate_limit_status()`; parallel workers with `future.apply`; writes to `output/fulltext/assessment=<id>/` |
| `R/build_alignement_parquet.R` | `alignement_run_specs`, `alignement_parquet` *(currently commented out)* | Expand per-run alignment specs, keep unique `run_id` values and KM lists inside each run, and score capped snowball works against each KM with `ellmer::parallel_chat_structured()` |

### Terminology

- **KM** = Key Message (e.g. `"A."`)
- **BM** = Background Message (e.g. `"A1"`)
- **SM** = Sub-Message
- **LOD** = Linked Open Data — IPBES assessments in RDF/Turtle format
- **key papers** = GA1 references used as snowball seeds (`oa_input == TRUE` in QMD nodes)
- **non-key papers** = papers discovered via snowball (`oa_input == FALSE`)

### Gitignored Intermediate Outputs

- `output/LoD/` — cached TTL files
- `output/refs/` — DB1 parquet (refs with Zotero group/key citations)
- `output/sections/` — DB2 parquet (section content)
- `output/key_messages/` — DB3 parquet (KM, BM, and SM descriptive text with confidence flags)
- `output/resolved_sections/` — sections with `(Author, Year)` replaced by OpenAlex W-IDs
- `output/zotero/` — Zotero parquet dataset partitioned by assessment/group id/page
- `output/works/` — OpenAlex works parquet dataset partitioned by assessment/km/bm
- `output/snowball/` — snowball parquet datasets: nodes (assessment/km/bm/relation), edges (assessment/km/bm/edge_type), keypaper (assessment/km/bm)
- `output/works_citing/` — papers citing the seed works, partitioned by assessment/km/bm
- `output/prompts/truth/` — rendered truth-document prompts per `(KM, BM)`, partitioned by assessment
- `output/prompts/citing/` — rendered candidate-paper prompts per citing work, partitioned by assessment/km/bm
- `output/alignement_scores/` — LLM alignement scores, partitioned by assessment/run_id/km/bm/model/replicate
- `output/fulltext/` — per-work Grobid XML (`.xml`), PDF (`.pdf`), or sentinel (`.missing`) files, partitioned by assessment
- `output/alignement/` — OpenRouter alignment scores, partitioned by assessment/run_id/km/model/temperature/relation/replicate
- `output/snowballs/` — per-paper snowball `.rds` files (QMD pipeline)
- `output/nodes/`, `output/edges/` — parquet datasets (QMD pipeline)
