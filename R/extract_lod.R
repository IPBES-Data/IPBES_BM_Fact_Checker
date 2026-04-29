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

extract_refs_from_endpoint <- function(endpoint, assessment_id) {
  message("Querying SPARQL refs endpoint for ", assessment_id, " ...")

  # DB1: references — KM → BM → SM → SubChapter ← Reference(doi)
  sparql_refs <- '
    PREFIX ipbes: <http://ontology.ipbes.net/report>
    PREFIX dcterms: <http://purl.org/dc/terms/>
    PREFIX owl: <http://www.w3.org/2002/07/owl#>

    SELECT DISTINCT ?km_id ?bm_id ?sm_id ?doi ?description ?zotero
    WHERE {
      ?km  a ipbes:KeyMessage ;
           dcterms:identifier ?km_id ;
           ipbes:BackgroundMessage ?bm .
      ?bm  dcterms:identifier ?bm_id ;
           ipbes:SubMessage ?sm .
      ?sm  dcterms:identifier ?sm_id ;
           ipbes:SubChapter ?sch .
      ?ref a ipbes:Reference ;
           ipbes:SubChapter ?sch ;
           ipbes:hasDoi ?doi .
      OPTIONAL { ?ref ipbes:hasDescription ?description . }
      OPTIONAL { ?ref owl:sameAs ?zotero . }
    }
  '

  tictoc::tic("  query refs (DB1)")
  refs_raw <- sparql_query(endpoint, sparql_refs)
  tictoc::toc()
  message("  Refs rows: ", nrow(refs_raw))

  if (nrow(refs_raw) == 0) {
    stop("Refs SPARQL returned 0 rows for ", assessment_id,
         ". Check the Fuseki dataset loaded correctly.")
  }

  refs <- refs_raw |>
    dplyr::mutate(
      assessment = assessment_id,
      zotero_group = vapply(zotero, extract_zotero_group, character(1)),
      zotero_key = vapply(zotero, extract_zotero_key, character(1)),
      citation = ifelse(
        !is.na(zotero_key) & nzchar(zotero_key),
        paste0("[", zotero_key, "]"),
        NA_character_
      )
    ) |>
    dplyr::select(assessment, km = km_id, bm = bm_id, sm = sm_id,
                  doi, description, citation, zotero_group, zotero_key, zotero)

  refs
}

extract_sections_from_endpoint <- function(endpoint, assessment_id) {
  message("Querying SPARQL sections endpoint for ", assessment_id, " ...")

  # DB2: section content — KM → BM → SM → SubChapter(content) → Chapter(section)
  sparql_sections <- '
    PREFIX ipbes: <http://ontology.ipbes.net/report>
    PREFIX dcterms: <http://purl.org/dc/terms/>

    SELECT DISTINCT ?km_id ?bm_id ?section_id ?subsection_id ?content
    WHERE {
      ?km  a ipbes:KeyMessage ;
           dcterms:identifier ?km_id ;
           ipbes:BackgroundMessage ?bm .
      ?bm  dcterms:identifier ?bm_id ;
           ipbes:SubMessage ?sm .
      ?sm  ipbes:SubChapter ?sch .
      ?sch dcterms:identifier ?subsection_id .
      OPTIONAL { ?sch ipbes:hasDescription ?content . }
      OPTIONAL {
        ?sch ipbes:Chapter ?ch .
        ?ch  dcterms:identifier ?section_id .
      }
    }
  '

  tictoc::tic("  query sections (DB2)")
  sections_raw <- sparql_query(endpoint, sparql_sections)
  tictoc::toc()
  message("  Sections rows: ", nrow(sections_raw))

  sections <- sections_raw |>
    dplyr::mutate(assessment = assessment_id) |>
    dplyr::select(assessment, km = km_id, bm = bm_id,
                  section = section_id, subsection = subsection_id, content)

  sections
}

extract_key_messages_from_endpoint <- function(endpoint, assessment_id) {
  message("Querying SPARQL key/background messages endpoint for ", assessment_id, " ...")

  # DB3: KM and BM descriptive text — KM → BM (both with optional hasDescription)
  sparql_key_messages <- '
    PREFIX ipbes: <http://ontology.ipbes.net/report>
    PREFIX dcterms: <http://purl.org/dc/terms/>

    SELECT DISTINCT ?km_id ?km_description ?bm_id ?bm_description
    WHERE {
      ?km  a ipbes:KeyMessage ;
           dcterms:identifier ?km_id ;
           ipbes:BackgroundMessage ?bm .
      ?bm  dcterms:identifier ?bm_id .
      OPTIONAL { ?km ipbes:hasDescription ?km_description . }
      OPTIONAL { ?bm ipbes:hasDescription ?bm_description . }
    }
  '

  tictoc::tic("  query key/background messages (DB3)")
  km_raw <- sparql_query(endpoint, sparql_key_messages)
  tictoc::toc()
  message("  Key/Background Message rows: ", nrow(km_raw))

  if (nrow(km_raw) == 0) {
    stop("Key messages SPARQL returned 0 rows for ", assessment_id,
         ". Check the Fuseki dataset loaded correctly.")
  }

  km_raw |>
    dplyr::mutate(assessment = assessment_id) |>
    dplyr::select(
      assessment,
      km = km_id, km_description,
      bm = bm_id, bm_description
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
