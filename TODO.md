# TODOs

## Active

- [ ] Optional: replace truncation with abstract chunking for long `(premise, claim)` pairs in `nli_scores_by_claim`/`nli_scores_by_claim_evidence` (pairs where `approx_tokens > max_length`): split long premises into overlapping windows, score each chunk, aggregate with `max(p_supports)`. Currently these pairs are NOT skipped — the server truncates the abstract tail and scores them (see `R/score_one_claim.R`); chunking would be a lossless alternative. See NEXT_STEPS.md for design.

- [ ] Fix `read_csv()` deprecation warning in SPARQL response parsing (`refs_parquet`, `key_messages_parquet`): wrap literal CSV strings in `I()` — readr 2.2.0+ deprecation, will become an error in a future version

- [ ] Gaps: Same pipeline, in CONF DATA (the one we have)
- [ ] Fine-tune NLI model using BM citations as training data — see [TD_NLI_training.md](TD_NLI_training.md)

## Two-phase NLI → LLM pipeline

See [TD_NLI_LLM_two_phase.md](TD_NLI_LLM_two_phase.md) for full design.

- [ ] Implement `llm_scores_parquet` target (Phase 2)
  - Route `REFUTES`, `uncertain`, and low-confidence `SUPPORTS` from `nli_scores_by_claim`/`nli_scores_by_claim_evidence` to LLM
  - Use NLI label + confidence as prior in LLM prompt
  - Structured output: `llm_label`, `llm_agrees`, `explanation`, `disagreement_reason`
  - Model config in `input/config.yaml` (separate from NLI config)
  - Cheaper model (`gpt-4o-mini`) for `uncertain`; stronger model (`gpt-4o`) for `REFUTES`
- [ ] Merge phase: use `llm_label` where available, fall back to `nli_label`
- [ ] Human expert review of all `REFUTES` calls
- [ ] Use `llm_agrees = FALSE` rows as training data for NLI fine-tuning

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
