#!/bin/bash
# Family VPN installer 0.4.0
# Downloads the agent only from the panel origin and verifies SHA-256 before install.
# Plain HTTP is accepted only for 127.0.0.1 and localhost (SSH tunnel).
# A remote panel must use HTTPS. This script does not pipe an unverified
# remote script into a privileged shell by itself.
# 0.4.0 adds WireGuard peer jobs via heartbeat; existing wg0.conf peers are preserved.
set -euo pipefail
umask 077

VERSION="0.4.0"
BACKEND=""
BINARY=""
SHA256=""
RELEASE_DIR=""
PORT="51820"
SUBNET="10.200.0.0/24"
DATA_DIR="/var/lib/family-vpn"
MODE="install"
CREATED_WG=0
TMP_KEYS=""
TMP_DIR=""
BACKUP_DIR=""
WG_FILE=""

die() {
  echo "family-vpn-install: $*" >&2
  exit 1
}

cleanup() {
  status=$?
  if [ -n "$TMP_KEYS" ]; then
    rm -rf "$TMP_KEYS"
  fi
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  if [ "$status" -ne 0 ] && [ "$CREATED_WG" -eq 1 ] && [ ! -f "$DATA_DIR/wg-managed-by-installer" ]; then
    wg-quick down wg0 >/dev/null 2>&1 || true
    rm -f /etc/wireguard/wg0.conf
    echo "family-vpn-install: incomplete new WireGuard config removed" >&2
  fi
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null || die "$1 is required"
}

self_check() {
  require_cmd sha256sum
  local got again
  got=$(printf 'family-vpn' | sha256sum | awk '{print $1}')
  again=$(printf 'family-vpn' | sha256sum | awk '{print $1}')
  [ "$got" = "$again" ] || die "checksum helper failed"
  echo "family-vpn-install $VERSION self-check ok"
}

normalize_backend() {
  BACKEND=${BACKEND%/}
  local scheme rest host port
  case "$BACKEND" in
    https://*) scheme=https; rest=${BACKEND#https://} ;;
    http://*) scheme=http; rest=${BACKEND#http://} ;;
    *) die "backend must start with https:// (http:// is only allowed for 127.0.0.1 or localhost)" ;;
  esac
  case "$rest" in
    ""|*/*|*"@"*|*"?"*|*"#"*|*" "*) die "backend must be an origin without a path" ;;
  esac
  case "$BACKEND" in
    *[!a-zA-Z0-9:/._~-]*) die "backend URL contains unsupported characters" ;;
  esac
  case "$rest" in
    *:*)
      host=${rest%:*}
      port=${rest##*:}
      case "$port" in
        ''|*[!0-9]*) die "backend port must be numeric" ;;
      esac
      [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "backend port is out of range"
      ;;
    *) host=$rest ;;
  esac
  [ -n "$host" ] || die "backend host is missing"
  if [ "$scheme" = "http" ]; then
    case "$host" in
      127.0.0.1|localhost) ;;
      *) die "plain HTTP is only allowed for 127.0.0.1 or localhost over a trusted tunnel; use https:// for a remote panel" ;;
    esac
  fi
}

wg_plan() {
  if [ -n "$1" ] && [ -f "$1" ]; then
    printf 'preserve\n'
  else
    printf 'create\n'
  fi
}

network_cidr() {
  local value="$1" ip prefix a b c d int mask network part
  case "$value" in
    *.*.*.*/*) ;;
    *) printf '\n'; return 0 ;;
  esac
  ip=${value%/*}
  prefix=${value#*/}
  case "$prefix" in
    ''|*[!0-9]*) printf '\n'; return 0 ;;
  esac
  if [ "$prefix" -gt 32 ]; then
    printf '\n'
    return 0
  fi
  IFS=. read -r a b c d <<EOF
$ip
EOF
  for part in "$a" "$b" "$c" "$d"; do
    case "$part" in
      ''|*[!0-9]*) printf '\n'; return 0 ;;
    esac
    if [ "$part" -gt 255 ]; then
      printf '\n'
      return 0
    fi
  done
  int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
  if [ "$prefix" -eq 0 ]; then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  network=$(( int & mask ))
  printf '%d.%d.%d.%d/%s\n' \
    $(( (network >> 24) & 255 )) \
    $(( (network >> 16) & 255 )) \
    $(( (network >> 8) & 255 )) \
    $(( network & 255 )) \
    "$prefix"
}

describe_wg_conf() {
  local file="$1"
  [ -n "$file" ] || die "pass a WireGuard config path"
  [ -f "$file" ] || die "wireguard config not found"
  local port="" address="" peers=0 private=0 postup=0 postdown=0
  local section="" line trimmed key value rules=""
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$trimmed" in
      "[Interface]") section=interface; continue ;;
      "[Peer]") section=peer; peers=$((peers + 1)); continue ;;
      "["*) section=other; continue ;;
    esac
    case "$trimmed" in
      *=*) ;;
      *) continue ;;
    esac
    key=$(printf '%s' "${trimmed%%=*}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    value=$(printf '%s' "${trimmed#*=}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]*#.*$//')
    case "$key" in
      privatekey) private=1 ;;
      listenport) [ "$section" = "interface" ] && port=$value ;;
      address) [ "$section" = "interface" ] && [ -z "$address" ] && address=$value ;;
      postup)
        if [ "$section" = "interface" ]; then
          postup=$((postup + 1))
          rules="${rules}rule_postup=${value}"$'\n'
        fi
        ;;
      postdown)
        if [ "$section" = "interface" ]; then
          postdown=$((postdown + 1))
          rules="${rules}rule_postdown=${value}"$'\n'
        fi
        ;;
    esac
  done < "$file"
  local subnet=""
  if [ -n "$address" ]; then
    subnet=$(network_cidr "$address")
  fi
  echo "action=preserve"
  echo "listen_port=${port}"
  echo "address=${address}"
  echo "subnet=${subnet}"
  echo "peers=${peers}"
  if [ "$private" -eq 1 ]; then
    echo "private_key=present"
  else
    echo "private_key=missing"
  fi
  echo "postup=${postup}"
  echo "postdown=${postdown}"
  printf '%s' "$rules"
}

is_hex64() {
  case "$1" in
    *[!0-9a-fA-F]*|"") return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

download_release() {
  require_cmd curl
  require_cmd sha256sum
  TMP_DIR=$(mktemp -d)
  local sums agent_name want got
  agent_name="family-vpn-agent-linux-amd64"
  echo "family-vpn-install: downloading release metadata"
  curl -fsSL "$BACKEND/releases/SHA256SUMS" -o "$TMP_DIR/SHA256SUMS"
  curl -fsSL "$BACKEND/releases/$agent_name" -o "$TMP_DIR/$agent_name"
  want=$(awk -v name="$agent_name" '
    {
      file = $2
      sub(/^\*/, "", file)
      if (file == name) { print $1; exit }
    }
  ' "$TMP_DIR/SHA256SUMS")
  [ -n "$want" ] || die "agent checksum is missing from SHA256SUMS"
  is_hex64 "$want" || die "agent checksum format is invalid"
  got=$(sha256sum "$TMP_DIR/$agent_name" | awk '{print $1}')
  [ "$got" = "$want" ] || die "downloaded agent checksum mismatch"
  BINARY="$TMP_DIR/$agent_name"
  SHA256="$want"
  echo "family-vpn-install: release checksum matches"
}

backup_wireguard() {
  [ -f /etc/wireguard/wg0.conf ] || return 0
  BACKUP_DIR="$DATA_DIR/backups"
  install -d -m 700 "$BACKUP_DIR"
  local stamp dest
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dest="$BACKUP_DIR/wg0.conf.$stamp"
  install -m 600 /etc/wireguard/wg0.conf "$dest"
  if command -v wg >/dev/null; then
    wg show wg0 > "$BACKUP_DIR/wg0.show.$stamp" 2>/dev/null || true
    chmod 600 "$BACKUP_DIR/wg0.show.$stamp" 2>/dev/null || true
  fi
  echo "family-vpn-install: WireGuard backup saved"
}

preflight() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
  [ -r /etc/os-release ] || die "cannot detect the operating system"
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ] || die "Ubuntu 24.04 is required"
  require_cmd ip
  require_cmd sha256sum
  if [ -f /etc/wireguard/wg0.conf ]; then
    echo "family-vpn-install: existing wg0.conf will be left unchanged"
    if command -v wg >/dev/null && wg show wg0 >/dev/null 2>&1; then
      echo "family-vpn-install: wg0 is present"
    else
      echo "family-vpn-install: wg0.conf exists; interface may be down"
    fi
  else
    echo "family-vpn-install: no wg0.conf; a new interface would be created on install"
  fi
  if [ -n "$BACKEND" ]; then
    normalize_backend
    require_cmd curl
    curl -fsSIL "$BACKEND/releases/SHA256SUMS" >/dev/null
    echo "family-vpn-install: panel releases endpoint is reachable"
  fi
  echo "family-vpn-install $VERSION preflight ok"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend) BACKEND=${2:-}; shift 2 ;;
    --binary) BINARY=${2:-}; shift 2 ;;
    --sha256) SHA256=${2:-}; shift 2 ;;
    --release-dir) RELEASE_DIR=${2:-}; shift 2 ;;
    --port) PORT=${2:-}; shift 2 ;;
    --subnet) SUBNET=${2:-}; shift 2 ;;
    --data) DATA_DIR=${2:-}; shift 2 ;;
    --self-check) MODE="self-check"; shift ;;
    --preflight) MODE="preflight"; shift ;;
    --check) MODE="check"; shift ;;
    --normalize) MODE="normalize"; shift ;;
    --describe-wg) MODE="describe-wg"; WG_FILE=${2:-}; shift 2 ;;
    --plan-wg) MODE="plan-wg"; WG_FILE=${2:-}; shift 2 ;;
    *) die "unknown argument" ;;
  esac
done

if [ "$MODE" = "self-check" ]; then
  self_check
  exit 0
fi

if [ "$MODE" = "preflight" ]; then
  preflight
  exit 0
fi

if [ "$MODE" = "describe-wg" ]; then
  describe_wg_conf "$WG_FILE"
  exit 0
fi

if [ "$MODE" = "plan-wg" ]; then
  [ -n "$WG_FILE" ] || die "pass a WireGuard config path"
  printf 'action=%s\n' "$(wg_plan "$WG_FILE")"
  exit 0
fi

if [ "$MODE" = "normalize" ]; then
  [ -n "$BACKEND" ] || die "pass --backend https://panel.example"
  normalize_backend
  printf '%s\n' "$BACKEND"
  exit 0
fi

[ -n "$BACKEND" ] || die "pass --backend https://panel.example"
normalize_backend
case "$PORT" in
  ''|*[!0-9]*) die "port must be numeric" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "port is out of range"
case "$SUBNET" in
  *.0/24) ;;
  *) die "subnet must be an IPv4 /24, for example 10.200.0.0/24" ;;
esac

if [ -n "$RELEASE_DIR" ]; then
  BINARY="$RELEASE_DIR/family-vpn-agent-linux-amd64"
  [ -f "$RELEASE_DIR/SHA256SUMS" ] || die "SHA256SUMS was not found in --release-dir"
  SHA256=$(awk '
    {
      file = $2
      sub(/^\*/, "", file)
      if (file == "family-vpn-agent-linux-amd64") { print $1; exit }
    }
  ' "$RELEASE_DIR/SHA256SUMS")
fi

if [ -z "$BINARY" ]; then
  download_release
fi

[ -n "$SHA256" ] || die "pass --sha256 or use panel releases"
is_hex64 "$SHA256" || die "sha256 must be 64 hex characters"
[ -f "$BINARY" ] || die "agent binary was not found"
got=$(sha256sum "$BINARY" | awk '{print $1}')
[ "$got" = "$SHA256" ] || die "agent binary checksum mismatch"
echo "family-vpn-install: agent binary checksum matches"

if [ "$MODE" = "check" ]; then
  echo "family-vpn-install $VERSION checksum ok"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -r /etc/os-release ] || die "cannot detect the operating system"
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ] || die "Ubuntu 24.04 is required"
require_cmd ip

install -d -m 700 "$DATA_DIR"
backup_wireguard
install -d -m 755 /usr/local/bin
install -m 755 "$BINARY" /usr/local/bin/family-vpn-agent
installed=$(sha256sum /usr/local/bin/family-vpn-agent | awk '{print $1}')
[ "$installed" = "$SHA256" ] || die "installed agent checksum mismatch"

if [ "$(wg_plan /etc/wireguard/wg0.conf)" = "preserve" ]; then
  describe_wg_conf /etc/wireguard/wg0.conf
  echo "family-vpn-install: existing wg0 left unchanged"
  echo "family-vpn-install: server key, peers, listen port, subnet, and network rules were not modified"
else
  require_cmd apt-get
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y wireguard
  iface=$(ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  [ -n "$iface" ] || die "could not detect the external network interface"
  base=${SUBNET%/*}
  address="${base%.*}.1/24"
  network="${base%.*}.0/24"
  tmp=$(mktemp -d)
  TMP_KEYS=$tmp
  wg genkey | tee "$tmp/private" | wg pubkey > "$tmp/public"
  chmod 600 "$tmp/private"
  umask 077
  CREATED_WG=1
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = $address
ListenPort = $PORT
PrivateKey = $(cat "$tmp/private")
PostUp = iptables -t nat -C POSTROUTING -s $network -o $iface -j MASQUERADE || iptables -t nat -A POSTROUTING -s $network -o $iface -j MASQUERADE
PostUp = iptables -C FORWARD -i wg0 -j ACCEPT || iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -C FORWARD -o wg0 -j ACCEPT || iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT || true
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -s $network -o $iface -j MASQUERADE || true
EOF
  chmod 600 /etc/wireguard/wg0.conf
  rm -rf "$tmp"
  TMP_KEYS=""
  if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-family-vpn.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
  fi
  wg-quick up wg0
  systemctl enable wg-quick@wg0
  : > "$DATA_DIR/wg-managed-by-installer"
  echo "family-vpn-install: new wg0 configured on $iface"
fi

cat > /etc/systemd/system/family-vpn-agent.service <<EOF
[Unit]
Description=Family VPN Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/family-vpn-agent run --backend $BACKEND --data $DATA_DIR
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
/usr/local/bin/family-vpn-agent enroll --backend "$BACKEND" --data "$DATA_DIR"
systemctl enable --now family-vpn-agent
echo "family-vpn-install: agent service is enabled"
echo "family-vpn-install: enter the pairing code in Servers → Add server"
