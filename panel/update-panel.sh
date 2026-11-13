#!/bin/bash
# Update an existing Family VPN panel that was installed from a digest-pinned
# Docker image package (ComposeDir may still be under /tmp/family-vpn-install).
# Does not reinstall Ubuntu, does not delete /var/lib/family-vpn/panel, and does
# not recreate WireGuard. Requires root.
set -euo pipefail
umask 077

SCRIPT_PATH=${BASH_SOURCE[0]:-$0}
BUNDLE_DIR=$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)
PANEL_SRC="$BUNDLE_DIR/panel"
STATE_DIR=${FAMILY_VPN_PANEL_DIR:-/var/lib/family-vpn/panel}
ETC_DIR=/etc/family-vpn
ENV_FILE="$ETC_DIR/panel.env"
INSTALL_ROOT=${FAMILY_VPN_INSTALL_ROOT:-/opt/family-vpn/install}
PREV_FILE="$ETC_DIR/panel-image.prev"
CUR_FILE="$ETC_DIR/panel-image.current"
MODE=update
DRY_RUN=0

die() { printf 'family-vpn-panel-update: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF'
usage:
  update-panel.sh [--dry-run]
  update-panel.sh --rollback
  update-panel.sh --check

Updates the running image-based panel in place.
Preserves SQLite, master.key, HTTPS material, and backups.
Relocates Compose from /tmp/family-vpn-install to /opt/family-vpn/install when needed.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --rollback) MODE=rollback; shift ;;
    --check) MODE=check; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE (panel not installed?)"
[ -f "$STATE_DIR/family-vpn.sqlite" ] || die "missing panel database $STATE_DIR/family-vpn.sqlite"
[ -f "$STATE_DIR/master.key" ] || die "missing $STATE_DIR/master.key"
[ -s "$STATE_DIR/family-vpn.sqlite" ] || die "panel database is empty; refusing update"
[ -s "$STATE_DIR/master.key" ] || die "master.key is empty; refusing update"

# shellcheck disable=SC1091
. "$ENV_FILE"
PANEL_IP=${FAMILY_VPN_PUBLIC_URL#https://}
PANEL_IP=${PANEL_IP#http://}
PANEL_IP=${PANEL_IP%%/*}
[ -n "$PANEL_IP" ] || die "FAMILY_VPN_PUBLIC_URL missing in panel.env"

db_schema_version() {
  local db=$1
  local py=python3
  command -v python3 >/dev/null 2>&1 || py=python
  "$py" -c 'import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
print(int(db.execute("PRAGMA user_version").fetchone()[0]))
' "$db"
}

read_bundle_info() {
  local info="$BUNDLE_DIR/BUNDLE-INFO.txt"
  [ -f "$info" ] || die "missing BUNDLE-INFO.txt in update package"
  IMAGE_REF=$(awk -F= '$1=="image_ref"{print substr($0,index($0,"=")+1); exit}' "$info")
  IMAGE_DIGEST=$(awk -F= '$1=="image_digest"{print substr($0,index($0,"=")+1); exit}' "$info")
  SOURCE_COMMIT=$(awk -F= '$1=="source_commit"{print substr($0,index($0,"=")+1); exit}' "$info")
  SCHEMA_MAX=$(awk -F= '$1=="schema_max"{print substr($0,index($0,"=")+1); exit}' "$info")
  SCHEMA_MIN=$(awk -F= '$1=="schema_min"{print substr($0,index($0,"=")+1); exit}' "$info")
  [ -n "$SCHEMA_MAX" ] || SCHEMA_MAX=4
  [ -n "$SCHEMA_MIN" ] || SCHEMA_MIN=1
  [ -n "$IMAGE_REF" ] && [ -n "$IMAGE_DIGEST" ] || die "BUNDLE-INFO incomplete"
  if ! [[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    die "invalid image_digest in BUNDLE-INFO"
  fi
  case "$IMAGE_REF" in
    "$IMAGE_DIGEST"|*"@${IMAGE_DIGEST}") ;;
    *) die "image_ref is not pinned to image_digest" ;;
  esac
  if ! [[ "$SCHEMA_MAX" =~ ^[0-9]+$ ]] || ! [[ "$SCHEMA_MIN" =~ ^[0-9]+$ ]]; then
    die "invalid schema bounds in BUNDLE-INFO"
  fi
}

assert_schema_compatible() {
  local schema
  schema=$(db_schema_version "$STATE_DIR/family-vpn.sqlite")
  [ "$schema" -ge "$SCHEMA_MIN" ] || die "DB schema $schema older than supported minimum $SCHEMA_MIN"
  [ "$schema" -le "$SCHEMA_MAX" ] || die "DB schema $schema newer than this update (max $SCHEMA_MAX); refuse downgrade via image"
  log "schema compatibility ok: db=$schema bounds=${SCHEMA_MIN}..${SCHEMA_MAX}"
}

restore_data_from_backup() {
  local bak=$1
  [ -d "$bak" ] || die "backup dir missing: $bak"
  [ -s "$bak/family-vpn.sqlite" ] || die "backup DB missing"
  [ -s "$bak/master.key" ] || die "backup master.key missing"
  # Stop writers briefly by restarting after copy; never delete the live dir.
  cp -a "$bak/family-vpn.sqlite" "$STATE_DIR/family-vpn.sqlite"
  if [ -f "$bak/family-vpn.sqlite-wal" ]; then
    cp -a "$bak/family-vpn.sqlite-wal" "$STATE_DIR/family-vpn.sqlite-wal"
  else
    rm -f "$STATE_DIR/family-vpn.sqlite-wal"
  fi
  if [ -f "$bak/family-vpn.sqlite-shm" ]; then
    cp -a "$bak/family-vpn.sqlite-shm" "$STATE_DIR/family-vpn.sqlite-shm"
  else
    rm -f "$STATE_DIR/family-vpn.sqlite-shm"
  fi
  cp -a "$bak/master.key" "$STATE_DIR/master.key"
  chmod 600 "$STATE_DIR/family-vpn.sqlite" "$STATE_DIR/master.key"
  assert_admin_present
  log "data restored from $bak"
}

inspect_compose_label() {
  local key=$1
  docker inspect family-vpn-panel --format "{{index .Config.Labels \"$key\"}}" 2>/dev/null || true
}

inspect_mount_source() {
  local container=$1
  local dest=$2
  docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "'"$dest"'"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true
}

compose_project_name() {
  local name
  name=$(inspect_compose_label 'com.docker.compose.project')
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  printf '%s\n' 'family-vpn'
}

compose_at() {
  local dir=$1
  shift
  local project
  project=$(compose_project_name)
  local -a files=(-f "$dir/docker-compose.yml" -f "$dir/docker-compose.image.yml")
  env FAMILY_VPN_PANEL_IMAGE="${FAMILY_VPN_PANEL_IMAGE:-}" \
    docker compose --project-name "$project" --project-directory "$dir" --env-file "$ENV_FILE" "${files[@]}" "$@"
}

# Refuse update when live bind mounts do not match the permanent data/TLS paths.
assert_live_bind_mounts() {
  local panel_data caddyfile_src certs_src acme_src
  docker ps --format '{{.Names}}' | grep -qx 'family-vpn-panel' \
    || die "panel container not running; refuse update"
  docker ps --format '{{.Names}}' | grep -qx 'family-vpn-caddy' \
    || die "caddy container not running; refuse update"

  panel_data=$(inspect_mount_source family-vpn-panel /data)
  [ -n "$panel_data" ] || die "panel /data mount missing in docker inspect; refuse"
  [ "$panel_data" = "$STATE_DIR" ] \
    || die "panel /data mount is '$panel_data', expected $STATE_DIR; refuse (no production changes)"

  caddyfile_src=$(inspect_mount_source family-vpn-caddy /etc/caddy/Caddyfile)
  [ "$caddyfile_src" = "$ETC_DIR/Caddyfile" ] \
    || die "caddy Caddyfile mount is '$caddyfile_src', expected $ETC_DIR/Caddyfile; refuse"

  certs_src=$(inspect_mount_source family-vpn-caddy /certs)
  [ "$certs_src" = "/var/lib/family-vpn/certs" ] \
    || die "caddy /certs mount is '$certs_src', expected /var/lib/family-vpn/certs; refuse"

  acme_src=$(inspect_mount_source family-vpn-caddy /acme)
  if [ -n "$acme_src" ] && [ "$acme_src" != "/var/lib/family-vpn/acme" ]; then
    die "caddy /acme mount is '$acme_src', expected /var/lib/family-vpn/acme; refuse"
  fi

  [ -s "$STATE_DIR/family-vpn.sqlite" ] || die "sqlite missing/empty at inspected mount $STATE_DIR"
  [ -s "$STATE_DIR/master.key" ] || die "master.key missing/empty at inspected mount $STATE_DIR"
  [ -f "$ETC_DIR/Caddyfile" ] || die "missing host Caddyfile $ETC_DIR/Caddyfile"
  [ -d /var/lib/family-vpn/certs ] || die "missing host certs dir /var/lib/family-vpn/certs"
  log "live mounts ok: data=$panel_data caddyfile=$caddyfile_src certs=$certs_src"
}

restore_compose_from_bundle() {
  [ -d "$PANEL_SRC" ] || die "update package missing panel/ (cannot restore ComposeDir)"
  [ -f "$PANEL_SRC/docker-compose.yml" ] || die "signed package missing docker-compose.yml"
  [ -f "$PANEL_SRC/docker-compose.image.yml" ] || die "signed package missing docker-compose.image.yml"
  mkdir -p "$INSTALL_ROOT/panel" "$INSTALL_ROOT/releases"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY_RUN would restore Compose files into $INSTALL_ROOT/panel from signed package"
    return 0
  fi
  # Materialize compose + helper scripts from the verified signed update package only.
  local name
  for name in \
    docker-compose.yml docker-compose.image.yml \
    Caddyfile.bootstrap Caddyfile.https \
    renew-cert.sh backup-panel.sh backup-wg.sh \
    restore-panel.sh restore-wg.sh push-restore.sh \
    archive-tool.mjs archive_host.py s3_store.py \
    backup.env.example certbot-requirements.txt \
    update-panel.sh install-panel.sh
  do
    [ -f "$PANEL_SRC/$name" ] || continue
    cp "$PANEL_SRC/$name" "$INSTALL_ROOT/panel/$name"
  done
  chmod 644 "$INSTALL_ROOT/panel/"* 2>/dev/null || true
  chmod 755 "$INSTALL_ROOT/panel/"*.sh 2>/dev/null || true
  if [ -d "$PANEL_SRC/systemd" ]; then
    mkdir -p "$INSTALL_ROOT/panel/systemd"
    cp -a "$PANEL_SRC/systemd/." "$INSTALL_ROOT/panel/systemd/"
  fi
  # Prefer copying whatever the live caddy releases mount still has (may be /tmp after wipe).
  local live_releases
  live_releases=$(inspect_mount_source family-vpn-caddy /srv/releases)
  if [ -n "$live_releases" ] && [ -d "$live_releases" ]; then
    cp -a "$live_releases/." "$INSTALL_ROOT/releases/" 2>/dev/null || true
  fi
  if [ -d "$BUNDLE_DIR/releases" ]; then
    cp -a "$BUNDLE_DIR/releases/." "$INSTALL_ROOT/releases/"
  fi
  if [ -f "$ETC_DIR/renew.env" ]; then
    sed -i "s#^COMPOSE_PROJECT_DIR=.*#COMPOSE_PROJECT_DIR=$INSTALL_ROOT/panel#" "$ETC_DIR/renew.env" || true
    sed -i "s#^COMPOSE_FILE=.*#COMPOSE_FILE=$INSTALL_ROOT/panel/docker-compose.yml#" "$ETC_DIR/renew.env" || true
  fi
  log "restored ComposeDir from signed package -> $INSTALL_ROOT/panel"
}

detect_running_compose_dir() {
  local path
  path=$(inspect_compose_label 'com.docker.compose.project.working_dir')
  if [ -n "$path" ] && [ -d "$path" ] && [ -f "$path/docker-compose.yml" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [ -f "$INSTALL_ROOT/panel/docker-compose.yml" ]; then
    printf '%s\n' "$INSTALL_ROOT/panel"
    return 0
  fi
  if [ -f /tmp/family-vpn-install/panel/docker-compose.yml ]; then
    printf '%s\n' /tmp/family-vpn-install/panel
    return 0
  fi
  # Label points at a wiped path (typical: /tmp/... after reboot) but containers still run.
  # Message on stderr so command substitution only captures the sentinel path.
  if [ -n "$path" ] && [ ! -d "$path" ]; then
    printf 'family-vpn-panel-update: ComposeDir missing on disk: %s (containers still labeled); will restore under %s\n' \
      "$path" "$INSTALL_ROOT/panel" >&2
    printf '%s\n' "__MISSING__:$path"
    return 0
  fi
  return 1
}

current_image_id() {
  docker inspect family-vpn-panel --format '{{.Image}}' 2>/dev/null || true
}

admin_row_present() {
  local db=${1:-$STATE_DIR/family-vpn.sqlite}
  command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || return 1
  local py=python3
  command -v python3 >/dev/null 2>&1 || py=python
  "$py" -c 'import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
row=db.execute("select id from admin where id=1").fetchone()
raise SystemExit(0 if row else 1)
' "$db"
}

assert_admin_present() {
  admin_row_present "$STATE_DIR/family-vpn.sqlite" \
    || die "administrator row missing; refusing to replace a possibly empty DB"
}

backup_before_update() {
  local stamp bak
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  bak="/var/lib/family-vpn/backups/panel-pre-update-$stamp"
  mkdir -p /var/lib/family-vpn/backups "$bak"
  chmod 700 /var/lib/family-vpn/backups "$bak" 2>/dev/null || true
  cp -a "$STATE_DIR/family-vpn.sqlite" "$bak/family-vpn.sqlite"
  if [ -f "$STATE_DIR/family-vpn.sqlite-wal" ]; then
    cp -a "$STATE_DIR/family-vpn.sqlite-wal" "$bak/family-vpn.sqlite-wal"
  fi
  if [ -f "$STATE_DIR/family-vpn.sqlite-shm" ]; then
    cp -a "$STATE_DIR/family-vpn.sqlite-shm" "$bak/family-vpn.sqlite-shm"
  fi
  cp -a "$STATE_DIR/master.key" "$bak/master.key"
  cp -a "$ENV_FILE" "$bak/panel.env"
  if [ -f "$ETC_DIR/Caddyfile" ]; then
    cp -a "$ETC_DIR/Caddyfile" "$bak/Caddyfile"
  fi
  chmod -R go-rwx "$bak"
  # Restore-readiness: sqlite opens and admin row still present in the copy.
  assert_admin_present
  admin_row_present "$bak/family-vpn.sqlite" || die "backup copy failed admin check"
  [ -s "$bak/master.key" ] || die "backup master.key incomplete"
  printf '%s\n' "$bak" >"$ETC_DIR/panel-last-backup.path"
  chmod 600 "$ETC_DIR/panel-last-backup.path"
  log "backup ready: $bak"
}

relocate_install_tree() {
  local from=$1
  local missing_label=""
  case "$from" in
    __MISSING__:*)
      missing_label=${from#__MISSING__:}
      from=""
      ;;
  esac
  mkdir -p /opt/family-vpn "$INSTALL_ROOT"
  if [ -n "$from" ] && [ "$from" = "$INSTALL_ROOT/panel" ]; then
    return 0
  fi
  if [ -n "$missing_label" ]; then
    log "relocating Compose project from missing $missing_label to $INSTALL_ROOT/panel"
    restore_compose_from_bundle
    return 0
  fi
  log "relocating Compose project from $from to $INSTALL_ROOT/panel"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  mkdir -p "$INSTALL_ROOT/panel" "$INSTALL_ROOT/releases"
  if [ ! -d "$from" ]; then
    log "source ComposeDir gone during relocate; restoring from signed package"
    restore_compose_from_bundle
    return 0
  fi
  # Copy compose + scripts from the running tree first (keeps current Caddy templates).
  cp -a "$from/." "$INSTALL_ROOT/panel/"
  if [ -d "$(dirname "$from")/releases" ]; then
    cp -a "$(dirname "$from")/releases/." "$INSTALL_ROOT/releases/" || true
  fi
  # Point renew.env at the permanent directory.
  if [ -f "$ETC_DIR/renew.env" ]; then
    sed -i "s#^COMPOSE_PROJECT_DIR=.*#COMPOSE_PROJECT_DIR=$INSTALL_ROOT/panel#" "$ETC_DIR/renew.env" || true
    sed -i "s#^COMPOSE_FILE=.*#COMPOSE_FILE=$INSTALL_ROOT/panel/docker-compose.yml#" "$ETC_DIR/renew.env" || true
  fi
}

install_bundle_files() {
  [ -d "$PANEL_SRC" ] || die "update package missing panel/"
  mkdir -p "$INSTALL_ROOT/panel" "$INSTALL_ROOT/releases"
  local name
  for name in \
    docker-compose.yml docker-compose.image.yml \
    Caddyfile.bootstrap Caddyfile.https \
    renew-cert.sh backup-panel.sh backup-wg.sh \
    restore-panel.sh restore-wg.sh push-restore.sh \
    archive-tool.mjs archive_host.py s3_store.py \
    backup.env.example certbot-requirements.txt \
    update-panel.sh install-panel.sh
  do
    [ -f "$PANEL_SRC/$name" ] || continue
    cp "$PANEL_SRC/$name" "$INSTALL_ROOT/panel/$name"
    chmod 644 "$INSTALL_ROOT/panel/$name" 2>/dev/null || true
  done
  chmod 755 "$INSTALL_ROOT/panel/"*.sh 2>/dev/null || true
  if [ -d "$PANEL_SRC/systemd" ]; then
    mkdir -p "$INSTALL_ROOT/panel/systemd"
    cp -a "$PANEL_SRC/systemd/." "$INSTALL_ROOT/panel/systemd/"
  fi
  if [ -d "$BUNDLE_DIR/releases" ]; then
    cp -a "$BUNDLE_DIR/releases/." "$INSTALL_ROOT/releases/"
  fi
  cp "$BUNDLE_DIR/BUNDLE-INFO.txt" "$INSTALL_ROOT/BUNDLE-INFO.txt"
  chmod 644 "$INSTALL_ROOT/BUNDLE-INFO.txt" 2>/dev/null || true
}

load_new_image() {
  local tar=${FAMILY_VPN_PANEL_IMAGE_TAR:-}
  if [ -z "$tar" ]; then
    if [ -f "$BUNDLE_DIR/family-vpn-panel-image.tar" ]; then
      tar="$BUNDLE_DIR/family-vpn-panel-image.tar"
    elif [ -f /tmp/family-vpn-panel-image.tar ]; then
      tar=/tmp/family-vpn-panel-image.tar
    fi
  fi
  export FAMILY_VPN_PANEL_IMAGE="$IMAGE_REF"
  export FAMILY_VPN_PANEL_DIGEST="$IMAGE_DIGEST"
  if docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
    local id
    id=$(docker image inspect --format '{{.Id}}' "$IMAGE_REF")
    [ "$id" = "$IMAGE_DIGEST" ] || die "loaded image id $id != $IMAGE_DIGEST"
    return 0
  fi
  [ -n "$tar" ] && [ -f "$tar" ] || die "panel image tar not found (set FAMILY_VPN_PANEL_IMAGE_TAR)"
  if [ -f "${tar}.sha256" ]; then
    (cd "$(dirname "$tar")" && sha256sum -c "$(basename "$tar").sha256") \
      || die "panel image tar checksum mismatch"
  fi
  log "loading panel image from $tar"
  docker load -i "$tar" || die "docker load failed"
  local id
  id=$(docker image inspect --format '{{.Id}}' "$IMAGE_REF")
  [ "$id" = "$IMAGE_DIGEST" ] || die "DIGEST_MISMATCH after load: $id != $IMAGE_DIGEST"
}

record_images() {
  local running
  running=$(current_image_id)
  if [ -n "$running" ]; then
    printf '%s\n' "$running" >"$PREV_FILE"
    chmod 600 "$PREV_FILE"
  fi
  printf '%s\n' "$IMAGE_DIGEST" >"$CUR_FILE"
  chmod 600 "$CUR_FILE"
}

switch_stack() {
  export FAMILY_VPN_PANEL_IMAGE="$IMAGE_REF"
  export FAMILY_VPN_PANEL_DIGEST="$IMAGE_DIGEST"
  compose_at "$INSTALL_ROOT/panel" pull --ignore-buildable >/dev/null 2>&1 || true
  # Ensure Caddy image is present; panel comes from local digest load.
  compose_at "$INSTALL_ROOT/panel" up -d --no-build --pull never \
    || die "compose up failed; data dir $STATE_DIR was not deleted"
}

health_check() {
  local status attempt require=${1:-die}
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    status=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${PANEL_IP}/login" || true)
    if [ "$status" = "200" ]; then
      log "health ok: https://${PANEL_IP}/login -> 200"
      return 0
    fi
    sleep 1
  done
  if [ "$require" = "soft" ]; then
    log "health check failed (HTTP ${status:-none})"
    return 1
  fi
  die "panel did not return HTTP 200 after update; restore from backup / --rollback. Data kept in $STATE_DIR"
}

cmd_check() {
  assert_admin_present
  assert_live_bind_mounts
  local dir
  dir=$(detect_running_compose_dir) || die "compose directory not found"
  case "$dir" in
    __MISSING__:*)
      log "CHECK_OK compose=MISSING(${dir#__MISSING__:}) recover_to=$INSTALL_ROOT/panel image=$(current_image_id) data=$STATE_DIR"
      ;;
    *)
      log "CHECK_OK compose=$dir image=$(current_image_id) data=$STATE_DIR"
      ;;
  esac
}

cmd_rollback() {
  [ -f "$PREV_FILE" ] || die "no previous image recorded in $PREV_FILE"
  local prev
  prev=$(tr -d '[:space:]' <"$PREV_FILE")
  [ -n "$prev" ] || die "previous image id empty"
  docker image inspect "$prev" >/dev/null 2>&1 || die "previous image $prev not present locally"
  assert_live_bind_mounts
  local dir
  dir=$(detect_running_compose_dir) || dir="$INSTALL_ROOT/panel"
  case "$dir" in
    __MISSING__:*)
      restore_compose_from_bundle
      dir="$INSTALL_ROOT/panel"
      ;;
  esac
  [ -d "$dir" ] || die "compose dir missing: $dir"
  export FAMILY_VPN_PANEL_IMAGE="$prev"
  export FAMILY_VPN_PANEL_DIGEST="$prev"
  # Rewrite overlay image ref for compose.
  printf 'services:\n  panel:\n    image: %s\n' "$prev" >"$dir/docker-compose.rollback.yml"
  local project
  project=$(compose_project_name)
  docker compose --project-name "$project" --project-directory "$dir" --env-file "$ENV_FILE" \
    -f "$dir/docker-compose.yml" -f "$dir/docker-compose.rollback.yml" \
    up -d --no-build --pull never \
    || die "rollback compose up failed; data untouched in $STATE_DIR"
  # Optional compatible data rollback when migration left DB incompatible with old image.
  if [ "${FAMILY_VPN_ROLLBACK_DATA:-0}" = "1" ]; then
    local bak=""
    if [ -f "$ETC_DIR/panel-last-backup.path" ]; then
      bak=$(tr -d '[:space:]' <"$ETC_DIR/panel-last-backup.path")
    fi
    [ -n "$bak" ] || die "FAMILY_VPN_ROLLBACK_DATA=1 but panel-last-backup.path missing"
    restore_data_from_backup "$bak"
  fi
  health_check
  log "ROLLBACK_OK image=$prev data_rollback=${FAMILY_VPN_ROLLBACK_DATA:-0}"
}

cmd_update() {
  read_bundle_info
  assert_admin_present
  assert_schema_compatible
  assert_live_bind_mounts
  local from
  from=$(detect_running_compose_dir) || die "cannot locate running ComposeDir"
  case "$from" in
    __MISSING__:*)
      log "current ComposeDir=MISSING(${from#__MISSING__:}) -> recover $INSTALL_ROOT/panel"
      ;;
    *)
      log "current ComposeDir=$from"
      ;;
  esac
  log "current image=$(current_image_id)"
  log "target image=$IMAGE_DIGEST commit=${SOURCE_COMMIT:-unknown}"
  log "compose project=$(compose_project_name)"

  if [ "$DRY_RUN" -eq 1 ]; then
    case "$from" in
      __MISSING__:*)
        log "DRY_RUN would restore Compose from signed package into $INSTALL_ROOT/panel"
        ;;
    esac
    log "DRY_RUN ok (no changes)"
    exit 0
  fi

  local schema_before bak
  schema_before=$(db_schema_version "$STATE_DIR/family-vpn.sqlite")
  backup_before_update
  bak=$(tr -d '[:space:]' <"$ETC_DIR/panel-last-backup.path")
  record_images
  relocate_install_tree "$from"
  install_bundle_files
  # After relocate/restore, always operate from the permanent install root.
  [ -f "$INSTALL_ROOT/panel/docker-compose.yml" ] \
    || die "permanent ComposeDir missing after relocate: $INSTALL_ROOT/panel"
  load_new_image
  switch_stack
  # Confirm DB still present and non-empty after switch — never accept a wiped volume.
  [ -s "$STATE_DIR/family-vpn.sqlite" ] || die "database missing after update"
  [ -s "$STATE_DIR/master.key" ] || die "master.key missing after update"
  if ! admin_row_present "$STATE_DIR/family-vpn.sqlite"; then
    log "admin missing after switch; restoring data from pre-update backup"
    restore_data_from_backup "$bak"
    die "update aborted: empty/new DB detected; data restored from $bak; image may need --rollback"
  fi
  local schema_after
  schema_after=$(db_schema_version "$STATE_DIR/family-vpn.sqlite")
  [ "$schema_after" -ge "$schema_before" ] || die "schema unexpectedly decreased ($schema_before -> $schema_after)"
  printf '%s\n' "$schema_before" >"$ETC_DIR/panel-schema.before"
  printf '%s\n' "$schema_after" >"$ETC_DIR/panel-schema.current"
  chmod 600 "$ETC_DIR/panel-schema.before" "$ETC_DIR/panel-schema.current"
  if ! health_check soft; then
    log "health failed; attempting image rollback + data restore"
    FAMILY_VPN_ROLLBACK_DATA=1 bash "$INSTALL_ROOT/panel/update-panel.sh" --rollback \
      || log "rollback helper also failed; data kept in $STATE_DIR and backup $bak"
    die "update failed health check; attempted rollback. Data kept in $STATE_DIR"
  fi
  log "UPDATE_OK image=$IMAGE_DIGEST install_root=$INSTALL_ROOT schema=$schema_after"
  log "previous image stored in $PREV_FILE (keep panel-d587d590518d for rollback)"
  log "data rollback: FAMILY_VPN_ROLLBACK_DATA=1 bash $INSTALL_ROOT/panel/update-panel.sh --rollback"
  log "local pre-update backup is on-box only; it does not replace offsite age+S3 backup"
  log "updater does not change WireGuard, UFW, NAT, or SSH; host hardening applies on fresh installs"
  log "do NOT set FAMILY_VPN_REQUIRE_HEARTBEAT_SIG until agent 0.5.0 signed heartbeat is verified"
}

case "$MODE" in
  check) cmd_check ;;
  rollback) cmd_rollback ;;
  update) cmd_update ;;
  *) usage; die "unknown mode" ;;
esac
