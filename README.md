# Knowledge Discovery for GA2 based on GA1

## Introduction

This repository is using the [Linked Open Data representation of the Global Asssessment 1](https://github.com/IPBES-Data/IPBES_LOD/blob/main/Global%20Assessment%201/README.md) to identify new knowledge / literature produced after GA1 (2018).

## Methods

We use snowballing to identify the literature. The key-papers are the publications which were used for the Backbround Mesages (BMs) as identified by the LOD representation of GA1.

## Building

The pipeline is run via the [`targets`](https://books.ropensci.org/targets/) package:

```r
targets::tar_make()                                 # run everything, including the report
targets::tar_make(names = "report_fact_checker")    # just build/render the report
targets::tar_visnetwork()                           # visualise the dependency graph
```

See [CLAUDE.md](CLAUDE.md) for build system details (credentials, system
dependencies) and the full pipeline architecture.

## Reports

- [`IPBES_Fact_Checker.html`](IPBES_Fact_Checker.html) — the main fact-checker report (built by `report_fact_checker`; render with `targets::tar_make(names = "report_fact_checker")`)
- [`TD_targets.html`](TD_targets.html) — the `targets` pipeline architecture design doc (rendered from [TD_targets.qmd](TD_targets.qmd))
