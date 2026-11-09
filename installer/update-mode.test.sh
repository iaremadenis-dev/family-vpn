#!/bin/bash
# Verifies --update mode guards without touching a real VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/installer/install.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --update must be a recognized flag and still refuse when not root / not paired.
if bash "$INSTALL" --backend "http://127.0.0.1:13010" --update --binary "$tmp/missing" --sha256 "$(printf 'a%.0s' {1..64})" >"$tmp/out" 2>"$tmp/err"; then
  echo "update with missing binary should fail" >&2
  exit 1
fi
grep -qi 'not found\|checksum\|root\|sha256' "$tmp/err" "$tmp/out"

# Craft a fake binary and matching sha, then expect root or paired-state refusal.
printf 'fake-agent' > "$tmp/agent"
sum=$(sha256sum "$tmp/agent" | awk '{print $1}')
set +e
bash "$INSTALL" --backend "http://127.0.0.1:13010" --update --binary "$tmp/agent" --sha256 "$sum" >"$tmp/out2" 2>"$tmp/err2"
code=$?
set -e
[ "$code" -ne 0 ] || {
  echo "update should not succeed in this harness" >&2
  exit 1
}
grep -Eiq 'run as root|not paired|binary not found|wg0.conf missing|Ubuntu 24.04' "$tmp/err2" "$tmp/out2"

# install path still mentions enroll; update path must not be the default without flag
grep -q 'enroll' "$INSTALL"
grep -q -- '--update' "$INSTALL"
grep -q 'update_paired_agent' "$INSTALL"
grep -q 'rolled back' "$INSTALL"

echo "update-mode checks ok"
