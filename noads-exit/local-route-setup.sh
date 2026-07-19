#!/usr/bin/env bash
#
# local-route-setup.sh — запускается на ОСНОВНОМ сервере (где Amnezia + AdGuard).
#
# Настраивает селективный роутинг: трафик VPN-клиентов к доменам YouTube уходит
# через WireGuard-туннель wgnoads (второй VPS в стране без рекламы YouTube),
# весь остальной трафик идёт как раньше.
#
# Как это работает:
#   1. AdGuard Home резолвит все DNS-запросы клиентов. Для доменов YouTube
#      он складывает полученные IP в ipset "youtube" (функция dns.ipset).
#   2. iptables (mangle) маркирует пакеты клиентов к этим IP меткой 0x77.
#   3. Policy routing (ip rule fwmark 0x77 -> table 200) отправляет их в туннель.
#
# Требования:
#   - установлен AdGuard Home (/opt/AdGuardHome) и настроен перехват DNS
#     (setup-amnezia-dns-redirect.sh);
#   - на втором VPS отработал remote-exit-setup.sh, его вывод сохранён в
#     /etc/wireguard/wgnoads.conf.
#
# Запуск:  sudo bash local-route-setup.sh
#
set -euo pipefail

WG_IF="wgnoads"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
BRIDGE_IF="${BRIDGE_IF:-amn0}"       # bridge-интерфейс docker-сети Amnezia
FWMARK="0x77"
RT_TABLE="200"
IPSET4="youtube"
IPSET6="youtube6"
AGH_YAML="${AGH_YAML:-/opt/AdGuardHome/AdGuardHome.yaml}"
YT_DOMAINS="youtube.com,youtu.be,googlevideo.com,ytimg.com,ggpht.com"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }
[[ -f "${WG_CONF}" ]] || { err "Нет ${WG_CONF} — сначала запусти remote-exit-setup.sh на втором VPS и сохрани его вывод сюда."; exit 1; }
[[ -f "${AGH_YAML}" ]] || { err "Не найден ${AGH_YAML} (AdGuard Home). Укажи путь: AGH_YAML=... bash $0"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq wireguard ipset python3-yaml >/dev/null

# --- 1. Конфиг wgnoads: Table=off и PostUp с policy routing --------------------
grep -q '^Table' "${WG_CONF}" || sed -i '/^\[Interface\]/a Table = off' "${WG_CONF}"
if ! grep -q 'fwmark' "${WG_CONF}"; then
  sed -i "/^\[Peer\]/i PostUp = ip rule add fwmark ${FWMARK} table ${RT_TABLE} || true; ip route replace default dev %i table ${RT_TABLE}; sysctl -qw net.ipv4.conf.%i.rp_filter=2 net.ipv4.conf.all.rp_filter=2\nPostDown = ip rule del fwmark ${FWMARK} table ${RT_TABLE} || true\n" "${WG_CONF}"
fi

# --- 2. ipset (создание при загрузке ДО восстановления iptables) --------------
info "Создаю ipset ${IPSET4}/${IPSET6}..."
ipset create "${IPSET4}" hash:ip family inet  -exist
ipset create "${IPSET6}" hash:ip family inet6 -exist
cat > /etc/systemd/system/youtube-ipset.service <<EOF
[Unit]
Description=Create youtube ipsets before firewall restore
Before=netfilter-persistent.service wg-quick@${WG_IF}.service
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ipset create ${IPSET4} hash:ip family inet -exist
ExecStart=/usr/sbin/ipset create ${IPSET6} hash:ip family inet6 -exist
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable youtube-ipset.service >/dev/null 2>&1

# --- 3. AdGuard Home: складывать IP доменов YouTube в ipset -------------------
info "Настраиваю dns.ipset в AdGuard Home..."
python3 - "$AGH_YAML" <<PYEOF
import sys, yaml
path = sys.argv[1]
entry = "${YT_DOMAINS}/${IPSET4},${IPSET6}"
with open(path) as f:
    cfg = yaml.safe_load(f)
dns = cfg.setdefault("dns", {})
cur = dns.get("ipset") or []
if entry not in cur:
    cur.append(entry)
    dns["ipset"] = cur
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False, allow_unicode=True)
    print("  ipset добавлен в конфиг")
else:
    print("  ipset уже настроен")
PYEOF
systemctl restart AdGuardHome

# --- 4. Маркировка пакетов и NAT ----------------------------------------------
info "Ставлю правила маркировки и NAT..."
iptables -t mangle -C PREROUTING -i "${BRIDGE_IF}" -m set --match-set "${IPSET4}" dst -j MARK --set-mark "${FWMARK}" 2>/dev/null || \
  iptables -t mangle -A PREROUTING -i "${BRIDGE_IF}" -m set --match-set "${IPSET4}" dst -j MARK --set-mark "${FWMARK}"
iptables -t nat -C POSTROUTING -o "${WG_IF}" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "${WG_IF}" -j MASQUERADE
iptables -t mangle -C FORWARD -o "${WG_IF}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  iptables -t mangle -A FORWARD -o "${WG_IF}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# --- 5. Поднимаем туннель и сохраняем -----------------------------------------
info "Поднимаю туннель ${WG_IF}..."
systemctl enable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || systemctl restart "wg-quick@${WG_IF}"
command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null

echo
info "Готово! Проверка:"
echo "  1. Туннель жив (должен быть handshake):        wg show ${WG_IF}"
echo "  2. Страна выхода YouTube-трафика:              curl -s --interface ${WG_IF} ipinfo.io"
echo "  3. Открой пару роликов с клиента, затем:       ipset list ${IPSET4} | head -20"
echo "     (в списке должны появиться IP; значит DNS->ipset работает)"
echo "  4. На клиенте зайди на youtube.com БЕЗ логина и открой популярный ролик."
