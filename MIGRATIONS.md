# Migration notes

Things to check when bumping pinned image versions, especially when reviewing a Renovate PR.

## Milvus (`milvusdb/milvus`)

The Milvus template encodes workarounds for several 2.6.x-specific gotchas. Before merging any Renovate bump:

### Always do

1. **Read the upstream release notes.** https://github.com/milvus-io/milvus/releases — note any breaking changes to env-var naming or default values.
2. **Compare `configs/milvus.yaml` between the old and new tag.** Most of our pinned env vars are workarounds for bad defaults; if upstream has fixed a default, we may be able to drop a `<Config>` from the template.
3. **Check whether stats-config validator was changed.** Our `DATA_COORD_SEGMENT_MIN_SIZE_FROM_IDLE_TO_SEALED=16` workaround exists because validator panicked when default resolved to 0 on large-RAM hosts. If upstream fixed it, we can drop it.
4. **Check `MixCoord` port assignment.** Our `ROOT_COORD_PORT=22125` exists because default sometimes resolved to 19530, colliding with Proxy. If upstream pins a different default, update accordingly.
5. **Check default MQ type.** Our `MQ_TYPE=rocksmq` exists because some 2.6 builds defaulted to kafka in standalone mode and tried `localhost:9092`. If fixed upstream, we can drop the override.

### Test against Castle before merging

```bash
# On Unraid, snapshot current state
docker tag milvusdb/milvus:v2.6.15 milvusdb/milvus:v2.6.15-known-good

# Pull the proposed new version manually
docker pull milvusdb/milvus:vNEW

# Recreate the milvus container with the new tag (Unraid UI: edit → Repository field)
# Wait 60s, watch logs:
docker logs milvus 2>&1 | tail -30
curl -sf http://localhost:9091/healthz && echo HEALTHY
```

If healthz doesn't return OK within 60 seconds, revert: change Repository back to `milvusdb/milvus:v2.6.15-known-good` (the local tag we made), reapply, restart.

### Rollback recipe

```bash
docker stop milvus && docker rm milvus
# Reinstall from CA → Previous Apps with Repository field set to the last-known-good tag.
# memsearch collection metadata in etcd is preserved across this; no re-index needed.
```

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
