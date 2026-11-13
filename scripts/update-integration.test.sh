#!/bin/bash
# End-to-end panel update test on a Linux host with Docker.
# Mirrors the stable d587d590518d layout under /opt/family-vpn and /var/lib/family-vpn.
# Does not contact DE-01, NL-01, or any production VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STABLE=${FAMILY_VPN_STABLE_COMMIT:-d587d590518d}
NEW=${FAMILY_VPN_NEW_COMMIT:-HEAD}
APP_DIR=/opt/family-vpn/app
STATE_DIR=/var/lib/family-vpn/panel
ETC_DIR=/etc/family-vpn
ENV_FILE=$ETC_DIR/panel.env
REPORT=${FAMILY_VPN_INTEGRATION_REPORT:-$ROOT/dist/update-integration-report.txt}
PASSWORD='correct-horse-battery'
AGENT_TOKEN='test-agent-token-0001'
PUBLIC_URL=http://127.0.0.1:3000
WORKDIR=$(mktemp -d)
STATUS_LINES=()

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

note() {
  STATUS_LINES+=("$*")
  printf '%s\n' "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "нужен $1"
}

cleanup() {
  docker rm -f family-vpn-caddy-ci >/dev/null 2>&1 || true
  ip link delete wg-fvpn-ci >/dev/null 2>&1 || true
  if [ -f "$ENV_FILE" ] && [ -d "$APP_DIR/panel" ]; then
    (
      cd "$APP_DIR/panel"
      docker compose --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.ci-http.yml down --remove-orphans >/dev/null 2>&1 || true
    )
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

write_report() {
  mkdir -p "$(dirname "$REPORT")"
  {
    printf 'Family VPN update integration report\n'
    printf 'stable=%s\n' "$STABLE"
    printf 'new=%s\n' "$(git -C "$ROOT" rev-parse "$NEW")"
    printf 'host=%s\n' "$(uname -a)"
    printf 'time=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n'
    printf '%s\n' "${STATUS_LINES[@]}"
  } >"$REPORT"
}

on_fail() {
  note "FAIL $*"
  if command -v docker >/dev/null 2>&1; then
    docker logs "$(docker ps -aq --filter name=family-vpn-panel | head -n 1)" 2>&1 | tail -n 80 || true
  fi
  write_report
  exit 1
}

sql() {
  python3 - "$STATE_DIR/family-vpn.sqlite" "$@" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1], timeout=10)
db.execute("PRAGMA busy_timeout = 5000")
cur = db.execute(sys.argv[2], sys.argv[3:])
row = cur.fetchone()
if row is None:
    raise SystemExit(1)
def cell(value):
    return "null" if value is None else str(value)
print(cell(row[0]) if len(row) == 1 else "\t".join(cell(x) for x in row))
PY
}

wait_http() {
  local url=$1 attempt
  for attempt in $(seq 1 60); do
    if curl -fsS -o /dev/null --max-time 3 "$url"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

compose_ci() {
  docker compose --project-directory "$APP_DIR/panel" --env-file "$ENV_FILE" \
    -f "$APP_DIR/panel/docker-compose.yml" \
    -f "$APP_DIR/panel/docker-compose.ci-http.yml" \
    "$@"
}

install_tree() {
  local commit=$1 dest=$2
  rm -rf "$dest"
  mkdir -p "$dest"
  git -C "$ROOT" archive --format=tar "$commit" | tar -x -C "$dest"
  [ -f "$dest/Dockerfile" ] || die "в коммите $commit нет Dockerfile"
  [ -f "$dest/panel/install-panel.sh" ] || die "в коммите $commit нет install-panel.sh"
}

WG_SERVER_PUB=$(printf '%s=' "$(printf 'A%.0s' {1..43})")
WG_CLIENT_PUB=$(printf '%s=' "$(printf 'B%.0s' {1..43})")

heartbeat() {
  local version=$1 cpu=${2:-} body response code
  if [ -n "$cpu" ]; then
    body=$(printf '{"version":"%s","report":{"endpoint":"203.0.113.10","listenPort":51820,"publicKey":"%s","subnet":"10.200.0.0/24","interfaceName":"wg0","interfaceUp":true,"externalInterface":"eth0","existingConfig":true,"cpuPercent":%s},"peers":[{"publicKey":"%s","allowedIps":"10.200.0.2/32","rxBytes":5000,"txBytes":7000,"lastHandshake":1700000000}]}' "$version" "$WG_SERVER_PUB" "$cpu" "$WG_CLIENT_PUB")
  else
    body=$(printf '{"version":"%s","report":{"endpoint":"203.0.113.10","listenPort":51820,"publicKey":"%s","subnet":"10.200.0.0/24","interfaceName":"wg0","interfaceUp":true,"externalInterface":"eth0","existingConfig":true},"peers":[{"publicKey":"%s","allowedIps":"10.200.0.2/32","rxBytes":5000,"txBytes":7000,"lastHandshake":1700000000}]}' "$version" "$WG_SERVER_PUB" "$WG_CLIENT_PUB")
  fi
  response=$(curl -sS -w '\n%{http_code}' -X POST "$PUBLIC_URL/api/agent/heartbeat" \
    -H "Authorization: Bearer $AGENT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body")
  code=$(printf '%s' "$response" | tail -n 1)
  body=$(printf '%s' "$response" | sed '$d')
  if [ "$code" != "200" ]; then
    printf 'heartbeat HTTP %s: %s\n' "$code" "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

verify_password() {
  node --input-type=module - "$STATE_DIR" "$PASSWORD" <<'JS'
import { createHash, scryptSync, timingSafeEqual } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import path from "node:path";
const dir = process.argv[2];
const password = process.argv[3];
const db = new DatabaseSync(path.join(dir, "family-vpn.sqlite"));
const row = db.prepare("SELECT password_hash FROM admin WHERE id = 1").get();
db.close();
const [scheme, n, r, p, saltRaw, hashRaw] = String(row.password_hash).split("$");
if (scheme !== "scrypt") process.exit(1);
const salt = Buffer.from(saltRaw, "base64url");
const expected = Buffer.from(hashRaw, "base64url");
const actual = scryptSync(password, salt, expected.length, {
  N: Number(n),
  r: Number(r),
  p: Number(p),
  maxmem: 64 * 1024 * 1024,
});
if (!timingSafeEqual(actual, expected)) process.exit(1);
console.log("PASSWORD_OK");
JS
}

decrypt_client_key() {
  node --input-type=module - "$STATE_DIR" <<'JS'
import { createDecipheriv, createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
const dir = process.argv[2];
const master = readFileSync(path.join(dir, "master.key"));
const db = new DatabaseSync(path.join(dir, "family-vpn.sqlite"));
const row = db.prepare("SELECT client_private_key_enc FROM configs WHERE id = 'cfg-test'").get();
db.close();
const raw = Buffer.from(String(row.client_private_key_enc), "base64");
const decipher = createDecipheriv("aes-256-gcm", master, raw.subarray(0, 12));
decipher.setAuthTag(raw.subarray(12, 28));
const plain = Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString("utf8");
if (plain !== "client-private-key-test") process.exit(1);
console.log("KEY_OK " + createHash("sha256").update(master).digest("hex"));
JS
}

page_contains() {
  local path=$1 needle=$2 token=$3
  local html
  html=$(curl -fsS -H "Cookie: family_vpn_session=$token" "$PUBLIC_URL$path")
  printf '%s' "$html" | grep -Fq "$needle"
}

create_session_cookie() {
  node --input-type=module - "$STATE_DIR" <<'JS'
import { createHash, randomBytes } from "node:crypto";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
const dir = process.argv[2];
const token = randomBytes(32).toString("base64url");
const hash = createHash("sha256").update(token).digest("hex");
const db = new DatabaseSync(path.join(dir, "family-vpn.sqlite"));
const expires = new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString();
const now = new Date().toISOString();
db.prepare("INSERT INTO sessions (token_hash, expires_at, created_at) VALUES (?, ?, ?)").run(hash, expires, now);
db.close();
process.stdout.write(token);
JS
}

[ "$(id -u)" -eq 0 ] || die "запустите от root (sudo)"
need_cmd docker
need_cmd git
need_cmd curl
need_cmd python3
need_cmd node
need_cmd go
docker info >/dev/null 2>&1 || die "docker не запущен"
git -C "$ROOT" rev-parse --verify "$STABLE^{commit}" >/dev/null
git -C "$ROOT" rev-parse --verify "$NEW^{commit}" >/dev/null
mkdir -p /opt/family-vpn /var/lib/family-vpn "$ETC_DIR" "$(dirname "$REPORT")" "$ROOT/dist" "$ROOT/releases"

note "HOST_OK ubuntu=$(. /etc/os-release; printf '%s' "$VERSION_ID") docker=$(docker version --format '{{.Server.Version}}')"
note "UNIT_GATES_EXTERNAL npm/go/tsc/lint/build and the agent release are prepared by the workflow before sudo"

# Agent release artifacts must already exist (built without root).
[ -f "$ROOT/releases/SHA256SUMS" ] || on_fail "releases/SHA256SUMS missing"
(cd "$ROOT/releases" && sha256sum -c SHA256SUMS) || on_fail "SHA256SUMS"
cmp -s "$ROOT/installer/install.sh" "$ROOT/releases/install.sh" || on_fail "install.sh mismatch"
chmod +x "$ROOT/releases/family-vpn-agent-linux-amd64"
test "$("$ROOT/releases/family-vpn-agent-linux-amd64" --version)" = "0.4.1" || on_fail "agent version"
test "$("$ROOT/releases/family-vpn-agent-linux-amd64" version)" = "0.4.1" || on_fail "agent version alias"
note "AGENT_BINARY_OK version=0.4.1"

(
  cd "$ROOT/agent"
  go test -count=1 -run 'TestCPU|TestJson' ./...
) || on_fail "agent cpu tests on Linux"
if [ -r /proc/stat ]; then
  note "PROC_STAT_OK host has /proc/stat"
else
  on_fail "/proc/stat missing"
fi

# Ephemeral WireGuard iface on the runner. Not a tunnel to DE-01/NL-01.
if ! command -v wg >/dev/null 2>&1; then
  apt-get update >/dev/null
  apt-get install -y wireguard >/dev/null
fi
WG_IFACE=wg-fvpn-ci
ip link delete "$WG_IFACE" 2>/dev/null || true
WG_PRIV=$(wg genkey)
ip link add dev "$WG_IFACE" type wireguard
printf '%s\n' "$WG_PRIV" >"$WORKDIR/wg-ci.key"
chmod 600 "$WORKDIR/wg-ci.key"
wg set "$WG_IFACE" private-key "$WORKDIR/wg-ci.key" listen-port 51821
ip address add 10.66.66.1/24 dev "$WG_IFACE"
ip link set "$WG_IFACE" up
wg show "$WG_IFACE" >/dev/null || on_fail "wg show $WG_IFACE"
WG_IFINDEX_BEFORE=$(cat "/sys/class/net/$WG_IFACE/ifindex")
bash "$ROOT/installer/update-rollback.test.sh" || on_fail "agent update sandbox"
bash "$ROOT/installer/update-mode.test.sh" || on_fail "agent update-mode sandbox"
[ -d "/sys/class/net/$WG_IFACE" ] || on_fail "wg iface removed during agent update sandbox"
WG_IFINDEX_AFTER=$(cat "/sys/class/net/$WG_IFACE/ifindex")
[ "$WG_IFINDEX_BEFORE" = "$WG_IFINDEX_AFTER" ] || on_fail "wg iface recreated during agent update sandbox"
note "WG0_CI_OK iface=$WG_IFACE ifindex=$WG_IFINDEX_BEFORE agent_update_left_iface=1"
ip link delete "$WG_IFACE" || true
rm -f "$WORKDIR/wg-ci.key"

# --- install stable tree exactly as d587d590518d ---
install_tree "$STABLE" "$APP_DIR"
# CI HTTP override is not in the stable commit; copy only that helper from HEAD.
install -m 644 "$ROOT/panel/docker-compose.ci-http.yml" "$APP_DIR/panel/docker-compose.ci-http.yml"
mkdir -p "$APP_DIR/releases"
cp -a "$ROOT/releases/." "$APP_DIR/releases/"
# Stable installer expects SCHEMA_MAX=3; keep its archive tools for rollback checks.
note "STABLE_TREE_OK commit=$(git -C "$ROOT" rev-parse --short "$STABLE") path=$APP_DIR"

# Seed schema 3 data in the real state directory.
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
node "$ROOT/scripts/seed-stable-panel.mjs" "$STATE_DIR" "$PASSWORD" "$AGENT_TOKEN" || on_fail "seed"
chown -R 1001:1001 "$STATE_DIR"
MASTER_BEFORE=$(sha256sum "$STATE_DIR/master.key" | awk '{print $1}')
SCHEMA_BEFORE=$(sql "PRAGMA user_version")
[ "$SCHEMA_BEFORE" = "3" ] || on_fail "expected schema 3, got $SCHEMA_BEFORE"
note "SEED_OK schema=3 master=$MASTER_BEFORE"

cat >"$ENV_FILE" <<EOF
NODE_ENV=production
FAMILY_VPN_DATA_DIR=/data
FAMILY_VPN_TRUST_PROXY=1
FAMILY_VPN_PUBLIC_URL=$PUBLIC_URL
FAMILY_VPN_DEMO_UI=1
EOF
chmod 600 "$ENV_FILE"

# Start the stable panel with a real Docker build of d587d590518d.
compose_ci up -d --build --no-deps panel || on_fail "stable compose up"
wait_http "$PUBLIC_URL/login" || on_fail "stable /login"
LOGIN_CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$PUBLIC_URL/login")
[ "$LOGIN_CODE" = "200" ] || on_fail "stable login HTTP $LOGIN_CODE"
verify_password >/dev/null || on_fail "stable password"
decrypt_client_key >/dev/null || on_fail "stable decrypt"
SESSION=$(create_session_cookie)
page_contains "/" "NL-01" "$SESSION" || on_fail "stable overview"
page_contains "/servers" "NL-01" "$SESSION" || on_fail "stable servers"
page_contains "/configurations" "phone" "$SESSION" || on_fail "stable configs"
note "STABLE_PANEL_OK http=200 https=NOT_CHECKED"
note "HTTPS_NOT_CHECKED Let's Encrypt needs a public IP; this run used HTTP on 127.0.0.1:3000"

# Stable agent 0.4.0 heartbeat against the stable panel.
HB=$(heartbeat 0.4.0)
printf '%s' "$HB" | grep -q '"ok"' || on_fail "stable heartbeat 0.4.0"
CPU_COLS=$(sql "SELECT COUNT(*) FROM pragma_table_info('servers') WHERE name='cpu_percent'")
[ "$CPU_COLS" = "0" ] || on_fail "stable schema unexpectedly has cpu_percent"
note "STABLE_HEARTBEAT_040_OK cpu_column=absent"

STABLE_IMAGE=$(docker inspect --format '{{.Image}}' "$(docker ps -aq --filter name=family-vpn-panel | head -n 1)")
[ -n "$STABLE_IMAGE" ] || on_fail "stable image id missing"
note "STABLE_IMAGE_OK $STABLE_IMAGE"

# --- replace the app tree with the new commit, keep data ---
install_tree "$NEW" "$APP_DIR"
install -m 644 "$ROOT/panel/docker-compose.ci-http.yml" "$APP_DIR/panel/docker-compose.ci-http.yml"
mkdir -p "$APP_DIR/releases"
cp -a "$ROOT/releases/." "$APP_DIR/releases/"
# Keep panel.env pointing at HTTP for the update health check.
note "NEW_TREE_OK commit=$(git -C "$ROOT" rev-parse --short "$NEW")"

# Disk room for a WAL-safe VACUUM INTO snapshot before the installer runs.
DB_BYTES=$(wc -c <"$STATE_DIR/family-vpn.sqlite" | tr -d ' ')
NEED_KB=$(( (DB_BYTES / 1024) * 3 + 1024 ))
AVAIL_KB=$(df -Pk "$STATE_DIR" | awk 'NR==2 { print $4 }')
[ "$AVAIL_KB" -ge "$NEED_KB" ] || on_fail "disk space before update need=${NEED_KB}KiB avail=${AVAIL_KB}KiB"
note "DISK_OK need_kib=$NEED_KB avail_kib=$AVAIL_KB"

# One-command panel update through the installer (no manual docker image swap).
export FAMILY_VPN_COMPOSE_EXTRA="$APP_DIR/panel/docker-compose.ci-http.yml"
bash "$APP_DIR/panel/install-panel.sh" --update || on_fail "panel --update"
wait_http "$PUBLIC_URL/login" || on_fail "updated /login"
SCHEMA_AFTER=$(sql "PRAGMA user_version")
[ "$SCHEMA_AFTER" = "4" ] || on_fail "expected schema 4, got $SCHEMA_AFTER"
MASTER_AFTER=$(sha256sum "$STATE_DIR/master.key" | awk '{print $1}')
[ "$MASTER_AFTER" = "$MASTER_BEFORE" ] || on_fail "master.key changed"
[ "$(sql "SELECT display_name FROM admin WHERE id = 1")" = "Ada" ] || on_fail "admin lost"
verify_password >/dev/null || on_fail "updated password"
decrypt_client_key >/dev/null || on_fail "updated decrypt"
[ "$(sql "SELECT token_hash FROM agents WHERE server_id = 'nl-test'")" = "$(printf '%s' "$AGENT_TOKEN" | sha256sum | awk '{print $1}')" ] || on_fail "agent token lost"
[ "$(sql "SELECT name FROM servers WHERE id = 'nl-test'")" = "NL-01" ] || on_fail "server lost"
[ "$(sql "SELECT device_name FROM configs WHERE id = 'cfg-test'")" = "phone" ] || on_fail "config lost"
SESSION=$(create_session_cookie)
page_contains "/" "NL-01" "$SESSION" || on_fail "updated overview"
# Demo servers must not appear: production NODE_ENV ignores FAMILY_VPN_DEMO_UI.
page_contains "/" "US-01" "$SESSION" && on_fail "demo server leaked into production" || true
if printf '%s' "$(curl -fsS -H "Cookie: family_vpn_session=$SESSION" "$PUBLIC_URL/")" | grep -Fq "Демо-данные"; then
  on_fail "demo chip visible in production"
fi
note "PANEL_UPDATE_OK schema=4 master_unchanged=1 demo_disabled=1"
note "DOCKER_IMAGE_BUILT_OK update used compose --build on the new tree"

# Heartbeats on the new panel.
HB40=$(heartbeat 0.4.0)
printf '%s' "$HB40" | grep -q '"ok"' || on_fail "new panel heartbeat 0.4.0"
CPU40=$(sql "SELECT cpu_percent FROM servers WHERE id='nl-test'")
[ "$CPU40" = "null" ] || on_fail "0.4.0 left a cpu value: $CPU40"
RX40=$(sql "SELECT rx_bytes FROM configs WHERE id='cfg-test'")
TX40=$(sql "SELECT tx_bytes FROM configs WHERE id='cfg-test'")
[ "$RX40" = "5000" ] && [ "$TX40" = "7000" ] || on_fail "RX/TX after 0.4.0"
note "COMPAT_040_OK cpu=null rx=5000 tx=7000"

HB41=$(heartbeat 0.4.1 18)
printf '%s' "$HB41" | grep -q '"ok"' || on_fail "new panel heartbeat 0.4.1"
CPU41=$(sql "SELECT cpu_percent FROM servers WHERE id='nl-test'")
[ "$CPU41" = "18" ] || on_fail "cpuPercent not stored: $CPU41"
note "COMPAT_041_OK cpu=18"

HB40B=$(heartbeat 0.4.0)
CPU40B=$(sql "SELECT cpu_percent FROM servers WHERE id='nl-test'")
[ "$CPU40B" = "null" ] || on_fail "cpu not cleared after return to 0.4.0"
note "COMPAT_DOWNGRADE_OK cpu_cleared=1"

# Confirm the previous image is still present for rollback.
docker image inspect "$STABLE_IMAGE" >/dev/null || on_fail "stable image missing before rollback"
note "ROLLBACK_IMAGE_PRESENT $STABLE_IMAGE"

# Rollback through the installer.
export FAMILY_VPN_COMPOSE_EXTRA="$APP_DIR/panel/docker-compose.ci-http.yml"
bash "$APP_DIR/panel/install-panel.sh" --rollback || on_fail "panel --rollback"
wait_http "$PUBLIC_URL/login" || on_fail "rollback /login"
SCHEMA_RB=$(sql "PRAGMA user_version")
# Snapshot taken before migration is schema 3.
[ "$SCHEMA_RB" = "3" ] || on_fail "rollback schema expected 3, got $SCHEMA_RB"
MASTER_RB=$(sha256sum "$STATE_DIR/master.key" | awk '{print $1}')
[ "$MASTER_RB" = "$MASTER_BEFORE" ] || on_fail "master.key changed on rollback"
verify_password >/dev/null || on_fail "rollback password"
decrypt_client_key >/dev/null || on_fail "rollback decrypt"
[ "$(sql "SELECT display_name FROM admin WHERE id = 1")" = "Ada" ] || on_fail "admin lost on rollback"
[ "$(sql "SELECT device_name FROM configs WHERE id = 'cfg-test'")" = "phone" ] || on_fail "config lost on rollback"
# Old archive tool from the stable commit must accept the restored schema 3 snapshot.
OLD_TOOL=$WORKDIR/old-archive-tool.mjs
git -C "$ROOT" show "$STABLE:panel/archive-tool.mjs" >"$OLD_TOOL"
SNAP=$WORKDIR/rb-snap
mkdir -p "$SNAP"
node "$OLD_TOOL" snapshot "$STATE_DIR/family-vpn.sqlite" "$SNAP/family-vpn.sqlite"
cp -p "$STATE_DIR/master.key" "$SNAP/master.key"
node "$OLD_TOOL" manifest "$SNAP" >/dev/null
OLD_VERIFY=$(node "$OLD_TOOL" verify "$SNAP")
printf '%s' "$OLD_VERIFY" | grep -q 'schema=3' || on_fail "old archive verify"
printf '%s' "$OLD_VERIFY" | grep -q 'KEY_OK' || on_fail "old archive key"
# Prove the running container image is the stable one again when possible.
RUNNING_IMAGE=$(docker inspect --format '{{.Image}}' "$(docker ps -aq --filter name=family-vpn-panel | head -n 1)")
[ "$RUNNING_IMAGE" = "$STABLE_IMAGE" ] || on_fail "rollback container image $RUNNING_IMAGE != $STABLE_IMAGE"
note "PANEL_ROLLBACK_OK schema=3 image_restored=1 archive_ok=1"

# One-command shapes (no fake production URLs).
grep -q -- '--update' "$APP_DIR/panel/install-from-pc.sh" || on_fail "install-from-pc missing --update"
grep -q 'install-panel.sh --update' "$APP_DIR/panel/install-from-pc.sh" || on_fail "install-from-pc update target"
DRY_OUT=$(bash "$ROOT/panel/install-from-pc.sh" --update --host root@127.0.0.1 --dry-run) || on_fail "install-from-pc --update --dry-run"
printf '%s' "$DRY_OUT" | grep -q 'install-panel.sh --update' || on_fail "dry-run missing remote --update"
printf '%s' "$DRY_OUT" | grep -q 'SHIP git-archive' || on_fail "dry-run missing git-archive ship"
note "INSTALL_FROM_PC_UPDATE_DRY_RUN_OK"
grep -q -- '--update' "$ROOT/releases/INSTALL.txt" || note "AGENT_ONE_LINER_WITHHELD no published PUBLIC_URL in this build"
note "ONE_COMMAND_PANEL: bash panel/install-from-pc.sh --update --host root@PANEL"
note "ONE_COMMAND_AGENT: rebuild with FAMILY_VPN_PUBLIC_URL=https://PANEL then use releases/INSTALL.txt update line"

# HTTPS via Caddy with a CI-only self-signed certificate (not Let's Encrypt).
CERT_CI=/var/lib/family-vpn/certs-ci
mkdir -p "$CERT_CI" "$ETC_DIR"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_CI/privkey.pem" -out "$CERT_CI/fullchain.pem" \
  -days 1 -subj '/CN=127.0.0.1' \
  -addext 'subjectAltName=IP:127.0.0.1' >/dev/null 2>&1 || on_fail "openssl test cert"
chmod 644 "$CERT_CI/fullchain.pem"
chmod 600 "$CERT_CI/privkey.pem"
# :443 avoids hostname/SNI site matching; disable h3 to avoid quic buffer issues on GHA.
cat >"$ETC_DIR/Caddyfile.ci-https" <<'EOF'
{
	auto_https off
	admin off
	servers {
		protocols h1 h2
	}
}
:443 {
	tls /certs/fullchain.pem /certs/privkey.pem
	reverse_proxy panel:3000
}
EOF
PANEL_NET=$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$(docker ps -aq --filter name=family-vpn-panel | head -n 1)" | head -n 1)
[ -n "$PANEL_NET" ] || on_fail "panel docker network missing"
docker rm -f family-vpn-caddy-ci >/dev/null 2>&1 || true
# Match production compose: Caddy must run as root to read mode-600 privkey.pem.
docker run -d --name family-vpn-caddy-ci --user 0:0 --network "$PANEL_NET" \
  -p 127.0.0.1:8443:443 \
  -v "$ETC_DIR/Caddyfile.ci-https:/etc/caddy/Caddyfile:ro" \
  -v "$CERT_CI:/certs:ro" \
  caddy:2.10-alpine >/dev/null || on_fail "caddy ci container"
HTTPS_OK=0
for _ in $(seq 1 30); do
  if curl -kfsS --http1.1 -o /dev/null --max-time 3 "https://127.0.0.1:8443/login"; then
    HTTPS_OK=1
    break
  fi
  sleep 1
done
if [ "$HTTPS_OK" != "1" ]; then
  docker logs family-vpn-caddy-ci 2>&1 | tail -n 80 || true
  on_fail "https test-cert /login"
fi
HTTPS_CODE=$(curl -ksS --http1.1 -o /dev/null -w '%{http_code}' "https://127.0.0.1:8443/login")
[ "$HTTPS_CODE" = "200" ] || on_fail "https test-cert HTTP $HTTPS_CODE"
docker rm -f family-vpn-caddy-ci >/dev/null 2>&1 || true
note "HTTPS_TEST_CERT_OK port=8443 caddy=2.10-alpine"
note "LETS_ENCRYPT_STATUS=NOT_CHECKED no public IP ACME in CI"

note "VERIFY_PRODUCTION_READY_EXTERNAL prepared by the workflow before sudo"

note "HTTPS_STATUS=TEST_CERT_OK"
note "WG0_STATUS=CI_IFACE_OK"
note "RESULT=PASS"
write_report
printf '%s\n' "UPDATE_INTEGRATION_OK report=$REPORT"
