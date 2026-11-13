#!/bin/bash
# Publish signed release assets onto the LIVE panel /releases/ mount.
# Does NOT restart the panel stack, does NOT touch SQLite/master.key/WireGuard,
# does NOT delete /var/lib/family-vpn. Overwrites only files under the releases dir.
#
# Usage:
#   export GH_TOKEN=...   # repo read; never commit this
#   sudo -E bash publish-releases-to-panel.sh
#   # or offline:
#   sudo bash publish-releases-to-panel.sh --from-dir /tmp/fvpn-release-stage
set -euo pipefail
umask 022

TAG=${FAMILY_VPN_RELEASE_TAG:-panel-936a5e9b2ccb}
REPO=${FAMILY_VPN_REPO:-iaremadenis-dev/family-vpn}
FROM_DIR=""
DRY_RUN=0
OLD_DIGEST=${FAMILY_VPN_PREV_PANEL_DIGEST:-sha256:b5a719f0148019784f4eb544289fb2acb4174cf1c8b76e70f18f73ac37b09479}
FP_EXPECTED=1ec270a068a05c1e1af1a29953e92a29c6c518e0b43b90f1a1f417e47d59e259
AGENT_BOOT_SHA_EXPECTED=${FAMILY_VPN_BOOTSTRAP_SHA:-f2d7d938999a40e4d7205e2cdac0282858a6127120eddb5d0c740afdd0dea296}

die() { printf 'family-vpn-publish: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from-dir) FROM_DIR=${2:-}; shift 2 ;;
    --tag) TAG=${2:-}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"

detect_releases_dir() {
  local mount_src compose_dir
  # Prefer the live Caddy bind mount (survives wiped ComposeDir under /tmp).
  mount_src=$(docker inspect family-vpn-caddy --format '{{range .Mounts}}{{if eq .Destination "/srv/releases"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
  if [ -n "$mount_src" ]; then
    mkdir -p "$mount_src"
    printf '%s\n' "$(cd "$mount_src" && pwd)"
    return 0
  fi
  compose_dir=$(docker inspect family-vpn-caddy --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
  if [ -z "$compose_dir" ]; then
    compose_dir=$(docker inspect family-vpn-panel --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
  fi
  if [ -n "$compose_dir" ] && [ -d "$(dirname "$compose_dir")/releases" ]; then
    printf '%s\n' "$(cd "$(dirname "$compose_dir")/releases" && pwd)"
    return 0
  fi
  if [ -d /opt/family-vpn/install/releases ]; then
    printf '%s\n' /opt/family-vpn/install/releases
    return 0
  fi
  if [ -d /tmp/family-vpn-install/releases ]; then
    printf '%s\n' /tmp/family-vpn-install/releases
    return 0
  fi
  return 1
}

RELEASES=$(detect_releases_dir) || die "cannot locate live ../releases mount (is the panel stack running?)"
log "live releases dir: $RELEASES"

# Refuse anything that looks like panel data.
case "$RELEASES" in
  /var/lib/family-vpn/*|/etc/family-vpn/*)
    die "refusing to write into $RELEASES"
    ;;
esac
[ -d /var/lib/family-vpn/panel ] || die "panel data dir missing; abort"
[ -f /var/lib/family-vpn/panel/family-vpn.sqlite ] || die "panel sqlite missing; abort"
[ -f /var/lib/family-vpn/panel/master.key ] || die "master.key missing; abort"

STAGE=$(mktemp -d /tmp/fvpn-publish-XXXXXX)
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

if [ -n "$FROM_DIR" ]; then
  [ -d "$FROM_DIR" ] || die "--from-dir not a directory: $FROM_DIR"
  cp -a "$FROM_DIR"/. "$STAGE/"
else
  command -v gh >/dev/null 2>&1 || die "gh not installed; use --from-dir with pre-downloaded assets"
  [ -n "${GH_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}" ] || die "set GH_TOKEN (private release) or use --from-dir"
  log "downloading GitHub release $TAG (auth via GH_TOKEN; token not printed)"
  gh release download "$TAG" -R "$REPO" -D "$STAGE"
fi

[ -f "$STAGE/PANEL-UPDATE.txt" ] || die "missing PANEL-UPDATE.txt in stage"
panel_update_field() {
  awk -F= -v k="$1" '$1==k { print substr($0, index($0,"=")+1); exit }' "$STAGE/PANEL-UPDATE.txt"
}
BOOT=$(panel_update_field PANEL_UPDATE_BOOT)
ARCHIVE=$(panel_update_field PANEL_UPDATE_ARCHIVE)
BOOT_SHA_EXPECTED=$(panel_update_field PANEL_UPDATE_BOOT_SHA256)
NEW_DIGEST=$(panel_update_field IMAGE_DIGEST)
[ -n "$BOOT" ] && [ -n "$ARCHIVE" ] && [ -n "$BOOT_SHA_EXPECTED" ] && [ -n "$NEW_DIGEST" ] \
  || die "PANEL-UPDATE.txt incomplete (BOOT/ARCHIVE/SHA/DIGEST)"

required=(
  "$BOOT"
  "$ARCHIVE"
  "${ARCHIVE}.sha256"
  "${ARCHIVE}.sig"
  family-vpn-panel-image.tar
  family-vpn-panel-image.tar.sha256
  bootstrap.sh
  install.sh
  install.sh.sig
  family-vpn-agent-linux-amd64
  SHA256SUMS
  release-signing.pub
  INSTALL.txt
  PANEL-UPDATE.txt
)
for name in "${required[@]}"; do
  [ -f "$STAGE/$name" ] || die "missing asset in stage: $name"
done

# Quick integrity checks before publish.
(cd "$STAGE" && sha256sum -c "${ARCHIVE}.sha256")
(cd "$STAGE" && sha256sum -c family-vpn-panel-image.tar.sha256)
(cd "$STAGE" && sha256sum -c SHA256SUMS)
echo "$FP_EXPECTED  $STAGE/release-signing.pub" | sha256sum -c -
grep -q 'AGENT_VERSION="0.5.0"' "$STAGE/install.sh"
# Panel update pack must pin the NEW digest (not the old production image).
BUNDLE_INFO=$(tar -xOf "$STAGE/$ARCHIVE" family-vpn-panel-update/BUNDLE-INFO.txt)
printf '%s\n' "$BUNDLE_INFO" | grep -qF "image_digest=$NEW_DIGEST" \
  || die "update pack missing NEW digest $NEW_DIGEST"
if printf '%s\n' "$BUNDLE_INFO" | grep -qF "image_digest=$OLD_DIGEST"; then
  die "update pack still pins OLD digest $OLD_DIGEST"
fi

BOOT_SHA=$(sha256sum "$STAGE/$BOOT" | awk '{print $1}')
AGENT_BOOT_SHA=$(sha256sum "$STAGE/bootstrap.sh" | awk '{print $1}')
[ "$BOOT_SHA" = "$BOOT_SHA_EXPECTED" ] || die "panel-update-boot SHA mismatch: $BOOT_SHA want $BOOT_SHA_EXPECTED"
[ "$AGENT_BOOT_SHA" = "$AGENT_BOOT_SHA_EXPECTED" ] || die "bootstrap.sh SHA mismatch: $AGENT_BOOT_SHA"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY_RUN ok — would copy $(find "$STAGE" -type f | wc -l) files into $RELEASES"
  log "panel data dirs untouched"
  exit 0
fi

install -d -m 755 "$RELEASES"
# Additive overwrite of release files only. Never rm -rf the directory.
for name in "${required[@]}"; do
  install -m 644 "$STAGE/$name" "$RELEASES/$name"
done
chmod 755 "$RELEASES/$BOOT" \
  "$RELEASES/bootstrap.sh" \
  "$RELEASES/install.sh" \
  "$RELEASES/family-vpn-agent-linux-amd64"

# Optional install pack / summary files if present
for name in family-vpn-install-*.tar.gz \
  family-vpn-install-*.tar.gz.sha256 \
  IMAGE-INSTALL.txt RELEASE-SUMMARY.txt \
  panel-image-id.txt panel-image-commit.txt; do
  for f in "$STAGE"/$name; do
    [ -f "$f" ] || continue
    install -m 644 "$f" "$RELEASES/$(basename "$f")"
  done
done

log "PUBLISH_OK releases=$RELEASES"
log "verify: curl -fsS https://127.0.0.1/releases/bootstrap.sh | sha256sum  (via public URL)"
log "DE-01 next:"
log "curl -fsSL https://62.133.60.25/releases/$BOOT -o /tmp/fvpn-panel-boot.sh && echo '$BOOT_SHA_EXPECTED  /tmp/fvpn-panel-boot.sh' | sha256sum -c - && sudo bash /tmp/fvpn-panel-boot.sh"
