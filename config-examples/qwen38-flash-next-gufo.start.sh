#!/bin/bash
# qwen38-flash-next-gufo runtime config.
# Edit values here, then restart the container. Nothing here leaks into the
# host environment; it is read only by this container's entrypoint.

MODEL=/models/Qwen3.8-Flash-Next-UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
MTP=/models/Qwen3.8-Flash-Next-UD-Q4_K_XL/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf

CTX=133760           # one session's full context; raise only if GTT allows
MAX_TOKENS=8192
SESSIONS=1           # >1 splits the context budget across warm slots
DRAFT_TOKENS=7       # MTP-7: the draft head was tuned for a 7-token window
SERVED_NAME=Qwen3.8-Flash-Next-UD-Q4_K_XL

[ -f "$MODEL" ] || { echo "missing model: $MODEL" >&2; exit 1; }
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
