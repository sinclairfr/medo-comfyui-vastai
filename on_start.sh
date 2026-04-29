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

S3_OFFLOADER_PORT="${S3_OFFLOADER_PORT:-5055}"
FILEBROWSER_PORT="${FILEBROWSER_PORT:-8081}"
AI_TOOLKIT_PORT="${AI_TOOLKIT_PORT:-8675}"
RUN_AI_TOOLKIT="${RUN_AI_TOOLKIT:-false}"

S3_DIR="${WORKSPACE}/comfyui_S3_offloader"
S3_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"
AI_TOOLKIT_DIR="${WORKSPACE}/ai-toolkit"
AI_TOOLKIT_REPO="https://github.com/ostris/ai-toolkit"

mkdir -p "${WORKSPACE}" "${LOG_DIR}" "${SERVICES_DIR}" "${SERVICES_DIR}/filebrowser"

log() { echo "[medo] $*" | tee -a "${LOG_DIR}/on_start.log"; }

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

log "Preparing repositories"
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

log "Service summary (internal ports only):"
log "- ComfyUI: 8188 (managed by base image)"
log "- S3 offloader: ${S3_OFFLOADER_PORT}"
log "- FileBrowser: ${FILEBROWSER_PORT}"
if [[ "${AI_TOOLKIT_AUTOSTART}" == "true" ]]; then
  log "- AI toolkit: ${AI_TOOLKIT_PORT}"
else
  log "- AI toolkit: disabled (RUN_AI_TOOLKIT=${RUN_AI_TOOLKIT})"
fi
