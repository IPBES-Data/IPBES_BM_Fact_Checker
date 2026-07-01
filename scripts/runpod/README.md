# RunPod pod-pool scripts

Create and start N RunPod pods programmatically, for running the NLI server
(`docker/nli-runpod/`) across a pool of GPUs in parallel instead of one pod at
a time. Uses the RunPod REST API directly — no local `runpodctl` install
needed.

## Usage

```bash
export RUNPOD_API_KEY=...          # your RunPod account API key

cp pods.conf.example pods.conf
$EDITOR pods.conf                  # set IMAGE, GPU_TYPE_ID, etc.

./create_pods.sh -n 3 -c pods.conf
```

This creates 3 pods, polls each one's `/health` until the NLI server inside
is responding (or times out), then prints:

- A ready-to-paste YAML `host:` list for the active entry in
  `input/config.yaml`. **The script does not edit `config.yaml` itself** —
  paste the list in yourself.
- `hosts.generated.csv` (id, name, host) for later teardown.

## Keeping the API key out of the payload

By default, the local `RUNPOD_API_KEY` you export is also injected as each
created pod's own `RUNPOD_API_KEY` env var (needed by its idle watchdog). That
means the raw key ends up in the pod-creation request body and in
`hosts.generated.csv`.

To avoid that, store the key as a [RunPod
Secret](https://docs.runpod.io/pods/templates/secrets) (console -> Secrets),
then set in `pods.conf`:

```bash
POD_ENV_RUNPOD_API_KEY='{{ RUNPOD_SECRET_runpod_api_key }}'
```

RunPod substitutes the real value only when the pod boots — the literal
template string is what gets sent in the API request, never the key itself.
The `RUNPOD_API_KEY` you export locally is still required as-is; it
authenticates the pod-creation call itself, which happens before any pod (and
thus any Secret substitution) exists.

## Finding a valid GPU type id

`GPU_TYPE_ID` in `pods.conf` must match RunPod's id exactly. List available
ids and current availability:

```bash
curl -s https://rest.runpod.io/v1/gpuTypes \
  -H "Authorization: Bearer $RUNPOD_API_KEY" | jq -r '.[].id'
```

## Tearing down

Each pod created this way still has the idle watchdog baked into the image
(`docker/nli-runpod/nli_idle_watchdog.sh`), so it self-stops after `IDLE_MIN`
minutes of no `/classify` traffic. To act immediately, use `stop_pods.sh`:

```bash
export RUNPOD_API_KEY=...

scripts/runpod/stop_pods.sh                      # stop every pod in hosts.generated.csv
scripts/runpod/stop_pods.sh -d                    # permanently delete them instead
scripts/runpod/stop_pods.sh -i <pod-id>           # target a specific pod id
```

**Stop** (`POST /pods/{id}/stop`, the default) halts the pod — GPU billing
stops, but the pod stays allocated and can be resumed later (RunPod console,
or `POST /pods/{id}/start`). **Delete** (`-d`/`--delete`, `DELETE /pods/{id}`)
removes the pod permanently — stops all billing including storage, but it
cannot be resumed afterward.

When run against the generated inventory (the default — not `-i <pod-id>`),
`hosts.generated.csv` and `hosts.generated.yaml` are deleted once every pod is
successfully actioned, since they'd otherwise reference pods that no longer
exist or are stopped.

## Notes / things to verify against current RunPod docs

RunPod's API has changed shape before (this project moved from the older
GraphQL API to `rest.runpod.io/v1` at some point). If `create_pods.sh` fails
with a validation error on a field like `cloudType`, check the current
request body schema at `https://docs.runpod.io/api-reference/pods/POST/pods`
and adjust `pods.conf`/the script accordingly.
