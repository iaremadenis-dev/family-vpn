#!/bin/bash
# Restore a WireGuard archive into an empty directory. It does not start the interface.
set -euo pipefail
umask 077

PANEL_DIR=$(cd "$(dirname "$0")" && pwd)
ARCHIVE=""
IDENTITY=""
INTO=""
AGE=${FAMILY_VPN_AGE:-age}
NODE=${FAMILY_VPN_NODE:-node}

node_ok() {
  "$NODE" --input-type=module -e "import 'node:sqlite'" >/dev/null 2>&1
}

archive() {
  if node_ok; then
    "$NODE" "$PANEL_DIR/archive-tool.mjs" "$@"
  else
    PYTHON=${FAMILY_VPN_PYTHON:-python3}
    "$PYTHON" "$PANEL_DIR/archive_host.py" "$@"
  fi
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --archive) ARCHIVE=${2:-}; shift 2 ;;
    --identity) IDENTITY=${2:-}; shift 2 ;;
    --into) INTO=${2:-}; shift 2 ;;
    *) die "WG_RESTORE_USAGE" ;;
  esac
done

[ -n "$ARCHIVE" ] && [ -n "$IDENTITY" ] && [ -n "$INTO" ] || die "WG_RESTORE_USAGE"
[ -f "$ARCHIVE" ] || die "ARCHIVE_MISSING"
[ -f "$IDENTITY" ] || die "IDENTITY_MISSING"
grep -q 'AGE-SECRET-KEY-' "$IDENTITY" || die "IDENTITY_INVALID"
command -v "$AGE" >/dev/null 2>&1 || die "AGE_MISSING"

if [ -e "$INTO/wg0.conf" ] || [ -e "$INTO/agent.json" ]; then
  die "DATA_EXISTS"
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/out"
if ! "$AGE" -d -i "$IDENTITY" -o "$STAGE/payload.tar" "$ARCHIVE" 2>/dev/null; then
  die "DECRYPT_FAIL"
fi
if tar -tf "$STAGE/payload.tar" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  die "TAR_UNSAFE"
fi
tar -C "$STAGE/out" -xf "$STAGE/payload.tar"
archive wg-verify "$STAGE/out" >/dev/null || die "VERIFY_FAIL"
mkdir -p "$INTO"
cp "$STAGE/out/wg0.conf" "$INTO/wg0.conf"
chmod 600 "$INTO/wg0.conf" 2>/dev/null || true
if [ -f "$STAGE/out/agent.json" ]; then
  cp "$STAGE/out/agent.json" "$INTO/agent.json"
  chmod 600 "$INTO/agent.json" 2>/dev/null || true
fi
if [ -f "$STAGE/out/family-vpn-agent.service" ]; then
  cp "$STAGE/out/family-vpn-agent.service" "$INTO/family-vpn-agent.service"
fi
printf '%s\n' "WG_RESTORE_OK"
