#!/bin/bash
# Pack the small installer. It contains no panel application source.
# The image digest is written into the package. Nothing is uploaded.
set -euo pipefail
umask 022

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${FAMILY_VPN_BUNDLE_DIR:-$ROOT/dist}
COMMIT=$(git -C "$ROOT" rev-parse HEAD)
SHORT=$(git -C "$ROOT" rev-parse --short=12 HEAD)
IMAGE_REF=${FAMILY_VPN_PANEL_IMAGE:-}
DIGEST=${FAMILY_VPN_PANEL_DIGEST:-}
PUBLIC_URL=${FAMILY_VPN_PUBLIC_URL:-https://62.133.60.25}
PUBLIC_URL=${PUBLIC_URL%/}

die() {
  printf '%s\n' "family-vpn-install-pack: $*" >&2
  exit 1
}

scan_tree() {
  local dir=$1
  local forbidden
  forbidden=$(find "$dir" -type f \( \
    -name '.env' -o -name '.env.*' -o -name 'master.key' -o -name '*.sqlite' \
    -o -name '*.age' -o -name '*.pem' -o -name 'id_rsa' -o -name '*.conf' \
    \) -print)
  if [ -n "$forbidden" ]; then
    printf '%s\n' "$forbidden" >&2
    die "в установочном пакете найден запрещённый файл"
  fi
  if grep -I -R -E -n \
    -e 'AGE-SECRET-KEY-1[A-Za-z0-9]{8,}' \
    -e '-----BEGIN (OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----' \
    -e 'ghp_[A-Za-z0-9]{20,}' \
    -e 'github_pat_[A-Za-z0-9_]{20,}' \
    "$dir"; then
    die "в установочном пакете найден секрет"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --image-ref) IMAGE_REF=${2:-}; shift 2 ;;
    --digest) DIGEST=${2:-}; shift 2 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[ -n "$DIGEST" ] || die "укажите --digest. Сначала соберите образ scripts/build-panel-image.sh"
if ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  die "digest должен иметь вид sha256 и 64 шестнадцатеричных знака"
fi
[ -n "$IMAGE_REF" ] || IMAGE_REF=$DIGEST
case "$IMAGE_REF" in
  "$DIGEST"|*"@${DIGEST}") ;;
  *) die "ссылка образа должна быть digest или заканчиваться на @${DIGEST}" ;;
esac

[ -f "$ROOT/releases/SHA256SUMS" ] || die "нет releases/SHA256SUMS"
[ -f "$ROOT/releases/install.sh.sig" ] || die "нет releases/install.sh.sig (сначала build-release.sh)"
[ -f "$ROOT/keys/release-signing.pub" ] || die "нет keys/release-signing.pub"
if [ -z "${FAMILY_VPN_RELEASE_SIGNING_KEY:-}" ] \
  && [ ! -f "$ROOT/keys/release-signing.pem" ] \
  && [ -z "${FAMILY_VPN_RELEASE_SIGNING_KEY_FILE:-}" ]; then
  die "нужен production signing key для подписи install-пакета"
fi
(
  cd "$ROOT/releases"
  sha256sum -c SHA256SUMS
) || die "контрольная сумма агента не совпала"
cmp -s "$ROOT/installer/install.sh" "$ROOT/releases/install.sh" \
  || die "releases/install.sh не совпадает с installer/install.sh"

stage=$(mktemp -d)
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
pack="$stage/family-vpn-install"
mkdir -p "$pack/panel/systemd" "$pack/releases"

files=(
  install-panel.sh
  update-panel.sh
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
  install -m 644 "$ROOT/panel/$name" "$pack/panel/$name"
done
chmod 755 "$pack/panel/install-panel.sh" "$pack/panel/update-panel.sh" \
  "$pack/panel/renew-cert.sh" \
  "$pack/panel/backup-panel.sh" "$pack/panel/backup-wg.sh" \
  "$pack/panel/restore-panel.sh" "$pack/panel/restore-wg.sh" \
  "$pack/panel/push-restore.sh"
cp -a "$ROOT/panel/systemd/." "$pack/panel/systemd/"
cp "$ROOT/releases/family-vpn-agent-linux-amd64" "$pack/releases/family-vpn-agent-linux-amd64"
chmod 755 "$pack/releases/family-vpn-agent-linux-amd64"
cp "$ROOT/releases/install.sh" "$pack/releases/install.sh"
chmod 755 "$pack/releases/install.sh"
cp "$ROOT/releases/SHA256SUMS" "$pack/releases/SHA256SUMS"
chmod 644 "$pack/releases/SHA256SUMS"
if [ -f "$ROOT/releases/install.sh.sig" ]; then
  cp "$ROOT/releases/install.sh.sig" "$pack/releases/install.sh.sig"
  chmod 644 "$pack/releases/install.sh.sig"
fi
if [ -f "$ROOT/releases/bootstrap.sh" ]; then
  cp "$ROOT/releases/bootstrap.sh" "$pack/releases/bootstrap.sh"
  chmod 755 "$pack/releases/bootstrap.sh"
fi
cp "$ROOT/keys/release-signing.pub" "$pack/release-signing.pub"
chmod 644 "$pack/release-signing.pub"
PUB_FP=$(sha256sum "$pack/release-signing.pub" | awk '{print $1}')

cat >"$pack/BUNDLE-INFO.txt" <<EOF
source_commit=$COMMIT
bundle=image-install
image_ref=$IMAGE_REF
image_digest=$DIGEST
schema_min=1
schema_max=4
EOF

cat >"$pack/install-family-vpn.sh" <<EOF
#!/bin/bash
# Minimal Family VPN installer. The panel application arrives only as a Docker image.
# Verifies SHA-256 MANIFEST + Ed25519 signature + pinned pubkey fingerprint before exec.
# Materializes Compose under /opt/family-vpn/install so /tmp wipe cannot orphan the stack.
set -euo pipefail
HERE=\$(cd "\$(dirname "\$0")" && pwd)
cd "\$HERE"
IMAGE_REF='$IMAGE_REF'
IMAGE_DIGEST='$DIGEST'
EXPECTED_PUB_FP='$PUB_FP'
PERM=/opt/family-vpn/install
if ! sha256sum -c MANIFEST; then
  printf '%s\n' "family-vpn-install: пакет повреждён или подменён" >&2
  exit 1
fi
echo "\$EXPECTED_PUB_FP  release-signing.pub" | sha256sum -c -
SIG_B64=\$(tr -d '\\n' <INSTALL.sig | tr '_-' '/+')
case \$(( \${#SIG_B64} % 4 )) in
  2) SIG_B64="\${SIG_B64}==" ;;
  3) SIG_B64="\${SIG_B64}=" ;;
esac
TMP=\$(mktemp)
trap 'rm -f "\$TMP"' EXIT
printf '%s' "\$SIG_B64" | openssl base64 -d -A -out "\$TMP"
openssl pkeyutl -verify -pubin -inkey release-signing.pub -rawin -in MANIFEST -sigfile "\$TMP" >/dev/null \
  || { printf '%s\n' "family-vpn-install: подпись пакета отклонена" >&2; exit 1; }
if [ -d app ] || [ -d lib ] || [ -d components ] || [ -f Dockerfile ] || [ -f package.json ]; then
  printf '%s\n' "family-vpn-install: пакет содержит исходники панели и отклонён" >&2
  exit 1
fi
case "\$IMAGE_REF" in
  "\$IMAGE_DIGEST"|*"@\$IMAGE_DIGEST") ;;
  *)
    printf '%s\n' "family-vpn-install: ссылка образа не закреплена digest" >&2
    exit 1
    ;;
esac
export FAMILY_VPN_PANEL_IMAGE="\$IMAGE_REF"
export FAMILY_VPN_PANEL_DIGEST="\$IMAGE_DIGEST"
if [ -z "\${FAMILY_VPN_PANEL_IMAGE_TAR:-}" ]; then
  # Prefer permanent path; fall back to legacy /tmp for offline copies.
  if [ -f "\$PERM/family-vpn-panel-image.tar" ]; then
    export FAMILY_VPN_PANEL_IMAGE_TAR="\$PERM/family-vpn-panel-image.tar"
  else
    export FAMILY_VPN_PANEL_IMAGE_TAR=/tmp/family-vpn-panel-image.tar
  fi
fi
# Install pack permanently before first compose up (idempotent).
# Skip for read-only --check / help so offline tests need no /opt write.
case "\${1:-}" in
  --check|--verify-image|-h|--help) ;;
  *)
    if [ "\$HERE" != "\$PERM" ]; then
      mkdir -p "\$PERM"
      cp -a "\$HERE/panel" "\$PERM/"
      cp -a "\$HERE/releases" "\$PERM/"
      for f in BUNDLE-INFO.txt release-signing.pub MANIFEST INSTALL.sig EXPECTED_PUB_FP install-family-vpn.sh; do
        [ -f "\$HERE/\$f" ] && cp -a "\$HERE/\$f" "\$PERM/\$f"
      done
      if [ -f "\$FAMILY_VPN_PANEL_IMAGE_TAR" ] && [ ! -f "\$PERM/family-vpn-panel-image.tar" ]; then
        cp -a "\$FAMILY_VPN_PANEL_IMAGE_TAR" "\$PERM/family-vpn-panel-image.tar"
        [ -f "\${FAMILY_VPN_PANEL_IMAGE_TAR}.sha256" ] && cp -a "\${FAMILY_VPN_PANEL_IMAGE_TAR}.sha256" "\$PERM/family-vpn-panel-image.tar.sha256" || true
        export FAMILY_VPN_PANEL_IMAGE_TAR="\$PERM/family-vpn-panel-image.tar"
      fi
      cd "\$PERM"
    fi
    ;;
esac
exec bash ./panel/install-panel.sh "\$@"
EOF
chmod 755 "$pack/install-family-vpn.sh"

: >"$pack/MANIFEST"
while IFS= read -r rel; do
  hash=$(sha256sum "$pack/$rel" | awk '{ print $1 }')
  printf '%s  %s\n' "$hash" "$rel" >>"$pack/MANIFEST"
done < <(find "$pack" -type f ! -name MANIFEST ! -name INSTALL.sig ! -name EXPECTED_PUB_FP -printf '%P\n' | sort)
printf '%s\n' "$PUB_FP" >"$pack/EXPECTED_PUB_FP"
scan_tree "$pack"
node "$ROOT/scripts/sign-release-file.mjs" "$pack/MANIFEST"
mv "$pack/MANIFEST.sig" "$pack/INSTALL.sig"

mkdir -p "$OUT"
archive="$OUT/family-vpn-install-$SHORT.tar.gz"
tar -C "$stage" -czf "$archive" family-vpn-install
archive_hash=$(sha256sum "$archive" | awk '{ print $1 }')
printf '%s  %s\n' "$archive_hash" "$(basename "$archive")" >"$archive.sha256"
node "$ROOT/scripts/sign-release-file.mjs" "$archive"

# One-line HTTPS bootstrap: verifies SHA-256 + Ed25519, fetches image tar, installs under /opt.
BOOT="$OUT/panel-install-boot-$SHORT.sh"
cat >"$BOOT" <<EOF
#!/bin/bash
# Family VPN panel fresh install bootstrap $SHORT
# Downloads signed install pack + digest-pinned image tar. Does not wipe existing SQLite.
set -euo pipefail
BACKEND="${PUBLIC_URL}"
ARCHIVE_NAME="$(basename "$archive")"
EXPECTED_ARCHIVE_SHA="${archive_hash}"
EXPECTED_PUB_FP="${PUB_FP}"
EXPECTED_IMAGE_DIGEST="${DIGEST}"
umask 077
[ "\$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
TMP=\$(mktemp -d)
trap 'rm -rf "\$TMP"' EXIT
curl -fsSL "\$BACKEND/releases/\$ARCHIVE_NAME" -o "\$TMP/\$ARCHIVE_NAME"
curl -fsSL "\$BACKEND/releases/\$ARCHIVE_NAME.sha256" -o "\$TMP/\$ARCHIVE_NAME.sha256"
curl -fsSL "\$BACKEND/releases/\$ARCHIVE_NAME.sig" -o "\$TMP/\$ARCHIVE_NAME.sig"
curl -fsSL "\$BACKEND/releases/release-signing.pub" -o "\$TMP/release-signing.pub"
echo "\$EXPECTED_ARCHIVE_SHA  \$TMP/\$ARCHIVE_NAME" | sha256sum -c -
(cd "\$TMP" && sha256sum -c "\$ARCHIVE_NAME.sha256")
echo "\$EXPECTED_PUB_FP  \$TMP/release-signing.pub" | sha256sum -c -
SIG_B64=\$(tr -d '\\n' <"\$TMP/\$ARCHIVE_NAME.sig" | tr '_-' '/+')
case \$(( \${#SIG_B64} % 4 )) in
  2) SIG_B64="\${SIG_B64}==" ;;
  3) SIG_B64="\${SIG_B64}=" ;;
esac
printf '%s' "\$SIG_B64" | openssl base64 -d -A -out "\$TMP/sig.bin"
openssl pkeyutl -verify -pubin -inkey "\$TMP/release-signing.pub" -rawin -in "\$TMP/\$ARCHIVE_NAME" -sigfile "\$TMP/sig.bin" >/dev/null \
  || { echo "panel-install-boot: archive signature rejected" >&2; exit 1; }
mkdir -p /opt/family-vpn/install
curl -fsSL "\$BACKEND/releases/family-vpn-panel-image.tar" -o /opt/family-vpn/install/family-vpn-panel-image.tar
curl -fsSL "\$BACKEND/releases/family-vpn-panel-image.tar.sha256" -o /opt/family-vpn/install/family-vpn-panel-image.tar.sha256
(cd /opt/family-vpn/install && sha256sum -c family-vpn-panel-image.tar.sha256)
tar -xzf "\$TMP/\$ARCHIVE_NAME" -C "\$TMP"
export FAMILY_VPN_PANEL_IMAGE_TAR=/opt/family-vpn/install/family-vpn-panel-image.tar
export FAMILY_VPN_PANEL_IMAGE="\$EXPECTED_IMAGE_DIGEST"
export FAMILY_VPN_PANEL_DIGEST="\$EXPECTED_IMAGE_DIGEST"
exec bash "\$TMP/family-vpn-install/install-family-vpn.sh" "\$@"
EOF
chmod 755 "$BOOT"
boot_hash=$(sha256sum "$BOOT" | awk '{ print $1 }')
node "$ROOT/scripts/sign-release-file.mjs" "$BOOT"

{
  printf '%s\n' "source_commit=$COMMIT"
  printf '%s\n' "image_ref=$IMAGE_REF"
  printf '%s\n' "image_digest=$DIGEST"
  printf '%s\n' "archive=$(basename "$archive")"
  printf '%s\n' "archive_sha256=$archive_hash"
  printf '%s\n' "PANEL_INSTALL_BOOT=$(basename "$BOOT")"
  printf '%s\n' "PANEL_INSTALL_BOOT_SHA256=$boot_hash"
  printf '%s\n' "pubkey_fp=$PUB_FP"
  printf '%s\n' "ONE_COMMAND=curl -fsSL ${PUBLIC_URL}/releases/$(basename "$BOOT") -o /tmp/fvpn-panel-install.sh && echo '${boot_hash}  /tmp/fvpn-panel-install.sh' | sha256sum -c - && sudo bash /tmp/fvpn-panel-install.sh --new --email YOUR@EMAIL --backup-pubkey age1YOURPUBLICKEY"
  printf '%s\n' "files:"
  tar -tzf "$archive" | sort
} | tee "$OUT/IMAGE-INSTALL.txt"
printf '%s\n' "INSTALL_SHA256=$archive_hash"
printf '%s\n' "INSTALL_BOOT_SHA256=$boot_hash"
printf '%s\n' "IMAGE_REF=$IMAGE_REF"
printf '%s\n' "IMAGE_DIGEST=$DIGEST"
printf '%s\n' "SOURCE_COMMIT=$COMMIT"
printf '%s\n' "PUB_FP=$PUB_FP"
