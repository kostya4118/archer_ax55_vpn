#!/usr/bin/env bash
#
# disable-youtube-routing.sh — выключает перенаправление YouTube-трафика через
# прокси и убирает за собой все правила.
#
# Что делает:
#   1. Останавливает и отключает автозапуск sing-box.
#   2. Убирает маркировку HTTPS/QUIC-трафика VPN-клиентов (mangle PREROUTING).
#   3. Убирает маркировку локального прокси (Dante), если она ставилась.
#   4. Убирает policy routing (ip rule + таблица 200).
#   5. Сохраняет правила, чтобы не вернулись после перезагрузки.
#
# Сам sing-box и его конфиг остаются на месте — включить обратно можно одной
# командой:  sudo bash vless-youtube-exit.sh '<ключ>'
#
# Запуск:  sudo bash disable-youtube-routing.sh
#
set -euo pipefail

FWMARK="${FWMARK:-0x77}"
RT_TABLE="${RT_TABLE:-200}"
TUN_IF="${TUN_IF:-singbox0}"
BRIDGE_IF="${BRIDGE_IF:-amn0}"

GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }

[[ "${EUID}" -ne 0 ]] && { echo "Запусти с sudo:  sudo bash $0"; exit 1; }

# --- 1. Останавливаем sing-box -----------------------------------------------
info "Останавливаю sing-box..."
systemctl disable --now sing-box 2>/dev/null || true

# --- 2. Маркировка трафика VPN-клиентов --------------------------------------
info "Убираю маркировку трафика VPN-клиентов (${BRIDGE_IF})..."
for proto in tcp udp; do
  while iptables -t mangle -D PREROUTING -i "${BRIDGE_IF}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}" 2>/dev/null; do :; done
done

# --- 3. Маркировка локального прокси (Dante) ---------------------------------
info "Убираю маркировку локального прокси, если была..."
for owner in nobody; do
  for proto in tcp udp; do
    while iptables -t mangle -D OUTPUT -m owner --uid-owner "${owner}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}" 2>/dev/null; do :; done
  done
done

# --- 4. Policy routing --------------------------------------------------------
info "Убираю policy routing (ip rule + таблица ${RT_TABLE})..."
while ip rule del fwmark "${FWMARK}" table "${RT_TABLE}" 2>/dev/null; do :; done
ip route flush table "${RT_TABLE}" 2>/dev/null || true

# --- 5. Правила форварда на tun ----------------------------------------------
while iptables -D FORWARD -o "${TUN_IF}" -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i "${TUN_IF}" -j ACCEPT 2>/dev/null; do :; done

command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null || \
  warn "netfilter-persistent не найден — правила могут вернуться после перезагрузки."

echo
echo "${BLD}Готово.${RST} YouTube-трафик больше не перенаправляется — идёт напрямую,"
echo "как весь остальной трафик VPN-клиентов."
echo
echo "Включить обратно:"
echo "  sudo bash noads-exit/vless-youtube-exit.sh '<vless:// или ss:// ключ>'"
