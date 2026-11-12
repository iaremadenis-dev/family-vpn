#!/bin/bash
# Local download and checksum checks. Contacts only 127.0.0.1.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/installer/install-from-panel.sh"
bash -n "$SCRIPT"

if bash "$SCRIPT" --backend 'http://203.0.113.10'; then
  echo "cleartext remote backend was accepted" >&2
  exit 1
fi
if bash "$SCRIPT" --backend 'https://panel.example.com/releases'; then
  echo "backend path was accepted" >&2
  exit 1
fi
if bash "$SCRIPT" --backend 'https://user:secret@panel.example.com'; then
  echo "backend credentials were accepted" >&2
  exit 1
fi

work=$(mktemp -d)
cleanup() {
  if [ -n "${server_pid:-}" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/www/releases" "$work/bin"
log="$work/ran.txt"
cat >"$work/www/releases/install.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$FAMILY_VPN_INSTALL_LOG"
EOF
printf '%s\n' 'family-vpn-agent-linux-amd64' >"$work/www/releases/family-vpn-agent-linux-amd64"
(
  cd "$work/www/releases"
  : >SHA256SUMS
  for file in family-vpn-agent-linux-amd64 install.sh; do
    hash=$(sha256sum "$file" | awk '{ print $1 }')
    printf '%s  %s\n' "$hash" "$file" >>SHA256SUMS
  done
)

python() {
  if command -v python3 >/dev/null 2>&1; then
    command python3 "$@"
  elif command -v python >/dev/null 2>&1; then
    command python "$@"
  else
    echo "python is required" >&2
    exit 1
  fi
}

port=$(python -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python -m http.server "$port" --bind 127.0.0.1 --directory "$work/www" >"$work/http.log" 2>&1 &
server_pid=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:${port}/releases/SHA256SUMS" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
[ "$ready" -eq 1 ] || {
  echo "local release server did not start" >&2
  exit 1
}

FAMILY_VPN_INSTALL_LOG="$log" bash "$SCRIPT" --backend "http://127.0.0.1:${port}"
grep -q -- "--backend http://127.0.0.1:${port}" "$log"

printf '\n' >>"$work/www/releases/install.sh"
if FAMILY_VPN_INSTALL_LOG="$log" bash "$SCRIPT" --backend "http://127.0.0.1:${port}"; then
  echo "tampered install.sh was accepted" >&2
  exit 1
fi
rm -f "$log"
curl -fsSL "http://127.0.0.1:${port}/releases/install.sh" -o "$work/downloaded.sh"
got=$(sha256sum "$work/downloaded.sh" | awk '{ print $1 }')
want=$(awk '$2 == "install.sh" { print $1; exit }' "$work/www/releases/SHA256SUMS")
[ "$got" != "$want" ]

echo "install-from-panel checks ok"
