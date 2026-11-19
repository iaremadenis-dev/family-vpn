#!/bin/bash
# Test the local forwarding path, then the complete WireGuard -> VLESS -> exit path.
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
site="fvpn-site-$$"
exit_pid=""
dns_pid=""
https_pid=""
ns_files=""
transport_pid=""
http_pid=""
udp_pid=""
netns_cleanup() {
  local rc=$?
  set +e
  if [ "$rc" -ne 0 ]; then
    for log in exit entry https dns; do
      if [ -f "$fixture/$log.log" ]; then tail -30 "$fixture/$log.log" >&2; fi
    done
  fi
  for pid in "$transport_pid" "$exit_pid" "$dns_pid" "$https_pid" "$http_pid" "$udp_pid"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fi
  done
  for ns in "$entry" "$client" "$target" "$site"; do ip netns delete "$ns" 2>/dev/null; done
  if [ -n "$ns_files" ]; then rm -f "$ns_files/hosts" "$ns_files/resolv.conf"; rmdir "$ns_files"; fi
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
ip -n "$client" route add 10.220.0.1/32 dev wg0

# Reproduce UFW's relevant input policy, without changing the runner's firewall.
ip netns exec "$entry" iptables -P INPUT DROP
ip netns exec "$entry" iptables -A INPUT -i lo -j ACCEPT
ip netns exec "$entry" iptables -A INPUT -i wg0 -p icmp --icmp-type echo-request -j ACCEPT
ip netns exec "$entry" iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip netns exec "$entry" iptables -A INPUT -p udp --dport 51820 -j ACCEPT
# Installation on a clean entry applies the guard once before wg-quick creates wg0.
# Use a fresh namespace to exercise that order, subsequent link loss and reattachment.
(
  boot="fvpn-boot-$$"
  ip netns add "$boot"
  trap 'ip netns delete "$boot"' EXIT
  transport_write_guard 10.220.0.0/24 >"$fixture/boot-guard.sh"
  ip netns exec "$boot" bash "$fixture/boot-guard.sh"
  ip -n "$boot" route show table 51821 | grep -q '^unreachable 10.220.0.0/24'
  ip netns exec "$boot" iptables -I FORWARD 1 -j DROP
  ip netns exec "$boot" sysctl -qw net.ipv4.ip_forward=0
  ip netns exec "$boot" bash "$fixture/boot-guard.sh"
  ip netns exec "$boot" bash "$fixture/boot-guard.sh"
  [ "$(ip netns exec "$boot" sysctl -n net.ipv4.ip_forward)" = 1 ]
  rules=$(ip netns exec "$boot" iptables -S FORWARD)
  [ "$(grep -Fxc -- '-A FORWARD -j FVPN_EGRESS' <<<"$rules")" = 1 ]
  [ "$(ip netns exec "$boot" iptables -S FORWARD 1)" = '-A FORWARD -j FVPN_EGRESS' ]
  ip netns exec "$boot" iptables -C FORWARD -j DROP
  echo "repair restored forwarding and guard order without deleting the existing firewall rule"
  for attempt in 1 2; do
    ip -n "$boot" link add wg0 type wireguard
    ip -n "$boot" address add 10.220.0.1/24 dev wg0
    ip -n "$boot" link set wg0 up
    ip netns exec "$boot" bash "$fixture/boot-guard.sh"
    ip -n "$boot" route get 10.220.0.2 from 10.220.0.1 | grep -qw wg0
    ip -n "$boot" link delete wg0
    ip -n "$boot" route show table 51821 | grep -q '^unreachable 10.220.0.0/24'
  done
)
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

# The entry's own replies to a peer must stay on the local WireGuard link.
gateway_reply=$(ip -n "$entry" -4 route get 10.220.0.2 from 10.220.0.1)
echo "entry gateway reply: $gateway_reply"
if ! grep -qw wg0 <<<"$gateway_reply"; then
  echo "entry routes a reply for its own WireGuard peer away from wg0" >&2
  exit 1
fi
ip netns exec "$client" ping -4 -c 1 -W 3 10.220.0.1 >/dev/null
echo "client received an IPv4 echo reply from its local WireGuard gateway"

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

# Keep the old system-stack experiment independent of the required full-chain test.
[ "${FAMILY_VPN_TEST_STACK:-}" != system ] || exit 0

# The original target becomes the exit VPS. A fourth namespace serves HTTPS and DNS.
# Disable IP forwarding on the exit: only the exit proxy can contact this site for a client.
ip netns add "$site"
ip -n "$site" link set lo up
ip link add fv-public type veth peer name fv-site
ip link set fv-public netns "$target"
ip link set fv-site netns "$site"
ip -n "$target" addr add 198.51.100.1/30 dev fv-public
ip -n "$site" addr add 198.51.100.2/30 dev fv-site
ip -n "$target" link set fv-public up
ip -n "$site" link set fv-site up
ip -n "$target" route add default via 198.51.100.2
ip netns exec "$target" sysctl -qw net.ipv4.ip_forward=0
ip -n "$client" route add default dev wg0

# Map the REALITY handshake host only inside the exit namespace.
mkdir -p /etc/netns
mkdir "/etc/netns/$target"
ns_files="/etc/netns/$target"
printf '127.0.0.1 localhost\n198.51.100.2 cover.test\n' >"$ns_files/hosts"
printf 'nameserver 198.51.100.2\n' >"$ns_files/resolv.conf"
ip netns exec "$site" dnsmasq --keep-in-foreground --no-resolv --no-hosts \
  --bind-interfaces --listen-address=198.51.100.2 --pid-file= \
  --address=/example.com/198.51.100.2 --address=/probe.test/198.51.100.2 --address=/cover.test/198.51.100.2 >"$fixture/dns.log" 2>&1 &
dns_pid=$!

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=probe.test' \
  -addext 'subjectAltName=DNS:cover.test,DNS:probe.test,IP:198.51.100.2' \
  -keyout "$fixture/tls.key" -out "$fixture/tls.crt" 2>/dev/null
cat >"$fixture/https.py" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ssl
import sys

class Probe(BaseHTTPRequestHandler):
    def do_GET(self):
        data = (self.client_address[0] + "\n").encode() + bytes(range(256)) * 256
        if self.path == "/cdn-cgi/trace":
            data = ("ip=" + self.client_address[0] + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer(("198.51.100.2", 443), Probe)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.set_ecdh_curve("X25519")
ctx.set_alpn_protocols(["http/1.1"])
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
ip netns exec "$site" python3 "$fixture/https.py" "$fixture/tls.crt" "$fixture/tls.key" >"$fixture/https.log" 2>&1 &
https_pid=$!

mkdir "$fixture/exit-config" "$fixture/entry-config" "$fixture/state"
TRANSPORT_DIR="$fixture/state"
TRANSPORT_STAGE="$fixture/exit-config"
ROLE=exit
SERVER_NAME=cover.test
PUBLIC_ADDRESS=192.0.2.1
TRANSPORT_PORT=443
transport_render
ip netns exec "$target" "$TRANSPORT_BIN" run -c "$TRANSPORT_STAGE/config.json" >"$fixture/exit.log" 2>&1 &
exit_pid=$!
ROLE=entry
TRANSPORT_STAGE="$fixture/entry-config"
UPLINK_FILE="$fixture/exit-config/uplink.json"
ip() { command ip netns exec "$entry" ip "$@"; }
transport_render
unset -f ip
ip netns exec "$entry" "$TRANSPORT_BIN" run -c "$TRANSPORT_STAGE/config.json" >"$fixture/entry.log" 2>&1 &
transport_pid=$!
for _ in {1..50}; do
  if ip -n "$entry" link show fvpn-tun >/dev/null 2>&1 && \
      ip netns exec "$target" ss -H -ltn 'sport = :443' | grep -q . && \
      ip netns exec "$site" ss -H -ltn 'sport = :443' | grep -q .; then break; fi
  sleep 0.1
done
ip -n "$entry" route replace default dev fvpn-tun metric 1 table 51821
answer=$(ip netns exec "$client" dig +short +notcp +ignore +time=3 +tries=2 @198.51.100.2 probe.test. A)
[ "$answer" = 198.51.100.2 ] || { echo "client DNS over UDP/53 failed" >&2; exit 1; }
echo "client received a DNS answer through WireGuard, VLESS/REALITY and the exit"
fetch_site() {
  ip netns exec "$client" curl -4 --noproxy '*' -fsS --connect-timeout 4 --max-time 12 \
    --cacert "$fixture/tls.crt" --resolve "probe.test:443:$answer" https://probe.test/probe
}
fetch_site >"$fixture/body"
python3 - "$fixture/body" <<'PY'
from pathlib import Path
import sys

assert Path(sys.argv[1]).read_bytes() == b"198.51.100.1\n" + bytes(range(256)) * 256
PY
echo "client verified TLS, exit source address and the full 64 KiB response"
# Run the same automatic client check the installer runs on an existing entry.
# A previous interrupted run owns only its temporary key and namespace.
ip netns exec "$entry" wg show wg0 allowed-ips >"$fixture/allowed.before"
old_ns="fvpca6b7223c01"
ip netns add "$old_ns"
old_key=$(wg genkey | wg pubkey)
ip netns exec "$entry" wg set wg0 peer "$old_key" allowed-ips 10.220.0.246/31
printf '{"ns":"%s","public":"%s"}\n' "$old_ns" "$old_key" >"$fixture/probe-state.json"
real_client_check() {
  # Enter only the simulated VPS network. Keep its named-namespace mount table
  # available across runs, just as it is for an installer started from SSH.
  nsenter --net="/run/netns/$entry" env CURL_CA_BUNDLE="$fixture/tls.crt" bash -c '
    source "$1"
    transport_client_probe 198.51.100.2 https://198.51.100.2/cdn-cgi/trace 198.51.100.1 "$2"
  ' bash "$fixture/functions.sh" "$fixture/probe-state.json"
}
real_client_check | tee "$fixture/probe-ok.log"
grep -q 'HTTPS OK, внешний IPv4 198.51.100.1' "$fixture/probe-ok.log"
grep -q 'WireGuard OK, DNS OK' "$fixture/probe-ok.log"
[ ! -e "$fixture/probe-state.json" ] && [ ! -e "/run/netns/$old_ns" ]
ip netns exec "$entry" wg show wg0 allowed-ips | cmp "$fixture/allowed.before" -
# A locally sourced HTTP check can stay green while forwarded clients get nothing.
ip netns exec "$entry" iptables -I FORWARD 1 -i wg0 -j DROP
ip netns exec "$entry" curl -4 --noproxy '*' -fsS --interface 10.220.0.1 \
  --cacert "$fixture/tls.crt" --connect-timeout 4 --max-time 10 \
  https://198.51.100.2/cdn-cgi/trace | grep -Fxq 'ip=198.51.100.1'
if real_client_check >"$fixture/probe-shadowed.log" 2>&1; then
  echo "a host-only check masked a broken client path" >&2
  exit 1
fi
grep -q 'WireGuard OK, DNS СБОЙ' "$fixture/probe-shadowed.log"
ip netns exec "$entry" bash "$fixture/guard.sh"
real_client_check | grep -q 'На VPS путь WireGuard'
ip netns exec "$entry" iptables -C FORWARD -i wg0 -j DROP
ip netns exec "$entry" wg show wg0 allowed-ips | cmp "$fixture/allowed.before" -
echo "reproduced host HTTPS success with broken client forwarding; repair restored client DNS and HTTPS"
kill "$exit_pid"
wait "$exit_pid" || true
exit_pid=""
if fetch_site >/dev/null 2>&1; then
  echo "client HTTPS succeeded with the foreign exit stopped" >&2
  exit 1
fi
echo "stopping only the foreign exit breaks client HTTPS as expected"
if real_client_check >"$fixture/probe-broken.log" 2>&1; then
  echo "automatic client check falsely passed with the exit stopped" >&2
  exit 1
fi
grep -q 'WireGuard OK, DNS СБОЙ' "$fixture/probe-broken.log"
grep -q 'HTTPS от тестового клиента' "$fixture/probe-broken.log"
[ ! -e "$fixture/probe-state.json" ]
ip netns exec "$entry" wg show wg0 allowed-ips | cmp "$fixture/allowed.before" -
echo "real client probe identified a broken exit and cleaned up after both outcomes"

# Prepare the two production candidates from the existing, successful VLESS setup.
mkdir "$fixture/link-exit" "$fixture/link-entry" "$fixture/stage-exit" "$fixture/stage-entry"
cp "$fixture/exit-config/"{uplink,config}.json "$fixture/link-exit/"
cp "$fixture/entry-config/config.json" "$fixture/link-entry/"
cp "$fixture/exit-config/uplink.json" "$fixture/link-entry/entry-uplink.json"
ROLE=exit
TRANSPORT_DIR="$fixture/link-exit"
TRANSPORT_STAGE="$fixture/stage-exit"
link_render 51821
cp "$TRANSPORT_STAGE/wg-link-keys.json" "$TRANSPORT_DIR/"
cp "$TRANSPORT_STAGE/link.code" "$fixture/stage-entry/"
link_render 51822
cmp "$TRANSPORT_STAGE/link.code" "$fixture/stage-entry/link.code"
ip netns exec "$target" "$TRANSPORT_BIN" run -c "$TRANSPORT_STAGE/wireguard.json" >"$fixture/exit.log" 2>&1 &
exit_pid=$!
ROLE=entry
TRANSPORT_DIR="$fixture/link-entry"
TRANSPORT_STAGE="$fixture/stage-entry"
link_render compare
kill "$transport_pid"
wait "$transport_pid" || true
transport_pid=""
start_entry_mode() {
  ip netns exec "$entry" "$TRANSPORT_BIN" run -c "$1" >"$fixture/entry.log" 2>&1 &
  transport_pid=$!
  for _ in {1..50}; do
    if ip -n "$entry" link show fvpn-tun >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  ip -n "$entry" route replace default dev fvpn-tun metric 1 table 51821
}
# Block the working REALITY route while exercising the second link.
ip netns exec "$entry" iptables -I OUTPUT -d 192.0.2.1 -p tcp --dport 443 -j REJECT
start_entry_mode "$TRANSPORT_STAGE/wireguard.json"
real_client_check | tee "$fixture/link-probe.log"
grep -Fq 'HTTPS OK, внешний IPv4 198.51.100.1' "$fixture/link-probe.log"
fetch_site >"$fixture/wg-body"
cmp "$fixture/body" "$fixture/wg-body"
ip netns exec "$entry" wg show wg0 allowed-ips | cmp "$fixture/allowed.before" -
echo "same client, UDP DNS, 64 KiB HTTPS and foreign IP verified over WireGuard with inter-server TCP blocked"
ip netns exec "$entry" iptables -D OUTPUT -d 192.0.2.1 -p tcp --dport 443 -j REJECT
ip netns exec "$entry" iptables -I OUTPUT -d 192.0.2.1 -p udp --dport 51821 -j DROP
if fetch_site >/dev/null 2>&1; then echo "WireGuard silently bypassed a blocked link"; exit 1; fi
kill "$transport_pid"
wait "$transport_pid" || true
transport_pid=""
start_entry_mode "$TRANSPORT_STAGE/vless.json"
fetch_site >"$fixture/restored-body"
cmp "$fixture/body" "$fixture/restored-body"
echo "same profile works on VLESS again with inter-server UDP still blocked"

# Exercise the command's commit/rollback logic independently of the real transport
# transfers above. Only service activation and probe outcomes are substituted.
cp "$fixture/stage-entry/link.code" "$fixture/link-entry/wg-link.code"
printf 'entry\n' >"$fixture/link-entry/role"
mkdir "$fixture/bin"
ln -s "$TRANSPORT_BIN" "$fixture/bin/sing-box"
cat >"$fixture/switch-driver.sh" <<'DRIVER'
set -euo pipefail
source "$1/functions.sh"
TRANSPORT_DIR="$1/link-entry"
export PATH="$1/bin:$PATH"
mode() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["route"]["final"])' "$TRANSPORT_DIR/config.json"; }
systemctl() { [ "$1" != restart ] || [ "$(mode)" != "$FAIL_START" ]; }
transport_verify_entry() { [ "$1" = strict ] && [ "$(mode)" != "$FAIL_PROBE" ] && [ "$FAIL_PROBE" != both ]; }
link_compare "$2" </dev/null
DRIVER
run_switch() { FAIL_START="$2" FAIL_PROBE="$3" bash "$fixture/switch-driver.sh" "$fixture" "$1"; }
run_switch compare foreign none
cmp "$fixture/stage-entry/wireguard.json" "$fixture/link-entry/config.json"
# An ordinary repair must keep the selected uplink.
TRANSPORT_DIR="$fixture/link-entry"
TRANSPORT_STAGE="$fixture/entry-config"
UPLINK_FILE="$TRANSPORT_DIR/entry-uplink.json"
ip() { command ip netns exec "$entry" ip "$@"; }
transport_render
unset -f ip
python3 - "$TRANSPORT_STAGE/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
assert c["route"]["final"] == "family-wg-uplink" and c["endpoints"][0]["type"] == "wireguard"
PY
if run_switch compare none both; then echo "reported success when both probes failed"; exit 1; fi
cmp "$fixture/stage-entry/wireguard.json" "$fixture/link-entry/config.json"
if run_switch compare family-wg-uplink none; then echo "reported success after WG startup failure"; exit 1; fi
python3 - "$fixture/link-entry/config.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["route"]["final"] == "foreign"
PY
run_switch compare none none
run_switch vless none none
[ ! -e "$fixture/link-entry/before-link-switch.json" ]
cmp "$fixture/stage-entry/vless.json" "$fixture/link-entry/config.json"
echo "startup and probe failures restore the selected mode; explicit return and ordinary repair preserve the selection"
