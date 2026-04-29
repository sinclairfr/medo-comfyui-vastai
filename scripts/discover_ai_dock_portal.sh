#!/usr/bin/env bash
set -Eeuo pipefail

echo "== supervisorctl status =="
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl status || true
else
  echo "supervisorctl not found"
fi

echo
echo "== listening ports =="
(ss -lntup || netstat -tulpn) 2>/dev/null || true

echo
echo "== /run/http_ports =="
if [[ -f /run/http_ports ]]; then
  cat /run/http_ports
else
  echo "/run/http_ports not present"
fi

echo
echo "== ai-dock references =="
if [[ -d /opt/ai-dock ]]; then
  rg -n "portal|service|http_ports|caddy" /opt/ai-dock || true
else
  echo "/opt/ai-dock not present"
fi

echo
echo "== caddy config =="
for c in /etc/caddy/Caddyfile /opt/ai-dock/**/Caddyfile /opt/ai-dock/**/caddy*.json; do
  if [[ -f "$c" ]]; then
    echo "--- $c ---"
    sed -n '1,200p' "$c"
  fi
done
