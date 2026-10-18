# Making the wizard

These Unraid container templates were written to stand up a backend for [memsearch](https://github.com/zilliztech/memsearch) — a semantic memory store — but they each work fine on their own too. The bigger project is Wizard: a smart home with a memory, and one you can talk to. The local LLM templates serve Wizard's models.

## Templates

| Template           | What it is                                                              |
|--------------------|-------------------------------------------------------------------------|
| `garage`           | S3-compatible object storage. Wrapper image adds env-var config + first-boot auto-setup. |
| `etcd`             | Distributed key-value store. Used by Milvus; works standalone.          |
| `milvus`           | Vector database (Standalone mode). Needs S3 + etcd.                     |
| `qwen38-flash-next-gufo` | Qwen3.8-Flash-Next on Strix Halo via Gufo (ROCm 10.0 toolbox). MTP-7 speculation, 133K context, OpenAI API on :8080. ROCm half of the A/B pair. |
| `deepseek-v4-flash-vulkan` | DeepSeek V4 Flash (0731) on Strix Halo via llama.cpp Vulkan (RADV). IQ2_XXS + dspark draft model, 131K context. Vulkan half of the A/B pair. |
| `searxng`          | Self-hosted metasearch engine. Aggregates Google/Bing/DDG/Brave results without giving your IP. JSON output pre-enabled for use as an MCP search backend. |
| `mcp-searxng`      | MCP bridge exposing SearXNG search and page-read tools to agents. |
| `hermes-agent`     | Nous Research Hermes agent with a web dashboard; optional Telegram and API server. |

## Install

```
cd /boot/config/plugins/community.applications/private
git clone https://github.com/iknox/unraid-templates.git iknox-templates
```

Refresh the Apps page; templates appear under **Private Apps**.

For the full backend deploy walkthrough see [DEPLOY.md](DEPLOY.md). When reviewing automated dependency PRs, see [MIGRATIONS.md](MIGRATIONS.md).
