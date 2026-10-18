# Migration notes

Things to check when bumping pinned image versions, especially when reviewing a Renovate PR.

## Milvus (`milvusdb/milvus`)

Current pin: **`v3.0.3`**. Upgraded from `v2.6.19` on 2026-10-18, staged `2.6.19 → 2.6.25 → 3.0.3`.

### 2.6 → 3.x invariants

1. **It is an image-tag change, not a data migration.** In-place upgrade is supported. The vendor-validated path starts at **2.6.20**, so step through the last 2.6 patch (`v2.6.25`) first if you are below it.
2. **Keep Storage V3 (Loon) off.** `common.storage.useLoonFFI` is `false` by default and must stay `false`. Enabling it changes the serialized data format, permanently closes the rollback door, and then decays that door segment-by-segment as background compaction rewrites data. Treat it as its own project.
3. **Rolling back by image swap is not validated.** Format compatibility is claimed, but the *operation* is not: once 3.0 has written data, retagging to 2.6 can leave collections unserviceable due to index-store path versions. Roll back by restoring the pre-upgrade backups instead.
4. **The runtime user changed.** 2.6.x ran as root; 3.0.x runs as `milvus:milvus` (**uid/gid 999**). On Unraid, `chown -R 999:999 /mnt/user/appdata/milvus/data` before first start or the container loops on permission errors. Upstream's compose now does this with a one-shot `milvus-volume-init` container.
5. **Back up before letting 3.x write.** Stop Milvus, `etcdctl snapshot save`, then tar `garage/`, `etcd/`, `milvus/`. Garage is the only non-derivable data and the whole set is ~100 MB — there is no reason to skip it.

### Template overrides — still present, now mostly redundant

As of 3.0.3 the shipped `configs/milvus.yaml` defaults match what we pin, so three of the four are belt-and-braces:

| Env var | 3.0.3 default | Status |
|---|---|---|
| `MQ_TYPE=rocksmq` | `mq.type: default` | **Keep.** Not retested without it; standalone must never fall back to kafka. |
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

Generally safe to auto-merge patch + minor updates. Major version bumps (3.5 → 4.x if it ever happens) need careful review — etcd's storage format has changed across majors before. Our config uses standard env vars (`ETCD_AUTO_COMPACTION_MODE`, etc.) that have been stable since 3.4.

## wyoming-onnx-asr (Parakeet)

Patch + minor are typically safe. The container exposes `/data` for the model cache; on a version bump the existing cached model is reused unless the model file path changed in the new version (rare). Watch for the entrypoint command-line shape changing — our `--quantization int8 --model-en nemo-parakeet-tdt-0.6b-v2` invocation is stable as of v0.5.0 but check the upstream Dockerfile.

## Garage (via `iknox/garage-env`)

Bumps to upstream `dxflrs/garage` happen in the `unraid-images` repo, not here. Our wrapper image's `Dockerfile` pins the upstream version with `FROM dxflrs/garage:vX.Y.Z`; Renovate watches that. When a new `garage-env` image publishes to GHCR, the Unraid container picks up the new `:main` tag automatically on the next "Force Update" or restart.

Things to watch in Garage upgrades:

- **Breaking changes to `garage.toml` schema** — our `garage.toml.tmpl` may need updates.
- **Cluster layout v2 → v3** — our auto-bootstrap assumes v2 semantics.
- **CLI flag changes** — our wrapper at `/usr/local/bin/garage` injects `--rpc-secret-file`; if that flag is renamed, we update the wrapper.
