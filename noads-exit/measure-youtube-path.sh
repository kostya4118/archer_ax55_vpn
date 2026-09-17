#!/usr/bin/env bash
#
# measure-youtube-path.sh — замеры маршрута, по которому идёт YouTube.
#
# Сравнивает два пути:
#   прямой  : сервер -> интернет (как ходит весь обычный трафик клиентов)
#   туннель : сервер -> WireGuard-выход -> интернет (как ходит YouTube)
#
# Меряет задержку, скорость скачивания и MTU — три главные причины, по которым
# видео может буферизовать.
#
# Запуск:  sudo bash measure-youtube-path.sh
#
set -euo pipefail

WG_IF="${WG_IF:-wgru}"
TUN_IF="${TUN_IF:-singbox0}"
# 20 МБ тестовый файл (Cloudflare speed test, доступен отовсюду)
TEST_URL="${TEST_URL:-https://speed.cloudflare.com/__down?bytes=20000000}"

GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }

hr() { printf '%s\n' "----------------------------------------------------------"; }

ip link show "${WG_IF}" >/dev/null 2>&1 || { echo "Интерфейс ${WG_IF} не поднят."; exit 1; }

# --- MTU ----------------------------------------------------------------------
echo "${BLD}MTU интерфейсов${RST}"
hr
for IF in eth0 "${TUN_IF}" "${WG_IF}"; do
  ip link show "${IF}" 2>/dev/null | awk -v i="${IF}" '/mtu/ {for(n=1;n<=NF;n++) if($n=="mtu") printf "  %-10s %s\n", i, $(n+1)}'
done
echo

# --- Реальный проходящий размер пакета через туннель --------------------------
echo "${BLD}Какой размер пакета реально проходит через ${WG_IF}${RST}"
hr
BEST=0
for SIZE in 1200 1280 1350 1372 1412; do
  if ping -M do -s "${SIZE}" -c 1 -W 3 -I "${WG_IF}" 1.1.1.1 >/dev/null 2>&1; then
    echo "  ${SIZE} байт (MTU $((SIZE+28))) — ${GRN}проходит${RST}"
    BEST="${SIZE}"
  else
    echo "  ${SIZE} байт (MTU $((SIZE+28))) — ${YLW}НЕ проходит${RST}"
  fi
done
if [[ "${BEST}" != "0" ]]; then
  echo
  echo "  Максимальный рабочий MTU через туннель: ${BLD}$((BEST+28))${RST}"
  CUR_MTU="$(ip link show "${WG_IF}" | awk '/mtu/ {for(n=1;n<=NF;n++) if($n=="mtu") print $(n+1)}')"
  if [[ -n "${CUR_MTU}" && "${CUR_MTU}" -gt "$((BEST+28))" ]]; then
    warn "MTU интерфейса (${CUR_MTU}) БОЛЬШЕ реально проходящего ($((BEST+28)))."
    warn "Это и есть причина тормозов: крупные пакеты молча теряются."
    warn "Лечится:  ip link set ${WG_IF} mtu $((BEST+28))"
  fi
fi
echo

# --- Задержка до WG-сервера ---------------------------------------------------
PEER_EP="$(wg show "${WG_IF}" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1 || true)"
if [[ -n "${PEER_EP}" ]]; then
  echo "${BLD}Задержка до WG-сервера (${PEER_EP})${RST}"
  hr
  ping -c 5 -W 3 "${PEER_EP}" 2>/dev/null | tail -2 || warn "  ICMP закрыт — пропускаем"
  echo
fi

# --- Задержка до Google: туннель против прямого -------------------------------
echo "${BLD}Задержка до YouTube${RST}"
hr
FMT='  connect=%{time_connect}s  первый_байт=%{time_starttransfer}s\n'
printf "  туннель (%s):\n" "${WG_IF}"
curl -s --interface "${WG_IF}" --max-time 15 -o /dev/null -w "  $FMT" \
  https://www.youtube.com/generate_204 2>/dev/null || warn "  не отвечает"
printf "  напрямую:\n"
curl -s --max-time 15 -o /dev/null -w "  $FMT" \
  https://www.youtube.com/generate_204 2>/dev/null || warn "  не отвечает"
echo

# --- Скорость: туннель против прямого -----------------------------------------
echo "${BLD}Скорость скачивания (20 МБ)${RST}"
hr
speed_of() {
  local label="$1"; shift
  local out
  out="$(curl -s --max-time 60 -o /dev/null -w '%{speed_download} %{time_total}' "$@" "${TEST_URL}" 2>/dev/null || echo "0 0")"
  local bps="${out%% *}" t="${out##* }"
  local mbps
  mbps="$(awk -v b="${bps}" 'BEGIN{printf "%.1f", b*8/1000000}')"
  printf "  %-22s %s Мбит/с   (%s сек)\n" "${label}" "${mbps}" "${t}"
}
speed_of "туннель (${WG_IF}):" --interface "${WG_IF}"
speed_of "напрямую:"
echo

hr
echo "${BLD}Как читать:${RST}"
echo "  • Скорость в туннеле сильно ниже прямой  → узкий канал WG-сервера"
echo "    или длинный маршрут Дублин↔Новосибирск. Лечится сменой выхода."
echo "  • Пакеты 1372/1412 не проходят, а MTU больше → снизить MTU (см. выше)."
echo "  • Задержка в туннеле в разы выше прямой  → география маршрута;"
echo "    видео будет дольше стартовать, но при достаточной скорости не тормозить."
