#!/usr/bin/env bash
# Launch the NLI pod pool for whichever fact_checking config is active, and
# write the hostnames back into input/config.yaml.
#
# Everything comes from input/config.yaml: the image, the pod settings, how
# many. The generated .conf under output/config/ is disposable -- regenerated
# on every run, never edited by hand -- so config.yaml stays the one place a
# pool is described. The hand-written input/nli_pods_*.conf files are kept for
# reference and read by nothing.
#
# Usage (from the repo root):
#   export RUNPOD_API_KEY=...
#   scripts/runpod/start_nli_pods.sh            # pods.count from config
#   scripts/runpod/start_nli_pods.sh -n 2       # override the count
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

CREATE="${NLI_CREATE_PODS:-external/runpod/scripts/runpod/create_pods.sh}"
[[ -x "${CREATE}" ]] || { echo "error: ${CREATE} not found -- is the external/runpod submodule checked out?" >&2; exit 1; }
[[ -n "${RUNPOD_API_KEY:-}" ]] || { echo "error: RUNPOD_API_KEY is not set. export RUNPOD_API_KEY=... first." >&2; exit 1; }

N_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) N_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# ACTIVE / COUNT / CONF / CSV, resolved from config.yaml. This also fails loudly
# on a config with no image: or no pods: block, before anything is charged for.
eval "$(scripts/runpod/nli_pods.R conf)"
COUNT="${N_OVERRIDE:-${COUNT}}"

echo "[start_nli_pods] ${ACTIVE}: starting ${COUNT} pod(s)"
echo "[start_nli_pods] conf: ${CONF}"

"${CREATE}" -n "${COUNT}" -c "${CONF}" -o "${CSV}"

# create_pods.sh writes one row per pod that actually came up, so a short pool
# is visible here rather than silently accepted. The ones that did start are
# still written back -- a partial pool scores more slowly, it does not score
# wrongly, and score_one_claim() dispatches per free host.
READY=$(($(wc -l < "${CSV}") - 1))
if [[ "${READY}" -lt "${COUNT}" ]]; then
  echo "WARNING: requested ${COUNT} pod(s), ${READY} reported ready. Writing back the ${READY} that started." >&2
fi

scripts/runpod/nli_pods.R hosts "${CSV}"
echo "[start_nli_pods] done. Teardown: scripts/runpod/stop_nli_pods.sh"
