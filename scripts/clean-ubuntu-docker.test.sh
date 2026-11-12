#!/bin/bash
# Runs inside a clean Ubuntu 24.04 where Docker is not installed yet.
# Installs Docker through the panel installer, loads the checked panel image,
# pulls Caddy from Compose, and verifies every compose image is present.
# Nested Docker on GitHub Actions cannot reliably start containers
# (overlay-on-overlay). Compose start, HTTPS, and Let's Encrypt are checked
# on a real public VPS.
set -euo pipefail

if command -v docker >/dev/null 2>&1; then
  printf '%s\n' "CLEAN_TEST_INVALID: Docker уже установлен. Это не чистая система." >&2
  exit 2
fi
[ -r /etc/os-release ] || {
  printf '%s\n' "CLEAN_TEST_INVALID: нет /etc/os-release" >&2
  exit 2
}
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ] || {
  printf '%s\n' "CLEAN_TEST_INVALID: нужна Ubuntu 24.04, обнаружено ${PRETTY_NAME:-unknown}" >&2
  exit 2
}
[ "$(uname -m)" = "x86_64" ] || {
  printf '%s\n' "CLEAN_TEST_INVALID: нужна архитектура x86_64, обнаружено $(uname -m)" >&2
  exit 2
}
[ -n "${FAMILY_VPN_PANEL_DIGEST:-}" ] || {
  printf '%s\n' "CLEAN_TEST_INVALID: не задан digest образа" >&2
  exit 2
}
[ -f "${FAMILY_VPN_PANEL_IMAGE_TAR:-}" ] || {
  printf '%s\n' "CLEAN_TEST_INVALID: нет архива образа" >&2
  exit 2
}
[ -f /opt/family-vpn/panel/install-panel.sh ] || {
  printf '%s\n' "CLEAN_TEST_INVALID: нет /opt/family-vpn/panel/install-panel.sh" >&2
  exit 2
}
[ -f /opt/family-vpn/panel/docker-compose.yml ] || {
  printf '%s\n' "CLEAN_TEST_INVALID: нет docker-compose.yml" >&2
  exit 2
}

printf '%s\n' "CLEAN_HOST: Ubuntu 24.04 x86_64, Docker отсутствует"
export FAMILY_VPN_PANEL_IMAGE=$FAMILY_VPN_PANEL_DIGEST
export FAMILY_VPN_PANEL_IP=${FAMILY_VPN_PANEL_IP:-203.0.113.5}
export FAMILY_VPN_DOCKER_READY_ATTEMPTS=90
export FAMILY_VPN_DOCKER_READY_SLEEP=1
export FAMILY_VPN_PULL_ATTEMPTS=5

# shellcheck disable=SC1091
source /opt/family-vpn/panel/install-panel.sh
PANEL_IP=$FAMILY_VPN_PANEL_IP

install_packages
docker compose version >/dev/null
systemctl is-active docker >/dev/null
load_verified_image
id=$(docker image inspect --format '{{.Id}}' "$FAMILY_VPN_PANEL_IMAGE")
[ "$id" = "$FAMILY_VPN_PANEL_DIGEST" ]

install -d -m 755 /var/lib/family-vpn /etc/family-vpn /opt/family-vpn/bin
install -d -m 700 -o 1001 -g 1001 "$STATE_DIR"
install -d -m 755 "$ACME_DIR"
install -d -m 700 "$CERT_DIR"
write_env
render_caddy "$PANEL_DIR/Caddyfile.bootstrap"

if docker image inspect caddy:2.10-alpine >/dev/null 2>&1; then
  printf '%s\n' "CLEAN_TEST_INVALID: образ Caddy уже был на чистой системе" >&2
  exit 2
fi

pull_public_compose_images
docker image inspect caddy:2.10-alpine >/dev/null
ensure_runtime_images_ready

# Resume after a simulated interruption: Caddy missing again, panel kept.
docker rmi caddy:2.10-alpine >/dev/null
if docker image inspect caddy:2.10-alpine >/dev/null 2>&1; then
  die "не удалось убрать образ Caddy для проверки продолжения"
fi
docker image inspect "$FAMILY_VPN_PANEL_IMAGE" >/dev/null
pull_public_compose_images
ensure_runtime_images_ready
docker image inspect caddy:2.10-alpine >/dev/null

printf '%s\n' "CLEAN_UBUNTU_DOCKER_OK"
printf '%s\n' "CLEAN_UBUNTU_CADDY_OK"
printf '%s\n' "CLEAN_UBUNTU_IMAGES_OK"
printf '%s\n' "CLEAN_UBUNTU_RESUME_OK"
printf '%s\n' "COMPOSE_NOT_RUN: nested Docker на этом runner не поднимает контейнеры надёжно. Запуск compose, HTTPS и Let's Encrypt проверяются на реальном VPS."
printf '%s\n' "TLS_NOT_CHECKED: нужен реальный публичный IP. Этот этап проверяется на чистом VPS."
