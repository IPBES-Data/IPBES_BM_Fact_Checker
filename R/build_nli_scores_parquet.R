# NLI alignement scoring (the "NLI approach", TD_BM NLI approach.md).
#
# Consumes `nli_ready_parquet` — one row per (citing work × BM sentence), with
# columns: km, bm, sentence_number, sentence_source, claim, work_id, premise,
# abstract_tokens, sentence_tokens, approx_tokens.
#
# For each (km, bm) partition, groups by (sentence_number, claim) so all
# premises for a given claim are POSTed in one HTTP request — restoring the
# batch efficiency of the original BM-level approach while keeping short
# sentence-level hypotheses.
#
# Rows where approx_tokens > max_length are skipped and logged.  The skipped
# rows are NOT scored (no truncation, no summarisation).  See NEXT_STEPS.md for
# the planned chunking approach that will handle them without truncation.

# Small config accessor: config[[key]] or a default when absent / NULL / "".
nli_cfg_get <- function(cfg, key, default) {
  v <- cfg[[key]]
  if (is.null(v)) return(default)
  if (is.character(v) && length(v) == 1L && !nzchar(v)) return(default)
  v
}

# Build the base /classify URL. `port: null` (or absent) → scheme://host with no
# :port, which is what the RunPod HTTPS proxy expects
# (https://<pod>-8080.proxy.runpod.net). A numeric port → scheme://host:port.
nli_classify_url <- function(cfg) {
  scheme <- nli_cfg_get(cfg, "scheme", "https")
  host   <- nli_cfg_get(cfg, "host", NULL)
  if (is.null(host)) {
    stop("nli config is missing `host` (set it to the running pod's hostname)")
  }
  port <- cfg[["port"]]
  if (is.null(port) || (is.character(port) && !nzchar(port))) {
    sprintf("%s://%s", scheme, host)
  } else {
    sprintf("%s://%s:%d", scheme, host, as.integer(port))
  }
}

# GET /health from the NLI server. Returns the parsed body (status, model,
# device, dtype, ...) or stops with a clear error if the server is unreachable.
nli_health <- function(base_url, auth_token = NULL) {
  req <- httr2::request(base_url) |>
    httr2::req_url_path_append("health") |>
    httr2::req_retry(max_tries = 3, backoff = ~ 5) |>
    httr2::req_timeout(30)
  if (!is.null(auth_token) && nzchar(auth_token)) {
    req <- httr2::req_auth_bearer_token(req, auth_token)
  }
  tryCatch(
    httr2::resp_body_json(httr2::req_perform(req)),
    error = function(e) stop(sprintf(
      "NLI server health check failed at %s/health: %s",
      base_url, conditionMessage(e)
    ))
  )
}

# POST one batch of premises against a single hypothesis template. Returns a list
# (one element per sequence) of named numeric vectors keyed by candidate label.
nli_classify_request <- function(base_url, sequences, candidate_labels,
                                  hypothesis_template, multi_label, batch_size,
                                  max_length = NULL, auth_token = NULL) {
  body <- list(
    sequences           = as.list(sequences),
    candidate_labels    = as.list(candidate_labels),
    hypothesis_template = hypothesis_template,
    multi_label         = isTRUE(multi_label),
    batch_size          = as.integer(batch_size)
  )
  if (!is.null(max_length)) {
    body$max_length <- as.integer(max_length)
  }

  req <- httr2::request(base_url) |>
    httr2::req_url_path_append("classify") |>
    httr2::req_body_json(body) |>
    httr2::req_retry(max_tries = 3, backoff = ~ 5) |>
    httr2::req_timeout(600)

  if (!is.null(auth_token) && nzchar(auth_token)) {
    req <- httr2::req_auth_bearer_token(req, auth_token)
  }

  resp <- httr2::resp_body_json(httr2::req_perform(req))

  if (!is.null(resp$labels) && !is.null(resp$scores)) {
    resp <- list(resp)
  }

  lapply(resp, function(r) {
    stats::setNames(
      as.numeric(unlist(r$scores)),
      as.character(unlist(r$labels))
    )
  })
}

build_nli_scores_parquet <- function(
  assessment,
  nli_ready_parquet,
  nli_config,
  nli_active,
  output_root = "output/nli_scores"
) {
  assessment_id <- assessment$id
  cfg <- if (is.null(nli_config)) list() else nli_config
  now <- function() format(Sys.time(), "%H:%M:%S")

  candidate_labels <- as.character(nli_cfg_get(
    cfg, "candidate_labels", c("supports", "refutes", "is not relevant to")
  ))
  if (length(candidate_labels) != 3L) {
    stop("nli config `candidate_labels` must have exactly 3 entries ",
         "(supports, refutes, not-relevant); got ", length(candidate_labels))
  }
  lab_supports <- candidate_labels[[1L]]
  lab_refutes  <- candidate_labels[[2L]]
  lab_nei      <- candidate_labels[[3L]]

  template_fmt        <- nli_cfg_get(cfg, "hypothesis_template",
                                     "This paper {} the following claim: %s")
  batch_size          <- as.integer(nli_cfg_get(cfg, "batch_size", 32L))
  http_chunk          <- as.integer(nli_cfg_get(cfg, "http_chunk", 256L))
  multi_label         <- isTRUE(nli_cfg_get(cfg, "multi_label", FALSE))
  uncertain_threshold <- as.numeric(nli_cfg_get(cfg, "uncertain_threshold", 0.60))
  max_length          <- nli_cfg_get(cfg, "max_length", NULL)
  if (!is.null(max_length)) max_length <- as.integer(max_length)

  base_url <- nli_classify_url(cfg)
  auth_token <- NULL
  token_entry <- cfg[["auth_token_keyring"]]
  if (!is.null(token_entry) && is.character(token_entry) && nzchar(token_entry)) {
    auth_token <- tryCatch(
      keyring::key_get(token_entry),
      error = function(e) stop(sprintf(
        "Could not read NLI auth token from keyring entry '%s': %s",
        token_entry, conditionMessage(e)
      ))
    )
  }

  health <- nli_health(base_url, auth_token)
  model_actual <- as.character(health[["model"]] %||% NA_character_)
  message(sprintf(
    "[NLI %s] %s server: model=%s dtype=%s device=%s max_length=%s",
    assessment_id, now(), model_actual,
    health[["dtype"]] %||% "?", health[["device"]] %||% "?",
    health[["max_length"]] %||% "(server default)"
  ))
  model_label <- cfg[["model"]]
  if (!is.null(model_label) && nzchar(model_label) &&
        !is.na(model_actual) && !identical(model_label, model_actual)) {
    warning(sprintf(
      "[NLI %s] config model label '%s' != server model '%s' — recording server model",
      assessment_id, model_label, model_actual
    ))
  }

  output_path <- file.path(
    output_root,
    paste0("nli_config=", nli_active),
    paste0("assessment=", assessment_id)
  )
  dir.create(output_path, recursive = TRUE, showWarnings = FALSE)

  # Identity of one scored pair. Includes `claim` so that if a BM's text changes
  # (different sentence for the same sentence_number) the pair is re-scored;
  # sentence_source disambiguates BMs that contribute both a description and a
  # label sentence at the same sentence_number. (A change to the abstract alone,
  # for an unchanged work_id, is not detected — see NEXT_STEPS.md.)
  score_key <- function(df) {
    paste(
      df$km, df$bm, df$sentence_number, df$sentence_source, df$work_id, df$claim,
      sep = ""
    )
  }

  # Read nli_ready for this assessment (already has premise + approx_tokens).
  ready <- arrow::open_dataset(nli_ready_parquet) |>
    dplyr::collect()

  if (!nrow(ready)) {
    message(sprintf("[NLI %s] nli_ready is empty — nothing to score", assessment_id))
    return(output_path)
  }

  # Skip rows where the (premise, claim) pair exceeds max_length tokens.
  # These are NOT scored.  See NEXT_STEPS.md for the planned chunking approach.
  filter_limit <- if (!is.null(max_length)) max_length else 512L
  n_total   <- nrow(ready)
  ready     <- ready[ready$approx_tokens <= filter_limit, , drop = FALSE]
  n_skipped <- n_total - nrow(ready)
  if (n_skipped > 0L) {
    message(sprintf(
      "[NLI %s] %s skipping %d/%d rows (approx_tokens > %d) — see NEXT_STEPS.md",
      assessment_id, now(), n_skipped, n_total, filter_limit
    ))
  }
  if (!nrow(ready)) {
    message(sprintf("[NLI %s] all rows skipped — nothing to score", assessment_id))
    return(output_path)
  }

  # Resume: drop pairs already scored in a previous run. Existing output for this
  # (nli_config, assessment) is preserved; only new pairs are computed and
  # appended (unique basename_template below prevents clobbering old files).
  scored_files <- list.files(
    output_path, pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE
  )
  if (length(scored_files)) {
    existing_keys <- arrow::open_dataset(output_path) |>
      dplyr::select(km, bm, sentence_number, sentence_source, work_id, claim) |>
      dplyr::collect() |>
      score_key()
    n_before <- nrow(ready)
    ready    <- ready[!(score_key(ready) %in% existing_keys), , drop = FALSE]
    n_cached <- n_before - nrow(ready)
    if (n_cached > 0L) {
      message(sprintf(
        "[NLI %s] %s resuming: %d/%d pairs already scored — skipping",
        assessment_id, now(), n_cached, n_before
      ))
    }
    if (!nrow(ready)) {
      message(sprintf("[NLI %s] nothing new to score", assessment_id))
      return(output_path)
    }
  }

  # Unique per-run filename stem so appended files never clobber earlier runs'.
  run_token <- paste0(format(Sys.time(), "%Y%m%d%H%M%S"), "-", Sys.getpid())

  pick <- function(sc, lab) {
    v <- sc[[lab]]
    if (is.null(v) || is.na(v)) NA_real_ else as.numeric(v)
  }
  label_levels <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")

  km_bm <- ready |>
    dplyr::select(km, bm) |>
    dplyr::distinct()

  wrote_any <- FALSE

  for (i in seq_len(nrow(km_bm))) {
    km_val <- km_bm$km[[i]]
    bm_val <- km_bm$bm[[i]]

    part <- ready[ready$km == km_val & ready$bm == bm_val, , drop = FALSE]

    # Unique claims in this partition, ordered by sentence_number.
    claim_groups <- part |>
      dplyr::select(sentence_number, sentence_source, claim) |>
      dplyr::distinct() |>
      dplyr::arrange(sentence_number)

    n_claims <- nrow(claim_groups)
    n_works  <- length(unique(part$work_id))
    message(sprintf(
      "[NLI %s] %s km=%s / bm=%s: %d claim(s) × %d work(s) = %d pair(s)",
      assessment_id, now(), km_val, bm_val, n_claims, n_works, nrow(part)
    ))

    result_rows <- vector("list", n_claims)

    for (j in seq_len(n_claims)) {
      cg         <- claim_groups[j, ]
      claim_text <- cg$claim
      claim_safe <- gsub("\\{", "{{", gsub("\\}", "}}", claim_text))
      hyp_tmpl_j <- sprintf(template_fmt, claim_safe)

      # Filter on BOTH sentence_number and sentence_source: a BM with both a
      # description and a label contributes two sources whose sentence_numbers
      # overlap, so number alone would mix premises across sources.
      cw <- part[
        part$sentence_number == cg$sentence_number &
          part$sentence_source == cg$sentence_source, ,
        drop = FALSE
      ]
      premises <- cw$premise

      # Send premises in HTTP-sized chunks; model batches internally at batch_size.
      chunks   <- split(
        seq_along(premises),
        ceiling(seq_along(premises) / max(1L, http_chunk))
      )
      n_chunks    <- length(chunks)
      scores_list <- vector("list", length(premises))

      for (chunk_i in seq_along(chunks)) {
        idx <- chunks[[chunk_i]]
        message(sprintf(
          "[NLI %s] %s km=%s / bm=%s claim %d/%d: chunk %d/%d (%d works)",
          assessment_id, now(), km_val, bm_val, j, n_claims,
          chunk_i, n_chunks, length(idx)
        ))
        res <- nli_classify_request(
          base_url            = base_url,
          sequences           = premises[idx],
          candidate_labels    = candidate_labels,
          hypothesis_template = hyp_tmpl_j,
          multi_label         = multi_label,
          batch_size          = batch_size,
          max_length          = max_length,
          auth_token          = auth_token
        )
        if (length(res) != length(idx)) {
          stop(sprintf(
            "NLI server returned %d results for %d sequences (km=%s/bm=%s/claim=%d)",
            length(res), length(idx), km_val, bm_val, cg$sentence_number
          ))
        }
        scores_list[idx] <- res
      }

      p_supports <- vapply(scores_list, pick, numeric(1), lab_supports)
      p_refutes  <- vapply(scores_list, pick, numeric(1), lab_refutes)
      p_nei      <- vapply(scores_list, pick, numeric(1), lab_nei)

      probs  <- cbind(p_supports, p_refutes, p_nei)
      argmax <- apply(probs, 1L, function(r) {
        if (all(is.na(r))) NA_integer_ else which.max(r)
      })
      label      <- ifelse(is.na(argmax), NA_character_, label_levels[argmax])
      confidence <- apply(probs, 1L, function(r) {
        if (all(is.na(r))) NA_real_ else max(r, na.rm = TRUE)
      })

      result_rows[[j]] <- dplyr::tibble(
        nli_config      = nli_active,
        nli_model       = model_actual,
        assessment      = assessment_id,
        km              = km_val,
        bm              = bm_val,
        sentence_number = cg$sentence_number,
        sentence_source = cg$sentence_source,
        claim           = claim_text,
        work_id         = cw$work_id,
        label           = label,
        p_supports      = p_supports,
        p_refutes       = p_refutes,
        p_nei           = p_nei,
        confidence      = confidence,
        uncertain       = !is.na(confidence) & confidence < uncertain_threshold
      )
    }

    out <- dplyr::bind_rows(result_rows)

    # existing_data_behavior = "overwrite" only overwrites files with matching
    # names; the unique run_token stem means appended files never collide with
    # earlier runs', so previously-scored pairs in this partition are preserved.
    arrow::write_dataset(
      dataset                = out,
      path                   = output_root,
      format                 = "parquet",
      partitioning           = c("nli_config", "assessment", "km", "bm"),
      basename_template       = paste0("part-", run_token, "-", i, "-{i}.parquet"),
      existing_data_behavior = "overwrite"
    )
    wrote_any <- TRUE
    rm(part, out)
  }

  if (!wrote_any) {
    message(sprintf("[NLI %s] no partitions scored", assessment_id))
  }

  output_path
}
