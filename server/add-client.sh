#!/usr/bin/env bash
# Запуск: sudo bash add-client.sh my-laptop
# Раздельный туннель: CLIENT_ALLOWED_IPS="10.0.0.0/8,192.168.5.0/24" ...
# Без DNS в конфиге: NO_CLIENT_DNS=1 (см. add-home-router.sh)

set -euo pipefail

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
CLIENT_BASE_IP="${CLIENT_BASE_IP:-10.8.0}"
CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-0.0.0.0/0}"
# DNS в [Interface]: 1.1.1.1 по умолчанию; NO_CLIENT_DNS=1 — не добавлять строку DNS (роутер)
NO_CLIENT_DNS="${NO_CLIENT_DNS:-0}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Запустите от root: sudo bash $0 <имя>" >&2
  exit 1
fi

NAME="${1:-}"
if [[ -z "${NAME}" ]] || [[ "${NAME}" =~ [^a-zA-Z0-9._-] ]]; then
  echo "Использование: sudo bash $0 <имя_клиента> (латиница, цифры, . _ -)" >&2
  exit 1
fi

CONF_PATH="/etc/wireguard/${WG_INTERFACE}.conf"
if [[ ! -f "${CONF_PATH}" ]]; then
  echo "Нет ${CONF_PATH}. Сначала выполните install.sh" >&2
  exit 1
fi

install -d -m 700 /etc/wireguard/clients
CLIENT_FILE="/etc/wireguard/clients/${NAME}.conf"
if [[ -f "${CLIENT_FILE}" ]]; then
  echo "Клиент ${NAME} уже есть: ${CLIENT_FILE}" >&2
  exit 1
fi

SERVER_PUB="$(cat /etc/wireguard/server_public.key)"

NEXT_HOST=2
while grep -qE "AllowedIPs = ${CLIENT_BASE_IP//./\\.}\\.${NEXT_HOST}/32" "${CONF_PATH}" 2>/dev/null; do
  if [[ "${NEXT_HOST}" -ge 254 ]]; then
    echo "Нет свободных адресов в подсети." >&2
    exit 1
  fi
  NEXT_HOST=$((NEXT_HOST + 1))
done

CLIENT_IP="${CLIENT_BASE_IP}.${NEXT_HOST}"

umask 077
PRIV="$(wg genkey)"
PUB="$(echo "${PRIV}" | wg pubkey)"

wg set "${WG_INTERFACE}" peer "${PUB}" allowed-ips "${CLIENT_IP}/32"

cat >> "${CONF_PATH}" <<EOF

[Peer]
# ${NAME}
PublicKey = ${PUB}
AllowedIPs = ${CLIENT_IP}/32
EOF

ENDPOINT="${WG_ENDPOINT:-}"
if [[ -z "${ENDPOINT}" ]]; then
  ENDPOINT="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || echo 'ВАШ_IP_VPS')"
fi

{
  echo "[Interface]"
  echo "PrivateKey = ${PRIV}"
  echo "Address = ${CLIENT_IP}/32"
  if [[ "${NO_CLIENT_DNS}" != "1" ]]; then
    echo "DNS = ${CLIENT_DNS}"
  fi
  echo ""
  echo "[Peer]"
  echo "PublicKey = ${SERVER_PUB}"
  echo "Endpoint = ${ENDPOINT}:${WG_PORT}"
  echo "AllowedIPs = ${CLIENT_ALLOWED_IPS}"
  echo "PersistentKeepalive = 25"
} > "${CLIENT_FILE}"
chmod 600 "${CLIENT_FILE}"

echo ""
echo "=== Клиент: ${NAME} ==="
echo "Туннель (AllowedIPs у клиента): ${CLIENT_ALLOWED_IPS}"
echo "Файл: ${CLIENT_FILE}"
echo ""
cat "${CLIENT_FILE}"
echo ""
if command -v qrencode >/dev/null 2>&1; then
  echo "QR (для WireGuard на телефоне):"
  qrencode -t ansiutf8 < "${CLIENT_FILE}"
fi
