#!/bin/bash
# qwen38-flash-next-rocm runtime config. Edit values here, then restart the container.
# Nothing here becomes a container/host env var; GGML_CUDA_DISABLE_GRAPHS applies to llama-server only.

export GGML_CUDA_DISABLE_GRAPHS=1   # HIP graph-capture crash workaround on gfx1151 (drluoto-verified)

MODEL=/models/Qwen3.8-Flash-Next-UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
MTP=/models/mtp-Qwen3.8-Flash-Next-Q8_0.gguf          # empty string disables speculation (17-20 tok/s)
MMPROJ=/models/Qwen3.8-Flash-Next-UD-IQ4_XS/mmproj-F16.gguf   # empty string disables vision
CTX=262144
NP=1                                                   # raise to 3 for agent session affinity
EXTRA_ARGS=

set -- -m "$MODEL" -fa 1 --no-mmap -ctk f16 -ctv f16 -c "$CTX" -np "$NP" \
       --ctx-checkpoints 8 --jinja --host 0.0.0.0 --port 6631 -ngl 999
[ -n "$MTP" ] && set -- "$@" -md "$MTP" --spec-type draft-mtp,ngram-mod \
       --spec-draft-n-max 3 --spec-ngram-mod-n-max 64 --spec-ngram-mod-n-match 24
[ -n "$MMPROJ" ] && set -- "$@" --mmproj "$MMPROJ"
exec llama-server "$@" $EXTRA_ARGS
