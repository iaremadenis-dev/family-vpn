#!/bin/bash
# Install a new Family VPN panel on Ubuntu 24.04.
# HTTPS is a Let's Encrypt certificate for the public IPv4 (shortlived, 160 hours).
# The script does not stop WireGuard, edit wg0.conf, or rewrite the firewall.
# --restore - --decrypted reads a tar already decrypted on the administrator's computer.
# --restore <archive> --identity remains available and then deletes that key copy.
set -euo pipefail
umask 077

APP_DIR=$(cd "$(dirname "$0")/.." && pwd)
PANEL_DIR="$APP_DIR/panel"
STATE_DIR=${FAMILY_VPN_PANEL_DIR:-/var/lib/family-vpn/panel}
CERT_DIR=/var/lib/family-vpn/certs
ACME_DIR=/var/lib/family-vpn/acme
ETC_DIR=/etc/family-vpn
BIN_DIR=/opt/family-vpn/bin
CERTBOT=${FAMILY_VPN_CERTBOT:-/opt/family-vpn/certbot/bin/certbot}
ENV_FILE="$ETC_DIR/panel.env"
CADDYFILE="$ETC_DIR/Caddyfile"
COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
LOG_FILE=/var/log/family-vpn-install.log

MODE=""
PANEL_IP=${FAMILY_VPN_PANEL_IP:-}
EMAIL=""
STAGING=0
DRY_RUN=0
DECRYPTED=0
BACKUP_PUBKEY=""
BACKUP_PUBKEY_FILE=""
IDENTITY=""
AGE_KEYGEN=${FAMILY_VPN_AGE_KEYGEN:-age-keygen}
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
  install-panel.sh --restore - --decrypted --backup-pubkey age1... --email admin@example.com [--ip A.B.C.D]
  install-panel.sh --restore <archive> --identity <age-key> --email admin@example.com [--ip A.B.C.D]
  install-panel.sh --setup-token
  install-panel.sh --check

--new prints a one-time activation code and does not accept an administrator password.
--restore decrypts a panel archive, keeps the administrator, and issues a certificate for this IP.
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
    log "Восстановление из архива, когда оно будет готово: install-panel.sh --restore <архив>"
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
  docker compose --project-directory "$PANEL_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

install_packages() {
  apt-get update
  apt-get install -y age ca-certificates curl iproute2 openssl python3 python3-cryptography python3-venv
  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y docker.io
  fi
  if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y docker-compose-v2
  fi
  systemctl enable --now docker
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
  printf '%s\n' "$hash" >"$STATE_DIR/setup-token.sha256"
  chmod 600 "$STATE_DIR/setup-token.sha256" 2>/dev/null || true
  printf '%s\n' "SETUP_TOKEN=${token}"
  printf '%s\n' "Код активации показан один раз и в журнал не пишется."
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
  install_certbot
  write_env
  render_caddy "$PANEL_DIR/Caddyfile.bootstrap"
  compose up -d --build
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
  compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  install_renewal
  install_backup

  local -a curl_tls=()
  if [ "$STAGING" -eq 1 ]; then
    curl_tls=(--insecure)
    log "проверка staging смотрит только ответ панели: цепочку доверия агенты проверяют сами"
  fi
  if ! curl -fsS "${curl_tls[@]}" --max-time 20 "https://${PANEL_IP}/login" >/dev/null; then
    die "панель не ответила на https://${PANEL_IP}/login. Данные в $STATE_DIR не удалялись."
  fi
}

prepare_host() {
  [ "$(id -u)" -eq 0 ] || die "запустите установщик от root"
  [ -r /etc/os-release ] || die "нужна Ubuntu 24.04"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ] || die "нужна Ubuntu 24.04, обнаружено ${PRETTY_NAME:-unknown}"
  if wireguard_present; then
    log "WireGuard обнаружен. wg0, его конфигурация, peers и firewall не изменяются."
    log "Порты 80 и 443 должны уже быть доступны снаружи. Установщик правила firewall не пишет."
  else
    log "Firewall не переписывается. Откройте TCP 80 и 443, если они ещё закрыты."
  fi
  if ! command -v ss >/dev/null 2>&1; then
    apt-get update
    apt-get install -y iproute2
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
  issue_setup_token
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
  if [ "$code" -eq 1 ]; then
    issue_setup_token
  fi
  start_https
  log "RESTORE_OK https://${PANEL_IP}/login"
  log "AGENTS_UNCHANGED: адреса агентов этой командой не менялись."
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
    "$PANEL_DIR/systemd/family-vpn-wg-backup.service"
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
  grep -q 'KEY_MISMATCH' "$PANEL_DIR/archive-tool.mjs"
  grep -q 'SCHEMA_MAX = 3' "$PANEL_DIR/archive-tool.mjs"
  grep -q 'UPLOAD_OK' "$PANEL_DIR/backup-panel.sh"
  grep -q 'DATA_EXISTS' "$PANEL_DIR/restore-panel.sh"
  grep -q 'DECRYPT_FAIL' "$PANEL_DIR/restore-panel.sh"
  grep -q 'KEY_STAYS_LOCAL' "$PANEL_DIR/restore-panel.sh"
  grep -q 'KEY_STAYS_LOCAL' "$PANEL_DIR/push-restore.sh"
  grep -q -- '--decrypted' "$PANEL_DIR/install-panel.sh"
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
  [ -f "$APP_DIR/Dockerfile" ] || die "запустите скрипт из копии репозитория: в $APP_DIR нет Dockerfile"
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
  save_pubkey
  issue_setup_token
  start_https
  log "Панель слушает https://${PANEL_IP}/login"
  log "Создайте администратора в браузере. Установщик пароль не видит и не записывает."
  log "База и master.key остаются в $STATE_DIR."
  log "Продление сертификата: systemctl status family-vpn-cert-renew.timer"
  log "Сбой продления пишется в /var/lib/family-vpn/cert-renew.status и в journalctl -u family-vpn-cert-renew.service"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --new)
      [ -z "$MODE" ] || die "укажите только один режим"
      MODE=new
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
  restore) cmd_restore "${RESTORE_ARCHIVE:-}" ;;
  setup-token) cmd_setup_token ;;
  check) cmd_check ;;
  *) usage; die "укажите --new, --restore, --setup-token или --check" ;;
esac
