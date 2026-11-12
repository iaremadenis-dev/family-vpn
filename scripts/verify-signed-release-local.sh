#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

(cd releases && sha256sum -c SHA256SUMS)
file releases/family-vpn-agent-linux-amd64 | grep -E 'ELF 64-bit'
# Cross-built on Windows: execute via go run version check is N/A; grep the binary bytes.
grep -aob $'0.5.0\0\|0.5.0' releases/family-vpn-agent-linux-amd64 >/dev/null \
  || grep -a '0\.5\.0' releases/family-vpn-agent-linux-amd64 >/dev/null

test -f releases/install.sh.sig
test -f releases/release-signing.pub
FP=$(sha256sum releases/release-signing.pub | awk '{print $1}')
node scripts/verify-release-file.mjs releases/install.sh releases/install.sh.sig releases/release-signing.pub "$FP"

TMP=$(mktemp)
cp releases/install.sh "$TMP"
printf '\nTAMPER\n' >>"$TMP"
if node scripts/verify-release-file.mjs "$TMP" releases/install.sh.sig releases/release-signing.pub "$FP"; then
  echo "TAMPER_ACCEPTED" >&2
  exit 1
fi
echo "TAMPER_REJECTED_OK"

BAD_FP=$(printf 'a%.0s' {1..64})
if node scripts/verify-release-file.mjs releases/install.sh releases/install.sh.sig releases/release-signing.pub "$BAD_FP"; then
  echo "BAD_FP_ACCEPTED" >&2
  exit 1
fi
echo "BAD_FP_REJECTED_OK"
echo "ALL_RELEASE_CHECKS_OK"
