# Health-check every host in the active nli config's pool, once per pipeline
# run. Fails loudly listing every unreachable host (a bad host must never be
# silently dropped — that would leave its share of claims never attempted).
# Stops (not warns) if hosts report different models: a pool scoring with
# genuinely different models per host would silently corrupt result
# provenance. Returns the common model name, used to stamp nli_model on
# every scored row.
check_nli_pool_health <- function(nli_config, nli_active) {
  cfg <- if (is.null(nli_config)) list() else nli_config
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

  model_actual
}
