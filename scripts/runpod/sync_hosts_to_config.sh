#!/usr/bin/env bash
# Splice the host list create_pods.sh just generated into input/config.yaml.
#
# create_pods.sh writes hosts.generated.yaml as exactly the one line config.yaml
# needs (host: ["<pod>-8080.proxy.runpod.net", ...]). Doing that by hand is the
# single slowest step between pods becoming ready and tar_make() sending them
# work -- and every minute of it is spent inside each already-ready pod's
# IDLE_MIN grace period (see keep_warm.sh for why /health polling does not help).
#
# Replaces ONLY the `host:` line inside the named nli.configs.<name> block,
# leaving every comment and every other config untouched. Dry-run by default.
#
# Usage:
#   scripts/runpod/sync_hosts_to_config.sh -c bge_m3_zeroshot_atomic_bm          # preview
#   scripts/runpod/sync_hosts_to_config.sh -c bge_m3_zeroshot_atomic_bm --write  # apply
set -euo pipefail

CONFIG="input/config.yaml"
HOSTS_YAML="external/runpod/scripts/runpod/hosts.generated.yaml"
BLOCK=""
WRITE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) BLOCK="$2"; shift 2 ;;
    -f) HOSTS_YAML="$2"; shift 2 ;;
    -o) CONFIG="$2"; shift 2 ;;
    --write) WRITE=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$BLOCK" ]]        || { echo "error: -c <nli config name> is required" >&2; exit 2; }
[[ -f "$HOSTS_YAML" ]]   || { echo "error: no generated host list at $HOSTS_YAML" >&2; exit 1; }
[[ -f "$CONFIG" ]]       || { echo "error: no config at $CONFIG" >&2; exit 1; }

BLOCK="$BLOCK" CONFIG="$CONFIG" HOSTS_YAML="$HOSTS_YAML" WRITE="$WRITE" python3 - <<'PY'
import io, os, re, sys

cfg_path, hosts_path = os.environ["CONFIG"], os.environ["HOSTS_YAML"]
block, write = os.environ["BLOCK"], os.environ["WRITE"] == "1"

new_line = None
for l in io.open(hosts_path, encoding="utf-8"):
    if l.strip().startswith("host:"):
        new_line = l.strip()
        break
if new_line is None:
    sys.exit("error: no `host:` line found in %s" % hosts_path)

lines = io.open(cfg_path, encoding="utf-8").read().split("\n")

# Find `    <block>:` then the first `host:` at a deeper indent before the next
# key at the same or shallower indent. Anchoring to the block is what keeps this
# from rewriting a different nli config's pool.
start = None
for i, l in enumerate(lines):
    m = re.match(r"^(\s*)%s:\s*$" % re.escape(block), l)
    if m:
        start, indent = i, len(m.group(1))
        break
if start is None:
    sys.exit("error: no `%s:` block in %s" % (block, cfg_path))

target = None
for i in range(start + 1, len(lines)):
    l = lines[i]
    if l.strip() and not l.startswith(" " * (indent + 1)):
        break                                   # left the block
    if re.match(r"^\s*host:", l):
        target = i
        break
if target is None:
    sys.exit("error: no `host:` line inside the `%s:` block" % block)

old = lines[target]
pad = re.match(r"^(\s*)", old).group(1)
n_old = old.count("proxy.runpod.net")
n_new = new_line.count("proxy.runpod.net")

print("block : %s   (%s:%d)" % (block, cfg_path, target + 1))
print("- %s" % old.strip()[:110])
print("+ %s" % new_line[:110])
print("hosts : %d -> %d" % (n_old, n_new))

if not write:
    print("\n(dry run - pass --write to apply)")
    sys.exit(0)

lines[target] = pad + new_line
io.open(cfg_path, "w", encoding="utf-8").write("\n".join(lines))
print("\nwritten. `workers` for crew is derived from this host count at "
      "_targets.R source time, so it picks up the new pool automatically.")
PY
