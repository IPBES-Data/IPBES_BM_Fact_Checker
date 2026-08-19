# `output/` — what's in here and where it comes from

Everything under `output/` is gitignored and reproducible from source via
`targets::tar_make()` (see the project root `CLAUDE.md` for the full data
flow). This file tracks *which* of the following folders are still
produced by the live pipeline, and which are dead leftovers safe to delete.

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
| `llm_candidate_scope/` | `llm_candidate_scope_parquet` (`R/build_llm_candidate_scope_parquet.R`) | Per-claim citing-work allow-list for `subset: "sm"` configs — derived from IPBES's own sub-chapter evidence references, not from download/snowball/NLI directly. Partitioned by assessment/km/bm. Always computed; `subset: "all"` configs never read it |
| `llm_verification/raw/` | `llm_verification_parquet` (`R/build_llm_verification_parquet.R`) | Phase 2's resumable per-pair JSON cache, one file per `(claim_id, work_id)`, partitioned by `model=<model>/prompt=<hash>` |
| `llm_verification/scores/` | `llm_verification_parquet` (`R/build_llm_verification_parquet.R`) | Phase 2 LLM review of whichever NLI slice the active config's `nli_labels`/`nli_certainty` select (currently `REFUTES`+`SUPPORTS`, both `certain`, on every shipped config), optionally narrowed by `llm_candidate_scope/` — see [TD_NLI_LLM_two_phase.qmd](../TD_NLI_LLM_two_phase.qmd). Partitioned by `llm_config` (the selected `input/config.yaml` `llm_verification.configs` entry name)/`subset` (`all` or `sm`)/assessment/`nli_route` (that row's own outcome, e.g. `REFUTES-certain` or `SUPPORTS-certain` — one subdirectory per distinct outcome actually present, even within a single config call)/km/bm. Not yet merged into `nli_overview_data`/the main report's own tables, but consumed by the label funnel reports below |
| `tables/` | Several targets (see below) | Rendered DT/plotly HTML tables + their rds caches |
| `figures/` | Several targets (see below) | Rendered PNG/SVG figures and Mermaid diagrams |
| `reports/` | `report_output_dir` (`R/build_report_output_dir.R`) | The deployable site: `IPBES_Fact_Checker.html` + every `TD_*.html` + every `IPBES_REFUTES_Report_<id>.html`/`IPBES_SUPPORTS_Report_<id>.html`, each with its `_files/` sidecar, plus `index.html`/`.nojekyll`. Published to `gh-pages` by `.github/workflows/deploy-pages.yml` |

`tables/` breakdown:
- `nli_bm_explorer_<id>.html` (+ `_files/`) — interactive per-BM explorer (`build_nli_bm_explorer`)
- `nli_overview_data_<id>.rds` — cached summary tables (`build_nli_overview_data`)
- `overlap_key_paper.html`/`.rds` (+ `_files/`) — key-paper overlap table (`build_overlap_key_paper_table`)
- `overlap_after_2018_sub_messages.html`/`.rds` (+ `_files/`) and `overlap_after_2018_background_messages.html`/`.rds` (+ `_files/`) — post-2018 citing-paper overlap tables
- `refutes_funnel_data_<id>.rds` / `supports_funnel_data_<id>.rds` — cached label-funnel counts, one per (assessment, label) (`build_label_funnel_data`)
- `refutes_funnel_table_l3_<id>.html`/`.rds` (+ `_files/`) and `supports_funnel_table_l3_<id>.html`/`.rds` (+ `_files/`) — each funnel's level-3 BM-filterable DT table (`build_label_funnel_tables`)

`figures/` breakdown:
- `fig_pub_per_year.{png,svg,pdf}` — publications-per-year by BM (`build_fig_pub_per_year`)
- `nli_overview_plot_*_<id>.png` — per-assessment label/confidence/alignment plots (`build_nli_overview_figures`)
- `fig_{refutes,supports}_funnel_overall_<id>.png` / `fig_{refutes,supports}_funnel_by_bm_<id>.png` / `fig_{refutes,supports}_funnel_by_bm_normalized_<id>.png` — each label funnel's overall, per-BM, and normalized-per-BM (each BM's own corpus = 1) charts (`build_label_funnel_figures`)
- `workflow_nli.{png,svg}` / `pipeline_nli.{png,svg}` — active-approach diagrams (rendered from `input/mmd/workflow_nli.mmd` and the auto-generated `input/mmd/pipeline_nli.mmd`)

## Orphaned — no active target, safe to delete

Nothing in the current `_targets.R` reads from or writes to these; their
source `.R` files exist on disk but were never wired into the pipeline
(fulltext/resolved_sections), or they're leftovers from before a naming
split (figures listed below).

| Folder / files | Size (as of 2026-08-12) | Superseded by / why dead |
|---|---|---|
| `fulltext/` | 8.5G | `R/build_fulltext.R` — never wired into `_targets.R` |
| `resolved_sections/` | 51M | `R/resolve_citations.R` — never wired into `_targets.R` |
| `figures/pipeline.{png,svg}`, `figures/workflow.{png,svg}`, `figures/layout_handdrawn.png` | small | Leftovers from before the diagrams split into `_nli`/`_lm` variants — nothing references the bare names anymore |

Already removed (documented here so it doesn't get "rediscovered" as a mystery later):
- `nli_scores/` — deleted 2026-08-12. Was the per-sentence scoring chain's output (`nli_scores_by_claim`, now commented out in `_targets.R` since it's not consumed by the report — see that target's comment for the full story).
- `overlap_key_paper_files/` (at the `output/` root, not inside `output/tables/`) — deleted 2026-08-12. Stale duplicate from before the code settled on writing to `output/tables/`; the real one lives at `tables/overlap_key_paper_files/`.
- `prompts/` (653M) — deleted 2026-08-17, along with the truth/citing-document LLM-comparison chain it belonged to (`R/build_prompts_truth_parquet.R`, `R/build_prompts_citing_parquet.R`, `R/build_alignement_scores_parquet.R`, `R/alignement_schema.R`, `R/build_alignement_parquet.R`, all removed). That chain was the once-"parked" planned Phase 2 of the NLI → LLM pipeline; it was replaced outright by `llm_verification/` (below) rather than un-parked — see [TD_LLM_approach.qmd](../TD_LLM_approach.qmd) for the design record and [TD_NLI_LLM_two_phase.qmd](../TD_NLI_LLM_two_phase.qmd) for what actually shipped.

## A gray area — active target, but a dead-end downstream

| Folder | Status |
|---|---|
| `nli_ready/` | `nli_ready_parquet` (the per-sentence segmentation source) is **still an active, uncommented target** — `tar_make()` keeps it up to date. But its only consumer chain (`nli_claim_units` → `nli_claim_units_flat` → `nli_scores_by_claim`) is commented out, so as of 2026-08-12 this folder (2.7G) is being maintained for no downstream purpose. Not "orphaned" in the same sense as the table above — it's one decision away from either being pruned (comment out the whole chain) or resurrected (uncomment `nli_scores_by_claim`) — see that target's comment in `_targets.R` for context. |

## Details

Column-by-column reference for the Active datasets above. Types are as
stored on disk (`arrow::schema()`); `string`/`int32`/`bool` etc. are Arrow
types, not R types. For the OpenAlex-passthrough datasets (`works/`,
`snowball/nodes`, `snowball/keypaper`, `works_citing/`), only the
project-added columns are described — the ~50 raw OpenAlex `Work` fields
(`title`, `authorships`, `topics`, `abstract_inverted_index`, ...) are
documented by the [OpenAlex API](https://docs.openalex.org/api-entities/works/work-object)
itself and passed through unmodified.

### `refs/` (DB1)

Built by `extract_refs_from_endpoint()` (`R/extract_lod.R`) from
[queries/refs.sparql](../queries/refs.sparql): KM → BM → SM → SubChapter ←
Reference, one row per `(bm, sm, reference)` triple.

| Column | Type | Meaning |
|---|---|---|
| `km` | string | Key Message identifier |
| `bm` | string | Background Message identifier |
| `sm` | string | Sub-Message identifier |
| `doi` | string | DOI of the reference cited by this SM's sub-chapter |
| `description` | bool | Value of `ipbes:hasDescription` on the `Reference` node — a boolean flag in the LOD data (not free text; contrast with `km_description`/`bm_description`/`sm_description` in `key_messages/`, which are prose) |
| `zotero` | string | Raw `owl:sameAs` URI to the Zotero item, e.g. `https://www.zotero.org/groups/<group>/items/<key>`, when the reference has one |
| `zotero_group` | string | Zotero group ID parsed out of `zotero` via `extract_zotero_group()` (`R/extract_lod.R`) |
| `zotero_key` | string | Zotero item key parsed out of `zotero` via `extract_zotero_key()` (`R/extract_lod.R`) |
| `citation` | string | Synthesized `"[<zotero_key>]"` citation-key string, or `NA` when there's no Zotero key |
| `assessment` | string | Assessment ID this row belongs to |

### `sections/` (DB2)

Built by `extract_sections_from_endpoint()` from
[queries/sections.sparql](../queries/sections.sparql): KM → BM → SM →
SubChapter(content) → Chapter(section).

| Column | Type | Meaning |
|---|---|---|
| `km`, `bm`, `sm` | string | Same identifiers as `refs/` |
| `section` | string | Identifier of the Chapter containing this SubChapter |
| `subsection` | string | Identifier of the SubChapter itself |
| `content` | string | Free text from `ipbes:hasDescription` on the SubChapter |
| `assessment` | string | Assessment ID |

### `key_messages/` (DB3)

Built by `extract_key_messages_from_endpoint()` from
[queries/key_messages.sparql](../queries/key_messages.sparql): one row per
`(km, bm, sm)` combination, carrying each level's own label/description/
confidence text.

| Column | Type | Meaning |
|---|---|---|
| `km` | string | Key Message identifier |
| `km_label` | string | KM `skos:prefLabel` |
| `km_description` | string | KM free text from `ipbes:hasDescription` |
| `bm` | string | Background Message identifier |
| `bm_label` | string | BM `skos:prefLabel` |
| `bm_description` | string | BM free text — this is the **hypothesis text used throughout NLI/LLM scoring** (segmented into claims by `build_nli_ready_evidence_parquet.R`) |
| `bm_well_established` | string | BM confidence annotation from `ipbes:hasWellestablished` |
| `bm_established_incomplete` | string | BM confidence annotation from `ipbes:hasEstablishedIncomplete` |
| `sm_id` | string | Sub-Message identifier |
| `sm_description` | string | SM free text from `ipbes:hasDescription` |
| `sm_well_established` | string | SM confidence annotation from `ipbes:hasWellestablished` |
| `sm_established_incomplete` | string | SM confidence annotation from `ipbes:hasEstablishedIncomplete` |
| `assessment` | string | Assessment ID |

### `zotero/`

Built by `R/download_zotero.R` from the Zotero group API, one row per
Zotero item referenced from `refs_parquet`.

| Column | Type | Meaning |
|---|---|---|
| `key` | string | Zotero item key (matches `refs_parquet$zotero_key`) |
| `item_type` | string | Zotero item type (e.g. `journalArticle`) |
| `title` | string | Item title |
| `authors` | string | Author list, flattened to a single string |
| `first_author` | string | First author only |
| `year` | string | Publication year |
| `doi` | string | DOI, when Zotero has one on file |
| `abstract` | string | Zotero's own abstract field, when present |
| `zotero_url` | string | Link back to the item in the Zotero web library |
| `assessment` | string | Assessment ID |
| `group_id` | int32 | Zotero group ID this item was fetched from |
| `page` | int32 | Zotero API pagination page this item was fetched on |

### `works/`, `snowball/nodes`, `snowball/keypaper`, `works_citing/`

All four are raw OpenAlex `Work` objects (`openalexPro::pro_fetch()` /
`openalexSnowball::pro_snowball()`) plus a handful of project-added columns:

| Column | Present in | Meaning |
|---|---|---|
| `assessment`, `km`, `bm` | all four | Assessment/KM/BM this work was fetched or discovered under |
| `oa_input` | `snowball/nodes`, `snowball/keypaper`, `works_citing` | `TRUE` for a GA1 seed reference itself ("key paper"), `FALSE` for a paper discovered via snowball search |
| `relation` | `snowball/nodes`, `snowball/keypaper` (not `works_citing`) | Snowball direction: e.g. `"citing"` (papers citing the seed) vs. other relation types the snowball search records |
| `citation`, `page`, `query` | `works/` only | Bookkeeping columns from the `pro_fetch()` call (source citation string, result page, query used) — not the same as `refs_parquet$citation` |

`snowball/edges` is a separate, much narrower dataset (citation graph edges,
not Work objects):

| Column | Type | Meaning |
|---|---|---|
| `from` | string | OpenAlex work ID of the citing work |
| `to` | string | OpenAlex work ID of the cited work |
| `assessment`, `km`, `bm` | string | Assessment/KM/BM this edge was discovered under |
| `edge_type` | string | Snowball edge type |

### `nli_ready_evidence/`

Built by `R/build_nli_ready_evidence_parquet.R`: one row per
`(citing work × BM-claim)` pair, ready to be scored by NLI.

| Column | Type | Meaning |
|---|---|---|
| `sentence_number` | int | 1-based index of this claim within its `sentence_source` field |
| `claim` | string | The claim's hypothesis text (a BM/label fragment segmented at a terminal evidence brace, braces stripped) |
| `sentence_source` | string | Which BM field this claim was segmented from (`bm_description` or `bm_label`) |
| `work_id` | string | OpenAlex ID of the citing work (the premise side of the pair) |
| `premise` | string | Cleaned title + abstract of the citing work (`R/clean_text.R`) |
| `abstract_tokens`, `sentence_tokens`, `approx_tokens` | int | Rough token-count estimates used for largest-first claim ordering and truncation awareness downstream |
| `assessment`, `km`, `bm` | string | Assessment/KM/BM this pair belongs to |

### `nli_scores_evidence/`

Built by `R/score_one_claim.R`: Phase 1 NLI verdict for each
`(claim, work)` pair in `nli_ready_evidence/`.

| Column | Type | Meaning |
|---|---|---|
| `nli_model` | string | Name of the zero-shot NLI model that produced this score (health-checked common model across the RunPod pool) |
| `sentence_number`, `sentence_source`, `claim`, `work_id` | — | Same meaning as in `nli_ready_evidence/` |
| `label` | string | NLI verdict: `SUPPORTS`, `REFUTES`, or `NOT_ENOUGH_INFO` (argmax of the three probabilities) |
| `p_supports`, `p_refutes`, `p_nei` | double | Full softmax probability distribution over the three labels |
| `confidence` | double | Probability of the winning label (`max(p_supports, p_refutes, p_nei)`) |
| `uncertain` | bool | `TRUE` when `confidence` falls below the configured certainty threshold |
| `nli_config` | string | Name of the active `input/config.yaml` `nli.configs` entry used for this score |
| `assessment`, `km`, `bm` | string | Assessment/KM/BM |
| `claim_id` | string | `sprintf("%s-%02d", sentence_source, sentence_number)` — unique only *within* a `(km, bm)` pair, reused across different BMs (see `apply_candidate_scope()`'s handling of this in `R/build_llm_verification_parquet.R`) |

### `llm_candidate_scope/`

Built by `R/build_llm_candidate_scope_parquet.R`: a per-claim citing-work
allow-list derived from IPBES's own evidence references, used only by
`subset: "sm"` `llm_verification` configs to narrow Phase 2 review.

| Column | Type | Meaning |
|---|---|---|
| `claim_id` | string | Claim this allow-list entry applies to (paired with `km`/`bm` for uniqueness — see `nli_scores_evidence` note above) |
| `work_id` | string | OpenAlex ID of a citing work allowed for this claim, because it traces back (via `snowball/edges`) to a seed reference whose `refs_parquet$sm` prefix-matches one of the claim's own evidence-reference braces |
| `assessment`, `km`, `bm` | string | Assessment/KM/BM |

A claim with no evidence braces at all has **no rows here** — this absence
is the signal `apply_candidate_scope()` uses to fall back to "unrestricted"
for that claim, rather than excluding it.

### `llm_verification/scores/`

Built by `R/build_llm_verification_parquet.R`: Phase 2 LLM review of
whichever NLI-scored pairs the active config's `nli_labels`/`nli_certainty`
select.

| Column | Type | Meaning |
|---|---|---|
| `llm_config` | string | Name of the active `input/config.yaml` `llm_verification.configs` entry |
| `subset` | string | `"all"` or `"sm"` — whether `llm_candidate_scope/` narrowed the candidates for this config |
| `nli_config` | string | Name of the Phase 1 `nli.configs` entry that produced the NLI scores being reviewed |
| `assessment`, `km`, `bm` | string | Assessment/KM/BM |
| `nli_route` | string | This row's own outcome, `paste(nli_label, certain\|uncertain, sep = "-")`, e.g. `"REFUTES-certain"` — one value per row, not per config (a config selecting multiple labels/certainties fans out into multiple `nli_route` values) |
| `claim_id` | string | Claim reviewed (paired with `km`/`bm` for uniqueness) |
| `work_id` | string | OpenAlex ID of the citing work reviewed |
| `claim` | string | Claim hypothesis text shown to the LLM |
| `nli_label` | string | Phase 1's label for this pair (`SUPPORTS`/`REFUTES`/`NOT_ENOUGH_INFO`) |
| `uncertain` | bool | Phase 1's certainty flag for this pair |
| `nli_confidence` | double | Phase 1's confidence for this pair |
| `p_supports`, `p_refutes`, `p_nei` | double | Phase 1's full probability distribution |
| `llm_model` | string | OpenRouter model name that produced the LLM verdict |
| `llm_label` | string | LLM's own verdict: `SUPPORTS`, `REFUTES`, or `NOT_ENOUGH_INFO` |
| `llm_agrees` | bool | `TRUE` when `llm_label == nli_label` |
| `sufficient_evidence` | bool | Whether the LLM judged the cited work as containing enough evidence to support its verdict (demoted to `FALSE`/`NOT_ENOUGH_INFO` if `quote_verbatim` fails — see below) |
| `quote` | string | Verbatim quote the LLM cited from the work's premise text as justification |
| `quote_verbatim` | bool | `TRUE` if `quote` was verified (via `quote_is_verbatim()`) to actually occur in the premise text shown to the LLM |
| `explanation` | string | LLM's free-text rationale |

The sibling `output/llm_verification/raw/model=<model>/prompt=<hash>/`
directory (not partitioned the same way — see the Active table above) holds
one resumable JSON cache file per `(claim_id, work_id)` pair, keyed by a
sanitized version of `paste(claim_id, work_id, sep = "__")`; it is not a
queryable parquet dataset.

### `refutes_funnel_data_<id>.rds` / `supports_funnel_data_<id>.rds`

Built by `R/build_label_funnel_data.R`, called once per label (`"REFUTES"`,
`"SUPPORTS"`): the 3-level sieve for one (assessment, label) combination
(see [IPBES_Label_Funnel_Report.qmd](../IPBES_Label_Funnel_Report.qmd) for
the full methodology). A fourth level, "+ sufficient evidence", was
considered and dropped: Phase 2's own parser forces `llm_label` to
`NOT_ENOUGH_INFO` whenever `sufficient_evidence` is `FALSE`, so
`llm_agrees == TRUE` (level 3) already implies `sufficient_evidence ==
TRUE` for every row — a 4th level would always equal the 3rd. A list with:

| Field | Type | Meaning |
|---|---|---|
| `assessment` | string | Assessment ID |
| `label` | string | Which NLI label this funnel is for — `"REFUTES"` or `"SUPPORTS"` |
| `empty` | bool | `TRUE` if the snowball, NLI, or LLM verification stage hasn't produced output yet for this assessment |
| `funnel_overall` | tibble | One row per level (`level1`..`level3`), with a human-readable `label` (e.g. `"NLI SUPPORTS (certain)"`) and the assessment-wide distinct-work count `n` — the sum of `funnel_by_bm`'s per-BM counts for that level, not a globally-deduped-across-BMs count |
| `funnel_by_bm` | tibble | One row per `(km, bm)`, with `n1`..`n3` (distinct works at each level) and `pct_2of1`/`pct_3of2` (conversion rate between consecutive levels, `NA` when the denominator is 0) |
| `level3_detail` | tibble | One row per `(km, bm, work_id, claim_id)` surviving to level 3 (`llm_agrees == TRUE`), with `claim`, `nli_confidence`, `quote`, `explanation`, `doi` — the source data for the level-3 DT table |

### `refutes_funnel_table_l3_<id>.rds` / `supports_funnel_table_l3_<id>.rds`

Built by `R/build_label_funnel_tables.R`: the exact data.frame rendered
into the level-3 DT table (`.html`, self-contained), after column curation
and DOI/OpenAlex link formatting.

| Column | Type | Meaning |
|---|---|---|
| `km`, `bm` | factor | Cast to `factor` specifically so DT's `filter = "top"` renders them as `<select>` dropdowns |
| `work` | string (HTML) | Clickable link to the work's DOI, or OpenAlex if no DOI exists — same `work_link()` convention as `nli_bm_explorer_html`'s drill-down table |
| `claim` | string | Claim hypothesis text shown to the LLM |
| `nli_confidence` | double | Phase 1's confidence for this pair, rounded to 3 d.p. |
| `quote` | string | Verbatim quote the LLM cited as justification |
| `explanation` | string | LLM's free-text rationale |
