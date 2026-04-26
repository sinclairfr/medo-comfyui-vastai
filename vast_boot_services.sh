#!/bin/bash

# Vast boot hook (sourced by /opt/instance-tools/bin/boot_default.sh)
# Keep this script non-fatal: never exit non-zero, avoid breaking base startup.

log() { echo "[medo-boot] $*"; }

S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"
S3_OFFLOADER_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"

ATK_CODE="/opt/ai-toolkit"
ATK_VENV="/opt/ai-toolkit-venv"
ATK_WORKSPACE="/workspace/ai-toolkit"
ATK_DB="${ATK_WORKSPACE}/aitk_db.db"
RUN_AI_TOOLKIT="${RUN_AI_TOOLKIT:-false}"

init_vast_extra_logs() {
  local base="/var/lib/vastai_kaalia/data/instance_extra_logs"
  mkdir -p "${base}" 2>/dev/null || return 0
  chmod 777 "${base}" 2>/dev/null || true

  local raw_id id
  for raw_id in \
    "${CONTAINER_ID:-}" \
    "${VAST_CONTAINER_ID:-}" \
    "${VAST_INSTANCE_ID:-}" \
    "${INSTANCE_ID:-}" \
    "${HOSTNAME:-}"; do
    [[ -z "${raw_id}" ]] && continue
    id="$(echo "${raw_id}" | tr -cd '[:alnum:]_.-')"
    [[ -z "${id}" ]] && continue
    touch "${base}/C.${id}" "${base}/O.${id}" 2>/dev/null || true
  done

  touch "${base}/C.placeholder" "${base}/O.placeholder" 2>/dev/null || true
}

setup_ssh() {
  if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    mkdir -p ~/.ssh
    echo "$SSH_PRIVATE_KEY" | base64 -d > ~/.ssh/id_ed25519 2>/dev/null || true
    chmod 600 ~/.ssh/id_ed25519 2>/dev/null || true
    ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null || true
    if ! grep -q "Host github.com" ~/.ssh/config 2>/dev/null; then
      cat >> ~/.ssh/config << 'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
      chmod 600 ~/.ssh/config 2>/dev/null || true
    fi
    log "SSH configured"
  fi
}

start_s3_offloader() {
  if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
    log "S3 offloader: cloning"
    git clone "${S3_OFFLOADER_REPO}" "${S3_OFFLOADER_DIR}" >/dev/null 2>&1 || {
      log "S3 offloader: clone failed (non-fatal)"
      return 0
    }
  fi

  [[ ! -f "${S3_OFFLOADER_DIR}/app.py" ]] && {
    log "S3 offloader: app.py missing (skip)"
    return 0
  }

  (cd "${S3_OFFLOADER_DIR}" && nohup python3 app.py >> /workspace/s3_offloader.log 2>&1 &) || true
  log "S3 offloader: started"
}

start_ai_toolkit() {
  case "${RUN_AI_TOOLKIT,,}" in
    true|1|yes) ;;
    *) log "ai-toolkit disabled"; return 0 ;;
  esac

  [[ ! -d "${ATK_CODE}" ]] && { log "ai-toolkit code missing"; return 0; }
  [[ ! -d "${ATK_CODE}/ui/.next" ]] && { log "ai-toolkit UI build missing"; return 0; }

  mkdir -p "${ATK_WORKSPACE}" "${ATK_WORKSPACE}/config" "${ATK_WORKSPACE}/datasets" "${ATK_WORKSPACE}/output" "${ATK_WORKSPACE}/jobs"

  local dir
  for dir in config datasets output jobs; do
    if [[ ! -e "${ATK_CODE}/${dir}" ]]; then
      ln -s "${ATK_WORKSPACE}/${dir}" "${ATK_CODE}/${dir}" || true
    elif [[ ! -L "${ATK_CODE}/${dir}" ]]; then
      mv "${ATK_CODE}/${dir}" "${ATK_CODE}/${dir}.bak" || true
      ln -s "${ATK_WORKSPACE}/${dir}" "${ATK_CODE}/${dir}" || true
    fi
  done

  export DATABASE_URL="file:${ATK_DB}"
  export AI_TOOLKIT_PYTHON="${ATK_VENV}/bin/python"

  if [[ ! -f "${ATK_DB}" ]]; then
    (cd "${ATK_CODE}/ui" && DATABASE_URL="file:${ATK_DB}" npx prisma db push --skip-generate >/dev/null 2>&1) || true
  fi

  (cd "${ATK_CODE}/ui" && nohup node dist/cron/worker.js >> "${ATK_WORKSPACE}/worker.log" 2>&1 &) || true
  (cd "${ATK_CODE}/ui" && nohup node_modules/.bin/next start --port 8675 >> "${ATK_WORKSPACE}/server.log" 2>&1 &) || true
  log "ai-toolkit started on :8675"
}

init_vast_extra_logs || true
setup_ssh || true
start_s3_offloader || true
start_ai_toolkit || true

