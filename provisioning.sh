#!/bin/bash
# provisioning.sh — runs at first boot via PROVISIONING_SCRIPT env var
# Installs ai-toolkit, S3 offloader, and extra ComfyUI deps on top of vastai/comfy.

set -euo pipefail
log() { echo "[provisioning] $*"; }

# ---------------------------------------------------------------------------
# System tools
# ---------------------------------------------------------------------------
log "Installing system tools..."
apt-get update -qq && apt-get install -y --no-install-recommends \
    nano vim lsof iproute2 net-tools iputils-ping procps \
    tree jq unzip zip rsync pv \
    htop tmux screen less \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Node.js 20 (required for ai-toolkit UI)
# ---------------------------------------------------------------------------
if ! command -v node &>/dev/null || [[ "$(node --version)" != v20* ]]; then
    log "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*
fi

# ---------------------------------------------------------------------------
# S3 offloader deps
# ---------------------------------------------------------------------------
S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"
S3_OFFLOADER_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"

log "Installing S3 offloader deps..."
apt-get remove -y --purge python3-blinker 2>/dev/null || true
uv pip install --system --no-cache-dir flask boto3 python-dotenv

if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "Cloning comfyui_S3_offloader..."
    git clone "${S3_OFFLOADER_REPO}" "${S3_OFFLOADER_DIR}"
fi

# ---------------------------------------------------------------------------
# ComfyUI custom node deps
# ---------------------------------------------------------------------------
log "Installing ComfyUI custom node deps..."
uv pip install --system --no-cache-dir \
    gguf scikit-image ultralytics dill piexif \
    segment-anything albumentations imageio-ffmpeg

# ---------------------------------------------------------------------------
# ai-toolkit
# ---------------------------------------------------------------------------
ATK_CODE="/opt/ai-toolkit"
ATK_VENV="/opt/ai-toolkit-venv"

if [[ ! -d "${ATK_CODE}" ]]; then
    log "Cloning ai-toolkit..."
    git clone --depth=1 https://github.com/ostris/ai-toolkit.git "${ATK_CODE}"
    cd "${ATK_CODE}" && git submodule update --init --recursive
fi

if [[ ! -d "${ATK_VENV}" ]]; then
    log "Creating ai-toolkit venv..."
    uv venv "${ATK_VENV}"

    log "Installing torch 2.7.0+cu128 for ai-toolkit..."
    uv pip install --python "${ATK_VENV}/bin/python" --no-cache-dir \
        torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 \
        --index-url https://download.pytorch.org/whl/cu128

    log "Installing ai-toolkit requirements..."
    uv pip install --python "${ATK_VENV}/bin/python" --no-cache-dir \
        -r "${ATK_CODE}/requirements.txt"
    uv pip install --python "${ATK_VENV}/bin/python" --no-cache-dir \
        accelerate transformers diffusers huggingface_hub gradio
fi

# Build the Next.js UI (once)
if [[ ! -d "${ATK_CODE}/ui/.next" ]]; then
    log "Building ai-toolkit Next.js UI..."
    cd "${ATK_CODE}/ui"
    npm install && npx prisma generate && npm run build
fi

log "Provisioning complete."
