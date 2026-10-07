# ⚠️ DO NOT RUN THE `main` PIPELINE (as of 2026-10-07)

`targets::tar_make()` on `main` would **delete and re-download** the collection
corpus. Measured: **16 of 18 targets outdated**, including every download target.

| target | guard | cost if run |
|---|---|---|
| `snowball_parquet` | unlinks, **no existence check** | 16 GB deleted, **days** of OpenAlex time |
| `works_parquet` | `download_works.R:9` — `if (file.exists()) unlink()` then refetch | 573 MB deleted, refetched |
| `zotero_parquet` | `download_zotero.R:123` — unlink then refetch | re-downloaded |
| `works_citing_parquet` | — | full DuckDB rebuild |
| `ttl_path` | SHA-checked against GitHub | cheap, skips if unchanged |

And a fresh snowball yields a **different corpus** from the one every existing
score was computed against.

**Cause.** `targets` hashes the function bodies a target depends on, and the
2026-10-07 `output/` restructure edited a path literal inside each of main's
builders. The move compounds it, but the code edit alone was enough — this is a
standing hazard of this repo, not specific to that change: *any* edit to
`download_works.R` or `build_snowball_parquet.R`, even a comment, invalidates
them and triggers a refetch.

**Decision: option C — keep the new structure, simply never run `main`.** Its
outputs are complete and correct on disk, and the consumer projects read them
through `format = "file"` path stubs, so `main` has nothing to produce. The two
alternatives, both still open:

- **A — revert `collection/` only.** Move `LoD refs key_messages zotero works
  snowball works_citing works_citing_meta` back to the `output/` top level and
  revert the path edits in main's seven builders, keeping `factchecker/` and
  `reporting/`. Main's store goes clean; nothing re-downloads.
- **B — repair the metadata.** Rewrite the recorded paths and function hashes in
  `_targets/meta/` so targets accepts the current outputs. Correct in principle
  (the data is byte-identical, only the path literal changed) but it is surgery
  on targets internals, and the failure mode is the refetch it exists to avoid.

**If `main` ever IS re-run, factcheck survives — it does not re-pay.** Its five
upstream stubs (`works_parquet`, `snowball_parquet`, `works_citing_parquet`,
`refs_parquet`, `key_messages_parquet`) are all `format = "file"`, so they hash
CONTENT and a changed corpus does invalidate them. But the scorers resume at
**work** granularity — `score_one_claim_jev.R:164`,
`todo_ids <- setdiff(work_ids, already)` — so existing scores are kept and only
newly-discovered works are dispatched, and Phase 2 replays its per-pair JSON
cache. Real cost of a main re-run would be: the `claim_work_pairs` cross-join
(hours, local, free) plus GPU/API for the delta.

**The exception that would make it expensive:** the scoring cache is discarded
**outright** on a claim-text or model mismatch (`score_one_claim_jev.R:126-148`),
forcing a full rescore. Claim text comes from `key_messages_parquet` ← the LOD
TTLs, which are SHA-checked, so a re-run alone does not change it — but an
upstream TTL revision by IPBES would.

---

# Simplify Jev even more by combining the questions

In Jev, multiple questions can be combined, i.e. the `noul` could be done at the same time as the `choice`.
This would reduce the number of calls necessary (and likely the costs and time as well).
See https://docs.typesafe.ai/primitives/advanced for details

Here is an example which worked in the playground:

```
{
  "State": {
    "claim": "Cats can be funny.",
    "paper": "Cats can be funny some of the time."
  },
  "Questions": {
    "addresses_claim": {
      "type": "bool",
      "instructions": "Does this paper address the specific subject of the claim closely enough that its findings bear on whether the claim is true?",
      "criteria": {
        "true": "the paper studies the same phenomenon, taxa, driver or region the claim is about, and its findings speak to the claim",
        "false": "the paper is about a related but different topic, so its findings cannot settle the claim either way"
      }
    },
    "claim_opinion": {
      "type": "choice",
      "instructions": "Judged only from this paper, what is its relationship to the claim?",
      "criteria": {
        "SUPPORTS": "the paper reports a finding consistent with the claim and bearing on it, making the claim more likely to be true",
        "REFUTES": "the paper reports a finding inconsistent with the claim, or pointing in the opposite direction, making the claim less likely to be true",
        "NOT_ENOUGH_INFO": "the paper does not report a finding that bears on the claim either way -- whether because it is about a related but different topic, or because it is on topic but reports nothing that settles the claim"
      }
    }
  }
}
```

which results in the playground in tyhe response of the form:

```
{
  "addresses_claim": {
    "question": "Does this paper address the specific subject of the claim closely enough that its findings bear on whether the claim is true?",
    "result": "94% true"
  },
  "claim_opinion": {
    "question": "Judged only from this paper, what is its relationship to the claim?",
    "options": {
      "SUPPORTS": "100%",
      "REFUTES": "0%",
      "NOT_ENOUGH_INFO": "0%"
    },
    "confidence": "99%"
  }
}
```

Try if you can reproduce this and if it is applicable for combining the two Jev calls.

Also, the section

```
  "label_map": {
    "SUPPORTS": "p_supports",
    "REFUTES": "p_refutes",
    "NOT_ENOUGH_INFO": "p_nei"
  }
```

seems to be dropped silently.



---

## Tested 2026-10-07 — it works, but **no change now**

Both points confirmed against the live API. Decision: **leave
`input/prompts/jev_claim_questions.json` untouched**, stay on the 3-way question.
Revisit after the human review round reports.

### Your playground JSON was nearly right

`"type": "bool"` is rejected — the API's discriminator accepts only
`noul | choice | score`. With `bool` → `noul` it reproduces your playground
result exactly: `addresses_claim` 0.94, `claim_opinion` SUPPORTS, confidence 1.

Mixed question types in one request work, and they survive **batching**, which
was the real risk — our design must put the paper inline in each question's
`instructions` rather than in shared `state`, because question ids never reach
the model. Controlled test, 3 papers × 2 questions in one request, all three
correctly discriminated (SUPPORTS / REFUTES / NOT_ENOUGH_INFO, addresses 0.93 /
0.84 / 0.01).

### But combining saves calls, not money

At production batch shape (20 papers under one claim), real GA1 premises:

| | tokens/pair | cost vs choice-only |
|---|---|---|
| 3-way choice only | 467 | 1.000 |
| **4-way choice** (OFF_TOPIC added) | 478 | **1.024** |
| 3-way choice + separate noul | 865 | **1.852** |

The premise has to be inline in *both* questions, so it is sent twice either
way. Merging two passes over the same pairs saves only ~1.7% — the request
envelope and one copy of the claim. The 85% is not packaging, it is the second
copy of every premise.

**And combining forces the noul onto every pair.** Routing is decided *by* the
choice answer, so at the moment Phase 1 asks the choice it cannot know which
pairs will be routed. There is no "combined but only on the routed subset".

### A fourth choice option is nearly free, but structurally blind

Adding `OFF_TOPIC` as a 4th option costs 2.4%, and `p_off` ranks the rejected
mass about as well as the noul does — on 20 rows where production `p_nei` is
pinned at exactly 1.000, `p_off` took 12 distinct values spanning 0.23–0.99
(Spearman vs `1 − addresses` across all 40 rows: **0.959**).

It cannot do the thing the screen exists for. On 20 routed pairs the noul
flagged 5 as low-relevance; the 4-way flagged **0** (`p_off` mean 0.042, max
0.190). All four options share one probability simplex, so mass in REFUTES
cannot also be in OFF_TOPIC — "this contradicts the claim, but isn't really
about the claim" is unrepresentable. That is exactly the topically-adjacent
REFUTES failure found in real data.

### Labels fold cleanly; `confidence` does not

Folding `OFF_TOPIC` back into `p_nei` is exact (`s + r + (n + off) = 1`, zero
deviation) and preserves the label on **40/40** rows. Renormalising S/R/NEI
after *dropping* OFF_TOPIC would be a bug — `(0.05, 0.02, 0.03, 0.90)` would
become a confident SUPPORTS.

`confidence` is returned separately and is **not portable**: Spearman 0.41
against the 3-way, mean abs diff 0.11, and it moves in opposite directions for
the two groups (saturated-NEI median 1.000 → 0.935; routed median 0.715 →
0.830). It is what `uncertain_threshold: 0.60` thresholds, so `uncertain`,
the routed set, Phase 2 spend and the funnel's "certain" level all shift.

### Why no change now

1. **`p_off` has no consumer.** It cannot gate Phase 2 (max 0.190 on routed
   pairs) and routing stays on label + confidence. It would only make the
   blind spot *rankable*, which is an analysis nobody has scheduled. "It only
   costs 2.4%" is not a justification for asking a question nothing reads.
2. **If relevance is ever wanted, it should be the noul, not `p_off`** — the
   noul is orthogonal to the verdict and can audit confident calls. So even
   the insurance argument points away from the 4-way.
3. **It would damage the one dataset that currently matters.** The gold
   standard drawn 2026-10-07 is 200 KM C. pairs scored by all three models
   under the 3-way question. A 4-way rescore keeps the labels but breaks
   `confidence` on exactly the rows the humans are about to label, and with it
   any "was this routed / was the model certain, and were the humans right"
   analysis.

### GA1 cost, for when this is revisited

GA1 is **18,010,940** pairs (A. 9,897,337 / B. 2,803,995 / C. 2,307,101 scored /
D. 3,002,507). Ranges span two anchors: the design-notes KM C. figure
(1.43 × 10⁻⁵/pair) and the rate measured here (1.72 × 10⁻⁵/pair).

| arrangement | passes | relevance on | audits confident verdicts | GA1 all KMs |
|---|---|---|---|---|
| A — 3-way + noul on routed (**current**) | 2 | 0.5% | yes | $260 – 310 |
| B — noul + 3-way combined | 1 | 100% | yes | $478 – 574 |
| A+ — 4-way choice | 1 | 100% | **no** | $264 – 317 |

Wall time scales mildly, because combining does not change the request count:
~2.5–3 h choice-only for all of GA1, ~3–4 h combined.

### `label_map` — confirmed dead, deliberately left in place

It appears in `jev_claim_questions.json` and **nowhere else**; the real mapping
is hardcoded at `R/score_one_claim_jev.R:183-187`. It should be deleted (not
wired up — a 1:1 rename map with one consumer buys nothing, and one out of step
with `criteria` would silently misassign probabilities).

**But the file is a `format = "file"` target**, so any edit — including deleting
a dead key or fixing a comment — invalidates `claim_scores_by_claim` and forces a
full rescore of 2,307,101 pairs. Not worth $33 on its own. Delete it on the next
genuine rescore, whenever the question changes for a real reason.

### Limits of this evidence

The 4-way comparisons are 40 pairs from 5 claims in a **single BM (C4)**,
deliberately 50/50 routed-versus-saturated rather than production's 0.5/99.5.
Enough to establish direction and that the effects are real; not enough to
predict the production routed fraction, which is what sets Phase 2 cost. If that
number is needed before committing, the same test across several BMs with a
proportional sample is ~$2 of API calls.


# Plan folding keypaper treatment into the citing treatment

It seems that the separation between keypaper and citing is causing unnecessary complexity 
in the pipeline. Look into folding them together into the citing branch, keep the name of the 
citing (`output/claim_work_pairs`, `output/claim_scores`, etc), add two columns (`keypaper` and `citing`) which 
will make it possible to filter for `citing` and `keypaper` and avoids duplicates (or other approach 
which is better - suggest it). Look into doing this 
throughout the fact_checker pipeline up to the `llm_verifiction_parquet` which should contain `llm_verification_keypaper_parquet`
Assess what needs to be re-evaluated.


---

## DONE 2026-10-07 — Phase 1 implemented (storage merged, targets not yet)

### Decision: one hive partition level, not two columns

Not `keypaper` + `citing` columns. Two booleans admit the illegal states (both
TRUE, both FALSE), and a column would have broken the Phase 2 de-duplication key
— `select_llm_verification_candidates()` builds `pair_id` as
`km__bm__claim_id__work_id` with no keypaper dimension, so a shared tree with a
mere column would have collapsed the two chains' rows into each other. As a
partition level the paths never meet and the key stays safe untouched.

```
output/claim_work_pairs/granularity=<g>/keypaper=<true|false>/assessment=<a>/km=/bm=
output/claim_scores/granularity=<g>/scorer_config=<c>/keypaper=<true|false>/assessment=<a>/km=/bm=
output/llm_verification/scores/llm_config=<c>/keypaper=<true|false>/assessment=<a>/nli_route=<r>/km=/bm=
```

**`keypaper=` sits ABOVE `assessment=`, and that placement is load-bearing:**

1. `consolidate_claim_scores.R:96` globs with a `$`-anchored regex,
   `"/assessment=[^/]+/km=[^/]+/bm=[^/]+$"`. Inserting the level *between*
   `assessment=` and `km=` makes it match nothing — the consolidator then sees
   zero on-disk groups and its own prune guard `stop()`s. Above `assessment=`,
   those three terminal levels are untouched.
2. Each chain gets its own `.scratch` root. `score_one_claim()` and
   `score_one_claim_jev()` name scratch files `<claim_id>.parquet`, so under a
   shared root a citing and a key-paper branch for the same claim would race on
   the same filename — the one real data-loss risk in the whole change, removed
   by construction rather than by locking.

Spelling follows the existing precedent in `output/llm_relevance/`:
`paste0("keypaper=", tolower(as.character(keypaper)))` → lowercase `true`/`false`.

### No de-duplication — but not for the reason it first appeared

The sets are disjoint **by definition** under the adopted rule (keypaper = every
paper tagged `relation == "keypaper"`; citing = citing AND NOT keypaper), which
is what `build_works_citing_parquet.R:153`'s `WHERE relation = 'citing'` already
enforces.

Worth recording that the underlying relationship is real and deliberately not
modelled: **1,492 of GA1's 2,137 key papers (70%) do cite another key paper** —
5,924 `keypaper → keypaper` edges in `output/snowball/edges`. They never appear
as `citing` only because `pro_snowball()` gives each node one relation tag and
keypaper wins. The initial "zero overlap" measurement was a fact about the files,
not about the citation graph.

### Migration

`scripts/migrate_keypaper_fold.R` — dry-run default, idempotent, rollback copy in
`.premigration_keypaper_fold/` (gitignored). **Nothing was rescored**: claims are
byte-identical between the chains and premise construction is byte-identical
code, so every existing score migrated.

| tree | action | notes |
|---|---|---|
| `claim_scores`, `claim_work_pairs`, `llm_verification/scores` | directory rename | the 165 GB citing tree never rewritten |
| `claim_work_pairs_keypaper` | rewrite | gained `km=`/`bm=` levels |
| `llm_verification/scores_keypaper` | rewrite | gained `km=`/`bm=` levels |

`km=`/`bm=` were **kept on both sides** — reversing an earlier suggestion to drop
them from Phase 2 — because per-KM funnel reporting needs them prunable.

Verified: row parity **exact** on all three trees (258,203,523 / 8,714,479 /
220,255); key-paper side intact (4,418 scores, 29,496 pairs); `keypaper`
surfaces as a column when opened above the level; GA1 `atomic_bm` funnel levels
unchanged at 6,691 / 87; gold-standard sampler returns identical row counts; all
three projects source (18 / 47 / 49 targets).

### Code changed

Nine R files plus both target scripts:

- `score_one_claim.R`, `score_one_claim_jev.R`, `consolidate_claim_scores.R` —
  new `keypaper` argument threaded into output/scratch paths.
- `build_claim_work_pairs_keypaper.R` — partitions `c("assessment","km","bm")`.
- `build_llm_verification_parquet.R`, `..._keypaper_parquet.R` — `keypaper` level
  between `llm_config=` and `assessment=`.
- `build_goldstandard_sample.R`, `find_orphaned_claim_scores.R`,
  `report_claim_scores_backlog.R` — **pin `keypaper=false`**. These were the
  silent-corruption risks: the sampler feeds the blinded human instrument, and
  the orphan finder *drives deletion* — unpinned it would have reported every
  key-paper score as an orphan.
- `_targets_factcheck.R` — all call sites; also fixed
  `claim_scores_keypaper_consolidated`, which passed neither `assessments=` nor
  `km=` (harmless only while it had a root to itself).
- `_targets_reporting.R` — the two `format = "file"` stubs on the vanished
  keypaper root (a hard error), plus five hand-rolled path formulas.

### Violations found, and what was done

The migration's disjointness assertion surfaced a pre-existing condition:

| | overlaps | live | outcome |
|---|---|---|---|
| GA1 `atomic_bm` | 4,192 | **0** | orphaned scores — left for `find_orphaned_claim_scores_all()` |
| GA1 `complete_bm` | 354 | **354** | **archived** |
| GA1 `naive_bm` | — | corpus only | **archived** |

GA1's `naive_bm`/`complete_bm` corpora predate the `relation = 'citing'` filter
and carry 553 key papers as citing works. **Repair was attempted and rejected on
measurement**: deleting loses 11,289 rows held nowhere else; relabelling looked
right (premise byte-identical on all 434 shared rows) until the claim text proved
identical on only **40 of 434**, with labels disagreeing on 44. `claim_id` is a
*structural* key (`sentence_source`-`sentence_number`), not a hash of the text,
so the two sides had segmented the BM differently and rows sharing a `claim_id`
were not the same claim. Merging them would have been worse than the violation.

Archived instead, to be re-run when wanted:

- `deep_archive/2026-10-07_GA1_naive_complete_bm/` (1.6 GB) — GA1 pairs + scores
  at both granularities, plus 40 derived artifacts.
- `deep_archive/2026-10-07_IAS_factcheck/` (47 GB) — **all** IAS factcheck
  output, at the user's instruction: too many changes accumulated between its
  runs for the outputs to be one coherent corpus. Collection-stage data
  (`works/`, `snowball/`, `works_citing/`, …) deliberately **kept**, since
  refetching costs days of OpenAlex time and would yield a different corpus;
  reporting left in place for now.

Both READMEs carry the full diagnosis. Disjointness now reports **0 live
violations**; `output/claim_scores` is GA1 `atomic_bm` only, with both
`keypaper=` sides.

### Still to do

- **Phase 2 of the plan: merge the 7 targets** (47 → 40), so
  `llm_verification_parquet` subsumes `llm_verification_keypaper_parquet`. The
  highest-risk line is Phase 2 coverage — citing is routed by
  `nli_labels`/`nli_certainty` while key papers pass `NULL, NULL` (every pair
  reviewed), so the merged filter becomes
  `keypaper | (label %in% nli_labels & uncertain %in% allowed)`. Wrong one way
  and key papers silently stop being reviewed; wrong the other and 2.3M citing
  pairs go to full coverage at real cost. Guard with a hard assertion on routed
  counts per `keypaper` value.
- `direct_evidence_match` needs a value for key papers in the merged schema. Use
  `NA`, not `FALSE` — `FALSE` already means "checked, no match" and is what
  `complete_bm` uses for "not supported".
- **Docs still describe the separation**: `CLAUDE.md` (coverage table, tree
  diagram, builder table), `output/README.md`, `input/reports/TD_targets.qmd`,
  `TD_NLI_training.qmd` (contains runnable `open_dataset()` calls).
- IAS was archived rather than cleaned, so its own smaller instance of the
  key-paper contamination (8 works) is parked with it.
- Nothing is committed.




# clean up the comments in the config.yml

There are many outdated and redundant comments in the `config.yml` file - clean the comments up.
Clean opt the workflow_factcheck.mmd and remove the NLI there and from all documentation.

Also: there are several bge (nli) config files - put them into deep_storage.

---

## PARTLY DONE 2026-10-07 — config.yaml cleaned, diagrams and docs not yet

### `input/config.yaml` — 608 → 412 lines

**Restructured to group by targets project**, matching `output/` and
`_targets.yaml`:

```
workers:            factcheck's -- commented to say so, because the name
                    invites the opposite assumption (collection passes its
                    own literal workers = 8 to download_works())
collection:         sparql_url, assessments
fact_checking:      active, relevance_screen, configs
reports:            which reports to render
claim_completion:   library of completion models
nli:                library of scorer configs -- now one entry
llm_verification:   library of judge configs
```

Read through `config_assessments()` (`R/branch_helpers.R`) rather than reaching
into the structure: `assessments` was accessed from six places, and a silent
`NULL` there reads as "no assessments" — every branched target produces nothing,
which looks like a successful empty run rather than a broken config. It now
stops with a message naming the move.

**Deleted outright:**

- `benchmark:` (by the user) and the 12-line comment block that documented it.
- `nli.pod_defaults` — 17 keys, read only by `scripts/runpod/nli_pods.R`.
- The four `bge_m3_*` entries in `nli.configs`, **and** `ga1_all` /
  `ga1_finetuned` in `fact_checking.configs`, which selected them. Removing the
  library entries alone would have left two selections that hard-error on
  switch.
- `nei_threshold: 0.90` ×3 — read by **no code anywhere** (checked R, Python,
  shell, submodule). Same trap class as the `label_map` in
  `jev_claim_questions.json`: it looks authoritative, so editing it feels
  effective while changing nothing.
- The commented-out `nli_finetuned:` template, superseded by the live config
  above it and pointing at `scripts/training/` which no longer exists.
- The hand-written `input/nli_pods_*.conf` → archived to
  `deep_archive/2026-10-07_handwritten_pod_confs/` rather than deleted, because
  they were **never tracked in git**. They are the provenance record for what
  `pod_defaults` held, and they named two configs that had already ceased to
  exist.
- `output/config/` emptied: two `.conf` (regenerated on every run) and two
  `_hosts.csv`. The CSVs were held back until pods were confirmed stopped —
  they are `stop_nli_pods.sh`'s teardown inventory and **that script defaults
  to stop, not delete**, so a merely-stopped pod would still accrue disk
  charges with the CSV as its only handle.

**Moved:** `relevance_screen:` → `fact_checking.relevance_screen`. Its own
comment had said the single `threshold:` "applies to BOTH purposes" and advised
splitting it before setting a real value — but `training:` was retired
2026-10-05, so that advice pointed at a block that no longer existed.

---

## DONE 2026-10-07 (part 2) — diagrams, docs and `r_files`

### `input/config.yaml` — 412 → 367 lines

Three dead comment blocks removed, all describing things that no longer exist:

- The **deberta-vs-bge switch rationale** (~40 lines): both models are retired
  and neither config is in the file. Replaced with a short note saying one
  backend exists and `_targets_factcheck.R` hard-stops on anything else.
- The **orphaned relevance-screen block** at the old top-level position, left
  behind by the move into `fact_checking.relevance_screen`. The live copy was
  already inside the purpose block; this was a second, diverging description of
  the same setting.
- The **`passes: 1` note**, which explained `bge_m3_ft_ga1`'s one-forward-pass
  mode. That config was deleted, so the comment documented nothing present.

The `complete_bm` granularity caveat was rewritten rather than dropped: it named
deberta's hard 512-token position-embedding limit as a live risk, and the
decisions API chunks by a token budget instead, so it does not arise.

**Cost: none.** Editing `config.yaml` changes `config_file`'s content hash and
cascades through the whole factcheck DAG — measured both ways, it was **44 of
46 outdated before the edit and 44 after**. The restructure and rename earlier
in the day had already invalidated everything.

### Diagrams — all seven rewritten or regenerated

Hand-authored, rewritten and each confirmed to render through `mermaid-cli`:

| file | was |
|---|---|
| `workflow_factcheck.mmd` | two backends (RunPod pool + Jev), pre-rename target names, pre-restructure paths, a parallel key-paper chain, dead `shiny_app/` click directives |
| `workflow_reporting.mmd` | pre-restructure paths, two separate key-paper score DBs |
| `overview.mmd` | an argument for a swap that has already happened — "NLI incumbent, Jev proposed" |
| `workflow_collection.mmd` | "one of four" diagrams, flat `output/` paths |

Auto-generated, regenerated from each project's live DAG. **Both were wrong,
and that is what exposed the `r_files` problem below:**

- `pipeline_factcheck.mmd` still named `nli_ready_evidence_parquet` and
  `nli_scores_by_claim_evidence` — it had never been redrawn after the rename.
- `pipeline_reporting.mmd` was a **byte-identical copy of collection's graph**,
  with zero reporting targets in it. Written while the target briefly lived in
  reporting during the split.

### `r_files` → `targets_script` — it never did its job

The question was whether `r_files` is needed for anything. It is not, and it was
actively wrong in both directions:

- **Too sensitive.** `build_pipeline_mmd()` does `force(r_files)` and ignores
  it. Any edit to any of ~60 files in `R/` redrew a byte-identical picture.
- **Not sensitive enough — this is the one that bit.** `tar_mermaid(targets_only
  = TRUE)` draws target-to-target edges from each target's *command expression*,
  so the graph can only change when the **script** changes. `targets` does not
  track the pipeline script as a dependency of the targets it defines, so
  adding, removing or renaming a target left the diagram untouched. Both stale
  files above are that failure, on disk.
- **Collection's copy was broken outright**: `c("_targets.R", list.files("R"))`,
  a `format = "file"` target on a path that stopped existing when the script was
  renamed to `_targets_collection.R`.

Replaced with `tar_target(targets_script, "_targets_<project>.R", format =
"file")` in all three scripts, and the self-exclusion regex in
`build_pipeline_mmd()` updated to match.

### Archived

- `scripts/runpod/` → `deep_archive/2026-10-07_runpod_pod_wrappers/`. Dead, not
  merely unused: `nli_pods.R` reads `nli.pod_defaults` and the active config's
  `image:`/`pods:` blocks, all three deleted, so `emit_conf()` can only die on
  its first lookup. `external/runpod/` (the submodule) **untouched**.
- `scripts/benchmark/` and `scripts/training/` — `__pycache__` of Python scripts
  deleted on 2026-10-05, nothing else in either.

### ⚠ The bge score trees are NOT orphaned — near miss

`scorer_config=bge_m3_ft_ga1` (77 MB) and `scorer_config=bge_m3_zeroshot_atomic_bm`
(180 MB) were archived as orphans and **restored the same hour**. Both are live
inputs to `build_goldstandard_sample()`, which inner-joins all three scorer trees
to build the Phase 1 three-way common set the imminent human review round draws
from; `goldstandard_read_scores()` `stop()`s if either is missing.

The reasoning that got it wrong is worth keeping, because the check *looked*
sound: every reader in `R/` builds its read path with an explicit
`scorer_config=<name>`, and nothing globs at the `granularity=` level — so with
both configs deleted from `nli.configs`, nothing config-driven could address
them. The gap is that `build_goldstandard_sample()` takes the names from **its
own `scorer_configs` default argument**, not from config. "Every path is
config-driven" was assumed, not verified.

Guards added: a ⚠ block in `config.yaml` beside `ga1_jev`, and the
`build_goldstandard_sample.R` row in `CLAUDE.md` now states it outright.

### Documentation

- **`CLAUDE.md`** — structural half rewritten (462 → 532 lines). It described
  four projects, a `main` project, a flat `output/`, a RunPod pool, and a
  parallel key-paper chain. The R-files table was reconciled against disk:
  **16 listed files did not exist and 13 existing files were not listed.** The
  11 renames from `f5d635a` applied, the 5 files deleted in `0c9784d` moved into
  the removed-files row, output paths repointed. The `build_goldstandard_sample.R`
  row was rewritten — it still described the v1 holdout-fold draw, wrong in
  every substantive claim after the 2026-10-07 redraw.
- **`README.md`** — four projects → three, `main` → `collection`, the pool-health
  caution replaced with the do-not-run-collection warning.
- **`output/README.md`** — folder/target/builder renames, `scorer_model`
  replacing `nli_model`, diagram filenames, `output/config/` noted as empty.
- **NOT touched, deliberately:** `design_notes.md` (the record of *why* the NLI
  was dropped — its NLI content is the point) and `input/reports/TD_NLI_training.qmd`
  (same, for the training project).

### Still carrying `nli_` names — live, not leftovers

`_targets_reporting.R` still has `nli_overview_data`, `nli_scores_qa_data`,
`nli_bm_explorer_html`, `nli_granularities`, `nli_overview_figures`,
`nli_scores_qa_figures`: the `f5d635a` rename covered `_targets_factcheck.R`
only. The `nli:` config key, the `nli_route=` partition level and the
`nli_label`/`nli_config`/`nli_confidence` columns in
`llm_verification/scores` are likewise structural and read from a dozen places.
Renaming them is a separate change that would invalidate the reporting store.

### Not done

`input/reports/TD_targets.qmd` — 93 NLI-ish references and 22 flat `output/`
paths across 1,029 lines. It is a design document describing the split itself,
so it needs reading rather than patching.

`batch_size: 20` was dropped with it: `build_llm_relevance_screen.R:130` records
it as accepted and **ignored**, since chunking is by token budget.

**Comments corrected** (facts, not style): `training:` written in the present
tense; `check_nli_pool_health()` described as automatic when it is hand-run
only; renamed functions (`build_nli_claim_units` → `build_claim_units`,
`consolidate_nli_scores` → `consolidate_claim_scores`); pre-restructure paths
(`output/nli_scores_evidence/` → `output/factchecker/claim_scores/`); and one
outright false claim — `naive_bm` described as "(default) … Currently active"
when it is neither active nor scored anywhere.

### `_targets_factcheck.R` — now Jev-only, 47 → 46 targets

- **Backend dispatch removed.** Both scoring targets called
  `score_one_claim_jev()` or `score_one_claim()` on `backend:`. They now call
  Jev directly, behind a hard `stop()` naming the offending config.
- **Crew sizing** (~55 lines → 6). It read `config.yaml` at script-source time
  to count pool hosts, including the `return()`-at-top-level trap. Under Jev it
  always returned `4L`; now it is `4L`.
- **`scorer_host_locks_cleanup` deleted** — it cleaned `score_one_claim()`'s
  per-host file locks, and `score_one_claim_jev()` has no locking. `filelock`
  dropped from the package list.
- 12 comment blocks corrected: the header said "one of **four** projects" and
  listed `_targets_training.R`; the scoring target described "a zero-shot NLI
  model served on a pool of RunPod hosts".

The guard is kept deliberately even though no non-jev config remains: restoring
one from `NLI_dirty` is a paste, and without it a RunPod-shaped config
(`host:`, `passes:`, `batch_size:`) would reach the Jev scorer and score a whole
corpus against the wrong thing, under the right `scorer_config=` name.

### STILL TO DO from this section

- **`input/mmd/workflow_factcheck.mmd` still has 16 NLI/RunPod references** and
  still depicts Phase 1 as having two backends. `overview.mmd` has 8,
  `workflow_reporting.mmd` 7, `workflow_collection.mmd` 1.
- **The documentation sweep has not happened.** `CLAUDE.md` (38 NLI mentions)
  still describes the flat `output/`, the pre-fold keypaper chain, the old
  config shape and `_targets.R`; `output/README.md` (14) and `README.md` (3)
  likewise. **`design_notes.md` (38) must NOT be cleaned** — it is the record of
  why the NLI was dropped, and its measurements are the justification.
- **The two orphaned bge score trees are still in `output/`**, now unreachable
  by any config-driven path since `nli_config_for_granularity()` resolves all
  three granularities to `jev_atomic_bm`:
  `claim_scores/granularity=atomic_bm/scorer_config=bge_m3_zeroshot_atomic_bm/`
  and `.../scorer_config=bge_m3_ft_ga1/` (~300 MB). Nothing depends on them —
  the gold-standard instrument is drawn with all three models' labels frozen
  into `sample_manifest_GA1.csv`, and the comparison artifact is published.

# MANUAL:

Assess the costs to run Jev for the whole assessment and run it manually if fine.

# Reasoning switch NLI -> Jev

Add one document outlining the reasoning of the switch including measurements, comparisons, reasoning etc. 
This will become part of the supplemental material of a paper.
 


# Plan moving the QA reports into the appropriate pipelines 

Re-arrange the reporting of the QA reports, which report to certain aspects in the pipeline, 
into the pipelines. Create for each a separate quarto project, and they should publish the 
website into `output/reports/PIPELINE_NAME_QA/`.
Input should also be `input/reports/PIPELINE_NAME_QA/`. 
Reasoning: the QA reports should be available after the pipeline is completed, not only 
after all pipelines are completed.

Do this for the main pipeline as well as the `factchecker`.

Revise the `factchecker` reports so that they fit to the current Jev based setup. Move 
non-needed reports to the deep_archive.
Write the remaining ones in an understandable language for ecologists / non AI experts. Even I have 
problems following the current versions. 

The overall reports should be in a folder `input/reports/overall` in the input and 
`output/reports/overall` in the output.

`input/reports` and therefore `output/reports` should only contain an index file linking 
to the other quarto projects (pipelines and overall). I think static is easier.

# Plan the Development of a Shiny app for review

The shiny app should be used for the human review. It should provide

- a download button to download the template (as csv, xlsx or openoffice) to be filled in. 
  These can be multiple templates to choose from, individual assessments, multiple 
  assessments combined, etc.
  A name is also required, to avoid unplanned re-scoring. But if a re-scoring is the idea,
  see below the VERSION.
- an upload button for the filled in template. The upload requires a name of the uploader
  For each uploader, an id should be created in a file and be used.
  It it should check the filled in form for correctness.
  If correct: save it under the name `ASSESSMENTS_REVIERID_VERSION.csv`. If it is a new 
  version (upload), the version is increased by one.

Is this a solid design? Any improvements? I do not want to deal with GDRP and emails etc.


