#!/bin/bash
# Builds and verifies signed production agent artifacts. Does not publish or deploy.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PUBLIC_URL=${FAMILY_VPN_PUBLIC_URL:-}
[ -n "$PUBLIC_URL" ] || {
  echo "set FAMILY_VPN_PUBLIC_URL to the panel origin (e.g. https://62.133.60.25)" >&2
  exit 1
}

if [ -z "${FAMILY_VPN_RELEASE_SIGNING_KEY:-}" ] \
  && [ ! -f "$ROOT/keys/release-signing.pem" ] \
  && [ -z "${FAMILY_VPN_RELEASE_SIGNING_KEY_FILE:-}" ]; then
  echo "missing release signing private key" >&2
  exit 1
fi

export PATH="/c/Program Files/Go/bin:/usr/local/go/bin:${PATH:-}"
command -v go >/dev/null || {
  echo "go is required" >&2
  exit 1
}

echo "== signing key hygiene =="
bash scripts/check-signing-key-hygiene.sh

echo "== agent go tests =="
bash scripts/run-agent-go-tests.sh

echo "== build signed agent release =="
VERSION=${VERSION:-0.5.0} FAMILY_VPN_PUBLIC_URL="$PUBLIC_URL" bash scripts/build-release.sh

echo "== verify signature / tamper rejection =="
bash scripts/verify-signed-release-local.sh

echo "== panel updater simulator =="
bash scripts/update-panel.test.sh

if [ -n "${FAMILY_VPN_PANEL_DIGEST:-}" ]; then
  echo "== build signed panel update bundle =="
  FAMILY_VPN_PUBLIC_URL="$PUBLIC_URL" \
    FAMILY_VPN_PANEL_DIGEST="$FAMILY_VPN_PANEL_DIGEST" \
    FAMILY_VPN_PANEL_IMAGE="${FAMILY_VPN_PANEL_IMAGE:-$FAMILY_VPN_PANEL_DIGEST}" \
    FAMILY_VPN_PREV_PANEL_DIGEST="${FAMILY_VPN_PREV_PANEL_DIGEST:-sha256:b5a719f0148019784f4eb544289fb2acb4174cf1c8b76e70f18f73ac37b09479}" \
    bash scripts/build-panel-update.sh
  echo "panel update artifacts in dist/ (not published)"
else
  echo "skip panel update pack (set FAMILY_VPN_PANEL_DIGEST to build)"
fi

echo "== fingerprint =="
sha256sum keys/release-signing.pub
echo "prepare-production-release: OK (artifacts prepared; not published / not deployed)"
