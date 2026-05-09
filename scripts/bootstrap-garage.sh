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
