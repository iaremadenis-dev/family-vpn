#!/bin/bash
# Static check: new wg0 templates isolate clients (no client-to-client FORWARD accept).
# Does not touch a live VPS or apply iptables.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/installer/install.sh"

grep -q 'FORWARD -i wg0 -o wg0 -j DROP' "$INSTALL"
grep -q 'FORWARD -i wg0 -o \$iface -j ACCEPT' "$INSTALL"
grep -q 'conntrack --ctstate RELATED,ESTABLISHED' "$INSTALL"
# Legacy broad accept must not remain in the new-template block.
if grep -n 'PostUp = iptables -C FORWARD -i wg0 -j ACCEPT' "$INSTALL"; then
  echo "legacy client-to-client ACCEPT still present" >&2
  exit 1
fi
if grep -n 'PostUp = iptables -C FORWARD -o wg0 -j ACCEPT' "$INSTALL"; then
  echo "legacy inbound wg0 ACCEPT still present" >&2
  exit 1
fi

echo "client-isolation template ok"
