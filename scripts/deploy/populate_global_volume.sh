#!/usr/bin/env bash
#
# Put the fine-tuned NLI model onto a RunPod Global Volume.
# RUN THIS ON THE POD, not on your machine.
#
#   export HF_TOKEN=<read token>          # keyring: API_HF_read_private
#   bash populate_global_volume.sh [MOUNT] [REPO]
#
# Defaults: MOUNT=/models  REPO=rakrug/ipbes-bm-nli-atomic-v1
#
# WHY ON THE POD: the model lives in a private HF repo, and HF -> RunPod runs at
# datacenter speed. Pushing 2.3 GB up from a laptop is the slow way round.
#
# WHAT YOU MUST DO FIRST, IN THE CONSOLE (there is no CLI or S3 path for global
# volumes -- they are beta; `runpodctl pod create --network-volume-id <global id>`
# fails with "network volume not found", verified):
#
#   1. Storage -> your global volume -> "Configure Pod with volume"
#      (or Deploy -> Storage -> "+ Add volume")
#   2. Attach to a GPU pod. Global volumes CANNOT attach to CPU pods.
#      The cheapest GPU is fine -- this is a file copy, ~$0.07 of L4 time.
#   3. SET THE MOUNT PATH EXPLICITLY to /models. Do not leave the default.
#
#      The default is /workspace, but if a network volume is ever also attached
#      the global volume SILENTLY RELOCATES to /workspace-global -- and every
#      NLI_MODEL pointing at /workspace breaks at pod boot. Pinning the path
#      makes it deterministic. (With a custom path set, an attached network
#      volume gets /workspace-2 instead.)
#
# Re-running is safe: hf download skips files already present.
set -euo pipefail

MOUNT="${1:-/models}"
REPO="${2:-rakrug/ipbes-bm-nli-atomic-v1}"
DEST="$MOUNT/$(basename "$REPO")"

[ -n "${HF_TOKEN:-}" ] || { echo "FATAL: HF_TOKEN not set (keyring: API_HF_read_private)"; exit 1; }
[ -d "$MOUNT" ] || { echo "FATAL: $MOUNT does not exist -- is the global volume attached at that path?"; df -h; exit 1; }
touch "$MOUNT/.write_test" 2>/dev/null && rm -f "$MOUNT/.write_test" || { echo "FATAL: $MOUNT is not writable"; exit 1; }

echo "==> mount $MOUNT ok; downloading $REPO -> $DEST"
command -v hf >/dev/null 2>&1 || pip install -q -U "huggingface_hub[cli]"
hf download "$REPO" --local-dir "$DEST"

echo "==> verifying"
python3 - "$DEST" <<'PY'
import json, os, sys
d = sys.argv[1]
need = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
missing = [f for f in need if not os.path.exists(os.path.join(d, f))]
if missing:
    sys.exit(f"FATAL: missing {missing}")

cfg = json.load(open(os.path.join(d, "config.json")))
got = {int(k): v for k, v in cfg.get("id2label", {}).items()}
want = {0: "SUPPORTS", 1: "REFUTES", 2: "NOT_ENOUGH_INFO"}
if got != want:
    # The serving layer matches candidate_labels BY NAME against id2label, so a
    # mismatch here is the difference between correct scores and silently wrong
    # ones -- exactly the class of failure that made passes:1 necessary.
    sys.exit(f"FATAL: id2label is {got}, expected {want}")

size = os.path.getsize(os.path.join(d, "model.safetensors")) / 1e9
print(f"  id2label  : {want}  OK")
print(f"  weights   : {size:.2f} GB")
print(f"  files     : {len(os.listdir(d))}")
PY

cat <<EOF

==> done. On each scoring pod, attach the same volume at $MOUNT and set:

    NLI_MODEL=$DEST
    NLI_MAX_LENGTH=512

Then in input/config.yaml, add an nli config that uses it:

    passes: 1
    candidate_labels: ["SUPPORTS", "REFUTES", "NOT_ENOUGH_INFO"]

passes:1 needs the nli-runpod-bge-m3 image at v0.4.0 or later. Earlier images
drop the field silently and score every pair against the default template --
wrong answers, no error. Check the image tag before you trust any output.

Global volumes are eventually consistent: give it a moment, and verify on the
first scoring pod rather than assuming the other pods see it.
EOF
