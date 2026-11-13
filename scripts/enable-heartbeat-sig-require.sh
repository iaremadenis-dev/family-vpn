#!/bin/bash
# Enable FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1 on an image-based panel install.
# Preserves SQLite, master.key, Caddy TLS, WireGuard, UFW, SSH.
# Requires: ComposeDir at /opt/family-vpn/install/panel; all agents on 0.5.0 with fresh heartbeats.
set -euo pipefail
umask 077

ENV_FILE=/etc/family-vpn/panel.env
COMPOSE_DIR=/opt/family-vpn/install/panel
DB=/var/lib/family-vpn/panel/family-vpn.sqlite
PANEL_IP=62.133.60.25
EXPECTED_IMAGE=sha256:7a14eb9234f77fa3ae6e51c4af6567fe1f62292dc8bbf21ee8c494575e3d9ed8
BAK_PATH_FILE=/etc/family-vpn/panel.env.bak-require-hb.path

die() { printf 'family-vpn-require-hb-sig: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
[ -f "$COMPOSE_DIR/docker-compose.yml" ] || die "missing compose at $COMPOSE_DIR"
[ -f "$COMPOSE_DIR/docker-compose.image.yml" ] || die "missing image overlay at $COMPOSE_DIR"
[ -s "$DB" ] || die "missing panel database"
[ -s /var/lib/family-vpn/panel/master.key ] || die "missing master.key"

P=$(docker ps -q -f label=com.docker.compose.service=panel -f label=com.docker.compose.project=family-vpn | head -n1)
[ -n "$P" ] || die "panel container not running"
WD=$(docker inspect "$P" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
[ "$WD" = "$COMPOSE_DIR" ] || die "ComposeDir is '$WD', expected $COMPOSE_DIR"

RUNNING_IMG=$(docker inspect "$P" --format '{{.Image}}')
[ "$RUNNING_IMG" = "$EXPECTED_IMAGE" ] \
  || die "running panel image is '$RUNNING_IMG', expected $EXPECTED_IMAGE; refuse"

log "pre-check: all agents must be 0.5.0 with fresh signed heartbeats"
python3 - <<'PY' || die "pre-check failed — refuse to enable REQUIRE"
import sqlite3, time, sys
from datetime import datetime
db = sqlite3.connect("file:/var/lib/family-vpn/panel/family-vpn.sqlite?mode=ro", uri=True)
db.row_factory = sqlite3.Row
rows = db.execute(
    """
    SELECT s.name, s.agent_version, s.last_seen_at, a.version AS av,
           length(a.public_key) AS pk, a.revoked_at
    FROM servers s LEFT JOIN agents a ON a.server_id = s.id
    """
).fetchall()
if not rows:
    print("no servers", file=sys.stderr); sys.exit(1)
now = time.time()
for r in rows:
    if r["revoked_at"]:
        print(f"{r['name']}: revoked", file=sys.stderr); sys.exit(1)
    if r["agent_version"] != "0.5.0" or r["av"] != "0.5.0":
        print(f"{r['name']}: version {r['agent_version']}/{r['av']} (need 0.5.0)", file=sys.stderr); sys.exit(1)
    if not r["pk"]:
        print(f"{r['name']}: missing agent public key", file=sys.stderr); sys.exit(1)
    seen = datetime.fromisoformat(r["last_seen_at"].replace("Z", "+00:00")).timestamp()
    age = int(now - seen)
    if age > 120:
        print(f"{r['name']}: last_seen too old ({age}s)", file=sys.stderr); sys.exit(1)
    print(f"OK {r['name']}: agent 0.5.0 last_seen_age={age}s pubkey_len={r['pk']} signed_hb_ready=true")
PY

# Backup env only (does not touch SQLite). Record exact path for unambiguous rollback.
stamp=$(date -u +%Y%m%dT%H%M%SZ)
bak="/etc/family-vpn/panel.env.bak-require-hb-$stamp"
cp -a "$ENV_FILE" "$bak"
chmod 600 "$bak"
printf '%s\n' "$bak" >"$BAK_PATH_FILE"
chmod 600 "$BAK_PATH_FILE"
log "panel.env backup (exact): $bak"
log "rollback pointer: $BAK_PATH_FILE"

if grep -q '^FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=' "$ENV_FILE"; then
  sed -i 's/^FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=.*/FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1/' "$ENV_FILE"
else
  printf '\nFAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1\n' >>"$ENV_FILE"
fi
chmod 600 "$ENV_FILE"
grep -qx 'FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1' "$ENV_FILE" || die "failed to set REQUIRE flag"

export FAMILY_VPN_PANEL_IMAGE="$EXPECTED_IMAGE"
log "recreate panel only (pinned image=$FAMILY_VPN_PANEL_IMAGE); caddy/data untouched"

docker compose \
  --project-name family-vpn \
  --project-directory "$COMPOSE_DIR" \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_DIR/docker-compose.yml" \
  -f "$COMPOSE_DIR/docker-compose.image.yml" \
  up -d --no-build --pull never --force-recreate --no-deps panel \
  || die "compose recreate failed; restore with: cp -a $bak $ENV_FILE && recreate panel"

# Confirm new container still uses the pinned digest.
P2=$(docker ps -q -f label=com.docker.compose.service=panel -f label=com.docker.compose.project=family-vpn | head -n1)
[ -n "$P2" ] || die "panel container missing after recreate"
NEW_IMG=$(docker inspect "$P2" --format '{{.Image}}')
[ "$NEW_IMG" = "$EXPECTED_IMAGE" ] \
  || die "after recreate image is '$NEW_IMG', expected $EXPECTED_IMAGE"
ENV_IN_CTR=$(docker exec "$P2" printenv FAMILY_VPN_REQUIRE_HEARTBEAT_SIG || true)
[ "$ENV_IN_CTR" = "1" ] || die "container env FAMILY_VPN_REQUIRE_HEARTBEAT_SIG='$ENV_IN_CTR' (want 1)"
log "image pin ok: $NEW_IMG; REQUIRE in container=1"

log "wait for HTTPS + Online + signed heartbeat under REQUIRE..."
ok=0
for i in $(seq 1 36); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${PANEL_IP}/login" || true)
  if [ "$code" = "200" ]; then
    if python3 - <<'PY'
import sqlite3, time, sys
from datetime import datetime
db = sqlite3.connect("file:/var/lib/family-vpn/panel/family-vpn.sqlite?mode=ro", uri=True)
db.row_factory = sqlite3.Row
now = time.time()
rows = db.execute(
    """
    SELECT s.name, s.agent_version, s.last_seen_at, a.version AS av,
           length(a.public_key) AS pk, a.revoked_at
    FROM servers s LEFT JOIN agents a ON a.server_id = s.id
    """
).fetchall()
if not rows:
    raise SystemExit(1)
for r in rows:
    if r["revoked_at"] or r["agent_version"] != "0.5.0" or r["av"] != "0.5.0" or not r["pk"]:
        raise SystemExit(1)
    age = int(now - datetime.fromisoformat(r["last_seen_at"].replace("Z", "+00:00")).timestamp())
    # After recreate, require a heartbeat newer than ~3 minutes (agent interval).
    if age > 180:
        raise SystemExit(1)
    print(f"online_signed_ok name={r['name']} age_sec={age}")
PY
    then
      ok=1
      break
    fi
  fi
  sleep 5
done
[ "$ok" = "1" ] || die "Online/signed heartbeat check failed — rollback: cp -a $(cat $BAK_PATH_FILE) $ENV_FILE && FAMILY_VPN_PANEL_IMAGE=$EXPECTED_IMAGE docker compose --project-name family-vpn --project-directory $COMPOSE_DIR --env-file $ENV_FILE -f $COMPOSE_DIR/docker-compose.yml -f $COMPOSE_DIR/docker-compose.image.yml up -d --no-build --pull never --force-recreate --no-deps panel"

log "REQUIRE_HEARTBEAT_SIG_OK image=$EXPECTED_IMAGE backup=$bak"
log "exact rollback command:"
log "  cp -a $bak $ENV_FILE && FAMILY_VPN_PANEL_IMAGE=$EXPECTED_IMAGE docker compose --project-name family-vpn --project-directory $COMPOSE_DIR --env-file $ENV_FILE -f $COMPOSE_DIR/docker-compose.yml -f $COMPOSE_DIR/docker-compose.image.yml up -d --no-build --pull never --force-recreate --no-deps panel"
