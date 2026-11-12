#!/bin/bash
# Signs a panel update pack with a fake digest and verifies SHA-256 + Ed25519.
# Does not need Docker or a VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash -n "$ROOT/scripts/build-panel-update.sh"

if [ -z "${FAMILY_VPN_RELEASE_SIGNING_KEY:-}" ] \
  && [ ! -f "$ROOT/keys/release-signing.pem" ] \
  && [ -z "${FAMILY_VPN_RELEASE_SIGNING_KEY_FILE:-}" ]; then
  echo "skip build-panel-update.test.sh (no signing key)" >&2
  exit 0
fi

DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

out=$(FAMILY_VPN_BUNDLE_DIR="$work/dist" FAMILY_VPN_PUBLIC_URL=https://62.133.60.25 \
  bash "$ROOT/scripts/build-panel-update.sh" --digest "$DIGEST" --image-ref "$DIGEST")
printf '%s\n' "$out" | grep -q '^PANEL_UPDATE_OK$'
test -f "$work/dist/PANEL-UPDATE.txt"
archive=$(find "$work/dist" -name 'family-vpn-panel-update-*.tar.gz' ! -name '*.sha256' ! -name '*.sig' | head -1)
test -f "$archive"
test -f "$archive.sha256"
test -f "$archive.sig"
(cd "$work/dist" && sha256sum -c "$(basename "$archive").sha256")

FP=$(sha256sum "$ROOT/keys/release-signing.pub" | awk '{print $1}')
node "$ROOT/scripts/verify-release-file.mjs" "$archive" "$archive.sig" "$ROOT/keys/release-signing.pub" "$FP"

mkdir -p "$work/unpack"
tar -xzf "$archive" -C "$work/unpack"
pack="$work/unpack/family-vpn-panel-update"
(cd "$pack" && sha256sum -c MANIFEST)
grep -q "$DIGEST" "$pack/BUNDLE-INFO.txt"
grep -q 'schema_max=4' "$pack/BUNDLE-INFO.txt"
test -f "$pack/panel/update-panel.sh"
test -f "$pack/apply-update.sh"
test -f "$pack/UPDATE.sig"
test -f "$pack/EXPECTED_PUB_FP"
# Private key must not ship.
if find "$pack" -name '*.pem' | grep -q .; then
  echo "pem leaked into update pack" >&2
  exit 1
fi
grep -q '1ec270a068a05c1e1af1a29953e92a29c6c518e0b43b90f1a1f417e47d59e259' "$work/dist/panel-update-boot-"*.sh

# Tamper rejection
cp "$archive" "$work/tampered.tar.gz"
printf 'x' >>"$work/tampered.tar.gz"
if node "$ROOT/scripts/verify-release-file.mjs" "$work/tampered.tar.gz" "$archive.sig" \
  "$ROOT/keys/release-signing.pub" "$FP"; then
  echo "tampered update archive accepted" >&2
  exit 1
fi

echo "build-panel-update package checks ok"
