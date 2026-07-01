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

## Incremental (resumable) NLI scoring

`build_nli_scores_parquet` no longer wipes its output at the start of a run. On
re-run it reads the existing scores for the current `(nli_config, assessment)`,
builds a key per scored pair, and skips pairs already present — only new pairs
are POSTed and appended (with a unique per-run `basename_template`, so old files
are preserved). This makes growth cheap: adding works, sentences, or BMs to
`nli_ready_parquet` only scores the additions.

The dedup key is `(km, bm, sentence_number, sentence_source, work_id, claim)`.

**Known limitations** (acceptable for the append-only growth case, revisit if needed):

- **Abstract change undetected**: if a work's abstract (premise) changes but its
  `work_id` and the claim stay the same, the cached score is kept — the premise
  is not part of the key (it is not stored in the output). Fix if needed: store a
  hash of the premise and include it in the key.
- **Removed rows leave stale scores**: if a pair disappears from
  `nli_ready_parquet` (e.g. a work is dropped upstream), its old score remains in
  the output. A full recompute requires deleting `output/nli_scores/nli_config=<x>/`.

## Handling long (premise, claim) pairs

### Current behaviour

Rows in `nli_ready_parquet` where `approx_tokens > max_length` are currently **skipped**
(not scored). A count is logged per assessment. This happens when an abstract is very long
relative to the sentence used as the claim.

### Why not truncation or LLM summarisation?

- **Auto-truncation**: the NLI model silently drops the tail of the abstract — opaque, hard to
  audit, may remove the most relevant sentence.
- **LLM summarisation**: non-deterministic, adds a dependency, risks meaning distortion.

### Planned approach — abstract chunking

Split long abstracts into overlapping windows (e.g. 400-token chunks, 50-token overlap), score
each `(chunk, claim)` pair separately, then aggregate across chunks — e.g. `max(p_supports)`
or `max(p_supports - p_refutes)`. No information is dropped.

Implementation sketch (in `build_nli_scores_parquet`):

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
