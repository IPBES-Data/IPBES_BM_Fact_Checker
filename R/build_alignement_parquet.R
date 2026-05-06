null_or <- function(x, default) {
  if (is.null(x)) default else x
}

normalize_km_id <- function(x) {
  x <- as.character(x)
  x <- trimws(x)
  sub("\\.+$", "", x)
}

load_text_file <- function(path) {
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

render_template <- function(template, replacements) {
  out <- template
  for (nm in names(replacements)) {
    out <- gsub(
      paste0("{{", nm, "}}"),
      replacements[[nm]],
      out,
      fixed = TRUE
    )
  }
  out
}

expand_alignement_specs <- function(analysis) {
  out <- list()
  runs <- null_or(analysis$runs, list())
  assessment_id <- analysis$assessment_id

  for (run in runs) {
    run_id <- as.character(run$run_id)
    if (!nzchar(trimws(run_id))) {
      stop("Alignment run is missing run_id")
    }
    km_values <- run$km
    if (is.null(km_values)) {
      km_values <- character(0)
    }
    km_values <- as.character(km_values)
    km_key <- paste(km_values, collapse = "__")

    model_id <- as.character(run$model)
    temperature <- as.numeric(null_or(run$temperature, 0))
    max_active <- as.integer(null_or(run$max_active, 2))
    replicates <- as.integer(null_or(run$replicates, 1))
    max_works  <- as.integer(null_or(run$max_works, 20L))
    branch_name <- sanitize_partition_value(
      paste(assessment_id, run_id, sep = "__")
    )

    out[[branch_name]] <- list(
      run_id = run_id,
      assessment_id = assessment_id,
      km = km_values,
      km_key = km_key,
      model_id = model_id,
      model = sanitize_partition_value(model_id),
      temperature = temperature,
      max_active = max_active,
      replicates = replicates,
      max_works  = max_works
    )
  }

  out
}

build_alignement_run_specs <- function(
  analysis_list,
  assessment,
  snowball_parquet,
  key_messages_parquet
) {
  if (is.null(analysis_list) || !length(analysis_list)) {
    stop("No analysis configuration found")
  }

  assessment_ids <- vapply(assessment, `[[`, character(1), "id")
  run_specs <- list()
  seen_run_ids <- character(0)

  for (analysis in analysis_list) {
    if (is.null(analysis$assessment_id)) {
      stop("Analysis entry is missing assessment_id")
    }

    idx <- match(analysis$assessment_id, assessment_ids)
    if (is.na(idx)) {
      stop(
        "No assessment entry found for analysis assessment_id ",
        analysis$assessment_id
      )
    }

    branch_specs <- expand_alignement_specs(analysis)
    for (nm in names(branch_specs)) {
      spec <- branch_specs[[nm]]
      if (is.null(spec$run_id)) {
        stop("Alignment run spec is missing run_id")
      }
      if (spec$run_id %in% seen_run_ids) {
        stop("Duplicate alignment run_id: ", spec$run_id)
      }
      seen_run_ids <- c(seen_run_ids, spec$run_id)
      spec$assessment_id <- analysis$assessment_id
      spec$index <- assessment[[idx]]$index
      spec$snowball_nodes_path <- unique(
        dirname(snowball_parquet[grepl("/nodes/", snowball_parquet, fixed = TRUE)])
      )[1L]
      spec$key_messages_path <- unique(dirname(key_messages_parquet))[1L]
      run_specs[[sanitize_partition_value(paste0(
        analysis$assessment_id,
        "__",
        spec$run_id
      ))]] <- spec
    }
  }

  run_specs
}

select_alignement_candidates <- function(
  snowball_nodes_path,
  assessment_id,
  km,
  max_works = 20L,
  keypaper_share = 0.2
) {
  nodes <- arrow::open_dataset(snowball_nodes_path) |>
    dplyr::filter(
      assessment == assessment_id,
      relation %in% c("keypaper", "citing")
    ) |>
    dplyr::select(id, km, doi, title, abstract, relation) |>
    dplyr::collect() |>
    dplyr::distinct(id, .keep_all = TRUE) |>
    dplyr::mutate(km_norm = normalize_km_id(km))

  km_norm <- normalize_km_id(km)
  nodes <- nodes |>
    dplyr::filter(km_norm == !!km_norm) |>
    dplyr::select(-km_norm)

  if (!nrow(nodes)) {
    stop(
      "No snowball candidate works found for assessment ",
      assessment_id,
      " / km ",
      km
    )
  }

  if (max_works <= 0L) {
    return(nodes |> dplyr::mutate(candidate_rank = dplyr::row_number()))
  }

  n_keypaper_target <- as.integer(floor(max_works * keypaper_share))
  n_citing_target <- as.integer(max_works - n_keypaper_target)

  pick_rows <- function(data, n) {
    if (!nrow(data) || n <= 0L) {
      return(data[0, , drop = FALSE])
    }
    data |>
      dplyr::arrange(id) |>
      dplyr::slice_head(n = min(n, nrow(data)))
  }

  keypaper <- nodes |>
    dplyr::filter(relation == "keypaper")
  citing <- nodes |>
    dplyr::filter(relation == "citing")

  selected <- dplyr::bind_rows(
    pick_rows(keypaper, n_keypaper_target),
    pick_rows(citing, n_citing_target)
  )

  if (nrow(selected) < max_works) {
    remainder <- nodes |>
      dplyr::arrange(
        match(relation, c("keypaper", "citing")),
        id
      ) |>
      dplyr::filter(!id %in% selected$id)

    if (nrow(remainder)) {
      selected <- dplyr::bind_rows(
        selected,
        remainder |>
          dplyr::slice_head(
            n = min(max_works - nrow(selected), nrow(remainder))
          )
      )
    }
  }

  selected |>
    dplyr::mutate(
      candidate_rank = dplyr::row_number()
    )
}

get_km_context <- function(key_messages_path, assessment_id, km) {
  km_norm <- normalize_km_id(km)
  key_messages <- arrow::open_dataset(key_messages_path) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, km_label, km_description) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::mutate(km_norm = normalize_km_id(km)) |>
    dplyr::filter(km_norm == !!km_norm)

  if (!nrow(key_messages)) {
    stop(
      "No key message text found for assessment ",
      assessment_id,
      " / km ",
      km
    )
  }

  km_row <- key_messages[1, , drop = FALSE]
  km_label <- if (!is.na(km_row$km_label) && nzchar(km_row$km_label)) {
    km_row$km_label
  } else {
    km
  }
  km_description <- if (
    !is.na(km_row$km_description) && nzchar(km_row$km_description)
  ) {
    km_row$km_description
  } else {
    ""
  }
  parts <- c(km_label, if (nzchar(km_description)) km_description else NULL)
  km_summary <- if (length(parts)) paste(parts, collapse = "\n\n") else km

  list(
    km_id = km,
    km_label_source = km_label,
    km_description_source = if (nzchar(km_description)) {
      km_description
    } else {
      "(not provided)"
    },
    km_summary_source = km_summary
  )
}

call_alignement_model <- function(
  prompt,
  expected_lm_id,
  expected_work_id,
  system_prompt,
  api_key,
  model_id,
  temperature
) {
  attempts <- 2L
  last_error <- NULL

  for (i in seq_len(attempts)) {
    chat <- ellmer::chat_openrouter(
      system_prompt = system_prompt,
      api_key = api_key,
      model = model_id,
      params = list(temperature = temperature),
      echo = "none"
    )
    raw <- tryCatch(
      chat$chat(prompt),
      error = function(e) {
        last_error <<- e
        NULL
      }
    )
    if (is.null(raw)) next

    # Strip optional markdown code fence that some models add
    json_text <- trimws(raw)
    json_text <- sub("^```(?:json)?[[:space:]]*", "", json_text, perl = TRUE)
    json_text <- sub("[[:space:]]*```$",           "", json_text, perl = TRUE)
    json_text <- trimws(json_text)

    response <- tryCatch(
      jsonlite::fromJSON(json_text, simplifyVector = FALSE),
      error = function(e) {
        last_error <<- e
        NULL
      }
    )
    if (is.null(response)) next

    parsed <- tryCatch(
      validate_alignement_response(
        response,
        expected_lm_id   = expected_lm_id,
        expected_work_id = expected_work_id
      ),
      error = function(e) {
        last_error <<- e
        NULL
      }
    )
    if (!is.null(parsed)) {
      return(list(success = TRUE, result = parsed))
    }

    prompt <- paste(
      prompt,
      "",
      "Return a valid JSON object without markdown code fences, matching the requested fields exactly.",
      sep = "\n"
    )
  }

  list(
    success = FALSE,
    error = if (is.null(last_error)) "Structured response failed" else conditionMessage(last_error)
  )
}

validate_alignement_response <- function(
  response,
  expected_lm_id,
  expected_work_id
) {
  if (!is.list(response)) {
    stop("Structured response was not a list")
  }

  required <- c(
    "lm_id",
    "work_id",
    "km_summary",
    "work_alignement",
    "confidence",
    "evidence",
    "justification"
  )
  missing <- setdiff(required, names(response))
  if (length(missing)) {
    stop(
      "Structured response missing fields: ",
      paste(missing, collapse = ", ")
    )
  }

  response$lm_id <- expected_lm_id
  response$work_id <- expected_work_id

  response$km_summary <- as.character(response$km_summary)
  if (
    length(response$km_summary) != 1L ||
      is.na(response$km_summary) ||
      !nzchar(trimws(response$km_summary))
  ) {
    stop("Structured response returned an empty km_summary")
  }

  response$work_alignement <- as.integer(max(
    -5,
    min(5, round(as.numeric(response$work_alignement)))
  ))
  response$confidence <- as.numeric(response$confidence)
  if (length(response$confidence) != 1L || is.na(response$confidence)) {
    stop("Structured response returned an invalid confidence")
  }

  response$evidence <- as.character(response$evidence)
  if (
    length(response$evidence) != 1L ||
      is.na(response$evidence) ||
      !nzchar(trimws(response$evidence))
  ) {
    stop("Structured response returned empty evidence")
  }

  response$justification <- as.character(response$justification)
  if (
    length(response$justification) != 1L ||
      is.na(response$justification) ||
      !nzchar(trimws(response$justification))
  ) {
    stop("Structured response returned empty justification")
  }

  response
}

build_alignement_parquet <- function(
  run_spec,
  system_prompt_file,
  user_prompt_file,
  output_root = "output/alignement",
  keypaper_share = 0.2
) {
  api_key <- Sys.getenv("API_openrouter")
  if (!nzchar(api_key)) {
    stop("API_openrouter environment variable is required")
  }

  system_prompt <- load_text_file(system_prompt_file)
  user_prompt_template <- load_text_file(user_prompt_file)
  spec <- run_spec
  if (is.null(spec$assessment_id)) {
    stop("Alignment run spec is missing assessment_id")
  }
  if (is.null(spec$run_id)) {
    stop("Alignment run spec is missing run_id")
  }
  if (is.null(spec$km)) {
    stop("Alignment run spec is missing km")
  }
  if (is.null(spec$model_id)) {
    stop("Alignment run spec is missing model_id")
  }
  if (is.null(spec$temperature)) {
    stop("Alignment run spec is missing temperature")
  }
  if (is.null(spec$replicates)) {
    stop("Alignment run spec is missing replicates")
  }
  if (is.null(spec$max_active)) {
    stop("Alignment run spec is missing max_active")
  }
  if (is.null(spec$snowball_nodes_path)) {
    stop("Alignment run spec is missing snowball_nodes_path")
  }
  if (is.null(spec$key_messages_path)) {
    stop("Alignment run spec is missing key_messages_path")
  }

  km_values <- as.character(spec$km)
  if (!length(km_values)) {
    stop("Alignment run spec is missing km values")
  }
  branch_dir <- alignement_branch_dir(
    output_root,
    spec$assessment_id,
    spec$run_id
  )
  if (file.exists(branch_dir)) {
    unlink(branch_dir, recursive = TRUE, force = TRUE)
  }
  dir.create(branch_dir, showWarnings = FALSE, recursive = TRUE)

  candidate_sets <- lapply(
    km_values,
    function(km_value) {
      list(
        km = km_value,
        candidates = select_alignement_candidates(
          spec$snowball_nodes_path,
          spec$assessment_id,
          km_value,
          max_works = spec$max_works,
          keypaper_share = keypaper_share
        ),
        km_context = get_km_context(
          spec$key_messages_path,
          spec$assessment_id,
          km_value
        )
      )
    }
  )

  total <- sum(vapply(
    candidate_sets,
    function(x) nrow(x$candidates),
    integer(1)
  )) * spec$replicates

  fmt_dur <- function(secs) {
    secs <- round(secs)
    if (secs < 60) return(sprintf("%ds", secs))
    sprintf("%dm %02ds", secs %/% 60L, secs %% 60L)
  }

  chunk_size <- max(1L, spec$max_active * 10L)

  total_chunks <- sum(vapply(
    candidate_sets,
    function(cs) as.integer(ceiling(nrow(cs$candidates) / chunk_size)),
    integer(1)
  )) * spec$replicates

  chunks_done <- 0L
  run_start   <- Sys.time()
  index       <- 0L

  for (replicate_id in seq_len(spec$replicates)) {
    for (km_data in candidate_sets) {
      km_value   <- km_data$km
      candidates <- km_data$candidates
      km_context <- km_data$km_context

      message(
        "Alignment [",
        spec$assessment_id, " / ", km_value, " / ", spec$model_id,
        " / temp=", spec$temperature,
        " / rep ", replicate_id, "/", spec$replicates,
        "]: ", nrow(candidates), " candidate works"
      )

      prompts <- lapply(
        seq_len(nrow(candidates)),
        function(i) {
          candidate <- candidates[i, , drop = FALSE]
          render_template(
            user_prompt_template,
            replacements = c(
              ASSESSMENT_ID  = spec$assessment_id,
              KM_ID          = km_value,
              KM_LABEL       = km_context$km_label_source,
              KM_DESCRIPTION = km_context$km_description_source,
              WORK_ID        = candidate$id[[1]],
              WORK_TITLE     = candidate$title[[1]],
              WORK_ABSTRACT  = if (is.na(candidate$abstract[[1]])) "" else candidate$abstract[[1]],
              WORK_RELATION  = candidate$relation[[1]]
            )
          )
        }
      )

      n_cands <- nrow(candidates)
      chunks  <- split(seq_len(n_cands), ceiling(seq_len(n_cands) / chunk_size))

      for (chunk_idx in seq_along(chunks)) {
        rows          <- chunks[[chunk_idx]]
        chunk_cands   <- candidates[rows, , drop = FALSE]
        chunk_prompts <- prompts[rows]
        chunk_start   <- Sys.time()

        batch_chat <- ellmer::chat_openrouter(
          system_prompt = system_prompt,
          api_key       = api_key,
          model         = spec$model_id,
          params        = list(temperature = spec$temperature),
          echo          = "none"
        )

        message(sprintf(
          "  Chunk %d/%d: %d works (max_active=%d)",
          chunk_idx, length(chunks), length(rows), spec$max_active
        ))

        parallel_results <- local({
          op <- options(cli.progress_show_after = Inf)
          on.exit(options(op), add = TRUE)
          tryCatch(
            ellmer::parallel_chat_structured(
              batch_chat, chunk_prompts,
              type       = alignement_output_type(),
              convert    = TRUE,
              max_active = spec$max_active
            ),
            error = function(e) {
              message("  parallel_chat_structured failed: ", conditionMessage(e))
              NULL
            }
          )
        })

        chunk_results <- vector("list", length(rows))
        for (j in seq_along(rows)) {
          candidate  <- chunk_cands[j, , drop = FALSE]
          item_start <- Sys.time()

          parsed <- NULL
          if (!is.null(parallel_results) && nrow(parallel_results) >= j) {
            row_result <- as.list(parallel_results[j, , drop = FALSE])
            row_result$.error <- NULL
            parsed <- tryCatch(
              validate_alignement_response(
                row_result,
                expected_lm_id   = km_value,
                expected_work_id = candidate$id[[1]]
              ),
              error = function(e) NULL
            )
          }

          if (is.null(parsed)) {
            fallback <- call_alignement_model(
              prompt           = chunk_prompts[[j]],
              expected_lm_id   = km_value,
              expected_work_id = candidate$id[[1]],
              system_prompt    = system_prompt,
              api_key          = api_key,
              model_id         = spec$model_id,
              temperature      = spec$temperature
            )
            if (isTRUE(fallback$success)) {
              parsed <- fallback$result
            } else {
              message("    failed: ", fallback$error)
            }
          }

          if (is.null(parsed)) {
            parsed <- list(
              lm_id           = km_value,
              work_id         = candidate$id[[1]],
              km_summary      = NA_character_,
              work_alignement = NA_integer_,
              confidence      = NA_real_,
              evidence        = NA_character_,
              justification   = "Summarising KM failed"
            )
          }

          item_dur <- as.numeric(difftime(Sys.time(), item_start, units = "secs"))
          index <- index + 1L
          message(sprintf("  [%d/%d] %s (%.1fs)", index, total, candidate$id[[1]], item_dur))

          chunk_results[[j]] <- dplyr::tibble(
            assessment      = spec$assessment_id,
            run_id          = spec$run_id,
            km              = km_value,
            relation        = candidate$relation[[1]],
            model           = spec$model,
            model_id        = spec$model_id,
            temperature     = spec$temperature,
            replicate       = replicate_id,
            candidate_rank  = candidate$candidate_rank[[1]],
            lm_id           = parsed$lm_id,
            work_id         = parsed$work_id,
            km_summary      = parsed$km_summary,
            work_alignement = parsed$work_alignement,
            confidence      = parsed$confidence,
            evidence        = parsed$evidence,
            justification   = parsed$justification,
            title           = candidate$title[[1]],
            abstract        = candidate$abstract[[1]]
          )
        }

        arrow::write_dataset(
          dataset      = dplyr::bind_rows(chunk_results),
          path         = output_root,
          format       = "parquet",
          partitioning = c("assessment", "run_id", "km", "model", "relation", "replicate"),
          existing_data_behavior = "overwrite"
        )

        chunks_done   <- chunks_done + 1L
        chunk_elapsed <- as.numeric(difftime(Sys.time(), chunk_start, units = "secs"))
        run_elapsed   <- as.numeric(difftime(Sys.time(), run_start,   units = "secs"))
        avg_chunk     <- run_elapsed / chunks_done
        eta           <- avg_chunk * (total_chunks - chunks_done)
        message(sprintf(
          "  Chunk done: %s | elapsed %s | %d/%d chunks | ETA %s",
          fmt_dur(chunk_elapsed), fmt_dur(run_elapsed),
          chunks_done, total_chunks,
          if (chunks_done < total_chunks) fmt_dur(eta) else "—"
        ))
      }
    }
  }

  branch_dir
}
