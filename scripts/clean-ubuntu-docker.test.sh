#!/bin/bash
# Runs inside a clean Ubuntu 24.04 where Docker is not installed yet.
# It installs Docker through the panel installer and loads the checked image.
# It does not start the panel, issue a certificate, or open a firewall.
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

printf '%s\n' "CLEAN_HOST: Ubuntu 24.04 x86_64, Docker отсутствует"
export FAMILY_VPN_PANEL_IMAGE=$FAMILY_VPN_PANEL_DIGEST
export FAMILY_VPN_DOCKER_READY_ATTEMPTS=90
export FAMILY_VPN_DOCKER_READY_SLEEP=1
# shellcheck disable=SC1091
source /installer/install-panel.sh
install_packages
docker compose version >/dev/null
systemctl is-active docker >/dev/null
load_verified_image
id=$(docker image inspect --format '{{.Id}}' "$FAMILY_VPN_PANEL_IMAGE")
[ "$id" = "$FAMILY_VPN_PANEL_DIGEST" ]
printf '%s\n' "CLEAN_UBUNTU_DOCKER_OK"
