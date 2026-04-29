resolve_citations <- function(
  assessment,
  sections_path,
  works_path,
  zotero_path,
  output_root = "output/resolved_sections"
) {
  output_path <- branch_output_dir(output_root, assessment$id)
  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

  zotero_df <- arrow::open_dataset(zotero_path) |>
    dplyr::select(first_author, year, doi) |>
    dplyr::filter(!is.na(doi), !is.na(first_author), !is.na(year)) |>
    dplyr::collect() |>
    dplyr::mutate(
      doi_norm = openalexPro::extract_doi(doi, what = "doi", normalize = TRUE, non_doi_value = "")
    )

  works_df <- arrow::open_dataset(works_path) |>
    dplyr::select(id, doi) |>
    dplyr::filter(!is.na(doi), !is.na(id)) |>
    dplyr::collect() |>
    dplyr::mutate(
      doi_norm = openalexPro::extract_doi(doi, what = "doi", normalize = TRUE, non_doi_value = ""),
      w_id     = sub("^https://openalex\\.org/", "", id)
    )

  lookup_df <- dplyr::inner_join(zotero_df, works_df, by = "doi_norm") |>
    dplyr::mutate(
      author_key = tolower(trimws(first_author)),
      year_key   = as.character(year)
    ) |>
    dplyr::select(author_key, year_key, w_id) |>
    dplyr::distinct() |>
    dplyr::group_by(author_key, year_key) |>
    dplyr::summarise(w_ids = list(unique(w_id)), .groups = "drop")

  lookup_map <- setNames(
    lookup_df$w_ids,
    paste(lookup_df$author_key, lookup_df$year_key, sep = "|||")
  )

  message("Built citation lookup with ", nrow(lookup_df), " (author, year) keys [", assessment$id, "]")

  sections <- arrow::open_dataset(sections_path) |>
    dplyr::collect()

  sections$content <- vapply(
    sections$content,
    replace_citations_in_text,
    character(1),
    lookup_map = lookup_map
  )

  arrow::write_dataset(
    dataset = sections,
    path = output_path,
    format = "parquet",
    partitioning = c("assessment", "km", "bm", "section", "subsection"),
    existing_data_behavior = "delete_matching"
  )

  message("Resolved citations in ", nrow(sections), " rows for [", assessment$id, "]")
  output_path
}

replace_citations_in_text <- function(text, lookup_map) {
  if (is.na(text) || !nzchar(text)) return(text)

  # Match (Author portion, YYYY[a-z]?)
  # Author portion: starts with a letter (incl. accented), no parens, non-greedy to comma
  pattern <- "\\(([A-Za-zÀ-ÿ][^,()]*?),\\s*(\\d{4}[a-z]?)\\)"

  m <- gregexpr(pattern, text, perl = TRUE)[[1]]
  if (m[[1]] == -1L) return(text)

  starts  <- as.integer(m)
  lengths <- attr(m, "match.length")

  for (i in rev(seq_along(starts))) {
    match_str <- substr(text, starts[i], starts[i] + lengths[i] - 1L)
    cap <- regmatches(match_str, regexec(pattern, match_str, perl = TRUE))[[1]]
    if (length(cap) < 3L) next

    author_raw <- cap[[2L]]
    year_raw   <- cap[[3L]]

    # Strip trailing letter suffix (2023a → 2023)
    year_key <- sub("[a-z]$", "", year_raw)

    # Extract first author from "Smith et al.", "Smith & Jones", "Smith and Jones"
    first_part <- sub(
      "\\s+(et\\s+al\\..*|[&]\\s+.*|\\band\\b.*)$", "",
      trimws(author_raw), perl = TRUE
    )
    author_key <- tolower(trimws(first_part))

    key   <- paste(author_key, year_key, sep = "|||")
    w_ids <- lookup_map[[key]]
    if (is.null(w_ids)) next

    replacement <- paste0("[", paste(w_ids, collapse = " "), "]")
    text <- paste0(
      substr(text, 1L, starts[i] - 1L),
      replacement,
      substr(text, starts[i] + lengths[i], nchar(text))
    )
  }

  text
}
