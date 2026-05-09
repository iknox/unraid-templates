# unraid-templates

Personal Unraid container templates for my homelab stack.

## Installing

Unraid webUI → **Docker** → **Add Container** → scroll to **Template repositories** → paste:

```
https://github.com/iknox/unraid-templates
```

Save. The templates appear under category **HomeLab: Memsearch** in the Template dropdown on the Add Container page.

## Catalog

### Memsearch stack (Milvus + etcd + Garage)

Runs the [zilliztech/memsearch](https://github.com/zilliztech/memsearch) server-mode backend. Three containers on a shared bridge network; installs in order.

| Template       | Image                          | Purpose                                    |
|----------------|--------------------------------|--------------------------------------------|
| `garage`       | `dxflrs/garage:v2.3.0`         | S3-compatible object store (MinIO replacement) |
| `milvus-etcd`  | `quay.io/coreos/etcd:v3.5.25`  | Metadata + coordination                    |
| `milvus`       | `milvusdb/milvus:v2.6.15`      | Vector database, Standalone mode           |

#### Prereqs (do once per host)

1. **Create the shared bridge network:**
   ```
   docker network create milvus-net
   ```
   (Unraid webUI → Settings → Docker → Network Type = Custom works too; CLI is faster.)

2. **Create appdata directories on cache pool:**
   ```
   mkdir -p /mnt/cache/appdata/garage/{meta,data}
   mkdir -p /mnt/cache/appdata/milvus/{etcd,data,configs}
   ```
   **Do not use `/mnt/user/…`** — FUSE fsync semantics cause etcd health-check flap.

3. **Drop starter configs:**
   ```
   cp config-examples/garage.toml    /mnt/cache/appdata/garage/garage.toml
   cp config-examples/milvus.yaml    /mnt/cache/appdata/milvus/configs/milvus.yaml
   ```
   Then edit `garage.toml` to replace the `REPLACE_WITH_OPENSSL_RAND_HEX_32` placeholders with real secrets. **The values must stay wrapped in double quotes** (TOML strings). Example:
   ```
   openssl rand -hex 32   # rpc_secret
   openssl rand -hex 32   # admin_token
   openssl rand -hex 32   # metrics_token (optional)
   ```
   Each result is a bare 64-char hex string; paste it *inside* the existing quotes in the file:
   ```
   rpc_secret = "80e66717ef4593c5d3f8adba9d36d2c17584b4177cca399706c888b45cd96e02"
   ```

#### Install order

Install each container from the Apps page in this order:

1. **garage** — wait for the container to report healthy.
2. **Bootstrap the bucket + access key** (one-time):
   ```
   bash scripts/bootstrap-garage.sh
   ```
   Copy the printed `Key ID` and `Secret key` into `milvus.yaml` under `minio.accessKeyID` / `minio.secretAccessKey`.
3. **milvus-etcd** — no further config needed.
4. **milvus** — reads the `milvus.yaml` you just edited.

#### Autostart

On the Docker page, switch to **Advanced View** and set:

| Container     | Autostart | Wait |
|---------------|-----------|------|
| `garage`      | ON        | 10s  |
| `milvus-etcd` | ON        | 10s  |
| `milvus`      | ON        | 0s   |

#### Smoke test

From any machine that can reach the Unraid host:

```
pip install pymilvus
python3 -c "
from pymilvus import MilvusClient
c = MilvusClient(uri='http://UNRAID-IP:19530')
print(c.list_collections())
"
```

Should print `[]` (empty list, no error).

#### Point memsearch at it

On your workstation:

```
memsearch config set milvus.uri http://UNRAID-IP:19530
```

Restart Claude Code; `SessionStart` will now use the remote Milvus for indexing.

## Notes

- All templates pin image tags. `:latest` is avoided so "update available" pings are actionable, not noise.
- Milvus compose file on upstream master currently references `v3.0-beta`; we pin `v2.6.15` which is the latest stable.
- MinIO is swapped for Garage because of the user's preference; Milvus speaks S3 to either one identically, with `useVirtualHost=false` and `region=garage`.
