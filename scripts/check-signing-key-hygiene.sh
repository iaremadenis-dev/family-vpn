#!/bin/bash
# Ensures the release private key is not published and the committed pubkey is stable.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

EXPECTED_FP=1ec270a068a05c1e1af1a29953e92a29c6c518e0b43b90f1a1f417e47d59e259

test -f keys/release-signing.pub
FP=$(sha256sum keys/release-signing.pub | awk '{print $1}')
[ "$FP" = "$EXPECTED_FP" ] || {
  echo "pubkey fingerprint changed unexpectedly: $FP (expected $EXPECTED_FP)" >&2
  exit 1
}

# Private key must never be tracked.
if git ls-files --error-unmatch keys/release-signing.pem >/dev/null 2>&1; then
  echo "keys/release-signing.pem is tracked by git" >&2
  exit 1
fi
git check-ignore -q keys/release-signing.pem || {
  echo "keys/release-signing.pem is not gitignored" >&2
  exit 1
}

# Pubkey must not look like a PEM private key.
if grep -q 'BEGIN .*PRIVATE KEY' keys/release-signing.pub; then
  echo "release-signing.pub contains a private key block" >&2
  exit 1
fi

# Scan release/dist artifacts for leaked private key material.
scan_dirs=()
[ -d releases ] && scan_dirs+=(releases)
[ -d dist ] && scan_dirs+=(dist)
if [ "${#scan_dirs[@]}" -gt 0 ]; then
  if find "${scan_dirs[@]}" -type f \( -name '*.pem' -o -name '*release-signing.pem' \) 2>/dev/null | grep -q .; then
    echo "private key file found under releases/ or dist/" >&2
    find "${scan_dirs[@]}" -type f \( -name '*.pem' -o -name '*release-signing.pem' \) >&2
    exit 1
  fi
  if grep -R -I -n -E 'BEGIN (OPENSSH |RSA |EC |DSA |PRIVATE )?PRIVATE KEY' "${scan_dirs[@]}" 2>/dev/null | grep -v 'release-signing.pub' | grep -q .; then
    echo "private key PEM text found under releases/ or dist/" >&2
    exit 1
  fi
fi

# releases may ship the public key only.
if [ -f releases/release-signing.pub ]; then
  cmp -s keys/release-signing.pub releases/release-signing.pub \
    || { echo "releases/release-signing.pub diverges from keys/" >&2; exit 1; }
fi

echo "signing-key-hygiene ok fp=$FP"
