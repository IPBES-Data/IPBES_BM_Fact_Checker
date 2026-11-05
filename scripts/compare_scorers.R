#!/usr/bin/env Rscript
# Compare every scorer that has scored the same claims, on identical rows.
#
# The whole point of giving each backend its own scorer_config= tree is that
# this comparison is possible: same claims, same works, same premises, three
# models. Nothing here re-scores anything -- it is a pure read of what is on
# disk, so it is free to re-run as more models or KMs arrive.
suppressPackageStartupMessages({library(arrow); library(dplyr)})
source("R/build_goldstandard.R")          # cohens_kappa()

GRAN <- "atomic_bm"; A <- "GA1"
root <- function(kp = FALSE) file.path(
  if (kp) "output/claim_scores_keypaper" else out_factcheck("claim_scores"), paste0("granularity=", GRAN))

scorers <- function(kp = FALSE) {
  d <- list.dirs(root(kp), recursive = FALSE)
  d <- d[grepl("scorer_config=", d)]
  setNames(d, sub(".*scorer_config=", "", d))
}

read_scorer <- function(path, kp = FALSE) {
  p <- file.path(path, paste0("assessment=", A))
  if (!dir.exists(p) || !length(list.files(p, "parquet$", recursive = TRUE))) return(NULL)
  open_dataset(p) |>
    select(km, bm, claim_id, work_id, label, p_supports, p_refutes, p_nei, confidence, uncertain) |>
    collect()
}

collect_all <- function(kp = FALSE) {
  s <- scorers(kp)
  out <- lapply(names(s), function(n) { d <- read_scorer(s[[n]], kp); if (is.null(d)) NULL else mutate(d, scorer = n) })
  bind_rows(out[!vapply(out, is.null, TRUE)])
}

cite <- collect_all(FALSE)
kp   <- collect_all(TRUE)

# Restrict to the claims EVERY scorer has, so comparisons are like-for-like.
common <- function(d) {
  k <- d |> distinct(scorer, km, bm, claim_id, work_id)
  n <- n_distinct(d$scorer)
  keep <- k |> count(km, bm, claim_id, work_id) |> filter(n == !!n) |> select(-n)
  inner_join(d, keep, by = c("km","bm","claim_id","work_id"))
}
cite_c <- common(cite); kp_c <- common(kp)

res <- list(
  generated = Sys.time(),
  cite_scorers = sort(unique(cite$scorer)), kp_scorers = sort(unique(kp$scorer)),
  cite_n_all = nrow(cite), cite_n_common = nrow(cite_c) / max(1L, n_distinct(cite_c$scorer)),
  kp_n_common = nrow(kp_c) / max(1L, n_distinct(kp_c$scorer)),
  cite_labels = cite |> count(scorer, label) |> group_by(scorer) |> mutate(pct = 100*n/sum(n)) |> ungroup(),
  kp_labels   = kp   |> count(scorer, label) |> group_by(scorer) |> mutate(pct = 100*n/sum(n)) |> ungroup(),
  conf = cite |> group_by(scorer) |> summarise(
    median_conf = median(confidence, na.rm = TRUE),
    pct_uncertain = 100*mean(uncertain, na.rm = TRUE),
    median_p_nei = median(p_nei, na.rm = TRUE),
    pct_p_nei_saturated = 100*mean(p_nei >= 0.999, na.rm = TRUE), .groups = "drop"),
  # routed set = what Phase 2 would cost
  routed = cite |> group_by(scorer) |> summarise(
    scored = n(),
    routed = sum(label %in% c("REFUTES","SUPPORTS") & !uncertain), .groups = "drop") |>
    mutate(pct = 100*routed/scored, phase2_usd = routed * 0.000149)
)

# Pairwise agreement, each pair on ITS OWN common rows.
#
# Not one three-way common set: bge_m3_zeroshot_atomic_bm only ever scored 31 of
# KM C.'s 38 claims (69,765 rows against 2,307,101) -- its delta backlog was
# never run -- so intersecting all three would throw away 97% of the rows where
# the fine-tune and Jev CAN be compared. Each pair is therefore scored on what
# that pair actually shares, and n is reported with every figure.
pairs_of <- function(d) {
  ms <- sort(unique(d$scorer)); out <- list()
  for (i in seq_along(ms)) for (j in seq_along(ms)) if (i < j) {
    a <- d |> filter(scorer == ms[i]) |> select(km, bm, claim_id, work_id, la = label) |>
      distinct(km, bm, claim_id, work_id, .keep_all = TRUE)
    b <- d |> filter(scorer == ms[j]) |> select(km, bm, claim_id, work_id, lb = label) |>
      distinct(km, bm, claim_id, work_id, .keep_all = TRUE)
    j2 <- inner_join(a, b, by = c("km","bm","claim_id","work_id"))
    if (!nrow(j2)) next
    out[[length(out)+1]] <- tibble(a = ms[i], b = ms[j], n = nrow(j2),
      agree = 100*mean(j2$la == j2$lb), kappa = cohens_kappa(j2$la, j2$lb))
  }
  bind_rows(out)
}
res$pairwise <- pairs_of(cite)
res$pairwise_kp <- pairs_of(kp)

# the headline cross-tab: the two models that scored the SAME full corpus
ft <- cite |> filter(scorer == "bge_m3_ft_ga1") |> select(km,bm,claim_id,work_id, ft = label) |>
  distinct(km,bm,claim_id,work_id, .keep_all = TRUE)
jv <- cite |> filter(scorer == "jev_atomic_bm") |> select(km,bm,claim_id,work_id, jev = label) |>
  distinct(km,bm,claim_id,work_id, .keep_all = TRUE)
fj <- inner_join(ft, jv, by = c("km","bm","claim_id","work_id"))
res$confusion_ft_jev <- table(`fine-tune` = fj$ft, jev = fj$jev)
res$confusion_n <- nrow(fj)

# key papers ARE the evidence a BM was written from -- they should land in
# SUPPORTS. This is the one quality signal available without human labels.
res$kp_vs_cite <- bind_rows(
  kp   |> count(scorer, label) |> group_by(scorer) |> mutate(pct = 100*n/sum(n)) |> ungroup() |> mutate(corpus = "key papers"),
  cite |> count(scorer, label) |> group_by(scorer) |> mutate(pct = 100*n/sum(n)) |> ungroup() |> mutate(corpus = "citing works")
) |> filter(label == "SUPPORTS") |> select(scorer, corpus, pct) |>
  tidyr::pivot_wider(names_from = corpus, values_from = pct) |>
  mutate(separation_pts = `key papers` - `citing works`)

saveRDS(res, out_reporting("tables/scorer_comparison.rds"))
message("wrote output/tables/scorer_comparison.rds")
str(res[c("cite_n_common","kp_n_common")])
print(as.data.frame(res$cite_labels)); print(as.data.frame(res$conf))
print(res$confusion_ft_jev); print(as.data.frame(res$pairwise_kp))
print(as.data.frame(res$routed)); print(as.data.frame(res$pairwise)); print(as.data.frame(res$kp_vs_cite))
