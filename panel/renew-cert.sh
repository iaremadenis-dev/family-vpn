#!/bin/bash
# Renew the panel IP certificate and reload Caddy.
# Reads /etc/family-vpn/renew.env. Does not print key material.
set -euo pipefail
umask 077

ENV_FILE=/etc/family-vpn/renew.env
STATUS=/var/lib/family-vpn/cert-renew.status

fail() {
  printf '%s FAIL %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >"$STATUS"
  chmod 644 "$STATUS" 2>/dev/null || true
  echo "family-vpn-cert: $*" >&2
  exit 1
}

[ -f "$ENV_FILE" ] || fail "missing $ENV_FILE"
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${PANEL_IP:?}"
: "${CERT_NAME:?}"
: "${CERTBOT:?}"
: "${COMPOSE_FILE:?}"
: "${COMPOSE_PROJECT_DIR:?}"

[ -x "$CERTBOT" ] || fail "certbot is not executable"
[ -f "$COMPOSE_FILE" ] || fail "compose file is missing"

"$CERTBOT" renew --non-interactive --quiet --cert-name "$CERT_NAME" || fail "certbot renew failed"

live="/etc/letsencrypt/live/${CERT_NAME}"
[ -f "$live/fullchain.pem" ] || fail "fullchain is missing after renew"
[ -f "$live/privkey.pem" ] || fail "private key is missing after renew"

install -d -m 700 /var/lib/family-vpn/certs
install -m 644 "$live/fullchain.pem" /var/lib/family-vpn/certs/fullchain.pem
install -m 600 "$live/privkey.pem" /var/lib/family-vpn/certs/privkey.pem

if ! openssl x509 -checkend 172800 -noout -in /var/lib/family-vpn/certs/fullchain.pem; then
  "$CERTBOT" renew --non-interactive --force-renewal --quiet --cert-name "$CERT_NAME" || fail "forced renew failed"
  install -m 644 "$live/fullchain.pem" /var/lib/family-vpn/certs/fullchain.pem
  install -m 600 "$live/privkey.pem" /var/lib/family-vpn/certs/privkey.pem
fi

openssl x509 -checkend 172800 -noout -in /var/lib/family-vpn/certs/fullchain.pem \
  || fail "certificate expires within 48 hours"

openssl x509 -in /var/lib/family-vpn/certs/fullchain.pem -noout -ext subjectAltName \
  | grep -q "IP Address:${PANEL_IP}" \
  || fail "certificate is not issued for ${PANEL_IP}"

docker compose --project-directory "$COMPOSE_PROJECT_DIR" -f "$COMPOSE_FILE" \
  exec -T caddy caddy reload --config /etc/caddy/Caddyfile \
  || fail "caddy reload failed"

printf '%s OK %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PANEL_IP" >"$STATUS"
chmod 644 "$STATUS"
