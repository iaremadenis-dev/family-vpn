#!/bin/bash
# Verifies install.sh against an Ed25519 detached signature and a pinned pubkey fingerprint.
# Prefers openssl when available; falls back to node scripts/verify-release-file.mjs.
set -euo pipefail

FILE=${1:?file}
SIG=${2:?sig}
PUB=${3:?pub}
EXPECTED_FP=${4:?fingerprint}

GOT=$(sha256sum "$PUB" | awk '{print $1}')
[ "$GOT" = "$EXPECTED_FP" ] || {
  echo "family-vpn: release public key fingerprint mismatch" >&2
  exit 1
}

if command -v node >/dev/null 2>&1; then
  ROOT=$(cd "$(dirname "$0")/.." && pwd)
  exec node "$ROOT/scripts/verify-release-file.mjs" "$FILE" "$SIG" "$PUB" "$EXPECTED_FP"
fi

# OpenSSL path: convert base64url sig to raw bytes then pkeyutl -verify.
if ! command -v openssl >/dev/null 2>&1; then
  echo "family-vpn: need node or openssl to verify the release signature" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SIG_B64=$(tr -d '\n' <"$SIG" | tr '_-' '/+')
case $(( ${#SIG_B64} % 4 )) in
  2) SIG_B64="${SIG_B64}==" ;;
  3) SIG_B64="${SIG_B64}=" ;;
esac
printf '%s' "$SIG_B64" | openssl base64 -d -A -out "$TMP/sig.bin"
openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$FILE" -sigfile "$TMP/sig.bin" >/dev/null
echo "ok"
