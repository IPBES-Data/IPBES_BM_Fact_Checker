# TODOs

## Active

- [ ] Optional: replace truncation with abstract chunking for long `(premise, claim)` pairs in `nli_scores_by_claim`/`nli_scores_by_claim_evidence` (pairs where `approx_tokens > max_length`): split long premises into overlapping windows, score each chunk, aggregate with `max(p_supports)`. Currently these pairs are NOT skipped — the server truncates the abstract tail and scores them (see `R/score_one_claim.R`); chunking would be a lossless alternative. See NEXT_STEPS.md for design.

- [ ] Fix `read_csv()` deprecation warning in SPARQL response parsing (`refs_parquet`, `key_messages_parquet`): wrap literal CSV strings in `I()` — readr 2.2.0+ deprecation, will become an error in a future version

- [ ] Gaps: Same pipeline, in CONF DATA (the one we have)
- [ ] Fine-tune NLI model using BM citations as training data — see [TD_NLI_training.qmd](TD_NLI_training.qmd)
- [ ] `score_one_claim()`'s resumability check (`dir.exists(claim_dir) && length(list.files(..., pattern = "\\.parquet$"))`) skips a claim entirely once it has ANY prior output, without checking whether the current candidate work-set for that claim still matches. If a later snowball re-run finds new citing works for an already-scored BM/claim (which happens naturally as new papers get published and cite the seed works), those new works are silently never NLI-scored — the claim is treated as done. Fixing this would mean diffing the claim's current work_id set against what's already scored and only dispatching the delta, rather than an all-or-nothing per-claim skip.

- [ ] **Consider the granularity of update/invalidation across the whole OpenAlex-sourced chain** (`works_parquet`/`snowball_parquet`/`works_citing_parquet` → `nli_ready_evidence_parquet` → `nli_scores_by_claim_evidence`), not just the new-works case above. Two related but distinct gaps, both found by discussion rather than by a real incident yet: (a) nothing in the pipeline detects that OpenAlex's own data changed server-side (e.g. a cleaned-up or newly-available abstract for a work already fetched) — `works_parquet`/`snowball_parquet` are plain `format = "file"` targets with no live-staleness check, so a re-fetch only happens if their output is deleted/forced outdated by hand; (b) even if fresh premise text did flow through to `nli_ready_evidence_parquet`, `score_one_claim()`'s per-claim (not per-work, not content-hash-based) resumability check would still skip any already-scored claim outright, silently keeping stale premise text for the changed work. Net effect today: there is no cheap, targeted way to pick up an OpenAlex-side data update — getting it to actually take effect means manually deleting `output/nli_scores_evidence/` (and cascading `output/llm_candidate_scope/`/`output/llm_verification/`) and re-running the full ~3.5M-pair NLI scoring job, real RunPod GPU cost included, not an incremental rescore of just the affected claims/works. Worth designing a real content-hash-aware invalidation (e.g. hash each claim's premise set and compare against what was used last time) before this comes up as a real need rather than a hypothetical one.

- [ ] `granularity: complete_bm` (NLI config option, `input/config.yaml`) and its `bge_m3_zeroshot` config are implemented but never run for real — needs (a) building/pushing `ghcr.io/rkrug/nli-runpod-bge-m3` (see `input/nli_pods_bge_m3.conf`), (b) provisioning at least one pod, (c) re-verifying `uncertain_threshold`/label calibration against the new model's actual score distribution (carried over from `deberta_zeroshot` as an unverified starting point), and (d) actually activating a `complete_bm` config and running `nli_scores_by_claim_evidence`/`llm_verification_parquet` against it. Real infrastructure/money decision, not automatic. See `TD_BM_NLI_approach.qmd` for the measured reduction numbers and the hypothesis-length/truncation caveat.
- [ ] The reporting layer (`nli_overview_data`, `nli_bm_explorer_html`, the label funnel reports) now renders one output per (assessment, granularity) combination, but every `complete_bm` branch is empty until the above actually runs — expected, not a bug, but worth remembering when `tar_outdated()`/`tar_make()` output looks like it doubled in target count after this change.

## Two-phase NLI → LLM pipeline

See [TD_NLI_LLM_two_phase.qmd](TD_NLI_LLM_two_phase.qmd) for full design.
Phase 2 (`llm_verification_parquet`) is implemented — remaining work is
downstream consumption:

- [ ] Run `llm_verification_parquet` against the new `SUPPORTS`+`certain` backlog (~52,061 pairs, ~$7.75 at `gpt-4o-mini` rates) added to `nli_labels` alongside the existing `REFUTES`+`certain` set — the `IPBES_SUPPORTS_Report_<id>.html` funnel reports render fine today but show an empty level 3 until this runs. Needs an explicit go-ahead, not automatic.
- [ ] **Safety note**: `report_fact_checker` now transitively depends on `llm_verification_parquet` (via the label funnel reports folded into its dependency list), so a plain `tar_make()`/`tar_make(report_fact_checker)` will attempt to rebuild it — and therefore spend real OpenRouter money — whenever `llm_verification_config` is outdated (e.g. right now, from the `SUPPORTS` addition). Use `tar_make(names = ..., shortcut = TRUE)` to render against on-disk Phase 2 data without triggering a fresh run. See `TD_NLI_LLM_two_phase.qmd`'s "Where this sits in the pipeline" section.
- [ ] Merge phase: use `llm_label` where available, fall back to `nli_label` — not yet wired into `nli_overview_data`/the report
- [ ] Human expert review of all `REFUTES` calls
- [ ] Use `llm_agrees = FALSE` rows as training data for NLI fine-tuning
- [ ] `input/mmd/workflow_nli.mmd` (hand-authored conceptual diagram) needs updating for the `nli_labels`/`nli_certainty`/`nli_route`/per-row-partitioning changes to the LLM verification stage — the diagram's Phase 2 subgraph still reflects the earlier, simpler `REFUTES | uncertain` routing shown when it was first added, not the configurable per-row routing implemented since. Deliberately deferred, not forgotten.

## Done

- [x] NLI scoring pipeline (`nli_scores_by_claim` / `nli_scores_by_claim_evidence`) — flags SUPPORTS / REFUTES / NEI per citing work vs BM
- [x] `truth` structured as JSON prompt with nested sub_messages and sources
- [x] Use openrouter + ellmer as LLM backend
- [x] Change local Fuseki server to per-assessment named graphs (one endpoint for all assessments)
- [x] Users: GA2 Ch 1 authors, IPBES, other assessments
- [x] one generation (CONF INTERPRET)
- [x] Interactive per-BM NLI explorer widget in the report (`nli_bm_explorer_html`) — linked BM/confidence-threshold/label controls, stacked solid/hollow bars, drill-down table with clickable DOI links, and a CSV download button (up to 5,000 rows, tagged with Assessment + BM columns)
- [x] Wire the report (`IPBES_Fact_Checker.qmd`) and its rendered artifacts (BM explorer, overlap tables, TD design docs) into `_targets.R` (`report_fact_checker`, `qmd_fact_checker`, `td_doc_html`) so `tar_make()` builds and renders everything, and copy heavy standalone HTML into `IPBES_Fact_Checker_files/` so the report distributes as just that one file + one directory
- [x] Render the `TD_*.md` design documents as standalone styled HTML pages (`TD_<name>.qmd` wrappers + `td_doc_html` target), linked from the report's Methods section
- [x] Combine each `TD_<name>.qmd` wrapper and its `TD_<name>.md` prose back into one self-contained `.qmd` file per doc; drop the `td_doc_md` target and the `{{< include >}}` indirection accordingly
- [x] Implement Phase 2 LLM verification (`llm_verification_parquet`, `R/build_llm_verification_parquet.R`): routes NLI's `REFUTES`/`uncertain` pairs to `openai/gpt-4o-mini` via OpenRouter, architecture ported from the sibling `Categorisation_Literature` project's LLM epistemology classifier (resumable per-pair cache, verbatim-quote verification, retry + fail-loud on unparseable responses). Removed the superseded truth/citing-document LLM design it replaced (`R/build_prompts_truth_parquet.R`, `R/build_prompts_citing_parquet.R`, `R/build_alignement_scores_parquet.R`, `R/alignement_schema.R`, `R/build_alignement_parquet.R`, the `analysis:` config block) — see [TD_LLM_approach.qmd](TD_LLM_approach.qmd) for that record
