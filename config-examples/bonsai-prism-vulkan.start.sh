#!/bin/bash
# Bonsai 2.5 27B (PrismML llama.cpp Vulkan) runtime config.
# Edit values here, then restart the container.
#
# Default: PTQ1_0-mtp (smallest Bonsai 2.5 27B, with built-in MTP draft head).
# First boot with an empty models share: the GGUF is downloaded from Hugging
# Face if AUTO_DOWNLOAD=1. Set AUTO_DOWNLOAD=0 to manage weights yourself.

set -euo pipefail

MODEL_DIR="${MODEL_DIR:-/models/bonsai-2.5-27b}"
MODEL="${MODEL:-$MODEL_DIR/Ternary-Bonsai-2.5-27B-PTQ1_0-mtp.gguf}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
CTX="${CTX:-8192}"                # keep small for unified-memory footprint/concurrency
PARALLEL="${PARALLEL:-1}"         # -np 1 avoids extra parallel-slot memory
N_GPU_LAYERS="${N_GPU_LAYERS:-99}"
FLASH_ATTN="${FLASH_ATTN:-on}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q4_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q4_0}"
SPEC_TYPE="${SPEC_TYPE:-draft-mtp}"       # embedded MTP head; set empty to disable
SPEC_DRAFT_N_MIN="${SPEC_DRAFT_N_MIN:-0}"
SPEC_DRAFT_N_MAX="${SPEC_DRAFT_N_MAX:-3}" # Bonsai preset
SPEC_DRAFT_P_MIN="${SPEC_DRAFT_P_MIN:-0.1}"
SERVED_NAME="${SERVED_NAME:-bonsai-2.5-27b}"
EXTRA_ARGS="${EXTRA_ARGS:-}"              # e.g. --reasoning-budget 0 if supported

AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-1}"
HF_REPO="${HF_REPO:-prism-ml/Ternary-Bonsai-2.5-27B-GGUF}"
HF_FILE="${HF_FILE:-Ternary-Bonsai-2.5-27B-PTQ1_0-mtp.gguf}"

if [ "$AUTO_DOWNLOAD" = "1" ] && [ ! -f "$MODEL" ]; then
  mkdir -p "$MODEL_DIR"
  url="https://huggingface.co/${HF_REPO}/resolve/main/${HF_FILE}?download=true"
  echo "[models] fetching ${HF_FILE} from ${HF_REPO}"
  if command -v aria2c >/dev/null 2>&1; then
    ( cd "$MODEL_DIR" && aria2c \
        -x8 -s8 -j1 -c \
        --file-allocation=none \
        --auto-file-renaming=false --allow-overwrite=true \
        --max-tries=10 --retry-wait=5 \
        --console-log-level=warn --summary-interval=30 \
        -o "$HF_FILE" "$url" )
  else
    curl -fL --retry 5 --retry-delay 5 -C - -o "$MODEL" "$url"
  fi
fi

[ -f "$MODEL" ] || {
  echo "missing model: $MODEL (set AUTO_DOWNLOAD=1 to fetch, or place the GGUF there)" >&2
  exit 1
}

SPEC_ARGS=()
if [ -n "$SPEC_TYPE" ]; then
  SPEC_ARGS+=(--spec-type "$SPEC_TYPE" --spec-draft-n-min "$SPEC_DRAFT_N_MIN" --spec-draft-n-max "$SPEC_DRAFT_N_MAX" --spec-draft-p-min "$SPEC_DRAFT_P_MIN")
fi

# PrismML llama-server (OpenAI-compatible). Techo firmware can point at /v1.
# --reasoning-budget is not present in all llama-server builds; pass via EXTRA_ARGS if supported.
exec /app/llama-server \
  --host "$HOST" \
  --port "$PORT" \
  -m "$MODEL" \
  --alias "$SERVED_NAME" \
  -ngl "$N_GPU_LAYERS" \
  -fa "$FLASH_ATTN" \
  -c "$CTX" \
  -np "$PARALLEL" \
  -ctk "$CACHE_TYPE_K" \
  -ctv "$CACHE_TYPE_V" \
  --jinja \
  --min-p 0 \
  --temp 0.7 \
  --top-p 0.8 \
  --top-k 20 \
  --presence-penalty 1.5 \
  --repeat-penalty 1.0 \
  "${SPEC_ARGS[@]}" \
  $EXTRA_ARGS
