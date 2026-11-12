#!/bin/bash
# Proves the panel installer installs Docker and Compose before it loads an image.
# The commands are stubs. This does not install packages and does not start a VPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL="$ROOT/panel/install-panel.sh"
ORIG_PATH=$PATH
DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WRONG=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

bash -n "$INSTALL"

body_of() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { printing = 1; next }
    printing && /^}/ { exit }
    printing { print }
  ' "$INSTALL"
}

require_order() {
  local fn=$1
  shift
  local body prev=0 line needle
  body=$(body_of "$fn")
  [ -n "$body" ] || {
    printf '%s\n' "missing function $fn" >&2
    exit 1
  }
  for needle in "$@"; do
    line=$(printf '%s\n' "$body" | grep -n -F "$needle" | head -n 1 | cut -d: -f1)
    [ -n "$line" ] || {
      printf '%s\n' "$fn does not contain: $needle" >&2
      exit 1
    }
    [ "$line" -gt "$prev" ] || {
      printf '%s\n' "$fn: out of order: $needle" >&2
      exit 1
    }
    prev=$line
  done
}

require_order prepare_host \
  "Ubuntu 24.04" \
  "x86_64" \
  "iproute2" \
  "require_ports_available"
require_order ensure_docker \
  "docker.io" \
  "docker-compose-v2" \
  "systemctl enable --now docker" \
  "docker info" \
  "Docker daemon готов"
require_order load_verified_image \
  "ensure_docker" \
  "docker image inspect" \
  "docker load" \
  "docker_pull_with_retry"
last=$(body_of load_verified_image | awk 'NF { line = $0 } END { print line }')
printf '%s\n' "$last" | grep -q 'verify_panel_image'
require_order start_https \
  "install_packages" \
  "load_verified_image" \
  "install_certbot" \
  "Caddyfile.bootstrap" \
  "pull_public_compose_images" \
  "ensure_runtime_images_ready" \
  "compose up -d --no-build --pull never" \
  "issue_certificate" \
  "Caddyfile.https" \
  "install_renewal" \
  "install_backup" \
  'https://${PANEL_IP}/login' \
  "confirm_stack"
require_order pull_public_compose_images \
  "ensure_docker" \
  "compose_image_list" \
  "caddy:" \
  "is_panel_runtime_image" \
  "docker image inspect" \
  "docker_pull_with_retry"
require_order ensure_runtime_images_ready \
  "docker image inspect" \
  "compose_image_list" \
  "verify_panel_image" \
  "все образы Docker Compose готовы"
require_order cmd_new \
  "refuse_existing_data" \
  "prepare_host" \
  "install_packages" \
  "load_verified_image" \
  "issue_setup_token" \
  "start_https" \
  "show_installed"

new_case() {
  CASE=$(mktemp -d)
  MOCK_LOG=$CASE/calls.log
  MOCK_BIN=$CASE/bin
  MOCK_STATE=$CASE/state
  TAR=$CASE/image.tar
  mkdir -p "$MOCK_BIN" "$MOCK_STATE"
  : >"$MOCK_LOG"
  printf '%s\n' "image archive" >"$TAR"
  local tool src
  for tool in bash grep awk sed cat cp chmod rm mkdir sleep date id uname ln touch head cut tr sort find dirname; do
    src=$(PATH="$ORIG_PATH" command -v "$tool" || true)
    [ -n "$src" ] || continue
    printf '#!/bin/bash\nexec %q "$@"\n' "$src" >"$MOCK_BIN/$tool"
    chmod 755 "$MOCK_BIN/$tool"
  done
  cat >"$CASE/docker-stub" <<'EOF'
#!/bin/bash
printf 'DOCKER %s\n' "$*" >>"$MOCK_LOG"
if [ "$1" = "info" ]; then
  [ -f "$MOCK_STATE/daemon" ] || exit 1
  exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then
  [ -f "$MOCK_STATE/compose" ] || exit 1
  exit 0
fi
if [ "$1" = "compose" ]; then
  [ -f "$MOCK_STATE/compose" ] || exit 1
  if printf '%s\n' "$*" | grep -q -- '--images'; then
    printf '%s\n' "${FAMILY_VPN_PANEL_IMAGE:-}"
    printf '%s\n' "caddy:2.10-alpine"
    exit 0
  fi
  exit 0
fi
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  target=${*: -1}
  if [ "$target" = "caddy:2.10-alpine" ]; then
    [ -f "$MOCK_STATE/caddy" ] || exit 1
    exit 0
  fi
  [ -f "$MOCK_STATE/loaded" ] || exit 1
  format=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--format" ]; then
      format=$arg
    fi
    prev=$arg
  done
  case "$format" in
    *'.Id'*) cat "$MOCK_STATE/image-id" ;;
    *RepoDigests*) printf '\n' ;;
    "") exit 0 ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [ "$1" = "load" ]; then
  if [ -f "$MOCK_STATE/load-fail" ]; then
    rm -f "$MOCK_STATE/load-fail"
    exit 1
  fi
  printf '%s\n' "$FAMILY_VPN_PANEL_DIGEST" >"$MOCK_STATE/image-id"
  : >"$MOCK_STATE/loaded"
  exit 0
fi
if [ "$1" = "pull" ]; then
  if [ "$2" = "caddy:2.10-alpine" ]; then
    if [ -f "$MOCK_STATE/caddy-pull-fail" ]; then
      fails=$(cat "$MOCK_STATE/caddy-pull-fail")
      if [ "$fails" -gt 0 ]; then
        printf '%s\n' "$((fails - 1))" >"$MOCK_STATE/caddy-pull-fail"
        exit 1
      fi
      rm -f "$MOCK_STATE/caddy-pull-fail"
    fi
    : >"$MOCK_STATE/caddy"
    exit 0
  fi
  printf '%s\n' "$FAMILY_VPN_PANEL_DIGEST" >"$MOCK_STATE/image-id"
  : >"$MOCK_STATE/loaded"
  exit 0
fi
printf 'unexpected docker: %s\n' "$*" >&2
exit 1
EOF
  chmod 755 "$CASE/docker-stub"
  cat >"$MOCK_BIN/apt-get" <<'EOF'
#!/bin/bash
printf 'APT %s\n' "$*" >>"$MOCK_LOG"
if printf '%s\n' "$*" | grep -q 'docker.io'; then
  [ ! -f "$MOCK_STATE/apt-docker-fail" ] || exit 1
  cp "$MOCK_DOCKER_STUB" "$MOCK_BIN/docker"
  chmod 755 "$MOCK_BIN/docker"
fi
if printf '%s\n' "$*" | grep -q 'docker-compose-v2'; then
  [ ! -f "$MOCK_STATE/apt-compose-fail" ] || exit 1
  : >"$MOCK_STATE/compose"
fi
exit 0
EOF
  cat >"$MOCK_BIN/systemctl" <<'EOF'
#!/bin/bash
printf 'SYSTEMCTL %s\n' "$*" >>"$MOCK_LOG"
[ ! -f "$MOCK_STATE/systemctl-fail" ] || exit 1
if [ "$1" = "enable" ] && [ ! -f "$MOCK_STATE/no-daemon" ]; then
  : >"$MOCK_STATE/daemon"
fi
exit 0
EOF
  chmod 755 "$MOCK_BIN/apt-get" "$MOCK_BIN/systemctl"
  export MOCK_LOG MOCK_BIN MOCK_STATE
  export MOCK_DOCKER_STUB=$CASE/docker-stub
}

run_fn() {
  local fn=$1
  set +e
  (
    set -euo pipefail
    export PATH="$MOCK_BIN"
    export MOCK_LOG MOCK_BIN MOCK_STATE MOCK_DOCKER_STUB
    export FAMILY_VPN_PANEL_IMAGE
    export FAMILY_VPN_PANEL_DIGEST=$DIGEST
    export FAMILY_VPN_PANEL_IMAGE_TAR=$TAR
    export FAMILY_VPN_DOCKER_READY_ATTEMPTS=${FAMILY_VPN_DOCKER_READY_ATTEMPTS:-5}
    export FAMILY_VPN_DOCKER_READY_SLEEP=0
    # shellcheck disable=SC1090
    source "$INSTALL"
    "$fn"
  ) >"$CASE/stdout" 2>"$CASE/stderr"
  RUN_CODE=$?
  set -e
}

show_failure() {
  printf '%s\n' "--- stdout ---" >&2
  cat "$CASE/stdout" >&2 || true
  printf '%s\n' "--- stderr ---" >&2
  cat "$CASE/stderr" >&2 || true
  printf '%s\n' "--- calls ---" >&2
  cat "$MOCK_LOG" >&2 || true
}

expect_ok() {
  run_fn "$1"
  if [ "$RUN_CODE" -ne 0 ]; then
    printf '%s\n' "expected success from $1" >&2
    show_failure
    exit 1
  fi
}

expect_fail() {
  local fn=$1 needle=$2
  run_fn "$fn"
  if [ "$RUN_CODE" -eq 0 ]; then
    printf '%s\n' "expected failure from $fn" >&2
    show_failure
    exit 1
  fi
  grep -q "$needle" "$CASE/stderr" || {
    printf '%s\n' "failure from $fn did not mention: $needle" >&2
    show_failure
    exit 1
  }
}

line_of() {
  grep -n -F "$1" "$MOCK_LOG" | head -n 1 | cut -d: -f1
}

before() {
  local left right
  left=$(line_of "$1")
  right=$(line_of "$2")
  [ -n "$left" ] && [ -n "$right" ] && [ "$left" -lt "$right" ] || {
    printf '%s\n' "expected '$1' before '$2'" >&2
    show_failure
    exit 1
  }
}

count_of() {
  grep -c -F "$1" "$MOCK_LOG" || true
}

# Clean system: neither Docker nor Compose exists.
new_case
FAMILY_VPN_PANEL_IMAGE=$DIGEST
expect_ok load_verified_image
before "APT install -y docker.io" "DOCKER "
before "APT install -y docker-compose-v2" "DOCKER load "
before "SYSTEMCTL enable --now docker" "DOCKER load "
before "DOCKER info" "DOCKER load "
grep -q "Docker Engine не установлен" "$CASE/stdout"
grep -q "Docker Compose не установлен" "$CASE/stdout"
grep -q "Docker daemon готов" "$CASE/stdout"
grep -q "Загружаю проверенный образ панели" "$CASE/stdout"
grep -q "образ панели подтверждён" "$CASE/stdout"
[ "$(count_of "DOCKER load ")" -eq 1 ]

# The same command continues after the image is already loaded.
expect_ok load_verified_image
[ "$(count_of "DOCKER load ")" -eq 1 ]
grep -q "Docker Engine уже установлен" "$CASE/stdout"

# Docker is present, Compose is not.
new_case
cp "$CASE/docker-stub" "$MOCK_BIN/docker"
chmod 755 "$MOCK_BIN/docker"
FAMILY_VPN_PANEL_IMAGE=$DIGEST
expect_ok load_verified_image
if grep -q 'docker.io' "$MOCK_LOG"; then
  printf '%s\n' "Docker Engine was installed again although it was already present" >&2
  show_failure
  exit 1
fi
grep -q 'docker-compose-v2' "$MOCK_LOG"
before "APT install -y docker-compose-v2" "DOCKER load "
grep -q "Docker Compose не установлен" "$CASE/stdout"

# Package installation is safe to repeat.
new_case
FAMILY_VPN_PANEL_IMAGE=
expect_ok install_packages
expect_ok install_packages
[ "$(count_of "docker.io")" -eq 1 ]
[ "$(count_of "docker-compose-v2")" -eq 1 ]
grep -q "Устанавливаю системные пакеты" "$CASE/stdout"
grep -q "Docker Engine уже установлен" "$CASE/stdout"
grep -q "Docker Compose уже установлен" "$CASE/stdout"

# A failed package install stops before any Docker command.
new_case
: >"$MOCK_STATE/apt-docker-fail"
FAMILY_VPN_PANEL_IMAGE=$DIGEST
expect_fail load_verified_image "не удалось установить Docker Engine"
if grep -q '^DOCKER ' "$MOCK_LOG"; then
  printf '%s\n' "docker ran before Docker Engine was installed" >&2
  show_failure
  exit 1
fi

# A daemon that does not answer stops with a clear error.
new_case
: >"$MOCK_STATE/no-daemon"
FAMILY_VPN_PANEL_IMAGE=$DIGEST
FAMILY_VPN_DOCKER_READY_ATTEMPTS=2
expect_fail load_verified_image "daemon не ответил"
if grep -q 'DOCKER load ' "$MOCK_LOG"; then
  printf '%s\n' "image load ran before the daemon was ready" >&2
  show_failure
  exit 1
fi
FAMILY_VPN_DOCKER_READY_ATTEMPTS=5

# Missing image archive.
new_case
TAR=$CASE/missing.tar
FAMILY_VPN_PANEL_IMAGE=$DIGEST
expect_fail load_verified_image "не найден проверенный архив образа"

# First load fails, the next run continues and loads the checked archive.
new_case
: >"$MOCK_STATE/load-fail"
FAMILY_VPN_PANEL_IMAGE=$DIGEST
expect_fail load_verified_image "не удалось загрузить проверенный архив образа"
expect_ok load_verified_image
grep -q "образ панели подтверждён" "$CASE/stdout"
[ "$(count_of "DOCKER load ")" -eq 2 ]

# Wrong image id is rejected.
new_case
: >"$MOCK_STATE/daemon"
: >"$MOCK_STATE/compose"
: >"$MOCK_STATE/loaded"
printf '%s\n' "$WRONG" >"$MOCK_STATE/image-id"
cp "$CASE/docker-stub" "$MOCK_BIN/docker"
chmod 755 "$MOCK_BIN/docker"
FAMILY_VPN_PANEL_IMAGE=$DIGEST
expect_fail load_verified_image "DIGEST_MISMATCH"
if grep -q 'DOCKER load ' "$MOCK_LOG"; then
  printf '%s\n' "a mismatched image was loaded again" >&2
  show_failure
  exit 1
fi

# A registry reference is pulled only after Docker is installed.
new_case
TAR=$CASE/missing.tar
FAMILY_VPN_PANEL_IMAGE="ghcr.io/example/family-vpn-panel@${DIGEST}"
expect_ok load_verified_image
before "APT install -y docker.io" "DOCKER pull "
grep -q "Скачиваю образ панели" "$CASE/stdout"

# Public compose images, including Caddy, are pulled after Docker is ready.
# The panel image is never pulled from a registry by this step.
new_case
mkdir -p "$CASE/etc"
printf 'NODE_ENV=production\n' >"$CASE/etc/panel.env"
cp "$CASE/docker-stub" "$MOCK_BIN/docker"
chmod 755 "$MOCK_BIN/docker"
: >"$MOCK_STATE/daemon"
: >"$MOCK_STATE/compose"
: >"$MOCK_STATE/loaded"
printf '%s\n' "$DIGEST" >"$MOCK_STATE/image-id"
FAMILY_VPN_PANEL_IMAGE=$DIGEST
FAMILY_VPN_PULL_ATTEMPTS=3
FAMILY_VPN_DOCKER_READY_SLEEP=0
set +e
(
  set -euo pipefail
  export PATH="$MOCK_BIN"
  export MOCK_LOG MOCK_BIN MOCK_STATE MOCK_DOCKER_STUB
  export FAMILY_VPN_PANEL_IMAGE=$DIGEST
  export FAMILY_VPN_PANEL_DIGEST=$DIGEST
  export FAMILY_VPN_PANEL_IMAGE_TAR=$TAR
  export FAMILY_VPN_PULL_ATTEMPTS=3
  export FAMILY_VPN_DOCKER_READY_ATTEMPTS=5
  export FAMILY_VPN_DOCKER_READY_SLEEP=0
  # shellcheck disable=SC1090
  source "$INSTALL"
  ETC_DIR="$CASE/etc"
  ENV_FILE="$CASE/etc/panel.env"
  PANEL_DIR="$ROOT/panel"
  COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
  pull_public_compose_images
  ensure_runtime_images_ready
) >"$CASE/stdout" 2>"$CASE/stderr"
RUN_CODE=$?
set -e
[ "$RUN_CODE" -eq 0 ] || {
  printf '%s\n' "pull_public_compose_images failed" >&2
  show_failure
  exit 1
}
grep -q "Загружаю образ caddy:2.10-alpine" "$CASE/stdout"
grep -q "образ панели берётся из проверенного архива" "$CASE/stdout"
grep -q "все образы Docker Compose готовы" "$CASE/stdout"
if grep -q "DOCKER pull $DIGEST" "$MOCK_LOG" || grep -q "DOCKER pull sha256:" "$MOCK_LOG"; then
  printf '%s\n' "panel image was pulled from a registry" >&2
  show_failure
  exit 1
fi
grep -q "DOCKER pull caddy:2.10-alpine" "$MOCK_LOG"

# Temporary pull failures are retried.
new_case
mkdir -p "$CASE/etc"
printf 'NODE_ENV=production\n' >"$CASE/etc/panel.env"
cp "$CASE/docker-stub" "$MOCK_BIN/docker"
chmod 755 "$MOCK_BIN/docker"
: >"$MOCK_STATE/daemon"
: >"$MOCK_STATE/compose"
: >"$MOCK_STATE/loaded"
printf '%s\n' "$DIGEST" >"$MOCK_STATE/image-id"
printf '1\n' >"$MOCK_STATE/caddy-pull-fail"
FAMILY_VPN_PANEL_IMAGE=$DIGEST
set +e
(
  set -euo pipefail
  export PATH="$MOCK_BIN"
  export MOCK_LOG MOCK_BIN MOCK_STATE MOCK_DOCKER_STUB
  export FAMILY_VPN_PANEL_IMAGE=$DIGEST
  export FAMILY_VPN_PANEL_DIGEST=$DIGEST
  export FAMILY_VPN_PULL_ATTEMPTS=3
  export FAMILY_VPN_DOCKER_READY_ATTEMPTS=5
  export FAMILY_VPN_DOCKER_READY_SLEEP=0
  # shellcheck disable=SC1090
  source "$INSTALL"
  ETC_DIR="$CASE/etc"
  ENV_FILE="$CASE/etc/panel.env"
  PANEL_DIR="$ROOT/panel"
  COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
  pull_public_compose_images
) >"$CASE/stdout" 2>"$CASE/stderr"
RUN_CODE=$?
set -e
[ "$RUN_CODE" -eq 0 ] || {
  printf '%s\n' "caddy pull retry failed" >&2
  show_failure
  exit 1
}
[ "$(count_of "DOCKER pull caddy:2.10-alpine")" -eq 2 ]
grep -q "повторная загрузка образа caddy:2.10-alpine" "$CASE/stdout"
test -f "$MOCK_STATE/caddy"

# Missing Caddy image is refused before compose up.
new_case
mkdir -p "$CASE/etc"
printf 'NODE_ENV=production\n' >"$CASE/etc/panel.env"
cp "$CASE/docker-stub" "$MOCK_BIN/docker"
chmod 755 "$MOCK_BIN/docker"
: >"$MOCK_STATE/daemon"
: >"$MOCK_STATE/compose"
: >"$MOCK_STATE/loaded"
printf '%s\n' "$DIGEST" >"$MOCK_STATE/image-id"
FAMILY_VPN_PANEL_IMAGE=$DIGEST
set +e
(
  set -euo pipefail
  export PATH="$MOCK_BIN"
  export MOCK_LOG MOCK_BIN MOCK_STATE MOCK_DOCKER_STUB
  export FAMILY_VPN_PANEL_IMAGE=$DIGEST
  export FAMILY_VPN_PANEL_DIGEST=$DIGEST
  export FAMILY_VPN_PULL_ATTEMPTS=1
  export FAMILY_VPN_DOCKER_READY_ATTEMPTS=5
  export FAMILY_VPN_DOCKER_READY_SLEEP=0
  # shellcheck disable=SC1090
  source "$INSTALL"
  ETC_DIR="$CASE/etc"
  ENV_FILE="$CASE/etc/panel.env"
  PANEL_DIR="$ROOT/panel"
  COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
  ensure_runtime_images_ready
) >"$CASE/stdout" 2>"$CASE/stderr"
RUN_CODE=$?
set -e
[ "$RUN_CODE" -ne 0 ]
grep -q "образ не доступен перед запуском: caddy:2.10-alpine" "$CASE/stderr"

printf '%s\n' "docker bootstrap order ok"
