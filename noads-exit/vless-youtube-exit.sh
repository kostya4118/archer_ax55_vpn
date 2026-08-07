#!/usr/bin/env bash
#
# vless-youtube-exit.sh — пустить YouTube-трафик через готовый ключ (VLESS или
# Shadowsocks/Outline), без AdGuard и без ipset.
#
# Идея: и VLESS, и Shadowsocks — прокси-протоколы, их нельзя напрямую
# подставить в таблицу маршрутизации. Поэтому поднимаем sing-box с
# TUN-инбаундом (singbox0). В tun заворачивается весь HTTPS/QUIC-трафик
# VPN-клиентов (порт 443, tcp+udp) через iptables mark + policy routing.
# Дальше решение "это ютуб или нет" принимает САМ sing-box: он смотрит SNI
# в TLS ClientHello / QUIC (без всякого DNS) и по domain_suffix отправляет
# совпавшее в прокси (VLESS/SS), а всё остальное — обычным путём напрямую
# (outbound "direct-out", идёт как будто прокси вообще нет).
#
# Раньше это делалось через AdGuard (dns.ipset -> ipset -> iptables MARK по
# IP) — но так пропадает надобность в AdGuard целиком: он был не нужен для
# самой схемы, только для наполнения списка IP.
#
# Запуск:
#   sudo bash vless-youtube-exit.sh 'vless://UUID@host:443?security=reality&...'
#   sudo bash vless-youtube-exit.sh 'ss://BASE64@host:port#Outline-key'
# Ключ можно передать и переменной:
#   sudo PROXY_URL='vless://...' bash vless-youtube-exit.sh
#
set -euo pipefail

# Заголовок Host для ws/httpupgrade (VLESS). Нужен, когда сервер за
# CDN/реверс-прокси и в ключе нет параметра host= (симптом: "unexpected HTTP
# response status: 404").
VLESS_HOST="${VLESS_HOST:-}"
TUN_IF="${TUN_IF:-singbox0}"
TUN_ADDR="${TUN_ADDR:-172.19.0.1/30}"
TUN_MTU="${TUN_MTU:-1400}"
FWMARK="${FWMARK:-0x77}"
RT_TABLE="${RT_TABLE:-200}"
CONF_DIR="/etc/sing-box"
ROUTE_UP="/usr/local/sbin/noads-route-up.sh"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }

PROXY_URL="${1:-${PROXY_URL:-${VLESS_URL:-}}}"
if [[ -z "${PROXY_URL}" ]]; then
  err "Не передан ключ."
  echo "  sudo bash $0 'vless://UUID@host:443?security=reality&pbk=...&sni=...'"
  echo "  sudo bash $0 'ss://BASE64@host:port#Outline-key'"
  exit 1
fi
case "${PROXY_URL}" in
  vless://*|ss://*) ;;
  *) err "Ключ должен начинаться с vless:// или ss://"; exit 1 ;;
esac

# --- 1. Ставим sing-box ------------------------------------------------------
if ! command -v sing-box >/dev/null 2>&1; then
  info "Устанавливаю sing-box..."
  curl -fsSL https://sing-box.app/install.sh | sh
fi
command -v sing-box >/dev/null 2>&1 || { err "sing-box не установился"; exit 1; }

# --- 2. Генерируем конфиг из ключа -------------------------------------------
info "Разбираю ключ и генерирую конфиг..."
mkdir -p "${CONF_DIR}"
python3 - "${PROXY_URL}" "${CONF_DIR}/config.json" "${TUN_IF}" "${TUN_ADDR}" "${TUN_MTU}" "${VLESS_HOST}" <<'PYEOF'
import base64, json, re, sys, urllib.parse as up

url, out_path, tun_if, tun_addr, tun_mtu, host_override = sys.argv[1:7]

def b64pad(s: str) -> str:
    return s + "=" * (-len(s) % 4)

def b64decode(s: str) -> bytes:
    for fn in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            return fn(b64pad(s))
        except Exception:
            continue
    raise ValueError(f"не удалось декодировать base64: {s!r}")

if url.startswith("vless://"):
    u = up.urlparse(url)
    uuid = up.unquote(u.username or "")
    host, port = u.hostname, u.port or 443
    if not uuid or not host:
        sys.exit("Не удалось разобрать ключ: нет UUID или адреса сервера")
    q = dict(up.parse_qsl(u.query))

    # path вытаскиваем регуляркой, а не через parse_qsl: в ключах он часто
    # записан незакодированным (path=/?ed=2560), и разбор query-строки
    # обрубил бы его на "/".
    _m = re.search(r'(?:^|&)path=([^&]*)', u.query)
    path = up.unquote(_m.group(1)) if _m else "/"

    sec = q.get("security", "none")
    net = q.get("type", "tcp")
    if net in ("xhttp", "splithttp"):
        sys.exit("Транспорт xhttp/splithttp умеет только xray-core, sing-box — нет.\n"
                 "Нужен другой ключ или связка на базе xray.")

    ob = {"type": "vless", "tag": "proxy-out",
          "server": host, "server_port": int(port), "uuid": uuid}
    if q.get("flow"):
        ob["flow"] = q["flow"]
    if q.get("encryption") and q["encryption"] != "none":
        ob["encryption"] = q["encryption"]

    if sec in ("tls", "reality", "xtls"):
        tls = {"enabled": True, "server_name": q.get("sni") or q.get("host") or host}
        if q.get("fp"):
            tls["utls"] = {"enabled": True, "fingerprint": q["fp"]}
        if q.get("alpn"):
            tls["alpn"] = q["alpn"].split(",")
        if sec == "reality":
            tls["reality"] = {"enabled": True,
                              "public_key": q.get("pbk", ""),
                              "short_id": q.get("sid", "")}
        if q.get("allowInsecure") in ("1", "true"):
            tls["insecure"] = True
        ob["tls"] = tls

    ws_host = host_override or q.get("host")
    if net == "ws":
        tr = {"type": "ws", "path": path}
        if ws_host:
            tr["headers"] = {"Host": ws_host}
        # ?ed=N — ранние данные (V2Ray early data), sing-box задаёт их отдельно
        _ed = re.search(r'[?&]ed=(\d+)', path)
        if _ed:
            tr["path"] = path.split("?")[0]
            tr["max_early_data"] = int(_ed.group(1))
            tr["early_data_header_name"] = "Sec-WebSocket-Protocol"
        ob["transport"] = tr
    elif net == "grpc":
        ob["transport"] = {"type": "grpc", "service_name": q.get("serviceName", "")}
    elif net == "httpupgrade":
        tr = {"type": "httpupgrade", "path": path}
        if ws_host:
            tr["host"] = ws_host
        ob["transport"] = tr

    summary = f"  сервер   : {host}:{port}\n  security : {sec}, transport: {net}"

elif url.startswith("ss://"):
    raw = url[len("ss://"):]
    frag = ""
    if "#" in raw:
        raw, frag = raw.split("#", 1)
    query = ""
    if "?" in raw:
        raw, query = raw.split("?", 1)
    q = dict(up.parse_qsl(query))

    if "@" in raw:
        # SIP002: ss://BASE64(method:password)@host:port  (userinfo может
        # быть percent-encoded base64, реже — уже "method:password" открытым
        # текстом).
        userinfo, hostport = raw.rsplit("@", 1)
        userinfo = up.unquote(userinfo)
        if ":" in userinfo:
            method, password = userinfo.split(":", 1)
        else:
            method, password = b64decode(userinfo).decode().split(":", 1)
    else:
        # Legacy: ss://BASE64(method:password@host:port)
        decoded = b64decode(raw).decode()
        methodpass, hostport = decoded.rsplit("@", 1)
        method, password = methodpass.split(":", 1)

    host, _, port_s = hostport.rpartition(":")
    if not host or not port_s:
        sys.exit(f"Не удалось разобрать host:port из {hostport!r}")
    port = int(port_s)

    if q.get("plugin"):
        sys.exit(f"Ключ использует plugin={q['plugin']!r} (obfs/v2ray-plugin) — "
                 "sing-box такое напрямую не поддерживает без внешнего бинаря плагина.\n"
                 "Попробуй ключ без plugin, либо это придётся ставить отдельно.")

    ob = {"type": "shadowsocks", "tag": "proxy-out",
          "server": host, "server_port": port,
          "method": method, "password": password}

    summary = f"  сервер   : {host}:{port}\n  метод    : {method}"

else:
    sys.exit("Неизвестная схема ключа")

YOUTUBE_DOMAINS = [
    "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com",
    "ggpht.com", "youtubei.googleapis.com", "youtube.googleapis.com",
    "youtube-nocookie.com",
]

cfg = {
    "log": {"level": "warn", "timestamp": True},
    # Блок "dns" намеренно не добавляем: outbound задан голым IP (не доменом),
    # а домен для route.rules sing-box берёт из sniffing SNI/QUIC прямо в
    # TLS-пакете — резолвить самому ему нечего. Старый формат DNS-блока
    # ("address": ...) с sing-box 1.12+ вообще не принимается без
    # ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true, а новый тут не нужен.
    "inbounds": [{
        "type": "tun",
        "tag": "tun-in",
        "interface_name": tun_if,
        "address": [tun_addr],
        "mtu": int(tun_mtu),
        # auto_route=false — маршрутизацией управляем мы сами (fwmark + table),
        # иначе sing-box перехватил бы весь трафик сервера.
        "auto_route": False,
        "strict_route": False,
        "stack": "system"
    }, {
        # Только для проверки страны выхода: curl --socks5 127.0.0.1:1080 ipinfo.io
        # Слушает localhost, снаружи недоступен.
        "type": "socks",
        "tag": "socks-test",
        "listen": "127.0.0.1",
        "listen_port": 1080
    }],
    "outbounds": [ob, {"type": "direct", "tag": "direct-out"}],
    "route": {
        "rules": [
            # sniff (было полем инбаунда до sing-box 1.11, теперь — action
            # правила) смотрит SNI в TLS ClientHello / QUIC без всякого DNS,
            # чтобы следующее правило могло матчить по домену.
            {"action": "sniff"},
            {"domain_suffix": YOUTUBE_DOMAINS, "outbound": "proxy-out"}
        ],
        # Всё, что не совпало с youtube-доменами, уходит напрямую — как будто
        # прокси вообще нет. Если прокси недоступен, ломается только ютуб,
        # а не весь интернет клиентов.
        "final": "direct-out",
        "auto_detect_interface": True
    }
}
with open(out_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(summary)
print(f"  домены   : {', '.join(YOUTUBE_DOMAINS)}")
PYEOF

sing-box check -c "${CONF_DIR}/config.json" || { err "sing-box забраковал конфиг"; exit 1; }
info "Конфиг валиден."

# --- 3. Заворачиваем HTTPS/QUIC (443) от VPN-клиентов в tun sing-box ---------
# Раньше матчили по ipset (наполнял AdGuard); теперь AdGuard не нужен —
# в tun идёт весь трафик 443 от amn0, а домен смотрит сам sing-box через
# sniffing (см. выше). Остальные порты (в т.ч. DNS) tun не касаются.
info "Настраиваю маркировку HTTPS/QUIC-трафика от VPN-клиентов (amn0)..."
BRIDGE_IF="${BRIDGE_IF:-amn0}"
for proto in tcp udp; do
  iptables -t mangle -C PREROUTING -i "${BRIDGE_IF}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}" 2>/dev/null || \
    iptables -t mangle -A PREROUTING -i "${BRIDGE_IF}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}"
done

# --- 4. Хелпер: поднять маршрут после старта sing-box ------------------------
cat > "${ROUTE_UP}" <<EOF
#!/usr/bin/env bash
# Ставит policy routing на tun-интерфейс sing-box (вызывается из systemd).
set -eu
TUN_IF="${TUN_IF}"; FWMARK="${FWMARK}"; RT_TABLE="${RT_TABLE}"
for _ in \$(seq 1 60); do
  ip link show "\${TUN_IF}" >/dev/null 2>&1 && break
  sleep 0.25
done
ip rule show | grep -q "fwmark \${FWMARK} lookup \${RT_TABLE}" || \\
  ip rule add fwmark "\${FWMARK}" table "\${RT_TABLE}"
ip route replace default dev "\${TUN_IF}" table "\${RT_TABLE}"
sysctl -qw net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
sysctl -qw "net.ipv4.conf.\${TUN_IF}.rp_filter=2" 2>/dev/null || true
iptables -C FORWARD -o "\${TUN_IF}" -j ACCEPT 2>/dev/null || iptables -I FORWARD -o "\${TUN_IF}" -j ACCEPT
iptables -C FORWARD -i "\${TUN_IF}" -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "\${TUN_IF}" -j ACCEPT
EOF
chmod +x "${ROUTE_UP}"

mkdir -p /etc/systemd/system/sing-box.service.d
cat > /etc/systemd/system/sing-box.service.d/noads-route.conf <<EOF
[Service]
ExecStartPost=${ROUTE_UP}
EOF

# --- 5. Отключаем албанский туннель (конфиг остаётся для отката) -------------
if systemctl is-active --quiet wg-quick@wgnoads 2>/dev/null; then
  warn "Останавливаю wg-quick@wgnoads (конфиг сохраняется, откат возможен)."
  systemctl disable --now wg-quick@wgnoads >/dev/null 2>&1 || true
fi

# --- 6. Запускаем ------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now sing-box
sleep 2
systemctl restart sing-box
sleep 2

if ! systemctl is-active --quiet sing-box; then
  err "sing-box не запустился. Логи:  journalctl -u sing-box -n 40 --no-pager"
  exit 1
fi

command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null || true

echo
echo "${BLD}Готово.${RST} Домены ютуба уходят через прокси, остальной HTTPS — напрямую."
echo "AdGuard для этого не нужен — sing-box сам смотрит SNI и решает маршрут."
echo
echo "Проверки:"
echo "  systemctl status sing-box --no-pager"
echo "  ip route show table ${RT_TABLE}          # default dev ${TUN_IF}"
echo "  curl -s --socks5 127.0.0.1:1080 ipinfo.io  # страна выхода"
echo "  journalctl -u sing-box -n 20 --no-pager    # ошибки подключения к прокси"
echo
echo "Откат (выключить youtube-роутинг совсем):"
echo "  systemctl disable --now sing-box"
