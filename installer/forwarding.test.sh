#!/bin/bash
# Privileged Linux regression: actual WireGuard -> TUN -> HTTP/UDP with INPUT deny.
# All interfaces, keys and test servers live in disposable network namespaces.
set -euo pipefail
if [ "${FAMILY_VPN_TEST_NETNS:-}" != 1 ]; then
  echo "network namespace regression skipped (set FAMILY_VPN_TEST_NETNS=1 on Linux)"
  exit 0
fi
[ "$(id -u)" -eq 0 ] || { echo "namespace test requires root" >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
sed '/^# Installer entry point\.$/,$d' "$ROOT/installer/install.sh" >"$fixture/functions.sh"
source "$fixture/functions.sh"
entry="fvpn-entry-$$"
client="fvpn-client-$$"
target="fvpn-target-$$"
transport_pid=""
http_pid=""
udp_pid=""
netns_cleanup() {
  set +e
  for pid in "$transport_pid" "$http_pid" "$udp_pid"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fi
  done
  for ns in "$entry" "$client" "$target"; do ip netns delete "$ns" 2>/dev/null; done
  rm -rf "$fixture"
}
trap netns_cleanup EXIT
for ns in "$entry" "$client" "$target"; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done

ip link add fv-exit type veth peer name fv-entry
ip link set fv-exit netns "$target"
ip link set fv-entry netns "$entry"
ip -n "$target" addr add 192.0.2.1/30 dev fv-exit
ip -n "$target" link set fv-exit up
ip -n "$entry" addr add 192.0.2.2/30 dev fv-entry
ip -n "$entry" link set fv-entry up
ip -n "$entry" route add default via 192.0.2.1
ip -n "$target" route add 10.220.0.0/24 via 192.0.2.2
ip link add fv-wan type veth peer name fv-client
ip link set fv-wan netns "$entry"
ip link set fv-client netns "$client"
ip -n "$entry" addr add 192.0.2.5/30 dev fv-wan
ip -n "$entry" link set fv-wan up
ip -n "$client" addr add 192.0.2.6/30 dev fv-client
ip -n "$client" link set fv-client up
ip netns exec "$entry" sysctl -qw net.ipv4.ip_forward=1

wg genkey >"$fixture/entry.key"
wg genkey >"$fixture/client.key"
entry_key=$(wg pubkey <"$fixture/entry.key")
client_key=$(wg pubkey <"$fixture/client.key")
ip -n "$entry" link add wg0 type wireguard
ip netns exec "$entry" wg set wg0 private-key "$fixture/entry.key" listen-port 51820 \
  peer "$client_key" allowed-ips 10.220.0.2/32
ip -n "$entry" addr add 10.220.0.1/24 dev wg0
ip -n "$entry" link set wg0 up
ip -n "$client" link add wg0 type wireguard
ip netns exec "$client" wg set wg0 private-key "$fixture/client.key" \
  peer "$entry_key" endpoint 192.0.2.5:51820 allowed-ips 0.0.0.0/0
ip -n "$client" addr add 10.220.0.2/32 dev wg0
ip -n "$client" link set wg0 up
ip -n "$client" route add 192.0.2.1/32 dev wg0

# Reproduce UFW's relevant input policy, without changing the runner's firewall.
ip netns exec "$entry" iptables -P INPUT DROP
ip netns exec "$entry" iptables -A INPUT -i lo -j ACCEPT
ip netns exec "$entry" iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip netns exec "$entry" iptables -A INPUT -p udp --dport 51820 -j ACCEPT
transport_write_guard 10.220.0.0/24 >"$fixture/guard.sh"
ip netns exec "$entry" bash "$fixture/guard.sh"

TRANSPORT_BIN=${FAMILY_VPN_TEST_SING_BOX:?set a Linux sing-box binary}
TRANSPORT_STAGE="$fixture"
UPLINK_FILE="$fixture/uplink.json"
ROLE=entry
cat >"$UPLINK_FILE" <<'EOF'
{"version":1,"server":"8.8.8.8","server_port":443,"uuid":"bf000d23-0752-40b4-affe-68f7707a9661","server_name":"example.com","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short_id":"01234567"}
EOF
# Read the namespace's routes when choosing a TUN subnet.
ip() { command ip netns exec "$entry" ip "$@"; }
transport_render
unset -f ip
# Isolate WG/TUN/firewall behavior from external DNS and REALITY reachability.
python3 - "$fixture/config.json" <<'PY'
import json, os, pathlib, sys
p = pathlib.Path(sys.argv[1])
c = json.loads(p.read_text())
c["outbounds"] = [{"type": "direct", "tag": "foreign"}]
if os.environ.get("FAMILY_VPN_TEST_STACK") == "system":
    c["inbounds"][0]["stack"] = "system"
p.write_text(json.dumps(c))
PY
printf 'forwarding-ok\n' >"$fixture/probe.txt"
ip netns exec "$target" python3 -m http.server 8080 --bind 192.0.2.1 --directory "$fixture" >"$fixture/http.log" 2>&1 &
http_pid=$!
cat >"$fixture/udp.py" <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("192.0.2.1", 5353))
while True:
    data, peer = s.recvfrom(4096)
    s.sendto(data, peer)
PY
ip netns exec "$target" python3 "$fixture/udp.py" >"$fixture/udp.log" 2>&1 &
udp_pid=$!
ip netns exec "$entry" "$TRANSPORT_BIN" run -c "$fixture/config.json" >"$fixture/transport.log" 2>&1 &
transport_pid=$!
for _ in {1..50}; do
  if ip -n "$entry" link show fvpn-tun >/dev/null 2>&1; then break; fi
  sleep 0.1
done
ip -n "$entry" route replace default dev fvpn-tun metric 1 table 51821
sleep 1

if ! ip netns exec "$client" curl -fsS --connect-timeout 5 --max-time 10 \
  http://192.0.2.1:8080/probe.txt >"$fixture/response"; then
  cat "$fixture/transport.log" >&2
  exit 1
fi
grep -qx 'forwarding-ok' "$fixture/response"
# The installer's source-bound probe must work too.
ip netns exec "$entry" curl -fsS --interface 10.220.0.1 --connect-timeout 5 --max-time 10 \
  http://192.0.2.1:8080/probe.txt | grep -qx 'forwarding-ok'
ip netns exec "$client" python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(5)
s.sendto(b"udp-forwarding-ok", ("192.0.2.1", 5353))
assert s.recv(4096) == b"udp-forwarding-ok"
PY

# The independently reachable main-table default must not become a direct fallback.
kill "$transport_pid"
wait "$transport_pid" || true
transport_pid=""
sleep 1
if ip netns exec "$client" curl -fsS --connect-timeout 2 --max-time 3 \
  http://192.0.2.1:8080/probe.txt >/dev/null 2>&1; then
  echo "direct fallback exposed after TUN shutdown" >&2
  exit 1
fi
ip -n "$entry" route show table 51821 | grep -q 'unreachable default'
echo "actual WireGuard/TUN TCP, UDP, source-bound probe and fail-closed shutdown passed"
