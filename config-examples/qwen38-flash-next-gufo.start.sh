#!/bin/bash
# qwen38-flash-next-gufo runtime config.
# Edit values here, then restart the container. Nothing here leaks into the
# host environment; it is read only by this container's entrypoint.
#
# First boot with an empty models share: the weights below are fetched from
# Hugging Face at a pinned revision with aria2 (8 connections/file, resumable,
# SHA-256 checked) and fall back to curl if aria2 cannot be installed. Set
# AUTO_DOWNLOAD=0 to manage them yourself.

MODEL_DIR=/models/Qwen3.8-Flash-Next-UD-Q4_K_XL
MODEL=$MODEL_DIR/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
MTP=$MODEL_DIR/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf
MMPROJ=$MODEL_DIR/mmproj-BF16.gguf   # auto-discovered beside the model

CTX=133760           # one session's full context; raise only if GTT allows
MAX_TOKENS=8192
SESSIONS=1           # >1 splits the context budget across warm slots
DRAFT_TOKENS=7       # MTP-7: the draft head was tuned for a 7-token window
SERVED_NAME=Qwen3.8-Flash-Next-UD-Q4_K_XL

AUTO_DOWNLOAD=${AUTO_DOWNLOAD:-1}
HF_REPO=unsloth/Qwen3.8-Flash-Next-GGUF
HF_REV=38bb39ee97821de2c9009abb7e93950eec396e66
FETCHER_READY=0

ensure_fetcher() {
  command -v aria2c >/dev/null 2>&1 && return 0
  echo "[models] installing aria2 (multi-connection downloads)"
  dnf install -y --setopt=install_weak_deps=False aria2 >/dev/null 2>&1 || true
}

fetch() { # remote-path local-path expected-bytes sha256
  local remote=$1 dest=$2 want=$3 sum=$4
  if [ -f "$dest" ] && [ "$(stat -c %s "$dest" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  local url="https://huggingface.co/$HF_REPO/resolve/$HF_REV/$remote?download=true"
  if [ "$FETCHER_READY" = 0 ]; then ensure_fetcher; FETCHER_READY=1; fi
  echo "[models] fetching $(basename "$dest") ($((want / 1000000000)) GB)"
  if command -v aria2c >/dev/null 2>&1; then
    ( cd "$(dirname "$dest")" && aria2c \
        -x8 -s8 -j1 -c \
        --check-integrity=true \
        --checksum="sha-256=$sum" \
        --file-allocation=none \
        --auto-file-renaming=false --allow-overwrite=true \
        --max-tries=10 --retry-wait=5 \
        --console-log-level=warn --summary-interval=30 \
        -o "$(basename "$dest")" "$url" ) \
      || { echo "[models] aria2 failed: $remote" >&2; return 1; }
  else
    echo "[models] aria2 unavailable, using curl (single connection)" >&2
    curl -fLSs --retry 5 --retry-delay 5 -C - -o "$dest" "$url" \
      || { echo "[models] download failed: $remote" >&2; return 1; }
  fi
  local got
  got=$(stat -c %s "$dest" 2>/dev/null || echo 0)
  [ "$got" = "$want" ] || { echo "[models] size mismatch: $dest (got $got, want $want)" >&2; return 1; }
}

if [ "$AUTO_DOWNLOAD" = 1 ]; then
  mkdir -p "$MODEL_DIR"
  fetch "UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf" "$MODEL" 10946624 4448186216b3af4cc558bbce2c3213f01608f8f8b2e5267a9767971dd3ec8082 || exit 1
  fetch "UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf" "$MODEL_DIR/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf" 49859583136 3f342f1c1580473f1ee94ddd5b28206e8c07a70fa1a366f59d1d6c922919a6c9 || exit 1
  fetch "UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf" "$MODEL_DIR/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf" 49376141504 56758f40269cad5cd9b0d3d6fbae0f40f6d5be6de49e4ab392dbe83157d9cbd3 || exit 1
  fetch "UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf" "$MODEL_DIR/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf" 12087983520 753bda48b98ba4f1636134a90a967de1b2d3908a236c026e464777342e53510a || exit 1
  fetch "mmproj-BF16.gguf" "$MMPROJ" 907542944 2e788f8c511d8093c7b43cb87b2fd7e14228340318057f8fb20c86df2efe2355 || exit 1
  fetch "MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf" "$MTP" 2786568256 5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6 || exit 1
fi

[ -f "$MODEL" ] || { echo "missing model: $MODEL (set AUTO_DOWNLOAD=1 to fetch)" >&2; exit 1; }
[ -z "$MTP" ] || [ -f "$MTP" ] || { echo "missing MTP head: $MTP" >&2; exit 1; }

# Note: shard 1 only. llama.cpp discovers the other shards from its filename.
# The BF16 mmproj is auto-discovered beside the model; add --mmproj to override.
exec gufo serve llm \
  --host 0.0.0.0 \
  --port 8080 \
  --sessions "$SESSIONS" \
  --log-progress \
  --model "$MODEL" \
  --speculative mtp \
  --mtp-model "$MTP" \
  --draft-tokens "$DRAFT_TOKENS" \
  --context "$CTX" \
  --max-tokens "$MAX_TOKENS" \
  --served-model-name "$SERVED_NAME"
