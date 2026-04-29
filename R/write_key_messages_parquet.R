write_key_messages_parquet <- function(key_messages, output_path, reset = TRUE) {
  if (reset && file.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

  arrow::write_dataset(
    dataset = key_messages,
    path = output_path,
    format = "parquet",
    partitioning = c("assessment"),
    existing_data_behavior = "delete_matching"
  )
  output_path
}

build_key_messages_parquet <- function(config, assessment, ttl_path, output_root = "output/key_messages") {
  output_path <- branch_output_dir(output_root, assessment$id)

  with_fuseki_session(
    ttl_path,
    config,
    assessment$id,
    port_base = 5030L,
    code = function(fuseki_state) {
      if (file.exists(output_path)) {
        unlink(output_path, recursive = TRUE, force = TRUE)
      }
      dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

      endpoint <- resolve_lod_endpoint(config, fuseki_state, assessment$id)
      key_messages <- extract_key_messages_from_endpoint(endpoint, assessment$id)
      write_key_messages_parquet(key_messages, output_path, reset = FALSE)
    }
  )

  output_path
}
