#!/bin/bash
# Checks that an existing wg0 is detected and not rewritten, and that plain HTTP
# stays limited to loopback. Does not touch /etc or a remote host.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/installer/install.sh"
SECRET="SUPERSECRETPRIVATEKEYVALUE"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/wg0.conf" <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = ${SECRET}
PostUp = iptables -t nat -A POSTROUTING -s 10.77.0.0/24 -o eth0 -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT || true
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -s 10.77.0.0/24 -o eth0 -j MASQUERADE || true

[Peer]
PublicKey = peer-one
AllowedIPs = 10.77.0.2/32

[Peer]
PublicKey = peer-two
AllowedIPs = 10.77.0.3/32
EOF

before=$(sha256sum "$tmp/wg0.conf" | awk '{print $1}')
out=$(bash "$INSTALL" --describe-wg "$tmp/wg0.conf")
after=$(sha256sum "$tmp/wg0.conf" | awk '{print $1}')
[ "$before" = "$after" ]

require_line() {
  printf '%s\n' "$out" | grep -Fxq "$1" || {
    printf 'missing %s\n%s\n' "$1" "$out" >&2
    exit 1
  }
}

require_line "action=preserve"
require_line "listen_port=51820"
require_line "address=10.77.0.1/24"
require_line "subnet=10.77.0.0/24"
require_line "peers=2"
require_line "private_key=present"
require_line "postup=3"
require_line "postdown=3"
require_line "rule_postup=iptables -t nat -A POSTROUTING -s 10.77.0.0/24 -o eth0 -j MASQUERADE"
require_line "rule_postdown=iptables -t nat -D POSTROUTING -s 10.77.0.0/24 -o eth0 -j MASQUERADE || true"

if printf '%s\n' "$out" | grep -q "$SECRET"; then
  echo "private key leaked into installer output" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -q "10.200.0.0/24"; then
  echo "default subnet replaced the existing 10.77.0.0/24" >&2
  exit 1
fi

plan=$(bash "$INSTALL" --plan-wg "$tmp/wg0.conf")
[ "$plan" = "action=preserve" ]
plan=$(bash "$INSTALL" --plan-wg "$tmp/missing.conf")
[ "$plan" = "action=create" ]

got=$(bash "$INSTALL" --backend "http://127.0.0.1:13010" --normalize)
[ "$got" = "http://127.0.0.1:13010" ]
got=$(bash "$INSTALL" --backend "http://localhost:3010/" --normalize)
[ "$got" = "http://localhost:3010" ]
got=$(bash "$INSTALL" --backend "https://panel.example.com/" --normalize)
[ "$got" = "https://panel.example.com" ]

reject() {
  if bash "$INSTALL" --backend "$1" --normalize >"$tmp/out" 2>"$tmp/err"; then
    echo "backend was accepted: $1" >&2
    exit 1
  fi
  grep -q "plain HTTP" "$tmp/err" || {
    echo "unexpected refusal for $1" >&2
    cat "$tmp/err" >&2
    exit 1
  }
}

reject "http://203.0.113.5"
reject "http://10.77.0.1:51820"

if FAMILY_VPN_PUBLIC_URL="http://203.0.113.5" bash "$ROOT/scripts/build-release.sh" >"$tmp/out" 2>"$tmp/err"; then
  echo "release build accepted remote HTTP" >&2
  exit 1
fi
grep -q "plain HTTP" "$tmp/err"

echo "preserve-wg tests ok"
