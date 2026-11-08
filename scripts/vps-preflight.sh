#!/bin/bash
# Read-only checks before attaching Family VPN Agent to an already configured VPS.
# Does not install packages, change WireGuard, or contact the panel unless --backend is set.
set -euo pipefail

BACKEND=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend) BACKEND=${2:-}; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "== OS =="
. /etc/os-release
echo "ID=$ID VERSION_ID=$VERSION_ID"
[ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ] || echo "WARN: Ubuntu 24.04 expected"

echo "== WireGuard =="
if [ -f /etc/wireguard/wg0.conf ]; then
  echo "wg0.conf: present"
  # Never print private keys.
  awk '
    BEGIN { ignore = 0 }
    tolower($1) ~ /^privatekey/ { next }
    { print }
  ' /etc/wireguard/wg0.conf | sed 's/\r$//'
else
  echo "wg0.conf: missing"
fi

if command -v wg >/dev/null; then
  wg show wg0 || echo "wg0 interface is not up"
else
  echo "wg command not found"
fi

echo "== Network =="
ip -4 route show default || true
ss -uln | awk 'NR==1 || /:51820/' || true

echo "== Backup suggestion =="
echo "Before install: sudo cp -a /etc/wireguard /root/wireguard-backup-\$(date -u +%Y%m%dT%H%M%SZ)"

if [ -n "$BACKEND" ]; then
  echo "== Panel =="
  curl -fsSIL "${BACKEND%/}/releases/SHA256SUMS" >/dev/null
  echo "releases endpoint reachable"
fi

echo "preflight finished; no changes were made"
