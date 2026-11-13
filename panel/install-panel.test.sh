#!/bin/bash
# Local checks for the panel installer. Does not install packages or contact a VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/panel/install-panel.sh"
PUB=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

bash -n "$INSTALL"
grep -q 'install -o 1001 -g 1001 -m 600' "$INSTALL"
bash -n "$ROOT/panel/install-from-pc.sh"
bash -n "$ROOT/panel/bootstrap-panel.sh"
bash -n "$ROOT/installer/install-from-panel.sh"
bash -n "$ROOT/panel/renew-cert.sh"
bash -n "$ROOT/panel/push-restore.sh"
bash -n "$ROOT/panel/restore-panel.sh"
bash -n "$ROOT/panel/restore-wg.sh"
bash "$INSTALL" --check
grep -q 'renew_before_expiry = 2 days' "$INSTALL"
grep -q -- '--cert-name' "$ROOT/panel/renew-cert.sh"
grep -q 'checkend 172800' "$ROOT/panel/renew-cert.sh"
grep -q 'caddy reload --address 127.0.0.1:2019' "$ROOT/panel/renew-cert.sh"
grep -q 'caddy reload --address 127.0.0.1:2019' "$INSTALL"
grep -q 'admin 127.0.0.1:2019' "$ROOT/panel/Caddyfile.bootstrap"
grep -q 'admin 127.0.0.1:2019' "$ROOT/panel/Caddyfile.https"
grep -q 'default_sni __PANEL_IP__' "$ROOT/panel/Caddyfile.https"
grep -q '^https://__PANEL_IP__ {$' "$ROOT/panel/Caddyfile.https"

if grep -E 'wg-quick|iptables|nft |ufw |systemctl (stop|restart|disable)|set -x' \
  "$INSTALL" "$ROOT/panel/renew-cert.sh" "$ROOT/panel/backup-panel.sh" \
  "$ROOT/panel/restore-panel.sh" "$ROOT/panel/backup-wg.sh" "$ROOT/panel/restore-wg.sh" \
  "$ROOT/panel/push-restore.sh"; then
  echo "installer contains a forbidden mutation or a trace flag" >&2
  exit 1
fi

if grep -E 'wg (set|addconf|syncconf)|peer[[:space:]]+delete|--backend' \
  "$INSTALL" "$ROOT/panel/restore-panel.sh" "$ROOT/panel/push-restore.sh"; then
  echo "restore can reach WireGuard peers or agent backends" >&2
  exit 1
fi

if grep -E 'ghp_|github_pat_|BEGIN .*PRIVATE KEY|AKIA[0-9A-Z]{16}' \
  "$INSTALL" "$ROOT/panel/install-from-pc.sh" "$ROOT/panel/renew-cert.sh" "$ROOT/panel/docker-compose.yml" \
  "$ROOT/panel/Caddyfile.bootstrap" "$ROOT/panel/Caddyfile.https"; then
  echo "installer tree contains a secret" >&2
  exit 1
fi

out=$(mktemp -d)

set +e
bash "$INSTALL" --new --backup-pubkey "$PUB" --ip 10.1.2.3 --email admin@example.com --dry-run >"$out/private" 2>"$out/private.err"
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
FAMILY_VPN_PANEL_DIR="$data" bash "$INSTALL" --new --backup-pubkey "$PUB" --ip 203.0.113.5 --email admin@example.com --dry-run \
  >"$out/exists" 2>"$out/exists.err"
exists_code=$?
set -e
[ "$exists_code" -eq 3 ]
grep -q 'DATA_EXISTS' "$out/exists"
test -f "$data/family-vpn.sqlite"
test -f "$data/master.key"
set +e
FAMILY_VPN_PANEL_DIR="$data" bash "$INSTALL" --new --backup-pubkey "$PUB" --ip 203.0.113.5 --email admin@example.com --dry-run \
  >"$out/exists-2" 2>"$out/exists-2.err"
exists_again=$?
set -e
[ "$exists_again" -eq 3 ]
test -f "$data/family-vpn.sqlite"
test -f "$data/master.key"

empty=$(mktemp -d)
FAMILY_VPN_PANEL_DIR="$empty" bash "$INSTALL" --new --backup-pubkey "$PUB" --ip 203.0.113.5 --email admin@example.com --dry-run \
  >"$out/ok"
grep -q 'DRY_RUN_OK' "$out/ok"
test ! -e "$empty/family-vpn.sqlite"

set +e
bash "$INSTALL" --restore "$out/missing.tar.age" --identity "$out/id.txt" --email admin@example.com --ip 203.0.113.5 --dry-run \
  >"$out/restore" 2>"$out/restore.err"
restore_code=$?
set -e
[ "$restore_code" -ne 0 ]
grep -q 'ARCHIVE_MISSING' "$out/restore.err"

printf 'not-an-archive\n' >"$out/archive.tar.age"
printf 'AGE-SECRET-KEY-1testonly\n' >"$out/id.txt"
FAMILY_VPN_PANEL_DIR="$empty" bash "$INSTALL" --restore "$out/archive.tar.age" --identity "$out/id.txt" \
  --email admin@example.com --ip 203.0.113.5 --backup-pubkey "$PUB" --dry-run >"$out/restore-ok"
grep -q 'RESTORE_DRY_RUN' "$out/restore-ok"
test ! -e "$empty/family-vpn.sqlite"

FAMILY_VPN_PANEL_DIR="$empty" bash "$INSTALL" --restore - --decrypted --backup-pubkey "$PUB" \
  --email admin@example.com --ip 203.0.113.5 --dry-run >"$out/local-key"
grep -q 'KEY_STAYS_LOCAL' "$out/local-key"
grep -q 'RESTORE_DRY_RUN' "$out/local-key"
test ! -e "$empty/family-vpn.sqlite"

set +e
FAMILY_VPN_PANEL_DIR="$empty" bash "$INSTALL" --restore - --decrypted --identity "$out/id.txt" \
  --backup-pubkey "$PUB" --email admin@example.com --ip 203.0.113.5 --dry-run \
  >"$out/key-on-server" 2>"$out/key-on-server.err"
key_code=$?
set -e
[ "$key_code" -ne 0 ]
grep -q 'KEY_STAYS_LOCAL' "$out/key-on-server.err"

set +e
FAMILY_VPN_PANEL_DIR="$empty" bash "$INSTALL" --new --ip 203.0.113.5 --email admin@example.com --dry-run \
  >"$out/nopub" 2>"$out/nopub.err"
nopub_code=$?
set -e
[ "$nopub_code" -ne 0 ]
grep -q 'PUBKEY_MISSING' "$out/nopub.err"

token_dir=$(mktemp -d)
owner_log=$(mktemp)
owner_bin=$(mktemp -d)
real_install=$(command -v install)
real_id=$(command -v id)
cat >"$owner_bin/install" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$owner_log"
exec "$real_install" "\$@"
EOF
cat >"$owner_bin/id" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-u" ]; then
  printf '0\n'
  exit 0
fi
exec "$real_id" "\$@"
EOF
chmod +x "$owner_bin/install" "$owner_bin/id"
token_out=$(PATH="$owner_bin:$PATH" FAMILY_VPN_PANEL_DIR="$token_dir" bash "$INSTALL" --setup-token)
token=$(printf '%s\n' "$token_out" | sed -n 's/^SETUP_TOKEN=//p')
[ -n "$token" ]
stored=$(tr -d '\r\n' <"$token_dir/setup-token.sha256")
want=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
[ "$stored" = "$want" ]
if grep -q "$token" "$token_dir/setup-token.sha256"; then
  echo "activation token was stored in clear text" >&2
  exit 1
fi
if grep -q "$token" "$INSTALL"; then
  echo "activation token was written into the installer" >&2
  exit 1
fi
if ! grep -q -- '-o 1001 -g 1001 -m 600' "$owner_log"; then
  echo "setup-token.sha256 was not created as uid 1001 mode 600" >&2
  exit 1
fi
if ! grep -F -q -- "$token_dir/setup-token.sha256" "$owner_log"; then
  echo "setup-token.sha256 was not the install target" >&2
  exit 1
fi
second_out=$(PATH="$owner_bin:$PATH" FAMILY_VPN_PANEL_DIR="$token_dir" bash "$INSTALL" --setup-token)
second=$(printf '%s\n' "$second_out" | sed -n 's/^SETUP_TOKEN=//p')
[ -n "$second" ]
[ "$second" != "$token" ]
stored=$(tr -d '\r\n' <"$token_dir/setup-token.sha256")
want=$(printf '%s' "$second" | sha256sum | awk '{print $1}')
[ "$stored" = "$want" ]
if [ "$(printf '%s' "$token" | sha256sum | awk '{print $1}')" = "$stored" ]; then
  echo "the previous activation code still matches" >&2
  exit 1
fi
owner_calls=$(grep -c -- '-o 1001 -g 1001 -m 600' "$owner_log" || true)
[ "$owner_calls" -ge 2 ]

admin_dir=$(mktemp -d)
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "python is required to build the admin fixture" >&2
  exit 1
fi
"$PY" -c 'import sqlite3,sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("create table admin (id integer primary key, display_name text, password_hash text, created_at text)")
connection.execute("insert into admin values (1, \"Ada\", \"hash\", \"t\")")
connection.commit()' "$admin_dir/family-vpn.sqlite"
set +e
FAMILY_VPN_PANEL_DIR="$admin_dir" bash "$INSTALL" --setup-token >"$out/admin-token" 2>"$out/admin-token.err"
admin_code=$?
set -e
[ "$admin_code" -ne 0 ]
grep -q 'ADMIN_EXISTS' "$out/admin-token.err"
test ! -e "$admin_dir/setup-token.sha256"
test -f "$admin_dir/family-vpn.sqlite"

awk '
  /^cmd_new\(\)/ { inside=1 }
  inside && /^}/ { exit }
  inside && /start_https/ { started=1 }
  inside && /show_installed/ && !started { print "activation banner is shown before HTTPS checks" > "/dev/stderr"; exit 1 }
' "$INSTALL"

bash "$ROOT/panel/install-from-pc.sh" --dry-run --host root@203.0.113.5 --email admin@example.com --backup-pubkey "$PUB" \
  >"$out/ship"
grep -q 'PASSWORD_IN_TERMINAL' "$out/ship"
grep -q 'SHIP git-archive' "$out/ship"
grep -q 'SHIP releases' "$out/ship"
grep -q -- '--new' "$out/ship"
bash "$ROOT/panel/install-from-pc.sh" --update --dry-run --host root@203.0.113.5 >"$out/ship-update"
grep -q 'SHIP git-archive' "$out/ship-update"
grep -q 'SHIP releases' "$out/ship-update"
grep -q '/opt/family-vpn/app/panel/install-panel.sh --update' "$out/ship-update"
if grep -q -- '--new' "$out/ship-update"; then
  echo "panel update command must not reinstall" >&2
  exit 1
fi
grep -q '../releases:/app/releases:ro' "$ROOT/panel/docker-compose.yml"
grep -q 'fetch-agent-release.ps1' "$ROOT/panel/install-from-pc.sh"
grep -q 'ControlMaster=no' "$ROOT/panel/install-from-pc.sh"
grep -q 'ControlPath=none' "$ROOT/panel/install-from-pc.sh"
grep -q 'ControlPersist=no' "$ROOT/panel/install-from-pc.sh"
if grep -E 'ControlMaster=auto|ControlPersist=[1-9]|-fN|-O exit' "$ROOT/panel/install-from-pc.sh"; then
  echo "install-from-pc still opens an SSH control socket" >&2
  exit 1
fi
set +e
bash "$ROOT/panel/install-from-pc.sh" --dry-run --host root@203.0.113.5 --email admin@example.com \
  --backup-pubkey 'AGE-SECRET-KEY-1testonly' >"$out/ship-key" 2>"$out/ship-key.err"
ship_code=$?
set -e
[ "$ship_code" -ne 0 ]
grep -q 'PRIVATE_KEY_REFUSED' "$out/ship-key.err"

ident=$(mktemp)
archive_file=$(mktemp)
printf 'AGE-SECRET-KEY-1testonly\n' >"$ident"
printf 'archive\n' >"$archive_file"
bash "$ROOT/panel/install-from-pc.sh" --dry-run --restore --host root@203.0.113.5 --email admin@example.com \
  --archive "$archive_file" --identity "$ident" >"$out/restore-ship"
grep -q 'KEY_STAYS_LOCAL' "$out/restore-ship"
grep -q -- '--restore' "$out/restore-ship"
grep -q -- '--decrypted' "$out/restore-ship"
if grep -F -q -- "$ident" "$out/restore-ship"; then
  echo "age identity path leaked into the remote command" >&2
  exit 1
fi
if grep -q 'AGE-SECRET-KEY-' "$out/restore-ship"; then
  echo "age private key leaked into the remote command" >&2
  exit 1
fi
rm -f "$ident" "$archive_file"

rm -rf "$token_dir" "$admin_dir" "$owner_bin"
rm -f "$owner_log"

update_root=$(mktemp -d)
update_state="$update_root/state"
update_backup="$update_root/backups"
update_env="$update_root/panel.env"
update_pub="$update_root/backup.pub"
mkdir -p "$update_state"
printf 'PUBLIC_URL=https://203.0.113.5\n' >"$update_env"
printf 'age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p\n' >"$update_pub"
if command -v python3 >/dev/null 2>&1; then
  UPDATE_PY=python3
elif command -v python >/dev/null 2>&1; then
  UPDATE_PY=python
else
  echo "python is required for the panel update fixture" >&2
  exit 1
fi
"$UPDATE_PY" -c 'import sqlite3,sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("create table admin (id integer primary key, display_name text, password_hash text, created_at text)")
connection.execute("insert into admin values (1, \"Ada\", \"scrypt-hash\", \"t0\")")
connection.execute("create table servers (id text primary key, endpoint text, listen_port integer)")
connection.execute("insert into servers values (\"nl\", \"203.0.113.10\", 51820)")
connection.execute("PRAGMA user_version = 3")
connection.commit()' "$update_state/family-vpn.sqlite"
"$UPDATE_PY" -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"k"*32)' "$update_state/master.key"
sqlite_before=$("$UPDATE_PY" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_bytes().hex())' "$update_state/family-vpn.sqlite")
key_before=$("$UPDATE_PY" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_bytes().hex())' "$update_state/master.key")

empty_state=$(mktemp -d)
set +e
FAMILY_VPN_PANEL_DIR="$empty_state" FAMILY_VPN_UPDATE_TEST=1 bash "$INSTALL" --update >"$out/update-empty" 2>"$out/update-empty.err"
empty_code=$?
set -e
[ "$empty_code" -ne 0 ]
grep -q 'SQLITE_MISSING' "$out/update-empty.err"
test ! -e "$empty_state/family-vpn.sqlite"

set +e
FAMILY_VPN_PANEL_DIR="$update_state" FAMILY_VPN_UPDATE_TEST=1 bash "$INSTALL" --update --dry-run \
  >"$out/update-dry" 2>"$out/update-dry.err"
dry_code=$?
set -e
[ "$dry_code" -eq 0 ]
grep -q 'UPDATE_DRY_RUN' "$out/update-dry"
dry_after=$("$UPDATE_PY" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_bytes().hex())' "$update_state/family-vpn.sqlite")
[ "$dry_after" = "$sqlite_before" ]
test ! -d "$update_backup"

cat >"$update_root/compose-ok" <<'EOF'
#!/bin/bash
printf '%s %s\n' "${FAMILY_VPN_UPDATE_PHASE:-}" "${FAMILY_VPN_PREVIOUS_IMAGE:-}" >>"$FAMILY_VPN_COMPOSE_LOG"
exit 0
EOF
compose_log="$update_root/compose.log"
: >"$compose_log"
FAMILY_VPN_PANEL_DIR="$update_state" \
  FAMILY_VPN_PANEL_ENV="$update_env" \
  FAMILY_VPN_BACKUP_PUB="$update_pub" \
  FAMILY_VPN_PREUPDATE_DIR="$update_backup" \
  FAMILY_VPN_UPDATE_TEST=1 \
  FAMILY_VPN_UPDATE_COMPOSE="$update_root/compose-ok" \
  FAMILY_VPN_COMPOSE_LOG="$compose_log" \
  FAMILY_VPN_UPDATE_IMAGE_BEFORE="sha256:previous" \
  bash "$INSTALL" --update >"$out/update-ok"
grep -q 'UPDATE_OK' "$out/update-ok"
grep -q 'apply sha256:previous' "$compose_log"
ok_after=$("$UPDATE_PY" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_bytes().hex())' "$update_state/family-vpn.sqlite")
[ "$ok_after" = "$sqlite_before" ]
key_after=$("$UPDATE_PY" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_bytes().hex())' "$update_state/master.key")
[ "$key_after" = "$key_before" ]
env_hash_before=$("$UPDATE_PY" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_bytes().hex())' "$update_env")
snapshot=$(find "$update_backup" -mindepth 1 -maxdepth 1 -type d | head -n 1)
test -n "$snapshot"
test -f "$snapshot/SHA256SUMS"
( cd "$snapshot" && sha256sum -c SHA256SUMS >/dev/null )
if command -v cygpath >/dev/null 2>&1; then
  tool_path=$(cygpath -w "$ROOT/panel/archive-tool.mjs")
  snapshot_path=$(cygpath -w "$snapshot")
else
  tool_path="$ROOT/panel/archive-tool.mjs"
  snapshot_path=$snapshot
fi
node "$tool_path" verify "$snapshot_path" >"$out/snapshot-verify"
grep -q 'schema=3' "$out/snapshot-verify"

cat >"$update_root/compose-fail" <<'EOF'
#!/bin/bash
printf '%s %s\n' "${FAMILY_VPN_UPDATE_PHASE:-}" "${FAMILY_VPN_PREVIOUS_IMAGE:-}" >>"$FAMILY_VPN_COMPOSE_LOG"
if [ "${FAMILY_VPN_UPDATE_PHASE:-}" = "rollback" ]; then
  exit 0
fi
rm -f "$FAMILY_VPN_PANEL_DIR/family-vpn.sqlite" "$FAMILY_VPN_PANEL_ENV"
printf 'empty\n' >"$FAMILY_VPN_PANEL_DIR/family-vpn.sqlite"
exit 1
EOF
fail_log="$update_root/compose-fail.log"
: >"$fail_log"
set +e
FAMILY_VPN_PANEL_DIR="$update_state" \
  FAMILY_VPN_PANEL_ENV="$update_env" \
  FAMILY_VPN_BACKUP_PUB="$update_pub" \
  FAMILY_VPN_PREUPDATE_DIR="$update_backup" \
  FAMILY_VPN_UPDATE_TEST=1 \
  FAMILY_VPN_UPDATE_COMPOSE="$update_root/compose-fail" \
  FAMILY_VPN_COMPOSE_LOG="$fail_log" \
  bash "$INSTALL" --update >"$out/update-fail" 2>"$out/update-fail.err"
fail_code=$?
set -e
[ "$fail_code" -ne 0 ]
grep -q 'UPDATE_ROLLBACK' "$out/update-fail.err"
grep -q 'PANEL_RESTORED' "$out/update-fail"
grep -q 'rollback previous-image' "$fail_log"
restored=$("$UPDATE_PY" -c 'import sqlite3,sys
connection = sqlite3.connect(sys.argv[1])
row = connection.execute("select display_name from admin where id = 1").fetchone()
print(row[0])' "$update_state/family-vpn.sqlite")
[ "$restored" = "Ada" ]
test -f "$update_env"
env_hash_after=$("$UPDATE_PY" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_bytes().hex())' "$update_env")
[ "$env_hash_after" = "$env_hash_before" ]

set +e
FAMILY_VPN_PANEL_DIR="$update_state" \
  FAMILY_VPN_PREUPDATE_DIR="$update_backup" \
  FAMILY_VPN_UPDATE_TEST=1 \
  bash "$INSTALL" --rollback --dry-run >"$out/rollback-dry" 2>"$out/rollback-dry.err"
rollback_dry=$?
set -e
[ "$rollback_dry" -eq 0 ]
grep -q 'ROLLBACK_DRY_RUN' "$out/rollback-dry"
dry_admin=$("$UPDATE_PY" -c 'import sqlite3,sys
connection = sqlite3.connect(sys.argv[1])
print(connection.execute("select display_name from admin where id = 1").fetchone()[0])' "$update_state/family-vpn.sqlite")
[ "$dry_admin" = "Ada" ]

grep -q '/var/lib/family-vpn/panel:/data' "$ROOT/panel/docker-compose.yml"
grep -q 'compose up -d --build --no-deps panel' "$INSTALL"
grep -q 'FAMILY_VPN_COMPOSE_EXTRA' "$INSTALL"
grep -q '127.0.0.1:3000:3000' "$ROOT/panel/docker-compose.ci-http.yml"

rm -rf "$update_root" "$empty_state"
rm -rf "$data" "$empty" "$out"

echo "panel installer checks ok"
