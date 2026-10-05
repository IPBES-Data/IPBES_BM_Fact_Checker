# NOT A GOLD STANDARD

These files are LLM output, produced by scripts/run_ai_reviewers.R as a PILOT
of the reviewer instrument. They are not human labels and must never be
copied into input/goldstandard/ or used as the benchmark's `human` reference.

R/build_goldstandard.R exists precisely because a model that reproduced a
wrong judge perfectly would score perfectly. Every NLI model benchmarked here
was distilled from gpt-4o-mini's labels; scoring them against other LLMs'
labels measures agreement between language models, not accuracy.

What these ARE good for: checking whether REVIEWER_GUIDE.md is unambiguous
enough that independent readers converge, and a cheap prior on how rare
REFUTES really is, before two humans spend a week finding out.
