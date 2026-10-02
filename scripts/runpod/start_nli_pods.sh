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
#   scripts/runpod/start_nli_pods.sh                     # fact_checking's pool
#   scripts/runpod/start_nli_pods.sh -p training        # training's pool
#   scripts/runpod/start_nli_pods.sh -n 2               # override the count
#
# -p matters: the two purposes deliberately run DIFFERENT models -- fact
# checking on the fine-tune, training left on zero-shot so the training set is
# not distilled from labels the model itself shaped. Starting one pool and
# pointing the other chain at it scores with the wrong model under the right
# config name.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

CREATE="${NLI_CREATE_PODS:-external/runpod/scripts/runpod/create_pods.sh}"
[[ -x "${CREATE}" ]] || { echo "error: ${CREATE} not found -- is the external/runpod submodule checked out?" >&2; exit 1; }
[[ -n "${RUNPOD_API_KEY:-}" ]] || { echo "error: RUNPOD_API_KEY is not set. export RUNPOD_API_KEY=... first." >&2; exit 1; }

N_OVERRIDE=""
PURPOSE="fact_checking"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) N_OVERRIDE="$2"; shift 2 ;;
    -p|--purpose) PURPOSE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# ACTIVE / COUNT / CONF / CSV, resolved from config.yaml. This also fails loudly
# on a config with no image: or no pods: block, before anything is charged for.
# ACTIVE / COUNT / CONF / CSV / HEALTH_PATH, resolved from config.yaml. This
# also fails loudly on a config with no image: or no pods: block, before
# anything is charged for. The count override is passed through so MIN_READY is
# clamped to it: create_pods.sh sources the conf BEFORE applying its own
# MIN_READY default, so a conf value wins over anything -n could say, and asking
# for 1 pod against min_ready: 4 would fail every single time.
eval "$(scripts/runpod/nli_pods.R conf "${PURPOSE}" ${N_OVERRIDE})"

echo "[start_nli_pods] ${PURPOSE} -> ${ACTIVE}: starting ${COUNT} pod(s)"
echo "[start_nli_pods] conf: ${CONF}"

# NOT under set -e. create_pods.sh exits 2 for PARTIAL (at least MIN_READY up,
# fewer than requested) and 1 for below-MIN_READY, and in BOTH cases the pods
# that did come up are real, billing, and worth recording. Letting set -e abort
# here left them running with nothing written back anywhere -- the whole point
# of the wrapper lost in exactly the case it exists for.
rc=0
"${CREATE}" -n "${COUNT}" -c "${CONF}" -o "${CSV}" || rc=$?
case "${rc}" in
  0) ;;
  2) echo "WARNING: partial pool -- fewer pods ready than requested (create_pods.sh exit 2)." >&2 ;;
  1) echo "WARNING: create_pods.sh reported failure (exit 1): no pod ready, or fewer than MIN_READY." >&2 ;;
  *) echo "error: create_pods.sh exited ${rc}." >&2; exit "${rc}" ;;
esac

if [[ ! -f "${CSV}" ]]; then
  echo "error: no inventory at ${CSV} -- no pod was created, so there is nothing to write back." >&2
  exit 1
fi

# The inventory lists every pod CREATED, not every pod READY -- a pod that
# never came up is in there precisely because it is billing and has to be
# findable for teardown. Writing that column straight into config.yaml would
# hand the pipeline a host check_nli_pool_health() then stops on, so the hosts
# are filtered by asking them. The full inventory is what stop_nli_pods.sh
# uses; only this filtered copy feeds the write-back.
READY_CSV="${CSV%.csv}_ready.csv"
head -1 "${CSV}" > "${READY_CSV}"
n_created=0
while IFS=, read -r id name host port; do
  n_created=$((n_created + 1))
  if curl -fsS -m 10 "https://${host}${HEALTH_PATH}" >/dev/null 2>&1; then
    echo "${id},${name},${host},${port}" >> "${READY_CSV}"
  else
    echo "  not healthy, left out of host:  ${host}  (id=${id}, still billing)" >&2
  fi
done < <(tail -n +2 "${CSV}")

n_ready=$(($(wc -l < "${READY_CSV}") - 1))
echo "[start_nli_pods] ${n_ready}/${n_created} created pod(s) answering ${HEALTH_PATH}"

if [[ "${n_ready}" -eq 0 ]]; then
  echo "error: no pod is answering. input/config.yaml left untouched -- the previous host list is still there." >&2
  echo "       ${n_created} pod(s) ARE RUNNING AND BILLING. Tear down with: scripts/runpod/stop_nli_pods.sh" >&2
  exit 1
fi
if [[ "${n_ready}" -lt "${COUNT}" ]]; then
  # A partial pool scores more slowly, not wrongly: score_one_claim() dispatches
  # per free host, so the pool size is a throughput knob, not a correctness one.
  echo "WARNING: requested ${COUNT} pod(s), ${n_ready} healthy. Writing back the ${n_ready} that came up." >&2
fi

scripts/runpod/nli_pods.R hosts "${PURPOSE}" "${READY_CSV}"
echo "[start_nli_pods] done. Teardown: scripts/runpod/stop_nli_pods.sh"
