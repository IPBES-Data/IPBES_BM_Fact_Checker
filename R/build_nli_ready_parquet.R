# Build the NLI-ready parquet database.
#
# For each (assessment, km, bm) partition this target produces one row per
# (citing work × BM sentence), storing everything the NLI scoring step needs
# in one place:
#
#   claim  — one sentence from the BM description (NLI hypothesis).
#                  Falls back to bm_label when bm_description is absent.
#   premise      — clean(title) + clean(abstract) of the citing work (NLI premise).
#
# Sentence splitting uses a simple sentence-boundary regex.  Fragments shorter
# than 20 characters are dropped (headings, trailing labels, etc.).
#
# The cross-join (work × sentence) is intentional: the NLI scoring step scores
# each work against every retained BM sentence separately, then aggregates.

build_nli_ready_parquet <- function(
  assessment,
  key_messages_parquet,
  works_citing_parquet,
  workers    = 1L,
  output_root = "output/nli_ready"
) {
  assessment_id <- assessment$id
  now <- function() format(Sys.time(), "%H:%M:%S")

  # ── 1. BM sentences for this assessment ──────────────────────────────────
  km_root <- unique(dirname(key_messages_parquet))[[1L]]
  bm_info <- arrow::open_dataset(km_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, km_label, bm, bm_label, bm_description) |>
    dplyr::distinct() |>
    dplyr::collect()

  claims <- dplyr::bind_rows(lapply(seq_len(nrow(bm_info)), function(i) {
    row <- bm_info[i, , drop = FALSE]
    has_desc  <- !is.na(row$bm_description) && nzchar(row$bm_description)
    has_label <- !is.na(row$bm_label)        && nzchar(row$bm_label)

    # Build a named list of sources to split: use both when both are present,
    # otherwise whichever is available.
    sources <- list()
    if (has_desc)  sources[["bm_description"]] <- row$bm_description
    if (has_label) sources[["bm_label"]]        <- row$bm_label
    if (!length(sources)) return(NULL)

    dplyr::bind_rows(lapply(names(sources), function(src) {
      sents <- stringr::str_squish(
        stringr::str_split(sources[[src]], "(?<=[.!?])\\s+")[[1L]]
      )
      sents <- sents[nchar(sents) > 20L]
      if (!length(sents)) return(NULL)
      dplyr::tibble(
        km              = row$km,
        km_label        = row$km_label,
        bm              = row$bm,
        bm_label        = row$bm_label,
        sentence_source = src,
        sentence_number = seq_along(sents),
        claim     = sents
      )
    }))
  }))

  # ── 2. Process works_citing partitions in parallel ───────────────────────
  output_path <- file.path(output_root, paste0("assessment=", assessment_id))
  if (file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }

  scalar_cols <- c("id", "doi", "title", "abstract", "publication_year")

  # works_citing_parquet now carries two paths per assessment: the slim
  # per-(km, bm) id mapping (the km=/bm= tree walked below) and the
  # deduplicated metadata table the premise text comes from.
  # See R/build_works_citing_parquet.R.
  wc_map  <- works_citing_map_paths(works_citing_parquet)[[1L]]
  wc_meta <- works_citing_meta_paths(works_citing_parquet)[[1L]]

  # All (km, bm) groups, one element each, so mclapply can distribute them.
  groups   <- works_citing_groups(wc_map)
  bm_pairs <- split(groups, seq_len(nrow(groups)))

  results <- parallel::mclapply(bm_pairs, function(pair) {
    km_val <- pair$km[[1L]]
    bm_val <- pair$bm[[1L]]

    sents_bm <- claims[
      claims$km == km_val & claims$bm == bm_val, ,
      drop = FALSE
    ]
    if (!nrow(sents_bm)) {
      message(sprintf(
        "[NLI_READY %s] %s km=%s / bm=%s: no sentences — skipping",
        assessment_id, now(), km_val, bm_val
      ))
      return(FALSE)
    }

    works <- works_citing_group(wc_map, km_val, bm_val, wc_meta, scalar_cols)
    if (is.null(works) || !nrow(works)) return(FALSE)

    for (mc in setdiff(scalar_cols, names(works))) works[[mc]] <- NA
    works <- works |>
      dplyr::mutate(
        dplyr::across(dplyr::any_of(c("id", "doi", "title", "abstract")), as.character),
        publication_year = suppressWarnings(as.integer(publication_year))
      ) |>
      dplyr::rename(work_id = id) |>
      dplyr::mutate(
        premise = trimws(paste(
          dplyr::coalesce(vapply(title,    clean_title,    character(1L)), ""),
          dplyr::coalesce(vapply(abstract, clean_abstract, character(1L)), "")
        ))
      ) |>
      dplyr::select(work_id, premise)

    # Cross-join: every work × every BM sentence for this partition.
    # approx_tokens: rough token estimate for the full (premise, hypothesis)
    # pair sent to the NLI model — (nchar / 4) + 3 special tokens
    # ([CLS] premise [SEP] hypothesis [SEP]).  Divide by 4 is a standard
    # English-text approximation; actual subword counts vary by ±15 %.
    out <- dplyr::cross_join(
      sents_bm |> dplyr::select(sentence_source, sentence_number, claim),
      works
    ) |>
      dplyr::mutate(
        assessment      = assessment_id,
        km              = km_val,
        bm              = bm_val,
        abstract_tokens = as.integer(round(nchar(premise) / 4)),
        sentence_tokens = as.integer(round(nchar(claim)   / 4)),
        approx_tokens   = abstract_tokens + sentence_tokens + 3L
      ) |>
      dplyr::select(
        km, bm, sentence_number, claim, sentence_source,
        work_id, premise, abstract_tokens, sentence_tokens, approx_tokens,
        assessment
      )

    message(sprintf(
      "[NLI_READY %s] %s km=%s / bm=%s: %d works × %d sentences = %d rows",
      assessment_id, now(), km_val, bm_val,
      nrow(works), nrow(sents_bm), nrow(out)
    ))

    arrow::write_dataset(
      dataset                = out,
      path                   = output_root,
      format                 = "parquet",
      partitioning           = c("assessment", "km", "bm"),
      existing_data_behavior = "overwrite"
    )
    TRUE
  }, mc.cores = workers)

  if (!any(unlist(results))) {
    message(sprintf("[NLI_READY %s] no partitions written", assessment_id))
  }

  output_path
}
