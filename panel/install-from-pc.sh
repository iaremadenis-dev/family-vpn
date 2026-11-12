#!/bin/bash
# Run on the administrator's computer.
# Copies the committed repository to a new Ubuntu 24.04 VPS and installs the panel.
# Type the SSH password in this terminal. No GitHub token is used.
# The age private key never leaves this computer.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=""
HOST=""
EMAIL=""
PUBKEY=""
ARCHIVE=""
IDENTITY=""
IP=""
STAGING=0
DRY=0

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --new) MODE=new; shift ;;
    --restore) MODE=restore; shift ;;
    --host) HOST=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --backup-pubkey) PUBKEY=${2:-}; shift 2 ;;
    --archive) ARCHIVE=${2:-}; shift 2 ;;
    --identity) IDENTITY=${2:-}; shift 2 ;;
    --ip) IP=${2:-}; shift 2 ;;
    --staging) STAGING=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) die "usage: install-from-pc.sh --host root@IP --email you@example.com --backup-pubkey age1..." ;;
  esac
done

[ -n "$MODE" ] || MODE=new
[ -n "$HOST" ] || die "укажите --host root@IP"
[ -n "$EMAIL" ] || die "укажите --email"
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "адрес --email выглядит неверно"
if [ "$MODE" = "new" ]; then
  [ -n "$PUBKEY" ] || die "укажите --backup-pubkey"
  printf '%s' "$PUBKEY" | grep -q 'AGE-SECRET-KEY-' && die "PRIVATE_KEY_REFUSED"
  [[ "$PUBKEY" =~ ^age1[0-9a-z]+$ ]] || die "PUBKEY_INVALID"
elif [ "$MODE" = "restore" ]; then
  [ -n "$ARCHIVE" ] || die "укажите --archive"
  [ -f "$ARCHIVE" ] || die "ARCHIVE_MISSING"
  [ -n "$IDENTITY" ] || die "укажите --identity"
  [ -f "$IDENTITY" ] || die "IDENTITY_MISSING"
  grep -q 'AGE-SECRET-KEY-' "$IDENTITY" || die "IDENTITY_INVALID"
else
  die "укажите --new или --restore"
fi
case "$HOST" in
  *@*) ;;
  *) HOST="root@${HOST}" ;;
esac

grep -q 'default_sni __PANEL_IP__' "$ROOT/panel/Caddyfile.https" || die "в шаблоне Caddy нет default_sni"
grep -q '^https://__PANEL_IP__ {$' "$ROOT/panel/Caddyfile.https" || die "сайт Caddy должен быть https://IP"

if [ "$MODE" = "new" ]; then
  remote=(bash /opt/family-vpn/app/panel/install-panel.sh --new --email "$EMAIL" --backup-pubkey "$PUBKEY")
else
  remote=(bash /opt/family-vpn/app/panel/install-panel.sh --restore - --decrypted --backup-pubkey "$PUBKEY" --email "$EMAIL")
fi
if [ -n "$IP" ]; then
  remote+=(--ip "$IP")
fi
if [ "$STAGING" -eq 1 ]; then
  remote+=(--staging)
fi
if [[ "$HOST" != root@* ]]; then
  remote=(sudo -H "${remote[@]}")
fi
printf -v remote_text '%q ' "${remote[@]}"

if [ "$DRY" -eq 1 ]; then
  printf 'PASSWORD_IN_TERMINAL\n'
  printf 'SHIP git-archive\n'
  if [ "$MODE" = "new" ]; then
    printf 'SHIP releases\n'
  fi
  if [ "$MODE" = "restore" ]; then
    printf 'KEY_STAYS_LOCAL\n'
    if printf '%s' "$remote_text" | grep -F -q -- "$IDENTITY"; then
      die "KEY_LEAKED"
    fi
    if printf '%s' "$remote_text" | grep -q 'AGE-SECRET-KEY-'; then
      die "KEY_LEAKED"
    fi
  fi
  printf 'REMOTE %s\n' "$remote_text"
  exit 0
fi

command -v git >/dev/null 2>&1 || die "нужен git"
command -v ssh >/dev/null 2>&1 || die "нужен ssh"
command -v tar >/dev/null 2>&1 || die "нужен tar"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null
if [ -n "$(git -C "$ROOT" status --porcelain -- panel Dockerfile)" ]; then
  die "сначала закоммитьте установщик: на VPS уходит только зафиксированный HEAD"
fi

archive=$(mktemp)
ctl=${TMPDIR:-/tmp}/fvpn-ssh-$$
master=0
cleanup() {
  rm -f "$archive"
  if [ "$master" -eq 1 ]; then
    ssh "${ssh_opts[@]}" -O exit "$HOST" >/dev/null 2>&1 || true
    rm -f "$ctl"
  fi
}
trap cleanup EXIT

git -C "$ROOT" archive --format=tar HEAD >"$archive"
ssh_opts=(-o StrictHostKeyChecking=accept-new)
set +e
ssh "${ssh_opts[@]}" -o ControlMaster=auto -o ControlPersist=300 -o "ControlPath=${ctl}" -fN "$HOST"
opened=$?
set -e
if [ "$opened" -eq 0 ]; then
  master=1
  ssh_opts+=(-o "ControlPath=${ctl}" -o ControlMaster=auto)
fi

ssh "${ssh_opts[@]}" "$HOST" "mkdir -p /opt/family-vpn/app"
ssh "${ssh_opts[@]}" "$HOST" "tar -x -C /opt/family-vpn/app" <"$archive"
if [ "$MODE" = "new" ]; then
  release_names=(family-vpn-agent-linux-amd64 install.sh SHA256SUMS INSTALL.txt bootstrap.sh)
  for name in "${release_names[@]}"; do
    [ -f "$ROOT/releases/$name" ] || die "нет releases/$name. Сначала: powershell -File scripts/fetch-agent-release.ps1"
  done
  ssh "${ssh_opts[@]}" "$HOST" "mkdir -p /opt/family-vpn/app/releases"
  tar -C "$ROOT/releases" -cf - "${release_names[@]}" | ssh "${ssh_opts[@]}" "$HOST" "tar -x -C /opt/family-vpn/app/releases"
fi
if [ "$MODE" = "restore" ]; then
  command -v age >/dev/null 2>&1 || die "нужен age"
  command -v age-keygen >/dev/null 2>&1 || die "нужен age-keygen"
  PUBKEY=$(age-keygen -y "$IDENTITY" | tr -d '[:space:]')
  [[ "$PUBKEY" =~ ^age1[0-9a-z]+$ ]] || die "PUBKEY_INVALID"
  remote=(bash /opt/family-vpn/app/panel/install-panel.sh --restore - --decrypted --backup-pubkey "$PUBKEY" --email "$EMAIL")
  if [ -n "$IP" ]; then
    remote+=(--ip "$IP")
  fi
  if [ "$STAGING" -eq 1 ]; then
    remote+=(--staging)
  fi
  if [[ "$HOST" != root@* ]]; then
    remote=(sudo -H "${remote[@]}")
  fi
  printf -v remote_text '%q ' "${remote[@]}"
  if printf '%s' "$remote_text" | grep -F -q -- "$IDENTITY"; then
    die "KEY_LEAKED"
  fi
  if printf '%s' "$remote_text" | grep -q 'AGE-SECRET-KEY-'; then
    die "KEY_LEAKED"
  fi
  # The archive is decrypted here. The private key is an argument of the local age process.
  age -d -i "$IDENTITY" -o - "$ARCHIVE" | ssh "${ssh_opts[@]}" "$HOST" "$remote_text"
else
  # A terminal is required so the activation code is shown here and is not copied into a log.
  ssh -t "${ssh_opts[@]}" "$HOST" "$remote_text"
fi
