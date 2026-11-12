#!/bin/bash
# Pack a signed panel update bundle for image-based production installs.
# Includes compose files + update-panel.sh + agent releases. Image tar is adjacent.
# Does not upload or deploy.
set -euo pipefail
umask 022

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${FAMILY_VPN_BUNDLE_DIR:-$ROOT/dist}
COMMIT=$(git -C "$ROOT" rev-parse HEAD)
SHORT=$(git -C "$ROOT" rev-parse --short=12 HEAD)
IMAGE_REF=${FAMILY_VPN_PANEL_IMAGE:-}
DIGEST=${FAMILY_VPN_PANEL_DIGEST:-}
PUBLIC_URL=${FAMILY_VPN_PUBLIC_URL:-https://panel.example.com}
PUBLIC_URL=${PUBLIC_URL%/}

die() { printf 'family-vpn-panel-update-pack: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --image-ref) IMAGE_REF=${2:-}; shift 2 ;;
    --digest) DIGEST=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$DIGEST" ] || {
  if [ -f "$OUT/panel-image-id.txt" ]; then
    DIGEST=$(tr -d '[:space:]' <"$OUT/panel-image-id.txt")
  fi
}
[ -n "$DIGEST" ] || die "pass --digest or build image first (scripts/build-panel-image.sh)"
if ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  die "digest must look like sha256: + 64 hex"
fi
[ -n "$IMAGE_REF" ] || IMAGE_REF=$DIGEST
case "$IMAGE_REF" in
  "$DIGEST"|*"@${DIGEST}") ;;
  *) die "image-ref must be digest or end with @$DIGEST" ;;
esac

[ -f "$ROOT/releases/SHA256SUMS" ] || die "missing releases/SHA256SUMS (run build-release.sh first)"
[ -f "$ROOT/releases/install.sh.sig" ] || die "missing releases/install.sh.sig (signed agent release required)"
[ -f "$ROOT/keys/release-signing.pub" ] || die "missing keys/release-signing.pub"
[ -f "$ROOT/panel/update-panel.sh" ] || die "missing panel/update-panel.sh"

scan_tree() {
  local dir=$1
  local forbidden
  forbidden=$(find "$dir" -type f \( \
    -name '.env' -o -name '.env.*' -o -name 'master.key' -o -name '*.sqlite' \
    -o -name '*.age' -o -name 'id_rsa' -o -name 'release-signing.pem' \
    \) -print)
  if [ -n "$forbidden" ]; then
    printf '%s\n' "$forbidden" >&2
    die "forbidden file in update package"
  fi
  if grep -I -R -E -n \
    -e 'AGE-SECRET-KEY-1[A-Za-z0-9]{8,}' \
    -e '-----BEGIN (OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----' \
    -e 'ghp_[A-Za-z0-9]{20,}' \
    "$dir"; then
    die "secret material in update package"
  fi
}

if [ -z "${FAMILY_VPN_RELEASE_SIGNING_KEY:-}" ] \
  && [ ! -f "$ROOT/keys/release-signing.pem" ] \
  && [ -z "${FAMILY_VPN_RELEASE_SIGNING_KEY_FILE:-}" ]; then
  die "production signing key required"
fi

stage=$(mktemp -d)
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
pack="$stage/family-vpn-panel-update"
mkdir -p "$pack/panel/systemd" "$pack/releases"

files=(
  update-panel.sh
  install-panel.sh
  docker-compose.yml
  docker-compose.image.yml
  Caddyfile.bootstrap
  Caddyfile.https
  renew-cert.sh
  certbot-requirements.txt
  backup-panel.sh
  backup-wg.sh
  restore-panel.sh
  restore-wg.sh
  push-restore.sh
  archive-tool.mjs
  archive_host.py
  s3_store.py
  backup.env.example
)
for name in "${files[@]}"; do
  cp "$ROOT/panel/$name" "$pack/panel/$name"
  chmod 644 "$pack/panel/$name"
done
chmod 755 "$pack/panel/"*.sh
cp -a "$ROOT/panel/systemd/." "$pack/panel/systemd/"

# Agent release artifacts for /releases mount after relocate.
for name in family-vpn-agent-linux-amd64 install.sh install.sh.sig release-signing.pub \
  SHA256SUMS bootstrap.sh INSTALL.txt; do
  [ -f "$ROOT/releases/$name" ] || continue
  cp "$ROOT/releases/$name" "$pack/releases/$name"
  chmod 644 "$pack/releases/$name"
done
chmod 755 "$pack/releases/family-vpn-agent-linux-amd64" "$pack/releases/install.sh" \
  "$pack/releases/bootstrap.sh" 2>/dev/null || true

cat >"$pack/BUNDLE-INFO.txt" <<EOF
source_commit=$COMMIT
bundle=panel-update
image_ref=$IMAGE_REF
image_digest=$DIGEST
schema_min=1
schema_max=4
rollback_hint=panel-d587d590518d
EOF

PREV_DIGEST=${FAMILY_VPN_PREV_PANEL_DIGEST:-sha256:b5a719f0148019784f4eb544289fb2acb4174cf1c8b76e70f18f73ac37b09479}
printf '%s\n' "$PREV_DIGEST" >"$pack/ROLLBACK-IMAGE.txt"

cp "$ROOT/keys/release-signing.pub" "$pack/release-signing.pub"
chmod 644 "$pack/release-signing.pub"
PUB_FP=$(sha256sum "$pack/release-signing.pub" | awk '{print $1}')

cat >"$pack/apply-update.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
umask 077
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
sha256sum -c MANIFEST
EXPECTED_PUB_FP=$(cat EXPECTED_PUB_FP)
echo "$EXPECTED_PUB_FP  release-signing.pub" | sha256sum -c -
SIG_B64=$(tr -d '\n' <UPDATE.sig | tr '_-' '/+')
case $(( ${#SIG_B64} % 4 )) in
  2) SIG_B64="${SIG_B64}==" ;;
  3) SIG_B64="${SIG_B64}=" ;;
esac
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '%s' "$SIG_B64" | openssl base64 -d -A -out "$TMP"
# Signed payload is the MANIFEST file (lists every member hash).
openssl pkeyutl -verify -pubin -inkey release-signing.pub -rawin -in MANIFEST -sigfile "$TMP" >/dev/null \
  || { echo "family-vpn-panel-update: signature rejected" >&2; exit 1; }
if [ -f family-vpn-panel-image.tar ]; then
  export FAMILY_VPN_PANEL_IMAGE_TAR="$PWD/family-vpn-panel-image.tar"
fi
exec bash ./panel/update-panel.sh "$@"
EOF
chmod 755 "$pack/apply-update.sh"

# Optional: embed image tar if present in dist/
if [ -f "$OUT/family-vpn-panel-image.tar" ]; then
  cp "$OUT/family-vpn-panel-image.tar" "$pack/family-vpn-panel-image.tar"
  chmod 644 "$pack/family-vpn-panel-image.tar"
  if [ -f "$OUT/family-vpn-panel-image.tar.sha256" ]; then
    cp "$OUT/family-vpn-panel-image.tar.sha256" "$pack/family-vpn-panel-image.tar.sha256"
    chmod 644 "$pack/family-vpn-panel-image.tar.sha256"
  fi
fi

: >"$pack/MANIFEST"
while IFS= read -r rel; do
  hash=$(sha256sum "$pack/$rel" | awk '{ print $1 }')
  printf '%s  %s\n' "$hash" "$rel" >>"$pack/MANIFEST"
done < <(find "$pack" -type f ! -name MANIFEST ! -name UPDATE.sig ! -name EXPECTED_PUB_FP -printf '%P\n' | sort)

printf '%s\n' "$PUB_FP" >"$pack/EXPECTED_PUB_FP"
scan_tree "$pack"
node "$ROOT/scripts/sign-release-file.mjs" "$pack/MANIFEST"
mv "$pack/MANIFEST.sig" "$pack/UPDATE.sig"

mkdir -p "$OUT"
archive="$OUT/family-vpn-panel-update-$SHORT.tar.gz"
tar -C "$stage" -czf "$archive" family-vpn-panel-update
archive_hash=$(sha256sum "$archive" | awk '{ print $1 }')
printf '%s  %s\n' "$archive_hash" "$(basename "$archive")" >"$archive.sha256"
node "$ROOT/scripts/sign-release-file.mjs" "$archive"

# One-line PuTTY bootstrap (downloads archive from PUBLIC_URL/releases/)
BOOT="$OUT/panel-update-boot-$SHORT.sh"
cat >"$BOOT" <<EOF
#!/bin/bash
# Family VPN panel update bootstrap $SHORT
# Verifies SHA-256 + Ed25519 before apply-update.sh. Does not wipe panel data.
set -euo pipefail
BACKEND="${PUBLIC_URL}"
ARCHIVE_NAME="$(basename "$archive")"
EXPECTED_ARCHIVE_SHA="${archive_hash}"
EXPECTED_PUB_FP="${PUB_FP}"
umask 077
[ "\$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
TMP=\$(mktemp -d)
trap 'rm -rf "\$TMP"' EXIT
curl -fsSL "\$BACKEND/releases/\$ARCHIVE_NAME" -o "\$TMP/\$ARCHIVE_NAME"
curl -fsSL "\$BACKEND/releases/\$ARCHIVE_NAME.sig" -o "\$TMP/\$ARCHIVE_NAME.sig"
curl -fsSL "\$BACKEND/releases/release-signing.pub" -o "\$TMP/release-signing.pub"
echo "\$EXPECTED_ARCHIVE_SHA  \$TMP/\$ARCHIVE_NAME" | sha256sum -c -
echo "\$EXPECTED_PUB_FP  \$TMP/release-signing.pub" | sha256sum -c -
SIG_B64=\$(tr -d '\\n' <"\$TMP/\$ARCHIVE_NAME.sig" | tr '_-' '/+')
case \$(( \${#SIG_B64} % 4 )) in
  2) SIG_B64="\${SIG_B64}==" ;;
  3) SIG_B64="\${SIG_B64}=" ;;
esac
printf '%s' "\$SIG_B64" | openssl base64 -d -A -out "\$TMP/sig.bin"
openssl pkeyutl -verify -pubin -inkey "\$TMP/release-signing.pub" -rawin -in "\$TMP/\$ARCHIVE_NAME" -sigfile "\$TMP/sig.bin" >/dev/null \
  || { echo "panel-update-boot: archive signature rejected" >&2; exit 1; }
mkdir -p "\$TMP/unpack"
tar -xzf "\$TMP/\$ARCHIVE_NAME" -C "\$TMP/unpack"
# If the update archive did not embed the image tar, fetch the digest-pinned tar next to it.
if [ ! -f "\$TMP/unpack/family-vpn-panel-update/family-vpn-panel-image.tar" ]; then
  if curl -fsSL "\$BACKEND/releases/family-vpn-panel-image.tar" -o "\$TMP/family-vpn-panel-image.tar"; then
    curl -fsSL "\$BACKEND/releases/family-vpn-panel-image.tar.sha256" -o "\$TMP/family-vpn-panel-image.tar.sha256"
    (cd "\$TMP" && sha256sum -c family-vpn-panel-image.tar.sha256)
    cp "\$TMP/family-vpn-panel-image.tar" "\$TMP/unpack/family-vpn-panel-update/family-vpn-panel-image.tar"
    cp "\$TMP/family-vpn-panel-image.tar.sha256" "\$TMP/unpack/family-vpn-panel-update/family-vpn-panel-image.tar.sha256"
  fi
fi
exec bash "\$TMP/unpack/family-vpn-panel-update/apply-update.sh" "\$@"
EOF
chmod 755 "$BOOT"
boot_hash=$(sha256sum "$BOOT" | awk '{ print $1 }')

{
  printf '%s\n' "PANEL_UPDATE_ARCHIVE=$(basename "$archive")"
  printf '%s\n' "PANEL_UPDATE_SHA256=$archive_hash"
  printf '%s\n' "PANEL_UPDATE_BOOT=$(basename "$BOOT")"
  printf '%s\n' "PANEL_UPDATE_BOOT_SHA256=$boot_hash"
  printf '%s\n' "IMAGE_DIGEST=$DIGEST"
  printf '%s\n' "SOURCE_COMMIT=$COMMIT"
  printf '%s\n' "PUB_FP=$PUB_FP"
  printf '%s\n' "ROLLBACK_IMAGE=$PREV_DIGEST"
  printf '%s\n' "ONE_COMMAND=curl -fsSL ${PUBLIC_URL}/releases/$(basename "$BOOT") -o /tmp/fvpn-panel-boot.sh && echo '${boot_hash}  /tmp/fvpn-panel-boot.sh' | sha256sum -c - && sudo bash /tmp/fvpn-panel-boot.sh"
} | tee "$OUT/PANEL-UPDATE.txt"

printf '%s\n' "PANEL_UPDATE_OK"
