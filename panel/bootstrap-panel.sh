#!/bin/bash
# Fetch the private Family VPN repository onto a new Ubuntu VPS and run install-panel.sh.
# GitHub login is interactive (device code). The credential is removed before exit.
# This script does not publish the repository and does not accept a token in its arguments.
set -euo pipefail
umask 077

APP_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=${FAMILY_VPN_REPO:-iaremadenis-dev/family-vpn}
WORKFLOW=${FAMILY_VPN_WORKFLOW:-agent-release.yml}
ARTIFACT=${FAMILY_VPN_ARTIFACT:-family-vpn-agent-0.4.0}
AGENT_VERSION=${FAMILY_VPN_AGENT_VERSION:-0.4.0}
MODE=""
EMAIL=""
PUBKEY=""
ARCHIVE=""
IDENTITY=""
IP=""
STAGING=0
DRY=0
DECRYPTED=0
REAL=0

die() {
  printf '%s\n' "family-vpn-bootstrap: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage:
  bootstrap-panel.sh --new --email you@example.com --backup-pubkey age1... [--ip A.B.C.D]
  bootstrap-panel.sh --restore --archive <tar> --decrypted --email you@example.com --backup-pubkey age1...
  bootstrap-panel.sh --restore --archive <tar.age> --identity <age-key> --email you@example.com
  bootstrap-panel.sh --check
  bootstrap-panel.sh --fetch-only

--new and --restore call panel/install-panel.sh. A restore still needs the backup archive on this server.
The age private key is not part of the --new command.
EOF
}

logout_github() {
  if command -v gh >/dev/null 2>&1; then
    gh auth logout --hostname github.com >/dev/null 2>&1 || true
  fi
  rm -rf "${HOME}/.config/gh"
  if command -v git >/dev/null 2>&1; then
    git credential reject <<'EOF' >/dev/null 2>&1 || true
protocol=https
host=github.com

EOF
  fi
}

cleanup() {
  status=$?
  if [ "$REAL" -eq 1 ]; then
    logout_github
  fi
  exit "$status"
}

assert_ubuntu() {
  [ -r /etc/os-release ] || die "нужна Ubuntu 24.04"
  # shellcheck disable=SC1091
  (
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]
  ) || die "нужна Ubuntu 24.04"
}

refuse_token_env() {
  if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
    die "не передавайте GitHub-токен в команде или окружении; войдите через gh auth login"
  fi
}

install_tools() {
  command -v apt-get >/dev/null 2>&1 || die "нужен apt-get"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl git python3
  if ! command -v gh >/dev/null 2>&1; then
    if ! apt-get install -y gh; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg
      chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg
      printf 'deb [arch=%s signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture)" >/etc/apt/sources.list.d/github-cli.list
      apt-get update -y
      apt-get install -y gh
    fi
  fi
  command -v gh >/dev/null 2>&1 || die "не удалось установить gh"
}

ensure_login() {
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' "family-vpn-bootstrap: подтвердите вход GitHub в браузере. Токен в команду вставлять не нужно."
  gh auth login --hostname github.com --git-protocol https --web
  gh auth status --hostname github.com >/dev/null 2>&1 || die "вход GitHub не выполнен"
}

copy_release_files() {
  local source=$1 name
  install -d -m 755 "$APP_DIR/releases"
  for name in family-vpn-agent-linux-amd64 install.sh SHA256SUMS INSTALL.txt bootstrap.sh; do
    [ -f "$source/$name" ] || return 1
    [ -L "$source/$name" ] && return 1
    install -m 644 "$source/$name" "$APP_DIR/releases/$name" || return 1
  done
  chmod 755 "$APP_DIR/releases/family-vpn-agent-linux-amd64" \
    "$APP_DIR/releases/install.sh" "$APP_DIR/releases/bootstrap.sh"
}

remove_release_files() {
  local name
  for name in family-vpn-agent-linux-amd64 install.sh SHA256SUMS INSTALL.txt bootstrap.sh; do
    rm -f "$APP_DIR/releases/$name"
  done
}

verify_release() {
  (cd "$APP_DIR/releases" && sha256sum -c SHA256SUMS >/dev/null) || return 1
  if [ -f "$APP_DIR/installer/install.sh" ]; then
    cmp -s "$APP_DIR/installer/install.sh" "$APP_DIR/releases/install.sh" || return 1
  fi
  local got
  got=$("$APP_DIR/releases/family-vpn-agent-linux-amd64" --version 2>/dev/null | head -n 1 | tr -d '\r')
  [ "$got" = "$AGENT_VERSION" ]
}

fetch_release() {
  command -v gh >/dev/null 2>&1 || die "нужен gh"
  local run_id dest
  run_id=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch main --limit 20 \
    --json databaseId,status,conclusion \
    --jq '[.[] | select(.status=="completed" and .conclusion=="success")][0].databaseId')
  [ -n "$run_id" ] && [ "$run_id" != "null" ] || die "нет успешного запуска $WORKFLOW на main"
  dest=$(mktemp -d)
  if ! gh run download "$run_id" --repo "$REPO" --name "$ARTIFACT" --dir "$dest"; then
    rm -rf "$dest"
    die "не удалось скачать артефакт $ARTIFACT"
  fi
  local source=$dest dir
  if [ ! -f "$dest/SHA256SUMS" ]; then
    source=""
    for dir in "$dest"/* "$dest"/*/*; do
      [ -d "$dir" ] || continue
      if [ -f "$dir/SHA256SUMS" ]; then
        source=$dir
        break
      fi
    done
  fi
  if ! copy_release_files "$source"; then
    rm -rf "$dest"
    remove_release_files
    die "артефакт не принят"
  fi
  rm -rf "$dest"
  if ! verify_release; then
    remove_release_files
    die "проверка релиза не пройдена"
  fi
  printf '%s\n' "family-vpn-bootstrap: релиз $ARTIFACT проверен"
}

release_ready() {
  local name
  for name in family-vpn-agent-linux-amd64 install.sh SHA256SUMS; do
    [ -f "$APP_DIR/releases/$name" ] || return 1
  done
  verify_release
}

run_installer() {
  local -a cmd
  if [ "$MODE" = "new" ]; then
    cmd=(bash "$APP_DIR/panel/install-panel.sh" --new --email "$EMAIL" --backup-pubkey "$PUBKEY")
  else
    cmd=(bash "$APP_DIR/panel/install-panel.sh" --restore "$ARCHIVE" --email "$EMAIL")
    if [ "$DECRYPTED" -eq 1 ]; then
      cmd+=(--decrypted --backup-pubkey "$PUBKEY")
    else
      cmd+=(--identity "$IDENTITY")
    fi
  fi
  if [ -n "$IP" ]; then
    cmd+=(--ip "$IP")
  fi
  if [ "$STAGING" -eq 1 ]; then
    cmd+=(--staging)
  fi
  "${cmd[@]}"
}

print_wireguard_command() {
  local sums="$APP_DIR/releases/SHA256SUMS" env_file=/etc/family-vpn/panel.env sha url
  [ -f "$sums" ] && [ -f "$env_file" ] || return 0
  sha=$(awk '$2 == "install.sh" { print $1; exit }' "$sums")
  url=$(awk -F= '$1 == "FAMILY_VPN_PUBLIC_URL" { print $2; exit }' "$env_file")
  [ -n "$sha" ] && [ -n "$url" ] || return 0
  printf '%s\n' "КОМАНДА WIREGUARD"
  printf '%s\n' "curl -fsSL ${url}/releases/install.sh -o /tmp/fvpn-install.sh && echo '${sha}  /tmp/fvpn-install.sh' | sha256sum -c - && sudo bash /tmp/fvpn-install.sh --backend ${url}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --new) MODE=new; shift ;;
    --restore) MODE=restore; shift ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --backup-pubkey) PUBKEY=${2:-}; shift 2 ;;
    --archive) ARCHIVE=${2:-}; shift 2 ;;
    --identity) IDENTITY=${2:-}; shift 2 ;;
    --ip) IP=${2:-}; shift 2 ;;
    --staging) STAGING=1; shift ;;
    --decrypted) DECRYPTED=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --check) MODE=check; shift ;;
    --fetch-only) MODE=fetch; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[ -n "$MODE" ] || die "укажите --new, --restore, --check или --fetch-only"
refuse_token_env

if [ "$MODE" = "check" ]; then
  bash "$APP_DIR/panel/install-panel.sh" --check
  grep -q 'sha256sum -c' "$APP_DIR/panel/bootstrap-panel.sh"
  grep -q 'auth logout' "$APP_DIR/panel/bootstrap-panel.sh"
  grep -q 'install-panel.sh' "$APP_DIR/panel/bootstrap-panel.sh"
  printf '%s\n' "BOOTSTRAP_CHECK_OK"
  exit 0
fi

if [ "$MODE" = "fetch" ]; then
  fetch_release
  printf '%s\n' "FETCH_OK"
  exit 0
fi

if [ "$MODE" = "new" ]; then
  [ -n "$EMAIL" ] || die "укажите --email"
  [ -n "$PUBKEY" ] || die "укажите --backup-pubkey"
  if printf '%s' "$PUBKEY" | grep -q 'AGE-SECRET-KEY-'; then
    die "PRIVATE_KEY_REFUSED"
  fi
elif [ "$MODE" = "restore" ]; then
  [ -n "$ARCHIVE" ] || die "укажите --archive: восстановление без файла архива невозможно"
  if [ "$ARCHIVE" = "-" ]; then
    [ "$DECRYPTED" -eq 1 ] || die "архив из stdin только вместе с --decrypted"
  elif [ ! -f "$ARCHIVE" ]; then
    die "ARCHIVE_MISSING"
  fi
  [ -n "$EMAIL" ] || die "укажите --email"
  if [ "$DECRYPTED" -eq 1 ]; then
    [ -n "$PUBKEY" ] || die "укажите --backup-pubkey"
  else
    [ -n "$IDENTITY" ] || die "укажите --identity или --decrypted"
    [ -f "$IDENTITY" ] || die "IDENTITY_MISSING"
  fi
else
  die "укажите --new или --restore"
fi

if [ "$DRY" -eq 1 ]; then
  printf '%s\n' "BOOTSTRAP_DRY_RUN"
  printf '%s\n' "AUTH device-login"
  printf '%s\n' "VERIFY sha256sum"
  printf '%s\n' "LOGOUT"
  if [ "$MODE" = "new" ]; then
    printf '%s\n' "RUN install-panel.sh --new"
  else
    printf '%s\n' "RUN install-panel.sh --restore"
    printf '%s\n' "ARCHIVE_REQUIRED"
  fi
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "запустите от root"
REAL=1
trap cleanup EXIT
assert_ubuntu
if [ -f /var/lib/family-vpn/panel/family-vpn.sqlite ] || [ -f /var/lib/family-vpn/panel/master.key ]; then
  die "DATA_EXISTS: база панели уже есть. Повторная установка её не изменяет."
fi
install_tools
ensure_login
if ! release_ready; then
  fetch_release
fi
logout_github
run_installer
print_wireguard_command
