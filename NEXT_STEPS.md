# Next Steps

## NLI pipeline improvements

### Problem

The BM descriptions used as NLI hypotheses are too long. The HuggingFace tokenizer uses a
longest-first truncation strategy on the (premise, hypothesis) pair, so a long BM description
gets trimmed just as aggressively as the abstract. Increasing `max_length` from 256 to 512
had zero effect on A1 results, confirming the hypothesis length — not abstract truncation — is
the bottleneck.

### Proposed approach

1. **Split BM descriptions into sentences** — avoids LLM summarisation risk (meaning distortion,
   non-determinism). Each sentence is short enough (~20–60 tokens) to leave the full abstract
   budget available at 512 tokens.

2. **Filter to claim-bearing sentences** using zero-shot NLI self-filtering: score each BM
   sentence against the hypothesis `"This sentence makes a verifiable empirical claim."` using
   the existing NLI server; keep only SUPPORTS. This bootstraps off existing infrastructure
   with no new model or dependency. Fall back to heuristics (minimum length, exclude
   definitional openers) if the self-filter over- or under-selects.

   Alternative: **CheckThat! lab** (CLEF) checkworthiness detection models — trained specifically
   to identify sentences worth fact-checking. More principled but adds a dependency.

3. **Run filtered sentences as hypotheses at `max_length: 512`** — short hypothesis + full
   abstract budget. Each citing work is scored once per retained BM sentence; aggregate across
   sentences (e.g. max `p_supports`, mean alignment score) to get a per-work per-BM score.

### Design decision outstanding

Aggregation strategy across per-sentence scores:
- Max `p_supports` across sentences
- Mean alignment score (`p_supports - p_refutes`)
- "Any sentence SUPPORTS" (binary)
- Majority vote

Evaluate on KM D (where the current approach already works) to validate that the new pipeline
does not regress before applying to KMs A–C.

### Alternative claim segmentation — split on evidence references, not sentences

The `bm_label` and `bm_description` text carries inline **evidence references** to the
sub-chapters backing each sub-claim, in the form `{x.y, a.b.c, ...}` (a brace-delimited list
of section numbers). These braces mark the *boundaries* of what the assessment authors treat as
one discrete, evidenced claim — a more meaningful unit than an arbitrary sentence break.

Coverage was checked against all 88 distinct BMs (39 GA1 + 49 IAS):

- `bm_description`: 100% of BMs contain `{...}`; mean 4.67 (GA1) / 8.82 (IAS) references per
  description — genuinely multi-claim. This is where the strategy does its work.
- `bm_label`: 77% (GA1) / 100% (IAS) contain `{...}`, but almost always exactly **one** trailing
  reference. The same rule below therefore collapses a label to a single claim (= the whole
  label) — no special-casing; labels just happen to have one segment.
- Of the description braces, ~86% sit at a sentence end; ~10–12% are mid-sentence inline
  citations attached to a clause (e.g. `…distorting subsidies {2.3.5.2, …}, and – at landscape
  scales – …`). Splitting on those would produce non-standalone fragments, hence the
  **sentence-end-only** rule below.

Segmentation rule:

1. **Split only at a `{...}` that ends a sentence** — i.e. the brace is followed by `.` (optionally
   through a closing `)` and/or a confidence qualifier like `(established but incomplete)`) or by
   end-of-string. A **mid-sentence brace is an inline citation and does NOT trigger a split**.
   Everything from the previous boundary up to and including the sentence-ending brace is one
   claim unit. **Multiple sentences before a brace stay together as one claim** (this is expected
   and fine).
2. **No `{...}` at all → the complete label / description is one claim.** This also covers a
   trailing brace-less final sentence (e.g. a synthesising statement) at the end of an otherwise
   evidenced description — it becomes its own claim rather than being dropped or folded into the
   preceding one.
3. Strip the `{...}` markers from the `claim` text used as the NLI hypothesis (provenance
   metadata, not part of the assertion), but consider **retaining them separately** — the section
   numbers could later be joined against `sections_parquet` to fetch the actual backing text,
   grounding a premise = citing-work-abstract vs. hypothesis = assessment-claim comparison in the
   specific evidence the authors cited. Note the reference content is heterogeneous (`{box 2.6;
   4.6}`, `{table 4.33}`, `{Figure …}`, mixing `,` and `;` separators), so that later join must
   parse `box`/`table`/`Figure` tokens and both separators; the segmentation itself treats `{...}`
   as an opaque marker and is unaffected.

**Status: implemented** as a parallel *second* approach (not a replacement), so the two
segmentations can be scored and compared side by side. `R/build_nli_ready_evidence_parquet.R`
(`segment_bm_by_evidence()` + `build_nli_ready_evidence_parquet()`) mirrors the per-sentence
`build_nli_ready_parquet.R` with identical output schema, writing to
`output/nli_ready_evidence/`. Targets: `nli_ready_evidence_parquet` →
`nli_claim_units_evidence` → `nli_claim_units_evidence_flat` →
`nli_scores_by_claim_evidence` (scores to `output/nli_scores_evidence/`). The claim-unit and
scoring functions are reused unchanged — `claim_id` is assigned per evidence-delimited segment
because that is simply what `sentence_number`/`sentence_source` now index.

Still open: the overview/report targets (`nli_overview_data`, the QMD "NLI Alignment Scores"
section) currently read only the per-sentence `output/nli_scores/` tree; comparing the two
approaches in the report needs those to also (optionally) read `output/nli_scores_evidence/`.

## Incremental (resumable) NLI scoring

Scoring is dispatched at claim granularity: `nli_scores_by_claim` is a
`targets` dynamic branch per `(km, bm, sentence_source, sentence_number)`
claim (`R/score_one_claim.R`), fanned out across the active nli pool's hosts
via `crew` (`crew_controller_local`) with dynamic dispatch — each claim's
function tries every host's file lock (`output/nli_scores/.locks/`) and
whichever host is free next gets it, rather than a static upfront
assignment. `error = "continue"` means a failing claim is reported live and
marked failed while every other claim proceeds independently.

Resumability is now mostly `targets`' own branch caching: an unchanged,
already-succeeded claim is skipped automatically on the next `tar_make()`.
`score_one_claim()` additionally checks whether output already exists for a
claim's `claim_id=` directory before doing any work — this bridges claims
scored by an earlier run/system that `targets` itself has no cache entry
for (e.g. the pre-claim-level `mclapply` design this replaced).

**Known limitations** (acceptable for the append-only growth case, revisit if needed):

- **Abstract change undetected**: if a work's abstract (premise) changes but
  its `work_id` and the claim stay the same, the cached score is kept — the
  premise is not part of the on-disk output, so there's nothing to compare
  against without a hash.
- **Removed rows leave stale scores**: if a pair disappears from
  `nli_ready_parquet` (e.g. a work is dropped upstream), its old score
  remains in the output. A full recompute requires deleting the relevant
  `output/nli_scores/nli_config=<x>/assessment=<y>/km=.../bm=.../claim_id=.../`
  directory (or the whole `nli_config=<x>/` tree).

## Handling long (premise, claim) pairs

### Current behaviour — all pairs are scored (over-length ones truncated)

**Every work of every scored claim is scored.** `score_one_claim()` sends every
`(premise, hypothesis)` pair to the server without re-applying a token filter; the server
tokenizes with `truncation="longest_first"` at `max_length`, so a pair over the limit is
**truncated, not dropped**. Because the hypothesis (a BM sentence/segment) is short and the
premise (title + abstract) is the long side, truncation almost always trims the **tail of the
abstract** and leaves the full claim intact.

This is the intended behaviour — scoring every citing work is preferred over skipping long ones.
(The `approx_tokens <= max_length` filter in `build_nli_claim_units` only affects the row
*count* used for largest-first ordering; it does not drop any work from scoring, and in practice
all 600 evidence claims are enumerated.)

Consequence for progress accounting: the number of rows actually written exceeds the
`approx_tokens <= max_length` count, so a progress bar using that filtered count as its
denominator (e.g. `watch_gpu.sh`'s `get_target_total`) will read past 100%. The honest
denominator is the *unfiltered* row count.

### Optional enhancement — abstract chunking (lossless alternative to truncation)

Truncation silently drops the tail of a long abstract, which *could* omit the most relevant
sentence — opaque and hard to audit. If lossless handling is ever wanted, replace truncation
with chunking rather than reverting to skipping:

Split long abstracts into overlapping windows (e.g. 400-token chunks, 50-token overlap), score
each `(chunk, claim)` pair separately, then aggregate across chunks — e.g. `max(p_supports)`
or `max(p_supports - p_refutes)`. No information is dropped.

Implementation sketch (in `score_one_claim`, `R/score_one_claim.R`):

```r
chunk_premise <- function(premise, max_tokens, overlap = 50L) {
  words <- strsplit(premise, "\\s+")[[1L]]
  step  <- max_tokens - overlap
  starts <- seq(1L, length(words), by = step)
  lapply(starts, function(s) paste(words[s:min(s + max_tokens - 1L, length(words))], collapse = " "))
}
```

Aggregate: for each `(work_id, sentence_number)` take `max(p_supports)` across chunks.

Gating condition: only trigger when `approx_tokens > max_length`; rows that already fit are
scored as a single pair (no change to existing behaviour).
