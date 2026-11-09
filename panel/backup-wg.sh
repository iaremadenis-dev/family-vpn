#!/bin/bash
# Read-only backup of one WireGuard server. It does not stop the interface or edit peers.
set -euo pipefail
umask 077

PANEL_DIR=$(cd "$(dirname "$0")" && pwd)
WG_CONF=${FAMILY_VPN_WG_CONF:-/etc/wireguard/wg0.conf}
AGENT_STATE=${FAMILY_VPN_AGENT_STATE:-/var/lib/family-vpn/agent.json}
UNIT=${FAMILY_VPN_WG_UNIT:-/etc/systemd/system/family-vpn-agent.service}
BACKUP_DIR=${FAMILY_VPN_WG_BACKUP_DIR:-/var/lib/family-vpn/backups/wireguard}
PUB=${FAMILY_VPN_BACKUP_PUB:-/etc/family-vpn/backup.pub}
ENV_FILE=${FAMILY_VPN_BACKUP_ENV:-/etc/family-vpn/backup.env}
STATUS=${FAMILY_VPN_WG_BACKUP_STATUS:-/var/lib/family-vpn/backups/wireguard.status}
AGE=${FAMILY_VPN_AGE:-age}
NODE=${FAMILY_VPN_NODE:-node}
if [ -n "${FAMILY_VPN_PYTHON:-}" ]; then
  PYTHON=$FAMILY_VPN_PYTHON
elif command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
else
  PYTHON=python
fi

node_ok() {
  "$NODE" --input-type=module -e "import 'node:sqlite'" >/dev/null 2>&1
}

archive() {
  if node_ok; then
    "$NODE" "$PANEL_DIR/archive-tool.mjs" "$@"
  else
    "$PYTHON" "$PANEL_DIR/archive_host.py" "$@"
  fi
}

status() {
  mkdir -p "$(dirname "$STATUS")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$STATUS"
  chmod 600 "$STATUS" 2>/dev/null || true
  printf '%s\n' "$*"
}

fail() {
  status "WG_BACKUP_FAIL $*"
  exit 1
}

if [ "${1:-}" = "--install-timer" ]; then
  [ "$(id -u)" -eq 0 ] || fail "ROOT_REQUIRED"
  install -d -m 755 /opt/family-vpn/bin
  install -m 755 "$PANEL_DIR/backup-wg.sh" /opt/family-vpn/bin/backup-wg.sh
  sed "s#__PANEL_DIR__#${PANEL_DIR}#g" "$PANEL_DIR/systemd/family-vpn-wg-backup.service" \
    >/etc/systemd/system/family-vpn-wg-backup.service
  install -m 644 "$PANEL_DIR/systemd/family-vpn-wg-backup.timer" /etc/systemd/system/family-vpn-wg-backup.timer
  systemctl daemon-reload
  systemctl enable --now family-vpn-wg-backup.timer
  status "WG_TIMER_OK"
  exit 0
fi

[ -f "$WG_CONF" ] || fail "WG_CONF_MISSING"
[ -L "$WG_CONF" ] && fail "SYMLINK_REFUSED"
[ -f "$PUB" ] || fail "PUBKEY_MISSING"
grep -q 'AGE-SECRET-KEY-' "$PUB" && fail "PRIVATE_KEY_REFUSED"
command -v "$AGE" >/dev/null 2>&1 || fail "AGE_MISSING"
node_ok || command -v "$PYTHON" >/dev/null 2>&1 || fail "ARCHIVE_TOOL_MISSING"

mkdir -p "$BACKUP_DIR"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$WG_CONF" "$STAGE/wg0.conf"
chmod 600 "$STAGE/wg0.conf" 2>/dev/null || true
if [ -f "$AGENT_STATE" ]; then
  cp "$AGENT_STATE" "$STAGE/agent.json"
  chmod 600 "$STAGE/agent.json" 2>/dev/null || true
fi
if [ -f "$UNIT" ]; then
  cp "$UNIT" "$STAGE/family-vpn-agent.service"
fi
archive wg-manifest "$STAGE" || fail "MANIFEST"
archive wg-verify "$STAGE" >/dev/null || fail "VERIFY"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="$BACKUP_DIR/wg-${stamp}.tar.age"
tar -C "$STAGE" -cf - . | "$AGE" -a -R "$PUB" -o "$ARCHIVE" || fail "AGE_ENCRYPT"
"$PYTHON" -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' \
  "$ARCHIVE" >"$ARCHIVE.sha256"
if [ -f "$ENV_FILE" ]; then
  object="wireguard/$(basename "$ARCHIVE")"
  "$PYTHON" "$PANEL_DIR/s3_store.py" "$ENV_FILE" put "$object" "$ARCHIVE" || fail "UPLOAD_FAIL"
  status "UPLOAD_OK $object"
else
  status "UPLOAD_SKIPPED"
fi
status "WG_BACKUP_OK $(basename "$ARCHIVE")"
