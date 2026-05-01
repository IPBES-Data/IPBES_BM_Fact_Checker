# targets Pipeline Documentation

This document describes the `targets` pipeline for the IPBES Knowledge Discovery project.

## Overview

The pipeline fetches IPBES assessment data from the [IPBES Linked Open Data (LOD)](https://github.com/IPBES-Data/IPBES_LOD) repository in RDF/Turtle format, queries the assessments via SPARQL when needed, and stores refs, sections, Zotero items, and OpenAlex works as separate assessment-branched Parquet datasets.
Fuseki startup and shutdown are handled inside the parquet builders rather than as separate targets.

## Running the Pipeline

```r
# Run all outdated targets
targets::tar_make()

# Visualise the dependency graph
targets::tar_visnetwork()

# Check which targets are outdated
targets::tar_outdated()

# Load a target into your session
targets::tar_load(refs_parquet)
```

## Pipeline Diagrams

### Initial hand-drawn layout. 
The yellow squares are implemented, the red one still needs to be implemented:

![Hand-drawn layout](input/images/layout_handdrawn.png)

### Rendered Workflow

Based on the targets pipeline :

![Workflow](output/figures/workflow.png)

### Pipeline

Auto generated pipeline flow based on `_targets.R` definition

![Pipeline](output/figures/pipeline.png)

## Pipeline DAG

```
config_file (file)
    └── config
            ├── sparql_url                              ← SPARQL backend string
            ├── assessments_list
            │       └── assessment (list)
            │               ├── ttl_path (file)                    ← Target 1: download TTL per assessment
            │               ├── refs_sparql (file) ──────────────── queries/refs.sparql
            │               ├── refs_parquet (file)                ← Target 2a: refs dataset per assessment
            │               ├── sections_sparql (file) ──────────── queries/sections.sparql
            │               ├── sections_parquet (file)            ← Target 2b: sections dataset per assessment
            │               ├── key_messages_sparql (file) ──────── queries/key_messages.sparql
            │               ├── key_messages_parquet (file)        ← Target 2b2: KM/BM/SM text per assessment
            │               ├── zotero_parquet (file)              ← Target 2c: Zotero dataset per assessment
            │               ├── works_parquet (file)               ← Target 2d: OpenAlex works per assessment/km/bm
            │               ├── snowball_parquet (file)            ← Target 2e: snowball nodes+edges per assessment/km/bm
            │               ├── works_citing_parquet (file)        ← Target 2f: citing papers per assessment/km/bm
            │               └── resolved_sections_parquet (file)   ← Target 3: citations resolved to W-IDs
            └── analysis_list
                    └── analysis (list)                 ← one branch per analysis entry
```

## Configuration (`input/config.yaml`)

```yaml
# SPARQL endpoint to use for queries.
# "fuseki" = start a local Fuseki server automatically (requires: brew install fuseki).
# Any URL = query that endpoint directly (e.g. a remote SPARQL endpoint).
sparql_url: fuseki

assessments:
  - id: GA1
    ttl_url: https://raw.githubusercontent.com/IPBES-Data/IPBES_LOD/main/Global%20Assessment%201/GA1_v09.ttl

analysis:
  - assessment_id: GA1
    km: [A, B, C]
  - assessment_id: IAS
    km: ["KM-4a", "KM-B1"]
```

Config is split into fine-grained targets so that changing one section does not invalidate unrelated targets:

| Config key | Target | Invalidates |
|---|---|---|
| `sparql_url` | `sparql_url` | All SPARQL build targets |
| `assessments` | `assessments_list` → `assessment` | Assessment branches and their outputs |
| `analysis` | `analysis_list` → `analysis` | Analysis branches only |
| Any other key | `config` only | Nothing downstream |

## Target 0: `assessment` — Assessment Specs

**Source:** `input/config.yaml` via `_targets.R`

Creates a named list of assessment specifications from `assessments_list` (extracted from `config`). Each element gains an `index` field used for deterministic Fuseki port assignment. Branch names are the assessment IDs, so adding a new assessment creates a new branch without invalidating existing ones.

## Target 0b: `analysis` — Analysis Specs

**Source:** `input/config.yaml` via `_targets.R`

Creates a named list of analysis specifications from `analysis_list` (extracted from `config`). Branch names are the `assessment_id` values. Changing the `analysis` section only invalidates `analysis` branches — assessment extraction targets are unaffected.

## Target 1: `ttl_path` — Download TTL File

**Source:** `R/download_ttls.R` → `download_ttl(assessment)`

For each assessment branch:
1. Creates `output/LoD/` if it does not exist.
2. Downloads the TTL file to `output/LoD/<id>.ttl` using `utils::download.file()`.
3. Skips the download if the file already exists.

Returns a character vector of local TTL file paths (`format = "file"`).

> Even when `sparql_url` is a remote URL, the TTL files are still downloaded because they are a declared pipeline dependency.

## Target 2a: `refs_parquet` — DB1

**Source:** `R/write_refs_parquet.R` → `build_refs_parquet(sparql_url, assessment, ttl_path, refs_sparql, "output/refs")`

Builds the refs dataset for one assessment branch, queries only the refs SPARQL, and writes directly to `output/refs/assessment=<id>/`.
When `sparql_url: fuseki`, the function starts a local Fuseki session for the duration of the branch and stops it on exit.

The branch directory is deleted before the write so only that assessment partition is recreated cleanly.

### Reading DB1

```r
library(arrow)
library(dplyr)

arrow::open_dataset("output/refs") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::collect()
```

### Schema — DB1

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier — e.g. `"A."` |
| `bm` | chr | Background Message identifier — e.g. `"A1"` |
| `sm` | chr | Sub-Message identifier |
| `doi` | chr | DOI string — `NA` if absent |
| `description` | chr | Citation text from the LOD — `NA` if absent |
| `citation` | chr | Zotero-key citation string like `[P62TQUG2]` |
| `zotero_group` | chr | Zotero group id extracted from `zotero` |
| `zotero_key` | chr | Raw Zotero item key extracted from `zotero` |
| `zotero` | chr | Zotero URL (`owl:sameAs`) — `NA` if absent |

## Target 2b: `sections_parquet` — DB2

**Source:** `R/write_sections_parquet.R` → `build_sections_parquet(sparql_url, assessment, ttl_path, sections_sparql, "output/sections")`

Builds the sections dataset for one assessment branch, queries only the section-content SPARQL, and writes directly to `output/sections/assessment=<id>/`.
When `sparql_url: fuseki`, the function starts a local Fuseki session for the duration of the branch and stops it on exit.

The branch directory is deleted before the write so only that assessment partition is recreated cleanly.

### Reading DB2

```r
library(arrow)
library(dplyr)

arrow::open_dataset("output/sections") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::collect()
```

### Schema — DB2

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier — e.g. `"A."` |
| `bm` | chr | Background Message identifier — e.g. `"A1"` |
| `section` | chr | Chapter identifier — `NA` if not linked |
| `subsection` | chr | SubChapter identifier |
| `content` | chr | SubChapter description text — `NA` if absent |

## Target 2b2: `key_messages_parquet` — DB3

**Source:** `R/write_key_messages_parquet.R` → `build_key_messages_parquet(sparql_url, assessment, ttl_path, key_messages_sparql, "output/key_messages")`

Builds the key/background/sub-messages dataset for one assessment branch, queries the KM→BM→SM SPARQL, and writes directly to `output/key_messages/assessment=<id>/`.
When `sparql_url: fuseki`, the function starts a local Fuseki session (port base 5030) for the duration of the branch and stops it on exit.

The branch directory is deleted before the write so only that assessment partition is recreated cleanly.

### Reading DB3

```r
library(arrow)
library(dplyr)

arrow::open_dataset("output/key_messages") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::collect()
```

### Schema — DB3

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier — e.g. `"A."` |
| `km_label` | chr | KM headline text (`skos:prefLabel`) — `NA` if absent |
| `km_description` | chr | KM supporting detail text (`ipbes:hasDescription`) — `NA` if absent |
| `bm` | chr | Background Message identifier — e.g. `"A1"` |
| `bm_label` | chr | BM headline text (`skos:prefLabel`) — `NA` if absent |
| `bm_description` | chr | BM supporting detail text (`ipbes:hasDescription`) — `NA` if absent |
| `bm_well_established` | chr | BM confidence flag (`ipbes:hasWellestablished`) — e.g. `"Well-established"`, `NA` if absent |
| `bm_established_incomplete` | chr | BM confidence flag (`ipbes:hasEstablishedIncomplete`) — e.g. `"Established_but_incomplete"`, `NA` if absent |
| `sm_id` | chr | Sub-Message section reference(s) (`dcterms:identifier`) — e.g. `"2.3.3"` |
| `sm_description` | chr | SM statement text (`ipbes:hasDescription`) — `NA` if absent |
| `sm_well_established` | chr | SM confidence flag (`ipbes:hasWellestablished`) — `NA` if absent |
| `sm_established_incomplete` | chr | SM confidence flag (`ipbes:hasEstablishedIncomplete`) — `NA` if absent |

## Target 2c: `zotero_parquet` — Zotero Group Items

**Source:** `R/download_zotero.R` → `download_zotero(assessment, refs_parquet)`

Reads the refs branch for one assessment, infers the Zotero group id from `zotero`, downloads all top-level Zotero items page by page, and writes a parquet dataset to `output/zotero/assessment=<id>/` partitioned by `group_id` and `page`.

## Target 2d: `works_parquet` — OpenAlex Works

**Source:** `R/download_works.R` → `download_works(assessment, zotero_parquet, refs_parquet, workers = 8)`

Reads DOIs from the Zotero branch, fetches OpenAlex works with `openalexPro::pro_fetch()`, then joins the result with `refs_parquet` on normalised DOI to attach `km` and `bm` columns. Because one DOI can appear in multiple KM/BM pairs, the join duplicates work rows accordingly (many-to-many). The output is written to `output/works/assessment=<id>/` partitioned by `assessment`, `km`, and `bm`.

### Reading DB4

```r
library(arrow)
library(dplyr)

arrow::open_dataset("output/works") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::select(id, doi, title) |>
  dplyr::collect()
```

### Schema — DB4 (selected columns)

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier (partition) — e.g. `"A."` |
| `bm` | chr | Background Message identifier (partition) — e.g. `"A1"` |
| `id` | chr | OpenAlex work ID URL — e.g. `"https://openalex.org/W…"` |
| `doi` | chr | DOI string |
| `title` / `display_name` | chr | Work title |
| `publication_year` | int | Year of publication |
| … | … | 51 OpenAlex columns total (authors, topics, citations, etc.) |

## Target 2e: `snowball_parquet` — Snowball Search

**Source:** `R/build_snowball_parquet.R` → `build_snowball_parquet(assessment, works_parquet, "output/snowball")`

For each assessment branch, iterates over all km/bm combinations in `works_parquet`. For each group, collects the OpenAlex work IDs and calls `openalexSnowball::pro_snowball()` to retrieve all papers that cite or are cited by those seeds. The results are annotated with `assessment`, `km`, and `bm` then written to three shared parquet roots:

- `output/snowball/nodes/` — partitioned by `assessment`, `km`, `bm`, `relation`
- `output/snowball/edges/` — partitioned by `assessment`, `km`, `bm`, `edge_type`
- `output/snowball/keypaper/` — partitioned by `assessment`, `km`, `bm`

Only this assessment's partition directories are deleted before writing; other assessments are untouched.

### Reading

```r
library(arrow)
library(dplyr)

arrow::open_dataset("output/snowball/nodes") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::select(id, doi, title, relation, oa_input) |>
  dplyr::collect()

arrow::open_dataset("output/snowball/edges") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::collect()

arrow::open_dataset("output/snowball/keypaper") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::select(id, doi, title, oa_input) |>
  dplyr::collect()
```

### Schema — Nodes

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier (partition) — e.g. `"A."` |
| `bm` | chr | Background Message identifier (partition) — e.g. `"A1"` |
| `relation` | chr | Relationship to seeds (partition): `"keypaper"`, `"citing"`, or `"cited"` |
| `oa_input` | lgl | `TRUE` if this work was one of the seed IDs |
| `id` | chr | OpenAlex work ID URL |
| `doi` | chr | DOI string |
| `title` | chr | Work title |
| `publication_year` | int | Year of publication |
| … | … | 53 columns total (authorships, topics, citations, etc.) |

### Schema — Keypaper

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier (partition) — e.g. `"A."` |
| `bm` | chr | Background Message identifier (partition) — e.g. `"A1"` |
| `oa_input` | lgl | Always `TRUE` — these are the seed works |
| `id` | chr | OpenAlex work ID URL |
| `doi` | chr | DOI string |
| `title` | chr | Work title |
| `publication_year` | int | Year of publication |
| … | … | 53 columns total (same schema as nodes) |

### Schema — Edges

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier (partition) — e.g. `"A."` |
| `bm` | chr | Background Message identifier (partition) — e.g. `"A1"` |
| `edge_type` | chr | Edge classification (partition): `"core"`, `"extended"`, or `"outside"` |
| `from` | chr | OpenAlex ID of citing work |
| `to` | chr | OpenAlex ID of cited work |

## Target 2f: `works_citing_parquet` — Citing Works

**Source:** `R/build_works_citing_parquet.R` → `build_works_citing_parquet(assessment, snowball_parquet, "output/works_citing")`

Reads the snowball nodes for this assessment branch (from `output/snowball/nodes/`), filters for `relation == "citing"`, drops the `relation` column, and writes the result to `output/works_citing/` partitioned by `assessment/km/bm`. Depends on `snowball_parquet`.

### Reading

```r
library(arrow)
library(dplyr)

arrow::open_dataset("output/works_citing") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::select(id, doi, title, publication_year) |>
  dplyr::collect()
```

### Schema

Same columns as the snowball nodes dataset minus `relation` (dropped after filter), including:

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier (partition) — e.g. `"A."` |
| `bm` | chr | Background Message identifier (partition) — e.g. `"A1"` |
| `oa_input` | lgl | Whether this was an OpenAlex seed input |
| `id` | chr | OpenAlex work ID URL |
| `doi` | chr | DOI string |
| `title` | chr | Work title |
| `publication_year` | int | Year of publication |
| … | … | remaining OpenAlex columns |

## Target 3: `resolved_sections_parquet` — Resolved Sections

**Source:** `R/resolve_citations.R` → `resolve_citations(assessment, sections_parquet, works_parquet, zotero_parquet)`

For each assessment branch, joins the Zotero and OpenAlex Works datasets on normalised DOI to build an `(author_key, year_key) → [WID …]` lookup map, then rewrites every `content` cell in the sections dataset by replacing `(Author, Year)` citation strings with `[WID WID …]` OpenAlex work ID tokens. Output is written to `output/resolved_sections/assessment=<id>/` partitioned by assessment only.

### Reading

```r
library(arrow)
library(dplyr)

arrow::open_dataset("output/resolved_sections") |>
  dplyr::filter(assessment == "GA1", km == "A.", bm == "A1") |>
  dplyr::collect()
```

### Schema

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier — e.g. `"A."` |
| `bm` | chr | Background Message identifier — e.g. `"A1"` |
| `section` | chr | Chapter identifier — `NA` if not linked |
| `subsection` | chr | SubChapter identifier |
| `content` | chr | SubChapter text with `(Author, Year)` replaced by `[WID …]` tokens |

## SPARQL Queries

All three SPARQL queries live in `queries/*.sparql` and are tracked as `format = "file"` targets (`refs_sparql`, `sections_sparql`, `key_messages_sparql`). Changing a query file invalidates only the downstream parquet target — no R code changes needed.

| File | Target | Traversal |
|------|--------|-----------|
| `queries/refs.sparql` | `refs_parquet` | `KeyMessage → BackgroundMessage → SubMessage → SubChapter ← Reference(doi)` |
| `queries/sections.sparql` | `sections_parquet` | `KeyMessage → BackgroundMessage → SubMessage → SubChapter(content) → Chapter(section)` |
| `queries/key_messages.sparql` | `key_messages_parquet` | `KeyMessage → BackgroundMessage → SubMessage` (text + confidence flags on BM and SM) |

The IPBES ontology prefix is `http://ontology.ipbes.net/report` with no trailing slash or hash.

## Notes

- `refs_parquet`, `sections_parquet`, `zotero_parquet`, and `works_parquet` are all assessment-branched and do not cache a combined `lod_data` object.
- Each assessment branch rewrites only its own partition directory.
- Fuseki lifecycle is managed internally by the parquet builders.
- The OpenAlex branch requires `openalexPro` to be installed and uses the documented query -> download -> JSONL -> parquet workflow.

## Required R Packages

| Package | Role |
|---------|------|
| `targets` | Pipeline engine |
| `yaml` | Config parsing |
| `processx` | Fuseki subprocess management |
| `httr2` | HTTP SPARQL queries |
| `readr` | CSV response parsing |
| `arrow` | Parquet I/O |
| `dplyr` | Data manipulation |
| `tictoc` | Query timing |
| `openalexPro` | OpenAlex works download |
| `openalexSnowball` | Snowball search (citing/cited paper discovery) |

**System dependency:** `fuseki-server` on `PATH` (install with `brew install fuseki`). Only required when `sparql_url: fuseki`.
