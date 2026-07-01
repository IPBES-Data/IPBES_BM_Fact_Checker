# NLI alignement scoring (the "NLI approach", TD_BM NLI approach.md).
#
# Consumes `nli_ready_parquet` — one row per (citing work × BM sentence), with
# columns: km, bm, sentence_number, sentence_source, claim, work_id, premise,
# abstract_tokens, sentence_tokens, approx_tokens.
#
# Scoring is parallelized across a POOL of NLI server hosts (config `host:` can
# be a single hostname or a list). The unit of work distribution is the CLAIM
# — (km, bm, sentence_source, sentence_number) — not the BM: a single claim
# already represents substantial GPU work (thousands of premises), and BMs
# vary ~130x in size, so BM-level splitting would let one giant BM cap the
# achievable speedup regardless of pool size. Claims are assigned to hosts via
# greedy LPT (longest processing time first): sort by remaining pair count
# descending, assign each to the currently least-loaded host. Output is
# hive-partitioned by nli_config/assessment/km/bm/claim_id, one claim_id per
# (sentence_source, sentence_number) pair.
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

# Normalize cfg$host to a character vector of 1+ hostnames ("a pool of 1" for
# single-host configs). yaml::read_yaml() parses a YAML flow-style list as an
# R list, not an atomic vector, so unlist() first. This is the only place
# cfg$host should be read directly — everything else goes through this.
nli_hosts <- function(cfg) {
  host <- nli_cfg_get(cfg, "host", NULL)
  if (is.null(host)) {
    stop("nli config is missing `host` (a hostname, or a list of hostnames for a pool)")
  }
  host <- unlist(host, use.names = FALSE)
  host <- as.character(host)
  host <- host[nzchar(host)]
  if (!length(host)) {
    stop("nli config `host` resolved to zero non-empty hostnames")
  }
  host
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

  # Pool of 1+ NLI server hosts. base_urls is index-aligned with hosts; each
  # is built via a synthetic single-host cfg so nli_classify_url() itself
  # never needs to know about pools.
  hosts <- nli_hosts(cfg)
  n_hosts <- length(hosts)
  base_urls <- vapply(hosts, function(h) {
    cfg_h <- cfg
    cfg_h$host <- h
    nli_classify_url(cfg_h)
  }, character(1L))

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

  # Health-check every host up front. Collect ALL failures before stopping so
  # a broken pool is diagnosed in one shot, not host-by-host. A bad host must
  # never be silently dropped — that would leave its assigned claims unscored
  # with no clear signal why.
  health_results <- lapply(seq_along(hosts), function(k) {
    tryCatch(
      list(ok = TRUE, host = hosts[[k]], health = nli_health(base_urls[[k]], auth_token)),
      error = function(e) list(ok = FALSE, host = hosts[[k]], error = conditionMessage(e))
    )
  })
  failed <- Filter(function(r) !r$ok, health_results)
  if (length(failed)) {
    stop(sprintf(
      "[NLI %s] %d/%d pool host(s) failed health check:\n%s",
      assessment_id, length(failed), length(hosts),
      paste(sprintf("  - %s: %s",
                     vapply(failed, `[[`, character(1), "host"),
                     vapply(failed, `[[`, character(1), "error")),
            collapse = "\n")
    ))
  }

  for (k in seq_along(hosts)) {
    h <- health_results[[k]]$health
    message(sprintf(
      "[NLI %s pool=%d/%d] %s server: model=%s dtype=%s device=%s max_length=%s",
      assessment_id, k, n_hosts, now(), h[["model"]] %||% "?",
      h[["dtype"]] %||% "?", h[["device"]] %||% "?",
      h[["max_length"]] %||% "(server default)"
    ))
  }

  # A pool scoring with genuinely different models per host would silently
  # corrupt result provenance (one nli_model value stamped on rows actually
  # produced by two different models) — stop, don't warn.
  models_seen <- vapply(health_results, function(r) {
    as.character(r$health[["model"]] %||% NA_character_)
  }, character(1))
  if (length(unique(stats::na.omit(models_seen))) > 1L) {
    stop(sprintf(
      "[NLI %s] pool hosts report different models — results would not be homogeneous: %s",
      assessment_id,
      paste(sprintf("%s=%s", hosts, models_seen), collapse = ", ")
    ))
  }
  model_actual <- unique(stats::na.omit(models_seen))
  model_actual <- if (length(model_actual)) model_actual[[1L]] else NA_character_

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
      sep = ""
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

  # Unique per-run filename stem. Computed once in the PARENT, before forking
  # below — it is therefore textually IDENTICAL across all pool workers (they
  # inherit the parent's PID via copy-on-write fork), so it disambiguates
  # across separate pipeline runs, not across hosts within one run. host_idx
  # (added to basename_template further down) is what disambiguates hosts;
  # claim_id-level directory partitioning makes cross-host collisions
  # structurally impossible regardless.
  run_token <- paste0(format(Sys.time(), "%Y%m%d%H%M%S"), "-", Sys.getpid())

  pick <- function(sc, lab) {
    v <- sc[[lab]]
    if (is.null(v) || is.na(v)) NA_real_ else as.numeric(v)
  }
  label_levels <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")

  # Unit of work distribution is the CLAIM, not the BM: a BM's claims vary
  # widely in size and a single claim already represents substantial GPU
  # work, so BM-level splitting would let one giant BM cap achievable
  # speedup. claim_id disambiguates bm_description vs bm_label sentences
  # that share the same sentence_number within one BM.
  claim_counts <- ready |>
    dplyr::mutate(claim_id = sprintf("%s-%02d", sentence_source, sentence_number)) |>
    dplyr::count(km, bm, sentence_number, sentence_source, claim, claim_id, name = "n_pairs") |>
    dplyr::arrange(dplyr::desc(n_pairs))

  # Greedy LPT (longest processing time first): sort claims descending by
  # remaining pair count (done above), assign each to whichever host
  # currently has the smallest cumulative assigned load. Computed on `ready`
  # AFTER both filters above, so balancing reflects remaining work only.
  host_load <- rep(0L, n_hosts)
  assigned_host_idx <- integer(nrow(claim_counts))
  for (i in seq_len(nrow(claim_counts))) {
    h <- which.min(host_load)
    assigned_host_idx[[i]] <- h
    host_load[[h]] <- host_load[[h]] + claim_counts$n_pairs[[i]]
  }
  claim_counts$host_idx <- assigned_host_idx

  host_assignments <- lapply(seq_len(n_hosts), function(h) {
    claim_counts[
      claim_counts$host_idx == h,
      c("km", "bm", "sentence_number", "sentence_source", "claim", "claim_id", "n_pairs"),
      drop = FALSE
    ]
  })

  message(sprintf(
    "[NLI %s] %s LPT split: %d claim-unit(s), %d pair(s) total, across %d host(s): %s",
    assessment_id, now(), nrow(claim_counts), sum(claim_counts$n_pairs), n_hosts,
    paste(sprintf("host%d=%dpairs(%dclaims)", seq_len(n_hosts),
                   vapply(host_assignments, function(a) sum(a$n_pairs), numeric(1)),
                   vapply(host_assignments, nrow, integer(1))),
          collapse = ", ")
  ))

  score_one_host <- function(host_idx) {
    base_url    <- base_urls[[host_idx]]
    claims_host <- host_assignments[[host_idx]]
    pool_tag    <- sprintf("pool=%d/%d", host_idx, n_hosts)

    if (!nrow(claims_host)) {
      message(sprintf("[NLI %s %s] no claims assigned — idle", assessment_id, pool_tag))
      return(FALSE)
    }

    wrote_any_host <- FALSE

    for (i in seq_len(nrow(claims_host))) {
      cg <- claims_host[i, ]
      claim_text <- cg$claim
      claim_safe <- gsub("\\{", "{{", gsub("\\}", "}}", claim_text))
      hyp_tmpl_i <- sprintf(template_fmt, claim_safe)

      cw <- ready[
        ready$km == cg$km & ready$bm == cg$bm &
          ready$sentence_number == cg$sentence_number &
          ready$sentence_source == cg$sentence_source, ,
        drop = FALSE
      ]
      premises <- cw$premise

      chunks <- split(
        seq_along(premises),
        ceiling(seq_along(premises) / max(1L, http_chunk))
      )
      n_chunks    <- length(chunks)
      scores_list <- vector("list", length(premises))

      for (chunk_i in seq_along(chunks)) {
        idx <- chunks[[chunk_i]]
        message(sprintf(
          "[NLI %s %s] km=%s / bm=%s / claim_id=%s: chunk %d/%d (%d works)",
          assessment_id, pool_tag, cg$km, cg$bm, cg$claim_id,
          chunk_i, n_chunks, length(idx)
        ))
        res <- nli_classify_request(
          base_url            = base_url,
          sequences           = premises[idx],
          candidate_labels    = candidate_labels,
          hypothesis_template = hyp_tmpl_i,
          multi_label         = multi_label,
          batch_size          = batch_size,
          max_length          = max_length,
          auth_token          = auth_token
        )
        if (length(res) != length(idx)) {
          stop(sprintf(
            "NLI server returned %d results for %d sequences (km=%s/bm=%s/claim_id=%s)",
            length(res), length(idx), cg$km, cg$bm, cg$claim_id
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

      out <- dplyr::tibble(
        nli_config      = nli_active,
        nli_model       = model_actual,
        assessment      = assessment_id,
        km              = cg$km,
        bm              = cg$bm,
        claim_id        = cg$claim_id,
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

      # existing_data_behavior = "overwrite" only overwrites files with matching
      # names. run_token (parent-inherited, identical across pool workers) plus
      # host_idx plus the within-host index i plus Arrow's own {i} placeholder
      # guarantee no two writes — same run or different, same host or not —
      # ever produce colliding filenames; directory-level partitioning by
      # claim_id makes cross-host collisions structurally impossible regardless.
      arrow::write_dataset(
        dataset                = out,
        path                   = output_root,
        format                 = "parquet",
        partitioning           = c("nli_config", "assessment", "km", "bm", "claim_id"),
        basename_template       = paste0("part-", run_token, "-", host_idx, "-", i, "-{i}.parquet"),
        existing_data_behavior = "overwrite"
      )
      wrote_any_host <- TRUE
      rm(cw, out)
    }

    wrote_any_host
  }

  results <- parallel::mclapply(seq_len(n_hosts), score_one_host, mc.cores = n_hosts)

  # mclapply forks even at mc.cores = 1 and does NOT propagate a child's error
  # to the parent by default — it returns a "try-error"-classed object in that
  # slot instead of raising. Without this check, a silently-failed host would
  # be indistinguishable from a host that legitimately scored zero rows.
  failed_idx <- which(vapply(results, function(r) inherits(r, "try-error"), logical(1)))
  if (length(failed_idx)) {
    stop(sprintf(
      "[NLI %s] %d/%d pool host(s) errored during scoring:\n%s",
      assessment_id, length(failed_idx), n_hosts,
      paste(sprintf("  - pool=%d/%d: %s", failed_idx, n_hosts,
                     vapply(results[failed_idx], conditionMessage, character(1))),
            collapse = "\n")
    ))
  }

  wrote_any <- any(unlist(results))
  if (!wrote_any) {
    message(sprintf("[NLI %s] no claims scored", assessment_id))
  }

  output_path
}
