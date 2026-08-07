#!/usr/bin/env bash
#
# vless-youtube-exit.sh — пустить YouTube-трафик через VLESS-ключ вместо
# отдельного VPS (замена wgnoads).
#
# Идея: VLESS — прокси-протокол, его нельзя напрямую подставить в маршрут.
# Поэтому поднимаем sing-box с TUN-инбаундом: он создаёт интерфейс singbox0,
# всё попавшее туда уходит в VLESS. Существующая схема
#   AdGuard(dns.ipset) -> ipset youtube -> iptables MARK -> ip rule fwmark
# остаётся без изменений, меняется только устройство в таблице 200.
#
# Требуется: уже отработавший local-route-setup.sh (ipset + маркировка).
#
# Запуск:
#   sudo bash vless-youtube-exit.sh 'vless://UUID@host:443?security=reality&...'
# Ключ можно передать и переменной:
#   sudo VLESS_URL='vless://...' bash vless-youtube-exit.sh
#
set -euo pipefail

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

VLESS_URL="${1:-${VLESS_URL:-}}"
if [[ -z "${VLESS_URL}" ]]; then
  err "Не передан VLESS-ключ."
  echo "  sudo bash $0 'vless://UUID@host:443?security=reality&pbk=...&sni=...'"
  exit 1
fi
[[ "${VLESS_URL}" == vless://* ]] || { err "Ключ должен начинаться с vless://"; exit 1; }

# --- 1. Проверяем, что базовая схема уже настроена ---------------------------
if ! ipset list youtube >/dev/null 2>&1; then
  err "Нет ipset 'youtube' — сначала запусти noads-exit/local-route-setup.sh"
  exit 1
fi

# --- 2. Ставим sing-box ------------------------------------------------------
if ! command -v sing-box >/dev/null 2>&1; then
  info "Устанавливаю sing-box..."
  curl -fsSL https://sing-box.app/install.sh | sh
fi
command -v sing-box >/dev/null 2>&1 || { err "sing-box не установился"; exit 1; }

# --- 3. Генерируем конфиг из vless:// ---------------------------------------
info "Разбираю VLESS-ключ и генерирую конфиг..."
mkdir -p "${CONF_DIR}"
python3 - "${VLESS_URL}" "${CONF_DIR}/config.json" "${TUN_IF}" "${TUN_ADDR}" "${TUN_MTU}" <<'PYEOF'
import json, re, sys, urllib.parse as up

url, out_path, tun_if, tun_addr, tun_mtu = sys.argv[1:6]
u = up.urlparse(url)
uuid = up.unquote(u.username or "")
host, port = u.hostname, u.port or 443
if not uuid or not host:
    sys.exit("Не удалось разобрать ключ: нет UUID или адреса сервера")
q = dict(up.parse_qsl(u.query))

# path вытаскиваем регуляркой, а не через parse_qsl: в ключах он часто записан
# незакодированным (path=/?ed=2560), и разбор query-строки обрубил бы его на "/".
_m = re.search(r'(?:^|&)path=([^&]*)', u.query)
path = up.unquote(_m.group(1)) if _m else "/"

sec = q.get("security", "none")
net = q.get("type", "tcp")
if net in ("xhttp", "splithttp"):
    sys.exit("Транспорт xhttp/splithttp умеет только xray-core, sing-box — нет.\n"
             "Нужен другой ключ или связка на базе xray.")

ob = {"type": "vless", "tag": "vless-out",
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

if net == "ws":
    tr = {"type": "ws", "path": path}
    if q.get("host"):
        tr["headers"] = {"Host": q["host"]}
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
    if q.get("host"):
        tr["host"] = q["host"]
    ob["transport"] = tr

cfg = {
    "log": {"level": "warn", "timestamp": True},
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
    "outbounds": [ob],
    "route": {"final": "vless-out", "auto_detect_interface": True}
}
with open(out_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"  сервер   : {host}:{port}")
print(f"  security : {sec}, transport: {net}")
PYEOF

sing-box check -c "${CONF_DIR}/config.json" || { err "sing-box забраковал конфиг"; exit 1; }
info "Конфиг валиден."

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

echo
echo "${BLD}Готово.${RST} YouTube-трафик уходит через VLESS."
echo
echo "Проверки:"
echo "  systemctl status sing-box --no-pager"
echo "  ip route show table ${RT_TABLE}          # default dev ${TUN_IF}"
echo "  curl -s --socks5 127.0.0.1:1080 ipinfo.io  # страна выхода VLESS"
echo
echo "Откат на албанский туннель:"
echo "  systemctl disable --now sing-box && systemctl enable --now wg-quick@wgnoads"
