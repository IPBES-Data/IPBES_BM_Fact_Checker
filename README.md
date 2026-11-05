# Knowledge Discovery for GA2 based on GA1

## Introduction

This repository is using the [Linked Open Data representation of the Global Asssessment 1](https://github.com/IPBES-Data/IPBES_LOD/blob/main/Global%20Assessment%201/README.md) to identify new knowledge / literature produced after GA1 (2018).

## Methods

We use snowballing to identify the literature. The key-papers are the publications which were used for the Backbround Mesages (BMs) as identified by the LOD representation of GA1.

## Building

The work is split across **three** [`targets`](https://books.ropensci.org/targets/)
projects, defined in `_targets.yaml`. Each has its own script and its own store,
so rendering a report can no longer reach a target that spends API credit:

| Project | Holds | Credentials |
|---|---|---|
| `collection` | LOD → refs → zotero → works → snowball → works_citing | `API_openalex` |
| `factcheck` | Phase 1 (Jev) → relevance screen → Phase 2 (LLM verification) | `API_openrouter` |
| `reporting` | everything that renders | **none** |

```r
Sys.setenv(TAR_PROJECT = "collection"); targets::tar_make()
Sys.setenv(TAR_PROJECT = "factcheck");  targets::tar_make()

# or address a project directly, without changing the environment:
targets::tar_make(script = "_targets_reporting.R", store = "_targets_reporting")
targets::tar_visnetwork()                   # dependency graph of the current project
```

There is deliberately **no default project and no `_targets.R`**: a bare
`tar_make()` fails rather than silently running the collection pipeline, whose
download targets unlink before refetching. Name the project.

Which named configuration each project uses — and which assessments it covers —
comes from a **purpose block** in `input/config.yaml` — `fact_checking:`, which
is itself a library of named configs with one `active:` selection — not from a
global `active:` setting. A second block, `training:`, existed until 2026-10-05;
`purpose_config()` still accepts the flat shape it used.

Two cautions worth knowing before a first run:

- **`collection` is safe to run, but only because of content-key guards.** The
  expensive fetches (Zotero, OpenAlex works, the snowball) record the set of
  identifiers that determines their output and skip when it is unchanged, so a
  code edit or a directory move no longer triggers days of refetching. A real
  change — a new TTL, a new Zotero item — still propagates normally. Force a
  refetch with `COLLECTION_FORCE_REFRESH=1`. See [CLAUDE.md](CLAUDE.md).
- `factcheck` spends real money on every scoring and verification target. Use
  `tar_make(names = ..., shortcut = TRUE)` to render against on-disk data.

See [CLAUDE.md](CLAUDE.md) for build system details (credentials, system
dependencies) and the full pipeline architecture, and
[TD_targets.qmd](TD_targets.qmd) for why the split is shaped
this way.

## Reports

- [`IPBES_Fact_Checker.html`](IPBES_Fact_Checker.html) — the main fact-checker report (built by `report_fact_checker` in the **reporting** project: `targets::tar_make(names = "report", script = "_targets_reporting.R", store = "_targets_reporting")`)
- [`TD_targets.html`](TD_targets.html) — the `targets` pipeline architecture design doc (rendered from [TD_targets.qmd](TD_targets.qmd))
