# Low-level HTTP helpers shared by check_nli_pool_health.R and
# score_one_claim.R. Talks to the zero-shot NLI server (docker/nli-runpod/).
# `host:` in an nli config entry may be a single hostname or a list (pool) —
# nli_hosts() is the only place that field should be read directly.

# Small config accessor: config[[key]] or a default when absent / NULL / "".
nli_cfg_get <- function(cfg, key, default) {
  v <- cfg[[key]]
  if (is.null(v)) return(default)
  if (is.character(v) && length(v) == 1L && !nzchar(v)) return(default)
  v
}

# Normalize cfg$host to a character vector of 1+ hostnames ("a pool of 1" for
# single-host configs). yaml::read_yaml() parses a YAML flow-style list as an
# R list, not an atomic vector, so unlist() first.
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
