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

echo "== agent go tests =="
bash scripts/run-agent-go-tests.sh

echo "== build signed release =="
VERSION=${VERSION:-0.5.0} FAMILY_VPN_PUBLIC_URL="$PUBLIC_URL" bash scripts/build-release.sh

echo "== verify signature / tamper rejection =="
bash scripts/verify-signed-release-local.sh

echo "== fingerprint =="
sha256sum keys/release-signing.pub
echo "prepare-production-release: OK (artifacts in releases/; not published)"
