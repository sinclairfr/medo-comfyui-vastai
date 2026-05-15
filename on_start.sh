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
PORTAIL_CONFIG="${PORTAIL_CONFIG:-${PORTAL_CONFIG:-}}"
MEDO_EDIT_PORTAL_YAML="${MEDO_EDIT_PORTAL_YAML:-false}"

S3_DIR="${WORKSPACE}/comfyui_S3_offloader"
S3_REPO="https://github.com/sinclairfr/comfyui_S3_offloader"
AI_TOOLKIT_DIR="${WORKSPACE}/ai-toolkit"
AI_TOOLKIT_REPO="https://github.com/ostris/ai-toolkit"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"

COMFYUI_DIR="${WORKSPACE}/ComfyUI"
CUSTOM_NODES_CONFIG_FILE="${CUSTOM_NODES_CONFIG_FILE:-${COMFYUI_DIR}/custom_nodes_list.json}"
ROOT_CUSTOM_NODES_CONFIG_FILE="${WORKSPACE}/custom_nodes_list.json"
BAKED_CUSTOM_NODES_CONFIG_FILE="/opt/medo/custom_nodes_list.json"
CUSTOM_NODES_LIST_URL="${CUSTOM_NODES_LIST_URL:-https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/refs/heads/main/custom_nodes_list.json}"

mkdir -p "${WORKSPACE}" "${LOG_DIR}" "${SERVICES_DIR}" "${SERVICES_DIR}/filebrowser"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

_ts() { date '+%H:%M:%S'; }

log() {
  local msg="[medo $(_ts)] $*"
  echo "${msg}" | tee -a "${LOG_DIR}/on_start.log"
}

log_section() {
  local bar="================================================================"
  log "${bar}"
  log "  $*"
  log "${bar}"
}

log_ok()   { log "  OK  $*"; }
log_warn() { log "  WARN  $*"; }
log_err()  { log "  ERROR  $*"; }

# Run a command and show output in real-time on stdout AND in the log file
run_logged() {
  "$@" 2>&1 | tee -a "${LOG_DIR}/on_start.log"
  return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# Startup banner
# ---------------------------------------------------------------------------

log_section "Medo on_start starting"
log "WORKSPACE            = ${WORKSPACE}"
log "COMFYUI_DIR          = ${COMFYUI_DIR}"
log "PYTHON_BIN           = ${PYTHON_BIN} ($(${PYTHON_BIN} --version 2>&1 || echo 'not found'))"
log "CUSTOM_NODES_CONFIG  = ${CUSTOM_NODES_CONFIG_FILE}"
log "CUSTOM_NODES_LIST_URL= ${CUSTOM_NODES_LIST_URL}"
log "BAKED_CONFIG         = ${BAKED_CUSTOM_NODES_CONFIG_FILE}"
log "RUN_AI_TOOLKIT       = ${RUN_AI_TOOLKIT}"
log "MEDO_EDIT_PORTAL_YAML= ${MEDO_EDIT_PORTAL_YAML}"
log "LOG                  = ${LOG_DIR}/on_start.log"
log ""
log "Disk usage at startup:"
run_logged df -h "${WORKSPACE}" || true
log ""
log "ComfyUI directory exists: $([ -d "${COMFYUI_DIR}" ] && echo YES || echo NO)"
log "Custom nodes dir exists:  $([ -d "${COMFYUI_DIR}/custom_nodes" ] && echo YES || echo NO)"
if [[ -d "${COMFYUI_DIR}/custom_nodes" ]]; then
  log "Current custom nodes:"
  ls -1 "${COMFYUI_DIR}/custom_nodes" 2>/dev/null | while read -r n; do log "  - ${n}"; done || true
fi

# ---------------------------------------------------------------------------

register_http_port() {
  local port="$1" name="$2"
  local http_ports="/run/http_ports"
  [[ -f "${http_ports}" ]] || return 0
  if ! grep -Eq "(^|[^0-9])${port}([^0-9]|$)" "${http_ports}"; then
    echo "${port} ${name}" >> "${http_ports}"
    log_ok "Registered ${name} on port ${port} in /run/http_ports"
  fi
}

git_sync_repo() {
  local repo_url="$1" target_dir="$2"
  if [[ ! -d "${target_dir}/.git" ]]; then
    log "Cloning ${repo_url} -> ${target_dir}"
    if run_logged git clone --depth 1 "${repo_url}" "${target_dir}"; then
      log_ok "Cloned ${repo_url}"
    else
      log_err "git clone failed for ${repo_url}"
      return 1
    fi
  else
    log "Updating existing repo at ${target_dir}"
    if run_logged git -C "${target_dir}" fetch --depth 1 origin && \
       run_logged git -C "${target_dir}" reset --hard origin/HEAD; then
      log_ok "Updated ${target_dir}"
    else
      log_err "git update failed for ${target_dir}"
      return 1
    fi
  fi
}

fetch_custom_nodes_config() {
  log_section "Fetch custom_nodes_list.json"
  local dst="${ROOT_CUSTOM_NODES_CONFIG_FILE}"

  log "Checking for config file..."
  log "  1) ComfyUI-side  : ${CUSTOM_NODES_CONFIG_FILE} -> $([ -f "${CUSTOM_NODES_CONFIG_FILE}" ] && echo FOUND || echo missing)"
  log "  2) Workspace root: ${dst} -> $([ -f "${dst}" ] && echo FOUND || echo missing)"
  log "  3) Baked in image: ${BAKED_CUSTOM_NODES_CONFIG_FILE} -> $([ -f "${BAKED_CUSTOM_NODES_CONFIG_FILE}" ] && echo FOUND || echo missing)"

  if [[ -f "${CUSTOM_NODES_CONFIG_FILE}" ]]; then
    log_ok "Using ComfyUI-side config: ${CUSTOM_NODES_CONFIG_FILE}"
    return 0
  fi

  if [[ -f "${dst}" ]]; then
    log_ok "Using workspace root config: ${dst}"
    return 0
  fi

  if [[ -f "${BAKED_CUSTOM_NODES_CONFIG_FILE}" ]]; then
    log "Copying baked-in config to workspace root"
    cp "${BAKED_CUSTOM_NODES_CONFIG_FILE}" "${dst}"
    log_ok "Copied ${BAKED_CUSTOM_NODES_CONFIG_FILE} -> ${dst}"
    return 0
  fi

  if [[ -n "${CUSTOM_NODES_LIST_URL}" ]]; then
    log "Downloading config from ${CUSTOM_NODES_LIST_URL}"
    local http_code
    http_code=$(curl -fsSL -w "%{http_code}" "${CUSTOM_NODES_LIST_URL}" -o "${dst}" 2>>"${LOG_DIR}/on_start.log")
    if [[ "${http_code}" == "200" ]]; then
      log_ok "Downloaded config (HTTP ${http_code}) -> ${dst}"
    else
      log_err "curl returned HTTP ${http_code} for ${CUSTOM_NODES_LIST_URL}"
      rm -f "${dst}"
      return 0
    fi
  else
    log_warn "CUSTOM_NODES_LIST_URL is empty; no config to download"
    return 0
  fi

  if [[ -f "${dst}" ]]; then
    log "Config file content:"
    cat "${dst}" | tee -a "${LOG_DIR}/on_start.log"
  fi
}

restart_comfyui_after_nodes() {
  log_section "ComfyUI restart after custom node install"

  if ! pgrep -x supervisord >/dev/null 2>&1; then
    log "supervisord is not running yet; ComfyUI will pick up custom nodes on first start"
    return 0
  fi

  log "supervisord is running. Full status:"
  run_logged supervisorctl status || true

  local found_name=""
  for name in comfyui comfy comfy-ui; do
    if supervisorctl status "${name}" >/dev/null 2>&1; then
      found_name="${name}"
      break
    fi
  done

  if [[ -z "${found_name}" ]]; then
    log_warn "No ComfyUI program found in supervisord (tried: comfyui, comfy, comfy-ui)"
    log "Custom nodes are in place; ComfyUI will load them on its next start"
    return 0
  fi

  log "Found supervisord program: ${found_name}"
  local state
  state=$(supervisorctl status "${found_name}" 2>/dev/null | awk '{print $2}')
  log "Current state of ${found_name}: ${state}"

  if [[ "${state}" == "RUNNING" ]]; then
    log "Restarting ${found_name} so it picks up the new custom nodes..."
    run_logged supervisorctl restart "${found_name}" || true
    sleep 3
    local new_state
    new_state=$(supervisorctl status "${found_name}" 2>/dev/null | awk '{print $2}')
    log "State of ${found_name} after restart: ${new_state}"
    if [[ "${new_state}" == "RUNNING" ]]; then
      log_ok "${found_name} restarted and is RUNNING"
    else
      log_warn "${found_name} is in state '${new_state}' after restart — check supervisord logs"
    fi
  else
    log "${found_name} is not RUNNING (state=${state}); skipping restart"
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

  local tmp_dir="/tmp/medo-comfyui-vastai"
  if [[ ! -d "${tmp_dir}/.git" ]]; then
    log "Template directory missing. Cloning upstream repo for templates."
    run_logged git clone --depth 1 https://github.com/sinclairfr/medo-comfyui-vastai "${tmp_dir}" || true
  fi

  if [[ -d "${tmp_dir}/supervisord/programs" ]] && [[ -f "${tmp_dir}/supervisord/programs/medo-s3-offloader.conf" ]]; then
    mkdir -p /opt/medo/supervisor-templates
    cp -f "${tmp_dir}"/supervisord/programs/medo-*.conf /opt/medo/supervisor-templates/ 2>/dev/null || true
    SUPERVISOR_TPL_DIR="/opt/medo/supervisor-templates"
    log "Bootstrapped templates into ${SUPERVISOR_TPL_DIR}"
    return 0
  fi

  log_err "No valid supervisor template directory found."
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
    if run_logged "${PYTHON_BIN}" -m pip install -r "${S3_DIR}/requirements.txt"; then
      log_ok "S3 offloader deps installed"
    else
      log_warn "Standard pip install failed; retrying with --break-system-packages"
      if run_logged "${PYTHON_BIN}" -m pip install \
          --break-system-packages \
          --ignore-installed \
          -r "${S3_DIR}/requirements.txt"; then
        log_ok "S3 offloader deps installed (fallback)"
      else
        log_warn "Failed to install S3 offloader dependencies even after fallback"
      fi
    fi
  else
    log "No requirements.txt in ${S3_DIR}; skipping S3 deps"
  fi
}

ensure_s3_offloader_settings() {
  log_section "S3 offloader settings"
  local settings_file="${S3_DIR}/settings.json"

  local models_root="${S3O_MODELS_ROOT:-${MODELS_ROOT:-}}"
  local s3_bucket="${S3O_S3_BUCKET:-${S3_BUCKET:-}}"
  local s3_prefix="${S3O_S3_PREFIX:-${S3_PREFIX:-models-offload/}}"
  local r2_url="${S3O_R2_URL:-${R2_URL:-}}"
  local aws_profile="${S3O_AWS_PROFILE:-${AWS_PROFILE:-}}"
  local aws_access_key_id="${S3O_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  local aws_secret_access_key="${S3O_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  local aws_session_token="${S3O_AWS_SESSION_TOKEN:-${AWS_SESSION_TOKEN:-}}"
  local include_personal_stuff="${S3O_INCLUDE_PERSONAL_STUFF:-${INCLUDE_PERSONAL_STUFF:-false}}"

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

  log "models_root  = ${models_root}"
  log "s3_bucket    = ${s3_bucket:-<not set>}"
  log "s3_prefix    = ${s3_prefix}"
  log "r2_url       = ${r2_url:-<not set>}"

  export S3_SETTINGS_FILE="${settings_file}"
  export S3_MODELS_ROOT="${models_root}"
  export S3_BUCKET_VALUE="${s3_bucket}"
  export S3_PREFIX_VALUE="${s3_prefix}"
  export S3_R2_URL_VALUE="${r2_url}"
  export AWS_PROFILE_VALUE="${aws_profile}"
  export AWS_ACCESS_KEY_ID_VALUE="${aws_access_key_id}"
  export AWS_SECRET_ACCESS_KEY_VALUE="${aws_secret_access_key}"
  export AWS_SESSION_TOKEN_VALUE="${aws_session_token}"
  export INCLUDE_PERSONAL_STUFF_VALUE="${include_personal_stuff}"
  export WORKSPACE

  python3 - <<'PY' 2>&1 | tee -a "${LOG_DIR}/on_start.log"
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
settings["r2_url"] = (os.environ.get("S3_R2_URL_VALUE", "").strip() or None)
settings["aws_profile"] = (os.environ.get("AWS_PROFILE_VALUE", "").strip() or None)
settings["aws_access_key_id"] = (os.environ.get("AWS_ACCESS_KEY_ID_VALUE", "").strip() or None)
settings["aws_secret_access_key"] = (os.environ.get("AWS_SECRET_ACCESS_KEY_VALUE", "").strip() or None)
settings["aws_session_token"] = (os.environ.get("AWS_SESSION_TOKEN_VALUE", "").strip() or None)
settings["include_personal_stuff"] = _to_bool(os.environ.get("INCLUDE_PERSONAL_STUFF_VALUE", "false"))

if not isinstance(settings.get("personal_paths"), list) or not settings.get("personal_paths"):
    settings["personal_paths"] = [
        f"{workspace}/ComfyUI/custom_nodes",
        f"{workspace}/ComfyUI/user",
        f"{workspace}/comfyui_S3_offloader",
    ]

settings_path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"[s3-settings] Written to {settings_path}")
print(f"[s3-settings] models_root={settings['models_root']}")
print(f"[s3-settings] s3_bucket={settings['s3_bucket']}")
print(f"[s3-settings] s3_prefix={settings['s3_prefix']}")
print(f"[s3-settings] r2_url={settings['r2_url']}")
PY
}

ensure_portal_apps() {
  local portal_yaml="/etc/portal.yaml"
  if [[ ! -f "${portal_yaml}" ]]; then
    log_warn "${portal_yaml} not found; skipping portal app registration"
    return 0
  fi

  log "Registering Medo apps in ${portal_yaml}"
  python3 - <<'PY' 2>&1 | tee -a "${LOG_DIR}/on_start.log"
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
print('[portal] portal.yaml updated with Medo apps')
PY
}

ensure_filebrowser_binary() {
  if command -v filebrowser >/dev/null 2>&1; then
    log_ok "filebrowser already installed at $(command -v filebrowser)"
    return 0
  fi

  log "FileBrowser binary not found; attempting installation"
  local arch fb_arch tmpdir
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) fb_arch="linux-amd64" ;;
    aarch64|arm64) fb_arch="linux-arm64" ;;
    *)
      log_warn "Unsupported architecture for filebrowser install: ${arch}"
      return 1
      ;;
  esac

  log "Architecture: ${arch} -> using ${fb_arch} release"
  tmpdir="$(mktemp -d)"
  local fb_url="https://github.com/filebrowser/filebrowser/releases/latest/download/${fb_arch}-filebrowser.tar.gz"
  log "Downloading filebrowser from ${fb_url}"
  if curl -fsSL "${fb_url}" -o "${tmpdir}/filebrowser.tar.gz" 2>&1 | tee -a "${LOG_DIR}/on_start.log" \
    && tar -xzf "${tmpdir}/filebrowser.tar.gz" -C "${tmpdir}" \
    && install -m 0755 "${tmpdir}/filebrowser" /usr/local/bin/filebrowser; then
    log_ok "Installed filebrowser to /usr/local/bin/filebrowser"
  else
    log_warn "Failed to install filebrowser binary"
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${tmpdir}"
  return 0
}

install_custom_nodes_from_config() {
  log_section "Install custom nodes"
  local config_file="${CUSTOM_NODES_CONFIG_FILE}"
  local custom_nodes_dir="${COMFYUI_DIR}/custom_nodes"

  log "COMFYUI_DIR      = ${COMFYUI_DIR} (exists=$([ -d "${COMFYUI_DIR}" ] && echo yes || echo NO))"
  log "custom_nodes_dir = ${custom_nodes_dir}"
  log "config_file      = ${config_file}"

  if [[ ! -d "${COMFYUI_DIR}" ]]; then
    log_warn "ComfyUI directory not found at ${COMFYUI_DIR}; skipping custom nodes bootstrap"
    return 0
  fi

  if [[ ! -f "${config_file}" ]]; then
    log "Primary config not found at ${config_file}"
    if [[ -f "${ROOT_CUSTOM_NODES_CONFIG_FILE}" ]]; then
      config_file="${ROOT_CUSTOM_NODES_CONFIG_FILE}"
      log "Using workspace fallback: ${config_file}"
    else
      log_warn "No custom nodes config found at either location; skipping"
      log "  Tried: ${CUSTOM_NODES_CONFIG_FILE}"
      log "  Tried: ${ROOT_CUSTOM_NODES_CONFIG_FILE}"
      return 0
    fi
  fi

  log_ok "Using config: ${config_file}"
  log "Config content:"
  cat "${config_file}" | tee -a "${LOG_DIR}/on_start.log"
  echo ""

  mkdir -p "${custom_nodes_dir}"
  export CUSTOM_NODES_CONFIG_FILE="${config_file}"
  export CUSTOM_NODES_DIR="${custom_nodes_dir}"
  export LOG_DIR
  export PYTHON_BIN

  "${PYTHON_BIN}" - <<'PY' 2>&1 | tee -a "${LOG_DIR}/on_start.log"
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

cfg_path = Path(os.environ["CUSTOM_NODES_CONFIG_FILE"])
custom_nodes_dir = Path(os.environ["CUSTOM_NODES_DIR"])
python_bin = os.environ.get("PYTHON_BIN", "python3")

print(f"[custom-nodes] ----------------------------------------")
print(f"[custom-nodes] Config file : {cfg_path}")
print(f"[custom-nodes] Target dir  : {custom_nodes_dir}")
print(f"[custom-nodes] Python bin  : {python_bin}")
print(f"[custom-nodes] ----------------------------------------")

def _safe_name_from_url(url: str) -> str:
    base = url.rstrip("/").split("/")[-1]
    if base.endswith(".git"):
        base = base[:-4]
    return re.sub(r"[^A-Za-z0-9._-]+", "-", base).strip("-") or "custom-node"

def _run(cmd, label=""):
    label = label or " ".join(cmd[:3])
    print(f"[custom-nodes]   $ {' '.join(cmd)}")
    t0 = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True)
    elapsed = time.time() - t0
    if result.stdout.strip():
        for line in result.stdout.strip().splitlines():
            print(f"[custom-nodes]     {line}")
    if result.stderr.strip():
        for line in result.stderr.strip().splitlines():
            print(f"[custom-nodes]     STDERR: {line}")
    print(f"[custom-nodes]   -> exit={result.returncode} ({elapsed:.1f}s)")
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, cmd)

try:
    payload = json.loads(cfg_path.read_text())
except Exception as exc:
    print(f"[custom-nodes] ERROR: invalid JSON in {cfg_path}: {exc}")
    sys.exit(1)

if not isinstance(payload, list):
    print(f"[custom-nodes] ERROR: expected a JSON array, got {type(payload).__name__}")
    sys.exit(1)

print(f"[custom-nodes] {len(payload)} entries to process")

processed = 0
skipped = 0
cloned = 0
already_present = 0
requirements_found = 0
requirements_installed = 0
requirements_failed = 0

for i, entry in enumerate(payload, start=1):
    print(f"[custom-nodes] ---- Entry {i}/{len(payload)} ----")

    if not isinstance(entry, dict):
        print(f"[custom-nodes] WARN: not an object ({type(entry).__name__}), skipped")
        skipped += 1
        continue

    url = (entry.get("url") or "").strip()
    if not url:
        print(f"[custom-nodes] WARN: missing 'url' key, skipped")
        skipped += 1
        continue

    branch = (entry.get("branch") or "").strip() or None
    target_name = (entry.get("name") or "").strip() or _safe_name_from_url(url)
    target_dir = custom_nodes_dir / target_name
    processed += 1

    print(f"[custom-nodes]   url    : {url}")
    print(f"[custom-nodes]   branch : {branch or '(default)'}")
    print(f"[custom-nodes]   name   : {target_name}")
    print(f"[custom-nodes]   target : {target_dir}")

    if target_dir.exists():
        print(f"[custom-nodes]   status : ALREADY PRESENT — skipping clone")
        already_present += 1
    else:
        cmd = ["git", "clone", "--depth", "1"]
        if branch:
            cmd += ["--branch", branch]
        cmd += [url, str(target_dir)]
        try:
            _run(cmd)
            print(f"[custom-nodes]   status : CLONED OK")
            cloned += 1
        except subprocess.CalledProcessError as exc:
            print(f"[custom-nodes]   status : CLONE FAILED (exit={exc.returncode})")
            requirements_failed += 1
            continue

    req = target_dir / "requirements.txt"
    if req.exists():
        requirements_found += 1
        print(f"[custom-nodes]   requirements.txt : FOUND — installing")
        try:
            _run([python_bin, "-m", "pip", "install", "-r", str(req)])
            print(f"[custom-nodes]   pip : OK")
            requirements_installed += 1
        except subprocess.CalledProcessError:
            print(f"[custom-nodes]   pip : FAILED — retrying with --break-system-packages")
            try:
                _run([
                    python_bin, "-m", "pip", "install",
                    "--break-system-packages", "--ignore-installed",
                    "-r", str(req),
                ])
                print(f"[custom-nodes]   pip (fallback) : OK")
                requirements_installed += 1
            except subprocess.CalledProcessError as exc:
                print(f"[custom-nodes]   pip (fallback) : FAILED (exit={exc.returncode})")
                requirements_failed += 1
    else:
        print(f"[custom-nodes]   requirements.txt : not found — skipping pip")

print(f"")
print(f"[custom-nodes] ======== SUMMARY ========")
print(f"[custom-nodes]   total entries        : {len(payload)}")
print(f"[custom-nodes]   processed            : {processed}")
print(f"[custom-nodes]   skipped (bad entry)  : {skipped}")
print(f"[custom-nodes]   cloned               : {cloned}")
print(f"[custom-nodes]   already present      : {already_present}")
print(f"[custom-nodes]   requirements found   : {requirements_found}")
print(f"[custom-nodes]   requirements ok      : {requirements_installed}")
print(f"[custom-nodes]   failures             : {requirements_failed}")
print(f"[custom-nodes] =========================")
PY

  log "Custom nodes directory after install:"
  ls -1 "${custom_nodes_dir}" 2>/dev/null | while read -r n; do log "  - ${n}"; done || true
}

# ---------------------------------------------------------------------------
# Main sequence
# ---------------------------------------------------------------------------

log_section "Step 1/6 — Sync S3 offloader repo"
git_sync_repo "${S3_REPO}" "${S3_DIR}" || log_warn "Unable to sync comfyui_S3_offloader"

log_section "Step 2/6 — S3 offloader settings & deps"
ensure_s3_offloader_settings
ensure_s3_offloader_deps

log_section "Step 3/6 — Custom nodes config fetch"
fetch_custom_nodes_config

log_section "Step 4/6 — Custom nodes clone & pip install"
install_custom_nodes_from_config

log_section "Step 5/6 — Restart ComfyUI"
restart_comfyui_after_nodes

log_section "Step 6/6 — Portal, filebrowser, supervisord"

if [[ "${MEDO_EDIT_PORTAL_YAML,,}" == "true" ]]; then
  log "MEDO_EDIT_PORTAL_YAML=true; applying portal.yaml edits"
  ensure_portal_apps
elif [[ -n "${PORTAIL_CONFIG}" ]]; then
  log "PORTAL_CONFIG detected; skipping portal.yaml edits (Vast portal managed by env)"
else
  log "Skipping portal.yaml edits (set MEDO_EDIT_PORTAL_YAML=true to enable)"
fi

ensure_filebrowser_binary || true

AI_TOOLKIT_AUTOSTART="false"
if [[ "${RUN_AI_TOOLKIT,,}" == "true" ]]; then
  AI_TOOLKIT_AUTOSTART="true"
  log "RUN_AI_TOOLKIT=true; syncing ai-toolkit repo"
  git_sync_repo "${AI_TOOLKIT_REPO}" "${AI_TOOLKIT_DIR}" || log_warn "Unable to sync ai-toolkit"
fi

if command -v filebrowser >/dev/null 2>&1; then
  local _fb_pass_file="${WORKSPACE}/.filebrowser_password"
  local _fb_pass
  if [[ -n "${FILEBROWSER_PASSWORD:-}" ]]; then
    _fb_pass="${FILEBROWSER_PASSWORD}"
    log "FileBrowser password: from FILEBROWSER_PASSWORD env var"
  elif [[ -f "${_fb_pass_file}" ]]; then
    _fb_pass="$(cat "${_fb_pass_file}")"
    log "FileBrowser password: loaded from ${_fb_pass_file}"
  else
    _fb_pass="$(openssl rand -hex 12 2>/dev/null || tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)"
    echo "${_fb_pass}" > "${_fb_pass_file}"
    chmod 600 "${_fb_pass_file}"
    log "FileBrowser password: generated and saved to ${_fb_pass_file}"
  fi

  if [[ ! -f "${SERVICES_DIR}/filebrowser.db" ]]; then
    log "Initializing FileBrowser DB"
    run_logged filebrowser config init -d "${SERVICES_DIR}/filebrowser.db" || true
    run_logged filebrowser users add admin "${_fb_pass}" --perm.admin -d "${SERVICES_DIR}/filebrowser.db" || true
    run_logged filebrowser users update admin --password "${_fb_pass}" -d "${SERVICES_DIR}/filebrowser.db" || true
    log_ok "FileBrowser credentials: admin / $(cat "${_fb_pass_file}" 2>/dev/null || echo '(see FILEBROWSER_PASSWORD env var)')"
  else
    log "FileBrowser DB already exists at ${SERVICES_DIR}/filebrowser.db"
  fi
fi

if ! detect_supervisor_templates_dir; then
  log_err "Could not find supervisor templates; aborting"
  exit 1
fi

log "Supervisor template dir: ${SUPERVISOR_TPL_DIR}"
mkdir -p "${SUPERVISOR_DST_DIR}"

enabled_programs=("medo-s3-offloader")

render_supervisor_program "${SUPERVISOR_TPL_DIR}/medo-s3-offloader.conf" "${SUPERVISOR_DST_DIR}/medo-s3-offloader.conf"
sed -i "s|^command=python3 app.py --port |command=${PYTHON_BIN} app.py --port |" "${SUPERVISOR_DST_DIR}/medo-s3-offloader.conf"
log_ok "Rendered medo-s3-offloader.conf"

if command -v filebrowser >/dev/null 2>&1; then
  render_supervisor_program "${SUPERVISOR_TPL_DIR}/medo-filebrowser.conf" "${SUPERVISOR_DST_DIR}/medo-filebrowser.conf"
  sed -i 's|^command=filebrowser |command=filebrowser -a 0.0.0.0 |' "${SUPERVISOR_DST_DIR}/medo-filebrowser.conf"
  enabled_programs+=("medo-filebrowser")
  log_ok "Rendered medo-filebrowser.conf"
else
  log_warn "filebrowser binary not found; skipping medo-filebrowser"
  rm -f "${SUPERVISOR_DST_DIR}/medo-filebrowser.conf"
fi

render_supervisor_program "${SUPERVISOR_TPL_DIR}/medo-ai-toolkit-server.conf" "${SUPERVISOR_DST_DIR}/medo-ai-toolkit-server.conf"
render_supervisor_program "${SUPERVISOR_TPL_DIR}/medo-ai-toolkit-worker.conf" "${SUPERVISOR_DST_DIR}/medo-ai-toolkit-worker.conf"

if [[ "${AI_TOOLKIT_AUTOSTART}" != "true" ]]; then
  rm -f "${SUPERVISOR_DST_DIR}/medo-ai-toolkit-server.conf" "${SUPERVISOR_DST_DIR}/medo-ai-toolkit-worker.conf"
  log "AI Toolkit autostart disabled; confs removed"
fi

if pgrep -x supervisord >/dev/null 2>&1; then
  log "supervisord running; reloading config"
  run_logged supervisorctl reread || true
  run_logged supervisorctl update || true
else
  log "Starting supervisord"
  run_logged supervisord -c /etc/supervisor/supervisord.conf || true
fi

if [[ ${#enabled_programs[@]} -gt 0 ]]; then
  log "Starting programs: ${enabled_programs[*]}"
  run_logged supervisorctl start "${enabled_programs[@]}" || true
fi
if [[ "${AI_TOOLKIT_AUTOSTART}" == "true" ]]; then
  log "Starting AI Toolkit programs"
  run_logged supervisorctl start medo-ai-toolkit-server medo-ai-toolkit-worker || true
fi

register_http_port "${S3_OFFLOADER_PORT}" "Medo S3 Offloader"
register_http_port "${FILEBROWSER_PORT}" "Medo FileBrowser"
if [[ "${AI_TOOLKIT_AUTOSTART}" == "true" ]]; then
  register_http_port "${AI_TOOLKIT_PORT}" "Medo AI Toolkit"
fi

log_section "on_start complete"
log "Service summary (internal ports):"
log "  ComfyUI     : 8188 (managed by base image)"
log "  S3 offloader: ${S3_OFFLOADER_PORT}"
log "  FileBrowser : ${FILEBROWSER_PORT}"
if [[ "${AI_TOOLKIT_AUTOSTART}" == "true" ]]; then
  log "  AI toolkit  : ${AI_TOOLKIT_PORT}"
else
  log "  AI toolkit  : disabled (RUN_AI_TOOLKIT=${RUN_AI_TOOLKIT})"
fi
log ""
log "Full log: ${LOG_DIR}/on_start.log"
