#!/usr/bin/env bash
set -Eeuo pipefail

LOCK_FILE="/tmp/medo-onstart.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "[medo] on_start already running, exiting"
  exit 0
fi

WORKSPACE="${WORKSPACE:-/workspace}"
LOG_DIR="${WORKSPACE}/logs"
SERVICES_DIR="${WORKSPACE}/services"
SUPERVISOR_DST_DIR="/etc/supervisor/conf.d"
SUPERVISOR_TPL_DIR="/opt/medo/supervisor-templates"
FALLBACK_TPL_DIR="/tmp/medo-supervisor-templates"

S3_OFFLOADER_PORT="${S3_OFFLOADER_PORT:-5055}"
FILEBROWSER_PORT="${FILEBROWSER_PORT:-8081}"
AI_TOOLKIT_PORT="${AI_TOOLKIT_PORT:-8675}"
RUN_AI_TOOLKIT="${RUN_AI_TOOLKIT:-false}"

S3_DIR="${WORKSPACE}/comfyui_S3_offloader"
S3_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"
AI_TOOLKIT_DIR="${WORKSPACE}/ai-toolkit"
AI_TOOLKIT_REPO="https://github.com/ostris/ai-toolkit"
MEDO_REPO_DIR="${WORKSPACE}/medo-comfyui-vastai"
MEDO_REPO_URL="https://github.com/sinclairfr/medo-comfyui-vastai"

mkdir -p "${WORKSPACE}" "${LOG_DIR}" "${SERVICES_DIR}" "${SERVICES_DIR}/filebrowser"

log() { echo "[medo] $*" | tee -a "${LOG_DIR}/on_start.log"; }

register_portal_service() {
  local name="$1" target_url="$2"
  local portal_yaml="/etc/portal.yaml"
  [[ -f "${portal_yaml}" ]] || return 0
  python3 - "$portal_yaml" "$name" "$target_url" >>"${LOG_DIR}/on_start.log" 2>&1 <<'PY' || return 1
import sys
from pathlib import Path
try:
    import yaml
except Exception:
    raise SystemExit(1)

portal_path = Path(sys.argv[1])
name = sys.argv[2]
target = sys.argv[3]
data = {}
if portal_path.exists():
    raw = portal_path.read_text() or ""
    data = yaml.safe_load(raw) or {}

services = data.get("services")
if not isinstance(services, list):
    services = []

exists = False
for item in services:
    if isinstance(item, dict) and item.get("name") == name:
        item["url"] = target
        exists = True
        break
if not exists:
    services.append({"name": name, "url": target})
data["services"] = services
portal_path.write_text(yaml.safe_dump(data, sort_keys=False))
print(f"portal.yaml updated: {name} -> {target}")
PY
}

register_http_port() {
  local port="$1" name="$2"
  local http_ports="/run/http_ports"
  [[ -f "${http_ports}" ]] || return 0
  if ! grep -Eq "(^|[^0-9])${port}([^0-9]|$)" "${http_ports}"; then
    echo "${port} ${name}" >> "${http_ports}"
    log "Registered ${name} on ${port} in /run/http_ports"
  fi
}

git_sync_repo() {
  local repo_url="$1" target_dir="$2"
  if [[ ! -d "${target_dir}/.git" ]]; then
    log "Cloning ${repo_url} -> ${target_dir}"
    git clone --depth 1 "${repo_url}" "${target_dir}" >>"${LOG_DIR}/on_start.log" 2>&1 || return 1
  else
    log "Updating ${target_dir}"
    git -C "${target_dir}" fetch --depth 1 origin >>"${LOG_DIR}/on_start.log" 2>&1 || return 1
    git -C "${target_dir}" reset --hard origin/HEAD >>"${LOG_DIR}/on_start.log" 2>&1 || return 1
  fi
}

render_supervisor_program() {
  local src="$1" dst="$2"
  sed \
    -e "s|__WORKSPACE__|${WORKSPACE}|g" \
    -e "s|__S3_DIR__|${S3_DIR}|g" \
    -e "s|__S3_OFFLOADER_PORT__|${S3_OFFLOADER_PORT}|g" \
    -e "s|__FILEBROWSER_PORT__|${FILEBROWSER_PORT}|g" \
    -e "s|__AI_TOOLKIT_DIR__|${AI_TOOLKIT_DIR}|g" \
    -e "s|__AI_TOOLKIT_PORT__|${AI_TOOLKIT_PORT}|g" \
    -e "s|__AI_TOOLKIT_AUTOSTART__|${AI_TOOLKIT_AUTOSTART}|g" \
    "${src}" > "${dst}"
}

ensure_supervisor_templates() {
  if [[ -f "${SUPERVISOR_TPL_DIR}/medo-s3-offloader.conf" ]]; then
    return 0
  fi
  log "Supervisor templates not found in image; using fallback templates from script"
  mkdir -p "${FALLBACK_TPL_DIR}"
  SUPERVISOR_TPL_DIR="${FALLBACK_TPL_DIR}"

  cat > "${SUPERVISOR_TPL_DIR}/medo-s3-offloader.conf" <<'EOF'
[program:medo-s3-offloader]
directory=__S3_DIR__
command=python3 app.py --port __S3_OFFLOADER_PORT__
autostart=true
autorestart=true
startsecs=3
stdout_logfile=/workspace/logs/medo-s3-offloader.log
stderr_logfile=/workspace/logs/medo-s3-offloader.err.log
user=root
environment=PYTHONUNBUFFERED="1",WORKSPACE="__WORKSPACE__"
EOF

  cat > "${SUPERVISOR_TPL_DIR}/medo-filebrowser.conf" <<'EOF'
[program:medo-filebrowser]
command=filebrowser -r __WORKSPACE__ -d __WORKSPACE__/services/filebrowser.db -p __FILEBROWSER_PORT__
autostart=true
autorestart=true
startsecs=3
stdout_logfile=/workspace/logs/medo-filebrowser.log
stderr_logfile=/workspace/logs/medo-filebrowser.err.log
user=root
environment=FB_NOAUTH="false",WORKSPACE="__WORKSPACE__"
EOF

  cat > "${SUPERVISOR_TPL_DIR}/medo-ai-toolkit-server.conf" <<'EOF'
[program:medo-ai-toolkit-server]
directory=__AI_TOOLKIT_DIR__
command=/bin/bash -lc 'npm install && npm run start -- --port __AI_TOOLKIT_PORT__'
autostart=__AI_TOOLKIT_AUTOSTART__
autorestart=true
startsecs=5
stdout_logfile=/workspace/logs/medo-ai-toolkit-server.log
stderr_logfile=/workspace/logs/medo-ai-toolkit-server.err.log
user=root
environment=PORT="__AI_TOOLKIT_PORT__",WORKSPACE="__WORKSPACE__"
EOF

  cat > "${SUPERVISOR_TPL_DIR}/medo-ai-toolkit-worker.conf" <<'EOF'
[program:medo-ai-toolkit-worker]
directory=__AI_TOOLKIT_DIR__
command=/bin/bash -lc 'python3 worker.py'
autostart=__AI_TOOLKIT_AUTOSTART__
autorestart=true
startsecs=5
stdout_logfile=/workspace/logs/medo-ai-toolkit-worker.log
stderr_logfile=/workspace/logs/medo-ai-toolkit-worker.err.log
user=root
environment=WORKSPACE="__WORKSPACE__"
EOF
}

log "Preparing repositories"
ensure_supervisor_templates
git_sync_repo "${MEDO_REPO_URL}" "${MEDO_REPO_DIR}" || log "WARN: unable to sync medo-comfyui-vastai repo mirror"
git_sync_repo "${S3_REPO}" "${S3_DIR}" || log "WARN: unable to sync comfyui_S3_offloader"

AI_TOOLKIT_AUTOSTART="false"
if [[ "${RUN_AI_TOOLKIT,,}" == "true" ]]; then
  AI_TOOLKIT_AUTOSTART="true"
  git_sync_repo "${AI_TOOLKIT_REPO}" "${AI_TOOLKIT_DIR}" || log "WARN: unable to sync ai-toolkit"
fi

# Initialize filebrowser DB idempotently.
if command -v filebrowser >/dev/null 2>&1; then
  if [[ ! -f "${SERVICES_DIR}/filebrowser.db" ]]; then
    log "Initializing FileBrowser DB"
    filebrowser config init -d "${SERVICES_DIR}/filebrowser.db" >>"${LOG_DIR}/on_start.log" 2>&1 || true
    filebrowser users add admin admin --perm.admin -d "${SERVICES_DIR}/filebrowser.db" >>"${LOG_DIR}/on_start.log" 2>&1 || true
  fi
fi

mkdir -p "${SUPERVISOR_DST_DIR}"
for tpl in medo-s3-offloader.conf medo-filebrowser.conf medo-ai-toolkit-server.conf medo-ai-toolkit-worker.conf; do
  render_supervisor_program "${SUPERVISOR_TPL_DIR}/${tpl}" "${SUPERVISOR_DST_DIR}/${tpl}"
done

if pgrep -x supervisord >/dev/null 2>&1; then
  supervisorctl reread >>"${LOG_DIR}/on_start.log" 2>&1 || true
  supervisorctl update >>"${LOG_DIR}/on_start.log" 2>&1 || true
else
  log "Starting supervisord"
  supervisord -c /etc/supervisor/supervisord.conf >>"${LOG_DIR}/on_start.log" 2>&1 || true
fi

supervisorctl start medo-s3-offloader medo-filebrowser >>"${LOG_DIR}/on_start.log" 2>&1 || true
if [[ "${AI_TOOLKIT_AUTOSTART}" == "true" ]]; then
  supervisorctl start medo-ai-toolkit-server medo-ai-toolkit-worker >>"${LOG_DIR}/on_start.log" 2>&1 || true
fi

# Expose service hints to AI-Dock portal if /run/http_ports is managed by the base image.
register_http_port "${S3_OFFLOADER_PORT}" "Medo S3 Offloader"
register_http_port "${FILEBROWSER_PORT}" "Medo FileBrowser"
if [[ "${AI_TOOLKIT_AUTOSTART}" == "true" ]]; then
  register_http_port "${AI_TOOLKIT_PORT}" "Medo AI Toolkit"
fi

register_portal_service "Medo S3 Offloader" "http://127.0.0.1:${S3_OFFLOADER_PORT}" || log "WARN: unable to register S3 offloader in /etc/portal.yaml"
register_portal_service "Medo FileBrowser" "http://127.0.0.1:${FILEBROWSER_PORT}" || log "WARN: unable to register FileBrowser in /etc/portal.yaml"
if [[ "${AI_TOOLKIT_AUTOSTART}" == "true" ]]; then
  register_portal_service "Medo AI Toolkit" "http://127.0.0.1:${AI_TOOLKIT_PORT}" || log "WARN: unable to register AI Toolkit in /etc/portal.yaml"
fi

log "Service summary (internal ports only):"
log "- ComfyUI: 8188 (managed by base image)"
log "- S3 offloader: ${S3_OFFLOADER_PORT}"
log "- FileBrowser: ${FILEBROWSER_PORT}"
if [[ "${AI_TOOLKIT_AUTOSTART}" == "true" ]]; then
  log "- AI toolkit: ${AI_TOOLKIT_PORT}"
else
  log "- AI toolkit: disabled (RUN_AI_TOOLKIT=${RUN_AI_TOOLKIT})"
fi
