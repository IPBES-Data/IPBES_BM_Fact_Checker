# QA view for how nli_ready_evidence_parquet actually split each BM into
# claims -- for every (km, bm, sentence_source), the full original
# bm_description/bm_label text with each claim's source span
# colour-highlighted inline, followed by an indented, colour-matched list
# of the resulting claims (with their confidence qualifier, if any, on its
# own line beneath the claim text). Replaced an earlier DT::datatable()
# version (one row per claim, truncated + hover tooltip) that made it hard
# to see a BM's full text and its claims together, or which part of the
# text a claim came from.
#
# Reads nli_ready_evidence_parquet's ACTUAL on-disk claim/confidence output
# (distinct()-ed back down to one row per claim) -- same as the DT version
# did -- so the claim text/confidence shown can never drift from what
# actually got scored.
#
# Highlighting is based on each claim's RAW, pre-strip segment (the slice
# of the original text it was cut from, before braces/confidence
# qualifiers are stripped and, for atomic_bm, before LLM completion) --
# NOT the persisted `claim` text, which for atomic_bm can contain words
# (e.g. "that") the completion step added and that never appeared in the
# source. The raw segment is always a literal, contiguous, in-order slice
# of the original field text for all three granularities, so it's what
# highlighting is actually built from; the (possibly completed) `claim`
# text is what the list below shows.
#
# For naive_bm/complete_bm, segment_bm_by_evidence()/segment_bm_whole()
# (R/build_nli_ready_evidence_parquet.R) are deliberately NOT called here
# to recover the raw span -- small `*_raw()` siblings below duplicate only
# their splitting step instead (same reasoning
# build_llm_candidate_scope_parquet.R's extract_claim_evidence_tokens()
# already documents for its own duplication of segment_bm_by_evidence():
# avoids this cheap, report-only target being needlessly coupled to every
# edit of a function it doesn't need most of). Since neither granularity
# has an LLM completion step, the *_raw() duplicate's own copy of the same
# nchar-floor filters keeps its segment count exactly aligned with the
# real persisted claim count -- verified empirically, no fallback ever
# triggers for these two.
#
# atomic_bm is different: complete_bm_fragments() (R/build_claim_completion.R)
# applies its OWN nchar > 20 floor to the LLM-COMPLETED text, which a
# static *_raw() duplicate has no way to predict (real data: e.g. a
# trailing "(Appendix I)." fragment survives raw splitting but gets
# dropped post-completion). Rather than fall back to unhighlighted text
# whenever that happens, this file calls the REAL segment_bm_atomic() and
# complete_bm_fragments() for real (safe: every fragment for
# already-built data is fully cached, so this reads the cache and makes
# zero new LLM calls) and aligns the surviving completed fragments back to
# this file's own *_raw() pre-strip spans by walking both in order (a
# fragment's exact text is unique enough within one field's raw list, in
# the rare real sense that matters here, since complete_bm_fragments()
# preserves relative order and only drops rows).

# Escape regex metacharacters, then collapse literal whitespace runs into
# `\s+` -- segment_bm_by_evidence_raw()'s sentence accumulation runs each
# sentence through str_squish() before pasting them back together, so a
# reconstructed raw segment is not always a byte-exact substring of the
# original (double spaces, etc., get normalized away). Locating it via a
# whitespace-flexible regex instead of a literal match handles that.
bm_highlight_regex_escape <- function(x) {
  gsub("([.^$|()\\[\\]{}*+?\\\\])", "\\\\\\1", x, perl = TRUE)
}

bm_highlight_flexible_pattern <- function(x) {
  stringr::str_replace_all(bm_highlight_regex_escape(x), "[ \t\n\r]+", "\\\\s+")
}

# Locate `raw_segments` (in order) inside `text`, searching each one
# strictly after the previous match's end -- keeps segments in order and
# avoids matching a segment against a duplicate occurrence elsewhere in
# the text. Returns a tibble(start, end) (1-indexed, inclusive character
# positions into `text`) or NULL if any segment can't be located, so the
# caller can fall back to plain, unhighlighted text rather than mis-pair
# colours to claims.
bm_highlight_locate_segments <- function(text, raw_segments) {
  n <- length(raw_segments)
  if (!n) {
    return(NULL)
  }
  starts <- integer(n)
  ends <- integer(n)
  cursor <- 1L
  text_len <- nchar(text)
  for (i in seq_len(n)) {
    if (cursor > text_len) {
      return(NULL)
    }
    pat <- bm_highlight_flexible_pattern(raw_segments[[i]])
    remaining <- substr(text, cursor, text_len)
    m <- stringr::str_locate(remaining, pat)
    if (is.na(m[1L, "start"])) {
      return(NULL)
    }
    starts[[i]] <- cursor + m[1L, "start"] - 1L
    ends[[i]] <- cursor + m[1L, "end"] - 1L
    cursor <- ends[[i]] + 1L
  }
  dplyr::tibble(start = starts, end = ends)
}

bm_highlight_escape_html <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub("\"", "&quot;", x, fixed = TRUE)
  x
}

# Evidence-reference brace content (e.g. "2.3.5.3", or "2.3.4.2, 3.3.2.2"
# for a multi-reference brace) -- pulled from the RAW pre-strip segment
# (the same one highlighting is built from, see file header), since the
# persisted `claim` text has braces stripped out entirely and never
# carries this information. A segment can carry more than one brace group
# (e.g. naive_bm's multi-sentence accumulation); all of them are joined
# with "; ", same convention extract_bm_confidence() uses for multiple
# qualifiers. NA when the segment has no evidence brace at all.
bm_extract_evidence_refs <- function(x) {
  m <- stringr::str_extract_all(x, "\\{[^}]*\\}")
  vapply(m, function(refs) {
    if (!length(refs)) {
      return(NA_character_)
    }
    paste(stringr::str_remove_all(refs, "[{}]"), collapse = "; ")
  }, character(1))
}

# Small, fixed, light/pastel qualitative palette (dark default text stays
# legible on all of them) -- cycles by claim index when a field has more
# claims than colours. Exact codes are a starting point, not load-bearing;
# adjust after a real visual check if any pair reads as too similar.
bm_highlight_palette <- c(
  "#FFE8CC", "#D3F9D8", "#D0EBFF", "#FFF3BF", "#F3D9FA",
  "#C5F6FA", "#FFDEEB", "#E9ECEF", "#D8F5A2", "#B2F2BB"
)

bm_highlight_color <- function(i) {
  bm_highlight_palette[[(i - 1L) %% length(bm_highlight_palette) + 1L]]
}

# ── *_raw() span helpers -- see file header for why these duplicate only
# the splitting step of segment_bm_by_evidence()/segment_bm_whole() ────────

# Mirrors segment_bm_by_evidence()'s sentence-accumulate-until-terminal-
# brace splitting, returning the pre-strip segment text instead of
# stripped claims. Reapplies the same nchar(stripped) > 20 floor so the
# segment COUNT matches the real persisted claim count exactly (true by
# construction: both derive from the identical splitting rule, and
# naive_bm has no completion step to introduce drift afterwards).
segment_bm_by_evidence_raw <- function(text) {
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
  ends_with_ref <- stringr::str_detect(sentences, "\\}[)]?[.!?…]*\\s*$")
  segments <- character(0)
  buffer <- character(0)
  for (i in seq_along(sentences)) {
    buffer <- c(buffer, sentences[[i]])
    if (ends_with_ref[[i]]) {
      segments <- c(segments, paste(buffer, collapse = " "))
      buffer <- character(0)
    }
  }
  if (length(buffer)) {
    segments <- c(segments, paste(buffer, collapse = " "))
  }
  stripped <- strip_bm_confidence(stringr::str_squish(
    stringr::str_remove_all(segments, "\\s*\\{[^}]*\\}")
  ))
  segments[nchar(stripped) > 20L]
}

# complete_bm has no splitting -- the whole field is the one raw segment,
# same nchar floor as segment_bm_whole().
segment_bm_whole_raw <- function(text) {
  if (is.na(text) || !nzchar(text)) {
    return(character(0))
  }
  claim <- strip_bm_confidence(stringr::str_squish(
    stringr::str_remove_all(text, "\\s*\\{[^}]*\\}")
  ))
  if (nchar(claim) <= 20L) {
    return(character(0))
  }
  text
}

# Mirrors segment_bm_atomic()'s split-at-every-brace-or-unpaired-confidence-
# qualifier pattern (including not splitting a brace away from a
# confidence qualifier that immediately follows it -- see that function's
# own header comment), returning pre-strip fragments -- used only to get
# the RAW spans; which of these actually survive into the persisted claim
# set is resolved separately below (bm_atomic_raw_segments_aligned()),
# since a static duplicate can't predict complete_bm_fragments()'s
# post-completion filtering.
segment_bm_atomic_raw <- function(text) {
  if (is.na(text) || !nzchar(text)) {
    return(character(0))
  }
  atomic_split_pattern <- paste0(
    "(?<=\\})(?!\\s*", segment_bm_confidence_pattern, ")\\s*",
    "|",
    "(?<=", segment_bm_confidence_pattern, ")(?!\\s*\\{)\\s*"
  )
  segments <- stringr::str_split(text, atomic_split_pattern)[[1L]]
  segments <- segments[nzchar(stringr::str_squish(segments))]
  claims <- stringr::str_remove(
    strip_bm_confidence(stringr::str_squish(
      stringr::str_remove_all(segments, "\\s*\\{[^}]*\\}")
    )),
    "^[;,.]+\\s*"
  )
  segments[stringr::str_detect(claims, "[[:alpha:]]")]
}

# For each element of `completed_fragment` (a subsequence, in order, of
# `raw_claim` -- complete_bm_fragments() only ever drops rows, never
# reorders), find its position in `raw_claim` by walking both lists
# forward together. Correct even if `raw_claim` has literal duplicates,
# as long as the two lists agree on relative order (guaranteed here).
bm_align_surviving_indices <- function(raw_claim, completed_fragment) {
  idx <- integer(length(completed_fragment))
  cursor <- 1L
  n <- length(raw_claim)
  for (i in seq_along(completed_fragment)) {
    while (cursor <= n && raw_claim[[cursor]] != completed_fragment[[i]]) {
      cursor <- cursor + 1L
    }
    idx[[i]] <- if (cursor <= n) cursor else NA_integer_
    cursor <- cursor + 1L
  }
  idx
}

# atomic_bm's raw spans, filtered and reordered to exactly match the real
# persisted claim set for this field (see file header). `completion_cfg`/
# `completion_api_key` are only used if a fragment isn't already cached --
# for any assessment/granularity that's already been built, this is a
# pure cache read.
bm_atomic_raw_segments_aligned <- function(text, completion_cfg, completion_api_key) {
  raw_pre <- segment_bm_atomic(text)
  if (!nrow(raw_pre)) {
    return(character(0))
  }
  raw_spans_pre <- segment_bm_atomic_raw(text)
  if (length(raw_spans_pre) != nrow(raw_pre)) {
    return(NULL)
  }
  completed <- complete_bm_fragments(
    raw_pre$claim, completion_cfg, completion_api_key,
    confidence = raw_pre$confidence
  )
  if (!nrow(completed)) {
    return(character(0))
  }
  idx <- bm_align_surviving_indices(raw_pre$claim, completed$original_fragment)
  if (anyNA(idx)) {
    return(NULL)
  }
  raw_spans_pre[idx]
}

# One field's worth of highlighted original text + claim list, as one HTML
# string. `raw_segments` is this field's already-resolved, in-order list
# of pre-strip spans (NULL signals "couldn't be resolved" -- render plain
# text). `claims_sub` is this (km, bm, sentence_source)'s claims, sorted
# by sentence_number, with a `confidence` column always present (NA where
# absent/not applicable). Falls back to plain (still HTML-escaped,
# unhighlighted) text -- with a warning(), never an error -- whenever the
# raw segment count doesn't match nrow(claims_sub) or any segment can't be
# located; the claim list itself is always shown from the real persisted
# data regardless.
#
# Each list item also shows the evidence-reference brace content (e.g.
# "2.3.5.3") and the confidence qualifier, each on its own line, "n/a"
# where either is absent (NOT a run of hyphens -- Pandoc's smart-typography
# pass converts repeated "-" into en/em dashes even inside literal HTML
# text, so a placeholder like "----" renders as a mangled "—-") -- these
# values are pulled from `raw_segments` (evidence)
# and `claims_sub$confidence`, independently of whether the span could be
# LOCATED in the visible text: knowing a segment's own raw text is enough
# to read its evidence braces out of it, even on the rare field where
# highlighting itself falls back to plain text.
build_bm_field_html <- function(text, raw_segments, claims_sub, field_label) {
  n_claims <- nrow(claims_sub)
  raw_segments_ok <- !is.null(raw_segments) && length(raw_segments) == n_claims && n_claims > 0L
  evidence_refs <- if (raw_segments_ok) {
    bm_extract_evidence_refs(raw_segments)
  } else {
    rep(NA_character_, n_claims)
  }
  spans <- NULL
  if (raw_segments_ok) {
    spans <- bm_highlight_locate_segments(text, raw_segments)
  }
  if (is.null(spans) && n_claims > 0L) {
    warning(sprintf(
      "build_bm_field_html: could not align %s raw segment(s) to %d claim(s) for %s -- rendering plain text",
      if (is.null(raw_segments)) "unresolved" else length(raw_segments), n_claims, field_label
    ))
  }

  if (is.null(spans)) {
    body_html <- paste0("<p>", bm_highlight_escape_html(text), "</p>")
  } else {
    pieces <- character(0)
    cursor <- 1L
    for (i in seq_len(n_claims)) {
      if (spans$start[[i]] > cursor) {
        pieces <- c(pieces, bm_highlight_escape_html(substr(text, cursor, spans$start[[i]] - 1L)))
      }
      seg_text <- bm_highlight_escape_html(substr(text, spans$start[[i]], spans$end[[i]]))
      pieces <- c(pieces, sprintf(
        '<mark style="background:%s;">%s</mark>', bm_highlight_color(i), seg_text
      ))
      cursor <- spans$end[[i]] + 1L
    }
    if (cursor <= nchar(text)) {
      pieces <- c(pieces, bm_highlight_escape_html(substr(text, cursor, nchar(text))))
    }
    body_html <- paste0("<p>", paste(pieces, collapse = ""), "</p>")
  }

  list_items <- vapply(seq_len(n_claims), function(i) {
    evidence_text <- if (!is.na(evidence_refs[[i]])) bm_highlight_escape_html(evidence_refs[[i]]) else "n/a"
    confidence_text <- if (!is.na(claims_sub$confidence[[i]])) bm_highlight_escape_html(claims_sub$confidence[[i]]) else "n/a"
    sprintf(
      '<li style="border-left: 4px solid %s; padding-left: 8px; margin-bottom: 6px;">%s<br>%s<br><strong>%s</strong></li>',
      bm_highlight_color(i), bm_highlight_escape_html(claims_sub$claim[[i]]), evidence_text, confidence_text
    )
  }, character(1))
  list_html <- if (length(list_items)) {
    paste0("<ol>", paste(list_items, collapse = ""), "</ol>")
  } else {
    ""
  }

  paste0(body_html, list_html)
}

build_bm_split_highlighted <- function(
  assessment,
  nli_ready_evidence_parquet,
  key_messages_parquet,
  granularity,
  output_root = "output/tables",
  completion_model = NULL
) {
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  assessment_id <- assessment$id
  gran_suffix <- paste0("_", granularity)

  # Only needed for atomic_bm's real-completion alignment (see file
  # header) -- lazy, same pattern build_nli_ready_evidence_parquet() uses
  # for its own api_key fetch, so naive_bm/complete_bm callers stay free
  # of any keyring dependency.
  completion_cfg <- NULL
  completion_api_key <- NULL
  if (identical(granularity, "atomic_bm")) {
    completion_cfg <- list(model = completion_model %||% "openai/gpt-4o-mini")
    completion_api_key <- Sys.getenv("API_openrouter")
  }

  # Arrow's dplyr backend doesn't support any_of() as a lazy selection --
  # resolve the real column set in plain R first, collect, then normalize
  # confidence into an always-present column (NA where absent/not
  # applicable) so downstream HTML-building code doesn't need to branch on
  # whether the column exists.
  ds <- arrow::open_dataset(nli_ready_evidence_parquet)
  base_cols <- c("km", "bm", "sentence_source", "sentence_number", "claim")
  cols <- if ("confidence" %in% names(ds)) c(base_cols, "confidence") else base_cols

  claims <- ds |>
    dplyr::select(dplyr::all_of(cols)) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::arrange(km, bm, sentence_source, sentence_number)
  if (!"confidence" %in% names(claims)) {
    claims$confidence <- NA_character_
  }

  km_root <- unique(dirname(key_messages_parquet))[[1L]]
  bm_info <- arrow::open_dataset(km_root) |>
    dplyr::filter(assessment == assessment_id) |>
    dplyr::select(km, km_label, bm, bm_description, bm_label) |>
    dplyr::distinct() |>
    dplyr::collect() |>
    dplyr::arrange(km, bm)

  joined <- claims |>
    dplyr::left_join(
      bm_info |> dplyr::select(km, bm, bm_description, bm_label),
      by = c("km", "bm")
    ) |>
    dplyr::mutate(
      original_text = dplyr::if_else(
        sentence_source == "bm_description", bm_description, bm_label
      )
    ) |>
    dplyr::select(km, bm, sentence_source, original_text, sentence_number, claim, confidence)

  raw_segments_for <- function(text) {
    switch(granularity,
      atomic_bm = bm_atomic_raw_segments_aligned(text, completion_cfg, completion_api_key),
      complete_bm = segment_bm_whole_raw(text),
      segment_bm_by_evidence_raw(text)
    )
  }

  # Build the report body: one KM heading per distinct km, one BM+field
  # heading (h4) per (bm, sentence_source) actually present, in that order.
  field_order <- c("bm_description", "bm_label")
  km_ids <- unique(bm_info$km)
  section_html <- vapply(km_ids, function(km_id) {
    km_row <- bm_info[bm_info$km == km_id, ][1L, ]
    bm_ids <- unique(bm_info$bm[bm_info$km == km_id])
    bm_html <- vapply(bm_ids, function(bm_id) {
      row <- bm_info[bm_info$km == km_id & bm_info$bm == bm_id, ][1L, ]
      fields <- Filter(function(src) {
        txt <- if (src == "bm_description") row$bm_description else row$bm_label
        !is.na(txt) && nzchar(txt)
      }, field_order)
      field_html <- vapply(fields, function(src) {
        text <- if (src == "bm_description") row$bm_description else row$bm_label
        claims_sub <- joined[
          joined$km == km_id & joined$bm == bm_id & joined$sentence_source == src,
        ]
        claims_sub <- claims_sub[order(claims_sub$sentence_number), ]
        body <- build_bm_field_html(
          text, raw_segments_for(text), claims_sub,
          field_label = sprintf("%s / %s / %s", assessment_id, bm_id, src)
        )
        sprintf("\n\n#### %s \\-\\- %s\n\n%s\n", bm_id, src, body)
      }, character(1))
      paste(field_html, collapse = "")
    }, character(1))
    sprintf("\n\n### %s (%s)\n%s\n", km_row$km_label %||% km_id, km_id, paste(bm_html, collapse = ""))
  }, character(1))

  html <- paste(section_html, collapse = "")

  fn_stem <- sprintf("bm_split_highlighted_%s%s", assessment_id, gran_suffix)
  fn_rds <- file.path(output_root, paste0(fn_stem, ".rds"))
  saveRDS(
    list(assessment = assessment_id, granularity = granularity, data = joined, html = html),
    file = fn_rds
  )
  fn_rds
}
