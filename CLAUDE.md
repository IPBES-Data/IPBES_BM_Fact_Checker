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
    → output/works/assessment=<id>/          (partitioned by assessment, gitignored)
    → output/resolved_sections/assessment=<id>/ (partitioned by assessment, gitignored)
```

The `sparql_url` key in `input/config.yaml` controls the SPARQL backend:
- `"fuseki"` — each parquet builder manages a local Fuseki session for the assessment branch on a deterministic port
- Any URL — the parquet builders query that endpoint directly; no Fuseki lifecycle needed

Config is split into fine-grained targets (`sparql_url`, `assessments_list`) so that adding new config sections or changing one assessment does not invalidate other assessments' targets.

> **Caveat for remote endpoints:** The SPARQL queries match all `ipbes:KeyMessage` triples regardless of assessment. A shared endpoint holding multiple assessments would return mixed results. Named-graph filtering would be needed — leave as-is until the endpoint structure is known.

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
- **Fine-grained config**: `config` is split into `sparql_url` and `assessments_list` targets so unrelated config sections don't cascade invalidation.
- **Fuseki lifecycle**: started and stopped inside the parquet builders; cleanup is idempotent and handled by `on.exit()`.
- **Assessment branching**: `assessment` is the branch key, so adding a new assessment only computes the new branch.
- **Separated materialization**: refs, sections, key_messages, Zotero, and works are all built independently; there is no cached combined `lod_data` object.
- **Parquet databases**: partitioned by assessment only, queried lazily with `arrow::open_dataset()` + `dplyr` verbs, collected into memory only when needed.
- **SPARQL queries as files**: all three SPARQL queries live in `queries/*.sparql` and are read at runtime — edit queries without touching R code.
- **Legacy QMD caching**: uses `file.exists(fn)` checks. Delete the relevant `.rds` or parquet directory to force recomputation.

### R Files (targets pipeline)

| File | Target(s) | Purpose |
|------|-----------|---------|
| `R/download_openalex.R` | `works_parquet` | Download OpenAlex works to `output/works/assessment=<id>/` using `openalexPro::pro_query()` + `pro_request()` + `pro_request_jsonl()` + `pro_request_jsonl_parquet()` |
| `R/download_zotero.R` | `zotero_parquet` | Download Zotero group items to `output/zotero/assessment=<id>/` using refs parquet |
| `R/download_ttls.R` | `ttl_path` | Download TTL files to `output/LoD/` |
| `R/manage_fuseki.R` | helpers | Start/stop Fuseki sessions and resolve endpoints |
| `R/branch_helpers.R` | helpers | Assessment IDs and branch output paths |
| `R/extract_lod.R` | `refs_parquet`, `sections_parquet`, `key_messages_parquet` | SPARQL extraction helpers; reads queries from `queries/*.sparql` |
| `R/write_refs_parquet.R` | `refs_parquet` | Build DB1 directly into `output/refs/assessment=<id>/` |
| `R/write_sections_parquet.R` | `sections_parquet` | Build DB2 directly into `output/sections/assessment=<id>/` |
| `R/write_key_messages_parquet.R` | `key_messages_parquet` | Build DB3 directly into `output/key_messages/assessment=<id>/` |
| `R/resolve_citations.R` | `resolved_sections_parquet` | Replace `(Author, Year)` citations with OpenAlex W-IDs |

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
- `output/key_messages/` — DB3 parquet (KM and BM descriptive text)
- `output/resolved_sections/` — sections with `(Author, Year)` replaced by OpenAlex W-IDs
- `output/zotero/` — Zotero parquet dataset partitioned by assessment/group id/page
- `output/works/` — OpenAlex works parquet dataset partitioned by assessment
- `output/snowballs/` — per-paper snowball `.rds` files (QMD pipeline)
- `output/nodes/`, `output/edges/` — parquet datasets (QMD pipeline)
