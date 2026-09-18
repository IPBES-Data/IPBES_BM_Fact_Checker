# Knowledge Discovery for GA2 based on GA1

## Introduction

This repository is using the [Linked Open Data representation of the Global Asssessment 1](https://github.com/IPBES-Data/IPBES_LOD/blob/main/Global%20Assessment%201/README.md) to identify new knowledge / literature produced after GA1 (2018).

## Methods

We use snowballing to identify the literature. The key-papers are the publications which were used for the Backbround Mesages (BMs) as identified by the LOD representation of GA1.

## Building

The work is split across **four** [`targets`](https://books.ropensci.org/targets/)
projects, defined in `_targets.yaml`. Each has its own script and its own store,
so rendering a report can no longer reach a target that spends GPU time or API
credit:

| Project | Holds | Credentials |
|---|---|---|
| `main` | collection: LOD → refs → zotero → works → snowball → works_citing | `API_openalex` |
| `factcheck` | citing works → NLI (Phase 1) → LLM verification (Phase 2) | `API_openrouter` |
| `training` | key papers → NLI → LLM → training set → fine-tune | `API_openrouter` |
| `reporting` | everything that renders | **none** |

```r
targets::tar_make()                                    # main (the default project)

Sys.setenv(TAR_PROJECT = "factcheck"); targets::tar_make()
Sys.setenv(TAR_PROJECT = "training");  targets::tar_make()

# or address a project directly, without changing the environment:
targets::tar_make(script = "_targets_reporting.R", store = "_targets_reporting")
targets::tar_visnetwork()                              # dependency graph of the current project
```

Which named configuration each project uses — and which assessments it covers —
comes from a **purpose block** in `input/config.yaml` (`fact_checking:`,
`training:`), not from a global `active:` setting.

Two cautions worth knowing before a first run:

- The scoring projects need a live NLI pod for their pool health check, even for
  a pass that will skip every claim.
- `factcheck`'s first run rebuilds its claim × premise cross-join from scratch.

See [CLAUDE.md](CLAUDE.md) for build system details (credentials, system
dependencies) and the full pipeline architecture, and
[TODO_PIPELINE_SPLIT.md](TODO_PIPELINE_SPLIT.md) for why the split is shaped
this way.

## Reports

- [`IPBES_Fact_Checker.html`](IPBES_Fact_Checker.html) — the main fact-checker report (built by `report_fact_checker` in the **reporting** project: `targets::tar_make(names = "report", script = "_targets_reporting.R", store = "_targets_reporting")`)
- [`TD_targets.html`](TD_targets.html) — the `targets` pipeline architecture design doc (rendered from [TD_targets.qmd](TD_targets.qmd))
