#!/bin/bash
# Build the production panel image from one git commit.
# The result stays on this machine. This script does not push a registry.
set -euo pipefail
umask 022

ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMMIT=${FAMILY_VPN_COMMIT:-HEAD}
OUT=${FAMILY_VPN_BUNDLE_DIR:-$ROOT/dist}
TAG=${FAMILY_VPN_IMAGE_TAG:-family-vpn-panel:local}

die() {
  printf '%s\n' "family-vpn-image: $*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "нужен git"
command -v docker >/dev/null 2>&1 || die "нужен docker. Образ не собран и никуда не отправлен."
docker info >/dev/null 2>&1 || die "docker не запущен. Образ не собран и никуда не отправлен."

COMMIT=$(git -C "$ROOT" rev-parse --verify "$COMMIT^{commit}")
SHORT=$(git -C "$ROOT" rev-parse --short=12 "$COMMIT")
context=$(mktemp -d)
cleanup() {
  rm -rf "$context"
}
trap cleanup EXIT

git -C "$ROOT" archive --format=tar "$COMMIT" | tar -x -C "$context"
# The archive contains the private source only in this temporary build context.
# .dockerignore keeps git metadata, tests, panel scripts, and secrets out of the image.
[ -f "$context/Dockerfile" ] || die "в коммите $SHORT нет Dockerfile"
[ -f "$context/.dockerignore" ] || die "в коммите $SHORT нет .dockerignore"

iid="$context/image-id"
docker build \
  --pull \
  --file "$context/Dockerfile" \
  --iidfile "$iid" \
  --tag "$TAG" \
  "$context"

image_id=$(tr -d '[:space:]' <"$iid")
case "$image_id" in
  sha256:*) ;;
  *) die "docker не вернул digest образа" ;;
esac

mkdir -p "$OUT"
printf '%s\n' "$image_id" >"$OUT/panel-image-id.txt"
printf '%s\n' "$COMMIT" >"$OUT/panel-image-commit.txt"
docker save "$TAG" -o "$OUT/family-vpn-panel-image.tar"
image_tar_sha=$(sha256sum "$OUT/family-vpn-panel-image.tar" | awk '{ print $1 }')
printf '%s  %s\n' "$image_tar_sha" family-vpn-panel-image.tar >"$OUT/family-vpn-panel-image.tar.sha256"

# The saved archive is the exact image. Its hash is recorded here and is not a
# substitute for the image id baked into the install package.
scan=$(docker run --rm --user 0 --entrypoint find "$TAG" /app \
  \( -name '.git' -o -name 'master.key' -o -name '*.sqlite' -o -name '.env' \
     -o -name '*.test.ts' -o -name '*.test.tsx' -o -name 'id_rsa' -o -name '*.pem' \) \
  -print)
if [ -n "$scan" ]; then
  printf '%s\n' "$scan" >&2
  die "в образе найден запрещённый файл"
fi
docker run --rm --user 0 --entrypoint test "$TAG" -f /app/server.js
docker run --rm --user 0 --entrypoint node "$TAG" -e "require('node:sqlite')"

printf '%s\n' "IMAGE_ID=$image_id"
printf '%s\n' "IMAGE_TAR_SHA256=$image_tar_sha"
printf '%s\n' "SOURCE_COMMIT=$COMMIT"
