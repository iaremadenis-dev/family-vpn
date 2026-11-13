#!/usr/bin/env bash
# Read-only verification of the two generated production entrypoints.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
test -f dist/panel.sh
test -f dist/wireguard.sh
test -f dist/panel.sh.sig
test -f dist/wireguard.sh.sig
(cd dist && sha256sum -c panel.sh.sha256 && sha256sum -c wireguard.sh.sha256)
bash -n dist/panel.sh
bash -n dist/wireguard.sh
bash dist/panel.sh --help | grep -Fq -- '--new|--update'
bash dist/wireguard.sh --help | grep -Fq -- '--new|--update'
grep -Fq '/etc/family-vpn/panel.env' dist/panel.sh
grep -Fq '/var/lib/family-vpn/panel/master.key' dist/panel.sh
grep -Fq '/var/lib/family-vpn/agent.json' dist/wireguard.sh
grep -Fq 'sha256sum -c -' dist/panel.sh
grep -Fq 'sha256sum -c -' dist/wireguard.sh
! grep -Eq '__[A-Z_]+__|YOUR@EMAIL|YOURPUBLICKEY' dist/panel.sh dist/wireguard.sh
fp=$(sha256sum keys/release-signing.pub | awk '{print $1}')
for file in panel.sh wireguard.sh; do
  node scripts/verify-release-file.mjs "dist/$file" "dist/$file.sig" keys/release-signing.pub "$fp"
done
echo TWO_INSTALLERS_TEST_OK
