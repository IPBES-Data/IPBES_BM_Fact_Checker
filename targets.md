# targets Pipeline Documentation

This document describes the `targets` pipeline for the IPBES Knowledge Discovery project.

## Overview

The pipeline fetches IPBES assessment data from the [IPBES Linked Open Data (LOD)](https://github.com/IPBES-Data/IPBES_LOD) repository in RDF/Turtle format, queries the assessments via SPARQL, and produces per-assessment Parquet datasets for refs, sections, key-messages, Zotero items, OpenAlex works, snowball results, and rendered LLM prompts. A final scoring stage uses OpenRouter / ellmer to align candidate citing works against the corresponding truth document.

Fuseki startup and shutdown are handled inside the parquet builders rather than as separate targets. When `sparql_url: fuseki`, each builder boots an in-memory Fuseki, POSTs the TTL into the named graph `http://ontology.ipbes.net/report/<id>` via the Graph Store Protocol, runs its query, and tears Fuseki down.

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

### Initial hand-drawn layout

The yellow squares are implemented, the red one still needs to be implemented:

![Hand-drawn layout](input/images/layout_handdrawn.png)

### Rendered Workflow

Based on the targets pipeline:

![Workflow](output/figures/workflow.png)

### Pipeline

Auto-generated pipeline flow based on `_targets.R` definition:

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
            │               ├── sections_parquet (file)            ← Target 2b: sections dataset per assessment (now carries sm)
            │               ├── key_messages_sparql (file) ──────── queries/key_messages.sparql
            │               ├── key_messages_parquet (file)        ← Target 2c: KM/BM/SM text per assessment
            │               ├── zotero_parquet (file)              ← Target 2d: Zotero dataset per assessment
            │               ├── works_parquet (file)               ← Target 2e: OpenAlex works per assessment/km/bm
            │               ├── snowball_parquet (file)            ← Target 2f: snowball nodes+edges per assessment/km/bm
            │               ├── works_citing_parquet (file)        ← Target 2g: citing papers per assessment/km/bm
            │               ├── prompts_truth_parquet (file)       ← Target 2h: structured-JSON truth doc per (KM, BM)
            │               └── prompts_citing_parquet (file)      ← Target 2i: structured-JSON candidate prompt per citing work
            └── analysis_list
                    └── alignement_scores_run_specs (list)  ← one branch per configured run
                            └── alignement_scores_parquet (file) ← Target 3: OpenRouter alignement scores
```

Three tracked prompt-file targets feed `alignement_scores_parquet` directly (not branched, not per-assessment):

```
input/prompts/system_prompt.md  ──→ system_prompt_file  ─┐
input/prompts/truth_wrapper.md  ──→ truth_wrapper_file  ─┼─→ alignement_scores_parquet
input/prompts/citing_wrapper.md ──→ citing_wrapper_file ─┘
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
    full_text: false
  - id: IAS
    ttl_url: https://raw.githubusercontent.com/IPBES-Data/IPBES_LOD/refs/heads/main/Invasive%20Alien%20Species%20Assessment/IAS_v04.ttl
    full_text: true

analysis:
  # n_citing: number of citing works to score per (KM, BM). 0 = score all.
  - assessment_id: IAS
    runs:
      - run_id: IAS_km_ab
        km: ["KM-A1"]
        model: "openai/gpt-4o-mini"
        temperature: 0
        max_active: 8
        replicates: 1
        n_citing: 100
  - assessment_id: GA1
    runs:
      - run_id: GA1_km_ab
        km: ["A."]
        model: "openai/gpt-4o-mini"
        temperature: 0
        max_active: 8
        replicates: 1
        n_citing: 100
```

Config is split into fine-grained targets so that changing one section does not invalidate unrelated targets:

| Config key | Target | Invalidates |
|---|---|---|
| `sparql_url` | `sparql_url` | All SPARQL build targets |
| `assessments` | `assessments_list` → `assessment` | Assessment branches and their outputs |
| `analysis` | `analysis_list` | Alignement scoring runs only |
| Any other key | `config` only | Nothing downstream |

Alignement runs must define a unique `run_id`; this identifier is used to isolate each long-running run branch and avoid overwriting.

## Target 0: `assessment` — Assessment Specs

**Source:** `input/config.yaml` via `_targets.R`

Creates a named list of assessment specifications from `assessments_list` (extracted from `config`). Each element gains an `index` field used for deterministic Fuseki port assignment. Branch names are the assessment IDs, so adding a new assessment creates a new branch without invalidating existing ones.

## Target 0b: `alignement_scores_run_specs` — Alignement Run Specs

**Source:** `R/build_alignement_scores_parquet.R` → `build_alignement_scores_run_specs(analysis_list, assessment, prompts_truth_parquet, prompts_citing_parquet)`

Flattens all configured alignement runs into one branch per run. Each run spec keeps a unique `run_id`, the configured `km` list, plus its `assessment_id`, `model`, `temperature`, `max_active`, `replicates`, and `n_citing` (0 = score all citing works for the (KM, BM)). It also carries the resolved roots of `prompts_truth_parquet` and `prompts_citing_parquet`. Changing a run definition invalidates only the affected run branch.

## Target 1: `ttl_path` — Download TTL File

**Source:** `R/download_ttls.R` → `download_ttl(assessment)`

For each assessment branch:
1. Creates `output/LoD/` if it does not exist.
2. Queries the GitHub Contents API for the current SHA of the remote TTL file.
3. Skips the download if a local copy with a matching SHA already exists.
4. Otherwise downloads to `output/LoD/<id>.ttl` and writes the SHA next to it for the next run.

Returns a character vector of local TTL file paths (`format = "file"`).

> Even when `sparql_url` is a remote URL, the TTL files are still downloaded because they are a declared pipeline dependency. The download is cheap once cached.

## Target 2a: `refs_parquet` — DB1

**Source:** `R/write_refs_parquet.R` → `build_refs_parquet(sparql_url, assessment, ttl_path, refs_sparql, "output/refs")`

Builds the refs dataset for one assessment branch, queries only the refs SPARQL, and writes directly to `output/refs/assessment=<id>/`.
When `sparql_url: fuseki`, the function starts a local Fuseki session (in-memory, `--mem --update`) for the duration of the branch, POSTs the assessment's TTL into the named graph `http://ontology.ipbes.net/report/<id>` via the Graph Store Protocol, and stops Fuseki on exit.

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

Builds the sections dataset for one assessment branch. The SPARQL query now projects `?sm_id` alongside the other identifiers, so each SubChapter source row carries the SubMessage that referenced it. The result is written to `output/sections/assessment=<id>/`.

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
| `sm` | chr | Sub-Message identifier — e.g. `"2.3.2"` |
| `section` | chr | Chapter identifier — `NA` if not linked |
| `subsection` | chr | SubChapter identifier |
| `content` | chr | SubChapter description text — `NA` if absent |

## Target 2c: `key_messages_parquet` — DB3

**Source:** `R/write_key_messages_parquet.R` → `build_key_messages_parquet(sparql_url, assessment, ttl_path, key_messages_sparql, "output/key_messages")`

Builds the key/background/sub-messages dataset for one assessment branch, queries the KM→BM→SM SPARQL, and writes directly to `output/key_messages/assessment=<id>/`. Like DB1/DB2, runs against a Fuseki session that loads the TTL into a per-assessment named graph.

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
| `bm_well_established` | chr | BM confidence flag (`ipbes:hasWellestablished`) — `NA` if absent |
| `bm_established_incomplete` | chr | BM confidence flag (`ipbes:hasEstablishedIncomplete`) — `NA` if absent |
| `sm_id` | chr | Sub-Message section reference(s) (`dcterms:identifier`) — e.g. `"2.3.3"` |
| `sm_description` | chr | SM statement text (`ipbes:hasDescription`) — `NA` if absent |
| `sm_well_established` | chr | SM confidence flag — `NA` if absent |
| `sm_established_incomplete` | chr | SM confidence flag — `NA` if absent |

## Target 2d: `zotero_parquet` — Zotero Group Items

**Source:** `R/download_zotero.R` → `download_zotero(assessment, refs_parquet)`

Reads the refs branch for one assessment, infers the Zotero group id from `zotero`, downloads all top-level Zotero items page by page, and writes a parquet dataset to `output/zotero/assessment=<id>/` partitioned by `group_id` and `page`.

## Target 2e: `works_parquet` — OpenAlex Works

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

## Target 2f: `snowball_parquet` — Snowball Search

**Source:** `R/build_snowball_parquet.R` → `build_snowball_parquet(assessment, works_parquet, "output/snowball")`

For each assessment branch, iterates over all km/bm combinations in `works_parquet`. For each group, collects the OpenAlex work IDs and calls `openalexSnowball::pro_snowball()` to retrieve all papers that cite or are cited by those seeds. The results are annotated with `assessment`, `km`, and `bm`, then written to three shared parquet roots:

- `output/snowball/nodes/` — partitioned by `assessment`, `km`, `bm`, `relation` (relation = `keypaper` | `citing` | `cited`). Stays in Arrow end-to-end to avoid breaking nested struct/list columns on the R round-trip.
- `output/snowball/edges/` — partitioned by `assessment`, `km`, `bm`, `edge_type`
- `output/snowball/keypaper/` — partitioned by `assessment`, `km`, `bm`; derived from `nodes` filtered to `relation == "keypaper"` (since `openalexSnowball ≥ 0.1.1` no longer emits a standalone keypaper directory)

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

### Schema — Edges

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) — e.g. `"GA1"` |
| `km` | chr | Key Message identifier (partition) — e.g. `"A."` |
| `bm` | chr | Background Message identifier (partition) — e.g. `"A1"` |
| `edge_type` | chr | Edge classification (partition): `"core"`, `"extended"`, or `"outside"` |
| `from` | chr | OpenAlex ID of citing work |
| `to` | chr | OpenAlex ID of cited work |

## Target 2g: `works_citing_parquet` — Citing Works

**Source:** `R/build_works_citing_parquet.R` → `build_works_citing_parquet(assessment, snowball_parquet, "output/works_citing")`

Walks the per-km/bm parquet files under `output/snowball/nodes/assessment=<id>/km=*/bm=*/relation=citing/*.parquet` and copies each one directly into `output/works_citing/assessment=<id>/km=<km>/bm=<bm>/`. The file-copy approach is required because OpenAlex's nested struct columns can have inconsistent schemas (string in one batch, struct in another) across km/bm partitions, which neither Arrow nor DuckDB's `union_by_name` can reconcile across files — but within a single file the schema is internally consistent.

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

Same columns as the snowball nodes dataset minus `relation` (always `citing` in this dataset).

## Target 2h: `prompts_truth_parquet` — Truth Prompts (structured JSON)

**Source:** `R/build_prompts_truth_parquet.R` → `build_prompts_truth_parquet(assessment, key_messages_parquet, sections_parquet, "output/prompts/truth")`

For each `(assessment, KM, BM)` pair, builds a structured nested representation combining the BM's metadata, all SubMessages under it (with confidence flags), and each SubMessage's source sections (joined from `sections_parquet` on the new `sm` column). Writes one row per (KM, BM) to `output/prompts/truth/assessment=<id>/` with two columns of interest:

- `sub_messages` — Arrow `list<struct<sm_id, sm_description, sm_well_established, sm_established_incomplete, sources: list<struct<section, subsection, content>>>>`. Downstream code can slice by SM/source without re-parsing.
- `prompt` — the same payload serialised to JSON for LLM consumption. JSON is used (instead of markdown) because SubChapter content can contain literal `#` characters and table-derived line-per-cell text that would break a markdown wrapper.

Sources may legitimately duplicate across SMs when the LOD links one SubChapter to multiple SubMessages — this is accurate and intentional, not a bug.

### Schema

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) |
| `km`, `bm` | chr | Key/Background Message identifiers |
| `km_label`, `km_description` | chr | KM text fields |
| `bm_label`, `bm_description` | chr | BM text fields |
| `bm_well_established`, `bm_established_incomplete` | chr | BM confidence flags |
| `sub_messages` | list<struct> | One entry per SM; each SM has metadata + its own `sources` list of (section, subsection, content) |
| `prompt` | chr | JSON serialisation of the row, ready for the LLM |

## Target 2i: `prompts_citing_parquet` — Citing Prompts (structured JSON)

**Source:** `R/build_prompts_citing_parquet.R` → `build_prompts_citing_parquet(assessment, works_citing_parquet, "output/prompts/citing")`

For each row in `works_citing_parquet`, renders a flat JSON object (no nesting) with the work's scalar fields and the (assessment, km, bm) ids. Writes to `output/prompts/citing/assessment=<id>/km=<km>/bm=<bm>/`. Uses the same per-file iteration as the citing builder to avoid OpenAlex schema mismatches, and streams each km/bm partition straight to disk (keeps peak memory bounded for the large IAS/GA1 datasets).

JSON wire format chosen for the same reason as the truth prompts: OpenAlex abstracts contain `#` characters that would break markdown wrapping.

### Schema

| Column | Type | Description |
|--------|------|-------------|
| `assessment`, `km`, `bm` | chr | Partition columns |
| `work_id` | chr | OpenAlex work ID URL |
| `doi` | chr | DOI string |
| `title` | chr | Paper title |
| `abstract` | chr | Paper abstract |
| `publication_year` | int | Publication year |
| `relation` | chr | Always `"citing"` (kept for symmetry with future relation types) |
| `prompt` | chr | JSON serialisation of the row, ready for the LLM |

## Target 3: `alignement_scores_parquet` — OpenRouter Alignement Scoring

**Source:** `R/build_alignement_scores_parquet.R` → `build_alignement_scores_parquet(alignement_scores_run_specs, system_prompt_file, truth_wrapper_file, citing_wrapper_file, output_root = "output/alignement_scores")`

For each run branch (one per entry in `analysis.runs[]`), and for each KM in `spec$km`:

1. Reads the matching truth rows from `prompts_truth_parquet` (one per (KM, BM) under the chosen KM).
2. For each (KM, BM): samples the first `n_citing` citing prompts from `prompts_citing_parquet` deterministically by `work_id` (or all when `n_citing == 0`).
3. Sends each candidate to OpenRouter / ellmer with `system_prompt + truth_wrapper + truth_json + citing_wrapper + citing_json` as the prompt. Only the citing JSON varies per call, so the (system + truth_wrapper + truth_json + citing_wrapper) prefix is identical across candidates for the same (KM, BM) and the provider's automatic prefix caching kicks in.
4. Uses `ellmer::parallel_chat_structured()` with the schema in `R/alignement_schema.R` for the structured response; falls back to a single-call retry with JSON validation in `call_alignement_model()` for any failures.
5. Writes per-chunk results to `output/alignement_scores/` partitioned by `assessment`, `run_id`, `km`, `bm`, `model`, and `replicate`.

The three prompt-file inputs (`system_prompt_file`, `truth_wrapper_file`, `citing_wrapper_file`) are tracked as `format = "file"` targets; editing any of them invalidates the scoring branch automatically.

### Reading

```r
library(arrow)
library(dplyr)

arrow::open_dataset("output/alignement_scores") |>
  dplyr::filter(assessment == "GA1", run_id == "GA1_km_ab", km == "A.") |>
  dplyr::collect()
```

### Schema

| Column | Type | Description |
|--------|------|-------------|
| `assessment` | chr | Assessment ID (partition) |
| `run_id` | chr | Unique alignement run identifier (partition) |
| `km` | chr | Key Message identifier (partition) |
| `bm` | chr | Background Message identifier (partition) |
| `model` | chr | Filesystem-safe model partition slug (partition) |
| `replicate` | int | Replicate number within the run (partition) |
| `model_id` | chr | Raw OpenRouter model id |
| `temperature` | dbl | Sampling temperature |
| `candidate_rank` | int | Rank within the sampled candidate set |
| `work_id` | chr | OpenAlex work id |
| `lm_id` | chr | Echoed Key Message id |
| `km_summary` | chr | Distilled Key Message text |
| `work_alignement` | int | Score from -5 to +5 |
| `confidence` | dbl | Model confidence from 0 to 1 |
| `evidence` | chr | Supporting excerpt or close paraphrase |
| `justification` | chr | Short rationale for the score |
| `title` | chr | Candidate work title |
| `abstract` | chr | Candidate work abstract |

## SPARQL Queries

All three SPARQL queries live in `queries/*.sparql` and are tracked as `format = "file"` targets (`refs_sparql`, `sections_sparql`, `key_messages_sparql`). Changing a query file invalidates only the downstream parquet target — no R code changes needed.

| File | Target | Traversal |
|------|--------|-----------|
| `queries/refs.sparql` | `refs_parquet` | `KeyMessage → BackgroundMessage → SubMessage → SubChapter ← Reference(doi)` |
| `queries/sections.sparql` | `sections_parquet` | `KeyMessage → BackgroundMessage → SubMessage → SubChapter(content) → Chapter(section)` (projects `sm_id`) |
| `queries/key_messages.sparql` | `key_messages_parquet` | `KeyMessage → BackgroundMessage → SubMessage` (text + confidence flags on BM and SM) |

All three queries wrap their pattern in `GRAPH <%GRAPH_IRI%> { ... }`. The `%GRAPH_IRI%` placeholder is substituted at query time by `read_sparql_query()` (in `R/extract_lod.R`) using `assessment_graph_iri()` from `R/branch_helpers.R` — currently `http://ontology.ipbes.net/report/<id>`. The same query works against:

- Local Fuseki: the assessment's TTL is POSTed into that named graph at startup via the Graph Store Protocol.
- A shared IPBES endpoint hosting all assessments: requires the same IRI convention to be used upstream.

Switching backends is a one-line change in `input/config.yaml` (`sparql_url:`). If IPBES adopts a different graph IRI convention, edit `assessment_graph_iri()` in one place.

The IPBES ontology prefix is `http://ontology.ipbes.net/report` with no trailing slash or hash.

## Prompt files

Three markdown files in `input/prompts/` feed the alignement scoring stage; each is a tracked `format = "file"` target so edits invalidate the scoring branch:

| File | Target | Role |
|------|--------|------|
| `input/prompts/system_prompt.md` | `system_prompt_file` | System role: task definition, scoring rubric, output schema |
| `input/prompts/truth_wrapper.md` | `truth_wrapper_file` | Static intro + schema description placed before the truth JSON |
| `input/prompts/citing_wrapper.md` | `citing_wrapper_file` | Static intro + schema description placed before the citing JSON |

At scoring time the user prompt is assembled as:

```
truth_wrapper + truth_json + citing_wrapper + citing_json
```

The system + wrappers + truth_json form the cached prefix; citing_json is the only variable suffix per call.

## Orphaned / deprecated source files

The following R files still exist but are **not** wired into the current `_targets.R`. Their outputs are not produced by `tar_make()`. Kept for reference / future re-enablement:

- `R/build_fulltext.R` — legacy `fulltext_files` builder (Grobid XML / PDF download for citing works).
- `R/resolve_citations.R` — legacy `resolved_sections_parquet` builder (replace `(Author, Year)` with OpenAlex W-IDs in section content).
- `R/build_alignement_parquet.R` — legacy single-pass scoring builder; superseded by `R/build_alignement_scores_parquet.R`.

The corresponding output directories (`output/fulltext/`, `output/resolved_sections/`, `output/alignement/`) remain gitignored to keep any stale data from previous runs out of commits.

## Notes

- `refs_parquet`, `sections_parquet`, `key_messages_parquet`, `zotero_parquet`, `works_parquet`, `snowball_parquet`, `works_citing_parquet`, `prompts_truth_parquet`, and `prompts_citing_parquet` are all assessment-branched; there is no cached combined `lod_data` object.
- Each assessment branch rewrites only its own partition directory.
- Fuseki lifecycle is managed internally by the parquet builders (started per branch, TTL loaded into a named graph via the Graph Store Protocol, stopped on exit).
- The OpenAlex branch requires `openalexPro` to be installed and uses the documented query → download → parquet workflow.
- Credentials (`API_openalex`, `API_openrouter`) are read from the macOS keyring by `_targets.R` at session start via `keyring::key_get()`.

## Required R Packages

| Package | Role |
|---------|------|
| `targets` | Pipeline engine |
| `yaml` | Config parsing |
| `keyring` | API credential retrieval |
| `processx` | Fuseki subprocess management |
| `httr2` | HTTP SPARQL queries + Graph Store Protocol POSTs |
| `readr` | CSV response parsing |
| `arrow` | Parquet I/O |
| `dplyr` | Data manipulation |
| `tictoc` | Query timing |
| `jsonlite` | JSON serialisation for prompts |
| `ellmer` | OpenRouter chat client |
| `openalexPro` | OpenAlex works download |
| `openalexSnowball` | Snowball search (citing/cited paper discovery) |
| `future` | Parallel backend |
| `future.apply` | `future_lapply()` for parallel workers |

**System dependency:** `fuseki-server` on `PATH` (install with `brew install fuseki`). Only required when `sparql_url: fuseki`.
