#!/bin/bash

# Vast boot hook (sourced by /opt/instance-tools/bin/boot_default.sh)
# Keep this script non-fatal: never exit non-zero, avoid breaking base startup.

log() { echo "[medo-boot] $*"; }

S3_OFFLOADER_DIR="/workspace/comfyui_S3_offloader"
S3_OFFLOADER_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"

ATK_CODE="/opt/ai-toolkit"
ATK_VENV="/venv/main"
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
  # Run entirely in background so a slow git clone never delays the boot
  # sequence (which would push back portal.yaml generation and all Vast.ai
  # services that wait for it).
  (
    if [[ ! -d "${S3_OFFLOADER_DIR}" ]]; then
      log "S3 offloader: cloning"
      git clone "${S3_OFFLOADER_REPO}" "${S3_OFFLOADER_DIR}" >/dev/null 2>&1 || {
        log "S3 offloader: clone failed (non-fatal)"
        exit 0
      }
    fi

    [[ ! -f "${S3_OFFLOADER_DIR}/app.py" ]] && {
      log "S3 offloader: app.py missing (skip)"
      exit 0
    }

    cd "${S3_OFFLOADER_DIR}"
    nohup /venv/main/bin/python3 app.py >> /workspace/s3_offloader.log 2>&1 &
    log "S3 offloader: started (PID $!)"
  ) &
}

# Vast.ai portal.yaml / Caddy failures leave ComfyUI never started.
# This watchdog runs in the background: after 60 s it checks whether port 8188
# is listening and, if not, starts ComfyUI directly — bypassing the portal.yaml
# mechanism entirely.  It is a no-op when the supervisor already started it.
start_comfyui_watchdog() {
  (
    sleep 60

    if ss -tlnp 2>/dev/null | grep -q ':8188 '; then
      log "ComfyUI watchdog: already listening on :8188 — OK"
      exit 0
    fi

    # Locate ComfyUI installation (base image puts it in /opt/ComfyUI)
    local comfyui_dir=""
    for d in /opt/ComfyUI /workspace/ComfyUI; do
      [[ -f "${d}/main.py" ]] && { comfyui_dir="${d}"; break; }
    done
    if [[ -z "${comfyui_dir}" ]]; then
      log "ComfyUI watchdog: main.py not found in known paths — giving up"
      exit 0
    fi

    # Use the venv that Vast.ai activates at startup, fall back to system python3
    local python="/venv/main/bin/python3"
    [[ ! -x "${python}" ]] && python="$(command -v python3 2>/dev/null || echo "")"
    if [[ -z "${python}" ]]; then
      log "ComfyUI watchdog: python3 not found — giving up"
      exit 0
    fi

    log "ComfyUI watchdog: portal.yaml mechanism failed; starting ComfyUI directly from ${comfyui_dir}"
    mkdir -p /workspace/logs
    cd "${comfyui_dir}"
    nohup "${python}" main.py --listen 0.0.0.0 --port 8188 \
      >> /workspace/logs/comfyui.log 2>&1 &
    log "ComfyUI watchdog: started (PID $!) — logs at /workspace/logs/comfyui.log"
  ) &
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
start_comfyui_watchdog || true
start_s3_offloader || true
start_ai_toolkit || true

