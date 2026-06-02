extract_zotero_key <- function(zotero_url) {
  if (is.na(zotero_url) || !nzchar(zotero_url)) {
    return(NA_character_)
  }

  pattern <- "^https://www\\.zotero\\.org/groups/[0-9]+/items/([^/?#]+)$"
  match <- regexec(pattern, zotero_url)
  parts <- regmatches(zotero_url, match)[[1]]
  if (length(parts) < 2L) {
    return(NA_character_)
  }
  parts[[2L]]
}

extract_zotero_group <- function(zotero_url) {
  if (is.na(zotero_url) || !nzchar(zotero_url)) {
    return(NA_character_)
  }

  pattern <- "^https://www\\.zotero\\.org/groups/([0-9]+)/items/[^/?#]+$"
  match <- regexec(pattern, zotero_url)
  parts <- regmatches(zotero_url, match)[[1]]
  if (length(parts) < 2L) {
    return(NA_character_)
  }
  parts[[2L]]
}

extract_refs_from_endpoint <- function(endpoint, assessment_id, sparql_file = "queries/refs.sparql") {
  message("Querying SPARQL refs endpoint for ", assessment_id, " ...")

  tictoc::tic("  query refs (DB1)")
  refs_raw <- sparql_query(endpoint, read_sparql_query(sparql_file, assessment_id))
  tictoc::toc()
  message("  Refs rows: ", nrow(refs_raw))

  if (nrow(refs_raw) == 0) {
    stop("Refs SPARQL returned 0 rows for ", assessment_id,
         ". Check the Fuseki dataset loaded correctly.")
  }

  refs_raw |>
    dplyr::rename(km = km_id, bm = bm_id, sm = sm_id) |>
    dplyr::mutate(
      assessment   = assessment_id,
      zotero_group = vapply(zotero, extract_zotero_group, character(1)),
      zotero_key   = vapply(zotero, extract_zotero_key, character(1)),
      citation     = ifelse(
        !is.na(zotero_key) & nzchar(zotero_key),
        paste0("[", zotero_key, "]"),
        NA_character_
      )
    )
}

extract_sections_from_endpoint <- function(endpoint, assessment_id, sparql_file = "queries/sections.sparql") {
  message("Querying SPARQL sections endpoint for ", assessment_id, " ...")

  tictoc::tic("  query sections (DB2)")
  sections_raw <- sparql_query(endpoint, read_sparql_query(sparql_file, assessment_id))
  tictoc::toc()
  message("  Sections rows: ", nrow(sections_raw))

  sections_raw |>
    dplyr::rename(km = km_id, bm = bm_id, sm = sm_id,
                  section = section_id, subsection = subsection_id) |>
    dplyr::mutate(assessment = assessment_id)
}

extract_key_messages_from_endpoint <- function(endpoint, assessment_id, sparql_file = "queries/key_messages.sparql") {
  message("Querying SPARQL key/background messages endpoint for ", assessment_id, " ...")

  tictoc::tic("  query key/background messages (DB3)")
  km_raw <- sparql_query(endpoint, read_sparql_query(sparql_file, assessment_id))
  tictoc::toc()
  message("  Key/Background Message rows: ", nrow(km_raw))

  if (nrow(km_raw) == 0) {
    stop("Key messages SPARQL returned 0 rows for ", assessment_id,
         ". Check the Fuseki dataset loaded correctly.")
  }

  km_raw |>
    dplyr::rename(km = km_id, bm = bm_id) |>
    dplyr::mutate(
      dplyr::across(
        tidyselect::any_of(c(
          "km_label", "km_description",
          "bm_label", "bm_description",
          "sm_id", "sm_description"
        )),
        as.character
      ),
      assessment = assessment_id
    )
}

read_sparql_query <- function(sparql_file, assessment_id) {
  query <- readLines(sparql_file, warn = FALSE) |> paste(collapse = "\n")
  gsub(
    "%GRAPH_IRI%",
    assessment_graph_iri(assessment_id),
    query,
    fixed = TRUE
  )
}

sparql_query <- function(endpoint, query) {
  resp <- httr2::request(endpoint) |>
    httr2::req_method("POST") |>
    httr2::req_headers(
      "Content-Type" = "application/x-www-form-urlencoded",
      "Accept"       = "text/csv"
    ) |>
    httr2::req_body_form(query = query) |>
    httr2::req_perform()

  readr::read_csv(
    httr2::resp_body_string(resp),
    show_col_types = FALSE,
    na = ""
  )
}
