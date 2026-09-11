# Citing works, split into a slim per-(km, bm) MAPPING and a deduplicated
# per-assessment METADATA table.
#
# Why two datasets rather than one. A citing work belongs to every (km, bm)
# whose seed papers it cites -- ~21 groups on average, measured. The previous
# shape stored a full OpenAlex record once per group, which was affordable
# only while each group had its own small snowball. Since snowball_parquet
# was unified per assessment it is not: GA1 alone yields 3.7M rows from
# 802,448 distinct works, TCA 12M rows, and full records at that fan-out come
# to >100 GB across the four assessments (measured, not estimated). Dropping
# the 28 struct/list columns only buys ~5x, because `abstract` dominates and
# the duplication is the real cost.
#
# So metadata is stored ONCE per assessment and the per-group dataset carries
# nothing but `id`. Consumers that need per-group works join the two; several
# consumers (nli_overview_data, nli_scores_qa_data, llm_verification_qa_data,
# nli_training_data) only ever wanted id -> doi/title/abstract and get
# simpler, since the metadata table is already distinct.
#
# The mapping keeps the original output/works_citing/assessment/km/bm path
# and partitioning on purpose: consumers that walk those directories
# (build_nli_ready_parquet.R, build_nli_ready_evidence_parquet.R) and
# build_label_funnel_data.R's select(km, bm, work_id = id) keep working
# against the same layout.
#
# DuckDB does the heavy lifting rather than arrow: arrow refuses to carry
# struct columns through a join at all ("Data type struct<...> is not
# supported in join non-key field"), and its `%in%` breaks down on the
# 100k+ id sets these groups reach. Both were hit for real before switching.
#
# Snowball nodes are NOT deduplicated by openalexSnowball (.assemble_nodes()
# is a plain COPY with no DISTINCT), so the same work appears once per seed
# chunk that returned it -- 1.36x for GA1, up to 1.61x for IAS, differing
# only in the `query` column. That provenance is unused downstream, so both
# outputs here are deduplicated.

works_citing_meta_root <- function(output_root) {
  paste0(sub("/+$", "", output_root), "_meta")
}

# build_works_citing_parquet() returns c(<mapping dir>, <metadata dir>) per
# branch, the same "one target, several paths, split by name" convention
# snowball_parquet already uses for its nodes/edges/keypaper triple. When a
# consumer takes the target WITHOUT a pattern (fig_pub_per_year, the two
# overlap tables), targets hands it every branch's paths concatenated, so
# these split an arbitrary-length vector rather than assuming two elements.
works_citing_map_paths <- function(x) x[!grepl("_meta(/|$)", x)]
works_citing_meta_paths <- function(x) x[grepl("_meta(/|$)", x)]

# One LAZY arrow query per assessment, mapping joined to the metadata columns
# asked for. Lazy on purpose: the mapping is millions of rows and `abstract`
# is large, so consumers must be able to filter (publication_year, km/bm, ...)
# before anything is collected. The join is legal here precisely because the
# metadata table carries no struct/list columns -- arrow refuses those in a
# join, which is what forced duckdb on the write side.
works_citing_queries <- function(works_citing_path, columns = NULL) {
  maps  <- works_citing_map_paths(works_citing_path)
  metas <- works_citing_meta_paths(works_citing_path)
  asmts <- sub("^assessment=", "", basename(maps))

  stats::setNames(lapply(seq_along(maps), function(i) {
    meta_p <- metas[basename(metas) == paste0("assessment=", asmts[i])]
    if (!length(meta_p)) {
      stop(sprintf(
        "no works_citing metadata found for assessment=%s (looked in: %s)",
        asmts[i], paste(metas, collapse = ", ")
      ))
    }
    md <- arrow::open_dataset(meta_p[[1L]])
    if (!is.null(columns)) {
      md <- dplyr::select(md, dplyr::all_of(unique(c("id", columns))))
    }
    dplyr::inner_join(arrow::open_dataset(maps[i]), md, by = "id")
  }), asmts)
}

# The (km, bm) groups present in an assessment's mapping. Replaces the
# list.dirs() walk the builders used when km/bm were partition directories.
works_citing_groups <- function(map_path) {
  arrow::open_dataset(map_path) |>
    dplyr::distinct(km, bm) |>
    dplyr::collect() |>
    dplyr::arrange(km, bm)
}

# One (km, bm) group's citing works, with the metadata columns requested.
# Stays lazy until the last step so memory is bounded by one group rather
# than one assessment -- these builders run under mclapply, so several
# groups are in flight at once. The mapping is written sorted by km/bm, so
# this filter prunes row groups rather than scanning the whole file.
works_citing_group <- function(map_path, km_val, bm_val, meta_path, columns) {
  ids <- arrow::open_dataset(map_path) |>
    dplyr::filter(km == km_val, bm == bm_val) |>
    dplyr::select(id) |>
    dplyr::distinct() |>
    dplyr::collect()
  if (!nrow(ids)) {
    return(NULL)
  }
  arrow::open_dataset(meta_path) |>
    dplyr::select(dplyr::all_of(unique(c("id", columns)))) |>
    dplyr::inner_join(arrow::as_arrow_table(ids), by = "id") |>
    dplyr::collect()
}

build_works_citing_parquet <- function(assessment, works_path, snowball_path,
                                       output_root = "output/works_citing") {
  assessment_id <- assessment$id
  meta_root     <- works_citing_meta_root(output_root)
  output_path   <- file.path(output_root, paste0("assessment=", assessment_id))
  meta_path     <- file.path(meta_root, paste0("assessment=", assessment_id))

  unlink(output_path, recursive = TRUE, force = TRUE)
  unlink(meta_path, recursive = TRUE, force = TRUE)
  dir.create(output_root, showWarnings = FALSE, recursive = TRUE)
  dir.create(meta_root, showWarnings = FALSE, recursive = TRUE)

  nodes_path <- snowball_path[grepl("nodes", snowball_path)]
  edges_path <- snowball_path[grepl("edges", snowball_path)]

  if (!dir.exists(edges_path) || !dir.exists(nodes_path)) {
    dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
    dir.create(meta_path, recursive = TRUE, showWarnings = FALSE)
    return(c(output_path, meta_path))
  }

  # Keep every scalar column: stored once, the cost is trivial, and it means
  # no consumer can break on a column this function failed to anticipate.
  # abstract_inverted_index is the one deliberate drop -- it is simply
  # `abstract` in another encoding, and it is large.
  schema <- arrow::open_dataset(nodes_path)$schema
  scalar_cols <- Filter(
    function(n) !grepl("^(struct|list)", schema[[n]]$type$ToString()),
    names(schema)
  )
  scalar_cols <- setdiff(scalar_cols, c("abstract_inverted_index", "relation", "query"))
  meta_select <- paste(sprintf('n."%s"', scalar_cols), collapse = ", ")

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "SET memory_limit='6GB'; SET preserve_insertion_order=false;")

  nodes_glob <- file.path(nodes_path, "**", "*.parquet")
  edges_glob <- file.path(edges_path, "**", "*.parquet")
  works_glob <- file.path(works_path, "**", "*.parquet")

  DBI::dbExecute(con, sprintf(
    "CREATE VIEW seeds AS SELECT DISTINCT km, bm, id
       FROM read_parquet('%s', hive_partitioning = true)", works_glob
  ))
  DBI::dbExecute(con, sprintf(
    "CREATE VIEW citing AS SELECT * FROM read_parquet('%s', hive_partitioning = true)
       WHERE relation = 'citing'", nodes_glob
  ))

  # MAPPING: which citing work belongs to which (km, bm). A work qualifies
  # for a group when it references one of that group's seed papers.
  #
  # ONE file per assessment with km/bm as ordinary COLUMNS, rather than a
  # km=/bm= partition tree: 206 tiny files across the four assessments
  # becomes 4, which is what matters for putting this under Git LFS, and
  # km/bm are cheap columns (dictionary-encoded, a handful of distinct
  # values). ORDER BY km, bm so parquet row-group statistics still let a
  # per-group filter skip most of the file -- the pruning the partition tree
  # used to give for free.
  dir.create(output_path, recursive = TRUE, showWarnings = FALSE)
  DBI::dbExecute(con, sprintf(
    "COPY (
       SELECT DISTINCT s.km, s.bm, e.\"from\" AS id
       FROM read_parquet('%s', hive_partitioning = true) e
       JOIN seeds s ON e.\"to\" = s.id
       WHERE e.\"from\" IN (SELECT DISTINCT id FROM citing)
       ORDER BY s.km, s.bm
     ) TO '%s' (FORMAT PARQUET, OVERWRITE_OR_IGNORE)",
    edges_glob, file.path(output_path, "part-0.parquet")
  ))

  # METADATA: one row per distinct citing work. COPY TO a single file needs
  # its parent directory to exist (unlike the PARTITION_BY form above, which
  # creates its own).
  dir.create(meta_path, recursive = TRUE, showWarnings = FALSE)
  DBI::dbExecute(con, sprintf(
    "COPY (
       SELECT %s FROM citing n
       QUALIFY row_number() OVER (PARTITION BY n.id) = 1
     ) TO '%s' (FORMAT PARQUET, OVERWRITE_OR_IGNORE)",
    meta_select, file.path(meta_path, "part-0.parquet")
  ))

  c(output_path, meta_path)
}
