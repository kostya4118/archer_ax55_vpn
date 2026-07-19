#!/usr/bin/env bash
#
# install-adguard.sh — установка AdGuard Home на сервер Amnezia (VPS)
#
# Что делает скрипт:
#   1. Освобождает порт 53 (отключает systemd-resolved DNSStubListener,
#      если он занимает порт).
#   2. Устанавливает AdGuard Home официальным установщиком.
#   3. Подсказывает, как открыть веб-панель первичной настройки.
#   4. (Опционально) закрывает DNS от внешнего мира, оставляя доступ
#      только из VPN-подсети — чтобы сервер не стал открытым резолвером.
#
# ВАЖНО про YouTube: DNS-блокировка НЕ убирает видео-рекламу внутри YouTube
# (она идёт с тех же *.googlevideo.com, что и само видео). Для самого YouTube
# нужны клиентские решения — см. README.md. AdGuard Home уберёт рекламу и
# трекеры во всех остальных приложениях и на сайтах для всех VPN-клиентов.
#
# Запуск:  sudo bash install-adguard.sh
#
set -euo pipefail

# ---- Настройки (можно поменять) --------------------------------------------
# Подсеть VPN, которой разрешить доступ к DNS. Значение по умолчанию — типовое
# для AmneziaWG. Проверьте свою в конфиге сервера (адрес интерфейса wg/awg).
VPN_SUBNET="${VPN_SUBNET:-10.8.1.0/24}"
# Ограничивать ли доступ к порту 53 только VPN-подсетью (рекомендуется: yes).
RESTRICT_DNS="${RESTRICT_DNS:-ask}"
# ----------------------------------------------------------------------------

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info()  { echo "${GRN}[+]${RST} $*"; }
warn()  { echo "${YLW}[!]${RST} $*"; }
err()   { echo "${RED}[x]${RST} $*" >&2; }

if [[ "${EUID}" -ne 0 ]]; then
  err "Запусти скрипт с правами root:  sudo bash $0"
  exit 1
fi

# --- 1. Освобождаем порт 53 -------------------------------------------------
free_port_53() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemd не найден — пропускаю освобождение порта 53. Убедись сам, что порт свободен."
    return
  fi
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    info "Отключаю DNSStubListener у systemd-resolved (освобождаю порт 53)..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/adguardhome.conf <<'EOF'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
    # Перенаправляем resolv.conf на реальный конфиг resolved (не на stub)
    if [[ -e /run/systemd/resolve/resolv.conf ]]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
    systemctl reload-or-restart systemd-resolved
    info "Порт 53 освобождён."
  else
    info "systemd-resolved не активен — порт 53, вероятно, уже свободен."
  fi
}

# --- 2. Устанавливаем AdGuard Home ------------------------------------------
install_adguard() {
  if [[ -d /opt/AdGuardHome ]]; then
    info "AdGuard Home уже установлен в /opt/AdGuardHome — пропускаю установку."
    return
  fi
  info "Скачиваю и устанавливаю AdGuard Home (официальный установщик)..."
  curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
}

# --- 3. (Опционально) ограничиваем DNS только VPN-подсетью -------------------
restrict_dns() {
  local ans="${RESTRICT_DNS}"
  if [[ "${ans}" == "ask" ]]; then
    read -r -p "Закрыть DNS (порт 53) от интернета, оставив доступ только из VPN ${VPN_SUBNET}? [Y/n] " reply
    reply="${reply:-Y}"
    [[ "${reply}" =~ ^[YyДд] ]] && ans="yes" || ans="no"
  fi
  if [[ "${ans}" != "yes" ]]; then
    warn "Пропускаю ограничение DNS. ВНИМАНИЕ: открытый резолвер могут использовать для атак. Настрой firewall вручную."
    return
  fi
  if ! command -v iptables >/dev/null 2>&1; then
    warn "iptables не найден — не могу настроить правила. Ограничь порт 53 в своём firewall вручную."
    return
  fi
  info "Разрешаю DNS только из VPN-подсети ${VPN_SUBNET} и с localhost..."
  # Разрешаем DNS из VPN и localhost, блокируем остальное (udp+tcp/53).
  for proto in udp tcp; do
    iptables -C INPUT -p "${proto}" --dport 53 -s "${VPN_SUBNET}" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p "${proto}" --dport 53 -s "${VPN_SUBNET}" -j ACCEPT
    iptables -C INPUT -p "${proto}" --dport 53 -s 127.0.0.1 -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p "${proto}" --dport 53 -s 127.0.0.1 -j ACCEPT
    iptables -C INPUT -p "${proto}" --dport 53 -j DROP 2>/dev/null || \
      iptables -A INPUT -p "${proto}" --dport 53 -j DROP
  done
  info "Правила добавлены. Сохрани их, чтобы пережили перезагрузку:"
  echo "     apt install -y iptables-persistent   # или netfilter-persistent save"
}

main() {
  info "Установка AdGuard Home для сервера Amnezia"
  echo
  free_port_53
  install_adguard
  restrict_dns
  echo
  local ip
  ip="$(curl -fsSL https://api.ipify.org 2>/dev/null || echo "IP_СЕРВЕРА")"
  echo "${BLD}Готово!${RST}"
  echo
  echo "  1. Открой веб-панель первичной настройки:"
  echo "        ${BLD}http://${ip}:3000${RST}"
  echo "     Задай логин/пароль. Веб-интерфейс оставь на 80 или 8080,"
  echo "     а DNS-сервер (Listen) — на порту 53."
  echo
  echo "  2. В настройках AdGuard добавь блок-листы (см. README.md, раздел"
  echo "     «Блок-листы»)."
  echo
  echo "  3. В приложении Amnezia пропиши DNS для VPN-клиентов = адрес этого"
  echo "     сервера внутри VPN (адрес wg/awg-интерфейса, напр. ${VPN_SUBNET%.*}.1)."
  echo "     Подробности — в README.md, раздел «Подключение DNS к Amnezia»."
  echo
  warn "Напоминание: видео-рекламу в самом YouTube это не уберёт — см. README.md."
}

main "$@"
