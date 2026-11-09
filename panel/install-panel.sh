#!/bin/bash
# Install a new Family VPN panel on Ubuntu 24.04.
# HTTPS is a Let's Encrypt certificate for the public IPv4 (shortlived, 160 hours).
# The script does not stop WireGuard, edit wg0.conf, or rewrite the firewall.
# --restore is reserved for the next stage and changes nothing.
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
  install-panel.sh --new --email admin@example.com [--ip A.B.C.D] [--staging] [--dry-run]
  install-panel.sh --restore <archive>
  install-panel.sh --check

--new installs a panel and leaves administrator creation to https://<ip>/login.
The password is never accepted on the command line.
--restore is not implemented yet and does not change data or services.
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
  apt-get install -y ca-certificates curl iproute2 openssl python3 python3-venv
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

cmd_restore() {
  local archive=${1:-}
  [ -n "$archive" ] || die "usage: install-panel.sh --restore <archive>"
  log "RESTORE_LATER: режим --restore подготовлен и пока ничего не меняет."
  log "Архив не читается, база не записывается, службы не перезапускаются."
  log "Следующий этап проверит подпись, SHA-256 и соответствие master.key базе."
  exit 2
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
    "$PANEL_DIR/systemd/family-vpn-cert-renew.timer"
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
  is_public_ipv4 203.0.113.5 || die "public IP check failed"
  if is_public_ipv4 10.1.2.3 || is_public_ipv4 127.0.0.1 || is_public_ipv4 192.168.1.1; then
    die "private IP was accepted"
  fi
  log "CHECK_OK"
}

cmd_new() {
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
    log "Администратор создаётся в браузере на /login. Пароль установщик не принимает."
    log "WireGuard, wg0.conf, peers, UDP 51820 и действующий firewall не изменяются."
    log "Повторный запуск при уже существующей базе останавливается, не стирая её."
    exit 0
  fi

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
  refuse_existing_data

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

  local -a curl_tls=()
  if [ "$STAGING" -eq 1 ]; then
    curl_tls=(--insecure)
    log "проверка staging смотрит только ответ панели: цепочку доверия агенты проверяют сами"
  fi
  if ! curl -fsS "${curl_tls[@]}" --max-time 20 "https://${PANEL_IP}/login" >/dev/null; then
    die "панель не ответила на https://${PANEL_IP}/login. Данные в $STATE_DIR не удалялись."
  fi
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
  check) cmd_check ;;
  *) usage; die "укажите --new, --restore или --check" ;;
esac
