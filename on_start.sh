#!/bin/bash
# on_start.sh — medo custom tools loader
#
# Called from the Vast.ai "On-start Script" field AFTER entrypoint.sh:
#   entrypoint.sh
#   /opt/medo/on_start.sh
#
# What it adds on top of ai-dock/comfyui:
#   • extra ComfyUI custom node Python deps
#   • comfyui_S3_offloader  (started as daemon on every boot)
#   • ai-toolkit + Next.js UI (optional — set RUN_AI_TOOLKIT=true)
#
# All heavy work is cached in /workspace so subsequent boots are fast.
# This script never touches system Python or base-image files.

# No set -e: we handle errors individually so a single failure doesn't
# kill the whole script and cause a supervisor restart loop.

# ── Guard: prevent concurrent or repeated runs ───────────────────────────────
LOCK="/tmp/medo-onstart.lock"
if [[ -f "${LOCK}" ]]; then
    echo "[medo] already running (PID $(cat "${LOCK}")), skipping"
    exit 0
fi
echo $$ > "${LOCK}"
trap 'rm -f "${LOCK}"' EXIT

# ── /workspace must exist before any log ─────────────────────────────────────
mkdir -p /workspace
LOG=/workspace/medo-onstart.log
log() { echo "[medo] $*" | tee -a "${LOG}" 2>/dev/null || echo "[medo] $*"; }

log "── on_start.sh begin (PID $$) ─────────────────────────────────"

# ── Python interpreter ───────────────────────────────────────────────────────
# ai-dock/comfyui sets COMFYUI_VENV; fall back to system python3 if missing.
PY="${COMFYUI_VENV:+${COMFYUI_VENV}/bin/python3}"
[[ -z "${PY}" || ! -x "${PY}" ]] && PY="$(command -v python3 2>/dev/null || true)"
if [[ -z "${PY}" ]]; then
    log "ERROR: python3 not found — aborting"
    exit 1
fi
log "Python: ${PY}"

# ── Extra ComfyUI custom node deps ──────────────────────────────────────────
# pip skips packages already satisfied — idempotent on every boot.
log "Installing extra ComfyUI deps (skipped if already present)..."
"${PY}" -m pip install -q --no-cache-dir \
    flask boto3 python-dotenv \
    gguf \
    scikit-image \
    dill \
    piexif \
    imageio-ffmpeg \
    ultralytics \
    segment-anything \
    albumentations \
    || log "WARN: some deps failed to install (non-fatal)"

# ── S3 offloader ─────────────────────────────────────────────────────────────
S3_DIR="/workspace/comfyui_S3_offloader"
S3_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"

if [[ ! -d "${S3_DIR}" ]]; then
    log "Cloning S3 offloader..."
    git clone -q "${S3_REPO}" "${S3_DIR}" >> "${LOG}" 2>&1 \
        || log "WARN: S3 offloader clone failed (non-fatal)"
fi

if [[ -f "${S3_DIR}/app.py" ]]; then
    cd "${S3_DIR}"
    nohup "${PY}" app.py >> /workspace/s3_offloader.log 2>&1 &
    log "S3 offloader started (PID $!)"
fi

# ── ai-toolkit (optional) ────────────────────────────────────────────────────
case "${RUN_AI_TOOLKIT:-false}" in
    true|1|yes|TRUE|YES) ;;
    *)
        log "ai-toolkit disabled (set RUN_AI_TOOLKIT=true to enable)"
        log "── on_start.sh done ─"
        exit 0
        ;;
esac

log "Setting up ai-toolkit..."

# Node.js 20 — install once
if ! node --version 2>/dev/null | grep -q '^v20'; then
    log "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >> "${LOG}" 2>&1 || true
    apt-get install -y -q nodejs >> "${LOG}" 2>&1 || true
fi

# Store ai-toolkit code + build on workspace volume (persists across instances)
ATK_DIR="/workspace/ai-toolkit"
ATK_DATA="/workspace/ai-toolkit-data"
ATK_DB="/workspace/ai-toolkit.db"

if [[ ! -d "${ATK_DIR}" ]]; then
    log "Cloning ai-toolkit (first time only, ~1-2 min)..."
    git clone --depth=1 -q https://github.com/ostris/ai-toolkit.git "${ATK_DIR}" >> "${LOG}" 2>&1 \
        || { log "ERROR: ai-toolkit clone failed"; exit 0; }
    cd "${ATK_DIR}" && git submodule update --init --recursive -q >> "${LOG}" 2>&1 || true
fi

log "Installing ai-toolkit Python deps..."
"${PY}" -m pip install -q --no-cache-dir \
    -r "${ATK_DIR}/requirements.txt" \
    accelerate transformers diffusers huggingface_hub gradio \
    >> "${LOG}" 2>&1 || log "WARN: some ai-toolkit deps failed (non-fatal)"

if [[ ! -d "${ATK_DIR}/ui/.next" ]]; then
    log "Building ai-toolkit UI (first time only, ~5 min)..."
    cd "${ATK_DIR}/ui"
    npm install    >> "${LOG}" 2>&1 || true
    npx prisma generate >> "${LOG}" 2>&1 || true
    npm run build  >> "${LOG}" 2>&1 || true
    npm cache clean --force >> "${LOG}" 2>&1 || true
fi

# Persistent workspace dirs + symlinks
mkdir -p "${ATK_DATA}"/{config,datasets,output,jobs}
for d in config datasets output jobs; do
    [[ ! -e "${ATK_DIR}/${d}" ]] && ln -sfn "${ATK_DATA}/${d}" "${ATK_DIR}/${d}" 2>/dev/null || true
done

export DATABASE_URL="file:${ATK_DB}"
if [[ ! -f "${ATK_DB}" ]]; then
    cd "${ATK_DIR}/ui"
    DATABASE_URL="file:${ATK_DB}" npx prisma db push --skip-generate >> "${LOG}" 2>&1 || true
fi

cd "${ATK_DIR}/ui"
nohup node dist/cron/worker.js               >> /workspace/ai-toolkit-worker.log 2>&1 &
nohup node_modules/.bin/next start --port 8675 >> /workspace/ai-toolkit-server.log 2>&1 &
log "ai-toolkit started on :8675"

log "── on_start.sh done ─"
