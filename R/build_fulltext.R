build_fulltext <- function(
  assessment,
  works_citing_parquet,
  fulltext_list,
  output_root = "output/fulltext",
  workers = 8L
) {
  enabled <- any(vapply(
    fulltext_list,
    function(x) identical(x$assessment_id, assessment$id) && isTRUE(x$enabled),
    logical(1)
  ))

  out_dir <- file.path(output_root, paste0("assessment=", assessment$id))
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  if (!enabled) {
    sentinel <- file.path(out_dir, ".disabled")
    writeLines(character(0), sentinel)
    return(sentinel)
  }

  api_key <- Sys.getenv("API_openalex")
  if (!nzchar(api_key)) stop("API_openalex environment variable is required")

  wc_root <- unique(sub("/assessment=.*", "", works_citing_parquet))[1L]
  assessment_id <- assessment$id

  works <- arrow::open_dataset(wc_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::mutate(
      has_xml = has_content$grobid_xml,
      has_pdf = has_content$pdf,
      url_xml = content_urls$grobid_xml,
      url_pdf = content_urls$pdf
    ) |>
    dplyr::select(id, has_xml, has_pdf, url_xml, url_pdf) |>
    dplyr::distinct(id, .keep_all = TRUE) |>
    dplyr::collect()

  shorten <- function(id) sub("^https://openalex.org/", "", id)

  add_key <- function(url) {
    if (is.na(url) || !nzchar(url)) return(NA_character_)
    paste0(url, "?api_key=", api_key)
  }

  download_url <- function(url, dest) {
    if (is.na(url)) return(FALSE)
    resp <- tryCatch(
      httr2::request(url) |>
        httr2::req_error(is_error = \(r) FALSE) |>
        httr2::req_perform(path = dest),
      error = function(e) NULL
    )
    ok <- !is.null(resp) && httr2::resp_status(resp) == 200L
    if (!ok && file.exists(dest)) file.remove(dest)
    ok
  }

  # ── Pass 1: classify every work without downloading anything ──────────────
  message(sprintf("Pass 1: Checking %d works for %s", nrow(works), assessment_id))

  n_done    <- 0L
  n_missing <- 0L
  to_download <- vector("list", nrow(works))
  n_to_dl     <- 0L

  for (i in seq_len(nrow(works))) {
    row          <- works[i, , drop = FALSE]
    sid          <- shorten(row$id)
    xml_path     <- file.path(out_dir, paste0(sid, ".xml"))
    pdf_path     <- file.path(out_dir, paste0(sid, ".pdf"))
    missing_path <- file.path(out_dir, paste0(sid, ".missing"))

    if (file.exists(xml_path)) {
      # Reject JSON error bodies saved as .xml in a previous run
      if (file.size(xml_path) < 1000L) {
        hdr <- tryCatch(rawToChar(readBin(xml_path, "raw", 20L)), error = function(e) "")
        if (grepl("^\\{", hdr)) { file.remove(xml_path); } else { n_done <- n_done + 1L; next }
      } else { n_done <- n_done + 1L; next }
    }

    if (file.exists(pdf_path)) {
      # Reject HTML/JSON error bodies saved as .pdf in a previous run
      raw4 <- tryCatch(readBin(pdf_path, "raw", 4L), error = function(e) raw(0))
      is_pdf <- length(raw4) >= 4L && raw4[1L] == as.raw(0x25) && raw4[2L] == as.raw(0x50) &&
                raw4[3L] == as.raw(0x44) && raw4[4L] == as.raw(0x46)
      if (is_pdf) { n_done <- n_done + 1L; next } else { file.remove(pdf_path) }
    }

    if (file.exists(missing_path)) {
      if (isTRUE(row$has_xml) || isTRUE(row$has_pdf)) {
        n_to_dl <- n_to_dl + 1L
        to_download[[n_to_dl]] <- list(row = row, replace = missing_path)
      } else {
        n_done <- n_done + 1L
      }
      next
    }

    # Nothing on disk yet
    if (isTRUE(row$has_xml) || isTRUE(row$has_pdf)) {
      n_to_dl <- n_to_dl + 1L
      to_download[[n_to_dl]] <- list(row = row, replace = NULL)
    } else {
      writeLines(character(0), missing_path)
      n_missing <- n_missing + 1L
    }
  }

  to_download <- to_download[seq_len(n_to_dl)]

  message(sprintf(
    "  %d already done  |  %d missing (no full text available)  |  %d to download",
    n_done, n_missing, n_to_dl
  ))

  # ── Pass 2: download in parallel with progress bar ────────────────────────
  downloaded_paths <- character(0)

  is_credits_exhausted <- function(raw) {
    length(raw) < 2000L && length(raw) >= 1L && raw[1L] == as.raw(0x7b) &&
      grepl(
        "creditsRemaining|Insufficient budget|Rate limit exceeded",
        tryCatch(rawToChar(raw), error = function(e) "")
      )
  }

  credits_stop <- function(raw) {
    retry_after <- tryCatch({
      jsonlite::fromJSON(rawToChar(raw))$retryAfter
    }, error = function(e) NA_integer_)
    if (!is.na(retry_after))
      stop(sprintf(
        "OpenAlex credits exhausted. Retry after %d s (~%.1f h).",
        retry_after, retry_after / 3600
      ))
    stop("OpenAlex credits exhausted.")
  }

  if (n_to_dl > 0L) {
    message(sprintf("Pass 2: Downloading %d works (workers=%d)", n_to_dl, workers))

    # Pre-flight: check API credit balance before launching parallel workers
    message("  Pre-flight credit check...")
    rl <- openalexPro::pro_rate_limit_status(api_key = api_key, verbose = TRUE)
    if (isFALSE(rl)) stop("OpenAlex API key missing or invalid.")
    if (!is.null(rl)) {
      daily_rem   <- rl$rate_limit$daily_remaining_usd
      prepaid_rem <- rl$rate_limit$prepaid_remaining_usd
      daily_rem   <- if (is.null(daily_rem))   0 else daily_rem
      prepaid_rem <- if (is.null(prepaid_rem)) 0 else prepaid_rem
      if (daily_rem <= 0 && prepaid_rem <= 0) {
        resets_in <- rl$rate_limit$resets_in_seconds
        resets_in <- if (is.null(resets_in)) NA_integer_ else resets_in
        msg <- if (!is.na(resets_in))
          sprintf("OpenAlex credits exhausted. Resets in %d s (~%.1f h).", resets_in, resets_in / 3600)
        else
          "OpenAlex credits exhausted."
        stop(msg)
      }
    }

    download_item <- function(item) {
      row          <- item$row
      sid          <- sub("^https://openalex.org/", "", row$id)
      xml_path     <- file.path(out_dir, paste0(sid, ".xml"))
      pdf_path     <- file.path(out_dir, paste0(sid, ".pdf"))
      missing_path <- file.path(out_dir, paste0(sid, ".missing"))

      fetch <- function(url, dest, decompress = FALSE, check_pdf = FALSE) {
        resp <- tryCatch(
          httr2::request(url) |>
            httr2::req_timeout(seconds = 30) |>
            httr2::req_retry(max_tries = 3, is_transient = \(r) httr2::resp_status(r) %in% c(429L, 500L, 502L, 503L, 504L)) |>
            httr2::req_error(is_error = \(r) FALSE) |>
            httr2::req_perform(),
          error = function(e) NULL
        )
        if (is.null(resp) || httr2::resp_status(resp) != 200L) return("error")

        raw <- httr2::resp_body_raw(resp)

        if (length(raw) < 2000L && length(raw) >= 1L && raw[1L] == as.raw(0x7b)) {
          txt <- tryCatch(rawToChar(raw), error = function(e) "")
          if (grepl("creditsRemaining|Insufficient budget|Rate limit exceeded", txt))
            return("credits_exhausted")
          return("error")
        }

        if (decompress) {
          if (length(raw) >= 2L && raw[1L] == as.raw(0x1f) && raw[2L] == as.raw(0x8b))
            raw <- memDecompress(raw, type = "gzip")
          is_xml <- tryCatch(
            grepl("^\\s*(<\\?xml|<TEI)", rawToChar(raw[seq_len(min(100L, length(raw)))]),
                  ignore.case = FALSE),
            error = function(e) FALSE
          )
          if (!is_xml) return("error")
        }

        if (check_pdf) {
          is_pdf <- length(raw) >= 4L &&
            raw[1L] == as.raw(0x25) && raw[2L] == as.raw(0x50) &&
            raw[3L] == as.raw(0x44) && raw[4L] == as.raw(0x46)
          if (!is_pdf) return("error")
        }

        writeBin(raw, dest)
        "ok"
      }

      if (isTRUE(row$has_xml)) {
        url    <- paste0(row$url_xml, "?api_key=", api_key)
        result <- fetch(url, xml_path, decompress = TRUE)
        if (result == "credits_exhausted") return("__CREDITS_EXHAUSTED__")
        if (result == "ok") {
          if (!is.null(item$replace) && file.exists(item$replace)) file.remove(item$replace)
          return(xml_path)
        }
      }

      if (isTRUE(row$has_pdf)) {
        url    <- paste0(row$url_pdf, "?api_key=", api_key)
        result <- fetch(url, pdf_path, check_pdf = TRUE)
        if (result == "credits_exhausted") return("__CREDITS_EXHAUSTED__")
        if (result == "ok") {
          if (!is.null(item$replace) && file.exists(item$replace) &&
              item$replace != pdf_path) file.remove(item$replace)
          return(pdf_path)
        }
      }

      writeLines(character(0), missing_path)
      missing_path
    }

    old_plan <- future::plan(future::multisession, workers = workers)
    on.exit(future::plan(old_plan), add = TRUE)

    batch_size <- workers
    n_batches  <- ceiling(n_to_dl / batch_size)

    run_pass <- function(items, label) {
      n         <- length(items)
      n_batches <- ceiling(n / batch_size)
      paths     <- character(0)
      for (b in seq_len(n_batches)) {
        message(sprintf("  %s batch %d/%d ...", label, b, n_batches))
        idx     <- seq(from = (b - 1L) * batch_size + 1L, to = min(b * batch_size, n))
        results <- unlist(future.apply::future_lapply(items[idx], download_item, future.packages = "httr2"))
        if (any(results == "__CREDITS_EXHAUSTED__"))
          stop("OpenAlex credits exhausted (detected in workers).")
        paths   <- c(paths, results)
        exts    <- tools::file_ext(results)
        message(sprintf(
          "  %s [%d/%d]  xml: %d  pdf: %d  missing: %d",
          label, min(b * batch_size, n), n,
          sum(exts == "xml"), sum(exts == "pdf"), sum(exts == "missing")
        ))
      }
      paths
    }

    downloaded_paths <- run_pass(to_download, "Pass 2")

    # Pass 3: retry items that still ended up as .missing
    retry <- to_download[tools::file_ext(downloaded_paths) == "missing"]
    if (length(retry) > 0L) {
      message(sprintf("Pass 3: Retrying %d failed downloads", length(retry)))
      retry_paths      <- run_pass(retry, "Pass 3")
      n_recovered      <- sum(tools::file_ext(retry_paths) != "missing")
      message(sprintf("  Recovered: %d  Still missing: %d", n_recovered, length(retry) - n_recovered))
      downloaded_paths[tools::file_ext(downloaded_paths) == "missing"] <- retry_paths
    }
  }

  sort(c(
    list.files(out_dir, pattern = "\\.(xml|pdf|missing)$", full.names = TRUE),
    downloaded_paths
  ))
}
