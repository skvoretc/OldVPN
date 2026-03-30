#!/usr/bin/env bash
# ↑ Shebang в Linux: указать интерпретатор bash для этого файла.

# Профиль «домашний роутер»: полный туннель, без строки DNS (удобно для OpenWrt / Keenetic и т.п.)
# ↑ Обёртка задаёт переменные окружения и делегирует add-client.sh — один сценарий для роутера.
# Запуск: sudo bash add-home-router.sh home-openwrt
# ↑ Имя аргумента — метка клиента на сервере и имя файла .conf.

set -euo pipefail
# ↑ Останов при ошибке, запрет незаданных переменных, pipefail для конвейеров.

export NO_CLIENT_DNS=1
# ↑ export делает переменную видимой дочернему процессу add-client.sh; 1 — не добавлять DNS в конфиг.
export CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-0.0.0.0/0}"
# ↑ По умолчанию весь IPv4 через VPN; можно переопределить до вызова для нестандартного сценария.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ↑ BASH_SOURCE[0] — путь к текущему скрипту; dirname — каталог; cd … && pwd — канонический абсолютный путь (обходит symlink).
exec bash "${SCRIPT_DIR}/add-client.sh" "$@"
# ↑ exec заменяет текущий процесс на bash: не остаётся лишнего родителя; "$@" передаёт все аргументы (имя клиента и др.) в add-client.sh.
