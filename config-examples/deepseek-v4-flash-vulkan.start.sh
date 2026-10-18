#!/bin/bash
# deepseek-v4-flash-vulkan runtime config.
# Edit values here, then restart the container. Nothing here leaks into the
# host environment; it is read only by this container's entrypoint.

MODEL=/models/DeepSeek-V4-Flash-0731-UD-IQ2_XXS/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf
DSPARK=/models/DeepSeek-V4-Flash-0731-UD-IQ2_XXS/dspark-DeepSeek-V4-Flash-0731-Q8_0.gguf

CTX=131072
DRAFT_MAX=3          # dspark draft tokens per step
DRAFT_P_MIN=0.3      # skip speculation below this probability
ALIAS=deepseek-v4-flash

[ -f "$MODEL" ] || { echo "missing model: $MODEL" >&2; exit 1; }
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
