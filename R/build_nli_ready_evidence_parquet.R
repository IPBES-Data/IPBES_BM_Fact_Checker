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

# ── Confidence-qualifier extraction (shared) ────────────────────────────────
#
# IPBES's 4 standard confidence qualifiers -- "(well established)",
# "(established but incomplete)", "(unresolved)", "(inconclusive)" -- appear
# inline in the source text (e.g. "...clean water (well established)
# {2.3.5.2}"). They're metadata about the claim's evidentiary strength, not
# part of the assertion itself -- same reasoning evidence braces get
# stripped rather than left in the hypothesis text. Extracted into their own
# `confidence` column (checked against real data: exactly these terms occur
# across both assessments, 598 qualifiers total in bm_description/bm_label)
# rather than left in the claim text, so (a) NLI/LLM scoring never sees them
# as if they were part of the claim to entail/refute, and (b)
# complete_bm_fragments()'s LLM completion pass can't silently drop one
# while rewording a fragment -- a real failure mode this fix was found to
# prevent (see TD_BM_NLI_approach.qmd).
segment_bm_confidence_pattern <- "\\((well established|established but incomplete|unresolved|inconclusive)\\)"

# Extract every confidence qualifier occurring in `x` (a character vector,
# one BM segment/fragment per element), pasted together if a segment
# happens to bundle more than one (possible for segment_bm_by_evidence(),
# whose segments can span several accumulated sentences); NA where none
# found.
extract_bm_confidence <- function(x) {
  found <- stringr::str_extract_all(x, segment_bm_confidence_pattern)
  vapply(found, function(m) {
    if (!length(m)) {
      return(NA_character_)
    }
    paste(stringr::str_remove_all(m, "[()]"), collapse = "; ")
  }, character(1))
}

# Remove confidence qualifiers from claim text (companion to
# extract_bm_confidence(), which pulls the same qualifiers OUT into their
# own column) and tidy the whitespace/punctuation left behind -- removing
# "(well established)" from "...clean water (well established); can..."
# leaves a stray space before the semicolon that plain str_squish() doesn't
# catch (it collapses runs of whitespace, but doesn't know to pull a space
# in front of punctuation).
strip_bm_confidence <- function(x) {
  x <- stringr::str_remove_all(x, segment_bm_confidence_pattern)
  x <- stringr::str_replace_all(x, "\\s+([,;.!?])", "\\1")
  stringr::str_squish(x)
}

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
#   3. Brace markers AND confidence qualifiers are stripped from the returned
#      claim text (they are provenance/metadata, not part of the assertion) --
#      the qualifier is returned separately instead (see `confidence` above).
#
# Returns a tibble (claim, confidence): claim = braces + qualifier removed,
# squished; confidence = whichever qualifier (if any) was found in that
# segment, NA otherwise. Empty-after-strip segments dropped. naive_bm had
# never been scored under any NLI config when this was added (checked
# directly against disk), so it carried no risk of invalidating real
# scored data. segment_bm_whole()/complete_bm got the identical treatment
# later, once 949,334 real complete_bm pairs already existed -- that one
# WAS a deliberate, accepted tradeoff (see that function's own comment).
segment_bm_by_evidence <- function(text) {
  empty <- dplyr::tibble(claim = character(0), confidence = character(0))
  if (is.na(text) || !nzchar(text)) {
    return(empty)
  }

  sentences <- stringr::str_squish(
    stringr::str_split(text, "(?<=[.!?])\\s+")[[1L]]
  )
  sentences <- sentences[nzchar(sentences)]
  if (!length(sentences)) {
    return(empty)
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

  confidence <- extract_bm_confidence(segments)

  # Strip brace groups and confidence qualifiers (and whitespace they leave
  # behind), then squish.
  claims <- stringr::str_squish(
    stringr::str_remove_all(segments, "\\s*\\{[^}]*\\}")
  )
  claims <- strip_bm_confidence(claims)
  keep <- nchar(claims) > 20L
  dplyr::tibble(claim = claims[keep], confidence = confidence[keep])
}

# ── "complete BM" segmentation: no splitting at all ─────────────────────────
#
# For the granularity = "complete_bm" NLI config option: treat the whole
# field (bm_description or bm_label) as a single claim, brace groups AND
# confidence qualifiers stripped the same way segment_bm_by_evidence()/
# segment_bm_atomic() do (see segment_bm_confidence_pattern's own comment),
# but with no sentence-level splitting -- one claim per source field, not
# one per evidence-delimited segment. A whole field can carry several
# qualifiers (one per original clause); all of them are extracted and
# joined into the one `confidence` value for this claim, same as
# segment_bm_by_evidence() already does for its own multi-sentence
# segments. Returns a tibble (claim, confidence), 0 rows if the
# stripped text doesn't clear the same length floor the other two
# segmenters use.
#
# NOTE: this changed complete_bm's claim text (confidence qualifiers no
# longer inline) after 949,334 real pairs had already been scored against
# the OLD text -- score_one_claim()'s resumability check is purely
# directory-existence, so those existing scores are NOT automatically
# redone and now reflect stale (pre-strip) claim text until a real rescore
# is run. Deliberate, accepted tradeoff -- see git history/session notes
# for the exact discussion.
segment_bm_whole <- function(text) {
  empty <- dplyr::tibble(claim = character(0), confidence = character(0))
  if (is.na(text) || !nzchar(text)) {
    return(empty)
  }

  confidence <- extract_bm_confidence(text)
  claim <- stringr::str_squish(
    stringr::str_remove_all(text, "\\s*\\{[^}]*\\}")
  )
  claim <- strip_bm_confidence(claim)
  if (nchar(claim) <= 20L) {
    return(empty)
  }
  dplyr::tibble(claim = claim, confidence = confidence)
}

# ── "atomic BM" segmentation: split at EVERY evidence brace ─────────────────
#
# For granularity = "atomic_bm": unlike segment_bm_by_evidence() (which only
# splits at a brace that ends a SENTENCE, treating mid-sentence braces as
# non-splitting inline citations), this splits at EVERY brace group,
# including mid-sentence ones. Real data caught this session: a compound
# clause like "Nature provides X {ref1}; can help Y {ref2}" carries a
# DISTINCT evidence reference per semicolon-separated clause, so
# segment_bm_by_evidence() bundling all of it into one claim (since none of
# the braces end a full sentence) is the same compound-claim problem
# segment_bm_whole() has, just at a smaller scale -- one BM's worth of
# clauses instead of a whole BM. Splitting at every brace fixes that, at the
# cost of routinely producing elliptical fragments (sharing a subject/verb
# with an earlier fragment, e.g. "can help to regulate disease and the
# immune system" has no subject of its own) -- that's expected, and handled
# by a separate LLM completion pass (complete_bm_fragments(),
# R/build_claim_completion.R), NOT here.
#
# ALSO splits after a confidence qualifier -- e.g. "(well established)" --
# whenever it is not immediately followed by its own evidence brace. Real
# QA data (via the split report) caught the same compound-claim problem one
# level up: several sentences can share a single trailing brace between
# them (e.g. "X is Y (well established). Z is W (established but
# incomplete) {ref}."), so splitting on braces alone still bundled two
# independently-rated assertions into one fragment -- visible as two
# qualifiers joined by "; " in the resulting `confidence` column, since a
# genuine single (sub-)claim only ever carries one. A qualifier immediately
# followed by `{` is left alone (it's already paired with its own brace,
# which triggers the split above); tested against every real occurrence of
# this pattern across GA1's own BM text, confirming every resulting
# fragment now carries at most one confidence qualifier. This does produce
# occasional additional, over-fine splits when IPBES's own source text
# tags one assertion with a qualifier twice (e.g. once mid-clause, once at
# the end of an elaborating "including ..." continuation) -- accepted, since
# the completion pass already exists specifically to re-join elliptical
# fragments, and erring toward over-splitting is the same tradeoff this
# whole granularity already makes over segment_bm_by_evidence().
#
# Symmetrically, does NOT split right after a brace when a confidence
# qualifier immediately FOLLOWS it (e.g. "...pollinator loss {2.3.5.3}
# (established but incomplete)." -- the qualifier here comes after the
# brace, the reverse of the usual order). Splitting there unconditionally
# used to cut the qualifier off into its own fragment, which then strips
# down to nothing and gets silently dropped by the nzchar/alpha-content
# filter below -- not just misplaced, but the confidence value was lost
# entirely (a real GA1/A1 case, caught via the QA split report). The
# qualifier instead stays attached to the fragment before it, and is
# picked up by the split point right after ITSELF (the second alternative
# below) instead.
#
# Deliberately does NOT apply segment_bm_by_evidence()'s nchar > 20 floor --
# a short fragment like "and for soil stabilization" is exactly the kind of
# thing that only becomes a valid, complete claim after completion;
# filtering it out here would silently drop a real claim before it gets the
# chance. The length/validity floor for this granularity is applied AFTER
# completion instead (see complete_bm_fragments()).
#
# Confidence qualifiers are extracted the same way as
# segment_bm_by_evidence() -- see segment_bm_confidence_pattern's own
# comment above for the full rationale.
#
# Returns a tibble (claim, confidence) of raw (uncompleted) claim
# fragments -- braces AND confidence qualifiers stripped from `claim`,
# whitespace squished, in original order; `confidence` holds whichever
# qualifier (if any) was found in that fragment, NA otherwise. Empty
# 0-row tibble if the text has no content at all.
segment_bm_atomic <- function(text) {
  empty <- dplyr::tibble(claim = character(0), confidence = character(0))
  if (is.na(text) || !nzchar(text)) {
    return(empty)
  }

  # Split right after every closing brace (a zero-width lookbehind keeps the
  # brace, and everything before it, with the segment it closes), OR right
  # after a confidence qualifier not immediately followed by its own brace
  # (see this function's header comment). Any text after the last split
  # point -- or the whole text, if neither pattern occurs at all -- is
  # naturally produced as the final/only element.
  atomic_split_pattern <- paste0(
    "(?<=\\})(?!\\s*", segment_bm_confidence_pattern, ")\\s*",
    "|",
    "(?<=", segment_bm_confidence_pattern, ")(?!\\s*\\{)\\s*"
  )
  segments <- stringr::str_split(text, atomic_split_pattern)[[1L]]
  segments <- segments[nzchar(stringr::str_squish(segments))]

  confidence <- extract_bm_confidence(segments)

  claims <- stringr::str_squish(
    stringr::str_remove_all(segments, "\\s*\\{[^}]*\\}")
  )
  claims <- strip_bm_confidence(claims)
  # Splitting right after a brace leaves the delimiter that used to separate
  # this clause from the next one (a semicolon, comma, or period) stranded
  # at the START of the following fragment -- strip it. A fragment left with
  # no actual word content (e.g. a lone "." after the final brace) is not a
  # claim at all, just leftover punctuation -- drop it, not filtered by
  # nzchar() alone since "." is one non-empty character.
  claims <- stringr::str_remove(claims, "^[;,.]+\\s*")
  keep <- stringr::str_detect(claims, "[[:alpha:]]")
  dplyr::tibble(claim = claims[keep], confidence = confidence[keep])
}

build_nli_ready_evidence_parquet <- function(
  assessment,
  key_messages_parquet,
  works_citing_parquet,
  workers = 1L,
  output_root = "output/nli_ready_evidence",
  granularity = "naive_bm",
  completion_model = NULL
) {
  assessment_id <- assessment$id
  output_path <- file.path(output_root, paste0("assessment=", assessment_id))

  # Resumability: if this assessment already has parquet output for this
  # EXACT output_root (which already encodes granularity=<value>/ -- see
  # the _targets.R call site), skip regenerating entirely, same
  # short-circuit convention score_one_claim() uses. Without this,
  # switching nli.active back and forth between granularities forces a
  # full rebuild every time `targets` sees granularity's value change --
  # even reverting to a granularity that was already fully built earlier
  # in the session -- since targets only compares against the LAST
  # recorded value, not a history of past ones. For atomic_bm that meant
  # redoing real LLM completion calls for no reason. To force a genuine
  # rebuild (e.g. after a real segmentation/completion code change),
  # delete this assessment's output_path by hand first -- same lever
  # score_one_claim()'s own resumability check requires.
  if (dir.exists(output_path) &&
    length(list.files(output_path, pattern = "\\.parquet$", recursive = TRUE))) {
    message(sprintf(
      "[NLI_READY_EV %s] output already exists at %s (granularity=%s) -- skipping",
      assessment_id, output_path, granularity
    ))
    return(output_path)
  }

  now <- function() format(Sys.time(), "%H:%M:%S")
  # Each granularity is handled via its own explicit branch below in the
  # claims-building loop: naive_bm and atomic_bm both return a (claim,
  # confidence) tibble (confidence-qualifier metadata extracted out of the
  # claim text); complete_bm returns a bare character vector (unchanged --
  # real scored data exists for it, so its segmentation stays untouched).
  # atomic_bm only: LLM-complete elliptical fragments after the raw split
  # (see segment_bm_atomic()'s own comment for why completion is a separate
  # pass rather than folded into the splitter). Fetching the OpenRouter key
  # only when actually needed keeps naive_bm/complete_bm callers free of any
  # keyring dependency, same reasoning build_llm_verification_parquet() uses
  # for its own api_key fetch.
  completion_cfg <- NULL
  completion_api_key <- NULL
  if (identical(granularity, "atomic_bm")) {
    completion_cfg <- list(model = completion_model %||% "openai/gpt-4o-mini")
    completion_api_key <- Sys.getenv("API_openrouter")
    if (!nzchar(completion_api_key)) {
      stop("API_openrouter environment variable is required for granularity = \"atomic_bm\" (set from keyring in _targets.R)")
    }
  }

  # ── 1. BM claims (evidence-segmented, or whole, for this assessment) ─────
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

    # complete_bm only: a BM whose bm_label and bm_description are the same
    # text (after whitespace normalization) should produce one claim, not a
    # duplicate -- drop bm_label, keeping bm_description as the sole source.
    # naive_bm is untouched: it already scores both fields independently
    # regardless of whether they're identical.
    if (identical(granularity, "complete_bm") && has_desc && has_label &&
      identical(stringr::str_squish(row$bm_description), stringr::str_squish(row$bm_label))) {
      sources[["bm_label"]] <- NULL
    }

    dplyr::bind_rows(lapply(names(sources), function(src) {
      if (identical(granularity, "atomic_bm")) {
        raw <- segment_bm_atomic(sources[[src]])
        if (!nrow(raw)) {
          return(NULL)
        }
        completed <- complete_bm_fragments(
          raw$claim, completion_cfg, completion_api_key,
          confidence = raw$confidence
        )
        if (!nrow(completed)) {
          return(NULL)
        }
        return(dplyr::tibble(
          km = row$km,
          km_label = row$km_label,
          bm = row$bm,
          bm_label = row$bm_label,
          sentence_source = src,
          sentence_number = seq_len(nrow(completed)),
          claim = completed$completed_claim,
          confidence = completed$confidence
        ))
      }
      if (identical(granularity, "naive_bm")) {
        raw <- segment_bm_by_evidence(sources[[src]])
        if (!nrow(raw)) {
          return(NULL)
        }
        return(dplyr::tibble(
          km = row$km,
          km_label = row$km_label,
          bm = row$bm,
          bm_label = row$bm_label,
          sentence_source = src,
          sentence_number = seq_len(nrow(raw)),
          claim = raw$claim,
          confidence = raw$confidence
        ))
      }
      # complete_bm
      raw <- segment_bm_whole(sources[[src]])
      if (!nrow(raw)) {
        return(NULL)
      }
      dplyr::tibble(
        km = row$km,
        km_label = row$km_label,
        bm = row$bm,
        bm_label = row$bm_label,
        sentence_source = src,
        sentence_number = seq_len(nrow(raw)),
        claim = raw$claim,
        confidence = raw$confidence
      )
    }))
  }))

  # ── 2. Process works_citing partitions in parallel ───────────────────────
  # output_path already computed above (used by the early resumability
  # check); a defensive wipe here only matters for a partial/corrupt
  # leftover (dir exists but had no parquet files, which is exactly what
  # let execution reach this point instead of returning early).
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
          dplyr::coalesce(vapply(title, clean_title, character(1L)), ""),
          dplyr::coalesce(vapply(abstract, clean_abstract, character(1L)), "")
        ))
      ) |>
      dplyr::select(work_id, premise)

    out <- dplyr::cross_join(
      sents_bm |> dplyr::select(sentence_source, sentence_number, claim, dplyr::any_of("confidence")),
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
      # confidence (atomic_bm only -- the extracted IPBES confidence
      # qualifier, e.g. "well established", NA where none was found) is
      # included via any_of() so naive_bm/complete_bm's output schema is
      # completely unaffected -- their `sents_bm` never has this column.
      dplyr::select(
        km, bm, sentence_number, claim, sentence_source,
        work_id, premise, abstract_tokens, sentence_tokens, approx_tokens,
        assessment, dplyr::any_of("confidence")
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
