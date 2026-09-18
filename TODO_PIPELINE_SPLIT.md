# Splitting the pipeline: collection / fact-checking / training

Status: **proposal, nothing implemented.** Written 2026-09-18 against a
single-project pipeline of 76 targets in one `_targets.R`. Recorded so the
reasoning and the measured numbers are not lost; nothing in the pipeline
depends on it.

## The problem this solves

The pipeline currently mixes two *purposes* in one DAG:

- **Fact checking** — the deliverable. Citing works discovered by the
  snowball are scored against assessment claims, routed to an LLM for
  grounded verification, and reported.
- **Training** — a side quest. Key papers (the seed references IPBES itself
  cited) are scored and LLM-reviewed *exhaustively* to distil a fine-tuning
  set, which may or may not produce a model worth deploying.

These are not two stages of one process. They are two processes that happen
to share an input.

| | fact checking | training |
|---|---|---|
| input | citing works (2,698,608) | key papers (10,432) |
| LLM routing | filtered to `REFUTES`/`SUPPORTS` + certain (7.72% of scored pairs) | **every pair, unconditionally** |
| output | the published finding | a model, plus QA on it |
| cadence | per assessment, ongoing | occasional, experimental |
| cost of being wrong | a wrong claim is published | a worse model you decline to deploy |

Because they share a DAG, they also share failure modes that have nothing to
do with each other. Concretely, today:

- `nli_scores_qa_data` takes `nli_scores_keypaper_evidence` as a **bare,
  never-read argument**, purely so the training chain runs during a
  fact-checking build. That one line is why `tar_make(report_fact_checker)`
  dispatches key-paper GPU work.
- Both chains are forced onto the same `nli.active` and `granularity`, though
  nothing requires that.
- `train: true` lives inside an *NLI serving config*, where it does not
  belong — it is a training decision expressed in the configuration of a
  model server.

## Why a split is cheap here

The seams are already filesystem paths:

- **52 of 76 targets (~70%) are `format = "file"`**, returning parquet roots.
- Of the 24 value-returning targets, 15 are trivial config reads and 8 are
  internal to the NLI chain. **Essentially no value crosses a proposed
  boundary.**

`targets` 1.12.0 supports multiple projects natively (`_targets.yaml`,
`tar_config_set(project = )`, `TAR_PROJECT`), each with its own `script` and
`store`. Cross-project dependency tracking is preserved by declaring the
upstream project's outputs as `tar_file()` inputs downstream: `targets`
hashes them, so a genuine upstream change still invalidates downstream.

## Three pipelines, not two

Collection must be its own project rather than living inside fact checking.
Both consumers depend on it **symmetrically**, and they consume only file
targets:

| consumer | takes from collection |
|---|---|
| fact checking | `key_messages_parquet`, `works_citing_parquet`, `refs_parquet` |
| training | `key_messages_parquet`, `works_parquet`, `snowball_parquet` |

If collection lived inside fact checking, training would reach into another
project's internals for its inputs, and a fact-checking run could move them
underneath it. Three projects makes the ownership clean.

```
_targets_collect.R      LOD -> refs -> zotero -> works -> snowball -> works_citing
        |
        +--------------> _targets_factcheck.R   citing works -> NLI -> LLM -> reports
        +--------------> _targets_training.R    key papers   -> NLI -> LLM -> training set -> fine-tune
```

Collection is also the natural unit on independent grounds: it is the only
project that calls OpenAlex, it is the slowest, it is re-run least often, and
it is the one whose re-run most deserves to be a deliberate act.

## What moves where

### `_targets_collect.R`

`config_file`, `sparql_url`, `workers`, `assessments_list`, `assessment`,
`ttl_path`, `refs_sparql`, `key_messages_sparql`, `refs_parquet`,
`key_messages_parquet`, `zotero_parquet`, `works_parquet`, `snowball_parquet`,
`works_citing_parquet`.

Note the internal chain — `refs_parquet` -> `zotero_parquet` ->
`works_parquet`. `zotero_parquet` is load-bearing, not decorative:
`download_works()` reads it to backfill DOIs absent from the LOD, matched by
Zotero item key. VA has **0 of ~3,079** references with `ipbes:hasDoi` in its
graph; without this backfill VA produces almost nothing. It cannot be folded
into `refs_parquet`, because `zotero_parquet`'s own construction needs
`refs_parquet`'s `zotero` column — a real cycle.

### `_targets_factcheck.R`

Segmentation and scoring for citing works (`nli_ready_evidence_parquet`,
`nli_claim_units_evidence*`, `nli_scores_by_claim_evidence`,
`nli_scores_evidence_consolidated`, `nli_pool_health`,
`nli_host_locks_cleanup`); Phase 2 (`llm_candidate_scope_parquet`,
`llm_verification_parquet`); and the whole reporting layer
(`nli_overview_*`, `nli_scores_qa_*`, `llm_verification_qa_*`, the funnel
targets, `nli_bm_explorer_html`, `fig_pub_per_year`, the `overlap_*` tables,
the diagram targets, `reports_project`, `report_fact_checker`,
`report_output_dir`, `claude_md`).

### `_targets_training.R`

`nli_ready_evidence_keypaper_parquet`, `nli_claim_units_evidence_keypaper*`,
`nli_scores_keypaper_evidence*`, `llm_verification_keypaper_parquet`,
`nli_training_data`, `nli_training_qa_data`, `nli_finetuned_model`,
`nli_finetuned_model_qa_data`, and the two training QA report families.

### Orphans to decide about during the move

`nli_ready_parquet`, `nli_claim_units`, `nli_claim_units_flat` — the original
per-sentence segmentation. These are *active* targets, but the target that
would consume them (`nli_scores_by_claim`) is commented out, so they are
built and never read; `output/nli_scores/` is 0 B. Either delete them or
move them somewhere that records them as a parked comparison arm. Do not
carry them across without deciding.

## Configuration

### The question: `training:` and `fact_checking:` sections?

**Yes — but as purpose blocks that *select* from shared config libraries, not
as a second place to define models.**

The current file mixes two different kinds of thing under `nli:` and
`llm_verification:`: a **library of named configurations**, and a **selection**
(`active:`) of which one is in force. With one DAG that conflation is
invisible, because there can only be one selection. With three projects it
becomes wrong, because fact checking and training may legitimately want
different ones.

Proposed shape:

```yaml
# ---- shared -------------------------------------------------------------
sparql_url: fuseki
workers: 8
assessments:
  - id: GA1
    ttl_url: ...
    full_text: false
  # ... unchanged

# ---- libraries of named definitions (no selection here) -----------------
nli:
  claim_completion:
    configs: { haiku_completion: { model: "anthropic/claude-haiku-4.5" } }
  configs:
    bge_m3_zeroshot_atomic_bm: { ... }      # unchanged, minus train/downsample_seed
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
  reports: [ ... ]        # the fact-checking report families

training:
  assessments: [GA1, VA, TCA, IAS, BBA]
  nli: bge_m3_zeroshot_atomic_bm
  llm: openrouter_cheap
  claim_completion: haiku_completion
  finetune:
    enabled: true
    downsample_seed: 13
  reports: [ ... ]        # QA_NLI_Training_Data, QA_NLI_Finetuned_Model
```

What this achieves:

1. **Scope lives where it belongs.** `fact_checking.assessments: [GA1]` and
   `training.assessments: [all]` express exactly the intent, in one place
   each.
2. **It avoids a serious invalidation trap.** The alternative — per-assessment
   `training: true` / `fact_checking: false` flags inside `assessments:` —
   would change `assessments_list`'s value and therefore invalidate
   `assessment`, and with it `ttl_path`, `works_parquet`, `snowball_parquet`
   and everything downstream: re-downloading TTLs, re-fetching OpenAlex,
   re-running the snowball. (It *could* be made safe by extending the
   existing `setdiff(names(a), "full_text")` strip, which exists for exactly
   this reason — but a purpose block avoids the hazard entirely rather than
   defusing it.)
3. **`train:`/`downsample_seed:` leave the serving config.** They are training
   decisions and belong under `training.finetune`, not in the configuration of
   an inference server.
4. **Each project reads only its own block**, so a fact-checking config change
   cannot invalidate training, and vice versa — enforced by separate stores
   rather than by convention.

### What this does not fix

`nli_config_for_granularity()` still earns its place. The reporting layer
renders all three granularities while only one is "selected", so the mapping
from granularity to the config that actually produced its scores is still
needed.

## Cross-project contracts

Each consumer declares the collection outputs it uses as `tar_file()` inputs.
Cut at the **small consolidated outputs**, never the large intermediates:
`nli_scores_evidence_consolidated` is ~300 MB, `nli_ready_evidence` is 140 GB,
and `format = "file"` hashes what it is given.

Shared mutable state that must be named explicitly, because no DAG will
describe it after the split:

- **`output/claim_completion/raw/`** — under `atomic_bm` both consumers
  LLM-complete elliptical fragments through this cache. It is append-only and
  content-hash keyed, so concurrent use is safe, but it is a genuine
  side-channel between two projects.
- **`output/llm_verification/raw*/`** — the Phase 2 per-pair caches. Separate
  roots per chain (`raw/` vs `raw_keypaper/`), so no collision, but both are
  written outside any single DAG's view.

## The feedback loop, made explicit

This is the part the current design cannot express, and the main reason the
two purposes feel tangled.

Training produces a fine-tuned model. If it is good, that model becomes an
`nli` config that **fact checking consumes**. That is a cycle:

```
collection -> training -> a model -> (a human decides) -> config.yaml -> fact checking
```

A DAG cannot contain a cycle, so today the loop is hidden inside a bare
unread function argument and a `train:` flag in a serving config. After the
split it becomes what it actually is: two independent pipelines joined by a
human editing `training.finetune` and then `fact_checking.nli`.

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

## Reporting

Most report inputs (`refutes_funnel_*`, `nli_scores_qa_*`,
`bm_split_report_highlighted`) are built from on-disk parquet and belong to
whichever project owns them, so they need no cross-store reads. Only four
`tar_read()` calls genuinely cross a boundary — `works_parquet`,
`works_citing_parquet`, `refs_parquet`, `reports_project` — and become
`tar_read(x, store = "_targets_collect")`.

`R/generate_report_wrappers.R` already emits the dependency lines, so this is
one contained change to the generator plus a `store` column in the `reports:`
entries. The report families themselves split between the fact-checking and
training projects.

## What gets deleted

Eleven "bare argument only to establish a DAG edge" hacks exist solely
because everything is one DAG with mismatched branch shapes. After the split,
ordering is explicit and they are simply removed — including the one that
makes a fact-checking report build dispatch key-paper GPU work.

## What gets worse

- **No single `tar_make()`.** Three projects run in order. Given that a bare
  `tar_make()` today can spend RunPod GPU *and* OpenRouter money, and that
  work is already driven with `tar_make(names = ...)` to avoid exactly that,
  this is closer to honesty than to loss.
- **Config targets are duplicated** across three preambles. They are
  millisecond `yaml::read_yaml()` reads of one file; the cost is a little
  repetition, not computation.
- **Ordering becomes the operator's responsibility.** File hashing still
  catches a stale downstream, but nothing will *run* collection for you.

## Migration order

1. Extract `_targets_collect.R` first and verify the other two still build
   against it unchanged. This is the boundary with the clearest contract.
2. Split training out. It is the smaller consumer and the one whose failure
   matters least.
3. Restructure the configuration into purpose blocks.
4. Update `generate_report_wrappers.R` for cross-store reads and per-purpose
   report families.
5. Resolve the per-sentence orphans.

Do this from a quiet point: no scoring run in flight, and the parent repo
committed. A refactor of this size under a running system is how the
invalidation traps described above get triggered by accident.
