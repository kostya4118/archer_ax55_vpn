#!/usr/bin/env bash
#
# route-service-output.sh — отправить исходящий HTTPS/QUIC одной systemd-службы
# в тот же no-ads туннель, куда уходит трафик VPN-клиентов.
#
# Зачем: обычная маркировка ловит трафик, приходящий на мост клиентов. Службы,
# работающие на самом сервере (прокси, выходные узлы вроде OpenFlux), открывают
# соединения сами — такие пакеты идут через цепочку OUTPUT и проходят мимо
# схемы. В итоге у клиентов этих служб ютуб показывает рекламу, хотя у клиентов
# VPN — нет.
#
# Матчим по cgroup конкретного юнита, а не по порту или пользователю: так под
# правило попадает ровно одна служба. Пометить весь исходящий трафик сервера
# нельзя — туда попадёт и сам sing-box, и получится петля.
#
# Запуск:
#   sudo bash route-service-output.sh openflux.service
#   sudo bash route-service-output.sh --off openflux.service
#   sudo bash route-service-output.sh --list
#
set -euo pipefail

FWMARK="${FWMARK:-0x77}"
SERVICES_LIST="/etc/noads-routed-services"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }

OFF=0; UNIT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --off)  OFF=1; shift ;;
    --list)
      if [[ -s "${SERVICES_LIST}" ]]; then
        echo "${BLD}Службы, чей исходящий трафик уходит в туннель:${RST}"
        grep -vE '^\s*(#|$)' "${SERVICES_LIST}" | sed 's/^/  /'
      else
        echo "Список пуст."
      fi
      echo
      echo "${BLD}Правила сейчас:${RST}"
      iptables -t mangle -S OUTPUT | grep -- '--path' | sed 's/^/  /' || echo "  нет"
      exit 0 ;;
    *) UNIT="$1"; shift ;;
  esac
done

[[ -n "${UNIT}" ]] || { err "Укажи юнит:  sudo bash $0 openflux.service"; exit 1; }
[[ "${UNIT}" == *.* ]] || UNIT="${UNIT}.service"

CGROUP="system.slice/${UNIT}"

rules() {  # $1 = -A|-D|-C
  local op="$1" proto
  for proto in tcp udp; do
    iptables -t mangle "${op}" OUTPUT -m cgroup --path "${CGROUP}" \
      -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}" 2>/dev/null || return 1
  done
}

# --- Выключение ------------------------------------------------------------------
if [[ "${OFF}" == "1" ]]; then
  rules -D >/dev/null 2>&1 || true
  if [[ -f "${SERVICES_LIST}" ]]; then
    grep -vxF "${UNIT}" "${SERVICES_LIST}" > "${SERVICES_LIST}.new" || true
    mv -f "${SERVICES_LIST}.new" "${SERVICES_LIST}"
  fi
  info "${UNIT} больше не заворачивается в туннель."
  exit 0
fi

# --- Проверки до изменений --------------------------------------------------------
systemctl cat "${UNIT}" >/dev/null 2>&1 || { err "Юнита ${UNIT} нет."; exit 1; }
systemctl is-active --quiet "${UNIT}" || warn "${UNIT} сейчас не запущен — правило всё равно поставлю."

ip rule show 2>/dev/null | grep -q "fwmark ${FWMARK} lookup" || {
  err "Нет правила маршрутизации по метке ${FWMARK}."
  err "Сначала настрой выход:  sudo bash noads-exit/wg-youtube-exit.sh /путь/к/конфигу"
  exit 1
}

# Сам sing-box метить нельзя: его трафик вернётся в его же tun-интерфейс
case "${UNIT}" in
  sing-box*) err "sing-box метить нельзя — получится петля."; exit 1 ;;
esac

# --- Ставим правила ----------------------------------------------------------------
if rules -C >/dev/null 2>&1; then
  info "Правила для ${UNIT} уже стоят."
else
  if ! rules -A; then
    err "iptables не принял правило. Скорее всего, нет поддержки match 'cgroup'."
    err "Проверь:  modprobe xt_cgroup; iptables -t mangle -S OUTPUT"
    exit 1
  fi
  info "Исходящий HTTPS/QUIC от ${UNIT} помечен меткой ${FWMARK}."
fi

# --- Запоминаем, чтобы вернулось после перезагрузки ---------------------------------
touch "${SERVICES_LIST}"
grep -qxF "${UNIT}" "${SERVICES_LIST}" || echo "${UNIT}" >> "${SERVICES_LIST}"
info "Записал в ${SERVICES_LIST} — хелпер вернёт правило при старте sing-box."

# --- Проверка -----------------------------------------------------------------------
echo
echo "${BLD}Как убедиться${RST}"
echo "  Счётчики правила (должны расти, пока служба работает):"
echo "    iptables -t mangle -L OUTPUT -n -v | grep cgroup"
echo
echo "  Куда теперь выходит ютуб у клиентов этой службы — проверь на устройстве:"
echo "    открой ipinfo.io через неё; адрес должен быть выходным, а не серверным"
echo
echo "  Выключить:  sudo bash $0 --off ${UNIT}"
