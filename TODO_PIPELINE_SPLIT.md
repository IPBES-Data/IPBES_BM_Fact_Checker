# Splitting the pipeline: collection / fact-checking / training / reporting

Status: **proposal, nothing implemented.** Written 2026-09-18 against a
single-project pipeline of 76 targets in one `_targets.R`; revised the same day
from three projects to four. Recorded so the reasoning and the measured numbers
are not lost; nothing in the pipeline depends on it.

## The problem this solves

The pipeline mixes several *purposes* in one DAG:

- **Fact checking** — the deliverable. Citing works discovered by the snowball
  are scored against assessment claims and routed to an LLM for grounded
  verification.
- **Training** — a side quest. Key papers (the seed references IPBES itself
  cited) are scored and LLM-reviewed *exhaustively* to distil a fine-tuning
  set, which may or may not produce a model worth deploying.
- **Reporting** — rendering both of the above, plus the bibliometric
  descriptives, into the published HTML.

These are not stages of one process. They are separate processes sharing an
input.

| | fact checking | training |
|---|---|---|
| input | citing works (2,698,608) | key papers (10,432) |
| LLM routing | filtered to `REFUTES`/`SUPPORTS` + certain (7.72% of scored pairs) | **every pair, unconditionally** |
| output | the published finding | a model, plus QA on it |
| cadence | per assessment, ongoing | occasional, experimental |
| cost of being wrong | a wrong claim is published | a worse model you decline to deploy |

Because they share a DAG they share failure modes that have nothing to do with
each other. Concretely, today:

- `nli_scores_qa_data` takes `nli_scores_keypaper_evidence` as a **bare,
  never-read argument**, purely so the training chain runs during a
  fact-checking build. That one line is why `tar_make(report_fact_checker)`
  dispatches key-paper GPU work.
- **Rendering a report can spend money.** `report_fact_checker` transitively
  depends on `llm_verification_parquet`, so a plain `tar_make()` can bill
  OpenRouter and occupy the RunPod pool. The current mitigation is remembering
  `shortcut = TRUE`.
- Both scoring chains are forced onto the same `nli.active` and `granularity`,
  though nothing requires it.
- `train: true` lives inside an *NLI serving config*, where it does not belong.

## Why a split is cheap here

The seams are already filesystem paths:

- **52 of 76 targets (~70%) are `format = "file"`**, returning parquet roots.
- Of the 24 value-returning targets, 15 are trivial config reads and 8 are
  internal to the NLI chain. **Essentially no value crosses a proposed
  boundary.**

`targets` 1.12.0 supports multiple projects natively (`_targets.yaml`,
`tar_config_set(project = )`, `TAR_PROJECT`), each with its own `script` and
`store`. Cross-project dependency tracking is preserved by declaring the
upstream project's outputs as `tar_file()` inputs downstream.

## Four projects

```
_targets_collect.R  ──┬──► _targets_factcheck.R   citing works -> NLI -> LLM
  (keeps the existing │
   _targets/ store)   ├──► _targets_training.R    key papers -> NLI -> LLM -> fine-tune
                      │
                      └──► _targets_reporting.R   ◄── also reads the other two
```

**Collection** must be its own project because both scoring consumers depend on
it symmetrically, and on file targets only:

| consumer | takes from collection |
|---|---|
| fact checking | `key_messages_parquet`, `works_citing_parquet`, `refs_parquet` |
| training | `key_messages_parquet`, `works_parquet`, `snowball_parquet` |

**Reporting** must be its own project, rather than living inside fact checking,
because **reports come from both consumers**: the funnel and `QA_NLI_Scores`
families from fact checking, `QA_NLI_Training_Data` and
`QA_NLI_Finetuned_Model` from training. Putting reporting inside one of them
would split `config.yaml`'s `reports:` block and `generate_report_wrappers()`
across two projects — a generator that knows about half the reports it is
supposed to generate.

It also delivers the thing this whole exercise is really about: **a reporting
project needs no credentials and has no path to a paid target.** Not "use
`shortcut = TRUE` and remember why" — structurally impossible. Every
report-data target already reads parquet from disk paths rather than from
scoring target *values*, so the seams are `tar_file()` inputs and nothing else.

## The migration hazard, and how to avoid it

**A `targets` store is the record of what has been built.** Three new stores
means every target in them is outdated by definition and must run — regardless
of whether its output already exists on disk.

For the collection layer that is not survivable:

| builder | behaviour on a fresh store |
|---|---|
| `download_ttls` | SHA-checked against GitHub, skips if unchanged |
| `download_works` | **`unlink(output_path)` then refetches OpenAlex** |
| `build_snowball_parquet` | **no existence check at all** — the 16 GB job |
| `build_works_citing_parquet` | guard only checks that *upstream* nodes/edges exist |

Re-running those costs days and real OpenAlex budget — but worse, it would
produce a *different* corpus from the one every current score was computed
against.

**Therefore: collection keeps the existing `_targets.R` and the existing
`_targets/` store.** Delete the non-collection targets from that script; the
consumers get new scripts and new stores. Collection's metadata survives
untouched, so nothing re-downloads and nothing re-snowballs.

Do **not** run `tar_prune()` during the migration. Orphaned metadata for
removed targets is harmless (`targets` ignores rows for targets not in the
pipeline) and keeps a rollback available: restore the old `_targets.R` and the
store still knows about everything. (`tar_prune()` removes values from
`_targets/objects/` and rows from `_targets/meta/meta`; for a `format = "file"`
target the stored value is only the path, so `output/` is not endangered — but
there is no reason to take the risk mid-migration.)

What the fresh consumer stores actually pay:

| project | migration cost |
|---|---|
| collection | **nothing** |
| reporting | re-render everything — free, ~90 s |
| training | cheap — `nli_ready_evidence_keypaper` is 346 MB; scoring re-dispatches but delta-skips; Phase 2 reads its JSON cache |
| fact checking | dominated by `nli_ready_evidence_parquet` — 140 GB cross-join, no resumability since `0bb6bb0` removed its early return. Hours of local compute, no money |

One friction: both scoring targets depend on `nli_pool_health`, which fails
hard if any host in the active config is unreachable. With a fresh store the
scoring target is outdated by definition, so even a no-op pass needs a live
pool. A single pod in the active config's `host:` list satisfies it.

## What moves where

### `_targets_collect.R` — keeps the existing store

`config_file`, `sparql_url`, `workers`, `assessments_list`, `assessment`,
`ttl_path`, `refs_sparql`, `key_messages_sparql`, `refs_parquet`,
`key_messages_parquet`, `zotero_parquet`, `works_parquet`, `snowball_parquet`,
`works_citing_parquet`.

Note the internal chain — `refs_parquet` -> `zotero_parquet` ->
`works_parquet`. `zotero_parquet` is load-bearing: `download_works()` reads it
to backfill DOIs absent from the LOD, matched by Zotero item key. VA has **0 of
~3,079** references with `ipbes:hasDoi` in its graph; without this backfill VA
produces almost nothing. It cannot be folded into `refs_parquet`, because
`zotero_parquet`'s own construction needs `refs_parquet`'s `zotero` column — a
real cycle.

Needs `API_openalex` only.

### `_targets_factcheck.R`

`nli_ready_evidence_parquet`, `nli_claim_units_evidence*`,
`nli_scores_by_claim_evidence`, `nli_scores_evidence_consolidated`,
`nli_pool_health`, `nli_host_locks_cleanup`, `llm_candidate_scope_parquet`,
`llm_verification_parquet`.

Scoring only — no reports. Needs `API_openrouter` only.

### `_targets_training.R`

`nli_ready_evidence_keypaper_parquet`, `nli_claim_units_evidence_keypaper*`,
`nli_scores_keypaper_evidence*`, `llm_verification_keypaper_parquet`,
`nli_training_data`, `nli_finetuned_model`.

Needs `API_openrouter` only, plus the Python venv for `train_nli.py`.

### `_targets_reporting.R`

Everything that renders or prepares something to render: `nli_overview_data`,
`nli_overview_figures`, `nli_bm_explorer_html`, `bm_split_report_highlighted`,
`nli_scores_qa_data`/`_figures`, `llm_verification_qa_data`/`_figures`,
`nli_training_qa_data`, `nli_finetuned_model_qa_data`, the six funnel targets,
`fig_pub_per_year`, the three `overlap_*` tables, the diagram targets
(`mmd_workflow_nli`, `pipeline_mmd`, `diagram_*`), `reports_project`,
`report_fact_checker`, `report_output_dir`, `claude_md`, `report`.

Owns `config.yaml`'s `reports:` block and `generate_report_wrappers()`.

**Needs no credentials at all**, which also removes the headless/tmux Keychain
problem CLAUDE.md documents at length — a report re-render stops requiring
macOS Keychain access.

### Orphans to decide about during the move

`nli_ready_parquet`, `nli_claim_units`, `nli_claim_units_flat` — the original
per-sentence segmentation. These are *active* targets, but the target that
would consume them (`nli_scores_by_claim`) is commented out, so they are built
and never read; `output/nli_scores/` is 0 B. Either delete them or move them
somewhere that records them as a parked comparison arm. Do not carry them
across without deciding.

`zotero_parquet` is **not** an orphan (see above) — an earlier draft of this
document wrongly said so.

## Cross-project contracts

Each consumer declares the upstream outputs it uses as `tar_file()` inputs.
Cut at the **small consolidated outputs**, never the large intermediates:
`nli_scores_evidence_consolidated` is ~300 MB, `nli_ready_evidence` is 140 GB,
and `format = "file"` hashes what it is given.

**Use the direct `tar_file()` contract, not a manifest.** A manifest — a small
file of paths, row counts and a digest, tracked instead of the tree — was
considered and rejected. `targets`' guarantee comes from hashing the actual
bytes; a manifest substitutes trust in the producer's bookkeeping for direct
verification, and it breaks precisely when it matters: a partial write, a hand
edit, or a botched migration can leave the data changed and the manifest
unmoved, so the downstream stays "current" on data that is not. The saving is
also smaller than it looks — collection already hashes those trees on every
check, because that is how `format = "file"` detects external modification, so
a manifest would only stop *consumers* re-hashing the same bytes. Revisit only
if the hashing cost proves painful in practice (training's inputs are ~16.6 GB,
fact checking's ~2.4 GB, reporting's are small), and then with the digest
computed over the real files.

Shared mutable state that must be named explicitly, because no DAG will
describe it after the split:

- **`output/claim_completion/raw/`** — under `atomic_bm` both scoring consumers
  LLM-complete elliptical fragments through this cache. Append-only and
  content-hash keyed, so concurrent use is safe, but it is a genuine
  side-channel between two projects.
- **`output/llm_verification/raw*/`** — the Phase 2 per-pair caches. Separate
  roots per chain (`raw/` vs `raw_keypaper/`), so no collision, but both are
  written outside any single DAG's view.

## Configuration

Keep `nli:` and `llm_verification:` as **libraries of named definitions** and
move the *selection* into per-purpose blocks. The current file conflates the
two under an `active:` key, which is invisible while there is one DAG and wrong
once there are four.

```yaml
# ---- shared -------------------------------------------------------------
sparql_url: fuseki
workers: 8
assessments: [ ... ]        # unchanged

# ---- libraries of named definitions (no selection here) -----------------
nli:
  claim_completion:
    configs: { haiku_completion: { model: "anthropic/claude-haiku-4.5" } }
  configs:
    bge_m3_zeroshot_atomic_bm: { ... }   # minus train:/downsample_seed:
    bge_m3_zeroshot_complete_bm: { ... }
    bge_m3_zeroshot_naive_bm: { ... }
llm_verification:
  configs:
    openrouter_cheap: { ... }
    openrouter_midtier: { ... }
    openrouter_toptier_gpt5: { ... }

# ---- purpose blocks: scope + selection ----------------------------------
fact_checking:
  assessments: [GA1]
  nli: bge_m3_zeroshot_atomic_bm
  llm: openrouter_cheap
  claim_completion: haiku_completion

training:
  assessments: [GA1, VA, TCA, IAS, BBA]
  nli: bge_m3_zeroshot_atomic_bm
  llm: openrouter_cheap
  claim_completion: haiku_completion
  finetune:
    enabled: true
    downsample_seed: 13

reports: [ ... ]            # unchanged; owned by the reporting project
```

What this achieves:

1. **Scope lives where it belongs.** `fact_checking.assessments: [GA1]` and
   `training.assessments: [all]` state the intent in one place each.
2. **It avoids a serious invalidation trap.** The alternative — per-assessment
   `training: true` / `fact_checking: false` flags inside `assessments:` —
   would change `assessments_list`'s value and therefore invalidate
   `assessment`, and with it `ttl_path`, `works_parquet`, `snowball_parquet`
   and everything downstream. (It *could* be made safe by extending the
   existing `setdiff(names(a), "full_text")` strip, which exists for exactly
   this reason — but a purpose block avoids the hazard rather than defusing
   it.)
3. **`train:`/`downsample_seed:` leave the serving config**, where they never
   belonged.
4. **Each project reads only its own block**, so a fact-checking config change
   cannot invalidate training — enforced by separate stores rather than by
   convention.

`nli_config_for_granularity()` still earns its place: reporting renders all
three granularities while only one is selected, so the mapping from granularity
to the config that produced its scores is still needed.

## The feedback loop, made explicit

Training produces a fine-tuned model. If it is good, that model becomes an
`nli` config that **fact checking consumes**. That is a cycle:

```
collection -> training -> a model -> (a human decides) -> config.yaml -> fact checking
```

A DAG cannot contain a cycle, so today the loop hides inside a bare unread
function argument and a `train:` flag in a serving config. After the split it
becomes what it is: independent pipelines joined by a human editing
`training.finetune` and then `fact_checking.nli`.

Adopting a fine-tuned model is not a config edit alone. It requires:

- serving the checkpoint (push to a private HF repo and rebuild the image, or
  mount it from a network volume and set `NLI_MODEL` to that path),
- `passes: 1` — which only works on `nli-runpod-bge-m3` **v0.4.0 or later**;
  earlier images silently drop the parameter,
- `candidate_labels: ["SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO"]`, because
  `_direct_label_order()` matches by name against the model's own `id2label`
  and `train_nli.py` writes exactly those three. The current
  `["supports", "refutes", "is not relevant to"]` would fail every request
  with a 400,
- and a **full rescore**, since scored output is partitioned by
  `nli_config=<name>` and nothing carries over.

## What gets deleted

Eleven "bare argument only to establish a DAG edge" hacks exist solely because
everything is one DAG with mismatched branch shapes. After the split, ordering
is explicit and they are simply removed — including the one that makes a
fact-checking report build dispatch key-paper GPU work.

## What gets worse

- **No single `tar_make()`.** Four projects run in order. Given that a bare
  `tar_make()` today can spend RunPod GPU *and* OpenRouter money, this is
  closer to honesty than to loss.
- **Config targets are duplicated** across four preambles. Millisecond
  `yaml::read_yaml()` reads of one file; the cost is repetition, not compute.
- **Ordering becomes the operator's responsibility.** File hashing still
  catches a stale downstream, but nothing will *run* collection for you.
- **The big trees get hashed by producer and consumer both** — see
  *Cross-project contracts*.

## Migration order

Reporting first. It is the cheapest to move (no state beyond rendered HTML),
independently verifiable (render and diff against the current output), and it
immediately removes the accidental-spend risk while everything else is still
one pipeline.

1. **Extract `_targets_reporting.R`.** Move the report-data, figure, table,
   widget, diagram and render targets plus `generate_report_wrappers()`. Verify
   by rendering and comparing against the current `output/reports/`. Nothing
   upstream changes; the win (no credentials, no paid path) lands immediately.
2. **Extract `_targets_training.R`.** The smaller scoring consumer, and the one
   whose failure matters least. Verify that a no-op pass skips every claim.
3. **Extract `_targets_factcheck.R`,** leaving `_targets.R` as collection on
   its existing store. This is where the 140 GB `nli_ready_evidence` rebuild is
   paid.
4. **Restructure the configuration** into purpose blocks.
5. **Resolve the per-sentence orphans.**

Do this from a quiet point: no scoring run in flight, and the repository
committed. A refactor of this size under a running system is how the
invalidation traps described above get triggered by accident.
