#!/bin/bash
# Starts a clean Ubuntu 24.04 with systemd and runs the installer image path there.
# Exit 2 means this machine could not provide that environment.
# A successful run installs Docker, loads the panel image, pulls Caddy from
# Compose, and verifies image readiness. It does not start the panel stack.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE_TAR=${1:-$ROOT/dist/family-vpn-panel-image.tar}
DIGEST_FILE=${2:-$ROOT/dist/panel-image-id.txt}

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  printf '%s\n' "CLEAN_UBUNTU_UNAVAILABLE: на этой машине нет рабочего Docker. Тест чистой Ubuntu не запускался." >&2
  exit 2
fi
[ -f "$IMAGE_TAR" ] || {
  printf '%s\n' "CLEAN_UBUNTU_UNAVAILABLE: нет $IMAGE_TAR" >&2
  exit 2
}
[ -f "$DIGEST_FILE" ] || {
  printf '%s\n' "CLEAN_UBUNTU_UNAVAILABLE: нет $DIGEST_FILE" >&2
  exit 2
}
DIGEST=$(tr -d '[:space:]' <"$DIGEST_FILE")

releases=$ROOT/releases
if [ ! -d "$releases" ]; then
  releases=$(mktemp -d)
  mkdir -p "$releases"
  : >"$releases/.gitkeep"
fi

name="fvpn-clean-u24-$$"
base="fvpn-ubuntu2404-systemd"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

context=$(mktemp -d)
cat >"$context/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv ca-certificates curl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
docker build --pull -t "$base" "$context"
rm -rf "$context"
docker run --rm --entrypoint test "$base" -x /sbin/init

if ! docker run -d --name "$name" --privileged --cgroupns=host \
  --tmpfs /run:rw,nosuid,nodev,mode=755 \
  --tmpfs /run/lock:rw,nosuid,nodev,noexec,mode=755 \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$ROOT/panel:/opt/family-vpn/panel:ro" \
  -v "$releases:/opt/family-vpn/releases:ro" \
  -v "$ROOT/scripts/clean-ubuntu-docker.test.sh:/installer/clean-ubuntu-docker.test.sh:ro" \
  -v "$IMAGE_TAR:/opt/family-vpn-panel-image.tar:ro" \
  -e FAMILY_VPN_PANEL_DIGEST="$DIGEST" \
  -e FAMILY_VPN_PANEL_IMAGE_TAR=/opt/family-vpn-panel-image.tar \
  -e DEBIAN_FRONTEND=noninteractive \
  "$base"; then
  printf '%s\n' "CLEAN_UBUNTU_UNAVAILABLE: контейнер Ubuntu 24.04 со systemd не запустился." >&2
  docker logs "$name" >&2 || true
  exit 2
fi

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if docker exec "$name" systemctl show -p Version --value >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  printf '%s\n' "CLEAN_UBUNTU_UNAVAILABLE: systemd в контейнере Ubuntu 24.04 не запустился. Полный тест чистой системы не выполнен." >&2
  docker logs "$name" >&2 || true
  exit 2
fi

set +e
output=$(docker exec "$name" bash /installer/clean-ubuntu-docker.test.sh 2>&1)
code=$?
set -e
printf '%s\n' "$output"
if [ "$code" -ne 0 ]; then
  printf '%s\n' "CLEAN_UBUNTU_TEST_FAIL code=$code" >&2
  exit "$code"
fi
printf '%s\n' "$output" | grep -q 'CLEAN_UBUNTU_DOCKER_OK'
printf '%s\n' "$output" | grep -q 'CLEAN_UBUNTU_CADDY_OK'
printf '%s\n' "$output" | grep -q 'CLEAN_UBUNTU_IMAGES_OK'
printf '%s\n' "$output" | grep -q 'CLEAN_UBUNTU_RESUME_OK'
printf '%s\n' "$output" | grep -q 'COMPOSE_NOT_RUN'
printf '%s\n' "$output" | grep -q 'TLS_NOT_CHECKED'
