#!/usr/bin/env bash
# ↑ Shebang: выполнить скрипт интерпретатором bash (Linux/macOS/WSL).

# Добавить клиента WireGuard и вывести .conf + QR
# ↑ Описание назначения скрипта для читающего код.
# Запуск: sudo bash add-client.sh my-laptop
# ↑ Пример вызова; первый аргумент — уникальное имя клиента (латиница и безопасные символы).
# Раздельный туннель: CLIENT_ALLOWED_IPS="10.0.0.0/8,192.168.5.0/24" ...
# ↑ Подсказка: через переменные окружения меняют split tunnel без правки скрипта.
# Без DNS в конфиге: NO_CLIENT_DNS=1 (см. add-home-router.sh)
# ↑ NO_CLIENT_DNS=1 убирает строку DNS из клиентского .conf (удобно для роутеров).

set -euo pipefail
# ↑ Строгий режим bash: останов при ошибке, запрет неинициализированных переменных, корректный код в pipe.

WG_INTERFACE="${WG_INTERFACE:-wg0}"
# ↑ Имя интерфейса WireGuard на сервере (должен совпадать с install.sh).
WG_PORT="${WG_PORT:-51820}"
# ↑ Порт Endpoint в клиентском конфиге (тот же, что ListenPort на сервере).
# Первый клиент — .2, дальше по счётку
# ↑ Пояснение логики выдачи IP: .1 занят сервером в подсети /24.
CLIENT_BASE_IP="${CLIENT_BASE_IP:-10.8.0}"
# ↑ Первые три октета внутренней сети VPN (без последнего октета хоста).
# У клиента в [Peer]: какие сети идут через VPN (раздельное туннелирование)
# ↑ Это про поле AllowedIPs на стороне клиента в выдаваемом .conf.
CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-0.0.0.0/0}"
# ↑ 0.0.0.0/0 — весь IPv4 через туннель (полный туннель) по умолчанию.
# DNS в [Interface]: 1.1.1.1 по умолчанию; NO_CLIENT_DNS=1 — не добавлять строку DNS (роутер)
# ↑ DNS в WireGuard-клиенте может подставлять DNS-сервер в систему при активации туннеля.
NO_CLIENT_DNS="${NO_CLIENT_DNS:-0}"
# ↑ Флаг 0/1: не писать строку DNS в конфиг клиента.
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"
# ↑ Резолвер Cloudflare по умолчанию для клиентов с полным туннелем.

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
# ↑ Проверка root: wg set и запись в /etc требуют привилегий.
  echo "Запустите от root: sudo bash $0 <имя>" >&2
  exit 1
fi

NAME="${1:-}"
# ↑ Первый позиционный аргумент; :-" значит по умолчанию пустая строка, если аргумента нет.
if [[ -z "${NAME}" ]] || [[ "${NAME}" =~ [^a-zA-Z0-9._-] ]]; then
# ↑ -z пустое имя; =~ регулярное выражение bash — допустимы только буквы, цифры, . _ -
  echo "Использование: sudo bash $0 <имя_клиента> (латиница, цифры, . _ -)" >&2
  exit 1
fi

CONF_PATH="/etc/wireguard/${WG_INTERFACE}.conf"
# ↑ Путь к основному конфигу wg-quick на сервере.
if [[ ! -f "${CONF_PATH}" ]]; then
# ↑ ! -f — файл не существует или не обычный файл.
  echo "Нет ${CONF_PATH}. Сначала выполните install.sh" >&2
  exit 1
fi

install -d -m 700 /etc/wireguard/clients
# ↑ Каталог для сохранённых клиентских .conf на сервере.
CLIENT_FILE="/etc/wireguard/clients/${NAME}.conf"
# ↑ Итоговый путь файла конфигурации для этого клиента.
if [[ -f "${CLIENT_FILE}" ]]; then
  echo "Клиент ${NAME} уже есть: ${CLIENT_FILE}" >&2
  exit 1
fi

SERVER_PUB="$(cat /etc/wireguard/server_public.key)"
# ↑ Публичный ключ сервера из install.sh; попадёт в секцию [Peer] клиента.

# Следующий свободный хост в 10.8.0.0/24 (.1 — сервер)
# ↑ Цикл ищет незанятый последний октет, чтобы не выдать дважды один IP.
NEXT_HOST=2
# ↑ Минимальный номер хоста для клиента (10.8.0.2).
while grep -qE "AllowedIPs = ${CLIENT_BASE_IP//./\\.}\\.${NEXT_HOST}/32" "${CONF_PATH}" 2>/dev/null; do
# ↑ grep -qE тихий поиск по расширенному regex; ${VAR//./\\.} экранирует точки в IP для regex; ищем уже занятый AllowedIPs peer на сервере.
  if [[ "${NEXT_HOST}" -ge 254 ]]; then
    echo "Нет свободных адресов в подсети." >&2
    exit 1
  fi
  NEXT_HOST=$((NEXT_HOST + 1))
# ↑ Арифметика bash: увеличить счётчик хоста.
done

CLIENT_IP="${CLIENT_BASE_IP}.${NEXT_HOST}"
# ↑ Полный адрес клиента в VPN, например 10.8.0.3.

umask 077
# ↑ Новые файлы клиента только для root.
PRIV="$(wg genkey)"
# ↑ Сгенерировать приватный ключ устройства клиента.
PUB="$(echo "${PRIV}" | wg pubkey)"
# ↑ Вычислить публичный ключ из приватного (асимметричная криптография WireGuard).

# Живое добавление без полного рестарта
# ↑ wg set меняет работающий интерфейс без перезапуска всех peer (короче простой).
wg set "${WG_INTERFACE}" peer "${PUB}" allowed-ips "${CLIENT_IP}/32"
# ↑ Добавить peer с публичным ключом; allowed-ips на сервере — только этот /32 (трафик от клиента с этого IP).

# Персистентность в конфиге
# ↑ Дублируем peer в файл, чтобы после reboot wg-quick поднял тех же клиентов.
cat >> "${CONF_PATH}" <<EOF

[Peer]
# ${NAME}
PublicKey = ${PUB}
AllowedIPs = ${CLIENT_IP}/32
EOF
# ↑ Пустая строка перед [Peer] — разделение секций; комментарий # ${NAME} в .conf помечает человека; AllowedIPs на сервере — какие адреса маршрутизировать в туннель к этому peer (/32 один хост).

ENDPOINT="${WG_ENDPOINT:-}"
# ↑ WG_ENDPOINT позволяет задать публичный IP/домен VPS вручную.
if [[ -z "${ENDPOINT}" ]]; then
  ENDPOINT="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || echo 'ВАШ_IP_VPS')"
# ↑ Автоопределение IPv4 сервера через внешний HTTP; плейсхолдер, если curl недоступен.
fi

{
# ↑ Группа команд в подоболочке: перенаправление > применится ко всему выводу блока.
  echo "[Interface]"
# ↑ Начало секции локальных настроек клиента WireGuard.
  echo "PrivateKey = ${PRIV}"
# ↑ Секрет клиента (никому не отправлять).
  echo "Address = ${CLIENT_IP}/32"
# ↑ Адрес клиента внутри VPN (/32 — один хост).
  if [[ "${NO_CLIENT_DNS}" != "1" ]]; then
    echo "DNS = ${CLIENT_DNS}"
# ↑ Опционально: подсказать ОС использовать этот DNS при активном туннеле.
  fi
  echo ""
# ↑ Пустая строка между секциями — читаемость конфига.
  echo "[Peer]"
# ↑ Секция удалённого сервера (peer).
  echo "PublicKey = ${SERVER_PUB}"
# ↑ Публичный ключ сервера для проверки подлинности.
  echo "Endpoint = ${ENDPOINT}:${WG_PORT}"
# ↑ Куда слать зашифрованные UDP-пакеты (IP/домен и порт).
  echo "AllowedIPs = ${CLIENT_ALLOWED_IPS}"
# ↑ На клиенте: маршруты в туннель (split или 0.0.0.0/0).
  echo "PersistentKeepalive = 25"
# ↑ Периодический пакет каждые 25 с — помогает проходить через NAT у провайдера клиента.
} > "${CLIENT_FILE}"
# ↑ Записать сгенерированный конфиг в файл клиента.
chmod 600 "${CLIENT_FILE}"
# ↑ Только root читает файл с приватным ключом.

echo ""
echo "=== Клиент: ${NAME} ==="
echo "Туннель (AllowedIPs у клиента): ${CLIENT_ALLOWED_IPS}"
echo "Файл: ${CLIENT_FILE}"
echo ""
cat "${CLIENT_FILE}"
# ↑ Показать конфиг в терминал для копирования.
echo ""
if command -v qrencode >/dev/null 2>&1; then
# ↑ command -v — найти исполняемый файл qrencode в PATH.
  echo "QR (для WireGuard на телефоне):"
  qrencode -t ansiutf8 < "${CLIENT_FILE}"
# ↑ Сгенерировать QR в символах Unicode для сканирования приложением WireGuard.
fi
