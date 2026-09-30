"""Score the benchmark holdout with ONE NLI model, locally on CPU.

Part of the benchmark described in input/reports/TD_NLI_training.qmd. Called once
per model by R/build_nli_benchmark_scores.R; writes one parquet of per-row
probabilities.

    python scripts/benchmark/score_nli_local.py \
        --model MoritzLaurer/bge-m3-zeroshot-v2.0-c \
        --out output/nli_benchmark/model=baseline/scores.parquet

WHY LOCAL AND NOT THE RUNPOD POOL: the pool serves one model per deployment,
so comparing N models through it means N deployments -- real money, real setup,
and a hardware confound if they differ. The holdout is a few hundred rows.

WHY TWO SCORING MODES: this reproduces external/runpod/docker/nli-runpod-bge-m3/
server.py rather than inventing a scheme, because a baseline scored differently
from how it is actually deployed is not a baseline.

  * passes=3 (zero-shot) -- what the UNTUNED bge-m3 model is deployed with.
    The model head is binary (entailment / not_entailment), so it cannot emit
    SUPPORTS/REFUTES/NEI directly. Instead each candidate label is folded into
    its own reformulated hypothesis via hypothesis_template, one forward pass
    each, and the three entailment logits are cross-normalised with a softmax.
  * passes=1 (direct) -- what a FINE-TUNED checkpoint gets. Its head is already
    3-way over the real label names, so one forward pass on (premise, raw claim)
    and its native softmax is read straight off, reordered by NAME via
    config.id2label rather than by index position.

The mode is derived from the model itself (does its id2label carry all three
candidate labels?), not from a flag -- same rule server.py's _direct_label_order
applies, so a model can never be scored in the wrong mode by misconfiguration.

max_length differs per mode deliberately and is recorded in the output: the
zero-shot model is deployed at the config's max_length (2048), while a
fine-tuned checkpoint saw 512 during training and running it longer at
inference would be out of distribution. Truncation rates are reported so the
difference is visible rather than assumed harmless.
"""

import argparse
import os
import sys

import pandas as pd
import torch
import yaml
from transformers import AutoModelForSequenceClassification, AutoTokenizer

# Mirrors train_nli.py's own mapping; the output column order is fixed to
# SUPPORTS/REFUTES/NOT_ENOUGH_INFO regardless of any model's internal order.
LABELS = ["SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO"]
TRAIN_MAX_LENGTH = 512  # what train_nli.py tokenises at


def norm_label(label: str) -> str:
    return str(label).strip().upper().replace(" ", "_").replace("-", "_")


def build_premise(row):
    """Identical to train_nli.py's build_premise (PREMISE_MODE == 'full')."""
    title = row["title"] if isinstance(row.get("title"), str) else ""
    abstract = row["abstract"] if isinstance(row.get("abstract"), str) else ""
    return f"{title}. {abstract}" if abstract else title


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model", required=True, help="HF id or a local checkpoint directory")
    p.add_argument("--out", required=True, help="parquet file to write")
    p.add_argument("--data", default="output/nli_training")
    p.add_argument("--config", default="input/config.yaml")
    p.add_argument("--nli-config", default=None, help="restrict to one nli_config partition")
    p.add_argument("--split", default="test")
    p.add_argument("--batch-size", type=int, default=8)
    p.add_argument("--limit", type=int, default=None, help="score only the first N rows (smoke test)")
    return p.parse_args()


def main():
    args = parse_args()

    cfg = yaml.safe_load(open(args.config))
    nli_name = args.nli_config or cfg["training"]["nli"]
    nli_cfg = cfg["nli"]["configs"][nli_name]
    candidate_labels = nli_cfg.get("candidate_labels", ["supports", "refutes", "is not relevant to"])
    template = nli_cfg.get("hypothesis_template", "This paper {} the following claim: %s")
    zeroshot_max_length = int(nli_cfg.get("max_length", 2048))

    df = pd.read_parquet(args.data)
    if "split" not in df.columns:
        sys.exit(f"[benchmark] FATAL: no 'split' column in {args.data} -- rebuild nli_training_data first.")
    df = df[df["nli_config"] == nli_name]
    df = df[df["split"] == args.split].reset_index(drop=True)
    if args.limit:
        df = df.head(args.limit).reset_index(drop=True)
    if not len(df):
        sys.exit(f"[benchmark] FATAL: no rows with split=={args.split!r} and nli_config=={nli_name!r}")

    print(f"[benchmark] model = {args.model}")
    print(f"[benchmark] {len(df)} rows, split={args.split!r}, nli_config={nli_name!r}")

    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model)
    model.eval()

    id2label = getattr(model.config, "id2label", None) or {}
    native = {norm_label(v): int(k) for k, v in id2label.items()}

    # Mode detection, exactly server.py's rule: a head that already carries all
    # three real label names is read directly; anything else is a zero-shot
    # entailment model and needs the per-label reformulation.
    direct_order = [native.get(norm_label(lbl)) for lbl in LABELS]
    if all(i is not None for i in direct_order):
        mode, max_length = "direct", TRAIN_MAX_LENGTH
    else:
        mode, max_length = "zeroshot", zeroshot_max_length
        ent_id = next((i for lbl, i in native.items() if lbl.startswith("ENTAIL")), None)
        if ent_id is None:
            sys.exit(f"[benchmark] FATAL: {args.model} has neither the 3 real labels nor an 'entailment' class: {id2label!r}")

    print(f"[benchmark] mode = {mode}, max_length = {max_length}, id2label = {id2label}")

    premises = [build_premise(r) for _, r in df.iterrows()]
    claims = df["hypothesis"].astype(str).tolist()

    def run(pairs):
        """Forward a list of (premise, hypothesis) pairs; return raw logits."""
        out = []
        n_truncated = 0
        for i in range(0, len(pairs), args.batch_size):
            chunk = pairs[i : i + args.batch_size]
            enc = tokenizer(
                [a for a, _ in chunk], [b for _, b in chunk],
                truncation=True, max_length=max_length, padding=True, return_tensors="pt",
            )
            n_truncated += int((enc["attention_mask"].sum(dim=1) >= max_length).sum())
            with torch.no_grad():
                out.append(model(**enc).logits)
            if i and i % (args.batch_size * 20) == 0:
                print(f"[benchmark]   {i}/{len(pairs)}", flush=True)
        return torch.cat(out), n_truncated

    if mode == "direct":
        logits, n_trunc = run(list(zip(premises, claims)))
        probs = torch.softmax(logits, dim=1)[:, direct_order]
    else:
        # One pass per candidate label. The claim's literal braces ("{5.4.1}")
        # must be doubled before .format(), exactly as R/score_one_claim.R does
        # -- otherwise Python reads them as format fields and the call raises.
        # Escape braces in the CLAIM only, then substitute it for the template's
        # %s, leaving the template's own {} as the label slot for .format().
        # Same two steps as R/score_one_claim.R's
        #   claim_safe <- gsub("\\{", "{{", gsub("\\}", "}}", claim))
        #   hyp_tmpl   <- sprintf(template_fmt, claim_safe)
        claim_templates = [
            template.replace("%s", c.replace("{", "{{").replace("}", "}}")) for c in claims
        ]
        ent_logits, n_trunc = [], 0
        for lbl in candidate_labels:
            hyps = [ct.format(lbl) for ct in claim_templates]
            lg, trunc = run(list(zip(premises, hyps)))
            ent_logits.append(lg[:, ent_id])
            n_trunc = max(n_trunc, trunc)
            print(f"[benchmark]   pass done: {lbl!r}", flush=True)
        probs = torch.softmax(torch.stack(ent_logits, dim=1), dim=1)

    probs = probs.numpy()
    out = df[[c for c in ["id", "assessment", "km", "bm", "work_id", "hypothesis", "label",
                          "nli_label", "nli_confidence", "keypaper", "split"] if c in df.columns]].copy()
    out["p_supports"] = probs[:, 0]
    out["p_refutes"] = probs[:, 1]
    out["p_nei"] = probs[:, 2]
    out["pred_label"] = [LABELS[i] for i in probs.argmax(axis=1)]
    out["confidence"] = probs.max(axis=1)
    out["model"] = args.model
    out["mode"] = mode
    out["max_length"] = max_length
    out["n_truncated"] = n_trunc

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    out.to_parquet(args.out, index=False)
    print(f"[benchmark] wrote {len(out)} rows to {args.out} ({n_trunc} premises hit max_length)")
    print(out["pred_label"].value_counts())


if __name__ == "__main__":
    main()
