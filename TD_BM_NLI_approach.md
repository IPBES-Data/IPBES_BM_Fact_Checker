# Assessing Reference Support for IPBES Background Messages via NLI

## Overview

This document describes a pipeline for systematically classifying whether scientific
references **support**, **contradict**, or are **not relevant** to a given IPBES background
message (BM). The approach uses Natural Language Inference (NLI) — a text classification
task where a model determines the logical relationship between a *premise* (here: an
abstract) and a *hypothesis* (here: a background message).

The pipeline deliberately avoids a retrieval/filtering stage. Instead, NLI is run across
the complete reference set, using the model's own confidence scores as the filter. This
eliminates retrieval recall risk and produces a fully auditable, reproducible result with
no embedding hyperparameters to justify.

---

## Why NLI Without Prior Retrieval?

A natural first instinct is to pre-filter references using semantic similarity (e.g.
SPECTER2 embeddings), then run NLI only on the top-k candidates. This is computationally
attractive but has a critical weakness: **false negatives at retrieval stage are silent**.

A paper may be highly relevant to a BM without being semantically close in embedding
space. IPBES background messages are synthetic, policy-oriented claims — they do not
resemble any individual abstract. A study on soil carbon flux in Amazonia may directly
support a BM about terrestrial carbon sinks, but the vocabulary overlap is low and the
paper would likely not rank in the top-k.

Running NLI on the full set avoids this entirely. With GPU access the compute is
manageable (see numbers below), and the pipeline becomes a single auditable step.

---

## The NLI Task

NLI models take a *premise–hypothesis* pair and return a probability distribution over
three classes:

| Class | Meaning in this context |
|---|---|
| `SUPPORTS` | The abstract provides evidence consistent with the BM |
| `REFUTES` | The abstract provides evidence against the BM |
| `NOT_ENOUGH_INFO` | The abstract does not address the BM |

The claim–abstract framing maps directly onto the **SciFact** benchmark (Wadden et al.,
2020), which is precisely: *given a scientific claim and an abstract, classify as
SUPPORTS / REFUTES / NOT_ENOUGH_INFO*. Models fine-tuned on SciFact are the natural
starting point.

---

## Recommended Model

**`MoritzLaurer/deberta-v3-large-zeroshot-v2.0`**

DeBERTa-v3-large is consistently among the strongest NLI models across benchmarks.
Laurer's version is fine-tuned on a large cross-domain NLI corpus and performs well in
zero-shot settings on new domains — relevant here because biodiversity/IPBES language
differs from biomedical or computer science text that many SciFact models are trained on.

Alternatives worth benchmarking:

| Model | Notes |
|---|---|
| `MoritzLaurer/deberta-v3-large-zeroshot-v2.0` | **Recommended.** Strong cross-domain NLI |
| `allenai/scibert_scivocab_uncased` fine-tuned on SciFact | Science-specific vocabulary, shorter context |
| `facebook/bart-large-mnli` | General NLI, zero-shot, weaker on scientific text |
| `pritamdeka/S-PubMedBert-MS-MARCO-SciFact` | Biomedical focus, likely suboptimal for ecology |

For IPBES specifically, validate model choice by manually labelling 20–30 BM–abstract
pairs and checking model agreement before committing to a full run.

---

## Context Length Considerations

DeBERTa-v3-large has a maximum context of **512 tokens** (claim + abstract combined).
Most abstracts are 150–250 words (~200–330 tokens). A typical IPBES BM is 30–80 words
(~40–110 tokens). This leaves comfortable headroom in most cases.

**Action:** Check your abstract length distribution before running:

```r
library(dplyr)
library(tokenizers)

refs |>
  mutate(n_tokens = map_int(abstract, ~ length(tokenize_words(.x)[[1]]))) |>
  summarise(
    median_tokens = median(n_tokens),
    p95_tokens    = quantile(n_tokens, 0.95),
    n_over_400    = sum(n_tokens > 400)
  )
```

For abstracts exceeding ~400 tokens, truncate from the end (the claim is typically stated
early). Do not truncate mid-sentence.

---

## Compute Estimates

### Throughput by hardware

| Setup | Throughput | Basis |
|---|---|---|
| RunPod L4 GPU (24 GB) | 50–100 pairs/sec | DeBERTa-large, batch size 32 |
| RunPod A100 (80 GB) | 150–250 pairs/sec | Larger batch sizes |
| HuggingFace Inference API | 5–10 pairs/sec | Free tier, shared inference |
| CPU only (local) | 1–2 pairs/sec | Not recommended at scale |

### Time estimates for common scales

Assuming 50 background messages and varying reference set sizes, at 75 pairs/sec (L4 GPU,
conservative midpoint):

| References | Total pairs | L4 GPU | HF API |
|---|---|---|---|
| 500 | 25,000 | ~6 min | ~45 min |
| 2,000 | 100,000 | ~22 min | ~3 hrs |
| 5,000 | 250,000 | ~56 min | ~7 hrs |
| 10,000 | 500,000 | ~1.9 hrs | ~14 hrs |

For the typical IPBES assessment reference set (500–3,000 papers), **a single L4 GPU run
of 20–60 minutes** covers the full pipeline. This makes retrieval pre-filtering
unnecessary.

---

## Pipeline Design

### Inputs

- `background_messages`: a data frame with columns `bm_id`, `bm_text`
- `references`: a data frame with columns `ref_id`, `title`, `abstract`

### Steps

```
1. Preprocess
   ├── Concatenate title + abstract for each reference (title adds context)
   ├── Truncate to 400 tokens if needed
   └── Cross-join BMs × references → pairs data frame

2. NLI inference (batched)
   ├── Send batches of pairs to model
   ├── Receive probability scores for [SUPPORTS, REFUTES, NOT_ENOUGH_INFO]
   └── Store raw scores alongside predicted label

3. Post-filter
   ├── Drop pairs where p(NOT_ENOUGH_INFO) > 0.90 (configurable threshold)
   └── Flag pairs where max(p) < 0.60 as "uncertain" for human review

4. Output
   ├── Full results table (all pairs, raw scores)
   ├── Filtered table (SUPPORTS / REFUTES only, above threshold)
   └── Per-BM summary: n_supporting, n_contradicting, n_uncertain
```

### Output schema

```r
# One row per BM–reference pair
tibble(
  bm_id       = character(),   # Background message identifier
  ref_id      = character(),   # Reference identifier (DOI or internal ID)
  label       = character(),   # "SUPPORTS" | "REFUTES" | "NOT_ENOUGH_INFO"
  p_supports  = double(),      # Model probability for SUPPORTS
  p_refutes   = double(),      # Model probability for REFUTES
  p_nei       = double(),      # Model probability for NOT_ENOUGH_INFO
  confidence  = double(),      # max(p_supports, p_refutes, p_nei)
  uncertain   = logical()      # TRUE if confidence < threshold
)
```

---

## R Implementation Outline

### Option A — HuggingFace Inference API (prototyping)

```r
library(httr2)
library(purrr)
library(dplyr)

classify_nli <- function(premise, hypothesis,
                          model = "MoritzLaurer/deberta-v3-large-zeroshot-v2.0",
                          hf_token = Sys.getenv("HF_TOKEN")) {
  resp <- request("https://api-inference.huggingface.co/models") |>
    req_url_path_append(model) |>
    req_auth_bearer_token(hf_token) |>
    req_body_json(list(
      inputs = list(premise = premise, hypothesis = hypothesis)
    )) |>
    req_retry(max_tries = 3, backoff = ~ 5) |>
    req_perform() |>
    resp_body_json()

  # Response is a list of lists: [[label, score], ...]
  scores <- resp[[1]] |>
    map_dfr(~ tibble(label = .x$label, score = .x$score))

  scores
}

# Apply across all pairs (rate-limit aware)
results <- pairs |>
  mutate(
    nli = map2(abstract_text, bm_text, classify_nli, .progress = TRUE)
  ) |>
  unnest(nli)
```

### Option B — Local/RunPod inference via reticulate (production)

```r
library(reticulate)

# Python environment with transformers + torch
transformers <- import("transformers")
torch        <- import("torch")

pipe <- transformers$pipeline(
  "zero-shot-classification",
  model  = "MoritzLaurer/deberta-v3-large-zeroshot-v2.0",
  device = 0L   # GPU device index; -1 for CPU
)

classify_batch <- function(premises, hypothesis,
                            candidate_labels = c("supports", "refutes", "not relevant"),
                            batch_size = 32L) {
  pipe(
    premises,
    candidate_labels = candidate_labels,
    hypothesis_template = paste("This paper", "{}", "the following claim:", hypothesis),
    batch_size = batch_size
  )
}
```

Note: the `hypothesis_template` is important for zero-shot NLI — it frames the
classification correctly relative to the candidate labels.

---

## Thresholds and Human Review

The model returns a probability distribution, not a binary decision. Choose thresholds
based on your downstream use:

| Threshold | Recommendation |
|---|---|
| `p(NOT_ENOUGH_INFO) > 0.90` | Discard as not relevant |
| `confidence < 0.60` | Flag as uncertain, queue for human review |
| `p(SUPPORTS) > 0.75` | High-confidence support |
| `p(REFUTES) > 0.75` | High-confidence contradiction — always human-reviewed |

Contradictions deserve special attention: a high-confidence `REFUTES` classification is
scientifically significant and should never be accepted without expert review.

---

## Limitations

- **BMs are synthetic claims.** They aggregate evidence from multiple papers. No single
  paper may directly assert a BM; the model may undercount support as a result.
- **Partial support is not modelled.** A paper may address one aspect of a multi-part BM.
  Consider splitting complex BMs into atomic sub-claims before classification.
- **Domain shift.** Models trained on biomedical SciFact may underperform on ecology and
  biodiversity language. Benchmark on a hand-labelled sample first.
- **Abstract-only coverage.** Full-text classification would require chunking and
  aggregation across sections — feasible but adds complexity.
- **512-token limit.** Long abstracts must be truncated, with possible loss of relevant
  detail.

---

## Recommended Workflow

1. **Sample and label** 30–50 BM–abstract pairs manually (covering all three classes)
2. **Benchmark** two or three candidate models on this sample; pick the best
3. **Run full pipeline** on RunPod L4 with chosen model, batches of 32
4. **Apply thresholds** to produce filtered results table
5. **Human expert review** of all `REFUTES` calls and all `uncertain` cases
6. **Summarise per BM**: n_supporting, n_contradicting, n_uncertain, n_not_relevant

---

## See also

- https://towardsdatascience.com/natural-language-inference-an-overview-57c0eecf6517/
- https://medium.com/@mllabucu/natural-language-inference-for-fact-checking-on-wikipedia-d3f0825b062f

---

## References

- Wadden, D. et al. (2020). Fact or Fiction: Verifying Scientific Claims. *EMNLP 2020*.
  SciFact dataset and baseline models. https://github.com/allenai/scifact
- Laurer, M. et al. (2022). Less Annotating, More Classifying. DeBERTa zero-shot NLI
  models. https://huggingface.co/MoritzLaurer
- He, P. et al. (2021). DeBERTa: Decoding-enhanced BERT with Disentangled Attention.
  *ICLR 2021*.
