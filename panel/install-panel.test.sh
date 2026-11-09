#!/bin/bash
# Local checks for the panel installer. Does not install packages or contact a VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/panel/install-panel.sh"

bash -n "$INSTALL"
bash -n "$ROOT/panel/renew-cert.sh"
bash "$INSTALL" --check
grep -q 'renew_before_expiry = 2 days' "$INSTALL"
grep -q -- '--cert-name' "$ROOT/panel/renew-cert.sh"
grep -q 'checkend 172800' "$ROOT/panel/renew-cert.sh"
grep -q 'caddy reload' "$ROOT/panel/renew-cert.sh"

if grep -E 'wg-quick|iptables|nft |ufw |systemctl (stop|restart|disable)|set -x' "$INSTALL" "$ROOT/panel/renew-cert.sh"; then
  echo "installer contains a forbidden mutation or a trace flag" >&2
  exit 1
fi

if grep -E 'ghp_|github_pat_|BEGIN .*PRIVATE KEY|AKIA[0-9A-Z]{16}' \
  "$INSTALL" "$ROOT/panel/renew-cert.sh" "$ROOT/panel/docker-compose.yml" \
  "$ROOT/panel/Caddyfile.bootstrap" "$ROOT/panel/Caddyfile.https"; then
  echo "installer tree contains a secret" >&2
  exit 1
fi

out=$(mktemp -d)

set +e
bash "$INSTALL" --new --ip 10.1.2.3 --email admin@example.com --dry-run >"$out/private" 2>"$out/private.err"
private_code=$?
set -e
[ "$private_code" -ne 0 ]
grep -q 'PRIVATE_IP' "$out/private.err"

set +e
bash "$INSTALL" --new --ip 203.0.113.5 --email admin@example.com --password hunter2 --dry-run \
  >"$out/password" 2>"$out/password.err"
password_code=$?
set -e
[ "$password_code" -ne 0 ]
grep -q 'пароль администратора' "$out/password.err"

data=$(mktemp -d)
touch "$data/family-vpn.sqlite"
printf 'not-a-secret\n' >"$data/master.key"
set +e
FAMILY_VPN_PANEL_DIR="$data" bash "$INSTALL" --new --ip 203.0.113.5 --email admin@example.com --dry-run \
  >"$out/exists" 2>"$out/exists.err"
exists_code=$?
set -e
[ "$exists_code" -eq 3 ]
grep -q 'DATA_EXISTS' "$out/exists"
test -f "$data/family-vpn.sqlite"
test -f "$data/master.key"
set +e
FAMILY_VPN_PANEL_DIR="$data" bash "$INSTALL" --new --ip 203.0.113.5 --email admin@example.com --dry-run \
  >"$out/exists-2" 2>"$out/exists-2.err"
exists_again=$?
set -e
[ "$exists_again" -eq 3 ]
test -f "$data/family-vpn.sqlite"
test -f "$data/master.key"

empty=$(mktemp -d)
FAMILY_VPN_PANEL_DIR="$empty" bash "$INSTALL" --new --ip 203.0.113.5 --email admin@example.com --dry-run \
  >"$out/ok"
grep -q 'DRY_RUN_OK' "$out/ok"
test ! -e "$empty/family-vpn.sqlite"

set +e
bash "$INSTALL" --restore /tmp/family-vpn-not-there.tar.age >"$out/restore" 2>"$out/restore.err"
restore_code=$?
set -e
[ "$restore_code" -eq 2 ]
grep -q 'RESTORE_LATER' "$out/restore"
test ! -e /tmp/family-vpn-not-there.tar.age

rm -rf "$data" "$empty" "$out"

echo "panel installer checks ok"
