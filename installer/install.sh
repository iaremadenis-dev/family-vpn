#!/bin/bash
# Family VPN installer 0.5.0
# Downloads the agent only from the panel origin and verifies SHA-256 before install.
# Plain HTTP is accepted only for 127.0.0.1 and localhost (SSH tunnel).
# A remote panel must use HTTPS. This script does not pipe an unverified
# remote script into a privileged shell by itself.
# 0.5.0: signed heartbeats; new wg0 gets client-isolation FORWARD rules.
# Fresh installs also apply UFW (22/tcp + 51820/udp) and safe SSH hardening.
# --update never rewrites an existing wg0.conf, UFW, NAT, or SSH policy.
set -euo pipefail
umask 077

# Must not be named VERSION: sourcing /etc/os-release overwrites VERSION with Ubuntu's field.
AGENT_VERSION="0.5.0"
BACKEND=""
BINARY=""
SHA256=""
RELEASE_DIR=""
PORT="51820"
SUBNET=""
SUBNET_SET=0
DATA_DIR="/var/lib/family-vpn"
MODE="install"
CREATED_WG=0
TMP_KEYS=""
TMP_DIR=""
BACKUP_DIR=""
WG_FILE=""
AGENT_BIN="/usr/local/bin/family-vpn-agent"
AGENT_BACKUP=""
ROLE="direct"
UPLINK_FILE=""
PUBLIC_ADDRESS=""
SERVER_NAME=""
TRANSPORT_PORT="443"
TRANSPORT_DIR="/etc/family-vpn/transport"
TRANSPORT_BIN=""
TRANSPORT_STAGE=""
WIZARD_MODE=0
WIZARD_TMP=""

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
  if [ -n "$TRANSPORT_STAGE" ]; then
    rm -rf "$TRANSPORT_STAGE"
  fi
  if [ -n "$WIZARD_TMP" ]; then
    rm -rf "$WIZARD_TMP"
  fi
  if [ "$status" -ne 0 ] && [ "$CREATED_WG" -eq 1 ] && [ ! -f "$DATA_DIR/wg-managed-by-installer" ]; then
    systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true
    wg-quick down wg0 >/dev/null 2>&1 || true
    rm -f /etc/wireguard/wg0.conf
    echo "family-vpn-install: incomplete new WireGuard config removed" >&2
  fi
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null || die "$1 is required"
}

install_packages() {
  apt-get -o DPkg::Lock::Timeout=900 install -y "$@"
}

self_check() {
  require_cmd sha256sum
  local got again
  got=$(printf 'family-vpn' | sha256sum | awk '{print $1}')
  again=$(printf 'family-vpn' | sha256sum | awk '{print $1}')
  [ "$got" = "$again" ] || die "checksum helper failed"
  echo "family-vpn-install $AGENT_VERSION self-check ok"
}

assert_ubuntu_2404() {
  # Read os-release in a subshell so ID/VERSION* never clobber installer globals.
  local id version_id
  id=$(. /etc/os-release; printf '%s' "${ID:-}")
  version_id=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
  [ "$id" = "ubuntu" ] && [ "$version_id" = "24.04" ] || die "Ubuntu 24.04 is required"
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

write_agent_unit() {
  cat > /etc/systemd/system/family-vpn-agent.service <<EOF
[Unit]
Description=Family VPN Agent
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$AGENT_BIN run --backend $BACKEND --data $DATA_DIR
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA_DIR /etc/wireguard

[Install]
WantedBy=multi-user.target
EOF
}

# Detect default-route WAN iface. Never assumes ens3/eth0.
detect_wan_iface() {
  ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

ssh_admin_user() {
  if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    printf '%s\n' "$SUDO_USER"
  else
    printf 'root\n'
  fi
}

ssh_has_authorized_key() {
  local user=$1 home keys
  home=$(getent passwd "$user" | cut -d: -f6)
  [ -n "$home" ] || return 1
  keys="$home/.ssh/authorized_keys"
  [ -s "$keys" ] || return 1
  grep -E '^[[:space:]]*ssh-(ed25519|rsa|ecdsa)[A-Za-z0-9_-]*[[:space:]]' "$keys" >/dev/null
}

# Disable password SSH only after a usable authorized_keys entry exists for the admin user.
harden_ssh_if_safe() {
  local user conf
  user=$(ssh_admin_user)
  conf=/etc/ssh/sshd_config.d/99-family-vpn-hardening.conf
  if ! ssh_has_authorized_key "$user"; then
    echo "family-vpn-install: SSH password auth left enabled (no public key for $user)"
    return 0
  fi
  install -d -m 755 /etc/ssh/sshd_config.d
  cat >"$conf" <<'EOF'
# Managed by Family VPN installer. Password auth disabled only after authorized_keys check.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  chmod 644 "$conf"
  if ! sshd -t 2>/dev/null; then
    rm -f "$conf"
    echo "family-vpn-install: SSH hardening skipped (sshd -t failed); password auth unchanged"
    return 0
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  echo "family-vpn-install: SSH password authentication disabled for key-based access ($user)"
}

# UFW for a dedicated WG node. NAT/isolation stay in wg0 PostUp only (no duplicate MASQUERADE).
configure_ufw_agent() {
  local wan wg_port
  export DEBIAN_FRONTEND=noninteractive
  install_packages ufw >/dev/null
  # Let WireGuard PostUp own filter FORWARD / NAT; UFW must not drop forwarded WG traffic.
  if [ -f /etc/default/ufw ]; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw \
      || printf 'DEFAULT_FORWARD_POLICY="ACCEPT"\n' >>/etc/default/ufw
  fi
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  wg_port=$(wg show wg0 listen-port 2>/dev/null || true)
  if [ -z "$wg_port" ]; then
    wg_port=$(describe_wg_conf /etc/wireguard/wg0.conf | sed -n 's/^listen_port=//p')
  fi
  [ -n "$wg_port" ] || die "WireGuard listen port not found"
  ufw allow "$wg_port/udp" comment 'family-vpn-wireguard' >/dev/null
  wan=$(detect_wan_iface || true)
  if [ -n "$wan" ]; then
    # Route allowances are additive; they do not replace PostUp isolation DROP wg0→wg0.
    ufw route allow in on wg0 out on "$wan" >/dev/null 2>&1 || true
    ufw route allow in on "$wan" out on wg0 >/dev/null 2>&1 || true
  fi
  ufw --force enable >/dev/null
  ufw status | grep -qi 'Status: active' || die "ufw did not become active"
  echo "family-vpn-install: UFW active (22/tcp, $wg_port/udp); NAT/isolation remain in wg0 PostUp"
}

harden_fresh_agent_host() {
  # Never called from --update.
  configure_ufw_agent
  harden_ssh_if_safe
  install -d -m 700 "$DATA_DIR"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$DATA_DIR/host-hardening.done"
  chmod 600 "$DATA_DIR/host-hardening.done"
}

agent_is_paired() {
  local state="$DATA_DIR/agent.json"
  [ -f "$state" ] || return 1
  # Paired agents keep a non-empty token. Do not print secrets.
  grep -q '"token"[[:space:]]*:[[:space:]]*"[^"][^"]*"' "$state"
}

assert_paired_state() {
  [ -f "$AGENT_BIN" ] || die "current agent binary not found; use install, not --update"
  agent_is_paired || die "agent is not paired; refuse --update (no re-pair in update mode)"
  [ -f /etc/wireguard/wg0.conf ] || die "wg0.conf missing; refuse update that could alter networking assumptions"
}

# Pick a /24 in 10.200–10.250 that is not already used by a local route or address.
choose_vpn_subnet() {
  local candidate octet used
  used=$(
    {
      ip -4 route show 2>/dev/null || true
      ip -4 addr show 2>/dev/null || true
    } | tr ' ' '\n' | grep -E '^10\.(2[0-4][0-9]|250)\.0\.0/24$' || true
  )
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    octet=$((200 + $(od -An -N1 -tu1 /dev/urandom | tr -d ' ') % 51))
    candidate="10.${octet}.0.0/24"
    if ! printf '%s\n' "$used" | grep -Fxq "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # Deterministic fallback if random collisions keep hitting used ranges.
  for octet in $(seq 200 250); do
    candidate="10.${octet}.0.0/24"
    if ! printf '%s\n' "$used" | grep -Fxq "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  die "could not allocate a free VPN subnet in 10.200.0.0–10.250.0.0/24"
}

post_install_check() {
  require_cmd systemctl
  systemctl is-active --quiet family-vpn-agent || die "agent service is not active after install"
  local version
  version=$("$AGENT_BIN" --version 2>/dev/null | head -n 1 | tr -d '\r')
  [ "$version" = "$AGENT_VERSION" ] || die "agent version mismatch after install"
  if [ -f /etc/wireguard/wg0.conf ]; then
    if command -v wg >/dev/null; then
      wg show wg0 >/dev/null 2>&1 || die "wg0 is not up after install"
    fi
  fi
  if [ -f "$DATA_DIR/wg-managed-by-installer" ]; then
    systemctl is-enabled --quiet wg-quick@wg0 || die "wg-quick@wg0 is not enabled"
    systemctl is-active --quiet wg-quick@wg0 || die "wg-quick@wg0 is not active"
  fi
  [ -f "$DATA_DIR/agent.json" ] || die "agent state file missing after enroll"
  # Confirm enroll created a pairing code or token without printing secrets.
  if ! grep -qE '"pairingCode"|"token"|"enrollmentId"' "$DATA_DIR/agent.json"; then
    die "agent state incomplete after enroll"
  fi
  echo "family-vpn-install: health check ok"
}

backup_agent_binary() {
  BACKUP_DIR="$DATA_DIR/backups"
  install -d -m 700 "$BACKUP_DIR"
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  AGENT_BACKUP="$BACKUP_DIR/family-vpn-agent.$stamp"
  install -m 755 "$AGENT_BIN" "$AGENT_BACKUP"
  echo "family-vpn-install: agent binary backup saved"
}

rollback_agent_binary() {
  if [ -n "$AGENT_BACKUP" ] && [ -f "$AGENT_BACKUP" ]; then
    install -m 755 "$AGENT_BACKUP" "$AGENT_BIN"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart family-vpn-agent >/dev/null 2>&1 || true
    echo "family-vpn-install: rolled back to previous agent binary" >&2
  fi
}

read_agent_version() {
  local out=""
  out=$("$AGENT_BIN" --version 2>/dev/null | head -n 1 | tr -d '\r')
  if [ -z "$out" ]; then
    out=$("$AGENT_BIN" version 2>/dev/null | head -n 1 | tr -d '\r')
  fi
  printf '%s' "$out"
}

verify_agent_running() {
  local version="" pid=""
  systemctl is-active --quiet family-vpn-agent || return 1
  pid=$(systemctl show -p MainPID --value family-vpn-agent 2>/dev/null || true)
  case "$pid" in
    ''|0) return 1 ;;
  esac
  [ -d "/proc/$pid" ] || return 1
  version=$(read_agent_version)
  [ "$version" = "$AGENT_VERSION" ] || return 1
  return 0
}

update_paired_agent() {
  require_cmd systemctl
  assert_paired_state
  install -d -m 700 "$DATA_DIR"
  backup_wireguard
  backup_agent_binary

  local wg_before state_before
  wg_before=$(sha256sum /etc/wireguard/wg0.conf | awk '{print $1}')
  state_before=$(sha256sum "$DATA_DIR/agent.json" | awk '{print $1}')

  echo "family-vpn-install: updating paired agent in place (no enroll, wg0 untouched)"
  systemctl stop family-vpn-agent >/dev/null 2>&1 || true

  if ! install -m 755 "$BINARY" "$AGENT_BIN"; then
    rollback_agent_binary
    die "failed to install new agent binary"
  fi
  installed=$(sha256sum "$AGENT_BIN" | awk '{print $1}')
  if [ "$installed" != "$SHA256" ]; then
    rollback_agent_binary
    die "installed agent checksum mismatch after update"
  fi

  write_agent_unit
  systemctl daemon-reload
  systemctl enable family-vpn-agent >/dev/null
  if ! systemctl restart family-vpn-agent; then
    rollback_agent_binary
    die "new agent service failed to restart"
  fi

  local attempt=0
  while [ "$attempt" -lt 10 ]; do
    if verify_agent_running; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  if ! verify_agent_running; then
    rollback_agent_binary
    die "new agent did not stay active at version $AGENT_VERSION; rolled back"
  fi

  local wg_after state_after
  wg_after=$(sha256sum /etc/wireguard/wg0.conf | awk '{print $1}')
  state_after=$(sha256sum "$DATA_DIR/agent.json" | awk '{print $1}')
  [ "$wg_before" = "$wg_after" ] || die "wg0.conf changed during update; unexpected"
  [ "$state_before" = "$state_after" ] || die "agent.json changed during update; unexpected"

  echo "family-vpn-install: update to $AGENT_VERSION complete"
  echo "family-vpn-install: pairing token and WireGuard config preserved"
  "$AGENT_BIN" --version
}

preflight() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
  [ -r /etc/os-release ] || die "cannot detect the operating system"
  assert_ubuntu_2404
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
  echo "family-vpn-install $AGENT_VERSION preflight ok"
}

# Two-hop deployment uses this same installer twice. The exit does not need an agent.
# Existing/default invocations retain the direct WireGuard installation path.
transport_usage() {
  cat <<'EOF'
Interactive installation: sudo bash install.sh
Choose the server role when asked. The foreign VPS prints a connection code to paste
into the Russian VPS installer. Addresses and TLS settings are detected automatically.

Two-hop installation (Ubuntu 24.04, run as root):
  Foreign VPS:
    bash install.sh --role exit --public-address FOREIGN_IPV4 --server-name TLS_HOST
  Copy /etc/family-vpn/transport/uplink.json securely to the Russian VPS.
  Russian VPS:
    bash install.sh --role entry --uplink /root/uplink.json --backend https://PANEL

TLS_HOST must be a reachable TLS 1.3 website supporting X25519.
--transport-port defaults to 443. It must be free on the foreign VPS.
An already paired entry agent is reused. Client .conf/QR issuance uses that entry.
The entry keeps VPN forwarding blocked if the foreign transport fails.
Repeat the same command to repair/restart the transport without rotating exit credentials.
--preflight validates parameters without installing packages or changing networking.
On an existing two-hop setup, run the same file with --compare-uplinks on the exit
first, then on the entry. Both transports are checked with the existing client path.
A successful WireGuard comparison keeps that inter-server link active. Run
--use-vless on the entry to switch back. The client profile stays usable in both modes.
The original install and --update commands remain available with the default --role direct.
EOF
}

wizard_read() {
  read -r -p "$1" WIZARD_REPLY </dev/tty || die "input cancelled"
}

transport_export_code() {
  python3 - "$TRANSPORT_DIR/uplink.json" <<'PY'
import base64, json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
raw = json.dumps(data, separators=(",", ":")).encode()
print("FVPN1." + base64.urlsafe_b64encode(raw).decode().rstrip("="))
PY
}

transport_import_code() {
  # The code is data, never evaluated. No credentials appear in command arguments/history.
  python3 -c '
import base64, json, pathlib, sys
try:
    code = sys.stdin.read().strip()
    if not code.startswith("FVPN1.") or len(code) > 4096:
        raise ValueError()
    raw = code[6:]
    data = json.loads(base64.b64decode(raw + "=" * (-len(raw) % 4), altchars=b"-_", validate=True))
    pathlib.Path(sys.argv[1]).write_text(json.dumps(data), encoding="utf-8")
except (ValueError, TypeError, OSError):
    sys.exit("family-vpn-install: неверный код связи")
' "$UPLINK_FILE" <<<"$WIZARD_REPLY"
}

transport_wizard() {
  [ "$(id -u)" -eq 0 ] || die "запустите sudo bash install.sh"
  assert_ubuntu_2404
  [ -r /dev/tty ] || die "запустите скачанный файл командой sudo bash install.sh в терминале"
  WIZARD_MODE=1
  echo "Family VPN — настройка соединения через два сервера"
  echo "1 — зарубежный сервер (установить первым)"
  echo "2 — российский сервер, к которому подключается WireGuard"
  if [ -f "$TRANSPORT_DIR/role" ]; then
    ROLE=$(cat "$TRANSPORT_DIR/role")
    case "$ROLE" in entry|exit) ;; *) die "unknown installed transport role" ;; esac
    echo "Обнаружена существующая установка. Использую сохранённые параметры."
  else
    wizard_read "Какой это сервер? Введите 1 или 2: "
    case "$WIZARD_REPLY" in
      1) ROLE=exit ;;
      2) ROLE=entry ;;
      *) die "выберите 1 или 2" ;;
    esac
  fi
  if ! command -v python3 >/dev/null || ! command -v curl >/dev/null \
    || ! command -v openssl >/dev/null || ! command -v ss >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    install_packages python3 curl ca-certificates openssl iproute2
  fi
  if [ "$ROLE" = "exit" ]; then
    if [ -f "$TRANSPORT_DIR/uplink.json" ]; then
      PUBLIC_ADDRESS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"])' "$TRANSPORT_DIR/uplink.json")
      SERVER_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server_name"])' "$TRANSPORT_DIR/uplink.json")
      TRANSPORT_PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server_port"])' "$TRANSPORT_DIR/uplink.json")
      return
    fi
    local detected candidate
    detected=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1);exit}}')
    if ! python3 -c 'import ipaddress,sys; sys.exit(not ipaddress.IPv4Address(sys.argv[1]).is_global)' "$detected" 2>/dev/null; then
      detected=$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p') || detected=""
    fi
    if [ -z "$detected" ]; then
      wizard_read "Не удалось определить внешний IPv4. Введите IP этого VPS: "
      detected=$WIZARD_REPLY
    fi
    PUBLIC_ADDRESS=$detected
    echo "Адрес зарубежного сервера: $PUBLIC_ADDRESS"
    TRANSPORT_PORT=""
    for candidate in 443 8443 2053; do
      if [ -z "$(ss -H -ltn "sport = :$candidate")" ]; then TRANSPORT_PORT=$candidate; break; fi
    done
    [ -n "$TRANSPORT_PORT" ] || die "порты 443, 8443 и 2053 заняты; требуется отдельный свободный порт"
    echo "Проверяю параметры защищённого соединения…"
    for candidate in www.microsoft.com www.cloudflare.com www.apple.com; do
      if timeout 8 openssl s_client -connect "$candidate:443" -servername "$candidate" \
        -tls1_3 -groups X25519 -verify_hostname "$candidate" -verify_return_error -brief \
        </dev/null >/dev/null 2>&1; then
        SERVER_NAME=$candidate
        break
      fi
    done
    [ -n "$SERVER_NAME" ] || die "не удалось найти доступный TLS-сервер; проверьте интернет на VPS"
  else
    if [ -f "$TRANSPORT_DIR/entry-uplink.json" ]; then
      UPLINK_FILE="$TRANSPORT_DIR/entry-uplink.json"
    else
      wizard_read "Вставьте код связи, полученный на зарубежном сервере: "
      WIZARD_TMP=$(mktemp -d)
      UPLINK_FILE="$WIZARD_TMP/uplink.json"
      transport_import_code
      WIZARD_REPLY=""
    fi
    transport_validate
    if ! agent_is_paired; then
      BACKEND=${FAMILY_VPN_PUBLIC_URL:-}
      if [ -z "$BACKEND" ] && [ -f /etc/systemd/system/family-vpn-agent.service ]; then
        BACKEND=$(awk '/^ExecStart=/{for(i=1;i<NF;i++) if($i=="--backend") {print $(i+1);exit}}' /etc/systemd/system/family-vpn-agent.service)
      fi
      if [ -z "$BACKEND" ]; then
        wizard_read "Введите HTTPS-адрес вашей действующей панели Family VPN: "
        BACKEND=$WIZARD_REPLY
      fi
      normalize_backend
    fi
  fi
}

transport_validate() {
  case "$ROLE" in direct|entry|exit) ;; *) die "role must be direct, entry or exit" ;; esac
  case "$MODE" in install|preflight) ;; *) die "two-hop roles support install or --preflight" ;; esac
  case "$TRANSPORT_PORT" in ''|*[!0-9]*) die "transport port must be numeric" ;; esac
  [ "$TRANSPORT_PORT" -ge 1 ] && [ "$TRANSPORT_PORT" -le 65535 ] || die "transport port out of range"
  if [ "$ROLE" = "exit" ]; then
    [ -n "$PUBLIC_ADDRESS" ] && [ -n "$SERVER_NAME" ] || die "exit requires --public-address and --server-name"
    [ -z "$UPLINK_FILE" ] || die "--uplink is for the entry role"
  else
    [ -f "$UPLINK_FILE" ] && [ ! -L "$UPLINK_FILE" ] || die "entry requires a regular --uplink JSON file"
    [ -z "$PUBLIC_ADDRESS$SERVER_NAME" ] || die "exit address and TLS host come from --uplink"
  fi
  require_cmd python3
  # Parse data as JSON, never as shell code. Reject extra fields and untrusted overrides.
  python3 - "$ROLE" "$UPLINK_FILE" "$PUBLIC_ADDRESS" "$SERVER_NAME" <<'PY'
import base64, ipaddress, json, re, sys, uuid
role, filename, address, name = sys.argv[1:]
def host(value):
    if not isinstance(value, str) or len(value) > 253 or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", value):
        raise ValueError("invalid TLS hostname")
    if "." not in value or any(not label or len(label) > 63 for label in value.split(".")):
        raise ValueError("invalid TLS hostname")
try:
    if role == "entry":
        with open(filename, encoding="utf-8") as f:
            p = json.load(f)
        fields = {"version", "server", "server_port", "uuid", "server_name", "public_key", "short_id"}
        if not isinstance(p, dict) or set(p) != fields or type(p["version"]) is not int or p["version"] != 1:
            raise ValueError("unsupported uplink file")
        address, name = p["server"], p["server_name"]
        if type(p["server_port"]) is not int or not 1 <= p["server_port"] <= 65535:
            raise ValueError("invalid uplink port")
        uuid.UUID(p["uuid"])
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", p["public_key"]):
            raise ValueError("invalid REALITY public key")
        if len(base64.urlsafe_b64decode(p["public_key"] + "=")) != 32:
            raise ValueError("invalid REALITY public key")
        if not re.fullmatch(r"[0-9a-f]{8}", p["short_id"]):
            raise ValueError("invalid REALITY short ID")
    ip = ipaddress.IPv4Address(address)
    if not ip.is_global:
        raise ValueError("exit must have a public IPv4 address")
    host(name)
except (ValueError, TypeError, KeyError, OSError) as e:
    sys.exit("family-vpn-install: invalid transport parameters (" + type(e).__name__ + ")")
PY
}

transport_dependencies() {
  local packages=(ca-certificates curl python3 iproute2 iptables openssl util-linux)
  export DEBIAN_FRONTEND=noninteractive
  if [ -s "$TRANSPORT_DIR/config.json" ] && TRANSPORT_BIN=$(command -v sing-box) &&
    dpkg-query -W -f='${db:Status-Status}\n' "${packages[@]}" 2>/dev/null |
      awk -v count="${#packages[@]}" '$0 != "installed" { bad=1 } END { exit (bad || NR != count) }'; then
    return 0
  fi
  apt-get update -y
  install_packages "${packages[@]}"
  if ! command -v sing-box >/dev/null; then
    # Official signed APT repository. No downloaded shell script is executed.
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod 644 /etc/apt/keyrings/sagernet.asc
    cat >/etc/apt/sources.list.d/family-vpn-sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
    apt-get update -y
    install_packages sing-box
  fi
  TRANSPORT_BIN=$(command -v sing-box)
}

transport_render() {
  # Generated files contain credentials and are created under umask 077.
  if [ "$ROLE" = "entry" ]; then
    ip -j -4 route show table all >"$TRANSPORT_STAGE/routes.json"
  fi
  python3 - "$ROLE" "$TRANSPORT_STAGE" "$TRANSPORT_DIR" "$UPLINK_FILE" \
    "$PUBLIC_ADDRESS" "$SERVER_NAME" "$TRANSPORT_PORT" "$TRANSPORT_BIN" <<'PY'
import ipaddress, json, pathlib, re, secrets, subprocess, sys, uuid
role, stage, state, uplink, address, name, port, binary = sys.argv[1:]
stage, state = pathlib.Path(stage), pathlib.Path(state)
def write(name, obj):
    (stage / name).write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")
if role == "exit":
    if (state / "config.json").exists():
        config = json.loads((state / "config.json").read_text())
        params = json.loads((state / "uplink.json").read_text())
        if (params["server"], params["server_name"], params["server_port"]) != (address, name, int(port)):
            sys.exit("family-vpn-install: exit already configured with different parameters")
    else:
        pair = subprocess.check_output([binary, "generate", "reality-keypair"], text=True)
        private = re.search(r"PrivateKey:\s*(\S+)", pair).group(1)
        public = re.search(r"PublicKey:\s*(\S+)", pair).group(1)
        params = dict(version=1, server=address, server_port=int(port), uuid=str(uuid.uuid4()),
                      server_name=name, public_key=public, short_id=secrets.token_hex(4))
        config = {
            "log": {"level": "warn"},
            "inbounds": [{"type": "vless", "tag": "entry", "listen": "0.0.0.0", "listen_port": int(port),
                "users": [{"uuid": params["uuid"], "flow": "xtls-rprx-vision"}],
                "tls": {"enabled": True, "server_name": name, "reality": {"enabled": True,
                    "handshake": {"server": name, "server_port": 443},
                    "private_key": private, "short_id": [params["short_id"]]}}}],
            "outbounds": [{"type": "direct", "tag": "internet"}],
            "route": {"final": "internet"}}
    write("uplink.json", params)
else:
    params = json.loads(pathlib.Path(uplink).read_text())
    # Only wg0 traffic is policy-routed to this TUN. The host default route stays usable for management.
    used = json.loads((stage / "routes.json").read_text())
    networks = [ipaddress.ip_network(r["dst"], strict=False) for r in used
                if r.get("dst") not in (None, "default") and r.get("dev") != "fvpn-tun"]
    tun = None
    for candidate in ("172.31.255.1/30", "198.18.255.1/30", "10.254.255.1/30"):
        if not any(ipaddress.ip_interface(candidate).network.overlaps(n) for n in networks):
            tun = candidate
            break
    if tun is None:
        sys.exit("family-vpn-install: no free TUN subnet")
    config = {
        "log": {"level": "warn"},
        "inbounds": [{"type": "tun", "tag": "vpn", "interface_name": "fvpn-tun",
            "address": [tun], "mtu": 1400, "auto_route": False, "stack": "gvisor"}],
        "outbounds": [{"type": "vless", "tag": "foreign", "server": params["server"],
            "server_port": params["server_port"], "uuid": params["uuid"], "flow": "xtls-rprx-vision",
            "packet_encoding": "xudp", "tls": {"enabled": True, "server_name": params["server_name"],
                "utls": {"enabled": True, "fingerprint": "chrome"},
                "reality": {"enabled": True, "public_key": params["public_key"], "short_id": params["short_id"]}}}],
        "route": {"final": "foreign"}}
    # Preserve a tested WireGuard selection during an ordinary repair of this same exit.
    previous = state / "config.json"
    if previous.exists() and (state / "entry-uplink.json").exists():
        old = json.loads(previous.read_text())
        if (old.get("route", {}).get("final") == "family-wg-uplink"
                and json.loads((state / "entry-uplink.json").read_text()) == params):
            config["endpoints"] = [ep for ep in old["endpoints"] if ep["tag"] == "family-wg-uplink"]
            config["route"]["final"] = "family-wg-uplink"
write("config.json", config)
PY
  "$TRANSPORT_BIN" check -c "$TRANSPORT_STAGE/config.json"
}

transport_write_guard() {
  local network=$1
  cat <<EOF
#!/bin/bash
set -euo pipefail
# These guards intentionally persist when sing-box stops. No direct fallback.
iptables -w -N FVPN_EGRESS 2>/dev/null || true
iptables -w -C FVPN_EGRESS -i wg0 -j DROP 2>/dev/null || iptables -w -A FVPN_EGRESS -i wg0 -j DROP
iptables -w -C FVPN_EGRESS -i wg0 -o fvpn-tun -j ACCEPT 2>/dev/null || iptables -w -I FVPN_EGRESS 1 -i wg0 -o fvpn-tun -j ACCEPT
iptables -w -C FVPN_EGRESS -i fvpn-tun -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -w -I FVPN_EGRESS 1 -i fvpn-tun -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
if [ "\$(iptables -w -S FORWARD 1 2>/dev/null || true)" != '-A FORWARD -j FVPN_EGRESS' ]; then
  if iptables -w -C FORWARD -j FVPN_EGRESS 2>/dev/null; then
    # Move only our jump in one transaction, keeping unrelated firewall rules intact.
    printf '%s\n' '*filter' '-D FORWARD -j FVPN_EGRESS' '-I FORWARD 1 -j FVPN_EGRESS' 'COMMIT' | iptables-restore -w --noflush
  else
    iptables -w -I FORWARD 1 -j FVPN_EGRESS
  fi
fi
# Client profiles currently provide IPv4 addresses only. Explicitly block forwarded IPv6.
ip6tables -w -C FORWARD -i wg0 -j DROP 2>/dev/null || ip6tables -w -I FORWARD 1 -i wg0 -j DROP
ip -4 route replace unreachable default metric 32767 table 51821
# Gateway replies also match the source policy. Keep peer destinations on wg0.
# The more specific unreachable route survives removal of the interface.
ip -4 route replace unreachable $network metric 32767 table 51821
if ip link show dev wg0 >/dev/null 2>&1; then
  ip -4 route replace $network dev wg0 scope link metric 1 table 51821
fi
if ! ip -4 rule show | grep -Eq '^10518:.*from ${network//./\\.} .*lookup 51821'; then
  if ip -4 rule show | grep -q '^10518:'; then
    echo 'family-vpn: policy priority 10518 already in use' >&2
    exit 1
  fi
  ip -4 rule add priority 10518 from $network table 51821
fi
# Enable forwarding only after the fail-closed routes and filtering are in place.
if [ "\$(sysctl -n net.ipv4.ip_forward)" != 1 ]; then
  sysctl -qw net.ipv4.ip_forward=1
fi
EOF
}

transport_entry_guard() {
  local network
  network=$(describe_wg_conf /etc/wireguard/wg0.conf | sed -n 's/^subnet=//p')
  [ -n "$network" ] || die "wg0 IPv4 subnet not found"
  install -d -m 755 /usr/local/lib/family-vpn /etc/systemd/system/wg-quick@wg0.service.d
  transport_write_guard "$network" >/usr/local/lib/family-vpn/egress-guard.sh
  chmod 700 /usr/local/lib/family-vpn/egress-guard.sh
  cat >/etc/systemd/system/family-vpn-egress-guard.service <<'EOF'
[Unit]
Description=Family VPN fail-closed forwarding
Before=wg-quick@wg0.service family-vpn-transport.service
After=network-pre.target ufw.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/family-vpn/egress-guard.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/wg-quick@wg0.service.d/family-vpn-egress.conf <<'EOF'
[Unit]
Requires=family-vpn-egress-guard.service
After=family-vpn-egress-guard.service

[Service]
ExecStartPost=/usr/local/lib/family-vpn/egress-guard.sh
EOF
  systemctl daemon-reload
  systemctl enable family-vpn-egress-guard.service
  systemctl restart family-vpn-egress-guard.service
}

transport_start() {
  local previous=0 was_active=0
  if [ -f "$TRANSPORT_DIR/config.json" ]; then
    install -m 600 "$TRANSPORT_DIR/config.json" "$TRANSPORT_STAGE/previous.json"
    previous=1
  fi
  if [ "$ROLE" = "exit" ]; then
    # Save the matching export before starting so an interrupted first install is repairable.
    install -m 600 "$TRANSPORT_STAGE/uplink.json" "$TRANSPORT_DIR/uplink.json.next"
    mv -f "$TRANSPORT_DIR/uplink.json.next" "$TRANSPORT_DIR/uplink.json"
  fi
  systemctl is-active --quiet family-vpn-transport && was_active=1
  install -m 600 "$TRANSPORT_STAGE/config.json" "$TRANSPORT_DIR/config.json.next"
  mv -f "$TRANSPORT_DIR/config.json.next" "$TRANSPORT_DIR/config.json"
  cat >/etc/systemd/system/family-vpn-transport.service <<EOF
[Unit]
Description=Family VPN $ROLE transport
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0
EOF
  if [ "$ROLE" = "entry" ]; then
    cat >>/etc/systemd/system/family-vpn-transport.service <<'EOF'
Requires=family-vpn-egress-guard.service
After=family-vpn-egress-guard.service
EOF
  fi
  cat >>/etc/systemd/system/family-vpn-transport.service <<EOF

[Service]
Type=simple
ExecStart=$TRANSPORT_BIN run -c $TRANSPORT_DIR/config.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
UMask=0077
EOF
  if [ "$ROLE" = "entry" ]; then
    cat >>/etc/systemd/system/family-vpn-transport.service <<'EOF'
ExecStartPost=/bin/bash -c 'for n in {1..50}; do ip link show fvpn-tun >/dev/null 2>&1 && exec ip -4 route replace default dev fvpn-tun metric 1 table 51821; sleep 0.1; done; exit 1'
EOF
  fi
  cat >>/etc/systemd/system/family-vpn-transport.service <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  local started=0
  if systemctl restart family-vpn-transport; then
    sleep 2
    if systemctl is-active --quiet family-vpn-transport; then started=1; fi
  fi
  if [ "$started" -ne 1 ]; then
    if [ "$previous" -eq 1 ]; then
      install -m 600 "$TRANSPORT_STAGE/previous.json" "$TRANSPORT_DIR/config.json.next"
      mv -f "$TRANSPORT_DIR/config.json.next" "$TRANSPORT_DIR/config.json"
      if [ "$was_active" -eq 1 ]; then systemctl restart family-vpn-transport || true; fi
    fi
    die "transport failed to start; entry forwarding stays fail-closed; retry after checking journalctl -u family-vpn-transport"
  fi
  systemctl enable family-vpn-transport
}

install_transport() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
  assert_ubuntu_2404
  transport_validate
  require_cmd flock
  exec 9>/run/lock/family-vpn-transport.lock
  flock -n 9 || die "another transport installation is running"
  [ ! -L "$TRANSPORT_DIR" ] || die "transport directory must not be a symlink"
  if [ -f "$TRANSPORT_DIR/role" ]; then
    [ "$(cat "$TRANSPORT_DIR/role")" = "$ROLE" ] || die "this host already has a different transport role"
  elif [ -e "$TRANSPORT_DIR/config.json" ] || [ -e /etc/systemd/system/family-vpn-transport.service ]; then
    die "unmanaged transport files found; inspect them before installing"
  fi
  if [ "$ROLE" = "entry" ] && [ ! -f "$TRANSPORT_DIR/role" ]; then
    if ip -4 rule show | grep -Eq '^10518:|lookup 51821( |$)' \
      || [ -n "$(ip -4 route show table 51821 2>/dev/null)" ] \
      || ip link show fvpn-tun >/dev/null 2>&1 \
      || iptables -w -S FVPN_EGRESS >/dev/null 2>&1; then
      die "entry routing identifiers already in use (10518/51821/fvpn-tun/FVPN_EGRESS)"
    fi
  fi
  link_recover || die "previous transport switch could not be restored"
  transport_dependencies
  TRANSPORT_STAGE=$(mktemp -d)
  transport_render
  if [ "$ROLE" = "exit" ]; then
    # Refuse a port owned by another service, including an existing panel on 443.
    if ! systemctl is-active --quiet family-vpn-transport && [ -n "$(ss -H -ltn "sport = :$TRANSPORT_PORT")" ]; then
      die "transport TCP port is occupied; choose --transport-port"
    fi
    timeout 15 openssl s_client -connect "$SERVER_NAME:443" -servername "$SERVER_NAME" \
      -tls1_3 -groups X25519 -verify_hostname "$SERVER_NAME" -verify_return_error -brief </dev/null \
      >/dev/null 2>&1 || die "TLS host must accept verified TLS 1.3 with X25519"
  fi
  install -d -m 700 "$TRANSPORT_DIR"
  printf '%s\n' "$ROLE" >"$TRANSPORT_DIR/role"
  if [ "$ROLE" = "entry" ]; then transport_entry_guard; fi
  transport_start
  if [ "$ROLE" = "exit" ]; then
    if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
      ufw allow "$TRANSPORT_PORT/tcp" comment 'family-vpn-transport'
    fi
    if [ "$WIZARD_MODE" -eq 0 ]; then
      echo "family-vpn-install: exit ready; securely copy $TRANSPORT_DIR/uplink.json to the entry VPS (contains access credentials)"
    fi
    echo "family-vpn-install: allow TCP $TRANSPORT_PORT in the hosting provider firewall"
  else
    install -m 600 "$UPLINK_FILE" "$TRANSPORT_DIR/entry-uplink.json.next"
    mv -f "$TRANSPORT_DIR/entry-uplink.json.next" "$TRANSPORT_DIR/entry-uplink.json"
    echo "family-vpn-install: entry transport running; forwarding is limited to fvpn-tun"
  fi
}

transport_probe() {
  local host_address route expected observed
  host_address=$(ip -o -4 addr show dev wg0 | awk '{split($4, a, "/"); print a[1]; exit}')
  [ -n "$host_address" ] || die "entry wg0 is down"
  [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] || die "IPv4 forwarding is disabled on the entry"
  route=$(ip -4 route get 1.1.1.1 from "$host_address") || die "entry has no route for its HTTPS check"
  case " $route " in
    *" dev fvpn-tun "*) ;;
    *) die "entry HTTPS check would bypass fvpn-tun" ;;
  esac
  curl -4 --noproxy '*' -fsS --interface "$host_address" --connect-timeout 10 --max-time 20 \
    https://1.1.1.1/cdn-cgi/trace -o "$TRANSPORT_STAGE/probe.txt" \
    || die "HTTPS from the entry through fvpn-tun failed"
  expected=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["server"])' "$TRANSPORT_DIR/entry-uplink.json")
  observed=$(python3 - "$TRANSPORT_STAGE/probe.txt" <<'PY'
import ipaddress, pathlib, sys
ips = [line[3:] for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.startswith("ip=")]
if len(ips) != 1:
    sys.exit(1)
try:
    print(ipaddress.IPv4Address(ips[0]))
except ValueError:
    sys.exit(1)
PY
  ) || die "entry HTTPS check returned an invalid IPv4 address"
  if [ "$observed" = "$expected" ]; then
    echo "family-vpn-install: HTTPS from the entry used the configured exit IPv4 ($observed)"
  else
    # A VPS may legitimately send traffic from a different address behind provider NAT.
    echo "family-vpn-install: HTTPS from the entry returned IPv4 $observed; configured endpoint is $expected. Exit IP unconfirmed." >&2
  fi
}

# Use the real wg0 and the installed uplink. The encrypted hop stays on this VPS.
transport_client_probe() {
  python3 - "$@" <<'PY'
import ipaddress, json, os, pathlib, re, secrets, signal, subprocess, sys

resolver, trace_url, expected, journal_path = sys.argv[1:5]
strict = sys.argv[5:] == ["strict"]
journal = pathlib.Path(journal_path)
def run(*args, data=None):
    return subprocess.run(args, input=data, stdout=subprocess.PIPE, check=True).stdout
def wg_value(field):
    return run("wg", "show", "wg0", field).decode().strip()
def cleanup(state):
    ns, key = state["ns"], state["public"]
    if not re.fullmatch(r"fvpc[0-9a-f]{10}", ns) or not re.fullmatch(r"[A-Za-z0-9+/]{43}=", key):
        raise RuntimeError("invalid client-check recovery state")
    # This key is generated for this probe only. Production peers retain their /32s.
    if key in wg_value("peers").split():
        run("wg", "set", "wg0", "peer", key, "remove")
    if pathlib.Path("/run/netns", ns).exists():
        run("ip", "netns", "delete", ns)
    if pathlib.Path("/sys/class/net", ns).exists():
        run("ip", "link", "delete", ns)
    journal.unlink(missing_ok=True)

def probe():
    if journal.exists():
        cleanup(json.loads(journal.read_text()))
    addresses = json.loads(run("ip", "-j", "-4", "addr", "show"))
    wgaddrs = [a for dev in addresses if dev["ifname"] == "wg0" for a in dev["addr_info"] if a["family"] == "inet"]
    if len(wgaddrs) != 1:
        raise RuntimeError("проверке требуется один IPv4-адрес на wg0")
    subnet = ipaddress.ip_interface(f"{wgaddrs[0]['local']}/{wgaddrs[0]['prefixlen']}").network
    used = [ipaddress.ip_network(a["local"]) for dev in addresses for a in dev["addr_info"] if a["family"] == "inet"]
    for line in wg_value("allowed-ips").splitlines():
        for value in line.replace(",", " ").split()[1:]:
            if value != "(none)":
                net = ipaddress.ip_network(value)
                if net.version == 4:
                    used.append(net)
    # The panel assigns /32s. A concurrent new client always takes precedence over our /31.
    # Consider at most 128 pairs and exclude both the network and broadcast addresses.
    for high in range(int(subnet.broadcast_address)-2, max(int(subnet.network_address)+1, int(subnet.broadcast_address)-258), -2):
        pair = ipaddress.ip_network((high, 31), strict=False)
        if not any(pair.overlaps(other) for other in used):
            break
    else:
        if strict:
            raise RuntimeError("для сравнения нужен свободный адрес тестового клиента")
        print("Проверка тестовым клиентом пропущена: в подсети нет подходящей свободной пары адресов.")
        return
    source = str(pair.broadcast_address)
    route = run("ip", "-j", "-4", "route", "get", resolver, "from", source, "iif", "wg0")
    if json.loads(route)[0].get("dev") != "fvpn-tun":
        raise RuntimeError("маршрут запроса клиента с wg0 ведёт мимо fvpn-tun")
    target_key, port = wg_value("public-key"), wg_value("listen-port")
    private = run("wg", "genkey")
    key = run("wg", "pubkey", data=private).decode().strip()
    ns = "fvpc" + secrets.token_hex(5)
    if pathlib.Path("/run/netns", ns).exists() or pathlib.Path("/sys/class/net", ns).exists():
        raise RuntimeError("имя временного интерфейса занято")
    state = {"ns": ns, "public": key}
    tmp = journal.with_suffix(".next")
    tmp.write_text(json.dumps(state))
    os.replace(tmp, journal)
    try:
        run("ip", "netns", "add", ns)
        run("ip", "link", "add", ns, "type", "wireguard")
        run("wg", "set", ns, "private-key", "/dev/stdin", "peer", target_key,
            "allowed-ips", "0.0.0.0/0", "endpoint", "127.0.0.1:" + port, data=private)
        del private
        run("ip", "link", "set", ns, "netns", ns)
        run("ip", "-n", ns, "addr", "add", source + "/32", "dev", ns)
        run("ip", "-n", ns, "link", "set", ns, "mtu", "1280", "up")
        run("ip", "-n", ns, "route", "add", "default", "dev", ns)
        run("wg", "set", "wg0", "peer", key, "allowed-ips", str(pair))
        prefix = ["ip", "netns", "exec", ns]
        dns_code = """
import secrets, socket, struct, sys
tx = secrets.token_bytes(2)
request = tx + bytes.fromhex("01000001000000000000") + b"\\x07example\\x03com\\x00\\x00\\x01\\x00\\x01"
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.connect((sys.argv[1], 53))
    s.settimeout(3)
    for _ in range(2):
        s.send(request)
        try:
            msg = s.recv(4096)
        except socket.timeout:
            continue
        if len(msg) >= 12 and msg[:2] == tx:
            flags, _, answers = struct.unpack("!HHH", msg[2:8])
            if flags & 0x8000 and not flags & 15 and answers:
                sys.exit(0)
sys.exit(1)
"""
        dns = subprocess.run(prefix + [sys.executable, "-c", dns_code, resolver]).returncode == 0
        http = subprocess.run(prefix + ["curl", "-4", "--noproxy", "*", "-fsS",
            "--connect-timeout", "5", "--max-time", "12", trace_url], stdout=subprocess.PIPE)
        stamps = dict(line.split() for line in wg_value("latest-handshakes").splitlines())
        if int(stamps.get(key, 0)) == 0:
            raise RuntimeError("тестовый клиент не завершил локальное рукопожатие с wg0")
        print("Тестовый клиент: WireGuard OK, DNS " + ("OK" if dns else "СБОЙ"), flush=True)
        if http.returncode:
            raise RuntimeError("HTTPS от тестового клиента через зарубежный выход завершился ошибкой")
        ips = [line[3:] for line in http.stdout.decode().splitlines() if line.startswith("ip=")]
        if len(ips) != 1:
            raise RuntimeError("служба проверки не вернула один адрес выхода")
        address = str(ipaddress.IPv4Address(ips[0]))
        print(f"Тестовый клиент: HTTPS OK, внешний IPv4 {address}", flush=True)
        if strict and address != expected:
            raise RuntimeError(f"не подтверждён ожидаемый зарубежный IPv4 {expected}")
        if address != expected:
            print(f"Адрес выхода отличается от адреса подключения {expected}; возможен NAT у хостера.")
        if not dns:
            raise RuntimeError("через выход проходит HTTPS, запрос DNS по UDP без подтверждённого ответа")
        print("На VPS путь WireGuard → зарубежный выход проверен. Доступ из сети устройства проверяется отдельно.")
    finally:
        cleanup(state)

def interrupted(number, frame):
    raise SystemExit(128 + number)
for sig in (signal.SIGHUP, signal.SIGTERM):
    signal.signal(sig, interrupted)
try:
    probe()
except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
    sys.exit("family-vpn-install: " + str(error))
PY
}

transport_verify_entry() {
  transport_probe
  # wg-quick may persist a transient peer on shutdown if SaveConfig is enabled.
  if grep -Eiq '^[[:space:]]*SaveConfig[[:space:]]*=[[:space:]]*true([[:space:]#]|$)' /etc/wireguard/wg0.conf; then
    [ "${1:-}" != strict ] || die "сравнение требует проверки тестовым клиентом (SaveConfig включён)"
    echo "Тестовый клиент пропущен: wg-quick сохраняет работающую конфигурацию при остановке."
    return
  fi
  local expected
  expected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"])' "$TRANSPORT_DIR/entry-uplink.json")
  transport_client_probe 1.1.1.1 https://1.1.1.1/cdn-cgi/trace "$expected" /run/family-vpn-client-check.json "${1:-normal}"
}

# Add a userspace WireGuard link to an installed two-hop setup. wg0, its peers
# and the host routing table belong to the original entry installation.
link_render() {
  python3 - "$ROLE" "$TRANSPORT_BIN" "$TRANSPORT_DIR" "$TRANSPORT_STAGE" "$1" <<'PY'
import base64, ipaddress, json, pathlib, re, subprocess, sys
role, binary, state, stage, port = sys.argv[1:]
state, stage = pathlib.Path(state), pathlib.Path(stage)
def read(path):
    return json.loads(path.read_text())
def write(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")
def keypair():
    output = subprocess.check_output([binary, "generate", "wg-keypair"], text=True)
    return [re.search(label + r":\s*(\S+)", output).group(1) for label in ("PrivateKey", "PublicKey")]
def valid_key(key):
    return isinstance(key, str) and len(base64.b64decode(key, validate=True)) == 32
def encode(obj):
    return "FWG1." + base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")

cfg = read(state / "config.json")
link = read(state / ("uplink.json" if role == "exit" else "entry-uplink.json"))
tag = "family-wg-uplink"
if role == "exit":
    path = state / "wg-link-keys.json"
    if path.exists():
        keys = read(path)
    else:
        private, public = keypair()
        client_private, client_public = keypair()
        keys = dict(private=private, public=public, client_private=client_private,
                    client_public=client_public, port=int(port))
    write(stage / path.name, keys)
    ticket = [link["server"], link["public_key"], keys["port"], keys["public"], keys["client_private"]]
    (stage / "link.code").write_text(encode(ticket) + "\n")
    ep = dict(private_key=keys["private"], address=["10.254.253.1/32"], listen_port=keys["port"],
              peers=[dict(public_key=keys["client_public"], allowed_ips=["10.254.253.2/32"])])
else:
    cfg["route"]["final"] = "foreign"
    cfg["endpoints"] = [ep for ep in cfg.get("endpoints", []) if ep["tag"] != tag]
    write(stage / "vless.json", cfg)
    if port == "vless":
        sys.exit(0)
    try:
        code = (stage / "link.code").read_text().strip()
        if len(code) > 1500 or not code.startswith("FWG1."):
            raise ValueError()
        raw = code[5:]
        ip, identity, port, public, private = json.loads(base64.b64decode(
            raw + "=" * (-len(raw) % 4), altchars=b"-_", validate=True))
        if (str(ipaddress.IPv4Address(ip)) != link["server"] or identity != link["public_key"]
                or type(port) is not int or not 1 <= port <= 65535
                or not valid_key(public) or not valid_key(private)):
            raise ValueError()
    except (ValueError, TypeError):
        sys.exit("Код WireGuard повреждён или выдан другим выходным сервером.")
    ep = dict(private_key=private, address=["10.254.253.2/32"],
              peers=[dict(address=ip, port=port, public_key=public, allowed_ips=["0.0.0.0/0"],
                          persistent_keepalive_interval=25)])
    cfg["route"]["final"] = tag
ep.update(type="wireguard", tag=tag, system=False, mtu=1280)
cfg["endpoints"] = [old for old in cfg.get("endpoints", []) if old["tag"] != tag] + [ep]
write(stage / "wireguard.json", cfg)
PY
}

link_install_config() {
  install -m 600 "$1" "$TRANSPORT_DIR/config.json.next" &&
    mv -f "$TRANSPORT_DIR/config.json.next" "$TRANSPORT_DIR/config.json" &&
    systemctl restart family-vpn-transport &&
    systemctl is-active --quiet family-vpn-transport
}

link_recover() {
  local saved="$TRANSPORT_DIR/before-link-switch.json"
  if [ -f "$saved" ]; then
    echo "Восстанавливаю предыдущую конфигурацию связи между серверами." >&2
    link_install_config "$saved" && rm -f "$saved"
  fi
}

link_compare() (
  set -euo pipefail
  [ "$(id -u)" = 0 ] || die "запустите через sudo"
  assert_ubuntu_2404
  umask 077
  exec 9>/run/lock/family-vpn-transport.lock
  flock -n 9 || die "another transport installation is running"
  [ -s "$TRANSPORT_DIR/role" ] || die "сначала установите обычную связь через два сервера"
  ROLE=$(cat "$TRANSPORT_DIR/role")
  case "$ROLE" in entry|exit) ;; *) die "unknown installed role" ;; esac
  TRANSPORT_BIN=$(command -v sing-box) || die "sing-box is missing"
  link_recover || die "предыдущая конфигурация ожидает восстановления"
  TRANSPORT_STAGE=$(mktemp -d)
  trap 'rc=$?; link_recover || rc=1; rm -rf "$TRANSPORT_STAGE"; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  local saved="$TRANSPORT_DIR/before-link-switch.json" port="" candidate
  if [ "$ROLE" = exit ]; then
    [ "$1" = compare ] || die "VLESS выбирается только на российском VPS"
    if [ -f "$TRANSPORT_DIR/wg-link-keys.json" ]; then
      port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$TRANSPORT_DIR/wg-link-keys.json")
    else
      for candidate in 51821 51822 51823; do
        if [ -z "$(ss -H -uan "sport = :$candidate")" ]; then port=$candidate; break; fi
      done
      [ -n "$port" ] || die "нет свободного UDP-порта для связи серверов"
    fi
    link_render "$port"
    "$TRANSPORT_BIN" check -c "$TRANSPORT_STAGE/wireguard.json"
    install -m 600 "$TRANSPORT_STAGE/wg-link-keys.json" "$TRANSPORT_DIR/wg-link-keys.json.next"
    mv -f "$TRANSPORT_DIR/wg-link-keys.json.next" "$TRANSPORT_DIR/wg-link-keys.json"
    install -m 600 "$TRANSPORT_DIR/config.json" "$saved.next"
    mv -f "$saved.next" "$saved"
    link_install_config "$TRANSPORT_STAGE/wireguard.json"
    sleep 1
    systemctl is-active --quiet family-vpn-transport
    ss -H -lun "sport = :$port" | grep -q . || die "зарубежный WireGuard не открыл UDP-порт $port"
    if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
      ufw allow "$port/udp" comment 'family-vpn-wg-uplink'
    fi
    rm -f "$saved"
    echo "Для российского VPS доступны VLESS и WireGuard. Порт WireGuard на зарубежном VPS: $port/UDP."
    echo "Если у хостера включён внешний firewall, разрешите этот UDP-порт с адреса российского VPS."
    echo "Скопируйте секретный код в терминал российского VPS:"
    cat "$TRANSPORT_STAGE/link.code"
    exit 0
  fi

  if [ "$1" = compare ]; then
    local prompt="Вставьте код FWG1 с зарубежного VPS и нажмите Enter: "
    if [ -s "$TRANSPORT_DIR/wg-link.code" ]; then
      install -m 600 "$TRANSPORT_DIR/wg-link.code" "$TRANSPORT_STAGE/link.code"
      prompt="Enter — использовать прежний код FWG1; либо вставьте новый код: "
    fi
    if [ -t 0 ] || [ ! -s "$TRANSPORT_STAGE/link.code" ]; then
      read -rs -p "$prompt" candidate </dev/tty || die "ввод прерван"
      printf '\n'
      if [ -n "$candidate" ]; then printf '%s\n' "$candidate" >"$TRANSPORT_STAGE/link.code"; fi
      unset candidate
    fi
    [ -s "$TRANSPORT_STAGE/link.code" ] || die "нужен код FWG1 с зарубежного VPS"
  fi
  link_render "$1"
  "$TRANSPORT_BIN" check -c "$TRANSPORT_STAGE/vless.json"
  if [ "$1" = compare ]; then "$TRANSPORT_BIN" check -c "$TRANSPORT_STAGE/wireguard.json"; fi
  install -m 600 "$TRANSPORT_DIR/config.json" "$saved.next"
  mv -f "$saved.next" "$saved"
  if [ "$1" = vless ]; then
    link_install_config "$TRANSPORT_STAGE/vless.json"
    rm -f "$saved"
    echo "Между серверами выбран VLESS + REALITY."
    exit 0
  fi
  local vless_result="сбой" wg_result="сбой"
  echo "A — проверка VLESS + REALITY"
  if link_install_config "$TRANSPORT_STAGE/vless.json" && ( transport_verify_entry strict ); then vless_result=OK; fi
  echo "Б — проверка WireGuard между серверами"
  if link_install_config "$TRANSPORT_STAGE/wireguard.json" && ( transport_verify_entry strict ); then
    wg_result=OK
    install -m 600 "$TRANSPORT_STAGE/link.code" "$TRANSPORT_DIR/wg-link.code.next"
    mv -f "$TRANSPORT_DIR/wg-link.code.next" "$TRANSPORT_DIR/wg-link.code"
    rm -f "$saved"
    echo "Выбран межсерверный WireGuard. Можно включить прежний профиль на телефоне."
  elif [ "$vless_result" = OK ]; then
    link_install_config "$TRANSPORT_STAGE/vless.json"
    rm -f "$saved"
    echo "Выбран проверенный VLESS + REALITY."
  fi
  echo "Итог на VPS: VLESS + REALITY — $vless_result; WireGuard — $wg_result."
  [ "$wg_result" = OK ]
)

# Installer entry point.
case "$*" in
  --compare-uplinks) link_compare compare; exit $? ;;
  --use-vless) link_compare vless; exit $? ;;
esac
if [ "$#" -eq 0 ]; then
  transport_wizard
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend) BACKEND=${2:-}; shift 2 ;;
    --binary) BINARY=${2:-}; shift 2 ;;
    --sha256) SHA256=${2:-}; shift 2 ;;
    --release-dir) RELEASE_DIR=${2:-}; shift 2 ;;
    --port) PORT=${2:-}; shift 2 ;;
    --subnet) SUBNET=${2:-}; SUBNET_SET=1; shift 2 ;;
    --data) DATA_DIR=${2:-}; shift 2 ;;
    --role) ROLE=${2:-}; shift 2 ;;
    --uplink) UPLINK_FILE=${2:-}; shift 2 ;;
    --public-address) PUBLIC_ADDRESS=${2:-}; shift 2 ;;
    --server-name) SERVER_NAME=${2:-}; shift 2 ;;
    --transport-port) TRANSPORT_PORT=${2:-}; shift 2 ;;
    -h|--help) transport_usage; exit 0 ;;
    --self-check) MODE="self-check"; shift ;;
    --preflight) MODE="preflight"; shift ;;
    --check) MODE="check"; shift ;;
    --normalize) MODE="normalize"; shift ;;
    --update) MODE="update"; shift ;;
    --describe-wg) MODE="describe-wg"; WG_FILE=${2:-}; shift 2 ;;
    --plan-wg) MODE="plan-wg"; WG_FILE=${2:-}; shift 2 ;;
    *) die "unknown argument" ;;
  esac
done

case "$ROLE" in direct|entry|exit) ;; *) die "role must be direct, entry or exit" ;; esac
if [ "$ROLE" != "direct" ]; then
  transport_validate
  if [ "$MODE" = "preflight" ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root"
    assert_ubuntu_2404
    echo "family-vpn-install: $ROLE parameters valid; network reachability is not tested by --preflight"
    exit 0
  fi
  if [ "$ROLE" = "exit" ]; then
    install_transport
    if [ "$WIZARD_MODE" -eq 1 ]; then
      echo ""
      echo "Зарубежный сервер настроен. На российском запустите тот же установщик и выберите 2."
      echo "Скопируйте код ниже и вставьте его в установщик российского сервера:"
      transport_export_code
      echo "Код даёт доступ к вашему выходному серверу. Храните его как VPN-конфигурацию."
    fi
    exit 0
  fi
  if agent_is_paired; then
    [ -f /etc/wireguard/wg0.conf ] || die "paired entry is missing wg0.conf"
    install_transport
    if ! wg show wg0 >/dev/null 2>&1; then
      systemctl enable --now wg-quick@wg0
    fi
    transport_verify_entry
    echo "family-vpn-install: paired entry configured; existing agent identity reused"
    exit 0
  fi
elif [ -n "$UPLINK_FILE$PUBLIC_ADDRESS$SERVER_NAME" ]; then
  die "transport parameters require --role entry or --role exit"
fi

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
if [ "$SUBNET_SET" -eq 1 ]; then
  case "$SUBNET" in
    *.0/24) ;;
    *) die "subnet must be an IPv4 /24, for example 10.200.0.0/24" ;;
  esac
fi

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
  echo "family-vpn-install $AGENT_VERSION checksum ok"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -r /etc/os-release ] || die "cannot detect the operating system"
assert_ubuntu_2404
require_cmd ip

if [ "$MODE" = "update" ]; then
  update_paired_agent
  exit 0
fi

install -d -m 700 "$DATA_DIR"

# Full reinstall is refused when the agent is already paired: use --update instead.
if agent_is_paired; then
  echo "family-vpn-install: agent is already paired; refusing full reinstall" >&2
  echo "family-vpn-install: pairing identity and WireGuard were left unchanged" >&2
  echo "family-vpn-install: run the same command with --update to replace only the agent binary" >&2
  die "already installed; use --update"
fi

backup_wireguard
install -d -m 755 /usr/local/bin
install -m 755 "$BINARY" "$AGENT_BIN"
installed=$(sha256sum "$AGENT_BIN" | awk '{print $1}')
[ "$installed" = "$SHA256" ] || die "installed agent checksum mismatch"

if [ "$(wg_plan /etc/wireguard/wg0.conf)" = "preserve" ]; then
  describe_wg_conf /etc/wireguard/wg0.conf
  echo "family-vpn-install: existing wg0 left unchanged"
  echo "family-vpn-install: server key, peers, listen port, subnet, and network rules were not modified"
  if [ "$ROLE" = "entry" ]; then
    harden_fresh_agent_host
    install_transport
    if ! wg show wg0 >/dev/null 2>&1; then
      systemctl enable --now wg-quick@wg0
    fi
  fi
else
  require_cmd apt-get
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  install_packages wireguard iptables
  iface=$(detect_wan_iface)
  [ -n "$iface" ] || die "could not detect the external network interface from the default route"
  echo "family-vpn-install: WAN iface from default route: $iface"
  if [ "$SUBNET_SET" -eq 0 ] || [ -z "$SUBNET" ]; then
    SUBNET=$(choose_vpn_subnet)
    echo "family-vpn-install: selected VPN subnet $SUBNET (auto-detected; not a fixed template)"
  fi
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
PostUp = iptables -C FORWARD -i wg0 -o wg0 -j DROP || iptables -I FORWARD 1 -i wg0 -o wg0 -j DROP
PostUp = iptables -C FORWARD -i wg0 -o $iface -j ACCEPT || iptables -A FORWARD -i wg0 -o $iface -j ACCEPT
PostUp = iptables -C FORWARD -i $iface -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || iptables -A FORWARD -i $iface -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -o wg0 -j DROP || true
PostDown = iptables -D FORWARD -i wg0 -o $iface -j ACCEPT || true
PostDown = iptables -D FORWARD -i $iface -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -s $network -o $iface -j MASQUERADE || true
EOF
  chmod 600 /etc/wireguard/wg0.conf
  rm -rf "$tmp"
  TMP_KEYS=""
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-family-vpn.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if [ "$ROLE" = "entry" ]; then
    # Keep this subnet/config on a partial install: the persistent policy rule refers to it.
    : > "$DATA_DIR/wg-managed-by-installer"
    # Finish UFW reloads before installing the guard and bringing up new clients.
    harden_fresh_agent_host
    install_transport
  fi
  # The unit starts wg0 now and again after reboot. A separate wg-quick up leaves the unit inactive.
  systemctl daemon-reload
  systemctl enable --now wg-quick@wg0
  systemctl is-enabled --quiet wg-quick@wg0 || die "wg-quick@wg0 is not enabled"
  systemctl is-active --quiet wg-quick@wg0 || die "wg-quick@wg0 is not active"
  : > "$DATA_DIR/wg-managed-by-installer"
  echo "family-vpn-install: new wg0 configured on $iface ($SUBNET)"
  echo "family-vpn-install: wg-quick@wg0 is enabled and will start on boot"
fi

write_agent_unit
systemctl daemon-reload
/usr/local/bin/family-vpn-agent enroll --backend "$BACKEND" --data "$DATA_DIR"
systemctl enable --now family-vpn-agent
# Host firewall/SSH hardening for new installs only (skipped by --update above).
if [ "$ROLE" = "entry" ]; then
  transport_verify_entry
else
  harden_fresh_agent_host
fi
post_install_check
echo "family-vpn-install: agent service is enabled"
echo "family-vpn-install: enter the pairing code in Servers → Add server"
echo "family-vpn-install: local backups under $DATA_DIR/backups are not an offsite DR copy"
