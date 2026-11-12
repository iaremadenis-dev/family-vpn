#!/bin/bash
# Static checks: fresh-install hardening exists; --update never applies it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT="$ROOT/installer/install.sh"
PANEL="$ROOT/panel/install-panel.sh"
UPDATE="$ROOT/panel/update-panel.sh"

bash -n "$AGENT"
bash -n "$PANEL"
bash -n "$UPDATE"

# Agent fresh-install hardening
grep -q 'harden_fresh_agent_host' "$AGENT"
grep -q 'configure_ufw_agent' "$AGENT"
grep -q 'harden_ssh_if_safe' "$AGENT"
grep -q 'detect_wan_iface' "$AGENT"
grep -q 'DEFAULT_FORWARD_POLICY="ACCEPT"' "$AGENT"
grep -q '51820/udp' "$AGENT"
grep -q 'ssh_has_authorized_key' "$AGENT"
grep -q 'PasswordAuthentication no' "$AGENT"

# WAN/subnet not hardcoded as universal defaults
if grep -nE 'iface=ens3|IFACE=ens3|SUBNET="10\.201\.0\.0/24"' "$AGENT"; then
  echo "hardcoded ens3 or 10.201.0.0/24 found" >&2
  exit 1
fi
grep -q 'choose_vpn_subnet' "$AGENT"

# Client isolation + NAT dedupe still present
grep -q 'FORWARD -i wg0 -o wg0 -j DROP' "$AGENT"
grep -q 'iptables -t nat -C POSTROUTING' "$AGENT"

# Extract update_paired_agent function body and ensure no host mutation.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
awk '
  /^update_paired_agent\(\)/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}$/ { exit }
' "$AGENT" >"$tmp"
grep -q 'wg0.conf changed during update' "$tmp"
if grep -E 'harden_fresh_agent_host|configure_ufw_agent|ufw |sshd_config|iptables -t nat|cat > /etc/wireguard/wg0.conf' "$tmp"; then
  echo "--update path mutates host firewall/SSH/wg0" >&2
  exit 1
fi

# --update exits before harden_fresh_agent_host
harden_line=$(grep -n 'harden_fresh_agent_host$' "$AGENT" | head -1 | cut -d: -f1)
mode_update_line=$(grep -n 'MODE.*=.*"update"' "$AGENT" | head -1 | cut -d: -f1)
[ -n "$harden_line" ] && [ -n "$mode_update_line" ]
[ "$mode_update_line" -lt "$harden_line" ]

# Panel fresh-install hardening
grep -q 'configure_ufw_panel' "$PANEL"
grep -q 'harden_ssh_if_safe' "$PANEL"
grep -q '80/tcp' "$PANEL"
grep -q '443/tcp' "$PANEL"
grep -q 'BACKUP_NOTE: local age backup is on-box only' "$PANEL"

# Panel updater: no UFW/SSH/wg mutation; messaging about local backup
if grep -E 'ufw |sshd_config|iptables|wg-quick' "$UPDATE"; then
  echo "panel updater must not touch UFW/SSH/iptables/wg" >&2
  exit 1
fi
grep -q 'does not replace offsite' "$UPDATE"
grep -q 'do NOT set FAMILY_VPN_REQUIRE_HEARTBEAT_SIG' "$UPDATE"

echo "host-hardening checks ok"
