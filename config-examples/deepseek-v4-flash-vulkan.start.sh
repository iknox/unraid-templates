#!/bin/bash
# deepseek-v4-flash-vulkan runtime config.
# Edit values here, then restart the container. Nothing here leaks into the
# host environment; it is read only by this container's entrypoint.
#
# First boot with an empty models share: the weights below are fetched from
# Hugging Face at a pinned revision with aria2 (8 connections/file, resumable,
# SHA-256 checked) and fall back to curl if aria2 cannot be installed. Set
# AUTO_DOWNLOAD=0 to manage them yourself.

MODEL_DIR=/models/DeepSeek-V4-Flash-0731-UD-IQ2_XXS
MODEL=$MODEL_DIR/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf
DSPARK=$MODEL_DIR/dspark-DeepSeek-V4-Flash-0731-Q8_0.gguf

CTX=131072
DRAFT_MAX=3          # dspark draft tokens per step
DRAFT_P_MIN=0.3      # skip speculation below this probability
ALIAS=deepseek-v4-flash

AUTO_DOWNLOAD=${AUTO_DOWNLOAD:-1}
HF_REPO=unsloth/DeepSeek-V4-Flash-0731-GGUF
HF_REV=fbbb5b93fb787c21338159b0af3318bb3f4d9768
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
  fetch "UD-IQ2_XXS/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf" "$MODEL" 5257664 c58c9d62eac7b62e9578b52613f425e48313d7212ab8d1d76caed8ea8de26595 || exit 1
  fetch "UD-IQ2_XXS/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00002-of-00003.gguf" "$MODEL_DIR/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00002-of-00003.gguf" 49890588800 65a113df6d4469f16db6882b6919e153c464c3c78c833f5e1b41a33803cdbd52 || exit 1
  fetch "UD-IQ2_XXS/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00003-of-00003.gguf" "$MODEL_DIR/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00003-of-00003.gguf" 40964890464 a69102ddfaf4a84426e11fdb66716654f4260dc3a1de3ade9fd50e006b8691d3 || exit 1
  fetch "dspark-DeepSeek-V4-Flash-0731-Q8_0.gguf" "$DSPARK" 10896057440 2c7ac54b0b64a99df1f139a9f1371a00198265e1d6a614b77597d20a655a4249 || exit 1
fi

[ -f "$MODEL" ] || { echo "missing model: $MODEL (set AUTO_DOWNLOAD=1 to fetch)" >&2; exit 1; }
[ -z "$DSPARK" ] || [ -f "$DSPARK" ] || { echo "missing dspark draft: $DSPARK" >&2; exit 1; }

# Shard 1 only: llama.cpp discovers the remaining shards from the filename.
exec llama-server \
  -m "$MODEL" \
  -md "$DSPARK" \
  --spec-type draft-dspark \
  --spec-draft-n-max "$DRAFT_MAX" \
  --spec-draft-p-min "$DRAFT_P_MIN" \
  -ngl 99 \
  -fa on \
  -ctk q8_0 \
  -ctv q8_0 \
  -lm none \
  -c "$CTX" \
  --jinja \
  --alias "$ALIAS" \
  --host 0.0.0.0 \
  --port 8080
