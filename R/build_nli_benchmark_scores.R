# Score the benchmark holdout with one NLI model (TD_NLI_training.qmd).
#
# A thin system2() bridge to scripts/benchmark/score_nli_local.py, exactly the
# shape R/build_nli_finetuned_model.R already uses for train_nli.py -- the
# work is Python (transformers), the value to targets is a real
# format = "file" output path.
#
# Local CPU, not the RunPod pool: the pool serves one model per deployment, so
# comparing N models through it means N deployments, real money, and a hardware
# confound if they differ. The holdout is a few hundred rows.

# Every checkpoint under output/nli_training_finetuned/, plus the zero-shot
# baseline. Discovered from DISK, never from config -- runs accumulate and no
# config key tracks them, the same instinct shiny_app/R/discover_artifacts.R
# applies to rendered artifacts.
#
# The `.disabled/<nli_config>/` marker written when training.finetune.enabled
# is false holds no best/ subdirectory, so it is skipped by this pattern
# without needing to be named.
nli_benchmark_models <- function(baseline_model, finetuned_root = "output/nli_training_finetuned") {
  checkpoints <- character(0)
  if (dir.exists(finetuned_root)) {
    checkpoints <- grep(
      "/best$", list.dirs(finetuned_root, recursive = TRUE), value = TRUE
    )
  }
  c(baseline_model, sort(checkpoints))
}

# A short, stable, filesystem-safe id for one model, used as the
# model=<id>/ partition value and as the row label in the result table.
#
# A checkpoint's path already IS its identity -- KP=/citing=/downsample_seed=/
# date= were designed to describe a run -- so it is reused rather than
# inventing a naming scheme, with the separators flattened.
nli_benchmark_model_id <- function(model, finetuned_root = "output/nli_training_finetuned") {
  # Decided by PATH SHAPE, not by dir.exists(). A local checkpoint whose
  # directory has since moved or been deleted is still a local checkpoint, and
  # the existence test silently sent it down the HuggingFace branch, which
  # returns basename(model) -- i.e. "best" for EVERY fine-tuned run. Distinct
  # models then collapsed to one id and their rows merged in every per-model
  # table. Hit for real after the run tree gained a max_length= level: the
  # paths recorded in existing benchmark score files no longer resolved, and
  # five models became one.
  if (!startsWith(model, finetuned_root)) return(basename(model))   # a HuggingFace id
  rel <- sub(paste0("^", finetuned_root, "/?"), "", model)
  rel <- sub("/best$", "", rel)
  gsub("[^A-Za-z0-9._=-]+", "_", rel)
}

build_nli_benchmark_scores <- function(
  model,
  nli_active,
  training_data_path = "output/nli_training",
  output_root = "output/nli_benchmark",
  config_path = "input/config.yaml",
  python_bin = "~/.venvs/specter2-merge/bin/python3",
  script_path = "scripts/benchmark/score_nli_local.py",
  # Bare, never-read: purely so a new fine-tuning run marks this target
  # outdated. See the call site in _targets_training.R.
  nli_finetuned_model_dep = NULL
) {
  python_bin_expanded <- path.expand(python_bin)
  if (!file.exists(python_bin_expanded)) {
    stop(sprintf(
      "python not found at %s -- benchmark scoring needs the same venv as scripts/training/train_nli.py (override via the python_bin argument in _targets_training.R)",
      python_bin_expanded
    ))
  }
  if (!file.exists(script_path)) stop(sprintf("benchmark script not found: %s", script_path))

  model_id <- nli_benchmark_model_id(model)
  out_path <- file.path(output_root, paste0("model=", model_id), "scores.parquet")
  dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)

  # stdout = "" leaves the per-pass progress streaming live: a zero-shot pass
  # over the holdout is three forward passes per row on CPU and silence for
  # that long is worse than noise. Same reasoning as build_nli_finetuned_model().
  status <- system2(
    python_bin_expanded,
    args = c(
      shQuote(script_path),
      "--model", shQuote(model),
      "--out", shQuote(out_path),
      "--data", shQuote(training_data_path),
      "--config", shQuote(config_path),
      "--nli-config", shQuote(nli_active)
    ),
    stdout = "", stderr = ""
  )
  if (status != 0L) {
    stop(sprintf("benchmark scoring failed (exit %d) for model %s", status, model))
  }
  if (!file.exists(out_path)) {
    stop(sprintf("benchmark scoring reported success but wrote nothing to %s", out_path))
  }

  out_path
}
