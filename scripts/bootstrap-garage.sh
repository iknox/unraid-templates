#!/usr/bin/env bash
# Bootstrap a Garage bucket + access key for Milvus.
# Run AFTER the `garage` container is up and healthy.
# Run ONCE per install; the key only needs to be created a single time.

set -euo pipefail

CONTAINER="${GARAGE_CONTAINER:-garage}"
BUCKET="${GARAGE_BUCKET:-milvus}"
KEY_NAME="${GARAGE_KEY_NAME:-milvus-key}"

echo "==> Waiting for garage to be ready..."
for i in {1..30}; do
    if docker exec "$CONTAINER" /garage status >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Garage v2 requires an explicit cluster layout before bucket ops, even on a single node.
# If no layout is applied yet, stage + apply one now. Idempotent: skips if already done.
if ! docker exec "$CONTAINER" /garage bucket list >/dev/null 2>&1; then
    echo "==> Layout not ready — staging a single-node layout"
    NODE_ID=$(docker exec "$CONTAINER" /garage node id -q | cut -d'@' -f1)
    if [ -z "$NODE_ID" ]; then
        echo "    ERROR: could not read node id"; exit 1
    fi
    docker exec "$CONTAINER" /garage layout assign -z dc1 -c 1G "$NODE_ID"
    docker exec "$CONTAINER" /garage layout apply --version 1
fi

echo "==> Creating bucket: $BUCKET"
docker exec "$CONTAINER" /garage bucket create "$BUCKET" || echo "   (already exists)"

echo "==> Creating access key: $KEY_NAME"
docker exec "$CONTAINER" /garage key create "$KEY_NAME" || echo "   (already exists)"

echo "==> Granting key read+write on bucket"
docker exec "$CONTAINER" /garage bucket allow \
    --read --write --owner \
    "$BUCKET" --key "$KEY_NAME"

echo
echo "==> Key info (paste these into milvus.yaml minio.accessKeyID + secretAccessKey):"
echo
docker exec "$CONTAINER" /garage key info --show-secret "$KEY_NAME"
