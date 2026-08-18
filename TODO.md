# TODOs

## Active

- [ ] Optional: replace truncation with abstract chunking for long `(premise, claim)` pairs in `nli_scores_by_claim`/`nli_scores_by_claim_evidence` (pairs where `approx_tokens > max_length`): split long premises into overlapping windows, score each chunk, aggregate with `max(p_supports)`. Currently these pairs are NOT skipped — the server truncates the abstract tail and scores them (see `R/score_one_claim.R`); chunking would be a lossless alternative. See NEXT_STEPS.md for design.

- [ ] Fix `read_csv()` deprecation warning in SPARQL response parsing (`refs_parquet`, `key_messages_parquet`): wrap literal CSV strings in `I()` — readr 2.2.0+ deprecation, will become an error in a future version

- [ ] Gaps: Same pipeline, in CONF DATA (the one we have)
- [ ] Fine-tune NLI model using BM citations as training data — see [TD_NLI_training.qmd](TD_NLI_training.qmd)
- [ ] `score_one_claim()`'s resumability check (`dir.exists(claim_dir) && length(list.files(..., pattern = "\\.parquet$"))`) skips a claim entirely once it has ANY prior output, without checking whether the current candidate work-set for that claim still matches. If a later snowball re-run finds new citing works for an already-scored BM/claim (which happens naturally as new papers get published and cite the seed works), those new works are silently never NLI-scored — the claim is treated as done. Fixing this would mean diffing the claim's current work_id set against what's already scored and only dispatching the delta, rather than an all-or-nothing per-claim skip.

## Two-phase NLI → LLM pipeline

See [TD_NLI_LLM_two_phase.qmd](TD_NLI_LLM_two_phase.qmd) for full design.
Phase 2 (`llm_verification_parquet`) is implemented — remaining work is
downstream consumption:

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
