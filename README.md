# unraid-templates

Five Unraid container templates for common homelab services, each usable standalone and a few that compose into interesting recipes.

## Installing the template feed

Unraid's Community Applications plugin doesn't expose an "Add Repository" UI, so personal template sources get dropped into CA's private-apps directory. From the Unraid terminal:

```
cd /boot/config/plugins/community.applications/private
git clone https://github.com/iknox/unraid-templates.git iknox-templates
```

Refresh the Apps page. The templates appear under the **Private Apps** filter.

---

## Catalog

| Template           | Image                                      | Category               | Role                                  |
|--------------------|--------------------------------------------|------------------------|---------------------------------------|
| `garage`           | `ghcr.io/iknox/garage-env:main`            | Tools: Storage         | S3-compatible object store            |
| `etcd`             | `quay.io/coreos/etcd:v3.5.25`              | Tools: Databases       | Distributed KV store                  |
| `milvus`           | `milvusdb/milvus:v2.6.15`                  | Tools: Databases       | Vector database (Standalone mode)     |
| `wyoming-parakeet` | `ghcr.io/tboby/wyoming-onnx-asr:v0.5.0`    | Home Assistant         | Wyoming-protocol STT                  |
| `wyoming-kokoro`   | `ghcr.io/iknox/wyoming-kokoro-cpu:main`    | Home Assistant         | Wyoming-protocol TTS                  |

### Garage (`garage`)

S3-compatible object storage — a lightweight MinIO alternative. This template uses [iknox/garage-env](https://github.com/iknox/garage-env), which wraps upstream Garage v2.3.0 with env-var configuration and auto-generates RPC/admin/metrics secrets plus the v2 cluster layout on first boot. Install and use — no TOML to edit, no bootstrap ritual.

### etcd (`etcd`)

Strongly-consistent distributed key-value store. Used by Kubernetes, Milvus, and many other systems. Ships with Milvus-friendly auto-compaction defaults.

### Milvus Standalone (`milvus`)

Open-source vector database for similarity search over embeddings. Standalone mode needs an S3-compatible object store and an etcd instance; template defaults point at the `garage` and `etcd` containers above. If you install all three, the only manual step is creating a Garage bucket and access key — see the [Recipe: memsearch backend](#recipe-memsearch-backend) below.

### Wyoming Parakeet (`wyoming-parakeet`)

CPU-only speech-to-text using NVIDIA NeMo Parakeet-TDT 0.6B v2 through ONNX Runtime, wrapped in the Wyoming protocol. Drop-in STT for Home Assistant Voice Assist, Rhasspy, or anything else that speaks Wyoming.

### Wyoming Kokoro (`wyoming-kokoro`)

CPU-only neural text-to-speech using Kokoro-ONNX, over Wyoming. Upstream chiabre/wyoming-kokoro ships source only; this template uses [iknox/wyoming-kokoro-cpu](https://github.com/iknox/wyoming-kokoro-cpu), which repackages it as a reproducible image. 50+ voices in English, Spanish, French, Italian, Portuguese, Japanese, Korean, and Chinese.

---

## Recipe: memsearch backend

Wires Garage + etcd + Milvus into a memory-search backend for the [zilliztech/memsearch](https://github.com/zilliztech/memsearch) Claude Code plugin (or any client that talks pymilvus). All three containers run on a shared Docker network and find each other by name.

### 1. Create the shared Docker network (one-time)

Unraid webUI → **Settings** → **Docker** → **Network Type** → **Add new network**:
- Name: `milvus-net`
- Driver: bridge
- Subnet: any free private range (e.g. `172.28.0.0/16`)

The default `bridge` network doesn't do DNS-based container-name resolution, which is why a user-defined bridge is required.

### 2. Install the containers

1. **`garage`** — install from Apps → Private Apps. Auto-generates secrets and cluster layout on first boot.
2. **Create the Milvus bucket + access key.** From the Unraid terminal:
   ```
   docker exec garage garage bucket create milvus
   docker exec garage garage key create milvus-key
   docker exec garage garage bucket allow --read --write --owner milvus --key milvus-key
   docker exec garage garage key info --show-secret milvus-key
   ```
   Copy the printed **Key ID** and **Secret key**.
3. **`etcd`** — install from Apps → Private Apps. No config needed.
4. **`milvus`** — install from Apps → Private Apps. Paste the Key ID into `MINIO_ACCESS_KEY_ID` and the Secret key into `MINIO_SECRET_ACCESS_KEY`. Leave everything else at defaults.

### 3. Autostart

Docker page → **Advanced View**:

| Container | Autostart | Wait |
|-----------|-----------|------|
| `garage`  | ON        | 5s   |
| `etcd`    | ON        | 5s   |
| `milvus`  | ON        | 0s   |

### 4. Smoke test

From any machine that can reach the Unraid host:

```
pip install pymilvus
python3 -c "from pymilvus import MilvusClient; print(MilvusClient(uri='http://UNRAID-IP:19530').list_collections())"
```

Expect `[]`.

### 5. Point memsearch at it

```
memsearch config set milvus.uri http://UNRAID-IP:19530
```

Restart Claude Code. The `SessionStart` hook now indexes to remote Milvus instead of a local `.db` file.

---

## Recipe: local Home Assistant Voice Assist

Install `wyoming-parakeet` and `wyoming-kokoro` from Apps → Private Apps — no prereqs, no shared network, models download on first boot.

In Home Assistant: Settings → Devices & services → **Wyoming Protocol** → add two entries pointing at your Unraid IP on ports `10300` (Parakeet STT) and `10200` (Kokoro TTS). Then Settings → Voice assistants → create a pipeline that selects them as STT/TTS.

---

## Notes

- All templates pin image tags. `:latest` is avoided so "update available" pings are actionable, not noise.
- Milvus's upstream compose file currently references `v3.0-beta`; we pin `v2.6.15`.
- Garage is wrapped by [iknox/garage-env](https://github.com/iknox/garage-env). Kokoro by [iknox/wyoming-kokoro-cpu](https://github.com/iknox/wyoming-kokoro-cpu).
