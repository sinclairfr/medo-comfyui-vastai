# ComfyUI + Medo Services on Vast.ai

Production-ready startup layer for `vastai/comfy` instances on Vast.ai.

## Recommended image

Use this repo's Dockerfile base:

- `vastai/comfy:v0.19.3-cuda-12.9-py312`

This setup keeps the native AI-Dock/Vast portal untouched and adds Medo services through Supervisor.

## Vast.ai startup configuration

### 1) Startup command (important)

Use only:

```bash
bash -lc 'entrypoint.sh'
```

Reason: [`entrypoint.sh`](./entrypoint.sh) uses `exec`, so chaining with `&&` (or `;`) after it is not reliable on `vastai/comfy` boot flow.

### 2) BOOT_SCRIPT environment variable (required)

Set `BOOT_SCRIPT` in your Vast template to:

```bash
https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/main/boot_vast.sh
```

[`boot_vast.sh`](./boot_vast.sh) runs the default Vast boot process and then executes [`on_start.sh`](./on_start.sh) safely.

Optional env overrides:

- `MEDO_ON_START_URL` (default points to this repo's `on_start.sh`)
- `ON_START_WAIT_SUPERVISORD_SECONDS` (default `120`)

### 3) On-start script field

If you prefer using Vast's **On-start Script** field directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/main/on_start.sh)
```

## Environment variables

| Variable | Default | Description |
|---|---:|---|
| `RUN_AI_TOOLKIT` | `false` | Start ai-toolkit server/worker when `true`. |
| `S3_OFFLOADER_PORT` | `5055` | Internal port for `comfyui_S3_offloader`. |
| `FILEBROWSER_PORT` | `8081` | Internal port for FileBrowser. |
| `AI_TOOLKIT_PORT` | `8675` | Internal port for ai-toolkit web service. |
| `WORKSPACE` | `/workspace` | Persistent workspace root. |


## S3 Offloader environment variables (Vast template)

`on_start.sh` accepts both `S3O_*` names and fallback non-prefixed names.

| Preferred (`S3O_*`) | Fallback | Notes |
|---|---|---|
| `S3O_MODELS_ROOT` | `MODELS_ROOT` | ComfyUI models directory path. |
| `S3O_S3_BUCKET` | `S3_BUCKET` | S3 bucket name. |
| `S3O_S3_PREFIX` | `S3_PREFIX` | S3 prefix/path inside bucket (default: `models-offload/`). |
| `S3O_AWS_PROFILE` | `AWS_PROFILE` | AWS profile name (optional). |
| `S3O_AWS_ACCESS_KEY_ID` | `AWS_ACCESS_KEY_ID` | AWS access key (optional if profile/role used). |
| `S3O_AWS_SECRET_ACCESS_KEY` | `AWS_SECRET_ACCESS_KEY` | AWS secret key (optional if profile/role used). |
| `S3O_AWS_SESSION_TOKEN` | `AWS_SESSION_TOKEN` | AWS session token (optional). |
| `S3O_INCLUDE_PERSONAL_STUFF` | `INCLUDE_PERSONAL_STUFF` | `true/false`, include personal paths backup. |

Priority rule: `S3O_*` overrides fallback variables when both are set.

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
