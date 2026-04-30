#!/usr/bin/env bash
set -Eeuo pipefail

# Custom BOOT_SCRIPT for vastai/comfy base images.
#
# Why this exists:
# - entrypoint.sh uses `exec`, so chaining `entrypoint.sh && ...` never reaches `...`.
# - The base boot flow must still run (/opt/instance-tools/bin/boot_default.sh).
#
# Usage in Vast template env:
#   BOOT_SCRIPT=https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/main/boot_vast.sh
#
# Startup command:
#   bash -lc 'entrypoint.sh'

DEFAULT_BOOT_SCRIPT="/opt/instance-tools/bin/boot_default.sh"
ON_START_URL="${MEDO_ON_START_URL:-https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/main/on_start.sh}"
ON_START_WAIT_SUPERVISORD_SECONDS="${ON_START_WAIT_SUPERVISORD_SECONDS:-120}"

if [[ ! -x "${DEFAULT_BOOT_SCRIPT}" ]]; then
  echo "[medo] ERROR: ${DEFAULT_BOOT_SCRIPT} not found or not executable" >&2
  exit 1
fi

echo "[medo] Starting default Vast boot flow in background"
"${DEFAULT_BOOT_SCRIPT}" "$@" &
boot_pid=$!

echo "[medo] Waiting for supervisord (max ${ON_START_WAIT_SUPERVISORD_SECONDS}s)"
for ((i=0; i<ON_START_WAIT_SUPERVISORD_SECONDS; i++)); do
  if pgrep -x supervisord >/dev/null 2>&1; then
    echo "[medo] supervisord detected"
    break
  fi
  sleep 1
done

echo "[medo] Running Medo on_start from ${ON_START_URL}"
if ! bash <(curl -fsSL "${ON_START_URL}"); then
  echo "[medo] WARN: on_start failed, continuing base services" >&2
fi

# Keep the container lifecycle tied to the default boot process.
wait "${boot_pid}"

