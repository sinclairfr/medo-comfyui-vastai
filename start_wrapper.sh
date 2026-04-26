#!/bin/bash
# /etc/vast_boot.d/50-medo.sh — runs as part of Vast.ai's boot sequence.
# Starts S3 offloader and optionally ai-toolkit alongside the normal Vast.ai stack.
# Do NOT exec the entrypoint here — Vast.ai's framework handles that.

S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"
S3_OFFLOADER_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"

ATK_CODE="/opt/ai-toolkit"
ATK_VENV="/opt/ai-toolkit-venv"
ATK_WORKSPACE="/workspace/ai-toolkit"
ATK_DB="${ATK_WORKSPACE}/aitk_db.db"
RUN_AI_TOOLKIT="${RUN_AI_TOOLKIT:-false}"

log() { echo "[medo] $*"; }

# ---------------------------------------------------------------------------
# SSH private key — for git access inside the pod (PUBLIC_KEY handled by Vast.ai)
# ---------------------------------------------------------------------------
setup_ssh() {
  if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    mkdir -p ~/.ssh
    echo "$SSH_PRIVATE_KEY" | base64 -d > ~/.ssh/id_ed25519
    chmod 600 ~/.ssh/id_ed25519
    ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
    if ! grep -q "Host github.com" ~/.ssh/config 2>/dev/null; then
      cat >> ~/.ssh/config << 'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
      chmod 600 ~/.ssh/config
    fi
    log "SSH: private key + GitHub host configured"
  fi
}

# ---------------------------------------------------------------------------
# S3 offloader
# ---------------------------------------------------------------------------
start_s3_offloader() {
  if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "S3 offloader: cloning..."
    git clone "${S3_OFFLOADER_REPO}" "${S3_OFFLOADER_DIR}" \
      && log "S3 offloader: cloned OK" \
      || { log "S3 offloader: clone FAILED — skipping"; return; }
  fi

  [[ ! -f "${S3_OFFLOADER_DIR}/app.py" ]] \
    && { log "S3 offloader: app.py not found — skipping"; return; }

  cd "${S3_OFFLOADER_DIR}"
  nohup python3 app.py >> /workspace/s3_offloader.log 2>&1 &
  log "S3 offloader: started (PID $!)"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# ai-toolkit UI (Next.js, port 8675)
# ---------------------------------------------------------------------------
start_ai_toolkit() {
  if [[ ! -d "${ATK_CODE}/ui/.next" ]]; then
    log "ai-toolkit: ui/.next not found — skipping"
    return
  fi

  mkdir -p "${ATK_WORKSPACE}"
  for dir in config datasets output jobs; do
    mkdir -p "${ATK_WORKSPACE}/${dir}"
    if [[ ! -e "${ATK_CODE}/${dir}" ]]; then
      ln -s "${ATK_WORKSPACE}/${dir}" "${ATK_CODE}/${dir}"
    elif [[ ! -L "${ATK_CODE}/${dir}" ]]; then
      mv "${ATK_CODE}/${dir}" "${ATK_CODE}/${dir}.bak"
      ln -s "${ATK_WORKSPACE}/${dir}" "${ATK_CODE}/${dir}"
    fi
  done

  export DATABASE_URL="file:${ATK_DB}"
  export AI_TOOLKIT_PYTHON="${ATK_VENV}/bin/python"

  if [[ ! -f "${ATK_DB}" ]]; then
    log "ai-toolkit: initializing Prisma DB..."
    cd "${ATK_CODE}/ui"
    DATABASE_URL="file:${ATK_DB}" npx prisma db push --skip-generate 2>&1 \
      | grep -E "(sync|error|Error)" || true
    cd - >/dev/null
  fi

  cd "${ATK_CODE}/ui"
  nohup node dist/cron/worker.js >> "${ATK_WORKSPACE}/worker.log" 2>&1 &
  log "ai-toolkit: worker started (PID $!)"

  nohup node_modules/.bin/next start --port 8675 >> "${ATK_WORKSPACE}/server.log" 2>&1 &
  log "ai-toolkit: UI started on port 8675 (PID $!)"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
setup_ssh
start_s3_offloader

case "${RUN_AI_TOOLKIT,,}" in
  true|1|yes) start_ai_toolkit ;;
  *) log "ai-toolkit: disabled (set RUN_AI_TOOLKIT=true to enable)" ;;
esac
