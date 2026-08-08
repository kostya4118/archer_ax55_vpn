#!/usr/bin/env bash
#
# route-dante-output.sh — заворачивает исходящий HTTPS/QUIC-трафик локального
# SOCKS-прокси (Dante и т.п.) в тот же no-ads-туннель, что и VPN-клиенты.
#
# Зачем отдельный скрипт: основная маркировка в local-route-setup.sh /
# vless-youtube-exit.sh матчит трафик в цепочке PREROUTING по входящему
# интерфейсу amn0 (VPN-клиенты, транзитный трафик). Но Dante — процесс НА
# САМОМ сервере: его исходящие соединения генерируются локально и идут через
# цепочку OUTPUT, которую та маркировка не видит.
#
# Просто помечать в OUTPUT весь порт 443 — рискованно: заденет HTTPS-трафик
# самого сервера (git, apt, curl и т.д.), перепутает его с sing-box и может
# привести к тем же проблемам, что были с AdGuard при перезапусках sing-box.
# Поэтому матчим узко — по владельцу сокета (--uid-owner), под которым
# реально работают воркеры Dante (обычно "nobody" — проверь:
#   ps -eo pid,user,cmd | grep danted
#   grep -i '^\s*user\.' /etc/danted.conf   # user.notprivileged
# ).
#
# Запуск:  sudo bash route-dante-output.sh [uid_owner]
#          sudo bash route-dante-output.sh nobody
#
set -euo pipefail

FWMARK="${FWMARK:-0x77}"
OWNER="${1:-nobody}"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }

[[ "${EUID}" -ne 0 ]] && { echo "Запусти с sudo:  sudo bash $0 [uid_owner]"; exit 1; }

# Предупреждаем, если под этим пользователем работает что-то ещё — маркировка
# заденет и его тоже.
OTHER="$(ps -eo user,comm --no-headers | awk -v u="${OWNER}" '$1==u {print $2}' | sort -u | grep -v '^danted$' || true)"
if [[ -n "${OTHER}" ]]; then
  warn "Под пользователем '${OWNER}' работает не только danted:"
  echo "${OTHER}" | sed 's/^/    /'
  warn "Их HTTPS/QUIC-трафик тоже попадёт под маркировку. Если это нежелательно,"
  warn "передай другого владельца: sudo bash $0 <uid_owner>"
fi

info "Маркирую исходящий HTTPS/QUIC (443) от пользователя '${OWNER}'..."
for proto in tcp udp; do
  iptables -t mangle -C OUTPUT -m owner --uid-owner "${OWNER}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}" 2>/dev/null || \
    iptables -t mangle -A OUTPUT -m owner --uid-owner "${OWNER}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}"
done

command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null || warn "netfilter-persistent не найден — правило не сохранится после перезагрузки."

echo
info "Готово. Трафик Dante к youtube-доменам теперь тоже уйдёт через no-ads-туннель"
info "(sing-box сам решит по SNI, остальной трафик Dante пойдёт как раньше)."
echo
echo "Проверка: подключись через Dante и открой youtube-ролик, затем:"
echo "  journalctl -u sing-box -n 20 --no-pager -l | grep -i proxy-out"
