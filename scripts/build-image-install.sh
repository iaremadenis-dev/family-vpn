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
chmod 755 "$pack/panel/install-panel.sh" "$pack/panel/renew-cert.sh" \
  "$pack/panel/backup-panel.sh" "$pack/panel/backup-wg.sh" \
  "$pack/panel/restore-panel.sh" "$pack/panel/restore-wg.sh" \
  "$pack/panel/push-restore.sh"
cp -a "$ROOT/panel/systemd/." "$pack/panel/systemd/"
install -m 755 "$ROOT/releases/family-vpn-agent-linux-amd64" "$pack/releases/family-vpn-agent-linux-amd64"
install -m 755 "$ROOT/releases/install.sh" "$pack/releases/install.sh"
install -m 644 "$ROOT/releases/SHA256SUMS" "$pack/releases/SHA256SUMS"

cat >"$pack/BUNDLE-INFO.txt" <<EOF
source_commit=$COMMIT
bundle=image-install
image_ref=$IMAGE_REF
image_digest=$DIGEST
EOF

cat >"$pack/install-family-vpn.sh" <<EOF
#!/bin/bash
# Minimal Family VPN installer. The panel application arrives only as a Docker image.
set -euo pipefail
cd "\$(dirname "\$0")"
IMAGE_REF='$IMAGE_REF'
IMAGE_DIGEST='$DIGEST'
if ! sha256sum -c MANIFEST; then
  printf '%s\n' "family-vpn-install: пакет повреждён или подменён" >&2
  exit 1
fi
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
  export FAMILY_VPN_PANEL_IMAGE_TAR=/tmp/family-vpn-panel-image.tar
fi
exec bash ./panel/install-panel.sh "\$@"
EOF
chmod 755 "$pack/install-family-vpn.sh"

: >"$pack/MANIFEST"
while IFS= read -r rel; do
  hash=$(sha256sum "$pack/$rel" | awk '{ print $1 }')
  printf '%s  %s\n' "$hash" "$rel" >>"$pack/MANIFEST"
done < <(find "$pack" -type f ! -name MANIFEST -printf '%P\n' | sort)
scan_tree "$pack"

mkdir -p "$OUT"
archive="$OUT/family-vpn-install-$SHORT.tar.gz"
tar -C "$stage" -czf "$archive" family-vpn-install
archive_hash=$(sha256sum "$archive" | awk '{ print $1 }')
printf '%s  %s\n' "$archive_hash" "$(basename "$archive")" >"$archive.sha256"
{
  printf '%s\n' "source_commit=$COMMIT"
  printf '%s\n' "image_ref=$IMAGE_REF"
  printf '%s\n' "image_digest=$DIGEST"
  printf '%s\n' "archive=$(basename "$archive")"
  printf '%s\n' "archive_sha256=$archive_hash"
  printf '%s\n' "files:"
  tar -tzf "$archive" | sort
} >"$OUT/IMAGE-INSTALL.txt"
printf '%s\n' "INSTALL_SHA256=$archive_hash"
printf '%s\n' "IMAGE_REF=$IMAGE_REF"
printf '%s\n' "IMAGE_DIGEST=$DIGEST"
printf '%s\n' "SOURCE_COMMIT=$COMMIT"
