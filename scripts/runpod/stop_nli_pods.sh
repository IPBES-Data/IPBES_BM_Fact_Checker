#!/usr/bin/env bash
# Stop the NLI pods started for the active fact_checking config.
#
# Leaves input/config.yaml's host: list ALONE, deliberately: a stopped pod can
# be resumed under the same hostname, so the list stays meaningful and a
# restart needs no second write-back. Pass -d to delete permanently instead.
#
# Usage (from the repo root):
#   export RUNPOD_API_KEY=...
#   scripts/runpod/stop_nli_pods.sh         # stop
#   scripts/runpod/stop_nli_pods.sh -d      # stop and delete
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

STOP="${NLI_STOP_PODS:-external/runpod/scripts/runpod/stop_pods.sh}"
[[ -x "${STOP}" ]] || { echo "error: ${STOP} not found -- is the external/runpod submodule checked out?" >&2; exit 1; }

eval "$(scripts/runpod/nli_pods.R conf)"
[[ -f "${CSV}" ]] || { echo "error: no ${CSV} -- nothing recorded for ${ACTIVE}. Pass -i <pod-id> to ${STOP} directly." >&2; exit 1; }

echo "[stop_nli_pods] ${ACTIVE}: $(($(wc -l < "${CSV}") - 1)) pod(s) from ${CSV}"

# The FULL inventory, not the filtered _ready.csv the start wrapper writes back
# from: a pod that never became healthy is still running and still billing, and
# this is the only record of its id.
rc=0
"${STOP}" -f "${CSV}" "$@" || rc=$?

# stop_pods.sh removes the inventory once every pod in it was actioned, so the
# healthy-subset copy beside it has to go too -- otherwise it survives as the
# only file left, looking like a current pool.
[[ -f "${CSV}" ]] || rm -f "${CSV%.csv}_ready.csv"

echo "[stop_nli_pods] done. input/config.yaml host: left untouched."
exit "${rc}"
