#!/bin/bash
# Encrypt a consistent panel snapshot. The private age key is never on this host.
set -euo pipefail
umask 077

PANEL_DIR=$(cd "$(dirname "$0")" && pwd)
STATE_DIR=${FAMILY_VPN_PANEL_DIR:-/var/lib/family-vpn/panel}
BACKUP_DIR=${FAMILY_VPN_BACKUP_DIR:-/var/lib/family-vpn/backups/panel}
PUB=${FAMILY_VPN_BACKUP_PUB:-/etc/family-vpn/backup.pub}
ENV_FILE=${FAMILY_VPN_BACKUP_ENV:-/etc/family-vpn/backup.env}
PANEL_ENV=${FAMILY_VPN_PANEL_ENV:-/etc/family-vpn/panel.env}
STATUS=${FAMILY_VPN_BACKUP_STATUS:-/var/lib/family-vpn/backups/panel.status}
LOG=${FAMILY_VPN_BACKUP_LOG:-/var/lib/family-vpn/backups/panel.log}
MAX_AGE_HOURS=${FAMILY_VPN_BACKUP_MAX_AGE_HOURS:-26}
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
  mkdir -p "$(dirname "$STATUS")" "$(dirname "$LOG")"
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  printf '%s\n' "$line" >>"$STATUS"
  printf '%s\n' "$line" >>"$LOG"
  chmod 600 "$STATUS" "$LOG" 2>/dev/null || true
  printf '%s\n' "$*"
}

fail() {
  status "BACKUP_FAIL $*"
  exit 1
}

check_age() {
  [ -f "$STATUS" ] || {
    status "OFFSITE_UNCONFIGURED"
    exit 4
  }
  set +e
  "$PYTHON" -c 'import datetime, pathlib, sys
path, hours = pathlib.Path(sys.argv[1]), float(sys.argv[2])
last = None
skipped = False
for line in path.read_text(encoding="utf-8").splitlines():
    parts = line.split()
    if len(parts) < 2:
        continue
    if parts[1] == "UPLOAD_OK":
        last = parts[0]
    if parts[1] == "UPLOAD_SKIPPED":
        skipped = True
if last is None:
    raise SystemExit(5 if skipped else 4)
stamp = datetime.datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
age = datetime.datetime.now(datetime.timezone.utc) - stamp
raise SystemExit(0 if age.total_seconds() <= hours * 3600 else 4)
' "$STATUS" "$MAX_AGE_HOURS"
  code=$?
  set -e
  if [ "$code" -eq 0 ]; then
    status "AGE_OK"
    exit 0
  fi
  if [ "$code" -eq 5 ]; then
    status "OFFSITE_UNCONFIGURED"
    exit 4
  fi
  status "OFFSITE_STALE"
  exit 4
}

if [ "${1:-}" = "--check-age" ]; then
  check_age
fi

command -v "$AGE" >/dev/null 2>&1 || fail "AGE_MISSING"
node_ok || command -v "$PYTHON" >/dev/null 2>&1 || fail "ARCHIVE_TOOL_MISSING"
[ -f "$PUB" ] || fail "PUBKEY_MISSING"
if grep -q 'AGE-SECRET-KEY-' "$PUB"; then
  fail "PRIVATE_KEY_REFUSED"
fi
pub=$(tr -d '[:space:]' <"$PUB")
[[ "$pub" =~ ^age1[0-9a-z]+$ ]] || fail "PUBKEY_INVALID"
[ -f "$STATE_DIR/family-vpn.sqlite" ] || fail "SQLITE_MISSING"
if [ -L "$STATE_DIR/family-vpn.sqlite" ] || [ -L "$STATE_DIR/master.key" ]; then
  fail "SYMLINK_REFUSED"
fi

mkdir -p "$BACKUP_DIR"
LOCK="$BACKUP_DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  status "BACKUP_BUSY"
  exit 0
fi
STAGE=$(mktemp -d)
cleanup() {
  rmdir "$LOCK" 2>/dev/null || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

mkdir -p "$STAGE/payload"
archive snapshot "$STATE_DIR/family-vpn.sqlite" "$STAGE/payload/family-vpn.sqlite" \
  || fail "SNAPSHOT"
if [ -f "$STATE_DIR/master.key" ]; then
  cp -p "$STATE_DIR/master.key" "$STAGE/payload/master.key"
  chmod 600 "$STAGE/payload/master.key" 2>/dev/null || true
fi
if [ -f "$PANEL_ENV" ]; then
  cp -p "$PANEL_ENV" "$STAGE/payload/panel.env"
  chmod 600 "$STAGE/payload/panel.env" 2>/dev/null || true
fi
archive manifest "$STAGE/payload" || fail "MANIFEST"
archive verify "$STAGE/payload" >/dev/null || fail "VERIFY"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="$BACKUP_DIR/panel-${stamp}.tar.age"
tar -C "$STAGE/payload" -cf - . | "$AGE" -a -R "$PUB" -o "$ARCHIVE" || fail "AGE_ENCRYPT"
head -n 1 "$ARCHIVE" | grep -q 'BEGIN AGE ENCRYPTED FILE' || fail "AGE_OUTPUT"
"$PYTHON" -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' \
  "$ARCHIVE" >"$ARCHIVE.sha256"

if [ -f "$ENV_FILE" ]; then
  mode=$(stat -c %a "$ENV_FILE" 2>/dev/null || true)
  if [ -n "$mode" ] && [ "${mode: -1}" != "0" ]; then
    fail "S3_PERMS"
  fi
  object="panel/$(basename "$ARCHIVE")"
  "$PYTHON" "$PANEL_DIR/s3_store.py" "$ENV_FILE" put "$object" "$ARCHIVE" || fail "UPLOAD_FAIL"
  "$PYTHON" "$PANEL_DIR/s3_store.py" "$ENV_FILE" put "${object}.sha256" "$ARCHIVE.sha256" || fail "UPLOAD_FAIL"
  status "UPLOAD_OK $object"
else
  status "UPLOAD_SKIPPED"
fi
status "BACKUP_OK $(basename "$ARCHIVE")"

shopt -s nullglob
kept=0
for file in $(ls -1t "$BACKUP_DIR"/panel-*.tar.age 2>/dev/null); do
  kept=$((kept + 1))
  if [ "$kept" -gt 14 ]; then
    rm -f "$file" "$file.sha256"
  fi
done
