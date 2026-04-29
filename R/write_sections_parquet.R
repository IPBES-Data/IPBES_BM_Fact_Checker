write_sections_parquet <- function(sections, output_path, reset = TRUE) {
  if (reset && file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

  arrow::write_dataset(
    dataset = sections,
    path = output_path,
    format = "parquet",
    partitioning = c("assessment", "km", "bm", "section", "subsection"),
    existing_data_behavior = "delete_matching"
  )
  output_path
}

build_sections_parquet <- function(config, assessment, ttl_path, output_root = "output/sections") {
  output_path <- branch_output_dir(output_root, assessment$id)

  with_fuseki_session(
    ttl_path,
    config,
    assessment$id,
    port_base = 4030L,
    code = function(fuseki_state) {
      if (file.exists(output_path)) {
        unlink(output_path, recursive = TRUE, force = TRUE)
      }
      dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

      endpoint <- resolve_lod_endpoint(config, fuseki_state, assessment$id)
      sections <- extract_sections_from_endpoint(endpoint, assessment$id)
      write_sections_parquet(sections, output_path, reset = FALSE)
    }
  )

  output_path
}
