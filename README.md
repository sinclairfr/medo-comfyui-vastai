# medo-comfyui-vastai

Custom Docker image for Vast.ai based on `vastai/comfy`, with:

- extra system tools for SSH/debug
- S3 offloader runtime support
- `ai-toolkit` preinstalled and UI prebuilt
- wrapper entrypoint that starts optional services before handing off to Vast.ai supervisor

## Files

- [`Dockerfile`](Dockerfile): image build definition
- [`start_wrapper.sh`](start_wrapper.sh): container entrypoint wrapper
- [`provisioning.sh`](provisioning.sh): optional first-boot provisioning script
- [`.github/workflows/build.yml`](.github/workflows/build.yml): CI build workflow

## What the image does

From [`Dockerfile`](Dockerfile):

1. Extends `vastai/comfy:v0.19.3-cuda-12.9-py312`
2. Installs useful CLI tools (`vim`, `tmux`, `jq`, `tree`, etc.)
3. Installs Node.js 20 for `ai-toolkit` UI
4. Installs S3 offloader Python deps (`flask`, `boto3`, `python-dotenv`)
5. Installs common ComfyUI custom-node deps (`ultralytics`, `scikit-image`, etc.)
6. Clones `https://github.com/ostris/ai-toolkit`
7. Creates isolated venv at `/opt/ai-toolkit-venv`
8. Installs Torch 2.7.0 + cu128 for `ai-toolkit`
9. Builds `ai-toolkit` Next.js UI
10. Uses [`/start_wrapper.sh`](start_wrapper.sh) as container entrypoint

From [`start_wrapper.sh`](start_wrapper.sh):

- Optional SSH private key setup via `SSH_PRIVATE_KEY` (base64)
- Auto-clone + start of `comfyui_S3_offloader` in `/workspace/comfyui_S3_offloader`
- Optional `ai-toolkit` startup controlled by `RUN_AI_TOOLKIT`
- Final handoff to `/opt/instance-tools/bin/entrypoint.sh`

## Build

### Local build (recommended on Apple Silicon + x86 target)

```bash
docker build --platform linux/amd64 --progress=plain -t medo-comfyui-vastai:test .
```

### Notes

- If you hit Docker Hub pull limits, run `docker login` first.
- Base image is pulled from Docker Hub: `vastai/comfy:v0.19.3-cuda-12.9-py312`.

## Run

Minimal run:

```bash
docker run --rm -it \
  -p 8188:8188 \
  -v $(pwd)/workspace:/workspace \
  medo-comfyui-vastai:test
```

Run with optional `ai-toolkit` and SSH key:

```bash
docker run --rm -it \
  -p 8188:8188 \
  -p 8675:8675 \
  -e RUN_AI_TOOLKIT=true \
  -e SSH_PRIVATE_KEY="<base64_ed25519_private_key>" \
  -v $(pwd)/workspace:/workspace \
  medo-comfyui-vastai:test
```

## Environment variables

- `RUN_AI_TOOLKIT` (default: `false`)
  - `true|1|yes` starts `ai-toolkit` UI on port `8675`
- `SSH_PRIVATE_KEY` (optional)
  - base64-encoded private key written to `~/.ssh/id_ed25519`

## Runtime paths and logs

- S3 offloader repo: `/workspace/comfyui_S3_offloader`
- S3 offloader log: `/workspace/s3_offloader.log`
- ai-toolkit workspace: `/workspace/ai-toolkit`
- ai-toolkit server log: `/workspace/ai-toolkit/server.log`
- ai-toolkit worker log: `/workspace/ai-toolkit/worker.log`

## Provisioning script

[`provisioning.sh`](provisioning.sh) can be used as a first-boot provisioning script (for platforms that support passing a provisioning hook). It mirrors key installs and clones `comfyui_S3_offloader` if missing.

## Known caveats

- Installing Python packages into system Python requires `--break-system-packages` in this base image due to Debian/Ubuntu external management policy.
- Building Torch/CUDA layers is heavy and can take several minutes.
