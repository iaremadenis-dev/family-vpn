#!/bin/bash
# Imports a SQLite export into the Docker panel volume.
# Usage: sudo ./scripts/import-panel-data.sh ./export-YYYYMMDDTHHMMSS
set -euo pipefail

EXPORT_DIR=${1:-}
COMPOSE_DIR=${COMPOSE_DIR:-deploy}
VOLUME_NAME=${VOLUME_NAME:-family-vpn_panel-data}

[ -n "$EXPORT_DIR" ] || {
  echo "usage: $0 /path/to/export-dir" >&2
  exit 2
}
[ -f "$EXPORT_DIR/family-vpn.sqlite" ] || {
  echo "family-vpn.sqlite not found in export" >&2
  exit 1
}
if [ -f "$EXPORT_DIR/family-vpn.sqlite.sha256" ]; then
  (cd "$EXPORT_DIR" && sha256sum -c family-vpn.sqlite.sha256)
fi

if docker compose version >/dev/null 2>&1; then
  (cd "$COMPOSE_DIR" && docker compose stop panel || true)
elif command -v docker-compose >/dev/null; then
  (cd "$COMPOSE_DIR" && docker-compose stop panel || true)
fi

docker volume create "$VOLUME_NAME" >/dev/null
docker run --rm \
  -v "$VOLUME_NAME:/data" \
  -v "$(cd "$EXPORT_DIR" && pwd):/import:ro" \
  alpine:3.20 \
  sh -c 'mkdir -p /data && install -m 600 /import/family-vpn.sqlite /data/family-vpn.sqlite && if [ -f /import/family-vpn.sqlite-wal ]; then install -m 600 /import/family-vpn.sqlite-wal /data/family-vpn.sqlite-wal; fi && if [ -f /import/family-vpn.sqlite-shm ]; then install -m 600 /import/family-vpn.sqlite-shm /data/family-vpn.sqlite-shm; fi && chown -R 1001:1001 /data'

echo "import complete; start the stack with: cd $COMPOSE_DIR && docker compose up -d"
