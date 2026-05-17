# Making the wizard

These Unraid container templates were written to stand up a backend for [memsearch](https://github.com/zilliztech/memsearch) — a semantic memory store — but they each work fine on their own too. The bigger project is Wizard: a smart home with a memory, and one you can talk to. The STT and TTS containers here are Wizard's voice.

## Templates

| Template           | What it is                                                              |
|--------------------|-------------------------------------------------------------------------|
| `garage`           | S3-compatible object storage. Wrapper image adds env-var config + first-boot auto-setup. |
| `etcd`             | Distributed key-value store. Used by Milvus; works standalone.          |
| `milvus`           | Vector database (Standalone mode). Needs S3 + etcd.                     |
| `wyoming-parakeet` | Speech-to-text over the Wyoming protocol. NVIDIA Parakeet-TDT, CPU.     |
| `wyoming-kokoro`   | Text-to-speech over the Wyoming protocol. Kokoro-ONNX, CPU.             |
| `llama-swap`       | Multi-model proxy with llama.cpp baked in. Define many GGUFs in one YAML, hot-swap on demand. Vulkan GPU acceleration; no separate llama.cpp container needed. |
| `claude-code-router` | Anthropic↔OpenAI translating proxy. Lets Claude Code (and any other Anthropic-API client) drive a local OpenAI-compatible model like `llama-swap`. |
| `searxng`          | Self-hosted metasearch engine. Aggregates Google/Bing/DDG/Brave results without giving them your IP. JSON output pre-enabled for use as an MCP search backend. |

## Install

```
cd /boot/config/plugins/community.applications/private
git clone https://github.com/iknox/unraid-templates.git iknox-templates
```

Refresh the Apps page; templates appear under **Private Apps**.

For the full backend deploy walkthrough see [DEPLOY.md](DEPLOY.md). When reviewing automated dependency PRs, see [MIGRATIONS.md](MIGRATIONS.md).
