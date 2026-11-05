# LLM reviewers vs the gpt-4o-mini labels — GA1 gold-standard sample

Generated 2026-10-05 by `scripts/ai_reviewer_report.R`. 
**Not a gold standard** — see `NOT_A_GOLD_STANDARD.md` beside this file.

200 rows, 12 reviewers.

## The sample

200 rows drawn from the `holdout` fold by `build_goldstandard_sample()`,
stratified on **the LLM's own label** with REFUTES over-sampled:

| gpt-4o-mini said | n | share of sample |
|---|---:|---:|
| NOT_ENOUGH_INFO | 50 | 25.0% |
| REFUTES | 100 | 50.0% |
| SUPPORTS | 50 | 25.0% |

## What each reviewer said

| reviewer | SUPPORTS | REFUTES | NEI | CANNOT_JUDGE | unparsed | cost (200 rows) |
|---|---:|---:|---:|---:|---:|---:|
| `claude-haiku-4.5` | 113 | **4** | 79 | 4 | 0 | $0.438 |
| `claude-sonnet-4.6` | 75 | **1** | 118 | 6 | 0 | $1.294 |
| `deepseek-v4-pro` | 53 | **2** | 143 | 2 | 0 | $0.096 |
| `gemini-2.5-flash` | 57 | **3** | 135 | 5 | 0 | $0.110 |
| `gemini-2.5-pro` | 82 | **1** | 105 | 8 | 4 | $2.811 |
| `gpt-4o-mini` | 87 | **16** | 93 | 4 | 0 | $0.020 |
| `gpt-5-mini` | 38 | **4** | 153 | 5 | 0 | $0.249 |
| `jev-1.13` | 91 | **3** | 106 | 0 | 0 | $0.007 |
| `llama-4-maverick` | 137 | **6** | 54 | 3 | 0 | $0.021 |
| `mistral-medium-3` | 60 | **3** | 127 | 10 | 0 | $0.076 |
| `nli-zeroshot` | 137 | **39** | 24 | 0 | 0 | — |
| `qwen3-235b` | 69 | **3** | 123 | 5 | 0 | $0.013 |

## Agreement with gpt-4o-mini (the judge whose labels the training set carries)

| reviewer | n | agreement | Cohen's kappa |
|---|---:|---:|---:|
| `claude-haiku-4.5` | 196 | 40.8% | 0.205 |
| `claude-sonnet-4.6` | 194 | 40.2% | 0.200 |
| `deepseek-v4-pro` | 198 | 35.9% | 0.143 |
| `gemini-2.5-flash` | 195 | 40.5% | 0.204 |
| `gemini-2.5-pro` | 188 | 36.7% | 0.156 |
| `gpt-4o-mini` | 196 | 53.1% | 0.357 |
| `gpt-5-mini` | 195 | 33.3% | 0.109 |
| `jev-1.13` | 200 | 42.0% | 0.223 |
| `llama-4-maverick` | 197 | 42.6% | 0.225 |
| `mistral-medium-3` | 190 | 40.5% | 0.200 |
| `nli-zeroshot` | 200 | 34.0% | 0.059 |
| `qwen3-235b` | 195 | 39.0% | 0.182 |

## Agreement with the zero-shot NLI model

| reviewer | n | agreement | Cohen's kappa |
|---|---:|---:|---:|
| `claude-haiku-4.5` | 196 | 39.8% | -0.090 |
| `claude-sonnet-4.6` | 194 | 27.3% | -0.103 |
| `deepseek-v4-pro` | 198 | 22.2% | -0.068 |
| `gemini-2.5-flash` | 195 | 24.1% | -0.063 |
| `gemini-2.5-pro` | 188 | 32.4% | -0.063 |
| `gpt-4o-mini` | 196 | 29.6% | -0.128 |
| `gpt-5-mini` | 195 | 21.5% | -0.018 |
| `jev-1.13` | 200 | 34.0% | -0.061 |
| `llama-4-maverick` | 197 | 46.2% | -0.119 |
| `mistral-medium-3` | 190 | 26.3% | -0.063 |
| `qwen3-235b` | 195 | 29.2% | -0.049 |

For reference, gpt-4o-mini vs the zero-shot NLI on the same rows: 34.0% agreement, kappa 0.059.

## Reviewers against each other

Cohen's kappa, lower triangle:

| | `claude-haiku-4.5` | `claude-sonnet-4.6` | `deepseek-v4-pro` | `gemini-2.5-flash` | `gemini-2.5-pro` | `gpt-4o-mini` | `gpt-5-mini` | `jev-1.13` | `llama-4-maverick` | `mistral-medium-3` | `nli-zeroshot` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `claude-sonnet-4.6` | 0.51 |  |  |  |  |  |  |  |  |  |  |
| `deepseek-v4-pro` | 0.34 | 0.43 |  |  |  |  |  |  |  |  |  |
| `gemini-2.5-flash` | 0.37 | 0.62 | 0.42 |  |  |  |  |  |  |  |  |
| `gemini-2.5-pro` | 0.49 | 0.53 | 0.48 | 0.41 |  |  |  |  |  |  |  |
| `gpt-4o-mini` | 0.47 | 0.37 | 0.21 | 0.41 | 0.29 |  |  |  |  |  |  |
| `gpt-5-mini` | 0.28 | 0.42 | 0.38 | 0.38 | 0.33 | 0.15 |  |  |  |  |  |
| `jev-1.13` | 0.60 | 0.59 | 0.40 | 0.48 | 0.46 | 0.41 | 0.33 |  |  |  |  |
| `llama-4-maverick` | 0.51 | 0.30 | 0.21 | 0.20 | 0.27 | 0.42 | 0.14 | 0.37 |  |  |  |
| `mistral-medium-3` | 0.47 | 0.63 | 0.43 | 0.68 | 0.39 | 0.44 | 0.32 | 0.49 | 0.26 |  |  |
| `nli-zeroshot` | -0.09 | -0.10 | -0.07 | -0.06 | -0.06 | -0.13 | -0.02 | -0.06 | -0.12 | -0.06 |  |
| `qwen3-235b` | 0.54 | 0.62 | 0.50 | 0.58 | 0.55 | 0.33 | 0.44 | 0.47 | 0.33 | 0.62 | -0.05 |

## The REFUTES question

Of the **100** rows gpt-4o-mini called REFUTES, the reviewers' majority verdict was:

| majority verdict | n |
|---|---:|
| SUPPORTS | 31 |
| REFUTES | 2 |
| NOT_ENOUGH_INFO | 48 |

REFUTES count per reviewer, out of 200 rows: `claude-haiku-4.5` 4, `claude-sonnet-4.6` 1, `deepseek-v4-pro` 2, `gemini-2.5-flash` 3, `gemini-2.5-pro` 1, `gpt-4o-mini` 16, `gpt-5-mini` 4, `jev-1.13` 3, `llama-4-maverick` 6, `mistral-medium-3` 3, `nli-zeroshot` 39, `qwen3-235b` 3.
Rows where **every** reviewer said REFUTES: **0**.

## Cost to run a reviewer over all of GA1

Measured per-row cost from this run, scaled to two corpus sizes.

- **Zero-shot routing** — 78,922 pairs, the REFUTES+SUPPORTS-certain set for all five KMs
  under `bge_m3_zeroshot_atomic_bm` (measured, recorded in `config.yaml`).
- **Fine-tune routing** — ~6,140,000 pairs, scaling KM C's measured 787,215 routed of
  2,307,101 scored across GA1's 18,010,940. The 78x gap IS the calibration problem:
  the fine-tune routes 18.9% of the corpus where the zero-shot model routes 0.4%.

| reviewer | $/row | all GA1, zero-shot routing | all GA1, fine-tune routing |
|---|---:|---:|---:|
| `claude-haiku-4.5` | $0.00219 | $173 | $13,454 |
| `claude-sonnet-4.6` | $0.00647 | $511 | $39,730 |
| `deepseek-v4-pro` | $0.00048 | $38 | $2,941 |
| `gemini-2.5-flash` | $0.00055 | $43 | $3,366 |
| `gemini-2.5-pro` | $0.01405 | $1,109 | $86,294 |
| `gpt-4o-mini` | $0.00010 | $8 | $629 |
| `gpt-5-mini` | $0.00124 | $98 | $7,641 |
| `jev-1.13` | $0.00004 | $3 | $220 |
| `llama-4-maverick` | $0.00011 | $8 | $659 |
| `mistral-medium-3` | $0.00038 | $30 | $2,326 |
| `qwen3-235b` | $0.00007 | $5 | $407 |

Add OpenRouter's 5.5% credit fee. Phase 2 also caches per pair, so a re-run after
an unrelated change costs nothing.
