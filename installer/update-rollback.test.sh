#!/bin/bash
# Sandbox for agent --update. It does not touch /usr/local, /etc, or a VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/installer/install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export FAMILY_VPN_INSTALL_LIB=1
export FAMILY_VPN_WG_CONF="$work/wg0.conf"
export FAMILY_VPN_AGENT_UNIT="$work/agent.service"
# shellcheck disable=SC1090
source "$INSTALL"
trap 'rm -rf "$work"' EXIT

DATA_DIR="$work/data"
AGENT_BIN="$work/bin/family-vpn-agent"
BACKEND="http://127.0.0.1:9"
mkdir -p "$DATA_DIR" "$(dirname "$AGENT_BIN")"

cat > "$WG_CONF" <<'EOF'
[Interface]
PrivateKey = test-private
Address = 10.200.0.1/24
ListenPort = 51820

[Peer]
PublicKey = abcdef
AllowedIPs = 10.200.0.2/32
EOF
printf '%s\n' '{"token":"pairing-token-value","enrollmentId":"keep"}' >"$DATA_DIR/agent.json"
printf '%s\n' 'old-agent-0.4.0' >"$AGENT_BIN"

cat >"$work/new-ok" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --version|version) printf '0.4.1\n' ;;
esac
exit 0
EOF
cat >"$work/new-oldver" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --version|version) printf '0.4.0\n' ;;
esac
exit 0
EOF

install() {
  local dest_dir=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -d) dest_dir=1; shift ;;
      -m|-o|-g) shift 2 ;;
      --) shift; break ;;
      -*) echo "unexpected install flag $1" >&2; return 1 ;;
      *) break ;;
    esac
  done
  if [ "$dest_dir" -eq 1 ]; then
    mkdir -p "$1"
    return 0
  fi
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
}

sys_log="$work/systemctl.log"
restart_log="$work/restarts"
sandbox_pid=$$
if [ ! -d "/proc/$sandbox_pid" ]; then
  echo "SANDBOX_SKIPPED no /proc entry for the rollback process check" >&2
  exit 2
fi

systemctl() {
  printf '%s\n' "$*" >>"$sys_log"
  case "$1" in
    show) printf '%s\n' "$sandbox_pid" ;;
    restart)
      printf 'x\n' >>"$restart_log"
      if [ "${FAIL_RESTART:-}" = "1" ]; then
        local count
        count=$(wc -l <"$restart_log" | tr -d ' ')
        [ "$count" -eq 1 ] && return 1
      fi
      ;;
  esac
  return 0
}

wg_hash() { sha256sum "$WG_CONF" | awk '{print $1}'; }
state_hash() { sha256sum "$DATA_DIR/agent.json" | awk '{print $1}'; }
kept_wg=$(wg_hash)
kept_state=$(state_hash)

reset_agent() {
  printf '%s\n' 'old-agent-0.4.0' >"$AGENT_BIN"
  : >"$sys_log"
  : >"$restart_log"
  FAIL_RESTART=0
}

run_update() {
  local binary=$1 sha=$2
  set +e
  (
    set -euo pipefail
    BINARY=$binary
    SHA256=$sha
    update_paired_agent
  ) >"$work/out" 2>"$work/err"
  update_code=$?
  set -e
}

assert_preserved() {
  [ "$(wg_hash)" = "$kept_wg" ] || {
    echo "wg0.conf changed" >&2
    exit 1
  }
  [ "$(state_hash)" = "$kept_state" ] || {
    echo "agent.json changed" >&2
    exit 1
  }
  grep -q 'AllowedIPs = 10.200.0.2/32' "$WG_CONF"
  if grep -E 'wg-quick|ufw|iptables' "$sys_log"; then
    echo "systemctl log shows a networking change" >&2
    exit 1
  fi
}

reset_agent
ok_sha=$(sha256sum "$work/new-ok" | awk '{print $1}')
run_update "$work/new-ok" "$ok_sha"
[ "$update_code" -eq 0 ] || {
  echo "successful update failed" >&2
  cat "$work/out" "$work/err" >&2
  exit 1
}
[ "$(sha256sum "$AGENT_BIN" | awk '{print $1}')" = "$ok_sha" ]
grep -q 'systemctl stop family-vpn-agent' "$sys_log" || grep -q '^stop family-vpn-agent$' "$sys_log"
grep -q 'restart family-vpn-agent' "$sys_log"
assert_preserved
grep -q 'update to 0.4.1 complete' "$work/out"

reset_agent
run_update "$work/new-ok" "$(printf '0%.0s' {1..64})"
[ "$update_code" -ne 0 ]
grep -q 'old-agent-0.4.0' "$AGENT_BIN"
grep -q 'rolled back' "$work/err"
assert_preserved

reset_agent
bad_sha=$(sha256sum "$work/new-oldver" | awk '{print $1}')
run_update "$work/new-oldver" "$bad_sha"
[ "$update_code" -ne 0 ]
grep -q 'old-agent-0.4.0' "$AGENT_BIN"
grep -q 'rolled back' "$work/err"
assert_preserved

reset_agent
FAIL_RESTART=1
run_update "$work/new-ok" "$ok_sha"
[ "$update_code" -ne 0 ]
grep -q 'old-agent-0.4.0' "$AGENT_BIN"
grep -q 'rolled back' "$work/err"
assert_preserved

echo "agent update rollback checks ok"
