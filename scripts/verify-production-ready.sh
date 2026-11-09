#!/bin/bash
# Local checks that production artifacts are present and checksums match.
# Does not contact a remote VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

test -f deploy/docker-compose.yml
test -f deploy/Caddyfile
test -f deploy/.env.example
test -f Dockerfile
test -f installer/install.sh
test -f scripts/build-release.sh

bash -n installer/install.sh
bash -n installer/preserve-wg.test.sh
bash -n installer/update-mode.test.sh
bash -n scripts/build-release.sh
bash -n scripts/import-panel-data.sh
bash -n scripts/vps-preflight.sh
bash -n panel/install-panel.sh
bash -n panel/renew-cert.sh
bash panel/install-panel.test.sh
bash installer/preserve-wg.test.sh
bash installer/update-mode.test.sh
bash installer/onboarding.test.sh

if [ -f releases/SHA256SUMS ]; then
  (cd releases && sha256sum -c SHA256SUMS)
  echo "release checksums ok"
else
  echo "releases/ not built yet; run scripts/build-release.sh before panel publish"
fi

echo "production package structure ok"
