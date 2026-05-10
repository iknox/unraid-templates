# unraid-templates

Personal Unraid container templates for my homelab stack.

## Installing the template feed

Unraid has no public "add template repo" UI. The supported mechanism for a personal template source is dropping a clone of this repo into Community Applications' private-apps directory. From the Unraid terminal:

```
cd /boot/config/plugins/community.applications/private
git clone https://github.com/iknox/unraid-templates.git iknox-templates
```

Refresh the Apps page. The templates appear under the **Private Apps** filter.

---

## Catalog

### Memsearch backend (Milvus + etcd + Garage)

Milvus-backed vector database for the [zilliztech/memsearch](https://github.com/zilliztech/memsearch) Claude Code plugin. Three containers on a shared bridge; all configured via env vars — no yaml or toml files to hand-edit.

| Template      | Image                              | Role                                  |
|---------------|------------------------------------|---------------------------------------|
| `garage`      | `ghcr.io/iknox/garage-env:main`    | S3-compatible object store            |
| `milvus-etcd` | `quay.io/coreos/etcd:v3.5.25`      | Metadata + coordination               |
| `milvus`      | `milvusdb/milvus:v2.6.15`          | Vector database (Standalone mode)     |

#### One-time prereq — create the shared Docker network

**Unraid webUI → Settings → Docker → Network Type** → **Add new network**:
- Name: `milvus-net`
- Driver: bridge
- Subnet: any free private range (e.g. `172.28.0.0/16`)

The three containers find each other by name (`garage`, `milvus-etcd`, `milvus`) on this network, which requires a user-defined bridge — the default `bridge` network doesn't support DNS.

#### Install order

1. **`garage`** — install from Apps → Private Apps. Secrets auto-generate on first boot and persist in the metadata dir.

2. **Create the Milvus bucket and access key.** The garage container auto-bootstraps its cluster layout on first boot, so these just work. From the Unraid terminal:
   ```
   docker exec garage garage bucket create milvus
   docker exec garage garage key create milvus-key
   docker exec garage garage bucket allow --read --write --owner milvus --key milvus-key
   docker exec garage garage key info --show-secret milvus-key
   ```
   Copy the printed **Key ID** and **Secret key** — you'll paste them into the Milvus install form.

3. **`milvus-etcd`** — install from Apps → Private Apps. No config needed.

4. **`milvus`** — install from Apps → Private Apps. Paste the Key ID into `MINIO_ACCESS_KEY_ID` and the Secret key into `MINIO_SECRET_ACCESS_KEY`. Leave everything else at defaults.

#### Autostart

Docker page → **Advanced View** → set:

| Container     | Autostart | Wait |
|---------------|-----------|------|
| `garage`      | ON        | 5s   |
| `milvus-etcd` | ON        | 5s   |
| `milvus`      | ON        | 0s   |

#### Smoke test

From any machine that can reach the Unraid host:

```
pip install pymilvus
python3 -c "from pymilvus import MilvusClient; print(MilvusClient(uri='http://UNRAID-IP:19530').list_collections())"
```

Should print `[]`.

#### Point memsearch at it

On your workstation:

```
memsearch config set milvus.uri http://UNRAID-IP:19530
```

Restart Claude Code. The `SessionStart` hook now indexes to remote Milvus instead of the local `.db` file.

---

### Home Assistant Voice Assist (Parakeet + Kokoro)

Wyoming-protocol STT/TTS containers for HA's Assist pipeline. Fully CPU-based.

| Template           | Image                                      | Role                       |
|--------------------|--------------------------------------------|----------------------------|
| `wyoming-parakeet` | `ghcr.io/tboby/wyoming-onnx-asr:v0.5.0`    | STT (NVIDIA Parakeet-TDT)  |
| `wyoming-kokoro`   | `ghcr.io/iknox/wyoming-kokoro-cpu:main`    | TTS (Kokoro-ONNX)          |

**Install** from Apps → Private Apps. Models download on first boot (~600 MB Parakeet, ~80 MB Kokoro). Both are independent of each other and of the memsearch stack.

**Configure in HA:** Settings → Devices & services → Add integration → **Wyoming Protocol** → host = Unraid IP, port = `10300` (Parakeet) or `10200` (Kokoro). Then Settings → Voice assistants → create a pipeline that selects them as STT/TTS.

---

## Notes

- All templates pin image tags. `:latest` is avoided so "update available" pings are actionable, not noise.
- Milvus compose file on upstream master currently references `v3.0-beta`; we pin `v2.6.15`.
- Garage is wrapped by [iknox/garage-env](https://github.com/iknox/garage-env), a thin shim that templates `garage.toml` from env vars and auto-generates secrets.
- Kokoro is wrapped by [iknox/wyoming-kokoro-cpu](https://github.com/iknox/wyoming-kokoro-cpu) since chiabre's upstream is source-only.
