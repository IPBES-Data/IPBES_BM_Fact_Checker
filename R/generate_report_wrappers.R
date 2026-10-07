# Generate one small wrapper .qmd per (report x dimension) combination, from
# the `reports:` section of input/config.yaml.
#
# WHY THIS IS NOT A TARGET. tarchetypes::tar_quarto() resolves the project's
# file list AND its dependency edges when _targets_collection.R is SOURCED, not when the
# target runs: tar_quarto_raw() calls tar_quarto_files() in its own body, and
# tar_quarto_command() computes `deps <- map(sources, knitr_deps)` there too,
# baking both into the target's command. A wrapper produced by an upstream
# target would therefore contribute nothing on the run that created it -- no
# source, no dependency edge. So generation runs in _targets_collection.R's preamble,
# after R/ is sourced and before the pipeline list is built.
#
# Consequences of running at definition time, all handled below:
#   * it runs on every tar_make()/tar_outdated()/tar_visnetwork(), so it must
#     be cheap and IDEMPOTENT -- write_if_changed() leaves bytes and mtimes
#     alone when nothing moved;
#   * a failure here makes _targets_collection.R unsourceable, so every validation error
#     names exactly what is wrong in config.yaml;
#   * it must PRUNE, or a report dropped from config would keep rendering.
#
# Each wrapper is a params: block, a tar_read() chunk, and an include of the
# shared body `_<qmd_name>_body.qmd`.
#
# The tar_read() calls have to be in the WRAPPER, not the body. Quarto ignores
# underscore-prefixed files completely: they are neither rendered nor listed by
# tar_quarto_files(), so they never reach tar_quarto()'s dependency scan
# (verified both ways -- naming them explicitly in `project: render:` does not
# pull them in either). Since tar_quarto() derives its edges from
# `map(sources, knitr_deps)`, only the wrapper is ever scanned. So each wrapper
# declares its own dependencies literally and hands the values to the body in a
# `report_deps` list. A side benefit: the funnel wrappers name only their own
# label's targets, which is finer-grained than the old targets managed.
#
# The wrapper's FILENAME is the output filename, so no output_file plumbing is
# needed anywhere. Names are built with granularity_suffix()/nli_model_suffix()
# from R/branch_helpers.R rather than re-derived, so they match exactly what
# the nine former render targets produced.

# Which Quarto project each `reports:` entry belongs to, and where that
# project's sources live. The names match _targets.yaml's own project names,
# since that is what decides which STORE a wrapper's tar_read() calls resolve
# against -- a wrapper in the wrong directory names targets that do not exist
# in the project that renders it.
#
# Two projects rather than one because Quarto gives a project exactly one
# output-dir: output/reports/ is published to GitHub Pages at the site root,
# output/reports_training/ under /training/. See input/reports_training/_quarto.yml.
report_project_dirs <- function() {
  # `training` was removed on 2026-10-05 with the project that rendered into it.
  # Kept as a one-element vector rather than collapsed to a bare string: the
  # `project:` key, the per-directory pruning and the both-preambles call all
  # still work, so adding a second output directory back is adding an element.
  c(reporting = "input/reports")
}

# Marker written into every generated file. Pruning only ever removes files
# carrying it, so a hand-written .qmd in input/reports/ can never be deleted
# by accident.
report_wrapper_marker <- "<!-- GENERATED FILE -- edit config.yaml `reports:` instead, not this file. -->"

# Which params each body expects, and how its output file is named. Kept in
# one table so adding a report family is a single entry here plus a
# `reports:` entry in config.yaml.
report_wrapper_spec <- function() {
  list(
    IPBES_Label_Funnel_Report = list(
      dims = c("assessment", "granularity", "label", "scorer_config"),
      # Only this wrapper's own label's targets, not both.
      deps = function(p) {
        stem <- tolower(p$label)
        c(
          data = paste0(stem, "_funnel_data"),
          figures = paste0(stem, "_funnel_figures"),
          tables = paste0(stem, "_funnel_tables")
        )
      },
      params = function(p) {
        list(
          assessment_id = p$assessment,
          label = p$label,
          granularity = p$granularity,
          scorer_name = p$scorer_config
        )
      },
      name = function(p) {
        paste0(
          "IPBES_", p$label, "_Report_", p$assessment,
          nli_model_suffix(p$scorer_config), granularity_suffix(p$granularity)
        )
      }
    ),
    QA_BM_Split_Report = list(
      dims = c("assessment", "granularity"),
      deps = function(p) c(bm_split_report_highlighted = "bm_split_report_highlighted"),
      params = function(p) {
        list(assessment_id = p$assessment, granularity = p$granularity)
      },
      name = function(p) {
        paste0(
          "QA_BM_Split_Report_", p$assessment,
          granularity_suffix(p$granularity)
        )
      }
    ),
    QA_NLI_Scores_Report = list(
      dims = c("assessment", "granularity", "scorer_config"),
      deps = function(p) {
        c(
          nli_scores_qa_data = "nli_scores_qa_data",
          nli_scores_qa_figures = "nli_scores_qa_figures"
        )
      },
      params = function(p) {
        list(
          assessment_id = p$assessment,
          granularity = p$granularity,
          scorer_config = p$scorer_config
        )
      },
      name = function(p) {
        paste0(
          "QA_NLI_Scores_Report_", p$assessment,
          nli_model_suffix(p$scorer_config), granularity_suffix(p$granularity)
        )
      }
    ),
    QA_LLM_Verification_Report = list(
      dims = c("assessment", "llm_config"),
      deps = function(p) {
        c(
          llm_verification_qa_data = "llm_verification_qa_data",
          llm_verification_qa_figures = "llm_verification_qa_figures"
        )
      },
      params = function(p) {
        list(assessment_id = p$assessment, llm_config = p$llm_config)
      },
      name = function(p) {
        paste0("QA_LLM_Verification_Report_", p$assessment, "_", p$llm_config)
      }
    )
  )
}

report_wrapper_default_granularities <- function() {
  c("naive_bm", "complete_bm", "atomic_bm")
}

report_wrapper_labels <- function() {
  c("REFUTES", "SUPPORTS")
}

# Fill {placeholder}s in a title template from that wrapper's own values.
render_title_template <- function(template, values) {
  out <- template
  for (nm in names(values)) {
    out <- gsub(paste0("{", nm, "}"), values[[nm]], out, fixed = TRUE)
  }
  left <- regmatches(out, regexpr("\\{[^}]+\\}", out))
  if (length(left)) {
    stop(sprintf(
      "report title template '%s' has unfilled placeholder(s): %s (available: %s)",
      template, paste(left, collapse = ", "), paste(names(values), collapse = ", ")
    ), call. = FALSE)
  }
  out
}

# Write only when the bytes actually change, so this can run on every
# tar_make()/tar_outdated() without churning mtimes or invalidating anything.
write_if_changed <- function(path, lines) {
  # Compare and write the LINE VECTOR, not a pre-collapsed string: writeLines()
  # appends its own terminating newline, so writing an already-"\n"-terminated
  # string leaves a trailing blank line and every subsequent comparison fails
  # -- which silently defeats the whole point of this function.
  # as.character() strips names: the dep_lines vector is named, and c() keeps
  # those names, so identical() against readLines()' unnamed output would never
  # match no matter how equal the text is.
  lines <- as.character(lines)
  if (file.exists(path)) {
    if (identical(readLines(path, warn = FALSE), lines)) {
      return(FALSE)
    }
  }
  writeLines(lines, path, useBytes = TRUE)
  TRUE
}

report_wrapper_lines <- function(title, body_include, params, deps) {
  yaml_params <- vapply(
    names(params),
    function(nm) sprintf("  %s: \"%s\"", nm, params[[nm]]),
    character(1)
  )
  dep_lines <- vapply(
    names(deps),
    function(nm) sprintf("  %s = targets::tar_read(%s),", nm, deps[[nm]]),
    character(1)
  )
  dep_lines[length(dep_lines)] <- sub(",$", "", dep_lines[length(dep_lines)])
  c(
    "---",
    sprintf("title: \"%s\"", title),
    "date: today",
    "params:",
    yaml_params,
    "---",
    "",
    report_wrapper_marker,
    "",
    "```{r}",
    "#| label: targets-dependencies",
    "#| include: false",
    "",
    "# Named literally so tar_quarto() turns them into real dependency edges.",
    "# This has to happen here rather than in the included body: Quarto excludes",
    "# underscore-prefixed files from the project, so the body is never scanned.",
    "report_deps <- list(",
    dep_lines,
    ")",
    "```",
    "",
    sprintf("{{< include %s >}}", body_include)
  )
}

# Expand one config `reports:` entry into a data frame of combinations.
report_wrapper_combinations <- function(entry, cfg, spec) {
  qmd_name <- entry[["qmd_name"]]
  dims <- spec$dims

  assessments <- vapply(config_assessments(cfg), function(a) a$id, character(1))
  nli_configs <- cfg$nli$configs

  vals <- list()

  if ("assessment" %in% dims) {
    a <- unlist(entry[["assessment"]])
    if (is.null(a) || !length(a)) {
      stop(sprintf(
        "reports: entry '%s' needs an `assessment:` list (this report varies by assessment)",
        qmd_name
      ), call. = FALSE)
    }
    unknown <- setdiff(a, assessments)
    if (length(unknown)) {
      stop(sprintf(
        "reports: entry '%s' names assessment(s) absent from `assessments:`: %s",
        qmd_name, paste(unknown, collapse = ", ")
      ), call. = FALSE)
    }
    vals$assessment <- a
  }

  if ("granularity" %in% dims) {
    g <- unlist(entry[["granularity"]])
    if (is.null(g) || !length(g)) {
      g <- report_wrapper_default_granularities()
    }
    unknown <- setdiff(g, report_wrapper_default_granularities())
    if (length(unknown)) {
      stop(sprintf(
        "reports: entry '%s' names unknown granularity/ies: %s (known: %s)",
        qmd_name, paste(unknown, collapse = ", "),
        paste(report_wrapper_default_granularities(), collapse = ", ")
      ), call. = FALSE)
    }
    vals$granularity <- g
  }

  if ("label" %in% dims) {
    vals$label <- report_wrapper_labels()
  }

  if ("llm_config" %in% dims) {
    l <- unlist(entry[["llm_config"]])
    if (is.null(l) || !length(l)) {
      # Default to the fact-checking selection: the only llm_config-dimensioned
      # report today is the citing-works Phase 2 QA view.
      l <- purpose_config(cfg, "fact_checking")$llm
    }
    unknown <- setdiff(l, names(cfg$llm_verification$configs))
    if (length(unknown)) {
      stop(sprintf(
        "reports: entry '%s' names unknown llm_config(s): %s (known: %s)",
        qmd_name, paste(unknown, collapse = ", "),
        paste(names(cfg$llm_verification$configs), collapse = ", ")
      ), call. = FALSE)
    }
    vals$llm_config <- l
  }

  grid <- if (length(vals)) {
    expand.grid(vals, stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE)
  } else {
    data.frame(.dummy = NA)
  }

  # scorer_config last: when not pinned it is DERIVED per granularity via
  # nli_config_for_granularity(), which is the safe default -- naming the
  # wrong config silently makes already-scored data look unscored.
  if ("scorer_config" %in% dims) {
    pinned <- unlist(entry[["scorer_config"]])
    if (!is.null(pinned) && length(pinned)) {
      unknown <- setdiff(pinned, names(nli_configs))
      if (length(unknown)) {
        stop(sprintf(
          "reports: entry '%s' names unknown scorer_config(s): %s (known: %s)",
          qmd_name, paste(unknown, collapse = ", "),
          paste(names(nli_configs), collapse = ", ")
        ), call. = FALSE)
      }
      if ("granularity" %in% names(grid)) {
        # Pinned AND granularity-expanded: keep only the pairs that agree, so
        # a mismatched pin cannot point a report at another granularity's data.
        keep <- do.call(rbind, lapply(pinned, function(cf) {
          g <- nli_configs[[cf]][["granularity"]]
          rows <- grid[grid$granularity == (g %||% ""), , drop = FALSE]
          if (!nrow(rows)) {
            return(NULL)
          }
          rows$scorer_config <- cf
          rows
        }))
        if (is.null(keep) || !nrow(keep)) {
          stop(sprintf(
            "reports: entry '%s' pins scorer_config(s) %s, but none of them declares any of the requested granularities (%s)",
            qmd_name, paste(pinned, collapse = ", "),
            paste(grid$granularity, collapse = ", ")
          ), call. = FALSE)
        }
        grid <- keep
      } else {
        grid <- expand.grid(
          c(as.list(grid), list(scorer_config = pinned)),
          stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE
        )
      }
    } else {
      if (!"granularity" %in% names(grid)) {
        stop(sprintf(
          "reports: entry '%s' needs an explicit `scorer_config:` (it has no granularity to derive one from)",
          qmd_name
        ), call. = FALSE)
      }
      grid$scorer_config <- nli_config_for_granularity(
        nli_configs, grid$granularity, purpose_config(cfg, "fact_checking")$nli
      )
    }
  }

  grid$.dummy <- NULL


  grid
}

#' Generate the wrapper .qmd files declared by config.yaml's `reports:` section
#'
#' Called from _targets_collection.R's preamble. Idempotent: rewrites nothing when the
#' resulting content is unchanged, and prunes generated wrappers that the
#' current config no longer asks for.
# Writes EVERY entry's wrappers, into whichever directory its `project:`
# names, regardless of which pipeline called it. Called from both
# _targets_reporting.R's preamble (it was called from _targets_training.R's too,
# idempotent (write_if_changed() leaves unchanged bytes alone), so running
# either project leaves both directories correct, and neither can drift behind
# a config edit made while only the other was being run.
generate_report_wrappers <- function(
  config_file = "input/config.yaml",
  dirs = report_project_dirs(),
  quiet = FALSE
) {
  if (!file.exists(config_file)) {
    stop(sprintf("generate_report_wrappers(): no config file at %s", config_file), call. = FALSE)
  }
  cfg <- yaml::read_yaml(config_file)
  entries <- cfg[["reports"]]
  spec_all <- report_wrapper_spec()

  if (is.null(entries) || !length(entries)) {
    stop(sprintf(
      "generate_report_wrappers(): `reports:` section missing or empty in %s",
      config_file
    ), call. = FALSE)
  }

  written <- character()
  expected <- character()

  for (entry in entries) {
    qmd_name <- entry[["qmd_name"]]
    if (is.null(qmd_name) || !nzchar(qmd_name)) {
      stop("reports: every entry needs a `qmd_name:`", call. = FALSE)
    }
    spec <- spec_all[[qmd_name]]
    if (is.null(spec)) {
      stop(sprintf(
        "reports: unknown qmd_name '%s' (known: %s). Add it to report_wrapper_spec() in R/generate_report_wrappers.R.",
        qmd_name, paste(names(spec_all), collapse = ", ")
      ), call. = FALSE)
    }

    project <- entry[["project"]] %||% "reporting"
    if (!project %in% names(dirs)) {
      stop(sprintf(
        "reports: entry '%s' names project '%s'; known projects: %s",
        qmd_name, project, paste(names(dirs), collapse = ", ")
      ), call. = FALSE)
    }
    dir <- dirs[[project]]

    body_include <- paste0("_", qmd_name, "_body.qmd")
    if (!file.exists(file.path(dir, body_include))) {
      stop(sprintf(
        "reports: entry '%s' declares project '%s' but has no shared body at %s",
        qmd_name, project, file.path(dir, body_include)
      ), call. = FALSE)
    }

    title_template <- entry[["title"]]
    if (is.null(title_template) || !nzchar(title_template)) {
      title_template <- qmd_name
    }

    grid <- report_wrapper_combinations(entry, cfg, spec)

    for (i in seq_len(nrow(grid))) {
      p <- as.list(grid[i, , drop = FALSE])
      p <- lapply(p, as.character)
      base <- spec$name(p)
      path <- file.path(dir, paste0(base, ".qmd"))
      expected <- c(expected, path)
      title <- render_title_template(title_template, p)
      lines <- report_wrapper_lines(
        title, body_include, spec$params(p), spec$deps(p)
      )
      if (write_if_changed(path, lines)) {
        written <- c(written, path)
      }
    }
  }

  # Prune: only files carrying the marker, so hand-written sources are safe.
  # Per DIRECTORY, not once over the union -- a single pass keyed on one dir
  # would never visit the other, so a wrapper left behind by an entry that
  # changed project (or was deleted while only the other pipeline was being
  # run) would render forever against targets its project does not have.
  stale <- character()
  for (d in dirs) {
    if (!dir.exists(d)) next
    existing <- list.files(d, pattern = "\\.qmd$", full.names = TRUE)
    generated <- Filter(function(f) {
      any(grepl(report_wrapper_marker, readLines(f, warn = FALSE), fixed = TRUE))
    }, existing)
    stale <- c(stale, setdiff(generated, expected))
  }
  for (s in stale) unlink(s, force = TRUE)

  if (!quiet) {
    message(sprintf(
      "[report wrappers] %d declared, %d written/updated, %d pruned",
      length(expected), length(written), length(stale)
    ))
  }

  invisible(list(expected = expected, written = written, pruned = stale))
}
