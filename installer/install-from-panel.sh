#!/bin/bash
# Download the WireGuard installer from an already installed Family VPN panel and check it
# against that panel's SHA256SUMS before running it. Does not install the admin panel.
set -euo pipefail
umask 077

BACKEND=""
UPDATE=0

die() {
  printf '%s\n' "family-vpn-install: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: install-from-panel.sh --backend https://panel.example.com [--update]

The panel address is the HTTPS origin printed by the panel installer.
Plain HTTP is accepted only for 127.0.0.1 and localhost.
EOF
}

validate_backend() {
  case "$BACKEND" in
    *[@?#]*) die "недопустимый адрес панели" ;;
  esac
  local rest=${BACKEND#*://}
  case "$rest" in
    */*) die "адрес панели не должен содержать путь" ;;
  esac
  case "$BACKEND" in
    https://)
      die "пустой адрес панели"
      ;;
    https://*)
      ;;
    http://127.0.0.1|http://127.0.0.1:*|http://localhost|http://localhost:*)
      ;;
    http://*)
      die "plain HTTP is only allowed for 127.0.0.1 or localhost"
      ;;
    *)
      die "адрес панели должен начинаться с https://"
      ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --backend)
      BACKEND=${2:-}
      shift 2
      ;;
    --update)
      UPDATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "неизвестный аргумент: $1"
      ;;
  esac
done

[ -n "$BACKEND" ] || die "укажите --backend"
validate_backend

tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

curl -fsSL "$BACKEND/releases/SHA256SUMS" -o "$tmp/SHA256SUMS"
curl -fsSL "$BACKEND/releases/install.sh" -o "$tmp/install.sh"
want=$(awk '$2 == "install.sh" { print $1; exit }' "$tmp/SHA256SUMS")
[ -n "$want" ] || die "в SHA256SUMS нет install.sh"
printf '%s  %s\n' "$want" "$tmp/install.sh" | sha256sum -c -

args=(--backend "$BACKEND")
if [ "$UPDATE" -eq 1 ]; then
  args+=(--update)
fi
bash "$tmp/install.sh" "${args[@]}"
