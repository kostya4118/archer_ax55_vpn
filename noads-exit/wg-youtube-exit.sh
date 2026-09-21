#!/usr/bin/env bash
#
# wg-youtube-exit.sh — пустить YouTube-трафик через готовый WireGuard-сервер
# (например, в России) вместо VLESS/Shadowsocks-прокси.
#
# Идея: WireGuard — полноценный сетевой интерфейс, поэтому схема проще, чем с
# VLESS:
#   1. Поднимаем WG-конфиг как интерфейс wgru, но с "Table = off" — он НЕ
#      перехватывает маршруты сервера, просто висит поднятым.
#   2. sing-box остаётся только "определителем домена": по SNI в TLS/QUIC он
#      видит ютуб-домены и отправляет их в outbound, привязанный к wgru
#      (bind_interface), а весь остальной трафик — в обычный direct.
#
# Почему не через "wireguard endpoint" внутри sing-box: схема WG-аутбаунда в
# sing-box за последние версии переезжала (outbound -> endpoints) и ломается
# между версиями. bind_interface — стабильное поле, общее для всех аутбаундов,
# а сам WireGuard ведёт обычный wg-quick, который легко чинить и смотреть
# через "wg show".
#
# ВАЖНО: скрипт сам читает .conf на сервере — приватный ключ никуда не уходит.
# Из конфига удаляется строка DNS=, чтобы wg-quick не переписал резолвер
# сервера (иначе ломается DNS у всех клиентов).
#
# Запуск:
#   sudo bash wg-youtube-exit.sh /root/russia.conf
#
set -euo pipefail

WG_IF="${WG_IF:-wgru}"
TUN_IF="${TUN_IF:-singbox0}"
TUN_ADDR="${TUN_ADDR:-172.19.0.1/30}"
TUN_MTU="${TUN_MTU:-1400}"
FWMARK="${FWMARK:-0x77}"
RT_TABLE="${RT_TABLE:-200}"
BRIDGE_IF="${BRIDGE_IF:-amn0}"
CONF_DIR="/etc/sing-box"
ROUTE_UP="/usr/local/sbin/noads-route-up.sh"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo:  sudo bash $0 /путь/к/конфигу.conf"; exit 1; }

SRC_CONF="${1:-}"
if [[ -z "${SRC_CONF}" ]]; then
  err "Не передан путь к WireGuard-конфигу."
  echo "  sudo bash $0 /root/russia.conf"
  exit 1
fi
[[ -f "${SRC_CONF}" ]] || { err "Файл не найден: ${SRC_CONF}"; exit 1; }
grep -q '^\[Interface\]' "${SRC_CONF}" || { err "Это не похоже на WireGuard-конфиг (нет [Interface])."; exit 1; }

# --- 1. Ставим wireguard, если нужно -----------------------------------------
if ! command -v wg-quick >/dev/null 2>&1; then
  info "Устанавливаю wireguard..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq wireguard >/dev/null
fi

# --- 2. Готовим конфиг интерфейса --------------------------------------------
info "Готовлю /etc/wireguard/${WG_IF}.conf ..."
umask 077
mkdir -p /etc/wireguard

# DNS= убираем: wg-quick иначе перепишет резолвер сервера через resolvconf
# и положит DNS всем VPN-клиентам. Table=off — чтобы не трогал маршруты.
# Пишем через временный файл: источником может быть сам /etc/wireguard/<if>.conf,
# и прямое перенаправление обнулило бы его до того, как awk успеет прочитать.
TMP_CONF="$(mktemp)"
awk '
  /^[[:space:]]*DNS[[:space:]]*=/  { next }
  /^[[:space:]]*Table[[:space:]]*=/ { next }
  { print }
  /^\[Interface\][[:space:]]*$/    { print "Table = off" }
' "${SRC_CONF}" > "${TMP_CONF}"

if ! grep -q '^Table = off' "${TMP_CONF}"; then
  rm -f "${TMP_CONF}"
  err "Не удалось вставить 'Table = off' — проверь формат конфига"
  err "(нужна строка [Interface] на отдельной строке)."
  exit 1
fi
mv -f "${TMP_CONF}" "/etc/wireguard/${WG_IF}.conf"

chmod 600 "/etc/wireguard/${WG_IF}.conf"

# --- 3. Поднимаем интерфейс ---------------------------------------------------
info "Поднимаю интерфейс ${WG_IF}..."
systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
systemctl restart "wg-quick@${WG_IF}"
sleep 2

if ! ip link show "${WG_IF}" >/dev/null 2>&1; then
  err "Интерфейс ${WG_IF} не поднялся. Логи:  journalctl -u wg-quick@${WG_IF} -n 30 --no-pager"
  exit 1
fi

# Проверяем, что handshake вообще случился
HS="$(wg show "${WG_IF}" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1 || echo 0)"
if [[ "${HS:-0}" == "0" ]]; then
  warn "Handshake с WG-сервером пока не состоялся — возможно, нужно пару секунд,"
  warn "либо сервер недоступен. Проверить:  wg show ${WG_IF}"
fi

# --- 3a. Подбираем рабочий MTU ------------------------------------------------
# Туннели вложенные (клиент -> Amnezia -> singbox0 -> wgru), заголовки
# складываются. Если MTU интерфейса больше реально проходящего, крупные пакеты
# молча теряются — соединение живое, но видео буферизует. Поэтому меряем
# фактический предел пингом с запретом фрагментации и ставим его с запасом.
info "Подбираю рабочий MTU для ${WG_IF}..."
BEST_PAYLOAD=0
for SIZE in 1212 1252 1292 1332 1372 1412 1452; do
  if ping -M do -s "${SIZE}" -c 1 -W 2 -I "${WG_IF}" 1.1.1.1 >/dev/null 2>&1; then
    BEST_PAYLOAD="${SIZE}"
  else
    break
  fi
done

if [[ "${BEST_PAYLOAD}" -gt 0 ]]; then
  # payload + 8 (ICMP) + 20 (IP) = рабочий MTU; минус 20 байт запаса на то,
  # что путь до Google может оказаться чуть уже, чем до 1.1.1.1
  SAFE_MTU=$(( BEST_PAYLOAD + 28 - 20 ))
  info "Максимум проходит $(( BEST_PAYLOAD + 28 )), ставлю ${SAFE_MTU} (с запасом)."
  ip link set "${WG_IF}" mtu "${SAFE_MTU}" 2>/dev/null || warn "Не удалось применить MTU на лету."
  # Закрепляем в конфиге, чтобы пережило перезапуск
  if grep -qE '^[[:space:]]*MTU[[:space:]]*=' "/etc/wireguard/${WG_IF}.conf"; then
    sed -i "s/^[[:space:]]*MTU[[:space:]]*=.*/MTU = ${SAFE_MTU}/" "/etc/wireguard/${WG_IF}.conf"
  else
    sed -i "/^\[Interface\]/a MTU = ${SAFE_MTU}" "/etc/wireguard/${WG_IF}.conf"
  fi
else
  warn "Не удалось измерить MTU (ICMP закрыт?) — оставляю как есть."
  warn "Если видео будет буферизовать, попробуй вручную: ip link set ${WG_IF} mtu 1380"
fi

# --- 4. Ставим sing-box, если нужно ------------------------------------------
if ! command -v sing-box >/dev/null 2>&1; then
  info "Устанавливаю sing-box..."
  curl -fsSL https://sing-box.app/install.sh | sh
fi
command -v sing-box >/dev/null 2>&1 || { err "sing-box не установился"; exit 1; }

# --- 5. Генерируем конфиг sing-box -------------------------------------------
info "Генерирую конфиг sing-box (ютуб -> ${WG_IF}, остальное -> напрямую)..."
mkdir -p "${CONF_DIR}"
NEW_CONF="${CONF_DIR}/config.json.new"
python3 - "${NEW_CONF}" "${TUN_IF}" "${TUN_ADDR}" "${TUN_MTU}" "${WG_IF}" <<'PYEOF'
import json, os, sys

out_path, tun_if, tun_addr, tun_mtu, wg_if = sys.argv[1:6]

YOUTUBE_DOMAINS = [
    "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com",
    "ggpht.com", "youtubei.googleapis.com", "youtube.googleapis.com",
    "youtube-nocookie.com",
]

cfg = {
    "log": {"level": "warn", "timestamp": True},
    "inbounds": [{
        "type": "tun",
        "tag": "tun-in",
        "interface_name": tun_if,
        "address": [tun_addr],
        "mtu": int(tun_mtu),
        # auto_route=false — маршрутизацией управляем сами (fwmark + table),
        # иначе sing-box перехватил бы весь трафик сервера.
        "auto_route": False,
        "strict_route": False,
        "stack": "system"
    }, {
        "type": "socks",
        "tag": "socks-test",
        "listen": "127.0.0.1",
        "listen_port": 1080
    }],
    "outbounds": [
        # Ютуб: обычный direct, но прибитый к WG-интерфейсу — пакеты уходят
        # в туннель и вылезают уже на WG-сервере.
        {"type": "direct", "tag": "wg-out", "bind_interface": wg_if},
        # Всё остальное — как будто прокси нет вообще.
        {"type": "direct", "tag": "direct-out"},
    ],
    "route": {
        "rules": [
            # sniff — смотрит SNI в TLS ClientHello / QUIC, без всякого DNS,
            # чтобы следующее правило могло матчить по домену.
            {"action": "sniff"},
            {"domain_suffix": YOUTUBE_DOMAINS, "outbound": "wg-out"}
        ],
        "final": "direct-out",
        "auto_detect_interface": True
    }
}
# Публичные инбаунды прокси (proxy-server.sh) лежат отдельным фрагментом,
# чтобы переживать перегенерацию конфига при смене ключа/выхода.
# Файл намеренно ВНЕ /etc/sing-box: служба стартует с "-C /etc/sing-box" и
# читает оттуда все .json как части конфига — посторонний файл там роняет
# запуск. Старые версии клали его туда, поэтому заодно переносим.
_legacy = ["/etc/sing-box/proxy-server.json", "/etc/sing-box/socks-server.json"]
_frag = "/etc/noads-proxy.json"
for _old in _legacy:
    if os.path.exists(_old):
        if not os.path.exists(_frag):
            os.replace(_old, _frag)
        else:
            os.remove(_old)

if os.path.exists(_frag):
    try:
        _ib = json.load(open(_frag))
        cfg["inbounds"].extend(_ib if isinstance(_ib, list) else [_ib])
    except Exception as e:
        print(f"  (фрагмент прокси пропущен: {e})")

with open(out_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"  выход ютуба : интерфейс {wg_if}")
print(f"  домены      : {', '.join(YOUTUBE_DOMAINS)}")
PYEOF

if ! sing-box check -c "${NEW_CONF}"; then
  err "sing-box забраковал конфиг — боевой конфиг не тронут, служба работает как раньше."
  rm -f "${NEW_CONF}"
  exit 1
fi
info "Конфиг валиден."
mv -f "${NEW_CONF}" "${CONF_DIR}/config.json"

# --- 6-7. Хелпер policy routing (вызывается systemd после старта sing-box) ----
# Все правила netfilter ставит именно хелпер, а не этот скрипт напрямую: тогда
# они восстанавливаются при каждом старте sing-box — после перезагрузки, после
# `iptables -F`, после рестарта Docker. Сохранять их через netfilter-persistent
# не нужно и даже вредно: сохранённая копия тащит за собой правила Docker,
# которые при загрузке накатываются раньше самого Docker.
info "Готовлю хелпер маршрутизации и маркировки (${BRIDGE_IF} -> ${TUN_IF})..."
cat > "${ROUTE_UP}" <<EOF
#!/usr/bin/env bash
set -eu
TUN_IF="${TUN_IF}"; FWMARK="${FWMARK}"; RT_TABLE="${RT_TABLE}"; BRIDGE_IF="${BRIDGE_IF}"
for _ in \$(seq 1 60); do
  ip link show "\${TUN_IF}" >/dev/null 2>&1 && break
  sleep 0.25
done
# Интерфейса нет — значит, в конфиге больше нет tun-inbound'а (роутинг отключали,
# а drop-in остался). Выходим спокойно: иначе ExecStartPost уронит всю службу и
# вместе с ней всё остальное, что крутится на этом sing-box.
if ! ip link show "\${TUN_IF}" >/dev/null 2>&1; then
  echo "Интерфейса \${TUN_IF} нет — маршрутизацию пропускаю."
  exit 0
fi
ip rule show | grep -q "fwmark \${FWMARK} lookup \${RT_TABLE}" || \\
  ip rule add fwmark "\${FWMARK}" table "\${RT_TABLE}"
ip route replace default dev "\${TUN_IF}" table "\${RT_TABLE}"
sysctl -qw net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
sysctl -qw "net.ipv4.conf.\${TUN_IF}.rp_filter=2" 2>/dev/null || true
iptables -C FORWARD -o "\${TUN_IF}" -j ACCEPT 2>/dev/null || iptables -I FORWARD -o "\${TUN_IF}" -j ACCEPT
iptables -C FORWARD -i "\${TUN_IF}" -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "\${TUN_IF}" -j ACCEPT
# Маркировка HTTPS/QUIC от VPN-клиентов: по метке трафик уходит в таблицу \${RT_TABLE}.
# Моста может не быть вовсе — например, на сервере без Amnezia, где sing-box нужен
# только под прокси. Тогда маркировать нечего, и это не ошибка.
if ip link show "\${BRIDGE_IF}" >/dev/null 2>&1; then
  for _proto in tcp udp; do
    iptables -t mangle -C PREROUTING -i "\${BRIDGE_IF}" -p "\${_proto}" --dport 443 -j MARK --set-mark "\${FWMARK}" 2>/dev/null || \\
      iptables -t mangle -A PREROUTING -i "\${BRIDGE_IF}" -p "\${_proto}" --dport 443 -j MARK --set-mark "\${FWMARK}"
  done
else
  echo "Моста \${BRIDGE_IF} нет — маркировку клиентского трафика пропускаю."
fi
EOF
chmod +x "${ROUTE_UP}"

mkdir -p /etc/systemd/system/sing-box.service.d
cat > /etc/systemd/system/sing-box.service.d/noads-route.conf <<EOF
[Service]
# Префикс "+" — выполнить с полными правами, игнорируя User= юнита. Свежие
# пакеты sing-box гоняют службу под отдельным пользователем sing-box, а
# хелперу нужны root-права на ip rule / iptables (иначе 203/EXEC).
ExecStartPost=+${ROUTE_UP}
EOF

# --- 8. Запускаем -------------------------------------------------------------
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box
sleep 3

if ! systemctl is-active --quiet sing-box; then
  err "sing-box не запустился. Логи:  journalctl -u sing-box -n 40 --no-pager -l"
  exit 1
fi

# netfilter-persistent здесь намеренно НЕ вызывается: правила ставит хелпер при
# старте службы. Сохранённая копия /etc/iptables/rules.v4 захватила бы правила
# Docker и после перезагрузки накатилась бы раньше него — это ломает сеть
# контейнеров, а в худшем случае закрывает доступ на сервер.

# --- 9. Проверка --------------------------------------------------------------
echo
info "Проверяю, куда выходит трафик через ${WG_IF}..."
EXIT_INFO="$(curl -s --interface "${WG_IF}" --max-time 10 https://ipinfo.io/json 2>/dev/null || true)"
if [[ -n "${EXIT_INFO}" ]]; then
  echo "${EXIT_INFO}" | grep -E '"(ip|city|country|org)"' || echo "${EXIT_INFO}"
else
  warn "Не удалось получить ответ через ${WG_IF} — проверь handshake: wg show ${WG_IF}"
fi

echo
echo "${BLD}Готово.${RST} Домены ютуба уходят через WireGuard (${WG_IF}), остальное — напрямую."
echo
echo "Проверки:"
echo "  wg show ${WG_IF}                                  # handshake и трафик"
echo "  curl -s --interface ${WG_IF} https://ipinfo.io    # страна выхода ютуба"
echo "  journalctl -u sing-box -n 20 --no-pager -l        # ошибки маршрутизации"
echo
echo "Выключить перенаправление:"
echo "  sudo bash noads-exit/disable-youtube-routing.sh && sudo systemctl disable --now wg-quick@${WG_IF}"
