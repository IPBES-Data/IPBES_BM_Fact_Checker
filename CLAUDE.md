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

**Not wired into `_targets.R` (source files exist but no active target):** `R/build_fulltext.R`, `R/build_alignement_parquet.R`, `R/resolve_citations.R`. Their corresponding outputs (`output/fulltext/`, `output/alignement/`, `output/resolved_sections/`) are no longer produced by the live pipeline. The only deliberately commented-out target in `_targets.R` is the QMD `report` block at the bottom.

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
    → output/nli_ready/assessment=<id>/km=<km>/bm=<bm>/          (work × BM-sentence cross-join; premise + bm_sentence ready for NLI, gitignored)
    → output/nli_scores/assessment=<id>/km=<km>/bm=<bm>/claim_id=<claim_id>/   (NLI SUPPORTS/REFUTES/NEI scores per citing work, gitignored)

# PARKED — LLM-comparison approach (targets commented out in _targets.R, superseded by the NLI approach):
#   output/prompts/truth/, output/prompts/citing/, output/alignement_scores/

# Not currently produced (orphaned source files in R/, gitignored outputs may hold stale data):
#   output/fulltext/, output/resolved_sections/, output/alignement/
```

**Active scoring approach — NLI** (`TD_BM_NLI_approach.md`): `nli_scores_by_claim`
classifies each citing work against its partition's Background Message as
SUPPORTS / REFUTES / NOT_ENOUGH_INFO using a zero-shot NLI model
(`MoritzLaurer/deberta-v3-large-zeroshot-v2.0`) served on a pool of RunPod
hosts (see [docker/nli-runpod/](docker/nli-runpod/)). Premise = cleaned `title`+`abstract`;
hypothesis = `bm_description`. The full probability distribution is stored; all
thresholding is done downstream in `dplyr`. The previous LLM-comparison chain
(`prompts_truth_parquet` → `prompts_citing_parquet` → `alignement_scores_*`) is
**parked** — the targets are commented out in `_targets.R` and the `analysis:`
block in `input/config.yaml`, but their R source files remain on disk to un-park.

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
- **Separated materialization**: refs, sections, key_messages, Zotero, works, snowball, works_citing, prompts (truth/citing), and alignement scores are all built independently; there is no cached combined `lod_data` object.
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
| `R/render_diagrams.R` | `mmd_workflow_nli`, `diagram_workflow_nli`, `mmd_workflow_lm`, `diagram_workflow_lm`, `pipeline_mmd`, `diagram_pipeline_nli`, `pipeline_lm`, `diagram_pipeline_lm` | Render Mermaid `.mmd` sources to SVG. Hand-authored conceptual diagrams come in two variants: `workflow_nli.mmd` (active NLI approach) and `workflow_lm.mmd` (parked LLM approach). `build_pipeline_mmd()` auto-generates `pipeline_nli.mmd` from the live `tar_mermaid()` DAG; `pipeline_lm.mmd` is a frozen snapshot of the old LLM-comparison DAG |
| `R/alignement_schema.R` | *(PARKED — helpers for `alignement_scores_parquet`)* | `ellmer` structured-output schema for OpenRouter alignment scoring |
| `R/extract_lod.R` | `refs_parquet`, `sections_parquet`, `key_messages_parquet` | SPARQL extraction helpers; reads queries from `queries/*.sparql` |
| `R/write_refs_parquet.R` | `refs_parquet` | Build DB1 directly into `output/refs/assessment=<id>/` |
| `R/write_sections_parquet.R` | `sections_parquet` | Build DB2 directly into `output/sections/assessment=<id>/` |
| `R/write_key_messages_parquet.R` | `key_messages_parquet` | Build DB3 directly into `output/key_messages/assessment=<id>/` |
| `R/clean_text.R` | helpers for `nli_ready_parquet` | `clean_text()`/`clean_title()`/`clean_abstract()` — strip HTML/JATS + LaTeX, squish whitespace. Copied verbatim from the TCAC 2.0 project. Deps: `xml2`, `stringr` |
| `R/build_nli_ready_parquet.R` | `nli_ready_parquet` | **Segmentation approach 1 (per-sentence).** Split each BM's `bm_description` (and/or `bm_label`) into sentences (fragments < 20 chars dropped), cross-join with the cleaned `premise` (= title + abstract) of every citing work. One row per (work × BM sentence) with `sentence_number`, `sentence_source`, `claim`, `premise`, and token estimates (`abstract_tokens`, `sentence_tokens`, `approx_tokens`). Parallelised over km/bm partitions with `parallel::mclapply` (`workers` from config). Writes to `output/nli_ready/assessment=<id>/km=<km>/bm=<bm>/` |
| `R/build_nli_ready_evidence_parquet.R` | `nli_ready_evidence_parquet` | **Segmentation approach 2 (per-evidence-reference).** Identical schema/output to approach 1 but cuts BM text into claims at brace evidence-references (`{5.4.1, 5.4.2}`) that *end a sentence* rather than at every sentence: `segment_bm_by_evidence()` accumulates sentences until one ends with a `{...}`, keeps trailing brace-less text (and whole brace-less fields) as a claim, and strips the braces from the hypothesis text. See NEXT_STEPS.md. Writes to `output/nli_ready_evidence/assessment=<id>/km=<km>/bm=<bm>/`. The downstream `nli_claim_units_evidence` → `nli_claim_units_evidence_flat` → `nli_scores_by_claim_evidence` chain reuses `build_nli_claim_units()`/`score_one_claim()` unchanged (only the source path and the `output/nli_scores_evidence` root differ) |
| `R/nli_http_helpers.R` | helpers for `nli_pool_health`, `nli_scores_by_claim` | Low-level HTTP helpers shared by health-checking and scoring: `nli_cfg_get()`, `nli_hosts()` (normalizes `host:` scalar-or-list to a character vector), `nli_classify_url()`, `nli_health()`, `nli_classify_request()`. |
| `R/check_nli_pool_health.R` | `nli_pool_health` | Health-checks every host in the active nli config's pool once per pipeline build. Fails loudly listing every unreachable host (never silently drops one); stops (not warns) if hosts report different models, since that would silently corrupt result provenance. Returns the common model name for stamping onto scored rows. |
| `R/build_nli_claim_units.R` | `nli_claim_units`, `nli_claim_units_flat` | Enumerates one unit per `(km, bm, sentence_source, sentence_number)` claim remaining to score for an assessment (after the `approx_tokens > max_length` filter), sorted by pair count descending. Carries only identifying keys + the assessment's `nli_ready_parquet` path — **not** premises, so cached branch values stay small regardless of claim size. `nli_claim_units_flat` flattens the per-assessment lists into one combined list so the next target can branch one-target-per-claim across all assessments. |
| `R/score_one_claim.R` | `nli_scores_by_claim` | **Active NLI scoring**, one `targets` dynamic branch per claim (not per host/BM). Dynamic host dispatch: tries every host's file lock (`output/nli_scores/.locks/host_NN.lock`, via `filelock`) in turn — whichever host is free next gets the claim, so assignment happens when a worker becomes free rather than from an upfront LPT-style estimate. Local concurrency comes from a `crew_controller_local` (workers sized to the pool's host count, set in `_targets.R`'s `tar_option_set()`). Resumable: skips a claim immediately if its `claim_id=` output directory already has parquet files. `error = "continue"` on the target means a failing claim is reported live and marked failed while every other claim proceeds independently — no more losing an entire host's remaining backlog to one bad request, and no more silence until the whole build finishes (the old `mclapply`-per-host design's two failure modes). Rows with `approx_tokens > max_length` are skipped upstream (logged; see NEXT_STEPS.md). Writes to `output/nli_scores/nli_config=<cfg>/assessment=<id>/km=<km>/bm=<bm>/claim_id=<claim_id>/` |
| `R/resolve_citations.R` | *(orphaned — no active target)* | Replace `(Author, Year)` citations with OpenAlex W-IDs; legacy `resolved_sections_parquet` builder, no longer wired in `_targets.R` |
| `R/build_prompts_truth_parquet.R` | *(PARKED — `prompts_truth_parquet` commented out)* | One structured-JSON truth doc per `(assessment, KM, BM)`. Each row has a nested `sub_messages` list-of-struct column (per-SM metadata + per-SM `sources` list with `section`/`subsection`/`content`) plus a `prompt` column that serialises the same payload as JSON for the LLM. Writes to `output/prompts/truth/assessment=<id>/` |
| `R/build_prompts_citing_parquet.R` | *(PARKED — `prompts_citing_parquet` commented out)* | One structured-JSON candidate prompt per row of `works_citing_parquet`. Flat payload (assessment, km, bm, work_id, doi, publication_year, title, abstract, relation) serialised to JSON in the `prompt` column. Iterates per-km/bm parquet to dodge OpenAlex schema mismatches. Writes to `output/prompts/citing/assessment=<id>/km=<km>/bm=<bm>/` |
| `R/build_alignement_scores_parquet.R` | *(PARKED — `alignement_scores_*` commented out)* | Per `analysis.runs[]` config, score the first `n_citing` (or all, if `0`) citing prompts against the matching truth prompt via OpenRouter / ellmer. Uses shared `(system + truth)` prefix so the provider's automatic prefix caching kicks in. Writes to `output/alignement_scores/assessment=<id>/run_id=<run_id>/` |
| `R/build_fulltext.R` | *(orphaned — no active target)* | Download Grobid XML or PDF for each work in `works_citing`; legacy `fulltext_files` builder, no longer wired in `_targets.R` |
| `R/build_alignement_parquet.R` | *(orphaned — no active target)* | Legacy single-pass scoring builder superseded by `build_alignement_scores_parquet.R`; kept for side-by-side reference |

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
- `output/sections/` — DB2 parquet (section content; now includes `sm` column linking each SubChapter to the SubMessage that references it)
- `output/key_messages/` — DB3 parquet (KM, BM, and SM descriptive text with confidence flags)
- `output/resolved_sections/` — sections with `(Author, Year)` replaced by OpenAlex W-IDs
- `output/zotero/` — Zotero parquet dataset partitioned by assessment/group id/page
- `output/works/` — OpenAlex works parquet dataset partitioned by assessment/km/bm
- `output/snowball/` — snowball parquet datasets: nodes (assessment/km/bm/relation), edges (assessment/km/bm/edge_type), keypaper (assessment/km/bm)
- `output/works_citing/` — papers citing the seed works, partitioned by assessment/km/bm
- `output/nli_scores/` — NLI SUPPORTS/REFUTES/NEI scores per citing work, partitioned by assessment/km/bm/claim_id
- `output/prompts/truth/` — *(PARKED)* rendered truth-document prompts per `(KM, BM)`, partitioned by assessment
- `output/prompts/citing/` — *(PARKED)* rendered candidate-paper prompts per citing work, partitioned by assessment/km/bm
- `output/alignement_scores/` — *(PARKED)* LLM alignement scores, partitioned by assessment/run_id/km/bm/model/replicate
- `output/fulltext/` — *(no longer produced; gitignored to keep stale dirs out of commits)* per-work Grobid XML/PDF/sentinel files from the orphaned `build_fulltext.R`
- `output/resolved_sections/` — *(no longer produced)* sections with `(Author, Year)` replaced by OpenAlex W-IDs from the orphaned `resolve_citations.R`
- `output/alignement/` — *(no longer produced)* scores from the legacy `build_alignement_parquet.R`; superseded by `output/alignement_scores/`
- `output/snowballs/` — per-paper snowball `.rds` files (QMD pipeline)
- `output/nodes/`, `output/edges/` — parquet datasets (QMD pipeline)
