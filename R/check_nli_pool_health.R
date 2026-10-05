# Health-check every host in the active nli config's pool, once per pipeline
# run. Fails loudly listing every unreachable host (a bad host must never be
# silently dropped — that would leave its share of claims never attempted).
# Stops (not warns) if hosts report different models: a pool scoring with
# genuinely different models per host would silently corrupt result
# provenance. Returns the common model name, used to stamp nli_model on
# every scored row.
check_nli_pool_health <- function(nli_config, nli_active) {
  cfg <- if (is.null(nli_config)) list() else nli_config

  # The jev backend has no pool: it scores through an HTTP API, not a fixed set
  # of hosts serving one checkpoint. There is nothing to health-check and
  # nothing to verify is homogeneous, so this returns the model name -- which
  # is all the caller actually uses it for, stamping nli_model onto scored rows.
  # It is NOT skipped silently: a missing API key is the equivalent failure and
  # is caught here, early and once, rather than per claim halfway into a run.
  if (identical(cfg$backend, "jev")) {
    model <- cfg$model %||% "typesafe/jev-1.13"
    if (!nzchar(Sys.getenv("API_openrouter"))) {
      stop(sprintf("[NLI pool=%s] backend is jev but API_openrouter is not set", nli_active), call. = FALSE)
    }
    message(sprintf("[NLI pool=%s] backend=jev, model=%s -- no pod pool to check", nli_active, model))
    return(model)
  }

  hosts <- nli_hosts(cfg)
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

  health_results <- lapply(seq_along(hosts), function(k) {
    tryCatch(
      list(ok = TRUE, host = hosts[[k]], health = nli_health(base_urls[[k]], auth_token)),
      error = function(e) list(ok = FALSE, host = hosts[[k]], error = conditionMessage(e))
    )
  })
  failed <- Filter(function(r) !r$ok, health_results)
  if (length(failed)) {
    stop(sprintf(
      "[NLI pool=%s] %d/%d host(s) failed health check:\n%s",
      nli_active, length(failed), length(hosts),
      paste(sprintf("  - %s: %s",
                     vapply(failed, `[[`, character(1), "host"),
                     vapply(failed, `[[`, character(1), "error")),
            collapse = "\n")
    ))
  }

  for (k in seq_along(hosts)) {
    h <- health_results[[k]]$health
    message(sprintf(
      "[NLI pool=%s] host %d/%d (%s): model=%s dtype=%s device=%s max_length=%s",
      nli_active, k, length(hosts), hosts[[k]], h[["model"]] %||% "?",
      h[["dtype"]] %||% "?", h[["device"]] %||% "?",
      h[["max_length"]] %||% "(server default)"
    ))
  }

  models_seen <- vapply(health_results, function(r) {
    as.character(r$health[["model"]] %||% NA_character_)
  }, character(1))
  if (length(unique(stats::na.omit(models_seen))) > 1L) {
    stop(sprintf(
      "[NLI pool=%s] hosts report different models — results would not be homogeneous: %s",
      nli_active,
      paste(sprintf("%s=%s", hosts, models_seen), collapse = ", ")
    ))
  }
  model_actual <- unique(stats::na.omit(models_seen))
  model_actual <- if (length(model_actual)) model_actual[[1L]] else NA_character_

  model_label <- cfg[["model"]]
  if (!is.null(model_label) && nzchar(model_label) &&
        !is.na(model_actual) && !identical(model_label, model_actual)) {
    warning(sprintf(
      "[NLI pool=%s] config model label '%s' != server model '%s' — recording server model",
      nli_active, model_label, model_actual
    ))
  }

  # expect_model: an OPTIONAL hard assertion, where `model:` above is only a
  # label and only warns. A fine-tuned model is served from a baked path
  # (/opt/models/...), so pointing the pool at the wrong image produces a pool
  # that answers every request perfectly well with a different model -- no error
  # anywhere, just scores that silently are not what nli_config= says they are.
  expect <- cfg[["expect_model"]]
  if (!is.null(expect) && nzchar(expect) && !identical(as.character(expect), model_actual)) {
    stop(sprintf(
      "[NLI pool=%s] expect_model '%s' != server model '%s' -- refusing to score.",
      nli_active, expect, model_actual
    ), call. = FALSE)
  }

  # The same trap one layer down, and the reason the pod wrapper derives
  # NLI_MAX_LENGTH from this very field: a model trained at 512 served at 2048
  # raises nothing at all and merely scores worse (a8c6ea4). The server reports
  # what it actually runs at, so this is the one place it can be caught.
  #
  # A WARNING, not a stop, unlike expect_model above. What a given server build
  # reports here has not been confirmed against a live pod (the pool was down
  # when this was written), so a stop could block a run over a reporting
  # convention rather than a real mismatch. The bug it guards is already
  # removed by construction for any pool start_nli_pods.sh launches, since that
  # wrapper derives NLI_MAX_LENGTH from this same field. Promote to stop() once
  # a healthy pod has been seen to report the configured value.
  want_len <- cfg[["max_length"]]
  served_len <- health_results[[1L]]$health[["max_length"]]
  if (!is.null(want_len) && !is.null(served_len) &&
        !identical(as.integer(want_len), as.integer(served_len))) {
    warning(sprintf(
      "[NLI pool=%s] config max_length %s != server max_length %s -- the pods may have been launched with the wrong NLI_MAX_LENGTH.",
      nli_active, want_len, served_len
    ), call. = FALSE)
  }

  model_actual
}
