# TODOs

## Active

- [ ] Handle skipped rows in `nli_scores_parquet` (pairs where `approx_tokens > max_length`): implement abstract chunking (split long premises into overlapping windows, score each chunk, aggregate with `max(p_supports)`). Currently these pairs are skipped and logged. See NEXT_STEPS.md for design.

- [ ] Fix `read_csv()` deprecation warning in SPARQL response parsing (`refs_parquet`, `key_messages_parquet`): wrap literal CSV strings in `I()` — readr 2.2.0+ deprecation, will become an error in a future version

- [ ] Gaps: Same pipeline, in CONF DATA (the one we have)
- [ ] Fine-tune NLI model using BM citations as training data — see [TD_NLI_training.md](TD_NLI_training.md)

## Two-phase NLI → LLM pipeline

See [TD_NLI_LLM_two_phase.md](TD_NLI_LLM_two_phase.md) for full design.

- [ ] Implement `llm_scores_parquet` target (Phase 2)
  - Route `REFUTES`, `uncertain`, and low-confidence `SUPPORTS` from `nli_scores_parquet` to LLM
  - Use NLI label + confidence as prior in LLM prompt
  - Structured output: `llm_label`, `llm_agrees`, `explanation`, `disagreement_reason`
  - Model config in `input/config.yaml` (separate from NLI config)
  - Cheaper model (`gpt-4o-mini`) for `uncertain`; stronger model (`gpt-4o`) for `REFUTES`
- [ ] Merge phase: use `llm_label` where available, fall back to `nli_label`
- [ ] Human expert review of all `REFUTES` calls
- [ ] Use `llm_agrees = FALSE` rows as training data for NLI fine-tuning

## Done

- [x] NLI scoring pipeline (`nli_scores_parquet`) — flags SUPPORTS / REFUTES / NEI per citing work vs BM
- [x] `truth` structured as JSON prompt with nested sub_messages and sources
- [x] Use openrouter + ellmer as LLM backend
- [x] Change local Fuseki server to per-assessment named graphs (one endpoint for all assessments)
- [x] Users: GA2 Ch 1 authors, IPBES, other assessments
- [x] one generation (CONF INTERPRET)
