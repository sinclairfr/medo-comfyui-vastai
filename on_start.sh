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
SUPERVISOR_TPL_DIR="${SUPERVISOR_TPL_DIR:-/opt/medo/supervisor-templates}"

S3_OFFLOADER_PORT="${S3_OFFLOADER_PORT:-5055}"
FILEBROWSER_PORT="${FILEBROWSER_PORT:-8081}"
AI_TOOLKIT_PORT="${AI_TOOLKIT_PORT:-8675}"
RUN_AI_TOOLKIT="${RUN_AI_TOOLKIT:-false}"

S3_DIR="${WORKSPACE}/comfyui_S3_offloader"
S3_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"
AI_TOOLKIT_DIR="${WORKSPACE}/ai-toolkit"
AI_TOOLKIT_REPO="https://github.com/ostris/ai-toolkit"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"

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

detect_supervisor_templates_dir() {
  if [[ -d "${SUPERVISOR_TPL_DIR}" ]]; then
    return 0
  fi

  local fallback_dirs=(
    "${WORKSPACE}/medo-comfyui-vastai/supervisord/programs"
    "${WORKSPACE}/comfyui_S3_offloader/supervisord/programs"
    "/tmp/medo-comfyui-vastai/supervisord/programs"
    "$(pwd)/supervisord/programs"
  )

  for d in "${fallback_dirs[@]}"; do
    if [[ -d "${d}" ]] && [[ -f "${d}/medo-s3-offloader.conf" ]]; then
      SUPERVISOR_TPL_DIR="${d}"
      log "Using fallback supervisor template dir: ${SUPERVISOR_TPL_DIR}"
      return 0
    fi
  done

  # Last-resort: bootstrap from upstream repo templates.
  local tmp_dir="/tmp/medo-comfyui-vastai"
  if [[ ! -d "${tmp_dir}/.git" ]]; then
    log "Template directory missing. Cloning upstream repo for templates."
    git clone --depth 1 https://github.com/sinclairfr/medo-comfyui-vastai "${tmp_dir}" >>"${LOG_DIR}/on_start.log" 2>&1 || true
  fi

  if [[ -d "${tmp_dir}/supervisord/programs" ]] && [[ -f "${tmp_dir}/supervisord/programs/medo-s3-offloader.conf" ]]; then
    mkdir -p /opt/medo/supervisor-templates
    cp -f "${tmp_dir}"/supervisord/programs/medo-*.conf /opt/medo/supervisor-templates/ 2>/dev/null || true
    SUPERVISOR_TPL_DIR="/opt/medo/supervisor-templates"
    log "Bootstrapped templates into ${SUPERVISOR_TPL_DIR}"
    return 0
  fi

  log "ERROR: No valid supervisor template directory found."
  return 1
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

ensure_s3_offloader_deps() {
  if [[ -f "${S3_DIR}/requirements.txt" ]]; then
    log "Installing S3 offloader Python dependencies"
    if ! "${PYTHON_BIN}" -m pip install -r "${S3_DIR}/requirements.txt" >>"${LOG_DIR}/on_start.log" 2>&1; then
      log "WARN: standard pip install failed; retrying with system-package override flags"
      "${PYTHON_BIN}" -m pip install \
        --break-system-packages \
        --ignore-installed \
        -r "${S3_DIR}/requirements.txt" >>"${LOG_DIR}/on_start.log" 2>&1 || \
        log "WARN: failed to install S3 offloader dependencies even after fallback"
    fi
  fi
}

ensure_s3_offloader_settings() {
  local settings_file="${S3_DIR}/settings.json"
  log "Applying S3 offloader settings for this VM"

  # Prefer explicit env, then common defaults.
  local models_root="${S3O_MODELS_ROOT:-${MODELS_ROOT:-}}"
  local s3_bucket="${S3O_S3_BUCKET:-${S3_BUCKET:-}}"
  local s3_prefix="${S3O_S3_PREFIX:-${S3_PREFIX:-models-offload/}}"
  local aws_profile="${S3O_AWS_PROFILE:-${AWS_PROFILE:-}}"
  local aws_access_key_id="${S3O_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  local aws_secret_access_key="${S3O_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  local aws_session_token="${S3O_AWS_SESSION_TOKEN:-${AWS_SESSION_TOKEN:-}}"
  local include_personal_stuff="${S3O_INCLUDE_PERSONAL_STUFF:-${INCLUDE_PERSONAL_STUFF:-false}}"

  # VM-aware models directory auto-detection if not explicitly provided.
  if [[ -z "${models_root}" ]]; then
    if [[ -d "${WORKSPACE}/ComfyUI/models" ]]; then
      models_root="${WORKSPACE}/ComfyUI/models"
    elif [[ -d "${WORKSPACE}/comfyui/models" ]]; then
      models_root="${WORKSPACE}/comfyui/models"
    elif [[ -d "${WORKSPACE}/models" ]]; then
      models_root="${WORKSPACE}/models"
    else
      models_root="${WORKSPACE}/ComfyUI/models"
    fi
  fi

  export S3_SETTINGS_FILE="${settings_file}"
  export S3_MODELS_ROOT="${models_root}"
  export S3_BUCKET_VALUE="${s3_bucket}"
  export S3_PREFIX_VALUE="${s3_prefix}"
  export AWS_PROFILE_VALUE="${aws_profile}"
  export AWS_ACCESS_KEY_ID_VALUE="${aws_access_key_id}"
  export AWS_SECRET_ACCESS_KEY_VALUE="${aws_secret_access_key}"
  export AWS_SESSION_TOKEN_VALUE="${aws_session_token}"
  export INCLUDE_PERSONAL_STUFF_VALUE="${include_personal_stuff}"
  export WORKSPACE

  python3 - <<'PY' >>"${LOG_DIR}/on_start.log" 2>&1
import json
import os
from pathlib import Path

settings_path = Path(os.environ["S3_SETTINGS_FILE"])
settings_path.parent.mkdir(parents=True, exist_ok=True)

raw = {}
if settings_path.exists():
    try:
        raw = json.loads(settings_path.read_text()) or {}
    except Exception:
        raw = {}

def _to_bool(v: str) -> bool:
    return str(v).strip().lower() in {"1", "true", "yes", "y", "on"}

workspace = os.environ["WORKSPACE"]

settings = dict(raw)
settings["models_root"] = os.environ["S3_MODELS_ROOT"]
settings["s3_bucket"] = os.environ["S3_BUCKET_VALUE"]
settings["s3_prefix"] = os.environ["S3_PREFIX_VALUE"]
settings["aws_profile"] = (os.environ.get("AWS_PROFILE_VALUE", "").strip() or None)
settings["aws_access_key_id"] = (os.environ.get("AWS_ACCESS_KEY_ID_VALUE", "").strip() or None)
settings["aws_secret_access_key"] = (os.environ.get("AWS_SECRET_ACCESS_KEY_VALUE", "").strip() or None)
settings["aws_session_token"] = (os.environ.get("AWS_SESSION_TOKEN_VALUE", "").strip() or None)
settings["include_personal_stuff"] = _to_bool(os.environ.get("INCLUDE_PERSONAL_STUFF_VALUE", "false"))

# Keep existing personal_paths if present, otherwise provide sensible VM defaults.
if not isinstance(settings.get("personal_paths"), list) or not settings.get("personal_paths"):
    settings["personal_paths"] = [
        f"{workspace}/ComfyUI/custom_nodes",
        f"{workspace}/ComfyUI/user",
        f"{workspace}/comfyui_S3_offloader",
    ]

settings_path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"settings updated: {settings_path}")
print(f"models_root={settings['models_root']}")
print(f"s3_bucket={settings['s3_bucket']}")
print(f"s3_prefix={settings['s3_prefix']}")
PY
}

ensure_portal_apps() {
  local portal_yaml="/etc/portal.yaml"
  if [[ ! -f "${portal_yaml}" ]]; then
    log "WARN: ${portal_yaml} not found; skipping portal app registration"
    return 0
  fi

  log "Registering Medo apps in ${portal_yaml}"
  python3 - <<'PY' >>"${LOG_DIR}/on_start.log" 2>&1
import yaml
from pathlib import Path

p = Path('/etc/portal.yaml')
data = yaml.safe_load(p.read_text()) or {}
apps = data.setdefault('applications', {})

apps['Medo S3 Offloader'] = {
    'hostname': 'localhost',
    'external_port': 5055,
    'internal_port': 5055,
    'open_path': '/',
    'name': 'Medo S3 Offloader',
}

apps['Medo FileBrowser'] = {
    'hostname': 'localhost',
    'external_port': 8081,
    'internal_port': 8081,
    'open_path': '/',
    'name': 'Medo FileBrowser',
}

p.write_text(yaml.safe_dump(data, sort_keys=False))
print('portal.yaml updated with Medo apps')
PY
}

ensure_filebrowser_binary() {
  if command -v filebrowser >/dev/null 2>&1; then
    return 0
  fi

  log "FileBrowser binary not found; attempting installation"
  local arch fb_arch tmpdir
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) fb_arch="linux-amd64" ;;
    aarch64|arm64) fb_arch="linux-arm64" ;;
    *)
      log "WARN: unsupported architecture for filebrowser install: ${arch}"
      return 1
      ;;
  esac

  tmpdir="$(mktemp -d)"
  if curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/${fb_arch}-filebrowser.tar.gz" -o "${tmpdir}/filebrowser.tar.gz" \
    && tar -xzf "${tmpdir}/filebrowser.tar.gz" -C "${tmpdir}" \
    && install -m 0755 "${tmpdir}/filebrowser" /usr/local/bin/filebrowser; then
    log "Installed filebrowser to /usr/local/bin/filebrowser"
  else
    log "WARN: failed to install filebrowser binary"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  return 0
}

log "Preparing repositories"
git_sync_repo "${S3_REPO}" "${S3_DIR}" || log "WARN: unable to sync comfyui_S3_offloader"
ensure_s3_offloader_settings
ensure_s3_offloader_deps
ensure_portal_apps
ensure_filebrowser_binary || true

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
    # config init may already create an admin user; ensure password is always adminadmin12.
    filebrowser users add admin adminadmin12 --perm.admin -d "${SERVICES_DIR}/filebrowser.db" >>"${LOG_DIR}/on_start.log" 2>&1 || true
    filebrowser users update admin --password adminadmin12 -d "${SERVICES_DIR}/filebrowser.db" >>"${LOG_DIR}/on_start.log" 2>&1 || true
    log "FileBrowser default credentials: admin / adminadmin12"
  fi
fi

if ! detect_supervisor_templates_dir; then
  exit 1
fi

mkdir -p "${SUPERVISOR_DST_DIR}"

enabled_programs=("medo-s3-offloader")

render_supervisor_program "${SUPERVISOR_TPL_DIR}/medo-s3-offloader.conf" "${SUPERVISOR_DST_DIR}/medo-s3-offloader.conf"
# Ensure supervisor uses the same Python interpreter used for dependency install.
sed -i "s|^command=python3 app.py --port |command=${PYTHON_BIN} app.py --port |" "${SUPERVISOR_DST_DIR}/medo-s3-offloader.conf"

if command -v filebrowser >/dev/null 2>&1; then
  render_supervisor_program "${SUPERVISOR_TPL_DIR}/medo-filebrowser.conf" "${SUPERVISOR_DST_DIR}/medo-filebrowser.conf"
  # Ensure FileBrowser listens on all interfaces so Vast mapped ports can reach it.
  sed -i 's|^command=filebrowser |command=filebrowser -a 0.0.0.0 |' "${SUPERVISOR_DST_DIR}/medo-filebrowser.conf"
  enabled_programs+=("medo-filebrowser")
else
  log "WARN: filebrowser binary not found; skipping medo-filebrowser"
  rm -f "${SUPERVISOR_DST_DIR}/medo-filebrowser.conf"
fi

render_supervisor_program "${SUPERVISOR_TPL_DIR}/medo-ai-toolkit-server.conf" "${SUPERVISOR_DST_DIR}/medo-ai-toolkit-server.conf"
render_supervisor_program "${SUPERVISOR_TPL_DIR}/medo-ai-toolkit-worker.conf" "${SUPERVISOR_DST_DIR}/medo-ai-toolkit-worker.conf"

if [[ "${AI_TOOLKIT_AUTOSTART}" != "true" ]]; then
  rm -f "${SUPERVISOR_DST_DIR}/medo-ai-toolkit-server.conf" "${SUPERVISOR_DST_DIR}/medo-ai-toolkit-worker.conf"
fi

if pgrep -x supervisord >/dev/null 2>&1; then
  supervisorctl reread >>"${LOG_DIR}/on_start.log" 2>&1 || true
  supervisorctl update >>"${LOG_DIR}/on_start.log" 2>&1 || true
else
  log "Starting supervisord"
  supervisord -c /etc/supervisor/supervisord.conf >>"${LOG_DIR}/on_start.log" 2>&1 || true
fi

if [[ ${#enabled_programs[@]} -gt 0 ]]; then
  supervisorctl start "${enabled_programs[@]}" >>"${LOG_DIR}/on_start.log" 2>&1 || true
fi
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
