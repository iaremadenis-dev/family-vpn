#!/bin/bash
# Local checks for the private-repository bootstrap. Does not contact GitHub or a VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/panel/bootstrap-panel.sh"
PUB=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

bash -n "$SCRIPT"
bash "$SCRIPT" --check

if grep -E -- '--with-token|ghp_|github_pat_' "$SCRIPT"; then
  echo "bootstrap contains a GitHub token" >&2
  exit 1
fi
if grep -E 'ControlMaster=auto|ControlPersist=[1-9]' "$SCRIPT"; then
  echo "bootstrap opens an SSH control socket" >&2
  exit 1
fi
grep -q 'auth logout' "$SCRIPT"
grep -q 'rm -rf "${HOME}/.config/gh"' "$SCRIPT"
grep -q 'sha256sum -c' "$SCRIPT"
grep -q 'install-panel.sh' "$SCRIPT"
grep -q 'AGE-SECRET-KEY-' "$SCRIPT"

dry=$(bash "$SCRIPT" --new --email admin@example.com --backup-pubkey "$PUB" --dry-run)
printf '%s\n' "$dry" | grep -q 'BOOTSTRAP_DRY_RUN'
printf '%s\n' "$dry" | grep -q 'VERIFY sha256sum'
printf '%s\n' "$dry" | grep -q 'LOGOUT'
printf '%s\n' "$dry" | grep -q 'RUN install-panel.sh --new'

if bash "$SCRIPT" --new --email admin@example.com --backup-pubkey 'AGE-SECRET-KEY-not-used' --dry-run; then
  echo "private age key was accepted" >&2
  exit 1
fi

if GH_TOKEN=not-a-real-token bash "$SCRIPT" --check; then
  echo "GH_TOKEN was accepted" >&2
  exit 1
fi

archive=$(mktemp)
printf 'not-a-secret\n' >"$archive"
restore=$(bash "$SCRIPT" --restore --archive "$archive" --decrypted --email admin@example.com --backup-pubkey "$PUB" --dry-run)
printf '%s\n' "$restore" | grep -q 'RUN install-panel.sh --restore'
printf '%s\n' "$restore" | grep -q 'ARCHIVE_REQUIRED'
rm -f "$archive"

if bash "$SCRIPT" --restore --decrypted --email admin@example.com --backup-pubkey "$PUB" --dry-run; then
  echo "restore without an archive was accepted" >&2
  exit 1
fi

stdin=$(bash "$SCRIPT" --restore --archive - --decrypted --email admin@example.com --backup-pubkey "$PUB" --dry-run)
printf '%s\n' "$stdin" | grep -q 'ARCHIVE_REQUIRED'

work=$(mktemp -d)
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/src/panel" "$work/bin" "$work/artifact"
cp "$SCRIPT" "$work/src/panel/bootstrap-panel.sh"
cat >"$work/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "run" ] && [ "$2" = "list" ]; then
  printf '%s\n' "${FAMILY_VPN_FAKE_RUN_ID:-}"
  exit 0
fi
if [ "$1" = "run" ] && [ "$2" = "download" ]; then
  dir=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--dir" ]; then
      dir=$arg
    fi
    prev=$arg
  done
  [ -n "$dir" ] || exit 1
  cp -a "${FAMILY_VPN_FAKE_ARTIFACT}/." "$dir/"
  exit 0
fi
printf '%s\n' "unexpected gh: $*" >&2
exit 1
EOF
chmod 755 "$work/bin/gh"

write_artifact() {
  local version=$1
  local dir=$2
  mkdir -p "$dir"
  cat >"$dir/family-vpn-agent-linux-amd64" <<EOF
#!/bin/bash
printf '%s\n' '$version'
EOF
  printf '%s\n' 'install.sh' >"$dir/install.sh"
  printf '%s\n' 'note' >"$dir/INSTALL.txt"
  printf '%s\n' 'boot' >"$dir/bootstrap.sh"
  chmod 755 "$dir/family-vpn-agent-linux-amd64"
  (
    cd "$dir"
    : >SHA256SUMS
    for file in family-vpn-agent-linux-amd64 install.sh; do
      hash=$(sha256sum "$file" | awk '{ print $1 }')
      printf '%s  %s\n' "$hash" "$file" >>SHA256SUMS
    done
  )
}

write_artifact 0.4.0 "$work/artifact"
PATH="$work/bin:$PATH" FAMILY_VPN_FAKE_RUN_ID=42 FAMILY_VPN_FAKE_ARTIFACT="$work/artifact" \
  bash "$work/src/panel/bootstrap-panel.sh" --fetch-only
test -f "$work/src/releases/family-vpn-agent-linux-amd64"
(cd "$work/src/releases" && sha256sum -c SHA256SUMS)
got=$("$work/src/releases/family-vpn-agent-linux-amd64" --version)
[ "$got" = "0.4.0" ]

mkdir -p "$work/src/installer"
cp "$work/artifact/install.sh" "$work/src/installer/install.sh"
rm -rf "$work/src/releases"
PATH="$work/bin:$PATH" FAMILY_VPN_FAKE_RUN_ID=42 FAMILY_VPN_FAKE_ARTIFACT="$work/artifact" \
  bash "$work/src/panel/bootstrap-panel.sh" --fetch-only
test -f "$work/src/releases/install.sh"
printf 'substituted\n' >"$work/src/installer/install.sh"
rm -rf "$work/src/releases"
if PATH="$work/bin:$PATH" FAMILY_VPN_FAKE_RUN_ID=42 FAMILY_VPN_FAKE_ARTIFACT="$work/artifact" \
  bash "$work/src/panel/bootstrap-panel.sh" --fetch-only; then
  echo "substituted install.sh was accepted" >&2
  exit 1
fi
if [ -f "$work/src/releases/install.sh" ]; then
  echo "substituted release files were left in place" >&2
  exit 1
fi
rm -rf "$work/src/installer"

rm -rf "$work/src/releases" "$work/nested"
mkdir -p "$work/nested/inner"
cp -a "$work/artifact/." "$work/nested/inner/"
rm -rf "$work/artifact"
PATH="$work/bin:$PATH" FAMILY_VPN_FAKE_RUN_ID=42 FAMILY_VPN_FAKE_ARTIFACT="$work/nested" \
  bash "$work/src/panel/bootstrap-panel.sh" --fetch-only
[ "$("$work/src/releases/family-vpn-agent-linux-amd64" --version)" = "0.4.0" ]
rm -rf "$work/artifact"
mkdir -p "$work/artifact"
cp -a "$work/nested/inner/." "$work/artifact/"

rm -rf "$work/src/releases"
awk 'NR == 1 { print "0000000000000000000000000000000000000000000000000000000000000000  " $2; next } { print }' \
  "$work/artifact/SHA256SUMS" >"$work/artifact/SHA256SUMS.new"
mv "$work/artifact/SHA256SUMS.new" "$work/artifact/SHA256SUMS"
if PATH="$work/bin:$PATH" FAMILY_VPN_FAKE_RUN_ID=42 FAMILY_VPN_FAKE_ARTIFACT="$work/artifact" \
  bash "$work/src/panel/bootstrap-panel.sh" --fetch-only; then
  echo "broken checksum was accepted" >&2
  exit 1
fi
if [ -f "$work/src/releases/family-vpn-agent-linux-amd64" ]; then
  echo "rejected release files were left in place" >&2
  exit 1
fi

rm -rf "$work/artifact" "$work/src/releases"
write_artifact 9.9.9 "$work/artifact"
if PATH="$work/bin:$PATH" FAMILY_VPN_FAKE_RUN_ID=42 FAMILY_VPN_FAKE_ARTIFACT="$work/artifact" \
  bash "$work/src/panel/bootstrap-panel.sh" --fetch-only; then
  echo "wrong agent version was accepted" >&2
  exit 1
fi
if [ -f "$work/src/releases/family-vpn-agent-linux-amd64" ]; then
  echo "wrong-version release files were left in place" >&2
  exit 1
fi

echo "bootstrap checks ok"
