#!/bin/bash
# Restore a panel archive into an empty directory. Does not start WireGuard or issue TLS.
set -euo pipefail
umask 077

PANEL_DIR=$(cd "$(dirname "$0")" && pwd)
ARCHIVE=""
IDENTITY=""
INTO=""
PAYLOAD=""
S3_ENV=${FAMILY_VPN_BACKUP_ENV:-/etc/family-vpn/backup.env}
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

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --archive)
      ARCHIVE=${2:-}
      shift 2
      ;;
    --identity)
      IDENTITY=${2:-}
      shift 2
      ;;
    --into)
      INTO=${2:-}
      shift 2
      ;;
    --s3-env)
      S3_ENV=${2:-}
      shift 2
      ;;
    --payload)
      PAYLOAD=${2:-}
      shift 2
      ;;
    *)
      die "RESTORE_USAGE"
      ;;
  esac
done

[ -n "$INTO" ] || die "RESTORE_USAGE"
if [ -n "$PAYLOAD" ]; then
  [ -z "$IDENTITY" ] || die "KEY_STAYS_LOCAL"
else
  [ -n "$ARCHIVE" ] && [ -n "$IDENTITY" ] || die "RESTORE_USAGE"
  [ -f "$IDENTITY" ] || die "IDENTITY_MISSING"
  if grep -q 'AGE-SECRET-KEY-' "$IDENTITY"; then
    :
  else
    die "IDENTITY_INVALID"
  fi
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
      mode=$(stat -c %a "$IDENTITY" 2>/dev/null || true)
      if [ -n "$mode" ] && { [ "${mode: -1}" != "0" ] || [ "${mode: -2:1}" != "0" ]; }; then
        die "IDENTITY_PERMS"
      fi
      ;;
  esac
  command -v "$AGE" >/dev/null 2>&1 || die "AGE_MISSING"
fi
node_ok || command -v "$PYTHON" >/dev/null 2>&1 || die "ARCHIVE_TOOL_MISSING"

STAGE=$(mktemp -d)
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

if [ -n "$PAYLOAD" ]; then
  if [ "$PAYLOAD" = "-" ]; then
    cat >"$STAGE/payload.tar"
  else
    [ -f "$PAYLOAD" ] || die "ARCHIVE_MISSING"
    cp "$PAYLOAD" "$STAGE/payload.tar"
  fi
else
  LOCAL="$ARCHIVE"
  if [[ "$ARCHIVE" == s3://* ]]; then
    [ -f "$S3_ENV" ] || die "S3_CONFIG_MISSING"
    rest=${ARCHIVE#s3://}
    bucket=${rest%%/*}
    key=${rest#*/}
    file_bucket=$("$PYTHON" -c 'import pathlib,sys
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.startswith("S3_BUCKET="):
        print(line.split("=",1)[1].strip())
' "$S3_ENV")
    [ "$bucket" = "$file_bucket" ] || die "S3_BUCKET_MISMATCH"
    LOCAL="$STAGE/download.tar.age"
    "$PYTHON" "$PANEL_DIR/s3_store.py" "$S3_ENV" get "$key" "$LOCAL" || die "DOWNLOAD_FAIL"
  fi
  [ -f "$LOCAL" ] || die "ARCHIVE_MISSING"
  if ! "$AGE" -d -i "$IDENTITY" -o "$STAGE/payload.tar" "$LOCAL" 2>"$STAGE/age.err"; then
    die "DECRYPT_FAIL"
  fi
fi
mkdir -p "$STAGE/out"
if tar -tf "$STAGE/payload.tar" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  die "TAR_UNSAFE"
fi
tar -C "$STAGE/out" -xf "$STAGE/payload.tar"
rm -f "$STAGE/payload.tar"
for name in "$STAGE/out"/*; do
  base=$(basename "$name")
  case "$base" in
    manifest.json|family-vpn.sqlite|master.key|panel.env) ;;
    *) die "TAR_UNEXPECTED" ;;
  esac
done
if ! archive verify "$STAGE/out" >"$STAGE/verify.out" 2>"$STAGE/verify.err"; then
  token=$(tail -n 1 "$STAGE/verify.err" 2>/dev/null || true)
  die "${token:-VERIFY_FAIL}"
fi

same_file() {
  [ -f "$1" ] && [ -f "$2" ] || return 1
  "$PYTHON" -c 'import hashlib, pathlib, sys
def h(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
raise SystemExit(0 if h(sys.argv[1]) == h(sys.argv[2]) else 1)
' "$1" "$2"
}

if [ -e "$INTO/family-vpn.sqlite" ] || [ -e "$INTO/master.key" ]; then
  ok=1
  same_file "$STAGE/out/family-vpn.sqlite" "$INTO/family-vpn.sqlite" || ok=0
  if [ -f "$STAGE/out/master.key" ] || [ -f "$INTO/master.key" ]; then
    same_file "$STAGE/out/master.key" "$INTO/master.key" || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    printf '%s\n' "RESTORE_SAME"
    exit 0
  fi
  printf '%s\n' "DATA_EXISTS" >&2
  exit 3
fi

mkdir -p "$INTO"
incoming="$INTO/.incoming"
rm -rf "$incoming"
mkdir -m 700 "$incoming"
cp "$STAGE/out/family-vpn.sqlite" "$incoming/family-vpn.sqlite"
if [ -f "$STAGE/out/master.key" ]; then
  cp "$STAGE/out/master.key" "$incoming/master.key"
fi
if [ -f "$STAGE/out/panel.env" ]; then
  cp "$STAGE/out/panel.env" "$incoming/panel.env.previous"
fi

rollback() {
  rm -f "$INTO/family-vpn.sqlite" "$INTO/master.key" "$INTO/panel.env.previous"
  rm -rf "$incoming"
}

if [ "${FAMILY_VPN_RESTORE_FAIL_AFTER:-}" = "sqlite" ]; then
  mv "$incoming/family-vpn.sqlite" "$INTO/family-vpn.sqlite"
  rollback
  die "RESTORE_ROLLBACK"
fi

mv "$incoming/family-vpn.sqlite" "$INTO/family-vpn.sqlite"
if [ -f "$incoming/master.key" ]; then
  if ! mv "$incoming/master.key" "$INTO/master.key"; then
    rollback
    die "RESTORE_ROLLBACK"
  fi
fi
if [ -f "$incoming/panel.env.previous" ]; then
  mv "$incoming/panel.env.previous" "$INTO/panel.env.previous" || true
fi
rmdir "$incoming" 2>/dev/null || rm -rf "$incoming"
chmod 600 "$INTO/family-vpn.sqlite" "$INTO/master.key" "$INTO/panel.env.previous" 2>/dev/null || true
if [ "$(id -u)" -eq 0 ]; then
  chown 1001:1001 "$INTO" "$INTO/family-vpn.sqlite" "$INTO/master.key" 2>/dev/null || true
  chmod 700 "$INTO" 2>/dev/null || true
fi
printf '%s\n' "RESTORE_OK"
