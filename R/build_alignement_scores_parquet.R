# Build alignement scores by feeding pre-rendered truth + citing prompts to an
# LLM via ellmer / OpenRouter. Consumes `prompts_truth_parquet` and
# `prompts_citing_parquet`. Relies on automatic prefix caching at the provider
# (OpenAI gpt-4o-mini and similar auto-cache identical prefixes), so the
# (system + truth) portion costs full price once per (KM, BM) and the citing
# suffix is the only variable token cost on subsequent candidates.

expand_alignement_scores_specs <- function(analysis) {
  out <- list()
  runs <- null_or(analysis$runs, list())
  assessment_id <- analysis$assessment_id

  for (run in runs) {
    run_id <- as.character(run$run_id)
    if (!nzchar(trimws(run_id))) {
      stop("Alignment run is missing run_id")
    }
    km_values <- as.character(null_or(run$km, character(0)))
    km_key <- paste(km_values, collapse = "__")

    model_id    <- as.character(run$model)
    temperature <- as.numeric(null_or(run$temperature, 0))
    max_active  <- as.integer(null_or(run$max_active, 2))
    replicates  <- as.integer(null_or(run$replicates, 1))
    n_citing    <- as.integer(null_or(run$n_citing, 0L))
    branch_name <- sanitize_partition_value(
      paste(assessment_id, run_id, sep = "__")
    )

    out[[branch_name]] <- list(
      run_id        = run_id,
      assessment_id = assessment_id,
      km            = km_values,
      km_key        = km_key,
      model_id      = model_id,
      model         = sanitize_partition_value(model_id),
      temperature   = temperature,
      max_active    = max_active,
      replicates    = replicates,
      n_citing      = n_citing
    )
  }

  out
}

build_alignement_scores_run_specs <- function(
  analysis_list,
  assessment,
  prompts_truth_parquet,
  prompts_citing_parquet
) {
  if (is.null(analysis_list) || !length(analysis_list)) {
    stop("No analysis configuration found")
  }

  assessment_ids <- vapply(assessment, `[[`, character(1), "id")
  run_specs <- list()
  seen_run_ids <- character(0)

  prompts_truth_root  <- unique(dirname(prompts_truth_parquet))[[1L]]
  prompts_citing_root <- unique(dirname(prompts_citing_parquet))[[1L]]

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

    branch_specs <- expand_alignement_scores_specs(analysis)
    for (nm in names(branch_specs)) {
      spec <- branch_specs[[nm]]
      if (spec$run_id %in% seen_run_ids) {
        stop("Duplicate alignment run_id: ", spec$run_id)
      }
      seen_run_ids <- c(seen_run_ids, spec$run_id)
      spec$index               <- assessment[[idx]]$index
      spec$prompts_truth_path  <- prompts_truth_root
      spec$prompts_citing_path <- prompts_citing_root
      run_specs[[sanitize_partition_value(paste0(
        analysis$assessment_id, "__", spec$run_id
      ))]] <- spec
    }
  }

  run_specs
}

# Slice the first n citing prompts deterministically by work_id, or take all
# when n == 0.
sample_citing_prompts <- function(prompts_citing_path, assessment_id, km_val,
                                  bm_val, n_citing) {
  ds <- arrow::open_dataset(prompts_citing_path) |>
    dplyr::filter(
      assessment == assessment_id,
      km == km_val,
      bm == bm_val
    ) |>
    dplyr::select(work_id, title, abstract, prompt) |>
    dplyr::arrange(work_id)

  if (n_citing > 0L) {
    ds <- ds |> head(n_citing)
  }
  ds |> dplyr::collect() |> dplyr::mutate(candidate_rank = dplyr::row_number())
}

build_alignement_scores_parquet <- function(
  run_spec,
  system_prompt_file,
  truth_wrapper_file,
  citing_wrapper_file,
  output_root = "output/alignement_scores"
) {
  api_key <- Sys.getenv("API_openrouter")
  if (!nzchar(api_key)) {
    stop("API_openrouter environment variable is required")
  }

  spec <- run_spec
  required_spec <- c(
    "assessment_id", "run_id", "km", "model_id", "model",
    "temperature", "max_active", "replicates", "n_citing",
    "prompts_truth_path", "prompts_citing_path"
  )
  missing <- setdiff(required_spec, names(spec))
  if (length(missing)) {
    stop("Alignment scores run spec is missing: ", paste(missing, collapse = ", "))
  }
  if (!length(spec$km)) {
    stop("Alignment scores run spec is missing km values")
  }

  system_prompt  <- load_text_file(system_prompt_file)
  truth_wrapper  <- load_text_file(truth_wrapper_file)
  citing_wrapper <- load_text_file(citing_wrapper_file)

  branch_dir <- alignement_branch_dir(output_root, spec$assessment_id, spec$run_id)
  if (file.exists(branch_dir)) {
    unlink(branch_dir, recursive = TRUE, force = TRUE)
  }
  dir.create(branch_dir, showWarnings = FALSE, recursive = TRUE)

  truth_rows <- arrow::open_dataset(spec$prompts_truth_path) |>
    dplyr::filter(
      assessment == spec$assessment_id,
      km %in% spec$km
    ) |>
    dplyr::select(km, bm, prompt) |>
    dplyr::collect() |>
    dplyr::arrange(km, bm)

  if (!nrow(truth_rows)) {
    stop(
      "No truth prompts found for assessment ", spec$assessment_id,
      " / km {", paste(spec$km, collapse = ", "), "}"
    )
  }

  fmt_dur <- function(secs) {
    secs <- round(secs)
    if (secs < 60) return(sprintf("%ds", secs))
    sprintf("%dm %02ds", secs %/% 60L, secs %% 60L)
  }

  # Pre-load the candidate sets so we know totals (used for progress + ETA).
  candidate_sets <- vector("list", nrow(truth_rows))
  for (i in seq_len(nrow(truth_rows))) {
    km_val <- truth_rows$km[[i]]
    bm_val <- truth_rows$bm[[i]]
    cands <- sample_citing_prompts(
      spec$prompts_citing_path, spec$assessment_id, km_val, bm_val, spec$n_citing
    )
    candidate_sets[[i]] <- list(
      km = km_val, bm = bm_val,
      truth_prompt = truth_rows$prompt[[i]],
      candidates = cands
    )
  }

  total <- sum(vapply(
    candidate_sets, function(x) nrow(x$candidates), integer(1)
  )) * spec$replicates

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
      km_val       <- km_data$km
      bm_val       <- km_data$bm
      truth_prompt <- km_data$truth_prompt
      candidates   <- km_data$candidates

      n_cands <- nrow(candidates)
      if (!n_cands) {
        message(sprintf(
          "Skip (no candidates): %s / %s / %s",
          spec$assessment_id, km_val, bm_val
        ))
        next
      }

      message(sprintf(
        "Alignment [%s / %s / %s / %s / temp=%s / rep %d/%d]: %d candidates",
        spec$assessment_id, km_val, bm_val, spec$model_id,
        spec$temperature, replicate_id, spec$replicates, n_cands
      ))

      # Build user prompts. The cached prefix per (KM, BM) is:
      #   truth_wrapper + truth_json + citing_wrapper
      # The only variable suffix per call is citing_json. Provider-side
      # automatic prefix caching kicks in on identical prefixes.
      cached_prefix <- paste(truth_wrapper, truth_prompt, citing_wrapper,
                             sep = "\n\n")
      user_prompts <- vapply(
        candidates$prompt,
        function(citing) paste(cached_prefix, citing, sep = "\n\n"),
        character(1),
        USE.NAMES = FALSE
      )

      chunks <- split(seq_len(n_cands), ceiling(seq_len(n_cands) / chunk_size))

      for (chunk_idx in seq_along(chunks)) {
        rows         <- chunks[[chunk_idx]]
        chunk_cands  <- candidates[rows, , drop = FALSE]
        chunk_prompt <- user_prompts[rows]
        chunk_start  <- Sys.time()

        batch_chat <- ellmer::chat_openrouter(
          system_prompt = system_prompt,
          api_key       = api_key,
          model         = spec$model_id,
          params        = list(temperature = spec$temperature),
          echo          = "none"
        )

        message(sprintf(
          "  Chunk %d/%d: %d candidates (max_active=%d)",
          chunk_idx, length(chunks), length(rows), spec$max_active
        ))

        parallel_results <- local({
          op <- options(cli.progress_show_after = Inf)
          on.exit(options(op), add = TRUE)
          tryCatch(
            ellmer::parallel_chat_structured(
              batch_chat, chunk_prompt,
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
          cand <- chunk_cands[j, , drop = FALSE]
          parsed <- NULL
          if (!is.null(parallel_results) && nrow(parallel_results) >= j) {
            row_result <- as.list(parallel_results[j, , drop = FALSE])
            row_result$.error <- NULL
            parsed <- tryCatch(
              validate_alignement_response(
                row_result,
                expected_lm_id   = km_val,
                expected_work_id = cand$work_id[[1]]
              ),
              error = function(e) NULL
            )
          }

          if (is.null(parsed)) {
            fallback <- call_alignement_model(
              prompt           = chunk_prompt[[j]],
              expected_lm_id   = km_val,
              expected_work_id = cand$work_id[[1]],
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
              lm_id           = km_val,
              work_id         = cand$work_id[[1]],
              km_summary      = NA_character_,
              work_alignement = NA_integer_,
              confidence      = NA_real_,
              evidence        = NA_character_,
              justification   = "LLM call failed"
            )
          }

          index <- index + 1L
          message(sprintf("  [%d/%d] %s", index, total, cand$work_id[[1]]))

          chunk_results[[j]] <- dplyr::tibble(
            assessment      = spec$assessment_id,
            run_id          = spec$run_id,
            km              = km_val,
            bm              = bm_val,
            model           = spec$model,
            model_id        = spec$model_id,
            temperature     = spec$temperature,
            replicate       = replicate_id,
            candidate_rank  = cand$candidate_rank[[1]],
            work_id         = cand$work_id[[1]],
            lm_id           = parsed$lm_id,
            km_summary      = parsed$km_summary,
            work_alignement = parsed$work_alignement,
            confidence      = parsed$confidence,
            evidence        = parsed$evidence,
            justification   = parsed$justification,
            title           = cand$title[[1]],
            abstract        = cand$abstract[[1]]
          )
        }

        arrow::write_dataset(
          dataset      = dplyr::bind_rows(chunk_results),
          path         = output_root,
          format       = "parquet",
          partitioning = c("assessment", "run_id", "km", "bm", "model", "replicate"),
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
