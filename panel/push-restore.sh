#!/bin/bash
# Decrypt a panel archive on the administrator's computer and stream the tar
# over SSH. The age identity is an argument of the local age process only.
set -euo pipefail
umask 077

HOST=""
ARCHIVE=""
IDENTITY=""
EMAIL=""
IP=""
APP=/opt/family-vpn/app
DRY=0
STAGING=0
USE_SUDO=1
AGE=${FAMILY_VPN_AGE:-age}
KEYGEN=${FAMILY_VPN_AGE_KEYGEN:-age-keygen}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=${2:-}; shift 2 ;;
    --archive) ARCHIVE=${2:-}; shift 2 ;;
    --identity) IDENTITY=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --ip) IP=${2:-}; shift 2 ;;
    --app) APP=${2:-}; shift 2 ;;
    --staging) STAGING=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --no-sudo) USE_SUDO=0; shift ;;
    *) die "PUSH_USAGE" ;;
  esac
done

[ -n "$HOST" ] || die "PUSH_USAGE"
[ -n "$EMAIL" ] || die "PUSH_USAGE"
[ -f "$ARCHIVE" ] || die "ARCHIVE_MISSING"
[ -f "$IDENTITY" ] || die "IDENTITY_MISSING"
grep -q 'AGE-SECRET-KEY-' "$IDENTITY" || die "IDENTITY_INVALID"
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
command -v "$KEYGEN" >/dev/null 2>&1 || die "AGE_MISSING"

pubkey=$("$KEYGEN" -y "$IDENTITY" | tr -d '[:space:]')
[[ "$pubkey" =~ ^age1[0-9a-z]+$ ]] || die "PUBKEY_INVALID"

remote=()
if [ "$USE_SUDO" -eq 1 ]; then
  remote+=(sudo)
fi
remote+=(bash "$APP/panel/install-panel.sh" --restore - --decrypted --backup-pubkey "$pubkey" --email "$EMAIL")
if [ -n "$IP" ]; then
  remote+=(--ip "$IP")
fi
if [ "$STAGING" -eq 1 ]; then
  remote+=(--staging)
fi

printf -v remote_text '%q ' "${remote[@]}"
if printf '%s' "$remote_text" | grep -F -q -- "$IDENTITY"; then
  die "KEY_LEAKED"
fi
if printf '%s' "$remote_text" | grep -q 'AGE-SECRET-KEY-'; then
  die "KEY_LEAKED"
fi

if [ "$DRY" -eq 1 ]; then
  printf 'KEY_STAYS_LOCAL\n'
  printf 'REMOTE %s\n' "$remote_text"
  exit 0
fi

"$AGE" -d -i "$IDENTITY" -o - "$ARCHIVE" | ssh "$HOST" "$remote_text"
