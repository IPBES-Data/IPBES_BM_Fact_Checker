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

**System dependency:** `fuseki-server` must be on `PATH` when `sparql_url: fuseki` (default). Install with `brew install fuseki`.

**Credentials:** `_targets.R` reads `API_openalex` and `API_openrouter` from the macOS keyring at startup via `keyring::key_get()`. Set them before running `tar_make()`:

```r
keyring::key_set("API_openalex")
keyring::key_set("API_openrouter")
```

**Not wired into `_targets.R` (source files exist but no active target):** `R/build_fulltext.R`, `R/build_alignement_parquet.R`, `R/resolve_citations.R`. Their corresponding outputs (`output/fulltext/`, `output/alignement/`, `output/resolved_sections/`) are no longer produced by the live pipeline.

### Quarto Report

The report (`IPBES_Fact_Checker.qmd`) IS wired into the `targets` pipeline — `tar_make(report_fact_checker)` (or a plain `tar_make()`) builds every upstream target it needs and then renders it:

```r
targets::tar_make(names = "report_fact_checker")
```

`qmd_fact_checker` (file-hash tracked on `IPBES_Fact_Checker.qmd` itself) and `nli_bm_explorer_html`/`td_doc_html` (the interactive widgets and rendered design docs it links to) are all dependencies of `report_fact_checker`, so editing the qmd's prose, code, or YAML header, or any upstream data these embeds depend on, correctly invalidates the render. The report copies every heavy standalone HTML artifact it references (BM explorer widgets, overlap tables, rendered `TD_*` docs) into its own `IPBES_Fact_Checker_files/` sidecar directory at render time (via a `copy_into_report_files()` helper defined in the qmd's `setup` chunk) — so distributing the report only requires `IPBES_Fact_Checker.html` + `IPBES_Fact_Checker_files/`, not those source directories/files alongside it.

**Technical Design (`TD_*.md`) documents** are rendered the same way: each has a thin `TD_<name>.qmd` wrapper (same `format: html` block as the main report, body is just `{{< include TD_<name>.md >}}`) so they get consistent styling and become standalone linkable HTML pages, while the actual prose stays in the single-source-of-truth `.md` file. `td_doc_names` (a plain character vector target) branches into `td_doc_qmd`/`td_doc_md` (file-hash tracked) → `td_doc_html` (`quarto::quarto_render()` per branch) — adding a new TD doc is a one-line addition to `td_doc_names` plus a new `TD_<name>.qmd` wrapper file. The report's Methods section reads `td_doc_html` via `tar_read()` and links to the copied-in versions.

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
hosts (see [external/runpod/docker/nli-runpod/](external/runpod/docker/nli-runpod/), a git
submodule — see `runpod_migration_IPBES_BM_Fact_Checker/TODO_migration_runpod.md`
for the migration off this repo's own former copy). Premise = cleaned `title`+`abstract`;
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
| `R/build_nli_claim_units.R` | `nli_claim_units`, `nli_claim_units_flat` | Enumerates one unit per `(km, bm, sentence_source, sentence_number)` claim remaining to score for an assessment, sorted by pair count descending. The `approx_tokens <= max_length` filter here only affects **which rows are counted** for the largest-first ordering — it does **not** limit what gets scored (a claim with any in-budget row is enumerated, and `score_one_claim()` then scores every work of that claim; in practice all 600 claims are enumerated). Carries only identifying keys + the assessment's `nli_ready_parquet` path — **not** premises, so cached branch values stay small regardless of claim size. `nli_claim_units_flat` flattens the per-assessment lists into one combined list so the next target can branch one-target-per-claim across all assessments. |
| `R/score_one_claim.R` | `nli_scores_by_claim` | **Active NLI scoring**, one `targets` dynamic branch per claim (not per host/BM). Dynamic host dispatch: tries every host's file lock (`output/nli_scores/.locks/host_NN.lock`, via `filelock`) in turn — whichever host is free next gets the claim, so assignment happens when a worker becomes free rather than from an upfront LPT-style estimate. Local concurrency comes from a `crew_controller_local` (workers sized to the pool's host count, set in `_targets.R`'s `tar_option_set()`). Resumable: skips a claim immediately if its `claim_id=` output directory already has parquet files. `error = "continue"` on the target means a failing claim is reported live and marked failed while every other claim proceeds independently — no more losing an entire host's remaining backlog to one bad request, and no more silence until the whole build finishes (the old `mclapply`-per-host design's two failure modes). **Every work of a scored claim is scored** — `score_one_claim()` does not re-apply any token filter, so pairs longer than `max_length` are TRUNCATED by the server (`truncation="longest_first"` trims the abstract tail, preserving the short hypothesis), not skipped. See NEXT_STEPS.md for the optional abstract-chunking enhancement if lossless long-abstract handling is ever wanted. Writes to `output/nli_scores/nli_config=<cfg>/assessment=<id>/km=<km>/bm=<bm>/claim_id=<claim_id>/` |
| `R/build_nli_overview_data.R` | `nli_overview_data` | Per-assessment label/confidence/alignment summary tables (overall, per-KM, per-BM) read once from the on-disk scored-output path and cached as a single rds (`output/tables/nli_overview_data_<id>.rds`), so downstream figure/report targets don't re-`collect()` the raw dataset. Also caches trimmed per-row `raw` (km, bm, work_id, doi, label, confidence, alignment) — the input to `build_nli_bm_explorer()`; `work_id`/`doi` feed its drill-down table. `doi` comes from a left-join against `works_citing_path` (matched on `work_id == id`, both `https://openalex.org/W...` strings) — collapsed to one row per `work_id` first (picking any non-NA doi) since a work can appear once per km/bm partition it's cited from, so the join can't fan out and duplicate scored rows. **Wired to the evidence-segmentation chain only** (`output/nli_scores_evidence`, depends on `nli_scores_by_claim_evidence`), *not* the original per-sentence one (`output/nli_scores` / `nli_scores_by_claim`) — both scoring targets share `score_one_claim()`, so editing that file marks both outdated together regardless of which approach is actually being run, and the per-sentence chain has historically lagged far behind (e.g. 14/725 claims scored while evidence scoring was live). Wiring the report to the per-sentence target let `tar_make(report_fact_checker)` transitively try to dispatch hundreds of unscored per-sentence claims through the same live host pool as an in-progress evidence run — keep this pointed at the evidence chain unless you deliberately want to switch it back (and are prepared for `nli_scores_by_claim` to get pulled in). |
| `R/build_nli_overview_figures.R` | `nli_overview_figures` | Static ggplot PNGs per assessment: overall/per-KM/per-BM label split, confidence density, alignment density. Writes to `output/figures/`. |
| `R/build_fig_pub_per_year.R` | `fig_pub_per_year` | Number of new publications per year, grouped by background message, among papers citing the key papers (the forward/discovery direction of the snowball search). Reads `works_citing_parquet` directly (`relation == "citing"` is already the forward direction). `works_citing_path` arrives as a vector — one directory per assessment branch, consumed here without a `pattern` so `targets` aggregates all branches into one call — and since each element's own root (`assessment=<id>`) isn't surfaced by Arrow as a column when it's the dataset's own root, `assessment` is parsed back out of the path per element. |
| `R/build_overlap_key_paper_table.R` | `overlap_key_paper_table` | Overlap table: key/seed papers (`works_parquet`) referenced in more than one background message. `works_parquet` has one row per `(paper, km, bm)` combination (a paper cited in N BMs appears N times via a many-to-many join against refs), so grouping by `id` and counting distinct km/bm pairs directly gives the overlap count — no snowball data needed. Includes an `author` column (safe here, unlike the two `overlap_after_2018_*` variants below, since `works_parquet` comes from one `pro_fetch()` call per assessment with one consistent schema). Writes a DT-table HTML to `output/tables/overlap_key_paper.html`. |
| `R/build_overlap_after_2018_sub_messages_table.R` | `overlap_after_2018_sub_messages_table` | Overlap table: citing papers (`works_citing_parquet`) published after `cutoff_year` (default 2018), referenced from more than 5 background messages. Named "sub_messages" for continuity with the legacy report; the active pipeline has no sub-message level, so this and the background-messages variant group identically (by km/bm) — kept as a separate target only for report-section continuity, not because the two computations differ. No `author` column: `works_citing`'s `authorships` struct column has inconsistent nested schemas across different (km, bm) batches within the same assessment (each `pro_snowball()` call infers its own schema — see `build_snowball_parquet.R`), so collecting it across batches errors ("Some attributes are incompatible" from `vctrs`). |
| `R/build_overlap_after_2018_background_messages_table.R` | `overlap_after_2018_background_messages_table` | Identical grouping to the "sub_messages" variant above, but additionally carries the `abstract` column, matching the legacy report's background-message variant. Same `author`-column omission and reasoning as `build_overlap_after_2018_sub_messages_table.R`. |
| `R/build_nli_bm_explorer.R` | `nli_bm_explorer_html` | Interactive plotly widget per assessment with **three** linked controls — a BM-select dropdown (default "All BMs"), a minimum-confidence slider (0-0.9, default 0.5), and a table-label dropdown (REFUTES/SUPPORTS/NOT_ENOUGH_INFO, default REFUTES). The BM dropdown + slider jointly pick one precomputed `(bm, threshold)` cell for the three chart panels; all three controls together pick one `(bm, threshold, label)` cell for a drill-down table below the chart. All works are always shown in the charts (no filtering); the threshold instead splits every bar into two **stacked** segments via `barmode = "stack"`: confidence-≥-threshold (solid fill, bottom, hover shows `label: xx.xx%`) and confidence-<-threshold (hollow/outline-only via transparent `marker.color` + colored `marker.line`, on top) — label distribution (%) splits each label's bar this way (each bar also labelled `n / N` via `text`/`textposition = "outside"` on the top trace — `format(..., trim = TRUE)` is required there, since `format()` on a multi-element vector right-pads shorter numbers to a common width by default, which otherwise leaks stray spaces into the label), the confidence-histogram panel splits each bin by its own mid vs threshold (plus a dashed threshold line), and the alignment-histogram panel splits each bin by how many of its works meet the threshold (a genuine cross-tab, computed via two separate `hist()` calls on the above/below subsets sharing the same breaks). All three controls are `method = "skip"` (native dropdown/slider UI + active-index tracking, no automatic restyle) and a small `htmlwidgets::onRender()` JS handler reads all three current indices from the widget's own layout and applies one combined `Plotly.restyle`/`Plotly.relayout` for the charts, plus swaps a precomputed HTML string into a plain `<div>`/`<table>` appended right after the chart in the DOM for the drill-down table (work linked to its DOI when one exists, else OpenAlex, both real clickable `<a>` tags; confidence; alignment; sorted by confidence descending, capped at 50 rows with the true match count always in the caption) and wires a "Download table (CSV)" button. The download is deliberately **not** limited to the 50 on-screen rows: it draws from a separate, coarser-grained precomputed grid — one array per `(bm, label)` (93 buckets for GA1's 30 BMs), NOT per `(bm, threshold, label)` — because a threshold is just a `confidence >=` cutoff on an already-confidence-sorted list, so storing it once per `(bm, label)` and slicing off the leading run client-side (via `downloadRowsFor()`) avoids re-embedding the same rows once per threshold step; a first version that naively stored per `(bm, threshold, label)` cell (930 of them) produced a 166MB file for GA1 alone, confirmed by direct measurement, before this redesign brought it down to ~37MB. Each `(bm, label)` array is capped at `download_row_cap` (5000, well above `table_row_cap`) and includes `Assessment` and `BM` as explicit CSV columns (`BM` carried per-row, since under "All BMs" each row belongs to a different actual BM) — exact match counts per `(bm, threshold, label)` (needed to flag truncation accurately even though the full row data isn't stored per-threshold) are reused cheaply from the existing `lab_above_n` stats already computed for the bar-chart panels (`match_counts_flat`), re-indexed from `label_levels` order into `label_sel_options` order to match the dropdown. The table is deliberately **not** a plotly `type = "table"` trace: two real bugs were found there by isolated repro before this design was adopted — (1) plotly table cells render any HTML they're given as escaped plain text (an `<a href=...>` shows up as literal angle brackets, not a link — so DOI links would never have been clickable), and (2) calling `add_trace()` repeatedly on an already-`subplot()`-merged figure (as opposed to a fresh `plot_ly()` object) leaves each new trace's internal plotly "attrs" bookkeeping entry unnamed, which crashed `htmlwidgets::saveWidget()`'s `shouldEval()` validation once mixed with the properly-named bar-trace attrs at realistic scale (30+ BMs); a naive splice-in-a-fresh-object workaround for that also introduced a silent off-by-one (a phantom placeholder trace from the bare `plot_ly()` base call shifted every table index by one — every dropdown/slider combination would have shown the wrong table). The DOM-table redesign sidesteps all of this. Per-cell HTML uses CSS classes (`.nli-tbl` etc., injected once into `<head>`) rather than repeating inline `style=` on every cell — at up to 50 rows x ~900 cells that repetition alone had roughly doubled the saved file size. Verified end-to-end against a real headless-Chrome DOM (`chromote`) at full production scale (30 BMs, ~1.9M rows): all three controls combine correctly (changing any one preserves the other two), marker fill/outline styling and n/N counts are exactly as intended, DOI links are genuine clickable anchors (`href`/`textContent` checked directly, not just "does it render"), the download button's `Blob` was intercepted and its CSV content verified row-for-row against the visible table, and a screenshot confirmed no layout overlap between the controls, annotations, panel titles, and charts. `save_nli_bm_explorer()` writes the figure as a self-contained standalone HTML (`htmlwidgets::saveWidget(selfcontained = TRUE)`) to `output/tables/nli_bm_explorer_<id>.html`, embedded in the report via `<iframe>` — deliberately **not** printed in-place via `cat(knitr::knit_print(widget))` inside the report's `results: asis` loop, which was tried first and found to not propagate the plotly.js dependency under Quarto's HTML output (empty div, no chart); the iframe/saveWidget route matches the existing convention for other interactive artifacts (e.g. `build_overlap_key_paper_table`'s DT tables). |
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
