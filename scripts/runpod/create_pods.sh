#!/usr/bin/env bash
# Create and start N RunPod pods from a config file (see pods.conf.example),
# for parallel NLI scoring against a pool of hosts (input/config.yaml `host:`
# list). Uses the RunPod REST API directly (https://rest.runpod.io/v1/pods) —
# no runpodctl install required on the calling machine.
#
# Usage:
#   export RUNPOD_API_KEY=...          # required: RunPod account API key
#   cp scripts/runpod/pods.conf.example scripts/runpod/pods.conf
#   $EDITOR scripts/runpod/pods.conf
#   scripts/runpod/create_pods.sh -n 3 -c scripts/runpod/pods.conf
#
# Prints a ready-to-paste YAML `host:` list for input/config.yaml on stdout;
# does not edit config.yaml itself. Also writes a CSV of id,name,host to
# scripts/runpod/hosts.generated.csv for later teardown (`runpodctl pod stop
# <id>` or the RunPod console).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create_pods.sh -n <count> [-c <config-file>] [-o <output-csv>]

  -n <count>       Number of pods to create (required, positive integer).
  -c <config-file> Path to a pods.conf-style config (default: scripts/runpod/pods.conf).
  -o <output-csv>  Where to write id,name,host (default: scripts/runpod/hosts.generated.csv).
  -h               Show this help.

Set CREATE_DELAY_SEC in pods.conf to change the stagger between pod-creation
calls (default: 10s; set to 0 to disable).
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/pods.conf"
OUT_CSV="${SCRIPT_DIR}/hosts.generated.csv"
COUNT=""

while getopts "n:c:o:h" opt; do
  case "${opt}" in
    n) COUNT="${OPTARG}" ;;
    c) CONFIG_FILE="${OPTARG}" ;;
    o) OUT_CSV="${OPTARG}" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "${COUNT}" ]]; then
  echo "error: -n <count> is required" >&2
  usage
  exit 1
fi
if ! [[ "${COUNT}" =~ ^[0-9]+$ ]] || [[ "${COUNT}" -lt 1 ]]; then
  echo "error: -n must be a positive integer, got '${COUNT}'" >&2
  exit 1
fi

for bin in curl jq; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: required command '${bin}' not found on PATH" >&2
    exit 1
  fi
done

if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
  echo "error: RUNPOD_API_KEY is not set. export RUNPOD_API_KEY=... first." >&2
  exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "error: config file not found: ${CONFIG_FILE}" >&2
  echo "       copy scripts/runpod/pods.conf.example to get started." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

: "${IMAGE:?IMAGE not set in ${CONFIG_FILE}}"
: "${GPU_TYPE_ID:?GPU_TYPE_ID not set in ${CONFIG_FILE}}"
: "${GPU_COUNT:=1}"
: "${PORT:=8080}"
: "${CONTAINER_DISK_GB:=10}"
: "${VOLUME_GB:=20}"
: "${CLOUD_TYPE:=SECURE}"
: "${POD_NAME_PREFIX:=nli-runpod}"
: "${IDLE_MIN:=5}"
: "${POLL_SEC:=30}"
: "${HEALTH_TIMEOUT_SEC:=300}"
: "${HEALTH_POLL_INTERVAL_SEC:=10}"
# Stagger pod-creation calls so N pods don't all start pulling the (multi-GB,
# model-baked-in) image at the exact same instant — mitigates possible
# shared-egress/registry contention if several pods land on nearby nodes.
: "${CREATE_DELAY_SEC:=10}"
# Value injected as each pod's own RUNPOD_API_KEY env var (used by the idle
# watchdog's `runpodctl stop pod` call from inside the pod). Defaults to the
# raw local RUNPOD_API_KEY, but pods.conf can override this with a RunPod
# Secret reference (e.g. POD_ENV_RUNPOD_API_KEY='{{ RUNPOD_SECRET_name }}')
# so the raw key never appears in the API payload or hosts.generated.*.
: "${POD_ENV_RUNPOD_API_KEY:=${RUNPOD_API_KEY}}"

API_BASE="https://rest.runpod.io/v1"
timestamp="$(date +%Y%m%d%H%M%S)"

declare -a POD_IDS=()
declare -a POD_NAMES=()
declare -a POD_HOSTS=()

echo "Creating ${COUNT} pod(s) from ${CONFIG_FILE} (image=${IMAGE}, gpu=${GPU_TYPE_ID})..." >&2

for i in $(seq 1 "${COUNT}"); do
  name="$(printf '%s-%s-%02d' "${POD_NAME_PREFIX}" "${timestamp}" "${i}")"

  payload="$(
    jq -n \
      --arg name "${name}" \
      --arg image "${IMAGE}" \
      --arg gpuTypeId "${GPU_TYPE_ID}" \
      --argjson gpuCount "${GPU_COUNT}" \
      --arg port "${PORT}" \
      --argjson containerDiskInGb "${CONTAINER_DISK_GB}" \
      --argjson volumeInGb "${VOLUME_GB}" \
      --arg cloudType "${CLOUD_TYPE}" \
      --arg runpodApiKey "${POD_ENV_RUNPOD_API_KEY}" \
      --arg idleMin "${IDLE_MIN}" \
      --arg pollSec "${POLL_SEC}" \
      '{
        name: $name,
        imageName: $image,
        gpuTypeIds: [$gpuTypeId],
        gpuCount: $gpuCount,
        ports: [($port + "/http")],
        containerDiskInGb: $containerDiskInGb,
        volumeInGb: $volumeInGb,
        cloudType: $cloudType,
        env: {
          RUNPOD_API_KEY: $runpodApiKey,
          IDLE_MIN: $idleMin,
          POLL_SEC: $pollSec
        }
      }'
  )"

  echo "  [${i}/${COUNT}] creating ${name}..." >&2
  response="$(
    curl -sS -X POST "${API_BASE}/pods" \
      -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${payload}"
  )"

  pod_id="$(echo "${response}" | jq -r '.id // empty')"
  if [[ -z "${pod_id}" ]]; then
    echo "error: pod creation failed for ${name}. Response:" >&2
    echo "${response}" | jq . >&2 2>/dev/null || echo "${response}" >&2
    exit 1
  fi

  host="${pod_id}-${PORT}.proxy.runpod.net"
  echo "  [${i}/${COUNT}] created ${name} -> id=${pod_id} host=${host}" >&2

  POD_IDS+=("${pod_id}")
  POD_NAMES+=("${name}")
  POD_HOSTS+=("${host}")

  if [[ "${i}" -lt "${COUNT}" && "${CREATE_DELAY_SEC}" -gt 0 ]]; then
    sleep "${CREATE_DELAY_SEC}"
  fi
done

echo "id,name,host" > "${OUT_CSV}"
for idx in "${!POD_IDS[@]}"; do
  echo "${POD_IDS[$idx]},${POD_NAMES[$idx]},${POD_HOSTS[$idx]}" >> "${OUT_CSV}"
done
echo "Wrote pod inventory to ${OUT_CSV}" >&2

echo "Waiting for each pod's /health (timeout ${HEALTH_TIMEOUT_SEC}s each)..." >&2
for idx in "${!POD_HOSTS[@]}"; do
  host="${POD_HOSTS[$idx]}"
  name="${POD_NAMES[$idx]}"
  elapsed=0
  ready=0
  while [[ "${elapsed}" -lt "${HEALTH_TIMEOUT_SEC}" ]]; do
    if curl -sS --max-time 10 "https://${host}/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep "${HEALTH_POLL_INTERVAL_SEC}"
    elapsed=$((elapsed + HEALTH_POLL_INTERVAL_SEC))
  done
  if [[ "${ready}" -eq 1 ]]; then
    echo "  ${name} (${host}): ready after ~${elapsed}s" >&2
  else
    echo "  ${name} (${host}): NOT ready after ${HEALTH_TIMEOUT_SEC}s — check the RunPod console/logs" >&2
  fi
done

# Single-line flow-style YAML list — replace the whole `host: ...` line in
# input/config.yaml's active nli config entry with this line verbatim.
host_list="$(printf '"%s", ' "${POD_HOSTS[@]}")"
host_list="[${host_list%, }]"
host_line="host: ${host_list}"

echo "${host_line}" > "${SCRIPT_DIR}/hosts.generated.yaml"

echo "" >&2
echo "Paste this line to replace 'host:' in input/config.yaml's active nli config entry:" >&2
echo "---" >&2
echo "${host_line}"
echo "---" >&2
echo "(also written to ${SCRIPT_DIR}/hosts.generated.yaml)" >&2
echo "Pod inventory (for teardown): ${OUT_CSV}" >&2
echo "Stop a pod later with: runpodctl pod stop <id>   (ids are in ${OUT_CSV})" >&2
