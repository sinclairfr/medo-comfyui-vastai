# ComfyUI + Medo Services on Vast.ai

Production-ready startup layer for `vastai/comfy` instances on Vast.ai.

## Recommended image

Use this repo's Dockerfile base:

- `vastai/comfy:v0.19.3-cuda-12.9-py312`

This setup keeps the native AI-Dock/Vast portal untouched and adds Medo services through Supervisor.

## Vast.ai On-start Script

In your Vast template **On-start Script** field:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/main/on_start.sh)
```

`entrypoint.sh` is required in SSH/Jupyter launch modes so the native AI-Dock stack (portal + default services) starts first.

## Environment variables

| Variable | Default | Description |
|---|---:|---|
| `RUN_AI_TOOLKIT` | `false` | Start ai-toolkit server/worker when `true`. |
| `S3_OFFLOADER_PORT` | `5055` | Internal port for `comfyui_S3_offloader`. |
| `FILEBROWSER_PORT` | `8081` | Internal port for FileBrowser. |
| `AI_TOOLKIT_PORT` | `8675` | Internal port for ai-toolkit web service. |
| `WORKSPACE` | `/workspace` | Persistent workspace root. |

## Ports to expose in Vast

Expose only the ports you need from the container:

- `8188` (ComfyUI)
- `5055` (S3 offloader)
- `8081` (FileBrowser)
- `8675` (ai-toolkit, optional)
- `8888` / `8080` (Jupyter, depending on base image behavior)

> Do not map or replace the native AI-Dock portal on port `1111`.

## What `on_start.sh` does

- Creates persistent folders under `/workspace`:
  - `/workspace/logs`
  - `/workspace/services`
- Clones/updates `comfyui_S3_offloader` into `/workspace/comfyui_S3_offloader`.
- Clones/updates `ai-toolkit` only when `RUN_AI_TOOLKIT=true`.
- Initializes FileBrowser DB under `/workspace/services/filebrowser.db` (idempotent).
- Renders Supervisor program configs and starts/updates services with `supervisorctl`.
- Prints internal service summary.
- If `/run/http_ports` exists, appends Medo services so they can appear in the native portal links list.

## Troubleshooting

```bash
supervisorctl status
tail -f /workspace/logs/*.log
bash scripts/discover_ai_dock_portal.sh
```

## Safety guarantees

- `set -Eeuo pipefail`
- lock file via `flock` for concurrent-run protection
- idempotent git sync and config rendering
- optional ai-toolkit failures do not block core startup
- never modifies `/start.sh`, `entrypoint.sh`, or behavior on port `1111`
