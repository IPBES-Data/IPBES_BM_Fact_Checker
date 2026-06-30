infer_zotero_group_id <- function(refs_path) {
  refs <- arrow::open_dataset(refs_path) |>
    dplyr::select(zotero) |>
    dplyr::filter(!is.na(zotero)) |>
    dplyr::distinct() |>
    dplyr::collect()

  if (is.null(refs$zotero)) {
    stop("refs dataset does not contain a zotero column")
  }

  urls <- unique(stats::na.omit(as.character(refs$zotero)))
  urls <- urls[nzchar(urls)]
  if (!length(urls)) {
    stop("No Zotero URLs were found in refs$zotero")
  }

  pattern <- "^https?://(www\\.)?zotero\\.org/groups/([0-9]+)/items/[^/]+$"
  group_ids <- unique(sub(pattern, "\\2", urls, perl = TRUE))
  if (any(!grepl("^[0-9]+$", group_ids))) {
    bad_urls <- urls[!grepl(pattern, urls, perl = TRUE)]
    stop(
      "Could not parse Zotero group id from refs$zotero: ",
      paste(head(bad_urls, 5), collapse = ", ")
    )
  }

  if (length(group_ids) != 1L) {
    stop(
      "Expected exactly one Zotero group id in refs$zotero, found: ",
      paste(group_ids, collapse = ", ")
    )
  }

  group_ids[[1L]]
}

zotero_item_to_row <- function(item, group_id) {
  d <- item$data
  creators <- if (!is.null(d$creators)) d$creators else list()
  group_id_int <- as.integer(group_id)

  get_last_name <- function(c) {
    if (!is.null(c$lastName) && nchar(c$lastName) > 0) {
      c$lastName
    } else if (!is.null(c$name) && nchar(c$name) > 0) {
      c$name
    } else {
      NA_character_
    }
  }

  first_author <- if (length(creators) > 0) {
    get_last_name(creators[[1]])
  } else {
    NA_character_
  }
  authors <- if (length(creators) > 0) {
    parts <- vapply(creators, get_last_name, character(1))
    paste(parts[!is.na(parts)], collapse = "; ")
  } else {
    NA_character_
  }

  year_str <- if (!is.null(d$date) && nchar(d$date) > 0) {
    m <- regmatches(d$date, regexpr("[12][0-9]{3}", d$date))
    if (length(m) == 1L) m else NA_character_
  } else {
    NA_character_
  }

  chr <- function(x) {
    if (is.null(x) || length(x) == 0L) NA_character_ else as.character(x[[1L]])
  }

  data.frame(
    group_id = group_id_int,
    page = NA_integer_,
    key = chr(d$key),
    item_type = chr(d$itemType),
    title = chr(d$title),
    authors = if (!is.na(authors) && nchar(authors) > 0) {
      authors
    } else {
      NA_character_
    },
    first_author = first_author,
    year = year_str,
    doi = chr(d$DOI),
    abstract = chr(d$abstractNote),
    zotero_url = paste0(
      "https://www.zotero.org/groups/",
      group_id,
      "/items/",
      chr(d$key)
    ),
    stringsAsFactors = FALSE
  )
}

download_zotero <- function(
  assessment,
  refs_path,
  output_root = "output/zotero"
) {
  output_path <- branch_output_dir(output_root, assessment$id)
  group_id <- infer_zotero_group_id(refs_path)

  base_url <- paste0("https://api.zotero.org/groups/", group_id, "/items/top")

  resp0 <- httr2::request(base_url) |>
    httr2::req_url_query(limit = 1, format = "json") |>
    httr2::req_perform()
  total <- as.integer(httr2::resp_header(resp0, "Total-Results"))
  if (is.na(total) || total == 0L) {
    stop("Zotero group ", group_id, ": Total-Results header missing or zero")
  }
  message("Zotero group ", group_id, ": ", total, " top-level items")

  limit <- 100
  starts <- seq(0, total - 1, by = limit)

  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)
  total_rows <- 0L

  for (i in seq_along(starts)) {
    start <- starts[[i]]
    page <- i
    message(
      "  Fetching items ",
      start + 1L,
      "-",
      min(start + limit, total),
      " of ",
      total
    )

    resp <- httr2::request(base_url) |>
      httr2::req_url_query(limit = limit, start = start, format = "json") |>
      httr2::req_throttle(rate = 5) |>
      httr2::req_perform()

    items <- jsonlite::fromJSON(
      httr2::resp_body_string(resp),
      simplifyVector = FALSE
    )
    if (!length(items)) {
      next
    }
    page_df <- as.data.frame(
      dplyr::bind_rows(lapply(items, zotero_item_to_row, group_id = group_id))
    )
    page_df$page <- page

    arrow::write_dataset(
      dataset = page_df,
      path = output_path,
      format = "parquet",
      partitioning = c("group_id", "page"),
      existing_data_behavior = "delete_matching"
    )

    total_rows <- total_rows + nrow(page_df)
  }

  message(
    "Wrote ",
    total_rows,
    " rows to ",
    output_path,
    " across ",
    length(starts),
    " pages"
  )

  output_path
}
