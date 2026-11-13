#!/bin/bash
# Verifies clean-install artifacts from the published 0.4.1 release.
# Does not touch DE-01/NL-01. Nested compose/HTTPS/ACME are NOT claimed here.
set -euo pipefail

TAG=${FAMILY_VPN_RELEASE_TAG:-family-vpn-0.4.1-33876b1}
BASE=${FAMILY_VPN_RELEASE_BASE:-https://github.com/iaremadenis-dev/family-vpn-releases/releases/download/$TAG}
SHORT=33876b1
EXPECTED_DIGEST=${FAMILY_VPN_PANEL_DIGEST:-sha256:39a8844d35e703c769ecc3a16357a6a658dd883c66bdcd41fc70019ceff3fc16}
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

die() { printf 'clean-install-test: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

note "DOWNLOAD_OK base=$BASE"
curl -fsSL "$BASE/SHA256SUMS" -o SHA256SUMS
curl -fsSL "$BASE/family-vpn-panel-image-${SHORT}.tar" -o "family-vpn-panel-image-${SHORT}.tar"
curl -fsSL "$BASE/family-vpn-install-${SHORT}.tar.gz" -o "family-vpn-install-${SHORT}.tar.gz"
curl -fsSL "$BASE/family-vpn-agent-linux-amd64" -o family-vpn-agent-linux-amd64
curl -fsSL "$BASE/install.sh" -o install.sh
sha256sum -c SHA256SUMS
note "SHA256_OK"

chmod +x family-vpn-agent-linux-amd64 install.sh
VERSION=$(./family-vpn-agent-linux-amd64 --version)
[ "$VERSION" = "0.4.1" ] || die "agent version want 0.4.1 got $VERSION"
[ "$(./family-vpn-agent-linux-amd64 version)" = "0.4.1" ] || die "agent version alias mismatch"
grep -E '^AGENT_VERSION="0\.4\.1"' install.sh >/dev/null || die "install.sh AGENT_VERSION not 0.4.1"
if grep -E '0\.5\.0' install.sh family-vpn-agent-linux-amd64 >/dev/null 2>&1; then
  # Binary may contain unrelated byte sequences; check install.sh label only for 0.5.0.
  :
fi
grep -E '0\.5\.0' install.sh >/dev/null && die "install.sh references 0.5.0"
note "AGENT_VERSION_OK 0.4.1"

tar -xzf "family-vpn-install-${SHORT}.tar.gz"
PACK=$WORKDIR/family-vpn-install
test -f "$PACK/install-family-vpn.sh"
test -f "$PACK/panel/install-panel.sh"
grep -q 'SCHEMA_MAX = 4' "$PACK/panel/archive-tool.mjs"
grep -q "$EXPECTED_DIGEST" "$PACK/install-family-vpn.sh"
grep -q 'FAMILY_VPN_PANEL_IMAGE' "$PACK/panel/docker-compose.image.yml"
! test -e "$PACK/Dockerfile"
! test -e "$PACK/app"
! test -e "$PACK/package.json"
if find "$PACK" -type f \( -name '*.sqlite' -o -name 'master.key' -o -name 'agent.json' -o -name 'panel.env' \) | grep -q .; then
  die "secrets in install pack"
fi
note "INSTALL_PACK_OK schema_max=4 image_digest_pinned=1"

# Panel --new dry-run (no Docker/public IP required).
command -v age-keygen >/dev/null 2>&1 || die "age-keygen required for panel dry-run"
age-keygen -o "$WORKDIR/age.txt" >/dev/null
PUB=$(age-keygen -y "$WORKDIR/age.txt" | tr -d '\r\n')
[[ "$PUB" =~ ^age1[0-9a-z]+$ ]] || die "invalid age pubkey from age-keygen"
bash "$PACK/panel/install-panel.sh" --new --email admin@example.com --backup-pubkey "$PUB" --ip 203.0.113.50 --dry-run \
  | tee "$WORKDIR/panel-dry.txt"
grep -q 'DRY_RUN_OK' "$WORKDIR/panel-dry.txt"
grep -q 'SQLite и master.key' "$WORKDIR/panel-dry.txt"
note "PANEL_NEW_DRY_RUN_OK"

# Re-run refuse: existing DB must not be wiped.
mkdir -p "$WORKDIR/state"
printf 'x' >"$WORKDIR/state/family-vpn.sqlite"
printf 'y' >"$WORKDIR/state/master.key"
set +e
FAMILY_VPN_PANEL_DIR="$WORKDIR/state" bash "$PACK/panel/install-panel.sh" --new --email admin@example.com --backup-pubkey "$PUB" --ip 203.0.113.50 --dry-run >"$WORKDIR/refuse.out" 2>"$WORKDIR/refuse.err"
refuse_code=$?
set -e
[ "$refuse_code" -eq 3 ] || die "expected exit 3 on existing sqlite, got $refuse_code"
grep -q 'DATA_EXISTS' "$WORKDIR/refuse.out" "$WORKDIR/refuse.err"
note "PANEL_RERUN_REFUSE_OK"

# Agent installer self-check + checksum mode (no WireGuard changes).
bash install.sh --self-check
bash install.sh --backend https://203.0.113.50 --binary ./family-vpn-agent-linux-amd64 --sha256 "$(sha256sum family-vpn-agent-linux-amd64 | awk '{print $1}')" --check
grep -q -- '--update' install.sh
grep -q 'wg0 untouched' install.sh || grep -q 'does not restart wg0' install.sh
note "AGENT_INSTALLER_OK update_path_present=1 check_ok=1"

# Confirm docker-save image, not source tree.
python3 - <<'PY'
import tarfile
names=set(tarfile.open("family-vpn-panel-image-33876b1.tar").getnames())
assert "manifest.json" in names or any(n.startswith("blobs/") for n in names)
assert "package.json" not in names and "Dockerfile" not in names
print("PANEL_IMAGE_TAR_OK")
PY

note "TLS_NOT_CHECKED needs public IP + Let's Encrypt on a real VPS"
note "COMPOSE_START_NOT_CHECKED nested Docker compose start is unreliable on Actions runners"
note "ENROLL_NOT_CHECKED agent enroll needs a live panel HTTPS origin"
note "RESULT=PASS"
