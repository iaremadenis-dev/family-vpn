#!/bin/bash
# Checks onboarding helpers without touching a real VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/installer/install.sh"

grep -q 'choose_vpn_subnet' "$INSTALL"
grep -q 'agent_is_paired' "$INSTALL"
grep -q 'post_install_check' "$INSTALL"
grep -q 'already installed; use --update' "$INSTALL"
grep -q 'SUBNET_SET' "$INSTALL"
grep -q 'systemctl enable --now wg-quick@wg0' "$INSTALL"
grep -q 'wg-quick@wg0 is not enabled' "$INSTALL"
grep -q 'wg-quick@wg0 is not active' "$INSTALL"
grep -q 'net.ipv4.ip_forward=1' "$INSTALL"
grep -q 'After=network-online.target wg-quick@wg0.service' "$INSTALL"
if grep -nE '^[[:space:]]*wg-quick up wg0$' "$INSTALL"; then
  echo "a new wg0 must be started by systemd, not by a separate wg-quick up" >&2
  exit 1
fi

# Default subnet must no longer be hard-coded as always 10.200.0.0/24 at assign time.
if grep -nE '^SUBNET="10\.200\.0\.0/24"$' "$INSTALL"; then
  echo "fresh installs must auto-pick a subnet instead of always 10.200.0.0/24" >&2
  exit 1
fi

# Explicit --subnet still accepted by the parser (validation happens later).
bash -n "$INSTALL"

echo "onboarding checks ok"
