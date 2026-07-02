# Build the NLI-ready parquet database — EVIDENCE-REFERENCE segmentation.
#
# This is the SECOND of two segmentation approaches (see NEXT_STEPS.md,
# "Alternative claim segmentation"). It parallels build_nli_ready_parquet()
# in every respect except how a BM's text is cut into claims:
#
#   build_nli_ready_parquet()          -> one claim per SENTENCE
#   build_nli_ready_evidence_parquet() -> one claim per EVIDENCE-DELIMITED
#                                         segment (this file)
#
# Both write the identical column schema (km, bm, sentence_number, claim,
# sentence_source, work_id, premise, abstract_tokens, sentence_tokens,
# approx_tokens, assessment) so the SAME downstream targets
# (build_nli_claim_units / score_one_claim) consume either one unchanged —
# only the output_root differs (output/nli_ready_evidence vs output/nli_ready).
#
# The existing sentence-based builder is deliberately left untouched so its
# already-materialised target output and hash are not invalidated.

# ── Evidence-reference segmentation ─────────────────────────────────────────
#
# IPBES BM text carries inline evidence references to the backing
# sub-chapters, as brace groups: {5.4.1, 5.4.2}, {box 2.6; 4.6}, {table 4.33}.
# A brace that ENDS a sentence marks the end of one discrete, evidenced
# (sub-)claim. Rule (see NEXT_STEPS.md for the data behind it):
#
#   1. Split the text into sentences, then accumulate consecutive sentences
#      into one claim until a sentence ENDS with a brace group (a "terminal"
#      brace). Multiple sentences before that brace stay together as one claim.
#      A brace in the MIDDLE of a sentence is an inline citation and does NOT
#      split — sentence granularity handles that for free.
#   2. Any trailing sentences with no terminal brace (e.g. a synthesising final
#      sentence), and the whole text when it contains no braces at all, are
#      emitted as one claim rather than dropped.
#   3. Brace markers are stripped from the returned claim text (they are
#      provenance, not part of the assertion).
#
# Returns a character vector of claim strings (braces removed, squished),
# empty-after-strip segments dropped.
segment_bm_by_evidence <- function(text) {
  if (is.na(text) || !nzchar(text)) {
    return(character(0))
  }

  sentences <- stringr::str_squish(
    stringr::str_split(text, "(?<=[.!?])\\s+")[[1L]]
  )
  sentences <- sentences[nzchar(sentences)]
  if (!length(sentences)) {
    return(character(0))
  }

  # A sentence is "terminal" when, ignoring trailing sentence punctuation and
  # a closing paren, it ends with a brace group } — i.e. the reference is the
  # last meaningful token.
  ends_with_ref <- stringr::str_detect(
    sentences, "\\}[)]?[.!?…]*\\s*$"
  )

  segments <- character(0)
  buffer <- character(0)
  for (i in seq_along(sentences)) {
    buffer <- c(buffer, sentences[[i]])
    if (ends_with_ref[[i]]) {
      segments <- c(segments, paste(buffer, collapse = " "))
      buffer <- character(0)
    }
  }
  # Flush any trailing sentences that never hit a terminal brace (rule 2).
  if (length(buffer)) {
    segments <- c(segments, paste(buffer, collapse = " "))
  }

  # Strip brace groups (and any whitespace they leave behind), then squish.
  claims <- stringr::str_squish(
    stringr::str_remove_all(segments, "\\s*\\{[^}]*\\}")
  )
  claims <- claims[nchar(claims) > 20L]
  claims
}

build_nli_ready_evidence_parquet <- function(
  assessment,
  key_messages_parquet,
  works_citing_parquet,
  workers = 1L,
  output_root = "output/nli_ready_evidence"
) {
  assessment_id <- assessment$id
  now <- function() format(Sys.time(), "%H:%M:%S")

  # ── 1. BM claims (evidence-segmented) for this assessment ────────────────
  km_root <- unique(dirname(key_messages_parquet))[[1L]]
  bm_info <- arrow::open_dataset(km_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, km_label, bm, bm_label, bm_description) |>
    dplyr::distinct() |>
    dplyr::collect()

  claims <- dplyr::bind_rows(lapply(seq_len(nrow(bm_info)), function(i) {
    row <- bm_info[i, , drop = FALSE]
    has_desc <- !is.na(row$bm_description) && nzchar(row$bm_description)
    has_label <- !is.na(row$bm_label) && nzchar(row$bm_label)

    sources <- list()
    if (has_desc) sources[["bm_description"]] <- row$bm_description
    if (has_label) sources[["bm_label"]] <- row$bm_label
    if (!length(sources)) {
      return(NULL)
    }

    dplyr::bind_rows(lapply(names(sources), function(src) {
      segs <- segment_bm_by_evidence(sources[[src]])
      if (!length(segs)) {
        return(NULL)
      }
      dplyr::tibble(
        km = row$km,
        km_label = row$km_label,
        bm = row$bm,
        bm_label = row$bm_label,
        sentence_source = src,
        sentence_number = seq_along(segs),
        claim = segs
      )
    }))
  }))

  # ── 2. Process works_citing partitions in parallel ───────────────────────
  output_path <- file.path(output_root, paste0("assessment=", assessment_id))
  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }

  scalar_cols <- c("id", "doi", "title", "abstract", "publication_year")

  km_dirs <- list.dirs(works_citing_parquet, recursive = FALSE)
  bm_pairs <- do.call(c, lapply(km_dirs, function(km_dir) {
    lapply(list.dirs(km_dir, recursive = FALSE), function(bm_dir) {
      list(km_dir = km_dir, bm_dir = bm_dir)
    })
  }))

  results <- parallel::mclapply(bm_pairs, function(pair) {
    km_val <- sub("^km=", "", basename(pair$km_dir))
    bm_val <- sub("^bm=", "", basename(pair$bm_dir))

    sents_bm <- claims[
      claims$km == km_val & claims$bm == bm_val, ,
      drop = FALSE
    ]
    if (!nrow(sents_bm)) {
      message(sprintf(
        "[NLI_READY_EV %s] %s km=%s / bm=%s: no claims — skipping",
        assessment_id, now(), km_val, bm_val
      ))
      return(FALSE)
    }

    files <- list.files(pair$bm_dir, pattern = "\\.parquet$", full.names = TRUE)
    if (!length(files)) {
      return(FALSE)
    }

    works <- dplyr::bind_rows(lapply(files, function(f) {
      arrow::read_parquet(f) |>
        dplyr::select(dplyr::any_of(scalar_cols))
    }))
    if (!nrow(works)) {
      return(FALSE)
    }

    for (mc in setdiff(scalar_cols, names(works))) works[[mc]] <- NA
    works <- works |>
      dplyr::mutate(
        dplyr::across(dplyr::any_of(c("id", "doi", "title", "abstract")), as.character),
        publication_year = suppressWarnings(as.integer(publication_year))
      ) |>
      dplyr::rename(work_id = id) |>
      dplyr::mutate(
        premise = trimws(paste(
          vapply(title, clean_title, character(1L)),
          vapply(abstract, clean_abstract, character(1L))
        ))
      ) |>
      dplyr::select(work_id, premise)

    out <- dplyr::cross_join(
      sents_bm |> dplyr::select(sentence_source, sentence_number, claim),
      works
    ) |>
      dplyr::mutate(
        assessment = assessment_id,
        km = km_val,
        bm = bm_val,
        abstract_tokens = as.integer(round(nchar(premise) / 4)),
        sentence_tokens = as.integer(round(nchar(claim) / 4)),
        approx_tokens = abstract_tokens + sentence_tokens + 3L
      ) |>
      dplyr::select(
        km, bm, sentence_number, claim, sentence_source,
        work_id, premise, abstract_tokens, sentence_tokens, approx_tokens,
        assessment
      )

    message(sprintf(
      "[NLI_READY_EV %s] %s km=%s / bm=%s: %d works × %d claims = %d rows",
      assessment_id, now(), km_val, bm_val,
      nrow(works), nrow(sents_bm), nrow(out)
    ))

    arrow::write_dataset(
      dataset = out,
      path = output_root,
      format = "parquet",
      partitioning = c("assessment", "km", "bm"),
      existing_data_behavior = "overwrite"
    )
    TRUE
  }, mc.cores = workers)

  if (!any(unlist(results))) {
    message(sprintf("[NLI_READY_EV %s] no partitions written", assessment_id))
  }

  output_path
}
