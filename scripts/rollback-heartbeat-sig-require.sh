#!/bin/bash
# Roll back FAMILY_VPN_REQUIRE_HEARTBEAT_SIG using the exact panel.env backup
# recorded by enable-heartbeat-sig-require.sh (no glob).
set -euo pipefail
umask 077

ENV_FILE=/etc/family-vpn/panel.env
COMPOSE_DIR=/opt/family-vpn/install/panel
EXPECTED_IMAGE=sha256:7a14eb9234f77fa3ae6e51c4af6567fe1f62292dc8bbf21ee8c494575e3d9ed8
BAK_PATH_FILE=/etc/family-vpn/panel.env.bak-require-hb.path

die() { printf 'family-vpn-require-hb-sig-rollback: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$BAK_PATH_FILE" ] || die "missing $BAK_PATH_FILE (enable script did not record a backup path)"
bak=$(tr -d '[:space:]' <"$BAK_PATH_FILE")
[ -n "$bak" ] || die "empty backup path in $BAK_PATH_FILE"
[ -f "$bak" ] || die "backup file missing: $bak"
case "$bak" in
  /etc/family-vpn/panel.env.bak-require-hb-*) ;;
  *) die "refusing unexpected backup path: $bak" ;;
esac

log "restoring panel.env from exact backup: $bak"
cp -a "$bak" "$ENV_FILE"
chmod 600 "$ENV_FILE"
# Ensure REQUIRE is not forced to 1 after restore (backup may predate the flag).
if grep -q '^FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1$' "$ENV_FILE"; then
  die "restored env still has REQUIRE=1; refusing ambiguous rollback"
fi

export FAMILY_VPN_PANEL_IMAGE="$EXPECTED_IMAGE"
docker compose \
  --project-name family-vpn \
  --project-directory "$COMPOSE_DIR" \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_DIR/docker-compose.yml" \
  -f "$COMPOSE_DIR/docker-compose.image.yml" \
  up -d --no-build --pull never --force-recreate --no-deps panel \
  || die "compose recreate failed after env restore"

P=$(docker ps -q -f label=com.docker.compose.service=panel -f label=com.docker.compose.project=family-vpn | head -n1)
[ -n "$P" ] || die "panel not running after rollback"
IMG=$(docker inspect "$P" --format '{{.Image}}')
[ "$IMG" = "$EXPECTED_IMAGE" ] || die "image after rollback is '$IMG', expected $EXPECTED_IMAGE"
log "ROLLBACK_OK restored_from=$bak image=$IMG"
