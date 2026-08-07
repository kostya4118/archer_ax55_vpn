#!/usr/bin/env bash
#
# uninstall-adguard.sh — полностью убирает AdGuard Home и всё, что от него
# зависело: YouTube no-ads роутинг (ipset/mangle/sing-box или wgnoads),
# перехват DNS, ограничения порта 53. Возвращает сервер к состоянию
# "просто VPN, без ad-blocking слоя".
#
# Запуск:  sudo bash uninstall-adguard.sh
#
set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }

[[ "${EUID}" -ne 0 ]] && { echo "Запусти с sudo:  sudo bash $0"; exit 1; }

# --- 1. YouTube no-ads exit: sing-box/VLESS и/или wgnoads --------------------
info "Останавливаю YouTube-роутинг (sing-box / wgnoads)..."
systemctl disable --now sing-box 2>/dev/null || true
systemctl disable --now wg-quick@wgnoads 2>/dev/null || true
rm -f /etc/systemd/system/sing-box.service.d/noads-route.conf
rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
rm -f /usr/local/sbin/noads-route-up.sh
ip rule del fwmark 0x77 table 200 2>/dev/null || true
ip route flush table 200 2>/dev/null || true
systemctl daemon-reload

# --- 2. ipset и связанный systemd-юнит ---------------------------------------
info "Удаляю ipset youtube и его автозапуск..."
systemctl disable --now youtube-ipset.service 2>/dev/null || true
rm -f /etc/systemd/system/youtube-ipset.service
systemctl daemon-reload
ipset destroy youtube 2>/dev/null || true
ipset destroy youtube6 2>/dev/null || true

# --- 3. iptables-правила ------------------------------------------------------
info "Чищу iptables-правила (маркировка, DNAT, ограничения порта 53)..."
iptables -t mangle -D PREROUTING -i amn0 -m set --match-set youtube dst -j MARK --set-mark 0x77 2>/dev/null || true
iptables -t mangle -D OUTPUT -m set --match-set youtube dst -j MARK --set-mark 0x77 2>/dev/null || true
iptables -t nat -D POSTROUTING -o singbox0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -o wgnoads -j MASQUERADE 2>/dev/null || true
iptables -t mangle -D FORWARD -o wgnoads -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -D FORWARD -o singbox0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i singbox0 -j ACCEPT 2>/dev/null || true

# DNAT-перехват DNS на AdGuard (из setup-amnezia-dns-redirect.sh)
iptables -t nat -D PREROUTING -i amn0 -p udp --dport 53 ! -d 172.29.172.1 -j DNAT --to-destination 172.29.172.1 2>/dev/null || true
iptables -t nat -D PREROUTING -i amn0 -p tcp --dport 53 ! -d 172.29.172.1 -j DNAT --to-destination 172.29.172.1 2>/dev/null || true

# DROP-правила порта 53 (закрывали DNS от интернета, теперь там всё равно
# никто не слушает — убираем, чтобы не путали при будущей диагностике)
for proto in udp tcp; do
  while iptables -D INPUT -p "${proto}" --dport 53 -j DROP 2>/dev/null; do :; done
done

command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null || warn "netfilter-persistent не найден — правила не сохранены на будущую перезагрузку."

# --- 4. AdGuard Home -----------------------------------------------------------
if [[ -x /opt/AdGuardHome/AdGuardHome ]]; then
  info "Удаляю службу AdGuard Home..."
  /opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
  /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
fi
systemctl disable --now AdGuardHome 2>/dev/null || true
rm -rf /opt/AdGuardHome

# --- 5. Возвращаем системный DNS сервера в исходное состояние ----------------
info "Возвращаю системный DNS сервера на обычный systemd-resolved..."
rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
rmdir /etc/systemd/resolved.conf.d 2>/dev/null || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl reload-or-restart systemd-resolved

echo
echo "${BLD}Готово.${RST} AdGuard и весь связанный YouTube-роутинг удалены."
echo
echo "${YLW}ВАЖНО — сделай ещё на КЛИЕНТАХ${RST} (Amnezia на телефоне/компьютере):"
echo "  Настройки сервера -> DNS -> убери адрес вида 172.29.172.1 (или что там"
echo "  указано), оставь поле пустым или впиши публичный DNS (например 1.1.1.1)."
echo "  Иначе клиенты не смогут резолвить домены вообще — там больше никто"
echo "  не слушает."
echo
echo "Проверка на сервере:  dig +short google.com @1.1.1.1"
echo "Проверка диска:       df -h /   (место от AdGuard освобождено)"
