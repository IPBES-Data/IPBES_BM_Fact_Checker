# `output/` — what's in here and where it comes from

Everything under `output/` is gitignored and reproducible from source via
`targets::tar_make()` (see the project root `CLAUDE.md` for the full data
flow). This file tracks *which* of the following folders are still
produced by the live pipeline, which are intentionally parked for a
planned future stage, and which are dead leftovers safe to delete.

## Active — produced by a live target in `_targets.R`

| Folder | Produced by | Contents |
|---|---|---|
| `LoD/` | `ttl_path` (`R/download_ttls.R`) | Downloaded IPBES LOD Turtle files, one per assessment |
| `refs/` | `refs_parquet` (`R/write_refs_parquet.R`) | DB1: references with Zotero group/key citations, partitioned by assessment |
| `sections/` | `sections_parquet` (`R/write_sections_parquet.R`) | DB2: section content, partitioned by assessment |
| `key_messages/` | `key_messages_parquet` (`R/write_key_messages_parquet.R`) | DB3: KM/BM/SM descriptive text, partitioned by assessment |
| `zotero/` | `zotero_parquet` (`R/download_zotero.R`) | Zotero group items, partitioned by assessment/group id/page |
| `works/` | `works_parquet` (`R/download_works.R`) | OpenAlex metadata for GA1-reference works, partitioned by assessment/km/bm |
| `snowball/` | `snowball_parquet` (`R/build_snowball_parquet.R`) | Snowball search nodes/edges/keypaper, partitioned by assessment/km/bm/relation |
| `works_citing/` | `works_citing_parquet` (`R/build_works_citing_parquet.R`) | Papers citing the seed works, partitioned by assessment/km/bm |
| `nli_ready_evidence/` | `nli_ready_evidence_parquet` (`R/build_nli_ready_evidence_parquet.R`) | Work × BM-claim cross-join, evidence-reference segmentation (2-17 claims per BM) — the **active** segmentation approach |
| `nli_scores_evidence/` | `nli_scores_by_claim_evidence` (`R/score_one_claim.R`) | SUPPORTS/REFUTES/NEI scores per citing work per claim — the **active** scoring output, feeds the report |
| `tables/` | Several targets (see below) | Rendered DT/plotly HTML tables + their rds caches |
| `figures/` | Several targets (see below) | Rendered PNG/SVG figures and Mermaid diagrams |
| `reports/` | `report_output_dir` (`R/build_report_output_dir.R`) | The deployable site: `IPBES_Fact_Checker.html` + every `TD_*.html`, each with its `_files/` sidecar, plus `index.html`/`.nojekyll`. Published to `gh-pages` by `scripts/deploy_gh_pages.sh` |

`tables/` breakdown:
- `nli_bm_explorer_<id>.html` (+ `_files/`) — interactive per-BM explorer (`build_nli_bm_explorer`)
- `nli_overview_data_<id>.rds` — cached summary tables (`build_nli_overview_data`)
- `overlap_key_paper.html`/`.rds` (+ `_files/`) — key-paper overlap table (`build_overlap_key_paper_table`)
- `overlap_after_2018_sub_messages.html`/`.rds` (+ `_files/`) and `overlap_after_2018_background_messages.html`/`.rds` (+ `_files/`) — post-2018 citing-paper overlap tables

`figures/` breakdown:
- `fig_pub_per_year.{png,svg,pdf}` — publications-per-year by BM (`build_fig_pub_per_year`)
- `nli_overview_plot_*_<id>.png` — per-assessment label/confidence/alignment plots (`build_nli_overview_figures`)
- `workflow_nli.{png,svg}` / `pipeline_nli.{png,svg}` — active-approach diagrams (rendered from `input/mmd/workflow_nli.mmd` and the auto-generated `input/mmd/pipeline_nli.mmd`)
- `workflow_lm.{png,svg}` / `pipeline_lm.{png,svg}` — frozen parked-LLM-approach diagrams (reference only)

## Parked — intentionally not produced right now, part of a planned future stage

| Folder | Belongs to | Why it's not stale |
|---|---|---|
| `prompts/` | `prompts_truth_parquet` / `prompts_citing_parquet` (commented out in `_targets.R`) | Inputs for the **planned two-stage NLI → LLM verification pipeline** (see `TD_NLI_LLM_two_phase.qmd`, `TODO.md`): NLI runs first, then an LLM re-checks `REFUTES`/uncertain/low-confidence `SUPPORTS` cases using the NLI label+confidence as a prior. `llm_scores_parquet` (Phase 2) hasn't been implemented yet — this is why the target is commented out, not because the approach was abandoned. Keep until Phase 2 is built or explicitly dropped. |

## Orphaned — no active target, safe to delete

Nothing in the current `_targets.R` reads from or writes to these; their
source `.R` files exist on disk but were never wired into the pipeline
(fulltext/resolved_sections), or the approach was superseded
(alignement), or they're leftovers from before a naming split
(figures listed below).

| Folder / files | Size (as of 2026-08-12) | Superseded by / why dead |
|---|---|---|
| `fulltext/` | 8.5G | `R/build_fulltext.R` — never wired into `_targets.R` |
| `resolved_sections/` | 51M | `R/resolve_citations.R` — never wired into `_targets.R` |
| `alignement/` | 120K | `R/build_alignement_parquet.R` — superseded by the (also parked) `alignement_scores` chain |
| `figures/pipeline.{png,svg}`, `figures/workflow.{png,svg}`, `figures/layout_handdrawn.png` | small | Leftovers from before the diagrams split into `_nli`/`_lm` variants — nothing references the bare names anymore |

Already removed (documented here so it doesn't get "rediscovered" as a mystery later):
- `nli_scores/` — deleted 2026-08-12. Was the per-sentence scoring chain's output (`nli_scores_by_claim`, now commented out in `_targets.R` since it's not consumed by the report — see that target's comment for the full story).
- `overlap_key_paper_files/` (at the `output/` root, not inside `output/tables/`) — deleted 2026-08-12. Stale duplicate from before the code settled on writing to `output/tables/`; the real one lives at `tables/overlap_key_paper_files/`.

## A gray area — active target, but a dead-end downstream

| Folder | Status |
|---|---|
| `nli_ready/` | `nli_ready_parquet` (the per-sentence segmentation source) is **still an active, uncommented target** — `tar_make()` keeps it up to date. But its only consumer chain (`nli_claim_units` → `nli_claim_units_flat` → `nli_scores_by_claim`) is commented out, so as of 2026-08-12 this folder (2.7G) is being maintained for no downstream purpose. Not "orphaned" in the same sense as the table above — it's one decision away from either being pruned (comment out the whole chain) or resurrected (uncomment `nli_scores_by_claim`) — see that target's comment in `_targets.R` for context. |
