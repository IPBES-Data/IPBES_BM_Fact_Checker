github_blob_sha <- function(raw_url) {
  m <- regmatches(raw_url, regexec(
    "^https://raw\\.githubusercontent\\.com/([^/]+)/([^/]+)/(.+)$",
    raw_url
  ))[[1]]
  if (length(m) < 4L) stop("Cannot parse GitHub raw URL: ", raw_url)
  rest  <- m[4L]
  parts <- strsplit(rest, "/", fixed = TRUE)[[1L]]
  # refs/heads/<name> or refs/tags/<name> uses 3 components; plain branch uses 1
  if (length(parts) > 2L && parts[1L] == "refs") {
    ref  <- paste(parts[1:3], collapse = "/")
    path <- paste(parts[-(1:3)], collapse = "/")
  } else {
    ref  <- parts[1L]
    path <- paste(parts[-1L], collapse = "/")
  }
  api_url <- paste0(
    "https://api.github.com/repos/", m[2L], "/", m[3L],
    "/contents/", path, "?ref=", ref
  )
  resp <- httr2::request(api_url) |>
    httr2::req_headers(Accept = "application/vnd.github.v3+json") |>
    httr2::req_perform()
  httr2::resp_body_json(resp)$sha
}

download_ttl <- function(assessment, output_root = "output/LoD") {
  dir.create(output_root, showWarnings = FALSE, recursive = TRUE)
  dest     <- file.path(output_root, paste0(assessment$id, ".ttl"))
  sha_file <- paste0(dest, ".sha")

  remote_sha <- tryCatch(
    github_blob_sha(assessment$ttl_url),
    error = function(e) {
      warning("Could not fetch GitHub SHA for ", assessment$id, ": ", conditionMessage(e))
      NULL
    }
  )
  local_sha <- if (file.exists(sha_file)) readLines(sha_file, warn = FALSE)[[1L]] else ""

  if (!file.exists(dest) || is.null(remote_sha) || !identical(remote_sha, local_sha)) {
    message("Downloading TTL for ", assessment$id, " ...")
    utils::download.file(assessment$ttl_url, destfile = dest, mode = "wb", quiet = FALSE)
    if (!is.null(remote_sha)) writeLines(remote_sha, sha_file)
  } else {
    message("TTL up to date for ", assessment$id, " (SHA unchanged)")
  }

  dest
}

download_ttls <- function(config, output_root = "output/LoD") {
  vapply(config$assessments, download_ttl, character(1), output_root = output_root)
}
