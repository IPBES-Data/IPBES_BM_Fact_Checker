# Design notes — what the 2026-10-05 reviewer pilot implies

Working document. Each point states the finding, the evidence behind it, a
proposed change, and what would settle it. Nothing here is decided.

## Which pipeline each point touches

| point | project | |
|---|---|---|
| 1. architecture vindicated | `factcheck` | Phase 1 → Phase 2 on citing works |
| 2. the judge | **both** | one `llm_verification` config serves `llm_verification_parquet` (factcheck) and `llm_verification_keypaper_parquet` (training); the consequences land in training |
| 3. hold the fine-tune | `training` | |
| 4. corpus-aware routing | `factcheck` | key papers are not routed at all, see the point |
| 5. refutations do exist | **both** | the instrument is training's; the finding is about the corpus |
| 6. NLI vs Jev as REFUTES filter | `factcheck` | with a knock-on for what training distils |
| 7. would training the NLI fix it | `training` | |

**Points 2, 3 and 5 are the training cycle, and they form a closed loop:** the
judge produces labels, `nli_training_data` distils them, `nli_finetuned_model`
learns them, and `nli_benchmark_qa_data` scores the result against the same
judge's labels under `reference = "llm"`. Nothing inside that loop can detect
an error in the judge — which is what `reference = "human"` and the
`goldstandard` gate exist for, and why the gate standing open on synthetic data
is the live problem rather than a formality.

Points 1, 4 and 6 are the fact-checking arm, where the judge's verdicts are the
product rather than training material.

**Points 5, 6 and 7 were added on 2026-10-05 and two of them overturn earlier
conclusions in this file.** Point 5 replaces a claim that the corpus might hold
no refutations; it does hold them. Point 6 upgrades "the NLI is a weak filter"
to "as a REFUTES filter it selects a population depleted of refutations".

## Where the evidence comes from

Three measurements made on 2026-10-02 and 2026-10-05, all on GA1:

1. **KM C. scored against the fine-tuned model** (`nli_config=bge_m3_ft_ga1`,
   38 claims, 2,307,101 pairs, 2h54m on 5 L4 pods, ~$6). It labelled **32.1%**
   of the corpus REFUTES, against a zero-shot rate of 0.2–3%.
2. **The 200-row gold-standard instrument run past 11 LLM reviewers** plus the
   zero-shot NLI's own verdicts (`input/ai_goldstandard/`, $4.69,
   `AI_REVIEWER_COMPARISON.md`). Ten chat models from seven labs, none from
   OpenAI except the judge itself, plus Jev — a decision model sharing no
   architecture with the others.
3. **The Jev relevance screen** on 170,405 routed pairs ($2.19), whose
   P(addresses) medians put REFUTES nearer NOT_ENOUGH_INFO than SUPPORTS.

Two caveats apply to all of it and are not repeated below. The 200 rows are
**stratified on the LLM's own label**, so they are a deliberately skewed slice
and none of these are corpus-level rates. And every "reviewer" is a model —
this is models judging models, which is exactly what the gold standard exists
to replace.

---

## 1. The two-phase architecture is vindicated — do not change it

**Finding.** Phase 1's precision at the operating point the pipeline routes on,
judged by the 11 reviewers' majority:

| NLI said | n | confirmed |
|---|---:|---:|
| SUPPORTS certain, citing works | 90 | 18.9% |
| SUPPORTS certain, key papers | 18 | 77.8% |
| REFUTES certain | 25 | **0.0%** |

**Why this is not a problem.** `TD_NLI_LLM_two_phase.qmd` never claimed Phase 1
was a classifier: cheap wide net, expensive grounded check. 18.9% precision on a
recall filter is what that design predicts. Phase 2 is doing the work it exists
to do.

**Change proposed:** none.

---

## 2. The single point of failure is the judge, not the NLI

**Finding.** `gpt-4o-mini`, whose verdicts every NLI model here is distilled
from, reproduces only **53.1% of its own Phase 2 calls** when given the reviewer
instrument (Cohen's kappa 0.357 *against itself*). It called 16 of the 200 rows
REFUTES where it originally called 100.

Every other reviewer agrees with it at kappa 0.11–0.23 while agreeing with
**each other** at 0.30–0.68. They are not noisy; they converge somewhere else.
Of the 100 rows it called REFUTES, the majority verdict was NOT_ENOUGH_INFO 53,
SUPPORTS 40, REFUTES 3. **No row was called REFUTES by all eleven.** Jev, which
shares no architecture with the chat models, independently finds 3.

This is the structural problem: the training set, the fine-tune, and the
benchmark's notion of truth all derive from one unstable judge, and nothing
downstream can correct it. The design anticipated this — `goldstandard` is a
hard gate on `nli_finetuned_model` and `nli_benchmark_qa_data` — but the gate is
currently held open by synthetic data, so the circularity is live.

**Change proposed: an ensemble judge.** Three cheap models from different labs,
majority vote, replacing the single `openrouter_cheap` config. Scaled from
measured per-row cost to all of GA1 under zero-shot routing (78,922 pairs):

| model | all GA1 |
|---|---:|
| `qwen/qwen3-235b-a22b-2507` | $5 |
| `openai/gpt-4o-mini` | $8 |
| `google/gemini-2.5-flash` | $43 |
| **three-model majority** | **~$56** |

`llm_verification:` is already a library of named configs, so this is additive —
a new config beside the existing three, not a redesign. The output path is
partitioned by `llm_config=`, so an ensemble run cannot overwrite what the
single judge produced.

**What would settle it.** Whether the ensemble's majority tracks human labels
better than the single judge does, measured on the same 200 rows once the
reviewers report.

---

## 3. Hold the fine-tune

**Finding.** `nli_training_data`'s REFUTES class is 542 rows (18.9% of the
training set), included unconditionally on the LLM's call alone — deliberately,
so that "NLI was wrong, LLM corrected it" cases are not excluded. Those are the
verdicts the pilot rejects at 97%.

The model trained on them carries that prior into deployment: 18.9% in training,
**18.9% of KM C. routed as REFUTES-certain**, against a corpus rate of 0.2–3%.
The prior shows through to the decimal.

Raising `uncertain_threshold` from 0.60 to 0.90 would cut the routed set from
436,898 to 58,080 (2.5%, about the rate the corpus suggests) — but that thins
the output without changing what the model learned.

**Change proposed.** Set `training.finetune.enabled: false` until the labels are
validated. It is currently `true`, so a bare `tar_make()` in the training
project starts a multi-hour CPU run that re-encodes the judge's errors.

**What would settle it.** Human adjudication of the 100 REFUTES-stratum rows. If
a meaningful fraction are real, the class is sound and the prior is a
calibration problem. If almost none are, the class needs rebuilding.

---

## 4. Routing should probably be corpus-aware

**Finding.** Phase 1 is reasonable on key papers and poor on citing works
(77.8% vs 18.9%), but one `uncertain_threshold: 0.60` governs both.

The reason is not topicality — citing works were *discovered* by following the
citation graph out from the key papers, so topical relatedness is what put them
in the corpus at all. What differs is whether the paper reports the finding the
claim generalises: a key paper was chosen by the assessment authors *as the
evidence for that BM*, while a citing work inherits the topic without inheriting
the evidence.

The NLI barely registers that distinction. Corpus-wide, nothing pre-selected:

| corpus | n | SUPPORTS | median p_supports |
|---|---:|---:|---:|
| citing works | 2,429,848 | 35.9% | 0.332 |
| key papers | 29,511 | 45.3% | 0.369 |

It separates the two corpora by **9.4 points** where the reviewers separate them
by **49**. It leans the right way at about a fifth of the strength the truth
does — consistent with reading topical and lexical compatibility, which both
corpora have in abundance, rather than the presence of a finding.

A plausible mechanism, unconfirmed: a BM claim is a *generalisation* synthesised
from its key papers. A key paper reports particulars — a number, a taxon, a
region — so its abstract sits lexically further from the generalised claim even
while genuinely supporting it. Citing works, being downstream discussion, restate
the field's general framing in language much closer to the claim. Generalised
prose scores well against a generalised hypothesis whether or not it reports
anything. If right, this also explains the Jev finding (verbatim quotes that are
topically adjacent but do not bear on the claim).

**Change proposed — and note what it is *not*.** There is no second threshold to
set: `build_llm_verification_keypaper_parquet.R` passes `nli_labels = NULL,
nli_certainty = NULL`, so key papers are **not routed at all** — every one is
reviewed regardless of what Phase 1 said. The asymmetry already exists and is
deliberate.

So the finding bears on the citing-works arm alone, in two ways:

- **Routing (fact checking).** The routed set is exactly the population where
  Phase 1 is weakest. Raising `uncertain_threshold` thins it but does not make
  the survivors better, since confidence within citing works carries no usable
  signal (Spearman rho = −0.15, p = 0.16, n = 90). If the routed set needs
  narrowing, the lever with evidence behind it is the Jev relevance screen,
  which is already built, already scores without filtering, and is the one
  measurement that separates "about this topic" from "bears on this claim".
- **Training weight (training).** A key paper confirmed at 77.8% and a citing
  work at 18.9% are not equally reliable sources of a training label.
  `nli_training` already partitions on `keypaper` so `train_nli.py`'s `FILTERS`
  can prune to the seed tier — which is the existing mechanism for acting on
  this, currently unused.

**What would settle it.** Whether the 77.8% / 18.9% gap holds against human
labels. If it does, training on `keypaper=TRUE` alone is worth measuring against
training on both.

---

## 5. Refutations DO exist — the near-zero rate was the instrument

**This supersedes an earlier version of this point, which said the headline
metric may be unmeasurable because the corpus might hold no refutations. It
does hold them.**

Three enrichment attempts all came up near-empty — the judge's own label, the
NLI's `p_refutes`, and Jev's contradiction ranking — each yielding 1–3 REFUTES
per 200 rows. That looked like a finding about the corpus. It was not.

A third run (`scripts/run_refutes_probe.R`, `input/ai_refutes_probe/`) took the
**179 triple-positive rows** — judge said REFUTES *and* NLI said REFUTES *and*
`quote_is_verbatim()` confirmed the cited sentence — and changed the question:
permissive about partial and scope-limited contradictions, and showing each
model the sentence the judge had cited, asking whether it genuinely contradicts.

| agreement among 3 independent models | rows |
|---|---:|
| all 3 confirm | **18 (10%)** |
| ≥2 of 3 confirm | **48 (27%)** |
| none confirm | 99 (55%) |

Even across corpora: 26.2% of citing works, 27.6% of key papers. Against 1–3 per
200 under the four-way instrument, that is a 20–50x difference on the same
underlying question.

**Three causes, all fixable before the human round:**

1. **The instrument never shows the quote.** Reviewers see title + abstract and
   must rediscover the contradiction unaided, discarding the sentence Phase 2
   already found and verified.
2. **`REVIEWER_GUIDE.md` makes NEI the safe default** and rules on nothing about
   partial or scope-limited contradictions, so they land there.
3. **The REFUTES stratum was drawn from the wrong population** — all 568 of the
   judge's REFUTES verdicts, including the 303 where the NLI disagreed. The
   triple-positives are 181 rows and are where the real ones concentrate.

**Change proposed.** Show the quote; rule explicitly on partial contradictions;
draw the REFUTES stratum from triple-positives. All three before the reviewers
start, or they reproduce the artefact.

**Caveats.** Showing a sentence labelled "cited as evidence of contradiction"
anchors the judgement, and the prompt asked for permissiveness — both push
toward yes, so 27% is an upper bound and the 10% unanimous figure is firmer.
Still models, not humans. And `gpt-4o-mini` is internally incoherent here,
affirming `contradicts_any` on 172/179 while endorsing its own quote on 54/179.

**What survives of the metric concern.** SUPPORTS→REFUTES recovery is still
measured on a stratum built the old way, so it needs rebuilding — but it has a
population after all.

---

## 6. The NLI is counterproductive as a REFUTES filter; Jev is not

**Finding A — within the NLI's own positives, it cannot rank.** Scored against
the probe's confirmed refutations, on rows where both signals already said
REFUTES:

| target | NLI `p_refutes` | Jev `p_contradicts` |
|---|---:|---:|
| confirmed by ≥2 of 3 (48/179) | 0.529 [0.40, 0.66] | **0.737 [0.63, 0.84]** |
| unanimous (18/179) | 0.349 [0.15, 0.57] | **0.789 [0.64, 0.93]** |

(AUC, bootstrap 95% CI, n=103 where both are scored. Across all 179 the NLI
scores 0.503 and 0.422 — chance and below.) Jev is handicapped in this
comparison: the probe's judges saw the cited quote, Jev never did.

**Finding B — the NLI points at the wrong population entirely.**
`scripts/jev_recall_probe.R` screened 18,577 pairs the NLI did **not** call
REFUTES, with the identical question ($0.28):

| NLI said | n screened | rate ≥0.7 | corpus n | expected candidates |
|---|---:|---:|---:|---:|
| SUPPORTS, uncertain | 4,616 | **0.693%** | 688,534 | 4,772 |
| NOT_ENOUGH_INFO, certain | 4,784 | **0.460%** | 381,265 | 1,754 |
| NOT_ENOUGH_INFO, uncertain | 4,766 | 0.168% | 850,762 | 1,429 |
| SUPPORTS, certain | 4,411 | 0.045% | 183,972 | 83 |
| **REFUTES (the routed label)** | 67,588 | **0.058%** | 325,315 | **189** |

The population the pipeline routes has **among the lowest** rate of
Jev-flagged contradictions — 12x below `SUPPORTS-uncertain` and 8x below
`NEI-certain`. **97.7% of the high-confidence candidates lie outside the NLI's
REFUTES label**, in the 92% of the corpus Phase 2 never sees. At the probe's
measured confirmation rate this implies roughly **2,200 real refutations in
GA1**, against the ~50 the current architecture can reach.

So the NLI is not a weak REFUTES filter. As a REFUTES filter it is worse than
not filtering: it selects an 8% slice that is *depleted* of the thing being
looked for.

**Change proposed.** Use Jev's contradiction question as the first stage for the
REFUTES arm — one question over all 2,429,848 GA1 pairs is **~$42**, against the
NLI's ~$8 of GPU. Keep the NLI for SUPPORTS if it is wanted there (its AUC is
0.38, so that too is open).

**Caveats.** These are Jev *scores*, not confirmed refutations; the 27%
confirmation rate comes from the triple-positive pool and may not transfer. The
"truth" is three LLMs and Jev is a language model, so the comparison is not
neutral between it and the NLI. And a 0.7 cutoff is uncalibrated — on the first
instrument the best-fitting Jev cutoff was 0.70, but fitted on the data it was
evaluated against.

**What would settle it.** The human round, on a REFUTES stratum rebuilt per
point 5. The probe rows already carry both scores, so that recomputation is free.

---

## 7. Would training the NLI fix it?

Open, and one pod away. Only **6 of the 179** probe rows carry a fine-tuned
score, so the fine-tune has never been evaluated against confirmed refutations.
Scoring the other 173 is seconds of inference.

Three reasons to expect little, the first two solid:

1. **Size.** A human round yields ~150–200 adjudicated rows, perhaps 20–50
   REFUTES. The existing fine-tune had **542** and produced a model with a 19%
   prior on a ~2% corpus.
2. **The failure looks representational, not label-driven.** The NLI separates
   key papers from citing works by 9 points where truth separates them by 49,
   and its `p_refutes` carries no information about which of its own confident
   refutations hold up. That is an encoder reading topical compatibility, not a
   classifier with bad labels. *(Inference, not measurement.)*
3. **Opportunity cost.** `train_nli.py`, `build_nli_finetuned_model.R`, the
   benchmark scorer, three QA reports, 42 GB of checkpoints and 5+ hour runs,
   against $42 and an HTTP call.

**The one scenario where the training arm still earns its place:** distilling
**Jev** into a local model once it has labelled a few hundred thousand pairs.
That inverts the economics at corpus scale, reuses the whole existing training
chain for a teacher that demonstrably works, and needs no human labels to start
— the human round would then validate the student rather than supply its
training data.

## Sequencing

The two points that changed today (5 and 6) both argue for acting **before** the
human round rather than after it, because both concern the instrument the
reviewers will use:

1. **Rebuild the REFUTES stratum and the guide** (point 5). The current
   instrument demonstrably suppresses the thing it exists to find.
2. **Do not run the fine-tune** (point 3). Unchanged, and now stronger: point 6
   says the signal it was trained to improve points at the wrong population.
3. **Everything else waits for human labels.** Points 6 and 7 both reduce to
   recomputations against data already on disk once those exist.

## Open question not covered above

The zero-shot NLI's kappa against **every** LLM reviewer is negative (−0.02 to
−0.13), and against `gpt-4o-mini` 0.059. On this sample the two stages are not
imperfectly aligned, they are unrelated. Negative kappa means structured
disagreement, not noise: the largest single cell in the claude-sonnet
cross-tabulation is 88 papers the NLI calls SUPPORTS and the reviewer calls
NOT_ENOUGH_INFO. Whether that survives outside this skewed sample is untested,
and it is the thing most worth testing next.
