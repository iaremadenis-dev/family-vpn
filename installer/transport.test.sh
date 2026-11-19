#!/bin/bash
# Local configuration and failure-path checks. Never connects to a VPS or changes host networking.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
sed '/^# Installer entry point\.$/,$d' "$ROOT/installer/install.sh" >"$TEST_DIR/functions.sh"
source "$TEST_DIR/functions.sh"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/state" "$TEST_DIR/exit" "$TEST_DIR/entry" "$TEST_DIR/repeat"

if [ -n "${FAMILY_VPN_TEST_SING_BOX:-}" ]; then
  TRANSPORT_BIN=$FAMILY_VPN_TEST_SING_BOX
else
  TRANSPORT_BIN="$TEST_DIR/bin/sing-box"
  cat >"$TRANSPORT_BIN" <<'EOF'
#!/bin/bash
if [ "$1" = generate ]; then
  printf 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nPublicKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n'
else
  python3 - "$3" <<'PY'
import json, sys
json.load(open(sys.argv[1]))
PY
fi
EOF
  chmod +x "$TRANSPORT_BIN"
fi

# Rendering an entry must use the supplied route snapshot, not change routes itself.
ip() { printf '%s\n' '[{"dst":"172.31.255.0/30","dev":"other-vpn"}]'; }
ROLE=exit
PUBLIC_ADDRESS=8.8.8.8
SERVER_NAME=example.com
TRANSPORT_PORT=8443
TRANSPORT_DIR="$TEST_DIR/state"
TRANSPORT_STAGE="$TEST_DIR/exit"
transport_validate
transport_render
cp "$TRANSPORT_STAGE/config.json" "$TRANSPORT_DIR/config.json"
cp "$TRANSPORT_STAGE/uplink.json" "$TRANSPORT_DIR/uplink.json"
TRANSPORT_STAGE="$TEST_DIR/repeat"
transport_render
cmp "$TEST_DIR/exit/config.json" "$TRANSPORT_STAGE/config.json"
cmp "$TEST_DIR/exit/uplink.json" "$TRANSPORT_STAGE/uplink.json"

ROLE=entry
PUBLIC_ADDRESS=""
SERVER_NAME=""
UPLINK_FILE="$TEST_DIR/exit/uplink.json"
TRANSPORT_STAGE="$TEST_DIR/entry"
transport_validate
transport_render
WIZARD_REPLY=$(TRANSPORT_DIR="$TEST_DIR/exit"; transport_export_code)
UPLINK_FILE="$TEST_DIR/imported.json"
transport_import_code
transport_validate
python3 - "$TEST_DIR" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
assert json.loads((p / "imported.json").read_text()) == json.loads((p / "exit/uplink.json").read_text())
PY
if (WIZARD_REPLY='FVPN1.not-json'; transport_import_code) >"$TEST_DIR/rejected-code.log" 2>&1; then
  echo "malformed connection code accepted" >&2
  exit 1
fi

# The no-argument wizard discovers the exit parameters and accepts a pasted code on entry.
# Only these functions are mocked. No real network probes or installation commands run.
(
  source "$TEST_DIR/functions.sh"
  assert_ubuntu_2404() { return 0; }
  id() { printf '0\n'; }
  ss() { if [ "${*: -1}" = 'sport = :443' ]; then printf 'LISTEN\n'; fi; return 0; }
  ip() { printf '1.1.1.1 dev eth0 src 8.8.8.8\n'; }
  timeout() { return 0; }
  wizard_read() { WIZARD_REPLY=1; }
  TRANSPORT_DIR="$TEST_DIR/wizard-exit"
  transport_wizard
  [ "$ROLE" = exit ] && [ "$PUBLIC_ADDRESS" = 8.8.8.8 ]
  [ "$TRANSPORT_PORT" = 8443 ] && [ "$SERVER_NAME" = www.microsoft.com ]
)
(
  source "$TEST_DIR/functions.sh"
  assert_ubuntu_2404() { return 0; }
  id() { printf '0\n'; }
  ss() { return 0; }
  agent_is_paired() { return 0; }
  code=$(TRANSPORT_DIR="$TEST_DIR/exit"; transport_export_code)
  step=0
  wizard_read() {
    if [ "$step" -eq 0 ]; then WIZARD_REPLY=2; else WIZARD_REPLY=$code; fi
    step=$((step + 1))
  }
  TRANSPORT_DIR="$TEST_DIR/wizard-entry"
  transport_wizard
  [ "$ROLE" = entry ] && [ "$step" -eq 2 ]
  [ -f "$UPLINK_FILE" ]
  transport_validate
)
python3 - "$TEST_DIR" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
exit_config = json.loads((root / "exit/config.json").read_text())
entry = json.loads((root / "entry/config.json").read_text())
params = json.loads((root / "exit/uplink.json").read_text())
inbound = exit_config["inbounds"][0]
outbound = entry["outbounds"][0]
assert inbound["listen_port"] == outbound["server_port"] == 8443
assert inbound["users"][0]["uuid"] == outbound["uuid"]
assert inbound["tls"]["reality"]["short_id"] == [outbound["tls"]["reality"]["short_id"]]
assert params["public_key"] == outbound["tls"]["reality"]["public_key"]
assert "private_key" not in params
assert len(entry["outbounds"]) == 1 and outbound["type"] == "vless"
assert entry["route"]["final"] == outbound["tag"]
assert outbound["packet_encoding"] == "xudp" and "network" not in outbound
assert entry["inbounds"][0]["auto_route"] is False
assert entry["inbounds"][0]["address"] == ["198.18.255.1/30"]
bad = dict(params, private_key="must never be accepted")
(root / "bad.json").write_text(json.dumps(bad))
bad = dict(params, server="127.0.0.1")
(root / "local.json").write_text(json.dumps(bad))
bad = dict(params, server_port=True)
(root / "port.json").write_text(json.dumps(bad))
PY
for invalid in bad local port; do
  if (UPLINK_FILE="$TEST_DIR/$invalid.json"; transport_validate) >"$TEST_DIR/rejected.log" 2>&1; then
    echo "invalid uplink accepted: $invalid" >&2
    exit 1
  fi
done

transport_write_guard 10.221.0.0/24 >"$TEST_DIR/guard.sh"
bash -n "$TEST_DIR/guard.sh"
grep -q 'unreachable default metric 32767 table 51821' "$TEST_DIR/guard.sh"
grep -q 'priority 10518 from 10.221.0.0/24 table 51821' "$TEST_DIR/guard.sh"
grep -q 'FVPN_EGRESS -i wg0 -j DROP' "$TEST_DIR/guard.sh"
grep -q 'FVPN_EGRESS -i wg0 -o fvpn-tun -j ACCEPT' "$TEST_DIR/guard.sh"
grep -q 'ip6tables.*FORWARD -i wg0 -j DROP' "$TEST_DIR/guard.sh"
if grep -Eq 'MASQUERADE|ip route flush|iptables.*-F' "$TEST_DIR/guard.sh"; then
  echo "guard must not create a direct fallback or flush host rules" >&2
  exit 1
fi

# Exercise service-start failure with paths redirected into the temporary fixture.
sed "s|/etc/systemd/system|$TEST_DIR/units|g" "$TEST_DIR/functions.sh" >"$TEST_DIR/failure-functions.sh"
(
  source "$TEST_DIR/failure-functions.sh"
  trap - EXIT
  TRANSPORT_DIR="$TEST_DIR/state"
  TRANSPORT_STAGE="$TEST_DIR/entry"
  TRANSPORT_BIN=/usr/bin/sing-box
  ROLE=entry
  mkdir -p "$TEST_DIR/units"
  cp "$TEST_DIR/state/config.json" "$TEST_DIR/before.json"
  systemctl() {
    if [ "$1" = restart ]; then return 1; fi
    return 0
  }
  transport_start
) >"$TEST_DIR/failure.log" 2>&1 && {
  echo "service-start failure must be reported" >&2
  exit 1
}
cmp "$TEST_DIR/before.json" "$TEST_DIR/state/config.json"
grep -q 'transport failed to start' "$TEST_DIR/failure.log"

# A non-default WireGuard port must be opened, including before the interface starts.
sed "s|/etc/default/ufw|$TEST_DIR/ufw-default|g" "$TEST_DIR/functions.sh" >"$TEST_DIR/ufw-functions.sh"
(
  source "$TEST_DIR/ufw-functions.sh"
  trap - EXIT
  apt-get() { return 0; }
  wg() { return 1; }
  describe_wg_conf() { printf 'listen_port=51999\n'; }
  detect_wan_iface() { printf 'eth0\n'; }
  ufw() {
    printf '%s\n' "$*" >>"$TEST_DIR/ufw.log"
    if [ "$1" = status ]; then printf 'Status: active\n'; fi
    return 0
  }
  configure_ufw_agent
)
grep -q 'allow 51999/udp' "$TEST_DIR/ufw.log"
if grep -q 'allow 51820/udp' "$TEST_DIR/ufw.log"; then
  echo "UFW opened the template port instead of the configured port" >&2
  exit 1
fi
echo "transport configuration, credential reuse, input rejection and rollback checks ok"
