#!/usr/bin/env bash
#
# remote-exit-setup.sh — запускается на ВТОРОМ VPS (в стране без рекламы YouTube:
# немонетизируемый рынок — Узбекистан, Армения, Монголия и т.п.).
#
# Поднимает WireGuard-сервер и печатает готовый клиентский конфиг, который надо
# сохранить на ОСНОВНОМ (Amnezia) сервере как /etc/wireguard/wgnoads.conf,
# после чего там запускается local-route-setup.sh.
#
# Запуск:  sudo bash remote-exit-setup.sh
#
set -euo pipefail

WG_PORT="${WG_PORT:-51821}"
WG_NET="10.9.9"

[[ "${EUID}" -ne 0 ]] && { echo "Запусти с sudo"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq wireguard qrencode >/dev/null 2>&1 || \
  apt-get install -y wireguard

umask 077
SERVER_PRIV="$(wg genkey)"; SERVER_PUB="$(printf '%s' "${SERVER_PRIV}" | wg pubkey)"
CLIENT_PRIV="$(wg genkey)"; CLIENT_PUB="$(printf '%s' "${CLIENT_PRIV}" | wg pubkey)"

WAN_IF="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
PUB_IP="$(curl -fsSL https://api.ipify.org)"

cat > /etc/wireguard/wgnoads-exit.conf <<EOF
[Interface]
Address = ${WG_NET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET}.0/24 -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET}.0/24 -o ${WAN_IF} -j MASQUERADE

[Peer]
# основной (Amnezia) сервер
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${WG_NET}.2/32
EOF

sysctl -qw net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

systemctl enable --now wg-quick@wgnoads-exit

echo
echo "================================================================"
echo " ГОТОВО. Скопируй ВЕСЬ блок ниже на ОСНОВНОЙ сервер в файл"
echo "   /etc/wireguard/wgnoads.conf"
echo " и запусти там:  sudo bash noads-exit/local-route-setup.sh"
echo "================================================================"
echo
cat <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_NET}.2/24
MTU = 1340
Table = off

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
