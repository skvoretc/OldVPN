#!/usr/bin/env bash
# ↑ Shebang: первая строка исполняемого файла в Linux; ОС запускает скрипт через /usr/bin/env, который ищет bash в $PATH (переносимость между дистрибутивами).
# WireGuard VPN — установка на VPS (Ubuntu 22.04/24.04, Debian 11/12)
# ↑ Комментарий для человека: назначение файла и целевые ОС (семейство Debian/Ubuntu).
# Запуск: sudo bash install.sh
# ↑ Напоминание: нужны права root (sudo), интерпретатор bash.

set -euo pipefail
# ↑ set -e: выйти из скрипта при первой команде с ненулевым кодом возврата (ошибка).
# ↑ set -u: считать ошибкой обращение к несуществующей переменной (опечатки).
# ↑ set -o pipefail: в конвейере a|b|c код ошибки — от любой упавшей команды, а не только последней.

WG_INTERFACE="${WG_INTERFACE:-wg0}"
# ↑ Имя сетевого интерфейса WireGuard в Linux; ${VAR:-default} подставляет wg0, если переменная WG_INTERFACE не задана.
WG_PORT="${WG_PORT:-51820}"
# ↑ UDP-порт прослушивания; по умолчанию 51820 (стандартный для WireGuard), можно переопределить до запуска: export WG_PORT=443.
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"
# ↑ Подсеть VPN (для справки в скрипте; фактически адреса задаются через VPN_SERVER_IP и /24 в конфиге).
VPN_SERVER_IP="${VPN_SERVER_IP:-10.8.0.1}"
# ↑ Внутренний IPv4-адрес сервера в туннеле; .1 обычно «шлюз» для клиентов 10.8.0.x.

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
# ↑ EUID — effective user id процесса; у root равен 0. $(id -u) — запасной вариант, если EUID пуст.
  echo "Запустите от root: sudo bash $0" >&2
# ↑ echo … >&2 — сообщение в stderr (поток ошибок), не в stdout.
  exit 1
# ↑ exit 1 — ненулевой код: оболочка/CI поймёт, что скрипт завершился с ошибкой.
fi

if [[ -f "/etc/wireguard/${WG_INTERFACE}.conf" ]]; then
# ↑ -f: проверка «это обычный файл»; путь в /etc/wireguard — стандартное место конфигов wg-quick.
  echo "Уже есть /etc/wireguard/${WG_INTERFACE}.conf — удалите вручную или смените WG_INTERFACE." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
# ↑ Отключает интерактивные вопросы apt (важно для автоматизации и контейнеров): пакеты ставятся с настройками по умолчанию.
apt-get update -qq
# ↑ apt-get update — обновить индексы репозиториев; -qq — минимум вывода (quiet).
apt-get install -y wireguard wireguard-tools qrencode iptables
# ↑ install -y — ответ «yes» на подтверждения; wireguard — модуль/метапакет; wireguard-tools — wg, wg-quick; qrencode — QR для клиентов; iptables — NAT и фильтрация.

DEFAULT_IF="$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)"
# ↑ ip -4 route show default — таблица маршрутизации IPv4, строка default via … dev ИМЯ; awk печатает 5-е поле (имя интерфейса, например eth0); head -1 — первая строка; 2>/dev/null скрывает ошибки.
if [[ -z "${DEFAULT_IF}" ]]; then
# ↑ -z — строка пустая (интерфейс не найден, например нет default route).
  echo "Не удалось определить сетевой интерфейс с default route." >&2
  exit 1
fi

umask 077
# ↑ umask 077 — новые файлы создаются без прав для группы и остальных (только владелец), важно для секретных ключей.
install -d -m 700 /etc/wireguard/clients
# ↑ install -d — создать каталог; -m 700 — rwx только для root (владелец).
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
# ↑ wg genkey — сгенерировать приватный ключ Curve25519; tee — записать в файл и передать в stdout; wg pubkey — из приватного получить публичный ключ; перенаправление > в файл публичного ключа.
chmod 600 /etc/wireguard/server_private.key
# ↑ Только владелец читает/пишет приватный ключ (безопасность в многопользовательской системе).

SERVER_PRIV="$(cat /etc/wireguard/server_private.key)"
# ↑ Подстановка содержимого файла в переменную (для вставки в конфиг).
SERVER_PUB="$(cat /etc/wireguard/server_public.key)"
# ↑ Публичный ключ показывается администратору и попадает в конфиги клиентов.

# Включить форвардинг IPv4
# ↑ Комментарий: без ip_forward ядро Linux не пересылает пакеты между интерфейсами (клиенты VPN не выйдут в интернет).
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# ↑ sysctl -w — немедленно установить параметр ядра; net.ipv4.ip_forward=1 разрешает маршрутизацию IPv4.
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.d/99-wireguard.conf 2>/dev/null; then
# ↑ grep -q — тихий режим, только код возврата; если строки нет, создаём постоянную настройку.
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
# ↑ Файл в /etc/sysctl.d применяется при загрузке (персистентность после перезагрузки).
fi
sysctl --system -q 2>/dev/null || true
# ↑ Применить все drop-in sysctl; -q тихо; || true — не ронять скрипт, если часть ключей неизвестна.

# NAT: трафик из VPN наружу через основной интерфейс
# ↑ PostUp/PostDown в wg-quick вызовут iptables при подъёме/опускании интерфейса.
cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
# Сгенерировано install.sh — не публикуйте приватный ключ
[Interface]
Address = ${VPN_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IF} -j MASQUERADE
EOF
# ↑ heredoc <<EOF … EOF — записать многострочный текст в файл; переменные ${…} раскрывает bash до передачи в cat.
# ↑ [Interface] — секция WireGuard для локального интерфейса wg0.
# ↑ Address /24 — адрес сервера и маска подсети VPN.
# ↑ ListenPort — UDP-порт входящих подключений клиентов.
# ↑ PrivateKey — секрет сервера (никому не показывать).
# ↑ PostUp: FORWARD ACCEPT — разрешить пересылку через wg0; POSTROUTING MASQUERADE на $DEFAULT_IF — SNAT: пакеты от клиентов VPN выходят в интернет с IP VPS.
# ↑ PostDown — зеркально удалить правила при остановке интерфейса.

chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"
# ↑ Ограничить чтение конфига с приватным ключом.

# Для локальной проверки в Docker без systemd: WG_SKIP_SYSTEMD=1
# ↑ В контейнере часто нет systemd; тогда поднимаем интерфейс вручную через wg-quick.
if [[ "${WG_SKIP_SYSTEMD:-0}" == "1" ]]; then
  wg-quick up "${WG_INTERFACE}"
# ↑ wg-quick — обёртка: поднимает wg, адреса, вызывает PostUp (iptables).
else
  systemctl enable --now "wg-quick@${WG_INTERFACE}"
# ↑ systemd: enable — автозапуск при загрузке; --now — запустить сразу; шаблон wg-quick@wg0 читает /etc/wireguard/wg0.conf.
fi

PUBLIC_IP="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || true)"
# ↑ curl -4 — только IPv4; -s тихий режим; --max-time — таймаут; || цепочка запасных сервисов; || true — не падать, если сеть недоступна.

echo ""
echo "=== WireGuard установлен ==="
echo "Интерфейс: ${WG_INTERFACE}, порт UDP: ${WG_PORT}"
echo "Внешний интерфейс (NAT): ${DEFAULT_IF}"
echo "Публичный ключ сервера:"
echo "${SERVER_PUB}"
echo ""
if [[ -n "${PUBLIC_IP}" ]]; then
# ↑ -n — строка непустая.
  echo "Похоже, публичный IPv4: ${PUBLIC_IP} (проверьте в панели VPS)."
else
  echo "Не удалось автоопределить публичный IP — укажите Endpoint вручную в конфиге клиента."
fi
echo ""
echo "Добавить клиента: sudo bash $(dirname "$0")/add-client.sh имя_клиента"
# ↑ dirname "$0" — каталог, где лежит текущий скрипт (для подсказки пути к add-client.sh).
echo "Открыть порт в фаерволе (если UFW): sudo ufw allow ${WG_PORT}/udp && sudo ufw reload"
# ↑ Напоминание открыть UDP в ufw на том же порту, что слушает WireGuard.
