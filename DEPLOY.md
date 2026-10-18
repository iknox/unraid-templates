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
  │ Any OpenAI client       │         │ Local AI                               │
  │   (OpenCode, curl,      │── HTTP ─┼─▶ llama-swap (:8080)                   │
  │    your own scripts)    │  /v1/   │     │ multi-model proxy                │
  │                         │  chat   │     ▼                                  │
  │                         │         │   llama-server (Vulkan, in-container)  │
  │                         │         │                                        │
  │   └─ memsearch plugin ──┼── gRPC ─┼─▶ milvus (:19530, :9091)               │
  │       (SessionStart     │ 19530   │     ├─ etcd (:2379)                    │
  │        hook)            │         │     └─ garage (:3900)                  │
  └─────────────────────────┘         └────────────────────────────────────────┘
```

**Local AI stack:**
- **llama-swap** spawns llama-server processes per model on demand, with a baked-in Vulkan-accelerated llama.cpp. A single llama.cpp server container (Gufo, llama.cpp Vulkan) can sit in the same slot; clients only need `http://UNRAID-IP:8080/v1`.

**memsearch backend:**
- **Garage** holds the actual vector chunk bytes (objects in an S3 bucket).
- **etcd** holds Milvus's metadata and leader-election state.
- **Milvus** is the vector DB — clients talk to it on TCP 19530.

**`local-ai`** is a user-defined Docker bridge; DNS by container name only works on user-defined bridges, not the default `bridge`. All stack containers live on it. (Originally named `milvus-net` in older templates — this network now hosts more than Milvus, hence the rename.)

---

## Prerequisites

- Unraid 6.12+ with Community Applications plugin installed.
- For **memsearch**: ~2 GB free RAM, ~1 GB storage (plus your corpus). `memsearch` installed on the client; see [memsearch README](https://github.com/zilliztech/memsearch) and the Claude Code plugin notes below.
- For **Local AI**: a GPU that llama.cpp can target (Vulkan on AMD/Intel, ROCm on supported AMD, CUDA on NVIDIA), ~20 GB free disk for the daily-driver model, and enough GPU-addressable memory for the model you pick. Any OpenAI-compatible client on the workstation.

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

---

## Stack: Local AI (llama-swap)

Skip this section if you only want memsearch.

What you get: a local OpenAI-compatible inference endpoint at `http://UNRAID-IP:8080/v1`. Point any OpenAI-compatible client at it.

### Step 1: llama-swap

Apps → **Private Apps** → **llama-swap** → Install. Defaults are sane:

- HTTP / API: `8080`
- Models: `/mnt/user/models`
- Config: `/mnt/user/appdata/llama-swap`

On first boot the template auto-downloads a starter `config.yaml` from this repo with three model entries: a tiny smoke-test (`llama-3.2-3b_TEST`), a daily-driver coder (`qwen3-coder-30b_CODE`), and a parked general-purpose entry (`qwen3.6-35b-mtp_GEN_PURPOSE`). Edits to the config hot-reload — no container restart needed.

You then need to actually drop GGUF files into the Models dir. The seed config expects:

```bash
mkdir -p /mnt/user/models/Qwen3-Coder-30B-A3B-Instruct-GGUF
cd /mnt/user/models/Qwen3-Coder-30B-A3B-Instruct-GGUF
wget -O Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf \
  "https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf?download=true"
```

(That's the 17.7 GB Q4 daily driver. The smoke-test 3B is ~1.9 GB from `unsloth/Llama-3.2-3B-Instruct-GGUF`. The 35B-MTP is currently broken upstream — see config comments.)

Verify by hitting the model list:

```bash
curl -sf http://UNRAID-IP:8080/v1/models | jq -r '.data[].id'
```

### Step 2: Point a client at it

Anything that speaks OpenAI chat-completions works:

```bash
curl -sf http://UNRAID-IP:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-coder-30b_CODE","messages":[{"role":"user","content":"hello"}],"max_tokens":64}'
```

In a client (OpenCode, an editor plugin, your own script), set the base URL to `http://UNRAID-IP:8080/v1` and the model to one of the ids from `/v1/models`. No API key is required by the local server.

### What "good" looks like

```bash
docker logs llama-swap --tail 20 2>&1 | grep -E "prompt eval|cache_n"
```

First turn cold-loads the model (~30-60s). Later turns should respond in seconds, and `cache_n` should increase turn-over-turn as llama.cpp reuses the prompt cache.

---

## Stack: memsearch backend (Garage + etcd + Milvus)

### Step 1: Garage

Apps → **Private Apps** → **garage** → Install. Defaults are sane:

- S3 API: `3900` (only needed if external S3 clients will use this)
- Admin API: `3903`
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

On your workstation (assumes `memsearch` is already installed as a uv tool — see the [memsearch Claude Code plugin notes](#memsearch-claude-code-plugin-notes) section below if not):

```bash
memsearch config set milvus.uri http://UNRAID-IP:19530
```

Restart Claude Code if you use the plugin. The SessionStart hook now indexes to the remote Milvus instead of the local `.db` file.

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
- **Milvus** is pinned to `milvusdb/milvus:v3.0.3`. Bumps are image-tag-only (no data migration step), but read [MIGRATIONS.md](MIGRATIONS.md) first: keep Storage V3 (Loon) off, chown the data dir to `999:999`, and roll back by restoring backups rather than retagging.
- **etcd** is pinned to `quay.io/coreos/etcd:v3.7.2`. Milvus 3.0 requires **≥ 3.6.11**; the 3.7 line needs no `--experimental-*` flags.
- **llama-swap** uses `:vulkan` (a moving tag rebuilt by upstream as new llama.cpp releases land). To pick up a new llama.cpp build, click Update in the Unraid UI; container restarts with the new image. Edits to your `config.yaml` survive (volume-mounted).

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

**Local AI** — order doesn't matter (no inter-state):

```bash
docker stop llama-swap && docker rm llama-swap
rm -rf /mnt/user/appdata/llama-swap/*
# Models in /mnt/user/models/ are 17GB+ each; keep them
# unless you really mean to re-download.
```

Reinstall from Apps. The template auto-seeds its config on first boot from this repo.

### Backups

- **Garage data** (`/mnt/user/appdata/garage/`) — the actual vector bytes. This is the important one.
- **Garage metadata** (`/mnt/user/appdata/garage/meta/`) — bucket/key definitions + cluster layout + secrets. Back this up too; losing it means regenerating all credentials.
- **etcd data** (`/mnt/user/appdata/etcd/`) — Milvus metadata only. If you lose it, Milvus bootstraps a fresh empty collection; Garage still holds the bytes but they become orphaned. Not worth backing up separately — just plan to re-index.
- **Milvus data** (`/mnt/user/appdata/milvus/`) — rocksmq WAL + segment staging. Ephemeral, not worth backing up.

Practical backup approach: snapshot or rsync `/mnt/user/appdata/garage/` regularly; everything else is derivable.

---

## memsearch Claude Code plugin notes

If you're using memsearch via the Claude Code plugin rather than the standalone CLI:

### Recommended install path

```bash
# Remove any old uvx-cached version:
uv tool uninstall memsearch 2>/dev/null

# Install memsearch as a persistent uv tool (NOT the ephemeral uvx cache):
uv tool install 'memsearch[onnx]'
```

This puts memsearch at `~/.local/share/uv/tools/memsearch/` (stable across sessions) and on your `$PATH` as `~/.local/bin/memsearch`. The Claude Code plugin's hooks prefer PATH-discovered memsearch over their `uvx --from ...` fallback, so SessionStart is faster and the patch below sticks.

### No patch needed on memsearch ≥ 0.4.21

Older versions had an upstream bug ([#534](https://github.com/zilliztech/memsearch/issues/534)) where `MilvusStore.upsert()` never called `flush()`. Milvus Lite auto-flushes; remote Milvus 2.5+ did not, so indexed chunks reported "upserted" but were invisible to subsequent searches. The old workaround was a one-line `self._client.flush(...)` patch applied by hand after every upgrade.

That is obsolete. The fix landed upstream in [PR #757](https://github.com/zilliztech/memsearch/pull/757) (released in 0.4.21) and works differently: the store counts newly written rows and sets `consistency_level="Strong"` on searches, so results are visible without an explicit flush. **Do not re-apply the old flush patch** — it fights the new logic and slows every upsert. If you still see empty results on a remote Milvus, upgrade memsearch and check `memsearch --version` before touching `store.py`.

Verified 2026-10-18 on the Castle stack: index → immediate search returns score 1.0000.

### Configuring for remote Milvus

```bash
memsearch config set milvus.uri http://UNRAID-IP:19530
memsearch config set embedding.provider onnx   # default local ONNX bge-m3-int8
```

Config lands in `~/.memsearch/config.toml`. The plugin's SessionStart hook picks it up automatically on next Claude Code launch.

---

## Troubleshooting / History

This section documents the non-obvious bugs and design decisions we hit getting this stack to work cleanly on Unraid. Useful if you need to modify the templates or debug a new installation.

### Why Garage instead of MinIO

Milvus's official docker-compose defaults to MinIO for object storage. This repo swaps in Garage because:

- **Licensing/governance:** MinIO's upstream has made increasingly aggressive license + feature-tier changes since 2023. Garage is AGPL-3.0, built by a smaller community, and not chasing SaaS monetization.
- **Footprint:** Garage is a single statically-linked binary; roughly half the resource footprint.
- **API compatibility:** Milvus talks S3 via the AWS SDK. Both MinIO and Garage implement the same subset (PutObject/GetObject/ListObjectsV2/multipart), so the swap is transparent to Milvus.

Gotchas we hit and solved:

- **TOML secrets must be double-quoted.** Bare hex strings crash Garage's TOML parser. The garage-env wrapper handles this automatically; if you're editing garage.toml by hand, keep the quotes.
- **Garage v2 requires an explicit cluster layout before bucket operations.** Without running `garage layout assign + apply`, every bucket create errors with "Layout not ready". The wrapper auto-bootstraps this on first boot.
- **Milvus's `minio.region` must match Garage's `s3_region`.** AWS SigV4 signs the region into the request; a mismatch produces a cryptic `AuthorizationHeaderMalformed`. Both sides default to `garage` in our templates.
- **`docker exec garage /garage ...` fails with "Invalid RPC secret provided (wrong length)".** Docker exec inherits the container's `Config.Env` — which has empty `GARAGE_RPC_SECRET=` from the template form — and that empty value beats the config file. The garage-env wrapper installs `/usr/local/bin/garage` which `unset`s the env vars and reads from `--rpc-secret-file`. Hence `docker exec garage garage ...` (note: no leading slash) works.

### Milvus startup gotchas (2.6.x → 3.0.x)

These bit us on 2.6.x. As of **3.0.3** the shipped `configs/milvus.yaml` defaults match what we pin, so most are now belt-and-braces. The template keeps them anyway — a silent startup failure is a bad trade for four lines of XML.

1. **mq.type defaults to kafka.** Standalone expects `rocksmq`. If kafka is set (e.g. from a stale etcd value), Milvus tries `localhost:9092`, can't connect, and dies silently after its init phase. The template pins `MQ_TYPE=rocksmq` — still the one override worth keeping.

2. **localStorage.path defaults to empty.** QueryNode then does `mkdir ""` and FATALs with `no such file or directory`. The template pins `LOCAL_STORAGE_PATH=/var/lib/milvus/data`; 3.0.3 now defaults to `/var/lib/milvus/data/`.

3. **Stats-config validator panic.** On hosts with a lot of RAM, Milvus's `minSizeFromIdleToSealed` calculation resolves to 0, which the 2.6.x validator rejected at startup. The panic log message is misleading — it prints the (correct) HWM/LWM values as if *they* were the issue. The template pins `DATA_COORD_SEGMENT_MIN_SIZE_FROM_IDLE_TO_SEALED=16`; that is the 3.0.3 default too.

4. **Port collision between MixCoord and Proxy.** In 2.6, RootCoord was consolidated into MixCoord, which binds `rootCoord.port`. If the default resolves to `19530` (Proxy's external port), you get an infinite restart loop with `listen tcp :19530: bind: address already in use`. The template pins `PROXY_PORT=19530` and `ROOT_COORD_PORT=22125`; 3.0.3 defaults to 22125.

5. **3.0 runs as a non-root user.** The image's `Config.User` is `999:999`. On Unraid, `chown -R 999:999 /mnt/user/appdata/milvus/data` once before the first 3.x start, or the container loops on permission errors.

### Why env vars instead of milvus.yaml

The earlier version of this stack mounted a `milvus.yaml` file from `/mnt/user/appdata/milvus/configs/`. This required users to manually copy a starter file, edit the Garage key fields, and keep the file in sync with template defaults. Replaced with Unraid template env-var fields after we verified all ~25 yaml keys have env-var overrides in Milvus 2.6 (still true in 3.0). Upper-snake-case of the dotted yaml path works (e.g. `minio.accessKeyID` → `MINIO_ACCESS_KEY_ID`).

### Why `/mnt/user/appdata` not `/mnt/cache/appdata`

An earlier version of this stack pinned paths to `/mnt/cache/appdata/...` on the theory that etcd and rocksmq want fast fsync, which FUSE-backed user shares handle less well. Problem: Unraid users without a cache pool don't have `/mnt/cache/` as a real mount — bind-mounting there lands on tmpfs (root filesystem) and data vanishes on reboot. Flipped to `/mnt/user/appdata/...`, which transparently handles every Unraid storage topology (single disk, cache-only, cache+array, multiple pools) via the share layer. Users with a cache pool who want the performance bump configure the `appdata` share to "Prefer cache" — no template changes needed.

### CA private-apps directory naming

The directory under `/boot/config/plugins/community.applications/private/` must be plain ASCII. An earlier attempt at `"iknox's templates"` (space + apostrophe) caused CA's Install button to silently no-op; CA's path-escaping code doesn't handle those characters. Stick to `[a-zA-Z0-9_-]`.

### Network declaration in templates

Unraid's `<Network>` XML field expects one of: `bridge`, `host`, `none`, or the name of a Docker network that already exists on the host *and* has been registered in Unraid's known-networks list. Putting a custom network name like `local-ai` directly in `<Network>` silently makes the Install button a no-op — CA's form builder can't resolve the dropdown option. The working pattern is `<Network>bridge</Network>` + `<ExtraParams>--network=local-ai</ExtraParams>`, which is what these templates use.

### memsearch issue #534 (fixed upstream)

Discovered after standing up the remote Milvus and finding zero search results despite "successfully indexed" logs. Milvus returned `collection not found` on subsequent queries; the upsert had buffered but never flushed. Milvus Lite masked the bug by auto-flushing.

Fixed in [PR #757](https://github.com/zilliztech/memsearch/pull/757), released in **memsearch 0.4.21**. The fix is not a flush call — it counts newly written rows and queries with `consistency_level="Strong"`. See [No patch needed on memsearch ≥ 0.4.21](#no-patch-needed-on-memsearch--0421); do not re-apply the old `store.py` patch.

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
