# Reporting pipeline -- renders everything, computes nothing that costs money.
#
# One of four projects (see TODO_PIPELINE_SPLIT.md and _targets.yaml):
#
#   _targets.R             collection: LOD -> refs -> zotero -> works ->
#                          snowball -> works_citing. Keeps the ORIGINAL
#                          _targets/ store, so nothing re-downloads.
#   _targets_factcheck.R   citing works -> NLI -> LLM
#   _targets_training.R    key papers -> NLI -> LLM -> training set -> fine-tune
#   _targets_reporting.R   this file
#
# THE POINT OF THIS PROJECT: it has no path to a paid target. Rendering a
# report used to be able to spend RunPod GPU time and OpenRouter money,
# because report_fact_checker transitively depended on llm_verification_parquet
# and (via a bare unread argument on nli_scores_qa_data) on the key-paper
# scoring chain. The mitigation was remembering `shortcut = TRUE`. Here it is
# structural: every input below is a file on disk, so there is nothing to
# dispatch even in principle.
#
# Consequently this file sets NO credentials. The collection project needs
# API_openalex; the two scoring projects need API_openrouter; a re-render needs
# neither -- which also removes the headless/tmux macOS Keychain problem
# CLAUDE.md documents for `tar_make()` under SSH.
library(targets)

tar_option_set(
  packages = c(
    "yaml", "dplyr", "arrow", "readr", "jsonlite", "digest",
    "xml2", "stringr", "ggplot2", "IPBES.R", "htmlwidgets", "tidyr",
    "ggalluvial", "patchwork", "DT", "plotly", "MASS", "xfun"
  )
  # No crew controller: nothing here dispatches remote work. The scoring
  # projects size a crew_controller_local from the NLI host count; this one
  # has no hosts to talk to.
)

list.files("./R", full.names = TRUE) |> lapply(source)

# Generate the per-combination wrapper .qmd files declared by config.yaml's
# `reports:` section, BEFORE the pipeline list below is built.
#
# This has to be a plain call here rather than a target. tarchetypes::
# tar_quarto() resolves the Quarto project's file list AND its dependency
# edges when the script is SOURCED, so a wrapper produced by an upstream
# target would contribute nothing on the run that created it: no source, no
# dependency edge, no output.
#
# It lives in THIS project rather than a scoring one because reports come from
# both scoring consumers -- the funnel and QA_NLI_Scores families from fact
# checking, QA_NLI_Training_Data and QA_NLI_Finetuned_Model from training. A
# generator that only knew about half of `reports:` would be worse than useless.
generate_report_wrappers("input/config.yaml", "input/reports")

# ---------------------------------------------------------------------------
# Cross-project inputs.
#
# Declared as format = "file" targets pointing at what the other three projects
# write. targets hashes them, so a genuine upstream change still invalidates
# the reports -- the dependency contract survives the split. They deliberately
# keep the NAMES the other projects use (works_citing_parquet, refs_parquet,
# ...) for two reasons: the report targets below then move across verbatim, and
# the qmds' own `tar_read(refs_parquet)` / `tar_read(works_parquet)` /
# `tar_read(works_citing_parquet)` calls resolve inside THIS store, which is
# what lets tar_quarto() keep deriving their dependency edges automatically.
#
# Two inputs are deliberately NOT tracked, and passed as plain path strings
# instead: output/nli_ready_evidence (140 GB) and output/nli_training_finetuned
# (42 GB). format = "file" hashes what it is given, and hashing those on every
# check would make this project -- whose whole appeal is being fast and free --
# slower than the scoring it reports on. The cost is that a re-segmentation or
# a new fine-tuning run does not automatically invalidate the two targets that
# read them (bm_split_report_highlighted, nli_finetuned_model_qa_data); re-run
# those explicitly. Everything else is tracked normally.
# ---------------------------------------------------------------------------

list(
  # DAG diagram for THIS project.
  #
  # build_pipeline_mmd() renders whatever DAG it is run inside, so each project
  # generates its own picture rather than one "pipeline" diagram that silently
  # depicts whichever project happens to own the target. That is not
  # hypothetical: while these targets lived here during the split,
  # pipeline_nli.mmd was quietly regenerated as the 52-target REPORTING graph --
  # snowball_parquet and nli_scores_by_claim_evidence gone, works_citing_parquet
  # surviving only as the input stub this project declares. The per-project .mmd
  # files can be combined into one overview here later; for now each is honest
  # about what it shows.
  tar_target(r_files, list.files("R", full.names = TRUE), format = "file"),
  tar_target(
    pipeline_mmd,
    build_pipeline_mmd(r_files, "input/mmd/pipeline_reporting.mmd"),
    format = "file"
  ),
  tar_target(
    diagram_pipeline_reporting,
    render_mmd(pipeline_mmd),
    format = "file"
  ),

  # ---- configuration (re-derived here; every project reads the same file) ---
  tar_target(config_file, "input/config.yaml", format = "file"),
  tar_target(nli_active, yaml::read_yaml(config_file)[["nli"]][["active"]]),
  tar_target(nli_configs_all, yaml::read_yaml(config_file)[["nli"]][["configs"]]),
  tar_target(nli_config, {
    nli <- yaml::read_yaml(config_file)[["nli"]]
    nli[["configs"]][[nli[["active"]]]]
  }),
  tar_target(
    granularity,
    yaml::read_yaml(config_file)[["nli"]][["configs"]][[nli_active]][["granularity"]] %||% "naive_bm"
  ),
  # Fixed literal, not read from config: this layer renders ALL three
  # granularities even though only one is ever "active" for scoring, so a
  # granularity scored earlier under its own config still gets a report.
  tar_target(nli_granularities, c("naive_bm", "complete_bm", "atomic_bm")),
  tar_target(
    llm_verification_active,
    yaml::read_yaml(config_file)[["llm_verification"]][["active"]]
  ),
  tar_target(claim_completion_model, {
    cc <- yaml::read_yaml(config_file)[["nli"]][["claim_completion"]]
    cc[["configs"]][[cc[["active"]]]][["model"]]
  }),
  tar_target(
    assessments_list,
    lapply(yaml::read_yaml(config_file)[["assessments"]], function(a) {
      a[setdiff(names(a), "full_text")]
    })
  ),
  tar_target(
    assessment,
    {
      x <- assessments_list
      names(x) <- vapply(x, `[[`, character(1), "id")
      Map(function(a, i) c(a, list(index = i)), x, seq_along(x))
    },
    iteration = "list"
  ),

  # ---- inputs from the collection project (_targets.R) ----------------------
  # Every one KEEPS THE NAME the producing project uses, so the report targets
  # below move across verbatim, and so the qmds' own tar_read(refs_parquet) /
  # tar_read(works_parquet) / tar_read(works_citing_parquet) calls resolve
  # inside this store -- which is what lets tar_quarto() go on deriving their
  # dependency edges automatically.
  tar_target(
    refs_parquet,
    file.path("output/refs", paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  tar_target(
    key_messages_parquet,
    file.path("output/key_messages", paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  tar_target(
    works_parquet,
    file.path("output/works", paste0("assessment=", assessment$id)),
    pattern = map(assessment), format = "file"
  ),
  # Two paths per branch, exactly as the collection project's own target
  # returns them, so works_citing_map_paths()/works_citing_meta_paths()
  # (R/build_works_citing_parquet.R) keep working unchanged.
  tar_target(
    works_citing_parquet,
    c(
      file.path("output/works_citing", paste0("assessment=", assessment$id)),
      file.path("output/works_citing_meta", paste0("assessment=", assessment$id))
    ),
    pattern = map(assessment), format = "file"
  ),

  # ---- inputs from the fact-checking project (_targets_factcheck.R) --------
  # These replace bare, never-read arguments that existed only to force
  # ordering inside one DAG. Tracking the directory is strictly better: a real
  # change to the scores now invalidates the reports through content hashing,
  # rather than through a dependency edge someone had to remember to draw.
  tar_target(
    nli_scores_evidence_consolidated,
    "output/nli_scores_evidence", format = "file"
  ),
  # UNTRACKED on purpose, and NOT format = "file".
  #
  # A file target errors when its path does not exist, and these legitimately
  # do not: only GA1 has citing-works Phase 2 output, and BBA has no key-paper
  # Phase 2 output. Declaring them as file targets failed 6 of 15 branches on
  # the first real run. `error = "null"` is not a fix either -- the builders
  # probe with their own dir.exists()/parquet checks and degrade to an empty
  # state, but they need a path STRING to probe; NULL makes `if (dir.exists(x))`
  # raise on a zero-length condition.
  #
  # The cost is that a Phase 2 re-run does not automatically invalidate the
  # reports: re-run this project after scoring. That is the same
  # operator-ordering trade-off the split accepts generally (see
  # TODO_PIPELINE_SPLIT.md, "What gets worse").
  tar_target(
    llm_verification_parquet,
    file.path(
      "output/llm_verification/scores",
      paste0("llm_config=", llm_verification_active),
      paste0("assessment=", assessment$id)
    ),
    pattern = map(assessment)
  ),
  # UNTRACKED on purpose (140 GB) -- see the preamble. Branched per assessment
  # so bm_split_report_highlighted's `pattern = map(...)` is unchanged.
  tar_target(
    nli_ready_evidence_parquet,
    file.path(
      "output/nli_ready_evidence", paste0("granularity=", granularity),
      paste0("assessment=", assessment$id)
    ),
    pattern = map(assessment)
  ),

  # ---- inputs from the training project (_targets_training.R) --------------
  tar_target(
    nli_scores_keypaper_evidence_consolidated,
    "output/nli_scores_evidence_keypaper", format = "file"
  ),
  tar_target(
    nli_scores_keypaper_evidence,
    "output/nli_scores_evidence_keypaper", format = "file"
  ),
  # UNTRACKED on purpose, and NOT format = "file".
  #
  # A file target errors when its path does not exist, and these legitimately
  # do not: only GA1 has citing-works Phase 2 output, and BBA has no key-paper
  # Phase 2 output. Declaring them as file targets failed 6 of 15 branches on
  # the first real run. `error = "null"` is not a fix either -- the builders
  # probe with their own dir.exists()/parquet checks and degrade to an empty
  # state, but they need a path STRING to probe; NULL makes `if (dir.exists(x))`
  # raise on a zero-length condition.
  #
  # The cost is that a Phase 2 re-run does not automatically invalidate the
  # reports: re-run this project after scoring. That is the same
  # operator-ordering trade-off the split accepts generally (see
  # TODO_PIPELINE_SPLIT.md, "What gets worse").
  tar_target(
    llm_verification_keypaper_parquet,
    file.path(
      "output/llm_verification/scores_keypaper",
      paste0("llm_config=", llm_verification_active),
      paste0("assessment=", assessment$id)
    ),
    pattern = map(assessment)
  ),
  # UNTRACKED on purpose, and NOT format = "file".
  #
  # A file target errors when its path does not exist, and these legitimately
  # do not: only GA1 has citing-works Phase 2 output, and BBA has no key-paper
  # Phase 2 output. Declaring them as file targets failed 6 of 15 branches on
  # the first real run. `error = "null"` is not a fix either -- the builders
  # probe with their own dir.exists()/parquet checks and degrade to an empty
  # state, but they need a path STRING to probe; NULL makes `if (dir.exists(x))`
  # raise on a zero-length condition.
  #
  # The cost is that a Phase 2 re-run does not automatically invalidate the
  # reports: re-run this project after scoring. That is the same
  # operator-ordering trade-off the split accepts generally (see
  # TODO_PIPELINE_SPLIT.md, "What gets worse").
  tar_target(
    nli_training_data,
    file.path(
      "output/nli_training", paste0("granularity=", granularity),
      paste0("nli_config=", nli_active), paste0("assessment=", assessment$id)
    ),
    pattern = map(assessment)
  ),
  # UNTRACKED on purpose (42 GB of checkpoints). Reproduces what
  # build_nli_finetuned_model() returns -- the timestamped run directory it
  # recorded in its own sentinel, or the empty marker it writes when the active
  # config has train: false. build_nli_finetuned_model_qa_data() already
  # handles both.
  tar_target(
    nli_finetuned_model,
    {
      sentinel <- "output/nli_training_finetuned/.last_run_dir.txt"
      if (file.exists(sentinel)) {
        readLines(sentinel, warn = FALSE)[[1L]]
      } else {
        file.path("output/nli_training_finetuned", ".disabled", nli_active)
      }
    }
  ),

  tar_target(
    mmd_workflow_reporting,
    "input/mmd/workflow_reporting.mmd",
    format = "file"
  ),
  tar_target(
    diagram_workflow_reporting,
    render_mmd(mmd_workflow_reporting),
    format = "file"
  ),
  # Target 2f2: Publications-per-year-by-BM figure — aggregated across every
  # assessment's works_citing branches (no `pattern =` here: targets combines
  # all dynamic branches of works_citing_parquet into one vector).
  tar_target(
    fig_pub_per_year,
    build_fig_pub_per_year(works_citing_parquet, "output/figures"),
    format = "file"
  ),
  # Target 2f3: Key-paper overlap table — key/seed papers (works_parquet)
  # referenced in more than one background message. Aggregated across every
  # assessment's works branches, same aggregation pattern as fig_pub_per_year.
  tar_target(
    overlap_key_paper_table,
    build_overlap_key_paper_table(works_parquet, "output/tables"),
    format = "file"
  ),
  # # # Target 2f4/2f5: Citing-paper overlap tables — citing papers
  # # # (works_citing_parquet) published after 2018, referenced from more than 5
  # # # background messages. "sub_messages" and "background_messages" group
  # # # identically under the active schema (no sub-message level) — kept as two
  # # # targets only for report-section continuity with the legacy qmd; the
  # # # background_messages variant additionally carries the abstract column.
  # # tar_target(
  # #   overlap_after_2018_sub_messages_table,
  # #   build_overlap_after_2018_sub_messages_table(works_citing_parquet, 2018, "output/tables"),
  # #   format = "file"
  # # ),
  # tar_target(
  #   overlap_after_2018_background_messages_table,
  #   build_overlap_after_2018_background_messages_table(works_citing_parquet, 2018, "output/tables"),
  #   format = "file"
  # ),
  # QA report: how nli_ready_evidence_parquet actually split each BM into
  # claims, one assessment's worth of colour-highlighted-original-text +
  # itemised-claim-list HTML per branch, reflecting whichever granularity
  # is currently active (naive_bm/atomic_bm show the extracted confidence
  # column; complete_bm gracefully has none). Deliberately downstream of
  # nli_ready_evidence_parquet itself (reads its real on-disk output,
  # distinct()-ed back to one row per claim) rather than a separate
  # pre-scoring computation, so it can never drift from what was actually
  # produced. Not a TD_ design doc -- a QA artifact, same self-contained
  # `format: html` convention as the other reports.
  tar_target(
    bm_split_report_highlighted,
    build_bm_split_highlighted(
      assessment,
      nli_ready_evidence_parquet,
      key_messages_parquet,
      granularity,
      "output/tables",
      claim_completion_model
    ),
    pattern = map(assessment, nli_ready_evidence_parquet, key_messages_parquet),
    format = "file"
  ),
  # Target 2h4: NLI overview data — per-assessment label/confidence/alignment
  # summary tables, for the report and its BM explorer. Deliberately wired to
  # the EVIDENCE-segmentation scoring chain (nli_scores_by_claim_evidence /
  # output/nli_scores_evidence), not the original per-sentence one
  # (nli_scores_by_claim / output/nli_scores): the two scoring targets share
  # score_one_claim(), so any change to that file marks BOTH outdated
  # regardless of which approach is actually being run, and the per-sentence
  # chain is far less complete (14/725 claims scored at time of writing).
  # Wiring the report to it meant tar_make(report_fact_checker) could
  # transitively try to dispatch ~700 unscored per-sentence claims through
  # the same host pool as a live evidence scoring run — see git history for
  # the incident this comment is warning about. Reads directly from the
  # on-disk output path rather than individual per-claim file paths;
  # nli_scores_by_claim_evidence is listed as an argument purely to
  # establish the DAG dependency (so this target waits for evidence scoring
  # and invalidates when its output changes).
  tar_target(
    nli_overview_data,
    build_nli_overview_data(
      assessment,
      file.path(
        "output/nli_scores_evidence",
        paste0("granularity=", nli_granularities),
        paste0("nli_config=", nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active)),
        paste0("assessment=", assessment$id)
      ),
      nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active),
      works_citing_meta_paths(works_citing_parquet),
      "output/tables",
      nli_scores_evidence_consolidated,
      nli_granularities
    ),
    pattern = cross(map(assessment, works_citing_parquet), nli_granularities),
    format = "file",
    # collect()s the entire per-assessment nli_scores_evidence table (every
    # row, not just REFUTES/uncertain) to build the summary tables — for GA1
    # alone that's ~1.9M rows. Running GA1's and IAS's branches on separate
    # crew workers doubles that peak; deployment = "main" processes them one
    # at a time instead. Contributed to an observed OOM alongside
    # llm_verification_parquet/nli_ready_parquet running concurrently.
    deployment = "main",
    garbage_collection = TRUE
  ),
  # Target 2h4' (QA): Phase 1 scoring QA report data — sibling to
  # bm_split_report_highlighted (which QAs the segmentation step); this
  # QAs the scoring step itself: a capped, per-claim table of citing works
  # (title/abstract/DOI joined in from works_citing_parquet -- Phase 1's
  # own output only ever stores work_id) with their NLI label/confidence/
  # class-probabilities, plus a label x confidence-decile matrix computed
  # on the full (uncapped) data. Same cross(assessment, nli_granularities)
  # scoping and nli_config_for_granularity() resolution as nli_overview_data
  # just above, for the same reason (nli.active is a single global choice;
  # each granularity is normally scored under its own dedicated config).
  tar_target(
    nli_scores_qa_data,
    build_nli_scores_qa_data(
      assessment,
      file.path(
        "output/nli_scores_evidence",
        paste0("granularity=", nli_granularities),
        paste0("nli_config=", nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active)),
        paste0("assessment=", assessment$id)
      ),
      works_citing_meta_paths(works_citing_parquet),
      nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active),
      nli_granularities,
      "output/tables",
      per_claim_cap = 50L,
      # Same granularity/nli_config resolution as the main nli_scores_path
      # above, pointed at the SEPARATE key-paper scoring chain instead --
      # empty/absent until that (RunPod-calling) chain has actually been
      # run; build_nli_scores_qa_data() degrades to "no overlay" rather
      # than erroring.
      keypaper_scores_path = file.path(
        "output/nli_scores_evidence_keypaper",
        paste0("granularity=", nli_granularities),
        paste0("nli_config=", nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active)),
        paste0("assessment=", assessment$id)
      ),
      # Bare reference -- establishes the DAG dependency only, so the
      # key-paper chain runs automatically as part of a bare tar_make()
      # instead of needing to be triggered explicitly. Points at the
      # CONSOLIDATED target, not the per-claim scoring branches: this reads
      # the scored data off disk, so it must not start until the scratch
      # files have been merged.
      nli_scores_keypaper_evidence = nli_scores_keypaper_evidence_consolidated,
      # Resolved granularity's OWN uncertain_threshold -- not nli.active's --
      # same fine-grained-config reasoning as nli_config_for_granularity()
      # itself. Falls back to 0.60 (score_one_claim()'s own default) if the
      # resolved config doesn't set one. Feeds the ternary figure's
      # certain/uncertain boundary lines.
      uncertain_threshold = nli_configs_all[[nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active)]][["uncertain_threshold"]] %||% 0.60
    ),
    pattern = cross(map(assessment, works_citing_parquet), nli_granularities),
    format = "file",
    # Same OOM caution as nli_overview_data just above -- collect()s the
    # full per-assessment scored table before capping.
    deployment = "main",
    garbage_collection = TRUE
  ),
  # Target 2h4'' (QA figure): the ternary (p_supports, p_refutes, p_nei)
  # density plot as a static PNG. Separate target from nli_scores_qa_data
  # itself (same split as nli_overview_data -> nli_overview_figures) so
  # replotting doesn't require recollecting the raw scored table.
  tar_target(
    nli_scores_qa_figures,
    build_nli_scores_qa_figures(nli_scores_qa_data, "output/figures"),
    pattern = map(nli_scores_qa_data),
    format = "file"
  ),
  # Target 2h4b'' (QA data): Phase 2 (LLM verification) scoring QA report
  # data — sibling to nli_scores_qa_data (which QAs Phase 1). Single-
  # active-granularity, NOT cross()'d over nli_granularities like
  # nli_scores_qa_data is — llm_verification_parquet only ever reflects
  # whichever granularity is currently active (single active
  # nli_ready_evidence_parquet/nli_active, pattern = map(assessment, ...),
  # no cross()), so there is nothing to cross here either. See
  # R/build_llm_verification_qa_data.R.
  tar_target(
    llm_verification_qa_data,
    build_llm_verification_qa_data(
      assessment,
      llm_verification_parquet,
      works_citing_meta_paths(works_citing_parquet),
      llm_verification_active,
      nli_active,
      "output/tables",
      per_claim_cap = 50L,
      llm_verification_keypaper_path = llm_verification_keypaper_parquet,
      works_path = works_parquet
    ),
    pattern = map(
      assessment, llm_verification_parquet, llm_verification_keypaper_parquet,
      works_parquet, works_citing_parquet
    ),
    format = "file",
    # Same OOM caution as llm_verification_parquet above — collect()s the
    # full per-assessment reviewed table before capping.
    deployment = "main",
    garbage_collection = TRUE
  ),
  # Target 2h4b''' (QA figures): the two Phase 2 QA figures — a
  # confidence-decile agreement line and an NLI→LLM alluvial diagram, each
  # with a key-paper overlay (see R/build_llm_verification_qa_figures.R for
  # why a literal ternary plot was rejected for Phase 2). Separate target
  # from llm_verification_qa_data itself — same split as nli_overview_data
  # → nli_overview_figures — so replotting doesn't require recollecting the
  # raw scored table.
  tar_target(
    llm_verification_qa_figures,
    build_llm_verification_qa_figures(llm_verification_qa_data, "output/figures"),
    pattern = map(llm_verification_qa_data),
    format = "file"
  ),
  # Target 2h4d' (QA data/report): sibling to llm_verification_qa_data/
  # llm_verification_qa_report_html — same "not a scoring result, a sanity
  # check" framing, same cached-widget convention. See
  # R/build_nli_training_qa_data.R.
  tar_target(
    nli_training_qa_data,
    build_nli_training_qa_data(
      nli_training_data, assessment$id, nli_active, granularity, "output/tables"
    ),
    pattern = map(assessment, nli_training_data),
    format = "file"
  ),
  # Target 2h4e' (QA data/report): sibling to nli_training_qa_data/
  # nli_training_qa_report_html -- same "not a scoring result, a progress
  # check" framing. Single nli_config scope (fine-tuning pools across
  # whatever assessments/granularity that config's own training data has,
  # not per-assessment), so no cross()/map() over assessment here.
  tar_target(
    nli_finetuned_model_qa_data,
    build_nli_finetuned_model_qa_data(nli_finetuned_model, nli_active, "output/tables")
  ),
  # Target 2h3: NLI overview figures — label split (overall/per-KM/per-BM),
  # confidence density, alignment density, per assessment.
  tar_target(
    nli_overview_figures,
    build_nli_overview_figures(nli_overview_data, "output/figures"),
    pattern = map(nli_overview_data),
    format = "file"
  ),
  # Target 2h5: NLI BM explorer — one interactive plotly widget per
  # assessment with a BM-selector dropdown (label distribution, confidence
  # distribution with mean/median, alignment distribution). Written as a
  # self-contained standalone HTML file (embedded via <iframe> in the report)
  # rather than printed in-place, since Quarto's HTML format does not
  # propagate htmlwidget JS dependencies out of a manually cat()-ed
  # knit_print() call inside a results:asis loop — see R/build_nli_bm_explorer.R.
  tar_target(
    nli_bm_explorer_html,
    save_nli_bm_explorer(nli_overview_data, "output/tables"),
    pattern = map(nli_overview_data),
    format = "file"
  ),
  # Target 2h6: label funnels (REFUTES and SUPPORTS) — a 3-level sieve of
  # distinct citing works per (km, bm): snowball corpus -> NLI <label>-certain
  # -> LLM-confirmed <label>, each a subset of the previous. Pure local
  # arrow/dplyr over already-scored parquet (no network/GPU calls); reads
  # llm_verification_parquet only as an already-built dependency, same
  # DAG-dependency-only convention as nli_scores_by_claim_evidence elsewhere.
  # One shared build_label_funnel_*() implementation, called once per label,
  # rather than two near-identical copies. See R/build_label_funnel_data.R
  # and IPBES_Label_Funnel_Report.qmd.
  # Branches over BOTH assessment and nli_granularities (cross(), not map():
  # granularity is an independent dimension, not zipped 1:1 with assessment)
  # so naive_bm/complete_bm/atomic_bm each get their own funnel view,
  # regardless of which one is actually active in nli.active -- a
  # combination with no scored data yet renders the existing empty state.
  # The nli_config used to locate (and label) each granularity's data is
  # resolved per-branch via nli_config_for_granularity() (R/branch_helpers.R)
  # -- NOT nli_active directly -- since each granularity is normally scored
  # under its own dedicated config (bge_m3_zeroshot_naive_bm/_complete_bm/
  # _atomic_bm); substituting the single globally active config name for
  # every branch would make an already-scored, non-active granularity look
  # unscored the moment `nli.active` points elsewhere.
  tar_target(
    refutes_funnel_data,
    build_label_funnel_data(
      assessment,
      "REFUTES",
      works_citing_map_paths(works_citing_parquet),
      works_citing_meta_paths(works_citing_parquet),
      file.path(
        "output/nli_scores_evidence",
        paste0("granularity=", nli_granularities),
        paste0("nli_config=", nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active)),
        paste0("assessment=", assessment$id)
      ),
      llm_verification_parquet,
      "output/tables",
      nli_granularities,
      nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active)
    ),
    pattern = cross(map(assessment, works_citing_parquet, llm_verification_parquet), nli_granularities),
    format = "file",
    # collect()s a full per-assessment nli_scores_evidence table, same OOM
    # caution as nli_overview_data.
    deployment = "main",
    garbage_collection = TRUE
  ),
  tar_target(
    supports_funnel_data,
    build_label_funnel_data(
      assessment,
      "SUPPORTS",
      works_citing_map_paths(works_citing_parquet),
      works_citing_meta_paths(works_citing_parquet),
      file.path(
        "output/nli_scores_evidence",
        paste0("granularity=", nli_granularities),
        paste0("nli_config=", nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active)),
        paste0("assessment=", assessment$id)
      ),
      llm_verification_parquet,
      "output/tables",
      nli_granularities,
      nli_config_for_granularity(nli_configs_all, nli_granularities, nli_active)
    ),
    pattern = cross(map(assessment, works_citing_parquet, llm_verification_parquet), nli_granularities),
    format = "file",
    deployment = "main",
    garbage_collection = TRUE
  ),
  tar_target(
    refutes_funnel_figures,
    build_label_funnel_figures(refutes_funnel_data, "output/figures"),
    pattern = map(refutes_funnel_data),
    format = "file"
  ),
  tar_target(
    supports_funnel_figures,
    build_label_funnel_figures(supports_funnel_data, "output/figures"),
    pattern = map(supports_funnel_data),
    format = "file"
  ),
  tar_target(
    refutes_funnel_tables,
    build_label_funnel_tables(refutes_funnel_data, "output/tables"),
    pattern = map(refutes_funnel_data),
    format = "file"
  ),
  tar_target(
    supports_funnel_tables,
    build_label_funnel_tables(supports_funnel_data, "output/tables"),
    pattern = map(supports_funnel_data),
    format = "file"
  ),
  tar_target(
    claude_md,
    "CLAUDE.md",
    format = "file"
  ),
  # ── Reports ──────────────────────────────────────────────────────────────
  #
  # These three replace nineteen former targets: nine that each called
  # quarto::quarto_render() and then file.rename()d the result out of
  # input/reports/ into output/reports/, their nine companion *_qmd
  # file-tracking targets, and report_output_dir.
  #
  # input/reports/_quarto.yml is now the single source of shared format and,
  # via output-dir, of where rendered html lands -- so nothing moves files by
  # hand any more. tar_quarto() also derives each report's dependencies from
  # the tar_read() calls in the project's sources, which is the real win: the
  # old report_fact_checker target listed eight dependencies by hand and
  # MISSED five that the qmd genuinely reads (fig_pub_per_year,
  # nli_overview_figures, overlap_key_paper_table and the two
  # overlap_after_2018_* tables). Those were DAG leaves, rebuilt only because
  # a bare tar_make() builds everything.

  # Every report except the main one: the 27 generated wrapper documents plus
  # the six TD design docs.
  tarchetypes::tar_quarto(
    reports_project,
    path = "input/reports"
  ),
  # The main report, rendered separately and AFTER the project above, because
  # it links to -- and copies into its own _files/ sidecar -- the rendered
  # html of every sibling report. A single project render gives no ordering
  # guarantee, so IPBES_Fact_Checker.qmd is excluded from the project's
  # `render:` list and gets its own target here; the qmd's own
  # tar_read(reports_project) call is what creates the edge that orders them.
  # Rendering the single file still picks up _quarto.yml's format and
  # output-dir, since the file sits inside the project.
  tarchetypes::tar_quarto(
    report_fact_checker,
    path = "input/reports/IPBES_Fact_Checker.qmd"
  ),
  # Deploy extras that Quarto itself does not produce: .github/workflows/
  # deploy-pages.yml rsyncs output/reports/ verbatim to gh-pages, and it needs
  # a .nojekyll, an index.html, and the CLAUDE.md that TD_targets.qmd links to
  # by plain relative path. index.html is a byte-identical COPY of the report
  # rather than a redirect, so its relative _files/ links still resolve.
  #
  # This is all that survives of build_report_output_dir(). Its pruning half
  # was dropped because it was actively harmful -- it deleted two reports that
  # were never added to its `expected` list -- but note that nothing replaced
  # it: Quarto's project render was measured NOT to remove files it does not
  # manage (a stray file and a .nojekyll both survived one), so stale outputs
  # from earlier naming conventions now persist until removed by hand. See
  # CLAUDE.md.
  tar_target(
    report_output_dir,
    build_report_output_dir(
      report_fact_checker,
      reports_project,
      claude_md,
      "output/reports"
    ),
    format = "file"
  ),
  # Single entry point for "build every report". Depends on the whole report
  # chain -- the project render, the main report that must follow it, and the
  # deploy extras -- so one name covers all three.
  #
  # Deliberately NOT format = "file": report_output_dir already returns the
  # full listing of output/reports (~115 MB), and re-hashing all of it here to
  # produce a second copy of the same information would cost real time on every
  # check for no benefit. The value is a small summary instead; the actual
  # outputs stay tracked by the three targets below it.
  #
  # Two ways to invoke it, and the difference matters:
  #
  #   tar_make(names = "report")
  #     Full dependency check. Correct, and what you want when the pipeline is
  #     current -- but it walks the ENTIRE upstream, so it will rebuild
  #     nli_scores_by_claim_evidence (RunPod GPU) and llm_verification_parquet
  #     (OpenRouter spend) if those are outdated.
  #
  #   tar_make(names = c("reports_project", "report_fact_checker",
  #                      "report_output_dir"), shortcut = TRUE)
  #     Re-render against whatever is on disk, touching nothing upstream.
  #     Naming "report" with shortcut = TRUE does NOT work: shortcut builds
  #     only the named targets and loads their dependencies from the store, so
  #     nothing is re-rendered.
  tar_target(
    report,
    list(
      project_documents = length(reports_project),
      main_report = report_fact_checker[grepl("\\.html$", report_fact_checker)],
      deployed_files = length(report_output_dir)
    )
  ),
  NULL
)
