# NLI alignement scoring (the "NLI approach", TD_BM NLI approach.md).
#
# For each citing work, classify the (premise, hypothesis) pair against the BM
# under whose km/bm partition the work sits:
#   premise    = clean(title) + " " + clean(abstract)   (the paper)
#   hypothesis = bm_description                          (the IPBES claim)
# into SUPPORTS / REFUTES / NOT_ENOUGH_INFO using a zero-shot NLI model served
# over HTTP (see docker/nli-runpod/). No retrieval/embedding pre-filter — the
# model's own probabilities are the filter (stored in full; see below).
#
# Initial scope: each work is scored only against its own partition BM. The full
# BM x works cross-join described in the design doc can be layered on later by
# looping bm_lookup over every BM instead of selecting the matching one.
#
# Consumes the BG message DB (key_messages_parquet: km, bm, bm_description) and
# the citing works DB (works_citing_parquet: id, doi, title, abstract,
# publication_year), both partitioned by assessment.

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

# POST one batch of premises against a single hypothesis template. Returns a list
# (one element per sequence) of named numeric vectors keyed by candidate label.
nli_classify_request <- function(base_url, sequences, candidate_labels,
                                  hypothesis_template, multi_label, batch_size,
                                  auth_token = NULL) {
  req <- httr2::request(base_url) |>
    httr2::req_url_path_append("classify") |>
    httr2::req_body_json(list(
      sequences           = as.list(sequences),
      candidate_labels    = as.list(candidate_labels),
      hypothesis_template = hypothesis_template,
      multi_label         = isTRUE(multi_label),
      batch_size          = as.integer(batch_size)
    )) |>
    httr2::req_retry(max_tries = 3, backoff = ~ 5) |>
    httr2::req_timeout(600)

  if (!is.null(auth_token) && nzchar(auth_token)) {
    req <- httr2::req_auth_bearer_token(req, auth_token)
  }

  resp <- httr2::resp_body_json(httr2::req_perform(req))

  # The server returns either a single {labels, scores} object (one sequence) or
  # a list of them. Normalise to a list-of-objects.
  if (!is.null(resp$labels) && !is.null(resp$scores)) {
    resp <- list(resp)
  }

  lapply(resp, function(r) {
    sc <- stats::setNames(
      as.numeric(unlist(r$scores)),
      as.character(unlist(r$labels))
    )
    sc
  })
}

build_nli_scores_parquet <- function(
  assessment,
  key_messages_parquet,
  works_citing_parquet,
  nli_config,
  nli_active,
  output_root = "output/nli_scores"
) {
  assessment_id <- assessment$id
  cfg <- if (is.null(nli_config)) list() else nli_config

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

  output_path <- file.path(
    output_root,
    paste0("nli_config=", nli_active),
    paste0("assessment=", assessment_id)
  )
  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, recursive = TRUE, showWarnings = FALSE)

  # BM hypotheses for this assessment.
  km_root <- unique(dirname(key_messages_parquet))[[1L]]
  bm_lookup <- arrow::open_dataset(km_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, bm, bm_description) |>
    dplyr::distinct() |>
    dplyr::collect()
  bm_lookup <- bm_lookup[!is.na(bm_lookup$bm_description) &
                           nzchar(bm_lookup$bm_description), , drop = FALSE]

  scalar_cols <- c("id", "doi", "title", "abstract", "publication_year")
  km_dirs <- list.dirs(works_citing_parquet, recursive = FALSE)
  wrote_any <- FALSE

  for (km_dir in km_dirs) {
    km_val <- sub("^km=", "", basename(km_dir))
    bm_dirs <- list.dirs(km_dir, recursive = FALSE)
    for (bm_dir in bm_dirs) {
      bm_val <- sub("^bm=", "", basename(bm_dir))

      # Hypothesis for this partition's BM.
      hyp_row <- bm_lookup[bm_lookup$km == km_val & bm_lookup$bm == bm_val, ,
                           drop = FALSE]
      if (!nrow(hyp_row)) {
        message(sprintf("[NLI %s] no bm_description for km=%s / bm=%s — skipping",
                        assessment_id, km_val, bm_val))
        next
      }
      bm_description <- hyp_row$bm_description[[1L]]
      hypothesis_template <- sprintf(template_fmt, bm_description)

      files <- list.files(bm_dir, pattern = "\\.parquet$", full.names = TRUE)
      if (!length(files)) next

      partition <- dplyr::bind_rows(lapply(files, function(f) {
        arrow::read_parquet(f) |>
          dplyr::select(dplyr::any_of(scalar_cols))
      }))
      if (!nrow(partition)) next

      for (mc in setdiff(scalar_cols, names(partition))) {
        partition[[mc]] <- NA
      }
      partition <- partition |>
        dplyr::mutate(
          dplyr::across(
            dplyr::any_of(c("id", "doi", "title", "abstract")), as.character
          ),
          publication_year = suppressWarnings(as.integer(publication_year))
        ) |>
        dplyr::rename(work_id = id)

      # Premise = cleaned title + abstract. Drop works without a usable abstract
      # (NLI on a bare title is unreliable; the doc concatenates title+abstract).
      title_clean    <- vapply(partition$title,    clean_title,    character(1))
      abstract_clean <- vapply(partition$abstract, clean_abstract, character(1))
      keep <- !is.na(abstract_clean)
      if (!any(keep)) {
        message(sprintf("[NLI %s] km=%s / bm=%s: no abstracts — skipping",
                        assessment_id, km_val, bm_val))
        next
      }
      partition <- partition[keep, , drop = FALSE]
      t_keep <- title_clean[keep]
      a_keep <- abstract_clean[keep]
      premise <- trimws(paste(ifelse(is.na(t_keep), "", t_keep), a_keep))

      message(sprintf(
        "[NLI %s] km=%s / bm=%s: classifying %d works",
        assessment_id, km_val, bm_val, length(premise)
      ))

      # Send premises to the server in HTTP-sized chunks; the model batches
      # internally at `batch_size`.
      chunks <- split(
        seq_along(premise),
        ceiling(seq_along(premise) / max(1L, http_chunk))
      )
      n_chunks <- length(chunks)
      scores_list <- vector("list", length(premise))
      for (chunk_i in seq_along(chunks)) {
        idx <- chunks[[chunk_i]]
        message(sprintf(
          "[NLI %s] km=%s / bm=%s: chunk %d/%d (%d works)",
          assessment_id, km_val, bm_val, chunk_i, n_chunks, length(idx)
        ))
        res <- nli_classify_request(
          base_url            = base_url,
          sequences           = premise[idx],
          candidate_labels    = candidate_labels,
          hypothesis_template = hypothesis_template,
          multi_label         = multi_label,
          batch_size          = batch_size,
          auth_token          = auth_token
        )
        if (length(res) != length(idx)) {
          stop(sprintf(
            "NLI server returned %d results for %d sequences (km=%s/bm=%s)",
            length(res), length(idx), km_val, bm_val
          ))
        }
        scores_list[idx] <- res
      }

      pick <- function(sc, lab) {
        v <- sc[[lab]]
        if (is.null(v) || is.na(v)) NA_real_ else as.numeric(v)
      }
      p_supports <- vapply(scores_list, pick, numeric(1), lab_supports)
      p_refutes  <- vapply(scores_list, pick, numeric(1), lab_refutes)
      p_nei      <- vapply(scores_list, pick, numeric(1), lab_nei)

      probs <- cbind(p_supports, p_refutes, p_nei)
      label_levels <- c("SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO")
      argmax <- apply(probs, 1L, function(r) {
        if (all(is.na(r))) NA_integer_ else which.max(r)
      })
      label <- ifelse(is.na(argmax), NA_character_, label_levels[argmax])
      confidence <- apply(probs, 1L, function(r) {
        if (all(is.na(r))) NA_real_ else max(r, na.rm = TRUE)
      })

      out <- dplyr::tibble(
        nli_config       = nli_active,
        assessment       = assessment_id,
        km               = km_val,
        bm               = bm_val,
        work_id          = partition$work_id,
        doi              = partition$doi,
        title            = partition$title,
        publication_year = partition$publication_year,
        label            = label,
        p_supports       = p_supports,
        p_refutes        = p_refutes,
        p_nei            = p_nei,
        confidence       = confidence,
        uncertain        = !is.na(confidence) & confidence < uncertain_threshold
      )

      arrow::write_dataset(
        dataset = out,
        path = output_root,
        format = "parquet",
        partitioning = c("nli_config", "assessment", "km", "bm"),
        existing_data_behavior = "overwrite"
      )
      wrote_any <- TRUE
      rm(partition, out)
    }
  }

  if (!wrote_any) {
    message(sprintf("[NLI %s] no partitions scored", assessment_id))
  }

  output_path
}
