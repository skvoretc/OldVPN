#!/usr/bin/env bash
# Запуск: sudo bash install.sh

set -euo pipefail

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"
VPN_SERVER_IP="${VPN_SERVER_IP:-10.8.0.1}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Запустите от root: sudo bash $0" >&2
  exit 1
fi

if [[ -f "/etc/wireguard/${WG_INTERFACE}.conf" ]]; then
  echo "Уже есть /etc/wireguard/${WG_INTERFACE}.conf — удалите вручную или смените WG_INTERFACE." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y wireguard wireguard-tools qrencode iptables

DEFAULT_IF="$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)"
if [[ -z "${DEFAULT_IF}" ]]; then
  echo "Не удалось определить сетевой интерфейс с default route." >&2
  exit 1
fi

umask 077
install -d -m 700 /etc/wireguard/clients
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIV="$(cat /etc/wireguard/server_private.key)"
SERVER_PUB="$(cat /etc/wireguard/server_public.key)"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.d/99-wireguard.conf 2>/dev/null; then
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
fi
sysctl --system -q 2>/dev/null || true

cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
# Сгенерировано install.sh — не публикуйте приватный ключ
[Interface]
Address = ${VPN_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IF} -j MASQUERADE
EOF

chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"

if [[ "${WG_SKIP_SYSTEMD:-0}" == "1" ]]; then
  wg-quick up "${WG_INTERFACE}"
else
  systemctl enable --now "wg-quick@${WG_INTERFACE}"
fi

PUBLIC_IP="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || true)"

echo ""
echo "=== WireGuard установлен ==="
echo "Интерфейс: ${WG_INTERFACE}, порт UDP: ${WG_PORT}"
echo "Внешний интерфейс (NAT): ${DEFAULT_IF}"
echo "Публичный ключ сервера:"
echo "${SERVER_PUB}"
echo ""
if [[ -n "${PUBLIC_IP}" ]]; then
  echo "Похоже, публичный IPv4: ${PUBLIC_IP} (проверьте в панели VPS)."
else
  echo "Не удалось автоопределить публичный IP — укажите Endpoint вручную в конфиге клиента."
fi
echo ""
echo "Добавить клиента: sudo bash $(dirname "$0")/add-client.sh имя_клиента"
echo "Открыть порт в фаерволе (если UFW): sudo ufw allow ${WG_PORT}/udp && sudo ufw reload"
