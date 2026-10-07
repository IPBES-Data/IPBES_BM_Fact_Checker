# Git's own object id for a file's bytes: sha1("blob <len>\0" + content). Used to
# verify a download landed intact, since the GitHub contents API hands us exactly
# this id for free alongside the URL.
git_blob_sha1 <- function(bytes) {
  digest::digest(
    c(charToRaw(sprintf("blob %d", length(bytes))), as.raw(0L), bytes),
    algo = "sha1", serialize = FALSE
  )
}

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

download_ttl <- function(assessment, output_root = out_collection("LoD")) {
  dir.create(output_root, showWarnings = FALSE, recursive = TRUE)
  dest     <- file.path(output_root, paste0(assessment$id, ".ttl"))
  sha_file <- paste0(dest, ".sha")

  # NEVER write to `dest` directly. utils::download.file() creates/truncates its
  # destination before the transfer, so a failed download DESTROYS the existing
  # copy. That is not hypothetical: on 2026-10-07 the configured ttl_url for GA1
  # (GA1_v09.ttl) had been renamed upstream to GA1_v11.ttl, and the resulting 404
  # deleted a perfectly good 6.4 MB GA1.ttl that had been on disk since April.
  # Recovery was possible only because the .sha sidecar survived and GitHub still
  # served that blob by id. Same shape as the 2026-09-15 snowball incident
  # documented in build_snowball_parquet.R: destroy first, discover failure after.
  remote <- tryCatch(github_blob_sha(assessment$ttl_url), error = function(e) e)
  local_sha <- if (file.exists(sha_file)) readLines(sha_file, warn = FALSE)[[1L]] else ""

  if (inherits(remote, "condition")) {
    msg <- conditionMessage(remote)
    # A 404 means the URL is WRONG, not that the network is down -- the IPBES LOD
    # repository version-stamps its filenames, so a bumped version renames the
    # file out from under a pinned ttl_url. Carrying on against the stale local
    # copy would silently build everything downstream from a superseded LOD, so
    # this stops and says what to look at. A transient network failure, by
    # contrast, is survivable: the local copy is still whatever it always was.
    if (grepl("404|Not Found", msg)) {
      stop(sprintf(
        paste0("TTL URL for %s is gone (HTTP 404):\n  %s\n",
               "The IPBES LOD repository version-stamps its filenames, so this is ",
               "usually an upstream version bump.\nList the current files with:\n",
               "  curl -s 'https://api.github.com/repos/IPBES-Data/IPBES_LOD/contents/<assessment dir>' | grep '\"name\"'\n",
               "then update `collection.assessments[].ttl_url` in input/config.yaml.\n",
               "NOTE: a new LOD version legitimately changes refs -> works -> snowball."),
        assessment$id, assessment$ttl_url
      ), call. = FALSE)
    }
    if (!file.exists(dest)) {
      stop(sprintf("Cannot reach GitHub for %s and no local TTL exists: %s",
                   assessment$id, msg), call. = FALSE)
    }
    warning(sprintf(
      "[ttl %s] could not reach GitHub (%s) -- using the local copy, which may be stale",
      assessment$id, msg
    ), call. = FALSE)
    return(dest)
  }

  remote_sha <- remote
  if (file.exists(dest) && identical(remote_sha, local_sha)) {
    message("TTL up to date for ", assessment$id, " (SHA unchanged)")
    return(dest)
  }

  message("Downloading TTL for ", assessment$id, " ...")
  tmp <- tempfile(fileext = ".ttl")
  on.exit(unlink(tmp, force = TRUE), add = TRUE)
  utils::download.file(assessment$ttl_url, destfile = tmp, mode = "wb", quiet = FALSE)

  # Verify before replacing anything. download.file() reports success for a
  # truncated transfer often enough that the content check is worth its two lines,
  # and the expected id is already in hand from the contents API.
  got <- git_blob_sha1(readBin(tmp, "raw", file.size(tmp)))
  if (!identical(got, remote_sha)) {
    stop(sprintf(
      "TTL download for %s is corrupt: git blob sha1 %s, expected %s. The existing copy was left untouched.",
      assessment$id, got, remote_sha
    ), call. = FALSE)
  }

  if (!file.rename(tmp, dest)) file.copy(tmp, dest, overwrite = TRUE)
  writeLines(remote_sha, sha_file)
  dest
}

download_ttls <- function(config, output_root = out_collection("LoD")) {
  vapply(config_assessments(config), download_ttl, character(1), output_root = output_root)
}
