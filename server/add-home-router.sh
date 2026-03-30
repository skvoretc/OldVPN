#!/usr/bin/env bash
# Профиль «домашний роутер»: полный туннель, без строки DNS
# Запуск: sudo bash add-home-router.sh home-openwrt

set -euo pipefail

export NO_CLIENT_DNS=1
export CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-0.0.0.0/0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/add-client.sh" "$@"
