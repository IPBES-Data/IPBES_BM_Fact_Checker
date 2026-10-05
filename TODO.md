# TODOs

Reorganised 2026-10-05, on branch `Jev`, after the training project was retired.
Items the retirement made moot are listed under *Closed by the redirection*
rather than deleted, so it is clear they were considered rather than forgotten.

The reasoning behind the redirection is in `design_notes.md`; the state before it
is the `NLI_dirty` branch.

---

## 1. Before the human review round — the only deadline here

The reviews are being collected "beginning of next week" (said 2026-10-05). All
three of these change the instrument the reviewers use, so they have to land
first or the round measures the wrong thing.

- [ ] **Rebuild the REFUTES stratum from triple-positives.** The drawn sample
  took all 568 of the judge's REFUTES verdicts, including the 303 where the NLI
  disagreed. The 181 rows where judge + NLI + verbatim quote all agree are where
  real refutations concentrate: 27% confirmed by ≥2 of 3 independent models,
  against 1–3 per 200 in the current instrument. `design_notes.md` point 5.
- [ ] **Show the cited quote in the instrument.** Reviewers currently see only
  title + abstract and must rediscover the contradiction unaided, discarding the
  sentence Phase 2 already found and verified. This is the single largest cause
  of the near-zero REFUTES rate.
- [ ] **Rule on partial contradictions in `REVIEWER_GUIDE.md`.** It makes
  `NOT_ENOUGH_INFO` the safe default and says nothing about a result that
  contradicts in one region, taxon, time period or scale. Eleven models all
  defaulted to NEI; two humans will too. Also settle the SUPPORTS/NEI boundary —
  41 of 52 model disagreements sat exactly there.

## 2. Open from the Jev redirection

- [ ] **Score the 179 probe rows with the fine-tuned model.** Only 6 of 179
  carry a `bge_m3_ft_ga1` score, so the question "did the fine-tune inherit the
  judge's REFUTES errors?" is unanswered. Seconds of inference; the cost is one
  pod. Closes `design_notes.md` point 7 with a measurement instead of an
  argument.
- [ ] **Three-question Jev into the existing schema.** Ask supports /
  contradicts / bears-on-the-claim per pair and cross-normalise — structurally
  identical to what `passes: 3` already does for the zero-shot head, so
  `(p_supports, p_refutes, p_nei)` comes out unchanged and `uncertain_threshold`,
  the `nli_route=` partitions and the funnel sieve all keep working. Write it
  under its own `nli_config=` name so it sits beside the NLI on identical rows
  and overwrites nothing. ~$120 for all of GA1.
- [ ] **A gold-standard QA report.** Asked for on 2026-10-05 and not built: κ,
  the R1↔R2 ceiling, adjudication counts and the CANNOT_JUDGE split exist only
  as `build_goldstandard()` console output. New work, not a move.
- [ ] **Repoint or retire `_QA_NLI_Benchmark_Report.qmd`.** Parked
  (underscore-prefixed, so Quarto skips it). Its metrics are still wanted —
  κ against human labels, bootstrap CIs, inverse-probability weighting — but its
  subject is gone. Repointing means `build_nli_benchmark_metrics()` reads the
  `nli_config=` score trees instead of `output/nli_training_finetuned/*/best`
  (now in `deep_archive/`), turning the comparison into "which first-stage model
  ranks the gold rows best". Note its `training_data_path` also points at
  `output/nli_training/`, which moved to `deep_archive/`.
- [ ] **Finish the self-hostable filter comparison.** Cancelled 2026-10-05 after
  `gemma-3-12b` failed 26 of 39 attempts — any AUC from it would have been
  computed on a biased surviving subset. `llama-3.1-8b` completed: AUC 0.648
  [0.56, 0.73] against Jev's 0.737 and the NLI's 0.503. Generic instruct models
  asked for a probability via structured output are a poor fit; the better
  candidates are purpose-built fact-verification cross-encoders (MiniCheck,
  VitaminC, Vectara HHEM) — small, deterministic, no parsing failures, native
  score, and **three-way** so they drop straight into the existing schema. None
  are on OpenRouter, so this needs a pod and the existing `nli-runpod` serving
  code, which is also how they would really be deployed.
- [ ] **Update `TD_NLI_LLM_two_phase.qmd` if Phase 1 changes.** It has no stale
  references today — every target it names exists — but it describes Phase 1 as
  the NLI throughout. Premature while that is still a proposal.
- [ ] **Decide the relevance screen's future, after the first Jev run.**
  Left in deliberately ($0.65, 2% of the run) so the redundancy test gets the
  population it needs — pairs Jev itself routes. Today's test used pairs the
  fine-tune routed: Spearman 0.781, 95.4% agreement on keep/drop, but only 76
  Jev-routed pairs in the sample. `design_notes.md` point 9.

- [ ] **An ensemble judge for Phase 2.** Independent of everything above and
  unaffected by it: `gpt-4o-mini` reproduces only 53% of its own verdicts.
  Three cheap models from different labs, majority vote, ≈ $56 for all of GA1
  under zero-shot routing. `llm_verification:` is already a library of named
  configs, so this is a new config beside the existing three.
  `design_notes.md` point 2.

## 3. Fact-checking pipeline — standing

- [ ] **Finish GA1 beyond KM C.** KM C. is scored under `bge_m3_ft_ga1`
  (38 claims, 2,307,101 pairs, 2h54m on 5 L4 pods, ~$6). A., B. and D. are not:
  9.9M + 2.8M + 3.0M pairs, ~$20 of GPU at the measured 55 pairs/s/pod. Do not
  start before the redirection question is settled — scoring 15.7M more pairs
  with a model measured at chance is the expensive version of being wrong.
- [ ] **Phase 2 for GA1**, separately and deliberately —
  `llm_verification_parquet` spends real OpenRouter money and is not reached by
  the `nli_scores_evidence_consolidated` stop point.
- [ ] **Decide what happens to ~151 GB of unmaintained `nli_ready_evidence`.**
  `fact_checking` is scoped to `[GA1]`, so VA, IAS, BBA and TCA's `atomic_bm`
  cross-joins (61 + 46 + 39 + 5.6 GB) are rebuilt by no project and deleted by
  nothing. Their *scored* output is small and unaffected, and reporting still
  renders it. The single largest reclaim in `output/`.
- [ ] **The zero-shot backfill has never been run.** `score_one_claim()`'s delta
  fix means the next `tar_make()` of `nli_scores_by_claim_evidence` picks up
  every missing work: ~167M pairs for the three unscored assessments, plus the
  GA1/IAS delta. Scope it deliberately rather than letting a bare `tar_make()`
  fan out. Largely overtaken by the redirection, but the data is still missing.
- [ ] **Re-enable or retire the two "Overlap of Papers after 2018" tables.**
  Disabled 2026-09-18 after `build_overlap_after_2018_background_messages_table()`
  crashed the machine: it collects doi/title/**abstract** for every post-2018
  `(work × km × bm)` row *before* deduplicating — 25,717,725 rows, ~39 GB in one
  `collect()`. The performance fix is straightforward (count BM-groups lazily in
  Arrow, filter `n > 5`, fetch metadata for survivors only), but three content
  questions come first: the two committed rds files disagree (6,727 vs 805,028
  rows) although CLAUDE.md records that they group identically; an 805k-row DT
  widget carrying abstracts in a 500px iframe is not browsable; and `n > 5` was
  chosen when the corpus was a fraction of today's size.
- [ ] **Content-hash-aware invalidation across the OpenAlex chain.** Two gaps,
  both found by discussion rather than incident: nothing detects that OpenAlex's
  own data changed server-side (a cleaned-up or newly-available abstract), and
  even if fresh premise text reached `nli_ready_evidence_parquet`,
  `score_one_claim()` resumes per *work* but never compares premise *content*,
  so a changed abstract is silently kept at its old score. Today the only way to
  pick up such an update is deleting `output/nli_scores_evidence/` and
  re-running everything.
- [ ] **`granularity: complete_bm` has never been run for real.** Implemented
  and reported on, but needs a pod, a `complete_bm` config activated, and
  `uncertain_threshold`/label calibration re-verified against the actual score
  distribution (carried over from `deberta_zeroshot` as an unverified starting
  point). Every `complete_bm` branch in the reporting layer is empty until then —
  expected, not a bug.
- [ ] Optional: replace truncation with abstract chunking for pairs where
  `approx_tokens > max_length`. These are **not** skipped today — the server
  truncates the abstract tail and scores them; chunking would be lossless. See
  NEXT_STEPS.md.
- [ ] Fix the `read_csv()` deprecation in SPARQL response parsing
  (`refs_parquet`, `key_messages_parquet`): wrap literal CSV strings in `I()`.
  readr 2.2.0+; becomes an error eventually.
- [ ] Low value, noted because it was asked: parallelise `nli_bm_explorer_html`
  (96.4 s across 15 branches). It runs on workers, unlike
  `nli_scores_qa_figures`, so a controller in `reporting` would help.
- [ ] Gaps: same pipeline, in CONF DATA (the one we have).

## 4. Closed by the redirection

Not done — no longer wanted. Kept so it is clear they were considered.

- ~~Fine-tune the NLI model using BM citations as training data.~~ The arm was
  built, run and retired: the model it improves is at or below chance at the job
  (AUC 0.50 REFUTES / 0.38 SUPPORTS), and 97.7% of contradiction candidates lie
  outside the label it routes on. `design_notes.md` points 3, 6, 7.
- ~~Use `llm_agrees = FALSE` rows as training data for NLI fine-tuning.~~ Same
  reason, and compounded: those rows are disagreements with a judge that
  reproduces only 53% of its own verdicts.
- ~~Curated test set, as a training artifact.~~ The gold standard survives and
  is now *more* load-bearing — it is the only thing that can test the
  redirection. But its purpose changed from "validate the training labels" to
  "validate the filter's candidates".
- ~~Merge phase: use `llm_label` where available, falling back to `nli_label`.~~
  Still unwired, and now questionable in a different way: if Phase 1 changes
  model, what `nli_label` means changes with it. Revisit after the human round.

## 5. Done

- [x] NLI scoring pipeline — SUPPORTS / REFUTES / NEI per citing work vs BM
- [x] Two-phase NLI → LLM pipeline, Phase 2 implemented
  (`llm_verification_parquet`), replacing the earlier truth/citing-document
  design — see [TD_LLM_approach.qmd](input/reports/TD_LLM_approach.qmd)
- [x] `score_one_claim()` dispatches the per-claim **delta**, not all-or-nothing.
  The old check skipped a claim entirely once it had any prior output, so every
  snowball re-run silently froze already-scored claims at first-run coverage.
  Measured before the fix: GA1 `A.`/`A2` `bm_description-05` held 28,825 scored
  works against 257,708 present.
- [x] Four-project split, then three: `training` retired 2026-10-05, its
  key-paper QA chain and gold standard moved into `factcheck`
- [x] Interactive per-BM NLI explorer (`nli_bm_explorer_html`)
- [x] Per-project workflow diagrams; `overview.mmd` rewritten 2026-10-05
- [x] Pod lifecycle wrappers (`scripts/runpod/start_nli_pods.sh` /
  `stop_nli_pods.sh`), with `-p/--purpose` and `expect_model` guards
- [x] KM scoping and named `fact_checking` configs
- [x] Jev recall probe — 18,577 pairs the NLI did *not* call REFUTES, screened
  for contradictions. Answered the question it was set: the routed population is
  depleted, not enriched.
- [x] Reviewer-instrument pilot across 11 models + Jev + the zero-shot NLI
  (`input/ai_goldstandard/`, `input/ai_goldstandard_refutes/`,
  `input/ai_refutes_probe/`)
- [x] Use OpenRouter + ellmer as the LLM backend
- [x] Per-assessment named graphs in Fuseki (one endpoint for all assessments)
