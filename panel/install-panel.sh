#!/bin/bash
# Install a new Family VPN panel on Ubuntu 24.04.
# HTTPS is a Let's Encrypt certificate for the public IPv4 (shortlived, 160 hours).
# The script does not stop WireGuard, edit wg0.conf, or rewrite the firewall.
# --restore - --decrypted reads a tar already decrypted on the administrator's computer.
# --restore <archive> --identity remains available and then deletes that key copy.
set -euo pipefail
umask 077

SCRIPT_PATH=${BASH_SOURCE[0]:-$0}
APP_DIR=$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)
PANEL_DIR="$APP_DIR/panel"
STATE_DIR=${FAMILY_VPN_PANEL_DIR:-/var/lib/family-vpn/panel}
CERT_DIR=/var/lib/family-vpn/certs
ACME_DIR=/var/lib/family-vpn/acme
ETC_DIR=/etc/family-vpn
BIN_DIR=/opt/family-vpn/bin
CERTBOT=${FAMILY_VPN_CERTBOT:-/opt/family-vpn/certbot/bin/certbot}
ENV_FILE=${FAMILY_VPN_PANEL_ENV:-$ETC_DIR/panel.env}
PREUPDATE_DIR=${FAMILY_VPN_PREUPDATE_DIR:-/var/lib/family-vpn/backups/panel-pre-update}
CADDYFILE="$ETC_DIR/Caddyfile"
COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
LOG_FILE=/var/log/family-vpn-install.log

MODE=""
ACTIVATION_CODE=""
PANEL_IP=${FAMILY_VPN_PANEL_IP:-}
EMAIL=""
STAGING=0
DRY_RUN=0
DECRYPTED=0
BACKUP_PUBKEY=""
BACKUP_PUBKEY_FILE=""
IDENTITY=""
AGE_KEYGEN=${FAMILY_VPN_AGE_KEYGEN:-age-keygen}
NODE=${FAMILY_VPN_NODE:-node}
if [ -n "${FAMILY_VPN_PYTHON:-}" ]; then
  PYTHON=$FAMILY_VPN_PYTHON
elif command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
else
  PYTHON=python
fi

die() {
  echo "family-vpn-panel: $*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
  if [ -w "$(dirname "$LOG_FILE")" ] && [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -eq 0 ]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
}

usage() {
  cat <<'EOF'
usage:
  install-panel.sh --new --email admin@example.com --backup-pubkey age1... [--ip A.B.C.D] [--staging] [--dry-run]
  install-panel.sh --update [--dry-run]
  install-panel.sh --rollback [--dry-run]
  install-panel.sh --restore - --decrypted --backup-pubkey age1... --email admin@example.com [--ip A.B.C.D]
  install-panel.sh --restore <archive> --identity <age-key> --email admin@example.com [--ip A.B.C.D]
  install-panel.sh --setup-token
  install-panel.sh --check

--new prints a one-time activation code after HTTPS checks succeed. It does not accept an administrator password.
--update rebuilds the panel container on the existing data directory. It refuses to run when SQLite or master.key is missing, so it cannot create an empty database. A verified snapshot is taken first.
--rollback restores the newest pre-update snapshot and the recorded image id.
--restore keeps the administrator from the archive and issues a certificate for this IP.
--setup-token replaces the activation code when the first administrator does not exist yet. It does not delete SQLite.
The age private key is read from a file and removed from this host after a successful restore.
WireGuard servers are not changed.
EOF
}

is_public_ipv4() {
  local ip=$1 octet a b c d
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]}
  b=${BASH_REMATCH[2]}
  c=${BASH_REMATCH[3]}
  d=${BASH_REMATCH[4]}
  for octet in "$a" "$b" "$c" "$d"; do
    [ "$octet" -le 255 ] || return 1
  done
  [ "$a" -eq 0 ] && return 1
  [ "$a" -eq 10 ] && return 1
  [ "$a" -eq 127 ] && return 1
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 1
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 1
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 1
  [ "$a" -ge 224 ] && return 1
  return 0
}

valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

refuse_existing_data() {
  if [ -f "$STATE_DIR/family-vpn.sqlite" ] || [ -f "$STATE_DIR/master.key" ]; then
    log "DATA_EXISTS: база панели уже есть в $STATE_DIR. Установщик её не изменяет."
    log "Повторная установка не стирает SQLite и master.key."
    log "Обновление уже установленной панели этим режимом не выполняется."
    log "Восстановление из архива: $0 --restore <архив>"
    if [ -f "$STATE_DIR/family-vpn.sqlite" ]; then
      set +e
      admin_exists
      local admin_code=$?
      set -e
      if [ "$admin_code" -eq 1 ]; then
        log "Администратор ещё не создан. Новый код без удаления базы: $0 --setup-token"
      fi
    fi
    exit 3
  fi
}

wireguard_present() {
  if [ -d /etc/wireguard ]; then
    return 0
  fi
  if command -v ip >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

port_owners() {
  local port=$1
  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi
  ss -lntH "sport = :$port" 2>/dev/null || true
}

our_caddy_publishes() {
  command -v docker >/dev/null 2>&1 \
    && docker ps --filter name=family-vpn --format '{{.Ports}}' 2>/dev/null | grep -q ':80->'
}

require_ports_available() {
  local port listeners
  for port in 80 443; do
    listeners=$(port_owners "$port")
    if [ -n "$listeners" ] && ! our_caddy_publishes; then
      die "порт $port уже занят. Установщик не останавливает чужие службы. Освободите порт и повторите."
    fi
  done
}

detect_public_ipv4() {
  local candidate
  if command -v ip >/dev/null 2>&1; then
    candidate=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')
    if is_public_ipv4 "${candidate:-}"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    candidate=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
    if is_public_ipv4 "${candidate:-}"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}

render_caddy() {
  local template=$1
  sed "s/__PANEL_IP__/${PANEL_IP}/g" "$template" >"$CADDYFILE"
  chmod 644 "$CADDYFILE"
}

write_env() {
  local cert_name="family-vpn-${PANEL_IP}"
  umask 077
  cat >"$ENV_FILE" <<EOF
NODE_ENV=production
FAMILY_VPN_DATA_DIR=/data
FAMILY_VPN_TRUST_PROXY=1
FAMILY_VPN_PUBLIC_URL=https://${PANEL_IP}
EOF
  cat >"$ETC_DIR/renew.env" <<EOF
PANEL_IP=${PANEL_IP}
CERT_NAME=${cert_name}
CERTBOT=${CERTBOT}
COMPOSE_FILE=${COMPOSE_FILE}
COMPOSE_PROJECT_DIR=${PANEL_DIR}
EOF
  chmod 600 "$ENV_FILE" "$ETC_DIR/renew.env"
}

compose() {
  local -a files=(-f "$COMPOSE_FILE")
  if [ -n "${FAMILY_VPN_PANEL_IMAGE:-}" ]; then
    files+=(-f "$PANEL_DIR/docker-compose.image.yml")
  fi
  # Optional extra compose file for CI HTTP checks. Production never sets this.
  if [ -n "${FAMILY_VPN_COMPOSE_EXTRA:-}" ]; then
    files+=(-f "$FAMILY_VPN_COMPOSE_EXTRA")
  fi
  docker compose --project-directory "$PANEL_DIR" --env-file "$ENV_FILE" "${files[@]}" "$@"
}

verify_panel_image() {
  [ -n "${FAMILY_VPN_PANEL_IMAGE:-}" ] || return 0
  [ -n "${FAMILY_VPN_PANEL_DIGEST:-}" ] || die "FAMILY_VPN_PANEL_DIGEST не задан"
  docker image inspect "$FAMILY_VPN_PANEL_IMAGE" >/dev/null 2>&1 \
    || die "образ панели не найден: $FAMILY_VPN_PANEL_IMAGE"
  local expected id digests
  expected=$FAMILY_VPN_PANEL_DIGEST
  case "$expected" in
    sha256:*) ;;
    *) expected="sha256:$expected" ;;
  esac
  id=$(docker image inspect --format '{{.Id}}' "$FAMILY_VPN_PANEL_IMAGE")
  digests=$(docker image inspect --format '{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' "$FAMILY_VPN_PANEL_IMAGE")
  if [ "$id" = "$expected" ] || printf '%s\n' "$digests" | grep -F -q "$expected"; then
    log "образ панели подтверждён: $expected"
    return 0
  fi
  die "DIGEST_MISMATCH: образ $id не совпал с $expected. Установка остановлена."
}

ensure_docker() {
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker Engine не установлен. Устанавливаю."
    apt-get update || die "не удалось обновить список пакетов"
    apt-get install -y docker.io || die "не удалось установить Docker Engine. Повторите команду установки."
    hash -r
  else
    log "Docker Engine уже установлен"
  fi
  hash -r
  command -v docker >/dev/null 2>&1 || die "Docker Engine не появился в PATH после установки"
  if ! docker compose version >/dev/null 2>&1; then
    log "Docker Compose не установлен. Устанавливаю."
    apt-get install -y docker-compose-v2 || die "не удалось установить Docker Compose. Повторите команду установки."
    hash -r
  else
    log "Docker Compose уже установлен"
  fi
  docker compose version >/dev/null 2>&1 || die "Docker Compose не отвечает после установки"
  log "Включаю и запускаю службу Docker"
  systemctl enable --now docker || die "не удалось запустить службу Docker. Повторите команду установки."
  local attempt=1 attempts sleep_s
  attempts=${FAMILY_VPN_DOCKER_READY_ATTEMPTS:-30}
  sleep_s=${FAMILY_VPN_DOCKER_READY_SLEEP:-1}
  while [ "$attempt" -le "$attempts" ]; do
    if docker info >/dev/null 2>&1; then
      log "Docker daemon готов"
      return 0
    fi
    sleep "$sleep_s"
    attempt=$((attempt + 1))
  done
  die "Docker установлен, но daemon не ответил. Повторите команду установки."
}

load_verified_image() {
  [ -n "${FAMILY_VPN_PANEL_IMAGE:-}" ] || return 0
  ensure_docker
  local tar=${FAMILY_VPN_PANEL_IMAGE_TAR:-/tmp/family-vpn-panel-image.tar}
  if docker image inspect "$FAMILY_VPN_PANEL_IMAGE" >/dev/null 2>&1; then
    verify_panel_image
    return 0
  fi
  if [ -f "$tar" ]; then
    log "Загружаю проверенный образ панели"
    docker load -i "$tar" || die "не удалось загрузить проверенный архив образа. Повторите команду установки."
  elif printf '%s' "$FAMILY_VPN_PANEL_IMAGE" | grep -q '/'; then
    log "Скачиваю образ панели $FAMILY_VPN_PANEL_IMAGE"
    docker_pull_with_retry "$FAMILY_VPN_PANEL_IMAGE"
  else
    die "не найден проверенный архив образа: $tar"
  fi
  verify_panel_image
}

is_panel_runtime_image() {
  local image=$1
  [ -n "${FAMILY_VPN_PANEL_IMAGE:-}" ] || return 1
  [ "$image" = "$FAMILY_VPN_PANEL_IMAGE" ] && return 0
  [ -n "${FAMILY_VPN_PANEL_DIGEST:-}" ] && [ "$image" = "$FAMILY_VPN_PANEL_DIGEST" ] && return 0
  return 1
}

compose_image_list() {
  compose config --images | awk 'NF { print }' | sort -u
}

docker_pull_with_retry() {
  local image=$1
  local attempt=1
  local attempts=${FAMILY_VPN_PULL_ATTEMPTS:-5}
  local sleep_s
  while [ "$attempt" -le "$attempts" ]; do
    if docker pull "$image"; then
      return 0
    fi
    if [ "$attempt" -eq "$attempts" ]; then
      die "не удалось скачать образ $image. Повторите команду установки."
    fi
    sleep_s=$((attempt * 2))
    log "повторная загрузка образа $image через ${sleep_s}с"
    sleep "$sleep_s"
    attempt=$((attempt + 1))
  done
}

pull_public_compose_images() {
  ensure_docker
  [ -f "$ENV_FILE" ] || die "нет $ENV_FILE. Сначала подготовьте окружение панели."
  local image found_public=0
  local -a images=()
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    images+=("$image")
  done < <(compose_image_list)
  [ "${#images[@]}" -gt 0 ] || die "compose не вернул список образов"
  printf '%s\n' "${images[@]}" | grep -q '^caddy:' \
    || die "в Docker Compose нет образа Caddy"
  for image in "${images[@]}"; do
    if is_panel_runtime_image "$image"; then
      log "образ панели берётся из проверенного архива, не из registry"
      continue
    fi
    found_public=1
    if docker image inspect "$image" >/dev/null 2>&1; then
      log "образ уже есть: $image"
      continue
    fi
    log "Загружаю образ $image"
    docker_pull_with_retry "$image"
  done
  [ "$found_public" -eq 1 ] || die "в Docker Compose нет публичных образов для загрузки"
}

ensure_runtime_images_ready() {
  local image
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    docker image inspect "$image" >/dev/null 2>&1 \
      || die "образ не доступен перед запуском: $image"
  done < <(compose_image_list)
  verify_panel_image
  log "все образы Docker Compose готовы"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Устанавливаю системные пакеты"
  apt-get update || die "не удалось обновить список пакетов"
  apt-get install -y age ca-certificates curl iproute2 openssl python3 python3-cryptography python3-venv \
    || die "не удалось установить системные пакеты. Повторите команду установки."
  ensure_docker
}

install_certbot() {
  python3 -m venv /opt/family-vpn/certbot
  /opt/family-vpn/certbot/bin/pip install --upgrade pip
  /opt/family-vpn/certbot/bin/pip install -r "$PANEL_DIR/certbot-requirements.txt"
  local version
  version=$("$CERTBOT" --version 2>&1 | awk '{print $2}')
  printf '%s\n' "$version" | awk -F. '{ exit !($1 > 5 || ($1 == 5 && $2 >= 4)) }' \
    || die "нужен Certbot 5.4 или новее, установлен $version"
  log "certbot $version"
}

issue_certificate() {
  local -a staging=()
  local live="/etc/letsencrypt/live/family-vpn-${PANEL_IP}"
  if [ "$STAGING" -eq 1 ]; then
    staging=(--staging)
    log "сертификат запрашивается у staging Let's Encrypt и не будет доверенным для агентов"
  fi
  if ! "$CERTBOT" certonly \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --preferred-profile shortlived \
    --webroot -w "$ACME_DIR" \
    --ip-address "$PANEL_IP" \
    --cert-name "family-vpn-${PANEL_IP}" \
    "${staging[@]}"; then
    [ -f "$live/fullchain.pem" ] || die "не удалось выпустить сертификат"
    log "сертификат уже существует, повторный выпуск не требуется"
  fi
  local renewal="/etc/letsencrypt/renewal/family-vpn-${PANEL_IP}.conf"
  [ -f "$renewal" ] || die "не найден файл продления сертификата"
  if grep -q '^[[:space:]]*renew_before_expiry' "$renewal"; then
    sed -i 's/^[[:space:]]*renew_before_expiry.*/renew_before_expiry = 2 days/' "$renewal"
  else
    printf '\nrenew_before_expiry = 2 days\n' >>"$renewal"
  fi
  install -d -m 700 "$CERT_DIR"
  install -m 644 "$live/fullchain.pem" "$CERT_DIR/fullchain.pem"
  install -m 600 "$live/privkey.pem" "$CERT_DIR/privkey.pem"
}

install_renewal() {
  install -d -m 755 "$BIN_DIR"
  install -m 755 "$PANEL_DIR/renew-cert.sh" "$BIN_DIR/renew-cert.sh"
  install -m 644 "$PANEL_DIR/systemd/family-vpn-cert-renew.service" /etc/systemd/system/family-vpn-cert-renew.service
  install -m 644 "$PANEL_DIR/systemd/family-vpn-cert-renew.timer" /etc/systemd/system/family-vpn-cert-renew.timer
  systemctl daemon-reload
  systemctl enable --now family-vpn-cert-renew.timer
}

install_backup() {
  sed "s#__PANEL_DIR__#${PANEL_DIR}#g" "$PANEL_DIR/systemd/family-vpn-backup.service" \
    >/etc/systemd/system/family-vpn-backup.service
  sed "s#__PANEL_DIR__#${PANEL_DIR}#g" "$PANEL_DIR/systemd/family-vpn-backup-age.service" \
    >/etc/systemd/system/family-vpn-backup-age.service
  install -m 644 "$PANEL_DIR/systemd/family-vpn-backup.timer" /etc/systemd/system/family-vpn-backup.timer
  install -m 644 "$PANEL_DIR/systemd/family-vpn-backup-age.timer" /etc/systemd/system/family-vpn-backup-age.timer
  install -m 644 "$PANEL_DIR/systemd/family-vpn-backup.path" /etc/systemd/system/family-vpn-backup.path
  : >"$STATE_DIR/backup.requested"
  chown 1001:1001 "$STATE_DIR/backup.requested" 2>/dev/null || true
  chmod 600 "$STATE_DIR/backup.requested" 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable --now family-vpn-backup.timer family-vpn-backup.path family-vpn-backup-age.timer
}

save_pubkey() {
  [[ "$BACKUP_PUBKEY" =~ ^age1[0-9a-z]+$ ]] || die "PUBKEY_INVALID"
  printf '%s\n' "$BACKUP_PUBKEY" >"$ETC_DIR/backup.pub"
  chmod 644 "$ETC_DIR/backup.pub"
}

resolve_pubkey() {
  if [ -n "$BACKUP_PUBKEY_FILE" ]; then
    [ -f "$BACKUP_PUBKEY_FILE" ] || die "PUBKEY_MISSING"
    BACKUP_PUBKEY=$(tr -d '[:space:]' <"$BACKUP_PUBKEY_FILE")
  fi
  if printf '%s' "$BACKUP_PUBKEY" | grep -q 'AGE-SECRET-KEY-'; then
    die "PRIVATE_KEY_REFUSED"
  fi
  [[ "$BACKUP_PUBKEY" =~ ^age1[0-9a-z]+$ ]] || die "PUBKEY_MISSING"
}

issue_setup_token() {
  local pair token hash
  set +x
  if ! command -v "$PYTHON" >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3
    PYTHON=python3
  fi
  pair=$("$PYTHON" -c 'import hashlib, secrets
token = secrets.token_hex(32)
print(token)
print(hashlib.sha256(token.encode()).hexdigest())')
  token=${pair%%$'\n'*}
  hash=${pair#*$'\n'}
  hash_file=$(mktemp)
  printf '%s\n' "$hash" >"$hash_file"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  # Create the hash as the panel user. A root-owned mode 600 file is unreadable in the container.
  if [ "$(id -u)" -eq 0 ]; then
    install -o 1001 -g 1001 -m 600 "$hash_file" "$STATE_DIR/setup-token.sha256"
  else
    install -m 600 "$hash_file" "$STATE_DIR/setup-token.sha256"
    chmod 600 "$STATE_DIR/setup-token.sha256" 2>/dev/null || true
  fi
  rm -f "$hash_file"
  ACTIVATION_CODE=$token
}

load_panel_ip() {
  local saved
  if [ -n "$PANEL_IP" ]; then
    return 0
  fi
  if [ -f "$ETC_DIR/renew.env" ]; then
    saved=$(sed -n 's/^PANEL_IP=//p' "$ETC_DIR/renew.env" | head -n 1)
    if [ -n "$saved" ]; then
      PANEL_IP=$saved
    fi
  fi
}

print_activation_code() {
  local code=$1
  set +x
  if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
    printf '       \033[1;93m%s\033[0m\n\n' "$code"
  else
    printf 'SETUP_TOKEN=%s\n' "$code"
  fi
}

show_installed() {
  local code=$1
  local url="/login"
  set +x
  if [ -n "$PANEL_IP" ]; then
    url="https://${PANEL_IP}/login"
  fi
  if [ -t 1 ]; then
    printf '\n========================================\n'
    printf '       FAMILY VPN — УСТАНОВЛЕНО\n'
    printf '========================================\n\n'
    printf 'Панель: %s\n' "$url"
    printf 'HTTPS: OK\n'
    printf 'Docker: OK\n'
    printf 'Caddy: OK\n\n'
    printf 'КОД АКТИВАЦИИ АДМИНИСТРАТОРА:\n\n'
    print_activation_code "$code"
    printf '========================================\n\n'
    printf 'Открой панель, введи этот код\n'
    printf 'и создай пароль администратора.\n\n'
    printf '========================================\n'
  else
    print_activation_code "$code"
  fi
}

show_reissued() {
  local code=$1
  set +x
  if [ -t 1 ]; then
    printf '\n========================================\n'
    printf '   FAMILY VPN — НОВЫЙ КОД АКТИВАЦИИ\n'
    printf '========================================\n\n'
    printf 'Прежний код больше не действует.\n'
    printf 'База данных не изменялась.\n\n'
    if [ -n "$PANEL_IP" ]; then
      printf 'Панель: https://%s/login\n\n' "$PANEL_IP"
    fi
    printf 'КОД АКТИВАЦИИ АДМИНИСТРАТОРА:\n\n'
    print_activation_code "$code"
    printf '========================================\n\n'
    printf 'Открой панель, введи этот код\n'
    printf 'и создай пароль администратора.\n\n'
    printf '========================================\n'
  else
    print_activation_code "$code"
  fi
}

tls_handshake() {
  local label=$1
  shift
  local output
  set +e
  output=$(printf '\n' | openssl s_client -connect "${PANEL_IP}:443" "$@" 2>&1)
  set -e
  if printf '%s\n' "$output" | grep -q 'alert number 80'; then
    die "TLS ${label}: alert 80. Данные в $STATE_DIR не удалялись."
  fi
  if [ "$STAGING" -eq 0 ]; then
    printf '%s\n' "$output" | grep -q 'Verify return code: 0 (ok)' \
      || die "TLS ${label}: сертификат не прошёл проверку. Данные в $STATE_DIR не удалялись."
  else
    printf '%s\n' "$output" | grep -q 'Server certificate' \
      || die "TLS ${label}: рукопожатие не завершилось. Данные в $STATE_DIR не удалялись."
  fi
}

confirm_stack() {
  docker ps --format '{{.Names}}' | grep -q 'family-vpn-panel' \
    || die "контейнер панели не запущен. Данные в $STATE_DIR не удалялись."
  docker ps --format '{{.Names}}' | grep -q 'family-vpn-caddy' \
    || die "контейнер Caddy не запущен. Данные в $STATE_DIR не удалялись."
  [ -s "$STATE_DIR/family-vpn.sqlite" ] \
    || die "база панели не создана. Каталог $STATE_DIR не очищался."
}

admin_exists() {
  [ -f "$STATE_DIR/family-vpn.sqlite" ] || return 1
  "$PYTHON" -c 'import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
try:
    row = connection.execute("select id from admin where id = 1").fetchone()
except sqlite3.DatabaseError:
    raise SystemExit(2)
raise SystemExit(0 if row else 1)
' "$STATE_DIR/family-vpn.sqlite"
}

start_https() {
  install_packages
  load_verified_image
  install_certbot
  write_env
  render_caddy "$PANEL_DIR/Caddyfile.bootstrap"
  pull_public_compose_images
  ensure_runtime_images_ready
  if [ -n "${FAMILY_VPN_PANEL_IMAGE:-}" ]; then
    compose up -d --no-build --pull never
  else
    compose up -d --build
  fi
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if port_owners 80 | grep -q .; then
      break
    fi
    [ "$attempt" -eq 20 ] && die "Caddy не открыл порт 80"
    sleep 1
  done

  issue_certificate
  render_caddy "$PANEL_DIR/Caddyfile.https"
  compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile \
    || die "Caddy отклонил конфигурацию. Данные в $STATE_DIR не удалялись."
  compose exec -T caddy caddy reload --address 127.0.0.1:2019 --config /etc/caddy/Caddyfile \
    || die "Caddy не перезагрузил конфигурацию. Данные в $STATE_DIR не удалялись."
  install_renewal
  install_backup

  local -a curl_tls=()
  local status
  if [ "$STAGING" -eq 1 ]; then
    curl_tls=(--insecure)
    log "проверка staging смотрит только ответ панели: цепочку доверия агенты проверяют сами"
  fi
  status=$(curl -sS "${curl_tls[@]}" --max-time 20 -o /dev/null -w '%{http_code}' "https://${PANEL_IP}/login" || true)
  [ "$status" = "200" ] || die "панель не ответила HTTP 200 на https://${PANEL_IP}/login. Данные в $STATE_DIR не удалялись."
  tls_handshake "с SNI" -servername "$PANEL_IP"
  tls_handshake "без SNI" -noservername
  confirm_stack
}

prepare_host() {
  [ "$(id -u)" -eq 0 ] || die "запустите установщик от root"
  [ -r /etc/os-release ] || die "нужна Ubuntu 24.04"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ] || die "нужна Ubuntu 24.04, обнаружено ${PRETTY_NAME:-unknown}"
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "нужна архитектура x86_64, обнаружено $(uname -m)" ;;
  esac
  log "Система: Ubuntu ${VERSION_ID}, $(uname -m)"
  if wireguard_present; then
    log "WireGuard обнаружен. wg0, его конфигурация, peers и firewall не изменяются."
    log "Порты 80 и 443 должны уже быть доступны снаружи. Установщик правила firewall не пишет."
  else
    log "Firewall не переписывается. Откройте TCP 80 и 443, если они ещё закрыты."
  fi
  if ! command -v ss >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die "не удалось обновить список пакетов"
    apt-get install -y iproute2 || die "не удалось установить iproute2. Повторите команду установки."
  fi
  require_ports_available
  install -d -m 755 /var/lib/family-vpn "$ETC_DIR" "$BIN_DIR"
  install -d -m 700 -o 1001 -g 1001 "$STATE_DIR"
  install -d -m 755 "$ACME_DIR"
  install -d -m 700 "$CERT_DIR"
}

cmd_setup_token() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  set +e
  admin_exists
  local code=$?
  set -e
  if [ "$code" -eq 0 ]; then
    die "ADMIN_EXISTS"
  fi
  if [ "$code" -eq 2 ]; then
    die "SQLITE_UNREADABLE"
  fi
  load_panel_ip
  issue_setup_token
  show_reissued "$ACTIVATION_CODE"
}

cmd_restore() {
  local archive=${1:-} payload="" code=0
  [ -n "$archive" ] || die "usage: install-panel.sh --restore <archive> --email <address>"
  [ -n "$EMAIL" ] || die "укажите --email для учётки Let's Encrypt"
  valid_email "$EMAIL" || die "адрес --email выглядит неверно"
  if [ "$DECRYPTED" -eq 1 ]; then
    if [ "$archive" != "-" ] && [ ! -f "$archive" ]; then
      die "ARCHIVE_MISSING"
    fi
    [ -z "$IDENTITY" ] || die "KEY_STAYS_LOCAL"
    resolve_pubkey
  else
    if [[ "$archive" != s3://* ]] && [ ! -f "$archive" ]; then
      die "ARCHIVE_MISSING"
    fi
    [ -n "$IDENTITY" ] || die "укажите --identity с файлом приватного ключа age"
    [ -f "$IDENTITY" ] || die "IDENTITY_MISSING"
  fi
  if [ -z "$PANEL_IP" ]; then
    PANEL_IP=$(detect_public_ipv4) || die "не удалось определить публичный IPv4; укажите --ip"
  fi
  is_public_ipv4 "$PANEL_IP" || die "PRIVATE_IP: $PANEL_IP не является публичным IPv4"

  if [ "$DRY_RUN" -eq 1 ]; then
    refuse_existing_data
    if [ "$DECRYPTED" -eq 1 ]; then
      log "KEY_STAYS_LOCAL"
    fi
    log "RESTORE_DRY_RUN ip=$PANEL_IP"
    log "Архив будет проверен до записи. Существующая база не перезаписывается."
    log "После восстановления выпускается новый сертификат на этот IP."
    log "Серверы WireGuard и их peers этой командой не меняются."
    exit 0
  fi

  if [ "$DECRYPTED" -eq 1 ] && [ "$archive" = "-" ]; then
    payload=$(mktemp)
    chmod 600 "$payload" 2>/dev/null || true
    cat >"$payload"
    archive=$payload
  fi

  prepare_host
  install_packages
  set +e
  if [ "$DECRYPTED" -eq 1 ]; then
    bash "$PANEL_DIR/restore-panel.sh" --payload "$archive" --into "$STATE_DIR"
  else
    bash "$PANEL_DIR/restore-panel.sh" --archive "$archive" --identity "$IDENTITY" --into "$STATE_DIR"
  fi
  code=$?
  set -e
  if [ -n "$payload" ]; then
    rm -f "$payload"
  fi
  if [ "$code" -eq 3 ]; then
    log "DATA_EXISTS: в $STATE_DIR уже другая база. Она не изменена."
    exit 3
  fi
  [ "$code" -eq 0 ] || die "RESTORE_FAIL"

  if [ "$DECRYPTED" -eq 1 ]; then
    save_pubkey
    log "Приватный ключ age на этот сервер не передавался."
  else
    BACKUP_PUBKEY=$("$AGE_KEYGEN" -y "$IDENTITY")
    save_pubkey
    if [ "${FAMILY_VPN_KEEP_IDENTITY:-}" != "1" ]; then
      if command -v shred >/dev/null 2>&1; then
        shred -u "$IDENTITY" 2>/dev/null || rm -f "$IDENTITY"
      else
        rm -f "$IDENTITY"
      fi
      log "Копия ключа расшифровки на этом сервере удалена."
    fi
  fi
  set +e
  admin_exists
  code=$?
  set -e
  if [ "$code" -eq 2 ]; then
    die "SQLITE_UNREADABLE"
  fi
  local fresh_code=0
  if [ "$code" -eq 1 ]; then
    issue_setup_token
    fresh_code=1
  fi
  start_https
  log "AGENTS_UNCHANGED: адреса агентов этой командой не менялись."
  if [ "$fresh_code" -eq 1 ]; then
    show_installed "$ACTIVATION_CODE"
  else
    log "RESTORE_OK https://${PANEL_IP}/login"
    log "Администратор и его пароль сохранены. Код активации не требуется."
  fi
}

to_host_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
    return 0
  fi
  printf '%s\n' "$1"
}

archive_tool() {
  local command=$1
  shift
  local -a args=()
  local arg
  for arg in "$@"; do
    args+=("$(to_host_path "$arg")")
  done
  if "$NODE" --input-type=module -e "import 'node:sqlite'" >/dev/null 2>&1; then
    "$NODE" "$(to_host_path "$PANEL_DIR/archive-tool.mjs")" "$command" "${args[@]}"
    return $?
  fi
  "$PYTHON" "$(to_host_path "$PANEL_DIR/archive_host.py")" "$command" "${args[@]}"
}

take_panel_snapshot() {
  local stamp dir name
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dir="$PREUPDATE_DIR/$stamp"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  archive_tool snapshot "$STATE_DIR/family-vpn.sqlite" "$dir/family-vpn.sqlite" >/dev/null
  cp -p "$STATE_DIR/master.key" "$dir/master.key"
  chmod 600 "$dir/master.key" 2>/dev/null || true
  if [ -f "$ENV_FILE" ]; then
    cp -p "$ENV_FILE" "$dir/panel.env"
    chmod 600 "$dir/panel.env" 2>/dev/null || true
  fi
  if [ -f "${FAMILY_VPN_BACKUP_PUB:-$ETC_DIR/backup.pub}" ]; then
    cp -p "${FAMILY_VPN_BACKUP_PUB:-$ETC_DIR/backup.pub}" "$dir/backup.pub"
  fi
  archive_tool manifest "$dir" >/dev/null
  archive_tool verify "$dir" >/dev/null
  (
    cd "$dir"
    : > SHA256SUMS
    for name in family-vpn.sqlite master.key panel.env backup.pub; do
      [ -f "$name" ] || continue
      hash=$(sha256sum "$name" | awk '{print $1}')
      printf '%s  %s\n' "$hash" "$name" >> SHA256SUMS
    done
    sha256sum -c SHA256SUMS >/dev/null
  )
  printf '%s\n' "$dir"
}

restore_panel_snapshot() {
  local backup=$1 name
  [ -f "$backup/family-vpn.sqlite" ] || die "SNAPSHOT_MISSING"
  [ -f "$backup/master.key" ] || die "SNAPSHOT_MISSING"
  archive_tool verify "$backup" >/dev/null
  rm -f "$STATE_DIR/family-vpn.sqlite" "$STATE_DIR/family-vpn.sqlite-wal" "$STATE_DIR/family-vpn.sqlite-shm"
  cp -p "$backup/family-vpn.sqlite" "$STATE_DIR/family-vpn.sqlite"
  cp -p "$backup/master.key" "$STATE_DIR/master.key"
  chmod 600 "$STATE_DIR/family-vpn.sqlite" "$STATE_DIR/master.key" 2>/dev/null || true
  if [ -f "$backup/panel.env" ]; then
    cp -p "$backup/panel.env" "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
  fi
  if [ -f "$backup/backup.pub" ]; then
    cp -p "$backup/backup.pub" "${FAMILY_VPN_BACKUP_PUB:-$ETC_DIR/backup.pub}"
  fi
  log "PANEL_RESTORED $backup"
}

latest_panel_snapshot() {
  local dir latest=""
  [ -d "$PREUPDATE_DIR" ] || return 1
  for dir in "$PREUPDATE_DIR"/*; do
    [ -d "$dir" ] || continue
    [ -f "$dir/manifest.json" ] || continue
    latest=$dir
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

current_panel_image() {
  local container=""
  if [ "${FAMILY_VPN_UPDATE_TEST:-}" = "1" ]; then
    printf '%s\n' "${FAMILY_VPN_UPDATE_IMAGE_BEFORE:-previous-image}"
    return 0
  fi
  command -v docker >/dev/null 2>&1 || {
    printf '\n'
    return 0
  }
  container=$(docker ps -aq --filter name='family-vpn-panel' | head -n 1 || true)
  if [ -z "$container" ]; then
    printf '\n'
    return 0
  fi
  docker inspect --format '{{.Image}}' "$container" 2>/dev/null || printf '\n'
}

apply_panel_update() {
  local previous=$1
  if [ -n "${FAMILY_VPN_UPDATE_COMPOSE:-}" ]; then
    FAMILY_VPN_PREVIOUS_IMAGE="$previous" FAMILY_VPN_UPDATE_PHASE=apply \
      bash "$FAMILY_VPN_UPDATE_COMPOSE"
    return $?
  fi
  [ -f "$ENV_FILE" ] || return 1
  compose up -d --build --no-deps panel || return 1
  local attempt status url
  url=$(awk -F= '/^FAMILY_VPN_PUBLIC_URL=/{print $2; exit}' "$ENV_FILE")
  url=${url%/}
  [ -n "$url" ] || return 1
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    status=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "$url/login" || true)
    [ "$status" = "200" ] && return 0
    sleep 1
  done
  return 1
}

rollback_panel_runtime() {
  local backup=$1 previous=""
  previous=$(tr -d '\r' <"$backup/previous-image-id" 2>/dev/null || true)
  if [ -n "${FAMILY_VPN_UPDATE_COMPOSE:-}" ]; then
    FAMILY_VPN_PREVIOUS_IMAGE="$previous" FAMILY_VPN_UPDATE_PHASE=rollback \
      bash "$FAMILY_VPN_UPDATE_COMPOSE" || true
    return 0
  fi
  if [ -n "$previous" ] && [ -f "$ENV_FILE" ]; then
    FAMILY_VPN_PANEL_IMAGE="$previous" compose up -d --no-deps --no-build --pull never panel || true
  fi
}

require_panel_files() {
  [ -f "$STATE_DIR/family-vpn.sqlite" ] || die "SQLITE_MISSING: обновление не создаёт новую базу"
  [ -f "$STATE_DIR/master.key" ] || die "KEY_MISSING: обновление не создаёт новый master.key"
  [ -s "$STATE_DIR/master.key" ] || die "KEY_MISSING: обновление не создаёт новый master.key"
}

require_update_host() {
  [ "${FAMILY_VPN_UPDATE_TEST:-}" = "1" ] && return 0
  [ "$(id -u)" -eq 0 ] || die "запустите установщик от root"
  [ -r /etc/os-release ] || die "нужна Ubuntu 24.04"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ] || die "нужна Ubuntu 24.04, обнаружено ${PRETTY_NAME:-unknown}"
  command -v docker >/dev/null 2>&1 || die "нужен Docker"
  command -v sha256sum >/dev/null 2>&1 || die "нужен sha256sum"
}

admin_still_present() {
  local code=0
  set +e
  admin_exists
  code=$?
  set -e
  [ "$code" -eq 0 ]
}

cmd_update() {
  require_panel_files
  if [ "$DRY_RUN" -eq 1 ]; then
    log "UPDATE_DRY_RUN dir=$STATE_DIR"
    log "Сначала снимается проверяемая копия SQLite, master.key и panel.env."
    log "Контейнер panel пересобирается на том же каталоге. Новая пустая база не создаётся."
    log "WireGuard, peers, подсеть, NAT, firewall и SSH не изменяются."
    exit 0
  fi
  require_update_host
  local backup key_before key_after image_before
  backup=$(take_panel_snapshot) || die "BACKUP_FAIL"
  key_before=$(sha256sum "$STATE_DIR/master.key" | awk '{print $1}')
  image_before=$(current_panel_image)
  printf '%s\n' "$image_before" >"$backup/previous-image-id"
  chmod 600 "$backup/previous-image-id" 2>/dev/null || true
  if ! apply_panel_update "$image_before" || ! admin_still_present; then
    restore_panel_snapshot "$backup"
    rollback_panel_runtime "$backup"
    die "UPDATE_ROLLBACK"
  fi
  key_after=$(sha256sum "$STATE_DIR/master.key" | awk '{print $1}')
  if [ "$key_after" != "$key_before" ]; then
    restore_panel_snapshot "$backup"
    rollback_panel_runtime "$backup"
    die "UPDATE_ROLLBACK"
  fi
  log "UPDATE_OK backup=$backup"
}

cmd_rollback() {
  local backup=""
  backup=$(latest_panel_snapshot) || die "SNAPSHOT_MISSING"
  archive_tool verify "$backup" >/dev/null
  if [ "$DRY_RUN" -eq 1 ]; then
    log "ROLLBACK_DRY_RUN backup=$backup"
    log "Живая база не изменялась. Восстановление вернёт SQLite и master.key из этого снимка."
    exit 0
  fi
  require_update_host
  restore_panel_snapshot "$backup"
  rollback_panel_runtime "$backup"
  admin_still_present || die "ROLLBACK_ADMIN_MISSING"
  log "ROLLBACK_OK backup=$backup"
}

cmd_check() {
  local required template
  for required in \
    "$PANEL_DIR/Caddyfile.bootstrap" \
    "$PANEL_DIR/Caddyfile.https" \
    "$PANEL_DIR/docker-compose.yml" \
    "$PANEL_DIR/renew-cert.sh" \
    "$PANEL_DIR/certbot-requirements.txt" \
    "$PANEL_DIR/systemd/family-vpn-cert-renew.service" \
    "$PANEL_DIR/systemd/family-vpn-cert-renew.timer" \
    "$PANEL_DIR/backup-panel.sh" \
    "$PANEL_DIR/restore-panel.sh" \
    "$PANEL_DIR/backup-wg.sh" \
    "$PANEL_DIR/restore-wg.sh" \
    "$PANEL_DIR/push-restore.sh" \
    "$PANEL_DIR/archive-tool.mjs" \
    "$PANEL_DIR/s3_store.py" \
    "$PANEL_DIR/archive_host.py" \
    "$PANEL_DIR/backup.env.example" \
    "$PANEL_DIR/systemd/family-vpn-backup.service" \
    "$PANEL_DIR/systemd/family-vpn-backup.timer" \
    "$PANEL_DIR/systemd/family-vpn-wg-backup.service" \
    "$PANEL_DIR/docker-compose.image.yml"
  do
    [ -f "$required" ] || die "missing $required"
  done
  for template in "$PANEL_DIR/Caddyfile.bootstrap" "$PANEL_DIR/Caddyfile.https"; do
    grep -q '__PANEL_IP__' "$template" || die "$template has no panel IP placeholder"
    grep -q 'acme-challenge' "$template" || die "$template does not serve the ACME challenge"
    grep -q 'auto_https off' "$template" || die "$template must not ask Caddy to issue its own certificate"
  done
  grep -q '/certs/fullchain.pem' "$PANEL_DIR/Caddyfile.https"
  grep -q 'reverse_proxy panel:3000' "$PANEL_DIR/Caddyfile.https"
  grep -q 'certbot renew' "$PANEL_DIR/renew-cert.sh"
  grep -q 'caddy reload' "$PANEL_DIR/renew-cert.sh"
  grep -q 'checkend 172800' "$PANEL_DIR/renew-cert.sh"
  grep -q 'IP Address:' "$PANEL_DIR/renew-cert.sh"
  grep -q 'certbot>=5.4' "$PANEL_DIR/certbot-requirements.txt"
  grep -q 'preferred-profile shortlived' "$PANEL_DIR/install-panel.sh"
  grep -q 'FAMILY VPN — УСТАНОВЛЕНО' "$PANEL_DIR/install-panel.sh"
  grep -q -- '-noservername' "$PANEL_DIR/install-panel.sh"
  grep -q 'default_sni __PANEL_IP__' "$PANEL_DIR/Caddyfile.https"
  grep -q 'KEY_MISMATCH' "$PANEL_DIR/archive-tool.mjs"
  grep -q 'SCHEMA_MAX = 4' "$PANEL_DIR/archive-tool.mjs"
  grep -q 'SCHEMA_MAX = 4' "$PANEL_DIR/archive_host.py"
  grep -q 'UPLOAD_OK' "$PANEL_DIR/backup-panel.sh"
  grep -q 'DATA_EXISTS' "$PANEL_DIR/restore-panel.sh"
  grep -q 'DECRYPT_FAIL' "$PANEL_DIR/restore-panel.sh"
  grep -q 'KEY_STAYS_LOCAL' "$PANEL_DIR/restore-panel.sh"
  grep -q 'KEY_STAYS_LOCAL' "$PANEL_DIR/push-restore.sh"
  grep -q -- '--decrypted' "$PANEL_DIR/install-panel.sh"
  grep -q 'DIGEST_MISMATCH' "$PANEL_DIR/install-panel.sh"
  grep -q -- '--no-build' "$PANEL_DIR/install-panel.sh"
  grep -q 'load_verified_image' "$PANEL_DIR/install-panel.sh"
  grep -q 'pull_public_compose_images' "$PANEL_DIR/install-panel.sh"
  grep -q 'ensure_runtime_images_ready' "$PANEL_DIR/install-panel.sh"
  grep -q 'compose config --images' "$PANEL_DIR/install-panel.sh"
  grep -q 'docker.io' "$PANEL_DIR/install-panel.sh"
  grep -q 'docker-compose-v2' "$PANEL_DIR/install-panel.sh"
  grep -q 'Docker daemon готов' "$PANEL_DIR/install-panel.sh"
  grep -q 'Caddy: OK' "$PANEL_DIR/install-panel.sh"
  grep -q 'caddy:2.10-alpine' "$PANEL_DIR/docker-compose.yml"
  grep -q 'FAMILY_VPN_PANEL_IMAGE' "$PANEL_DIR/docker-compose.image.yml"
  is_public_ipv4 203.0.113.5 || die "public IP check failed"
  if is_public_ipv4 10.1.2.3 || is_public_ipv4 127.0.0.1 || is_public_ipv4 192.168.1.1; then
    die "private IP was accepted"
  fi
  log "CHECK_OK"
}

cmd_new() {
  resolve_pubkey
  [ -n "$EMAIL" ] || die "укажите --email для учётки Let's Encrypt"
  valid_email "$EMAIL" || die "адрес --email выглядит неверно"
  if [ -z "$PANEL_IP" ]; then
    PANEL_IP=$(detect_public_ipv4) || die "не удалось определить публичный IPv4; укажите --ip"
  fi
  is_public_ipv4 "$PANEL_IP" || die "PRIVATE_IP: $PANEL_IP не является публичным IPv4"
  if [ -n "${FAMILY_VPN_PANEL_IMAGE:-}" ]; then
    [ -n "${FAMILY_VPN_PANEL_DIGEST:-}" ] || die "FAMILY_VPN_PANEL_DIGEST не задан"
  elif [ ! -f "$APP_DIR/Dockerfile" ]; then
    die "запустите скрипт из копии репозитория: в $APP_DIR нет Dockerfile"
  fi
  [ -f "$COMPOSE_FILE" ] || die "не найден $COMPOSE_FILE"
  refuse_existing_data

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY_RUN_OK ip=$PANEL_IP url=https://$PANEL_IP"
    log "SQLite и master.key будут в $STATE_DIR с правами только у uid 1001."
    log "Администратор создаётся в браузере на /login по одноразовому коду. Пароль установщик не принимает."
    log "Копии шифруются публичным ключом age. Приватный ключ на сервер не кладётся."
    log "WireGuard, wg0.conf, peers, UDP 51820 и действующий firewall не изменяются."
    log "Повторный запуск при уже существующей базе останавливается, не стирая её."
    exit 0
  fi

  prepare_host
  refuse_existing_data
  install_packages
  load_verified_image
  save_pubkey
  issue_setup_token
  start_https
  log "Продление сертификата включено: family-vpn-cert-renew.timer"
  show_installed "$ACTIVATION_CODE"
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --new)
      [ -z "$MODE" ] || die "укажите только один режим"
      MODE=new
      shift
      ;;
    --update)
      [ -z "$MODE" ] || die "укажите только один режим"
      MODE=update
      shift
      ;;
    --rollback)
      [ -z "$MODE" ] || die "укажите только один режим"
      MODE=rollback
      shift
      ;;
    --restore)
      [ -z "$MODE" ] || die "укажите только один режим"
      MODE=restore
      shift
      [ $# -ge 1 ] || die "usage: install-panel.sh --restore <archive>"
      RESTORE_ARCHIVE=$1
      shift
      ;;
    --check)
      [ -z "$MODE" ] || die "укажите только один режим"
      MODE=check
      shift
      ;;
    --verify-image)
      [ -z "$MODE" ] || die "укажите только один режим"
      MODE=verify-image
      shift
      ;;
    --ip)
      [ $# -ge 2 ] || die "укажите адрес после --ip"
      PANEL_IP=$2
      shift 2
      ;;
    --email)
      [ $# -ge 2 ] || die "укажите адрес после --email"
      EMAIL=$2
      shift 2
      ;;
    --staging)
      STAGING=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --backup-pubkey)
      [ $# -ge 2 ] || die "укажите публичный ключ age после --backup-pubkey"
      BACKUP_PUBKEY=$2
      shift 2
      ;;
    --backup-pubkey-file)
      [ $# -ge 2 ] || die "укажите файл после --backup-pubkey-file"
      BACKUP_PUBKEY_FILE=$2
      shift 2
      ;;
    --identity)
      [ $# -ge 2 ] || die "укажите файл после --identity"
      IDENTITY=$2
      shift 2
      ;;
    --decrypted)
      DECRYPTED=1
      shift
      ;;
    --setup-token)
      [ -z "$MODE" ] || die "укажите только один режим"
      MODE=setup-token
      shift
      ;;
    --password|--admin-password)
      die "пароль администратора нельзя передавать установщику"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "неизвестный аргумент: $1"
      ;;
  esac
done

case "$MODE" in
  new) cmd_new ;;
  update) cmd_update ;;
  rollback) cmd_rollback ;;
  restore) cmd_restore "${RESTORE_ARCHIVE:-}" ;;
  setup-token) cmd_setup_token ;;
  check) cmd_check ;;
  verify-image) verify_panel_image; log "IMAGE_OK" ;;
  *) usage; die "укажите --new, --update, --rollback, --restore, --setup-token или --check" ;;
esac
