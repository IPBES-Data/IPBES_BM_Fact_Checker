# LLM Alignment Scoring Approach

## Overview

This document describes the LLM-based alignment scoring approach: feeding structured
representations of an IPBES Background Message (the *truth*) and a citing paper (the
*candidate*) to an LLM via OpenRouter/ellmer, and receiving a structured judgement of
whether the paper supports, contradicts, or is neutral toward the BM.

This approach was the original pipeline (now parked — see CLAUDE.md) and is the
intended **Phase 2** of the two-phase NLI → LLM pipeline described in
[TD_NLI_LLM_two_phase.md](TD_NLI_LLM_two_phase.md). In Phase 2, only the subset of
papers that NLI flagged as uncertain or contradicting are sent here.

---

## Prompt Architecture

The LLM receives two documents per scoring decision, each preceded by a short wrapper:

```
[System prompt]          ← task definition, output schema, rules
[Truth wrapper]          ← names the reference document, explains its schema
[Truth JSON]             ← structured BM + SM + source passages
[Citing wrapper]         ← names the candidate paper, explains its schema
[Citing JSON]            ← title, abstract, work_id, doi, publication_year
```

### Why JSON, not Markdown

BM source passages contain literal `#` characters, parenthetical citations, and
table-derived text. Wrapping in Markdown breaks the outer document structure. JSON
treats each source as opaque text and round-trips cleanly through the LLM.

### Prefix caching

The `(system + truth wrapper + truth JSON + citing wrapper)` prefix is identical for
all candidate papers scored against the same BM. OpenRouter/OpenAI auto-cache
identical prefixes — the BM portion costs full price once per BM, and only the citing
JSON suffix is the variable cost per candidate. Group calls by BM to exploit this.

---

## Truth Document Structure

One document per `(assessment, KM, BM)`. Built by
[R/build_prompts_truth_parquet.R](R/build_prompts_truth_parquet.R).

```json
{
  "assessment": "GA1",
  "km": "A.",
  "km_label": "...",
  "km_description": "...",
  "bm": "A1",
  "bm_label": "...",
  "bm_description": "...",
  "bm_well_established": "...",
  "bm_established_incomplete": "...",
  "sub_messages": [
    {
      "sm_id": "A1.1",
      "sm_description": "...",
      "sm_well_established": "...",
      "sm_established_incomplete": "...",
      "sources": [
        {
          "section": "...",
          "subsection": "...",
          "content": "raw passage text from the assessment chapter"
        }
      ]
    }
  ]
}
```

Note: the same source passage may appear under multiple SubMessages — this is accurate
to the underlying LOD and not a bug.

---

## Citing Document Structure

One document per citing work. Built by
[R/build_prompts_citing_parquet.R](R/build_prompts_citing_parquet.R).

```json
{
  "assessment": "GA1",
  "km": "A.",
  "bm": "A1",
  "work_id": "W2741809807",
  "doi": "10.1038/...",
  "publication_year": 2021,
  "relation": "citing",
  "title": "...",
  "abstract": "..."
}
```

---

## Output Schema

Defined as an `ellmer` structured type in
[R/alignement_schema.R](R/alignement_schema.R). One row per `(KM, BM, work_id)`.

| Field | Type | Description |
|---|---|---|
| `lm_id` | string | Must match `km` from the truth document |
| `work_id` | string | Must match `work_id` from the citing document |
| `km_summary` | string | KM distilled to ≤ 20 words |
| `work_alignement` | integer | −5 to +5 (see rubric below) |
| `confidence` | number | 0–1 confidence in the score |
| `evidence` | string | Supporting excerpt from title/abstract, ≤ 100 words |
| `justification` | string | Explanation of the score, ≤ 100 words |

### Alignment rubric

| Score | Meaning |
|---|---|
| +5 | Strong support — findings directly corroborate the BM |
| +3 | Moderate support |
| +1 | Slight support |
| 0 | Neutral / not enough information |
| −1 | Slight contradiction |
| −3 | Moderate contradiction |
| −5 | Strong contradiction — findings directly oppose the BM |

---

## System Prompt (current)

Located at [input/prompts/system_prompt.md](input/prompts/system_prompt.md). Key rules:

- Use only the information in the two JSON documents — no outside knowledge
- Do not invent quotations or claims not present in the abstract
- If the abstract is missing or very short, say so explicitly and lower confidence
- Return the JSON object directly — no markdown fences, no preamble

---

## Implementation

The scoring pipeline is in
[R/build_alignement_scores_parquet.R](R/build_alignement_scores_parquet.R):

1. Load truth prompt for the `(assessment, KM, BM)`
2. Load citing prompts for the same partition (optionally capped at `n_citing`)
3. Build user prompts: `truth_wrapper + truth_json + citing_wrapper + citing_json`
4. Call `ellmer::parallel_chat_structured()` with `max_active` concurrent requests
5. Validate structured output; retry individually on failure
6. Write to `output/alignement_scores/assessment=<id>/run_id=<id>/km=<km>/bm=<bm>/model=<model>/replicate=<n>/`

Run configuration (model, KMs to score, `n_citing`, `replicates`, `temperature`) is
defined per run in the `analysis:` block of `input/config.yaml`.

---

## Shortcomings

**Cost at scale**

At 330k pairs × ~550 tokens average prompt → ~180M input tokens. At `gpt-4o-mini`
rates ($0.15/1M) that is ~$27 in input tokens alone, plus output. Acceptable for a
targeted subset; prohibitive for the full pair space.

**Speed**

Even with `max_active = 8` parallel calls, scoring 330k pairs takes days, not hours.
NLI does the same in ~75 minutes.

**No probability distribution**

The LLM returns a point estimate (`work_alignement`) and a self-reported `confidence`.
Neither is calibrated. The NLI model returns a proper probability distribution over
three classes, which is more useful for downstream thresholding.

**Prompt sensitivity**

Small changes to the system prompt or wrapper text can shift scores significantly.
The NLI model is not affected by prompt wording.

**Abstract-only**

Both approaches are limited to title + abstract. Full-text classification would require
chunking and aggregation and is not yet implemented.

**Multi-part BMs**

A paper may support one sub-message of a BM while contradicting another. The LLM
returns a single score for the whole BM. Splitting BMs into atomic sub-claims before
scoring would improve precision but multiply the number of calls.

---

## Relation to the Two-Phase Pipeline

In [TD_NLI_LLM_two_phase.md](TD_NLI_LLM_two_phase.md), this LLM approach becomes
**Phase 2** applied only to the NLI remainder:

- NLI `uncertain` cases → LLM for refinement + explanation
- NLI `REFUTES` cases → LLM for confirmation + explanation (high stakes)
- NLI high-confidence `SUPPORTS` → accepted without LLM review

The `work_alignement` −5 to +5 scale remains the target output format. The NLI
label and confidence scores are added to the prompt as a prior (see
[TD_NLI_LLM_two_phase.md](TD_NLI_LLM_two_phase.md) for the adapted prompt template).

---

## See Also

- [TD_BM NLI approach.md](TD_BM%20NLI%20approach.md) — Phase 1 design
- [TD_NLI_LLM_two_phase.md](TD_NLI_LLM_two_phase.md) — two-phase pipeline design
- [TD_NLI_training.md](TD_NLI_training.md) — fine-tuning the NLI model
- [R/build_alignement_scores_parquet.R](R/build_alignement_scores_parquet.R) — implementation
- [R/alignement_schema.R](R/alignement_schema.R) — ellmer structured output schema
- [input/prompts/](input/prompts/) — system prompt and wrapper files
