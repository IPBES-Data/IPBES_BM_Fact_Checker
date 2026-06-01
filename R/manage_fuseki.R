fuseki_process_env <- new.env(parent = emptyenv())

start_fuseki <- function(ttl_path, dataset_name, port = 3030) {
  fuseki_bin <- Sys.which("fuseki-server")
  if (fuseki_bin == "") {
    stop("fuseki-server not found. Install with: brew install fuseki")
  }

  message("Starting Fuseki for ", dataset_name, " on port ", port, " ...")

  # In-memory, updatable dataset so we can POST the TTL into a named graph
  # matching the shared-endpoint IRI convention. Lets queries that use
  # `GRAPH <iri>` work identically against local Fuseki and the remote IPBES
  # endpoint.
  proc <- processx::process$new(
    command = fuseki_bin,
    args = c(
      paste0("--port=", port),
      "--mem",
      "--update",
      paste0("/", dataset_name)
    ),
    stdout = tempfile(fileext = ".log"),
    stderr = tempfile(fileext = ".log")
  )

  base <- paste0("http://localhost:", port, "/", dataset_name)
  endpoint <- paste0(base, "/sparql")
  data_endpoint <- paste0(base, "/data")
  graph_iri <- assessment_graph_iri(dataset_name)
  session_id <- paste0(dataset_name, "@", port)
  assign(session_id, proc, envir = fuseki_process_env)

  message("  Waiting for Fuseki to be ready...")
  ready <- FALSE
  for (i in seq_len(60)) {
    Sys.sleep(1)
    if (!proc$is_alive()) {
      stop("Fuseki process exited unexpectedly during startup")
    }
    ok <- tryCatch(
      {
        resp <- httr2::request(endpoint) |>
          httr2::req_url_query(query = "ASK {}") |>
          httr2::req_error(is_error = \(r) FALSE) |>
          httr2::req_perform()
        httr2::resp_status(resp) < 500
      },
      error = function(e) FALSE
    )
    if (ok) {
      message("  Fuseki ready after ", i, "s at ", endpoint)
      ready <- TRUE
      break
    }
  }

  if (!ready) {
    if (exists(session_id, envir = fuseki_process_env, inherits = FALSE)) {
      rm(list = session_id, envir = fuseki_process_env)
    }
    try(proc$kill(), silent = TRUE)
    stop("Fuseki did not become ready within 60 seconds")
  }

  message("  Loading ", basename(ttl_path), " into graph <", graph_iri, "> ...")
  load_resp <- httr2::request(data_endpoint) |>
    httr2::req_url_query(graph = graph_iri) |>
    httr2::req_method("POST") |>
    httr2::req_headers("Content-Type" = "text/turtle; charset=utf-8") |>
    httr2::req_body_file(normalizePath(ttl_path)) |>
    httr2::req_error(is_error = \(r) FALSE) |>
    httr2::req_perform()
  if (httr2::resp_status(load_resp) >= 300) {
    try(proc$kill(), silent = TRUE)
    if (exists(session_id, envir = fuseki_process_env, inherits = FALSE)) {
      rm(list = session_id, envir = fuseki_process_env)
    }
    stop(
      "Failed to POST TTL into Fuseki graph <", graph_iri, ">: HTTP ",
      httr2::resp_status(load_resp)
    )
  }

  list(
    pid = proc$get_pid(),
    endpoint = endpoint,
    port = port,
    dataset_name = dataset_name,
    session_id = session_id,
    graph_iri = graph_iri
  )
}

with_fuseki_session <- function(ttl_path, sparql_url, assessment_id,
                               port_base = 3030L, port_offset = 1L, code) {
  if (!identical(sparql_url, "fuseki")) {
    return(code(NULL))
  }

  session <- start_fuseki(
    ttl_path = ttl_path,
    dataset_name = assessment_id,
    port = port_base + port_offset - 1L
  )
  on.exit(stop_fuseki_session(session), add = TRUE)
  code(session)
}

resolve_lod_endpoint <- function(sparql_url, fuseki_state, assessment_id) {
  if (!identical(sparql_url, "fuseki")) {
    return(sparql_url)
  }

  if (is.null(fuseki_state) || is.null(fuseki_state$endpoint)) {
    stop("Missing Fuseki session for assessment ", assessment_id)
  }

  fuseki_state$endpoint
}

stop_fuseki_session <- function(session) {
  if (is.null(session)) {
    return(invisible(NULL))
  }

  if (
    !is.null(session$session_id) &&
      exists(session$session_id, envir = fuseki_process_env, inherits = FALSE)
  ) {
    proc <- get(
      session$session_id,
      envir = fuseki_process_env,
      inherits = FALSE
    )
    try(proc$kill(), silent = TRUE)
    rm(list = session$session_id, envir = fuseki_process_env)
    return(invisible(NULL))
  }

  if (is.null(session$pid) || is.na(session$pid)) {
    return(invisible(NULL))
  }

  pid <- as.character(session$pid)
  try(
    system2("kill", c("-TERM", pid), stdout = FALSE, stderr = FALSE),
    silent = TRUE
  )
  Sys.sleep(0.2)
  try(
    system2("kill", c("-KILL", pid), stdout = FALSE, stderr = FALSE),
    silent = TRUE
  )

  invisible(NULL)
}
