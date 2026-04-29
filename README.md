# ComfyUI + Medo Services on Vast.ai

> **[Create an Instance](https://cloud.vast.ai/?ref_id=62897&creator_id=62897&name=ComfyUI)**

## What is this template?

This setup runs a **complete AI image/video generation environment** based on `vastai/comfy`, with ComfyUI and native AI-Dock portal services intact, plus optional Medo services managed by Supervisor.

Core services from base image remain untouched (portal, ComfyUI, API wrapper, Jupyter, Syncthing).

## Medo additions in this repo

- `comfyui_S3_offloader` (default on internal port `5055`)
- `FileBrowser` (default on internal port `8081`)
- `ai-toolkit` server + worker (optional, enabled with `RUN_AI_TOOLKIT=true`, default `8675`)

All Medo runtime state/logs are persisted under `/workspace`.

## Quick start (Vast On-start Script)

Use this in your Vast template **On-start Script**:

```bash
entrypoint.sh
bash <(curl -fsSL https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/main/on_start.sh)
```

`entrypoint.sh` must run first so native AI-Dock services initialize normally.

You can run this directly on stock `vastai/comfy` images (without building this repo Dockerfile).  
If `/opt/medo/supervisor-templates` is missing, `on_start.sh` now generates fallback supervisor templates automatically.

## Why `on_start.sh` may be “not found” in SSH

`on_start.sh` is part of this GitHub repository, not a file preinstalled at `/` or `/workspace` in a fresh `vastai/comfy` container.
After the first successful on-start run, this repo is mirrored to `/workspace/medo-comfyui-vastai` for debugging/re-runs.

So this will fail unless you first clone the repo:

```bash
bash -n on_start.sh
```

Use one of these instead:

```bash
# Validate directly from GitHub
curl -fsSL https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/main/on_start.sh | bash -n

# Or clone repo locally, then validate
git clone https://github.com/sinclairfr/medo-comfyui-vastai.git /workspace/medo-comfyui-vastai
cd /workspace/medo-comfyui-vastai
bash -n on_start.sh scripts/discover_ai_dock_portal.sh
```

## Environment variables

| Variable | Default | Description |
|---|---:|---|
| `WORKSPACE` | `/workspace` | Persistent workspace root |
| `RUN_AI_TOOLKIT` | `false` | Start ai-toolkit only when `true` |
| `S3_OFFLOADER_PORT` | `5055` | Internal port for S3 offloader |
| `FILEBROWSER_PORT` | `8081` | Internal port for FileBrowser |
| `AI_TOOLKIT_PORT` | `8675` | Internal port for ai-toolkit web service |

## Port reference

| Service | Internal Port | Notes |
|---|---:|---|
| Instance Portal | `1111` | Native portal entrypoint (do not replace) |
| ComfyUI | `8188` | Native ComfyUI frontend |
| Jupyter | `8080`/`8888` | Depends on launch mode/image defaults |
| S3 Offloader | `5055` | Added by this repo |
| FileBrowser | `8081` | Added by this repo |
| AI Toolkit | `8675` | Optional, only when enabled |

## Troubleshooting

```bash
supervisorctl status
supervisorctl tail -100 medo-s3-offloader
supervisorctl tail -100 medo-filebrowser
supervisorctl tail -100 medo-ai-toolkit-server
supervisorctl tail -100 medo-ai-toolkit-worker

tail -f /workspace/logs/*.log
bash scripts/discover_ai_dock_portal.sh
cat /etc/portal.yaml
cat /run/http_ports
```

### If portal shows Cloudflare tunnel errors (`429 Too Many Requests`)

This is a **Cloudflare Quick Tunnel rate-limit issue**, not a Medo service startup failure.  
Your services may still be running locally even if a public tunnel URL is not issued.

Validate locally inside the instance:

```bash
supervisorctl status | egrep 'medo|comfyui|api-wrapper|instance_portal'
ss -lntp | egrep ':5055|:8081|:8675|:8188|:1111|:8288'
curl -fsS http://127.0.0.1:5055/ || true
curl -IfsS http://127.0.0.1:8081/ || true
```

If Medo services are missing from `supervisorctl status`, your on-start script likely was not executed in this instance.

## Safety guarantees

- `set -Eeuo pipefail`
- lock protection with `flock`
- idempotent git sync + supervisor config rendering
- optional service failures do not block core startup
- no custom static portal, no hardcoded public IP, no port-`1111` takeover

## Notes from upstream ComfyUI template

- ComfyUI supports text-to-image, image-to-image, inpainting, ControlNet, LoRA, upscaling, and video workflows.
- Native management stack uses Supervisor and the Instance Portal.
- You can use the Vast “Open” button for automatic auth.
- For model provisioning on first boot, use `PROVISIONING_SCRIPT` and related template env vars.

For full upstream details, see:
- https://github.com/vast-ai/base-image/tree/main/derivatives/pytorch/derivatives/comfyui
- https://docs.vast.ai/instance-portal
- https://docs.vast.ai/templates
