# Seed set and key factored out so scripts/seed_collection_input_keys.R uses the
# SAME derivation as the builder -- see the note in R/download_works.R.
snowball_input_seeds <- function(works_path) {
  unique(sub(
    "^https://openalex\\.org/", "",
    arrow::open_dataset(works_path) |> dplyr::select(id) |> dplyr::collect() |> dplyr::pull(id)
  ))
}

snowball_input_key <- function(ids) input_key(ids)

build_snowball_parquet <- function(
  assessment,
  works_path,
  output_root = out_collection("snowball"),
  force = collection_force_refresh()
) {
  assessment_id <- assessment$id
  nodes_root <- file.path(output_root, "nodes")
  edges_root <- file.path(output_root, "edges")
  keypaper_root <- file.path(output_root, "keypaper")

  nodes_assessment_dir <- file.path(
    nodes_root,
    paste0("assessment=", assessment_id)
  )
  edges_assessment_dir <- file.path(
    edges_root,
    paste0("assessment=", assessment_id)
  )
  keypaper_assessment_dir <- file.path(
    keypaper_root,
    paste0("assessment=", assessment_id)
  )

  dir.create(nodes_root, showWarnings = FALSE, recursive = TRUE)
  dir.create(edges_root, showWarnings = FALSE, recursive = TRUE)
  dir.create(keypaper_root, showWarnings = FALSE, recursive = TRUE)

  # Clearing this assessment's existing partitions is DEFERRED until the
  # OpenAlex fetch has actually succeeded -- see the three call sites below.
  # It used to happen right here, at the top of the function, which meant a
  # failed or interrupted fetch left the assessment with nothing at all: on
  # 2026-09-15 one api.openalex.org stall (curl aborting after 600 s below
  # 1 byte/sec) destroyed GA1, IAS and BBA in a single run, because all
  # three branches had wiped their output hours before the fetch that was
  # meant to replace it, and the erroring branch took the two still-running
  # ones down with it. Recovery needed a Time Machine snapshot.
  #
  # write_dataset(existing_data_behavior = "delete_matching") below would
  # already replace the matching partitions on its own, but an explicit
  # wipe is still needed to drop STALE sub-partitions -- a relation= or
  # edge_type= value present in the old data and absent from the new --
  # which delete_matching leaves untouched.
  clear_assessment_output <- function() {
    unlink(nodes_assessment_dir, recursive = TRUE, force = TRUE)
    unlink(edges_assessment_dir, recursive = TRUE, force = TRUE)
    unlink(keypaper_assessment_dir, recursive = TRUE, force = TRUE)
  }

  works <- arrow::open_dataset(works_path) |>
    dplyr::select(km, bm, id) |>
    dplyr::collect() |>
    dplyr::mutate(w_id = sub("^https://openalex\\.org/", "", id))

  # One snowball run per assessment over the UNION of every key paper
  # across all its km/bm groups -- a single work can legitimately be a
  # seed for several BMs (see R/download_works.R's many-to-many join), so
  # calling pro_snowball() once per (km, bm) as before re-fetched the same
  # seed's citation graph redundantly, up to ~19-29x for some assessments.
  # Per-(km, bm) attribution is now derived downstream by joining the
  # unified edges/nodes tables against works_parquet's own (km, bm, id)
  # mapping -- see R/build_works_citing_parquet.R and
  # R/build_claim_work_pairs_keypaper.R.
  ids <- unique(works$w_id)

  # CONTENT KEY -- see R/input_key_guard.R for the full rationale.
  #
  # The seed set is the only thing about this call that determines its output:
  # pro_snowball() is a pure function of `ids` plus whatever OpenAlex currently
  # holds about them. So an unchanged seed set means re-running costs days of
  # OpenAlex time to rebuild 16 GB that is already on disk -- and, worse, yields
  # a DIFFERENT corpus from the one every existing score was computed against,
  # because OpenAlex's citation graph keeps growing underneath a fixed seed set.
  #
  # This is deliberately NOT an existence check. If a new TTL or a new Zotero
  # item adds a seed, the key moves and the snowball re-runs, which is exactly
  # the propagation path that has to keep working.
  snowball_key <- snowball_input_key(ids)
  if (input_key_is_current(
    "snowball", assessment_id, snowball_key,
    outputs = c(nodes_assessment_dir, edges_assessment_dir),
    force = force
  )) {
    input_key_skip_message(
      "snowball", assessment_id,
      sprintf("seed set (%d works)", length(ids))
    )
    return(c(nodes_assessment_dir, edges_assessment_dir, keypaper_assessment_dir))
  }

  if (length(ids)) {
    message("Snowball [", assessment_id, "]: ", length(ids), " unique seeds")

    # openalexSnowball (confirmed on the installed 0.1.2) has a real
    # internal bug: when a seed set's snowball search finds ZERO
    # keypapers, its own code tries to read back an internal
    # "keypaper_parquet" temp directory via a glob pattern that matches
    # nothing, and duckdb/arrow raises an IO error instead of it just
    # returning an empty result -- reproduced twice on real assessment
    # data (VA and TCA), not a one-off. Narrowly catches ONLY this exact
    # error signature and treats it as "zero keypapers" (same as the
    # ids-empty case above) -- any OTHER pro_snowball() failure still
    # propagates and fails the pipeline loudly, since this is one
    # specific, understood package bug, not a blanket "ignore snowball
    # errors" escape hatch.
    sb_dir <- tryCatch(
      openalexSnowball::pro_snowball(
        identifier = ids,
        output = tempfile(fileext = ".snowball"),
        verbose = TRUE
      ),
      error = function(e) {
        msg <- conditionMessage(e)
        if (grepl("keypaper_parquet", msg, fixed = TRUE)) {
          warning(sprintf(
            "[snowball %s] openalexSnowball found no keypapers for this seed set (package-internal read error on empty result, treated as zero): %s",
            assessment_id, msg
          ), call. = FALSE)
          NULL
        } else {
          stop(e)
        }
      }
    )

    if (!is.null(sb_dir)) {
      # Stay in Arrow end-to-end: OpenAlex `nodes` carries list/struct
      # columns (authorships, topics, locations, mesh, ...) that don't
      # round-trip through an R data.frame — `collect() |> write_dataset()`
      # fails with "Degenerated data frame". `mutate()` on a Dataset is
      # lazy and works fine.
      nodes_ds <- arrow::open_dataset(file.path(sb_dir, "nodes")) |>
        dplyr::mutate(assessment = assessment_id)

      edges_ds <- arrow::open_dataset(file.path(sb_dir, "edges")) |>
        dplyr::mutate(assessment = assessment_id)

      # openalexSnowball >= 0.1.1 no longer emits a standalone keypaper
      # directory; keypapers are inside `nodes` with relation = "keypaper".
      keypaper_ds <- nodes_ds |> dplyr::filter(relation == "keypaper")

      # The fetch succeeded and its output is readable: only now is it safe
      # to drop the previous run's partitions. Everything above this line
      # is non-destructive, so any failure leaves the old data intact.
      clear_assessment_output()

      arrow::write_dataset(
        nodes_ds,
        nodes_root,
        partitioning = c("assessment", "relation"),
        existing_data_behavior = "delete_matching"
      )
      arrow::write_dataset(
        edges_ds,
        edges_root,
        partitioning = c("assessment", "edge_type"),
        existing_data_behavior = "delete_matching"
      )
      arrow::write_dataset(
        keypaper_ds,
        keypaper_root,
        partitioning = c("assessment"),
        existing_data_behavior = "delete_matching"
      )

      unlink(sb_dir, recursive = TRUE, force = TRUE)

      # Recorded only now, after the write succeeded. A key written earlier
      # would make the next run skip a fetch that never actually landed.
      input_key_write("snowball", assessment_id, snowball_key)
    } else {
      # pro_snowball() hit the known zero-keypaper package bug handled
      # above and produced nothing. No new data means whatever sits on
      # disk from an earlier run is stale, so it goes -- matching what
      # this function has always done for the no-data case.
      clear_assessment_output()
      input_key_clear("snowball", assessment_id)
    }
  } else {
    # No seed works for this assessment at all: nothing to snowball, and
    # any existing output is stale.
    clear_assessment_output()
    input_key_clear("snowball", assessment_id)
  }

  c(nodes_assessment_dir, edges_assessment_dir, keypaper_assessment_dir)
}
