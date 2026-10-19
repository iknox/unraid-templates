# Deploying on Unraid

End-to-end recipes for the homelab stacks in this repo. Targets an Unraid user comfortable with Docker and the Community Applications plugin.

Two stacks live here, on the same Docker bridge (`local-ai`) but otherwise independent:

- **memsearch backend** — three containers (Garage + etcd + Milvus) for the [memsearch](https://github.com/zilliztech/memsearch) semantic memory store.
- **Local AI** — llama.cpp-based inference containers exposing an OpenAI-compatible `/v1` endpoint that any client can use.

You can install either or both. They share the `local-ai` network for DNS-by-name but don't depend on each other.

For the standalone service docs, see [README.md](README.md).

---

## Architecture

```
  Your Mac / workstation              Unraid host (`local-ai` Docker bridge)
  ┌─────────────────────────┐         ┌────────────────────────────────────────┐
  │ Any OpenAI client       │         │ Local AI (one at a time)               │
  │   (OpenCode, curl,      │── HTTP ─┼─▶ qwen38-flash-next-gufo (:8080)      │
  │    your own scripts)    │  /v1/   │   or deepseek-v4-flash-vulkan (:8080)  │
  │                         │         │                                        │
  │   └─ memsearch plugin ──┼── gRPC ─┼─▶ milvus (:19530, :9091)               │
  │       (SessionStart     │ 19530   │     ├─ etcd (:2379)                    │
  │        hook)            │         │     └─ garage (:3900)                  │
  └─────────────────────────┘         └────────────────────────────────────────┘
```

**Local AI stack:**
- **qwen38-flash-next-gufo** runs Qwen3.8-Flash-Next on ROCm/Gufo; **deepseek-v4-flash-vulkan** runs DeepSeek V4 Flash on Vulkan. They share host port 9931, so one runs at a time. Clients only need `http://UNRAID-IP:9931/v1`.

**memsearch backend:**
- **Garage** holds the actual vector chunk bytes (objects in an S3 bucket).
- **etcd** holds Milvus's metadata and leader-election state.
- **Milvus** is the vector DB — clients talk to it on TCP 19530.

**`local-ai`** is a user-defined Docker bridge; DNS by container name only works on user-defined bridges, not the default `bridge`. All stack containers live on it.

---

## Prerequisites

- Unraid 6.12+ with Community Applications plugin installed.
- For **memsearch**: ~2 GB free RAM, ~1 GB storage (plus your corpus). `memsearch` installed on the client; see [memsearch README](https://github.com/zilliztech/memsearch) and the OpenCode plugin notes below.
- For **Local AI**: a GPU that llama.cpp can target (Vulkan on AMD/Intel, ROCm on supported AMD, CUDA on NVIDIA), ~120 GB free disk for the daily-driver model, and enough GPU-addressable memory for the model you pick. Any OpenAI-compatible client on the workstation.

---

## One-time Unraid setup

### 1. Install the template feed

Unraid's CA plugin doesn't expose an "Add Repository" UI. Personal template sources live in CA's private-apps directory. From the Unraid terminal (webUI → **Tools** → **Terminal**, or SSH as root):

```bash
cd /boot/config/plugins/community.applications/private
git clone https://github.com/iknox/unraid-templates.git iknox-templates
```

Refresh the Apps page. The templates appear under the **Private Apps** filter.

### 2. Create the shared Docker network

Unraid webUI → **Settings** → **Docker** → **Network Type** → **Add new network**:

- **Name:** `local-ai`
- **Driver:** bridge
- **Subnet:** any free private range — `172.28.0.0/16` works
- Leave IPv6, gateway, iprange blank

Click **Save**. Network now exists.

Why a user-defined bridge: containers on the default `bridge` network can only reach each other by IP, not by name. Our templates reference `garage`, `etcd`, and `milvus` by name, so the user-defined bridge is required.

### 3. Configure the `appdata` share

Probably already done, but confirm: Unraid webUI → **Shares** → `appdata` → edit:

- Primary storage: cache pool (if you have one) or array
- Secondary storage: Array (recommended: "Prefer cache" so hot data stays on SSD)

If you don't have a cache pool yet, put everything on the array. You can reconfigure later without changing any container settings.

### 4. Kernel tuning (Strix Halo only)

The local-LLM templates assume the iGPU can see a large GTT window. Add this to the default **Unraid OS** entry in `/boot/syslinux/syslinux.cfg`, leaving the rest of the file unchanged:

```
append initrd=/bzroot amdgpu.gttsize=126976 amdgpu.no_system_mem_limit=1 ttm.pages_limit=32505856 amd_iommu=off
```

- `126976` MiB of GTT is 124 GiB; `ttm.pages_limit=32505856` is the same cap in 4 KiB pages.
- Set BIOS **UMA Frame Buffer Size** to 512M — GTT is the real budget.
- If you run ZFS, cap ARC so it does not compete with the GPU. On a 96 GB box we use 19.2 GiB: `echo 'options zfs zfs_arc_max=20615843020' > /boot/config/modprobe.d/zfs.conf`.

Reboot after editing, then verify with `cat /proc/cmdline`.

---

## Stack: Local AI (Qwen / DeepSeek)

Skip this section if you only want memsearch.

What you get: an OpenAI-compatible endpoint at `http://UNRAID-IP:9931/v1`. Two templates serve one model each:

| Template | Backend | Model |
|---|---|---|
| `qwen38-flash-next-gufo` | ROCm 10.0 / Gufo (needs `/dev/kfd`) | Qwen3.8-Flash-Next UD-Q4_K_XL + shared MTP Q8_0 head |
| `deepseek-v4-flash-vulkan` | Vulkan RADV (needs `/dev/dri` only) | DeepSeek V4 Flash 0731 UD-IQ2_XXS + dspark Q8_0 |

### Install

Apps → **Private Apps** → pick a template → Install. The defaults are already correct:

- HTTP / API: host `9931` → container `8080`
- Models: `/mnt/user/models`
- Config: `/mnt/user/appdata/<container-name>`

No model files are needed up front. On first boot the template seeds `/config/start.sh` from this repo, and that script fetches the pinned GGUFs from Hugging Face into the models share. Downloads use aria2 (8 connections per file, resuming if interrupted) with a curl fallback, and are size- and SHA-256-checked; expect roughly 100 GB per model and a long first start. Watch progress with `docker logs -f <container>`.

The two templates share host port 9931 **on purpose**: only one can hold the GPU at a time. Starting the second while the first runs fails on the port bind instead of silently fighting over GTT. To switch, stop one, let the GPU release memory, then start the other.

### Point a client at it

```bash
curl -sf http://UNRAID-IP:9931/v1/models | jq -r '.data[].id'

curl -sf http://UNRAID-IP:9931/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3.8-Flash-Next-UD-Q4_K_XL",
       "messages":[{"role":"user","content":"hello"}],
       "max_tokens":512}'
```

In a client (OpenCode, an editor plugin, your own script), set the base URL to `http://UNRAID-IP:9931/v1` and the model to an id from `/v1/models`. No API key is required.

### What "good" looks like

```bash
docker logs qwen38-flash-next-gufo --tail 20 2>&1 | grep -E "fetching|prompt eval|draft"
docker logs deepseek-v4-flash-vulkan   --tail 20 2>&1 | grep -E "fetching|prompt eval|draft"
```

First turn cold-loads the model (~30-60s). Later turns should respond in seconds.

---

## Stack: memsearch backend (Garage + etcd + Milvus)

### Step 1: Garage

Apps → **Private Apps** → **garage** → Install. Defaults are sane:

- S3 API: `3900` (only needed if external S3 clients will use this)
- Admin API: `3903`
- Web UI: `3909` (embedded admin UI — buckets, keys, cluster status, object browser; trusted-LAN only)
- Metadata: `/mnt/user/appdata/garage/meta`
- Data: `/mnt/user/appdata/garage/data`
- `GARAGE_S3_REGION=garage` (must match what Milvus expects)
- `GARAGE_REPLICATION_FACTOR=1`
- Secrets fields blank → auto-generated on first boot

Click Apply. Garage boots in ~5 seconds. On first boot it:

1. Generates RPC/admin/metrics secrets and persists them to `/mnt/user/appdata/garage/meta/.garage-env-secrets`.
2. Prints the generated secrets to the container log (grep `first-boot secrets`).
3. Auto-assigns and applies a single-node v2 cluster layout.
4. Writes `/etc/garage.toml` (chmod 600) from the template.

Secrets are ONE-TIME-GENERATED per volume. If you later delete `/mnt/user/appdata/garage/meta/` and reinstall, new secrets appear.

### Step 2: Create the Milvus bucket and access key

From the Unraid terminal:

```bash
docker exec garage garage bucket create milvus
docker exec garage garage key create milvus-key
docker exec garage garage bucket allow --read --write --owner milvus --key milvus-key
docker exec garage garage key info --show-secret milvus-key
```

Copy the `Key ID` (starts with `GK`) and `Secret key` (64 hex chars) from the last command's output. You'll paste them into the Milvus install form next.

The secret is re-printable at any time with that last command — nothing must be captured at creation time. (The web UI shows the Key ID under Buckets but never the secret.)

The `garage` CLI here is a wrapper we install inside the image that auto-injects `--rpc-secret-file` so the commands work via `docker exec` without env-var juggling.

### Step 3: etcd

Apps → **Private Apps** → **etcd** → Install. Zero configuration needed; defaults handle Milvus-friendly auto-compaction. No ports are published to the host — Milvus reaches etcd at `etcd:2379` over `local-ai`.

Data persists at `/mnt/user/appdata/etcd`.

### Step 4: Milvus

Apps → **Private Apps** → **milvus** → Install.

Paste your Garage credentials from Step 2 into:

- **MINIO_ACCESS_KEY_ID**: the `GK...` key
- **MINIO_SECRET_ACCESS_KEY**: the 64-hex secret

Leave everything else at defaults. Apply.

Milvus takes ~30–60 seconds to fully boot (8 internal components have to register with etcd, negotiate leadership, and open ports). First-time logs are noisy; many `bad resolver state` warnings are expected during the bootstrap race and resolve themselves.

### Step 5: Autostart

Docker page → **Advanced View** → set for each container:

| Container | Autostart | Wait |
|-----------|-----------|------|
| `garage`  | ON        | 5s   |
| `etcd`    | ON        | 5s   |
| `milvus`  | ON        | 0s   |

Wait values ensure Garage and etcd are fully up before Milvus tries to connect.

---

## Smoke test (memsearch)

From any machine that can reach the Unraid host on port 19530:

```bash
uvx --from pymilvus python3 -c "from pymilvus import MilvusClient; print(MilvusClient(uri='http://UNRAID-IP:19530').list_collections())"
```

Expect `[]` (empty list of collections).

From Unraid itself:

```bash
curl -sf http://localhost:9091/healthz && echo HEALTHY
```

Expect `OK`.

---

## Point memsearch at the backend

On your workstation (assumes `memsearch` is already installed as a uv tool — see the [memsearch OpenCode plugin notes](#memsearch-opencode-plugin-notes) section below if not):

```bash
memsearch config set milvus.uri http://UNRAID-IP:19530
```

Restart OpenCode if you use the plugin. Its next session indexes to the remote Milvus instead of a local `.db` file.

Verify end-to-end:

```bash
memsearch index /path/to/some/.md/files
memsearch stats
memsearch search "some query"
```

---

## Operational notes

### Upgrading

All images pin explicit tags. To pick up security updates:

- **Garage wrapper** (`ghcr.io/iknox/garage-env:main`) rebuilds automatically on every push to `main` in [iknox/unraid-images](https://github.com/iknox/unraid-images) (`garage-env/Dockerfile`). Unraid's CA update check will flag available updates; click Update in the UI to pull and recreate the container. Persisted state survives — but take a backup first on a major Garage bump, since the metadata DB may be migrated in place.
- **Milvus** is pinned to `milvusdb/milvus:v3.0.3`. Bumps are image-tag-only (no data migration step), but read [UPGRADING.md](UPGRADING.md) first: keep Storage V3 (Loon) off, chown the data dir to `999:999`, and roll back by restoring backups rather than retagging.
- **etcd** is pinned to `quay.io/coreos/etcd:v3.7.2`. Milvus 3.0 requires **≥ 3.6.11**; the 3.7 line needs no `--experimental-*` flags.
- **Qwen / DeepSeek** use kyuz0's `amd-strix-halo-toolboxes` tags (`rocm-10.0-gufo`, `vulkan-radv-performance`), rebuilt upstream as Gufo/llama.cpp change. Unraid flags new digests; click Update to pull. The weights on the models share are not touched.

### Resetting the stack

**memsearch backend** — order matters:

```bash
docker stop milvus && docker rm milvus
docker stop etcd   && docker rm etcd
docker stop garage && docker rm garage
rm -rf /mnt/user/appdata/garage/* \
       /mnt/user/appdata/etcd/* \
       /mnt/user/appdata/milvus/*
```

Then reinstall from Apps → Private Apps in the original order.

**Local AI** — no inter-state:

```bash
docker rm -f qwen38-flash-next-gufo deepseek-v4-flash-vulkan 2>/dev/null
rm -rf /mnt/user/appdata/qwen38-flash-next-gufo/* \
       /mnt/user/appdata/deepseek-v4-flash-vulkan/*
# Models in /mnt/user/models/ are ~100GB each; keep them
# unless you really mean to re-download.
```

Reinstall from Apps. First boot re-seeds `start.sh` and reuses any weights already present.

### Backups

- **Garage data** (`/mnt/user/appdata/garage/`) — the actual vector bytes. This is the important one.
- **Garage metadata** (`/mnt/user/appdata/garage/meta/`) — bucket/key definitions + cluster layout + secrets. Back this up too; losing it means regenerating all credentials.
- **etcd data** (`/mnt/user/appdata/etcd/`) — Milvus metadata only. If you lose it, Milvus bootstraps a fresh empty collection; Garage still holds the bytes but they become orphaned. Not worth backing up separately — just plan to re-index.
- **Milvus data** (`/mnt/user/appdata/milvus/`) — rocksmq WAL + segment staging. Ephemeral, not worth backing up.

Practical backup approach: snapshot or rsync `/mnt/user/appdata/garage/` regularly; everything else is derivable.

---

## memsearch OpenCode plugin notes

If you're using memsearch via the OpenCode plugin rather than the standalone CLI:

### Recommended install path

```bash
# Remove any uvx-cached copy:
uv tool uninstall memsearch 2>/dev/null

# Install memsearch as a persistent uv tool (NOT the ephemeral uvx cache):
uv tool install 'memsearch[onnx]'
```

This puts memsearch at `~/.local/share/uv/tools/memsearch/` (stable across sessions) and on your `$PATH` as `~/.local/bin/memsearch`. Install it as a persistent uv tool so the plugin and your shell resolve the same version; an ephemeral `uvx` cache is easy to lose between sessions.

Then enable the plugin in `~/.config/opencode/opencode.jsonc`:

```json
{
  "plugin": ["@zilliz/memsearch-opencode"]
}
```

### Configuring for remote Milvus

```bash
memsearch config set milvus.uri http://UNRAID-IP:19530
memsearch config set embedding.provider onnx   # default local ONNX bge-m3-int8
```

Config lands in `~/.memsearch/config.toml`. The plugin reads it on the next OpenCode session.

---

## Troubleshooting

### Operational constraints

- **TOML secrets must be double-quoted.** Bare hex strings crash Garage's TOML parser. The garage-env wrapper handles this; if you edit `garage.toml` by hand, keep the quotes.
- **Garage needs an explicit cluster layout before bucket operations.** Without `garage layout assign` + `apply`, bucket creates fail with "Layout not ready". The wrapper bootstraps this on first boot.
- **Milvus's `minio.region` must match Garage's `s3_region`.** AWS SigV4 signs the region; a mismatch produces `AuthorizationHeaderMalformed`. Both default to `garage`.
- **Use `docker exec garage garage ...`, not `/garage`.** Docker exec inherits the container's empty `GARAGE_RPC_SECRET`, which overrides the config file and fails with "Invalid RPC secret provided (wrong length)". The wrapper's `/usr/local/bin/garage` unsets the env vars and reads `--rpc-secret-file`.

### Milvus template overrides

The template pins four values:

- `MQ_TYPE=rocksmq` — standalone must not use kafka.
- `LOCAL_STORAGE_PATH=/var/lib/milvus/data` — prevents the QueryNode `mkdir ""` failure.
- `DATA_COORD_SEGMENT_MIN_SIZE_FROM_IDLE_TO_SEALED=16` — prevents the stats-config validator from rejecting the computed segment size on large-memory hosts.
- `PROXY_PORT=19530` / `ROOT_COORD_PORT=22125` — keeps MixCoord off the Proxy port.

The image runs as `999:999`; `chown -R 999:999 /mnt/user/appdata/milvus/data` before first start.

### CA private-apps directory name

The directory under `/boot/config/plugins/community.applications/private/` must be plain ASCII (`[a-zA-Z0-9_-]`). Spaces and apostrophes make CA's Install button silently no-op.

### Network declaration in templates

Unraid's `<Network>` XML field accepts `bridge`, `host`, `none`, or a Docker network that already exists and is registered in Unraid's known-networks list. A custom name like `local-ai` in `<Network>` makes Install a no-op. Use `<Network>bridge</Network>` + `<ExtraParams>--network=local-ai</ExtraParams>`.

### Useful diagnostic commands

```bash
# All stack containers and their status
docker ps --filter name=garage --filter name=etcd --filter name=milvus \
  --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

# Milvus readiness
curl -sf http://localhost:9091/healthz

# Current Milvus collections (from Unraid itself)
docker exec milvus curl -s http://localhost:9091/webui/   # minimal admin page

# Recover the first-boot Garage secrets if you missed them in the log
docker logs garage 2>&1 | grep -A6 "first-boot secrets"

# Milvus config actually in use (env vars that won)
docker exec milvus env | grep -E "MINIO|ETCD|MQ_|PORT|COORD|LOCAL_STORAGE"

# Garage cluster health
docker exec garage garage status
docker exec garage garage bucket list
```
