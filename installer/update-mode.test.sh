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

# Regression: /etc/os-release defines VERSION="24.04.5 LTS (Noble Numbat)".
# Agent release version must live in AGENT_VERSION and must not be compared via $VERSION.
grep -E '^AGENT_VERSION=' "$INSTALL" >/dev/null
grep -q '\$AGENT_VERSION' "$INSTALL"
if grep -nE 'did not stay active at version \$VERSION|\[ "\$version" = "\$VERSION" \]' "$INSTALL"; then
  echo "agent version check still uses \$VERSION which os-release overwrites" >&2
  exit 1
fi
grep -q 'assert_ubuntu_2404' "$INSTALL"
# os-release must be read in a subshell (or via assert helper), never as bare `. /etc/os-release` in the main shell.
if grep -nE '^\. /etc/os-release$' "$INSTALL"; then
  echo "bare sourcing of /etc/os-release in main shell can clobber AGENT_VERSION/VERSION" >&2
  exit 1
fi

# Simulate Ubuntu os-release clobber against a tiny extracted check.
cat > "$tmp/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
VERSION="24.04.5 LTS (Noble Numbat)"
EOF
AGENT_VERSION="0.5.0"
VERSION="0.5.0"
# shellcheck disable=SC1091
. "$tmp/os-release"
[ "$VERSION" = "24.04.5 LTS (Noble Numbat)" ] || {
  echo "fixture did not clobber VERSION as Ubuntu does" >&2
  exit 1
}
[ "$AGENT_VERSION" = "0.5.0" ] || {
  echo "AGENT_VERSION must survive os-release" >&2
  exit 1
}

echo "update-mode checks ok"
