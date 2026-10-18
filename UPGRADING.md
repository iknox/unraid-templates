# Upgrade notes

Checks to run when bumping pinned image versions, especially on a Renovate PR.

## Milvus (`milvusdb/milvus`)

Current pin: **`v3.0.3`**.

### 3.x invariants

1. **It is an image-tag change, not a data migration.** In-place upgrade is supported from **2.6.20**; below that, step through `v2.6.25` first.
2. **Keep Storage V3 (Loon) off.** `common.storage.useLoonFFI` is `false` by default and must stay `false`. Enabling it changes the serialized data format and closes the rollback path. Treat it as its own project.
3. **Roll back by restoring backups, not retagging.** Once 3.0 has written data, retagging to 2.6 can leave collections unserviceable due to index-store path versions.
4. **The runtime user is `milvus:milvus` (uid/gid 999).** `chown -R 999:999 /mnt/user/appdata/milvus/data` before first start or the container loops on permission errors.
5. **Back up before a 3.x upgrade.** Stop Milvus, `etcdctl snapshot save`, then tar `garage/`, `etcd/`, `milvus/`. Garage is the only non-derivable data and the whole set is ~100 MB.

### Template overrides

The template pins these; `MQ_TYPE` is the only one not matched by the 3.0.3 defaults.

| Env var | 3.0.3 default | Status |
|---|---|---|
| `MQ_TYPE=rocksmq` | `mq.type: default` | **Keep.** Standalone must never fall back to kafka. |
| `LOCAL_STORAGE_PATH` | `/var/lib/milvus/data/` | Redundant, harmless. |
| `DATA_COORD_SEGMENT_MIN_SIZE_FROM_IDLE_TO_SEALED=16` | `16` | Redundant, harmless. |
| `PROXY_PORT` / `ROOT_COORD_PORT` | `19530` / `22125` | Redundant, harmless. |

### Before merging any Renovate bump

1. **Read the upstream release notes.** https://github.com/milvus-io/milvus/releases
2. **Diff `configs/milvus.yaml` between tags** for env-var renames and default changes.
3. **Check whether the Storage V3 default flipped.** If it did, pin it off explicitly.
4. **Check the image's `Config.User`.** A uid change needs a chown.
5. **Test staged on Castle**, then verify collection counts *and* a real search — not just `healthz`.

### Test recipe

```bash
# Back up first (Milvus stopped, so rocksmq is consistent)
docker stop milvus
docker exec etcd etcdctl --endpoints=http://127.0.0.1:2379 snapshot save /etcd/pre-upgrade.db
tar -czf /mnt/user/backups/milvus-pre-upgrade.tgz -C /mnt/user/appdata garage etcd milvus

# Apply the new tag through Unraid's own template → docker run path
/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/rebuild_container milvus

# Verify
curl -sf http://localhost:9091/healthz && echo HEALTHY
docker logs milvus 2>&1 | grep -nE "FATAL|panic:|permission denied|bind: address already in use"
```

Then confirm every collection still has its expected row count and run one real `memsearch search`. If the upgrade fails, restore the tars and retag — do not let a half-working 3.x write while you debug.

## etcd (`quay.io/coreos/etcd`)

Generally safe to auto-merge patch + minor updates. Major version bumps need careful review — etcd's storage format can change across majors. The config uses standard env vars (`ETCD_AUTO_COMPACTION_MODE`, etc.) that are stable.

## Garage (via `iknox/garage-env`)

Bumps to upstream `dxflrs/garage` happen in the `unraid-images` repo, not here. The wrapper image's `Dockerfile` pins the upstream version with `FROM dxflrs/garage:vX.Y.Z`; Renovate watches that. When a new `garage-env` image publishes to GHCR, the Unraid container picks up the new `:main` tag on the next "Force Update" or restart.

Things to watch in Garage upgrades:

- **Breaking changes to `garage.toml` schema** — `garage.toml.tmpl` may need updates.
- **Cluster layout changes** — the auto-bootstrap assumes v2 semantics.
- **CLI flag changes** — the wrapper at `/usr/local/bin/garage` injects `--rpc-secret-file`; if that flag is renamed, update the wrapper.
