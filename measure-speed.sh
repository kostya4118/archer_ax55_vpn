#!/usr/bin/env bash
#
# measure-speed.sh — скорость на сервере: напрямую, через no-ads туннель и
# текущий поток по каждому интерфейсу.
#
# Только измеряет, ничего не меняет.
#
# Запуск:  sudo bash measure-speed.sh
#          sudo bash measure-speed.sh --size 200   # качать 200 МБ вместо 50
#          sudo bash measure-speed.sh --live       # только текущий поток
#
set -uo pipefail

SIZE_MB=50
LIVE_ONLY=0
WG_IF="${WG_IF:-wgru}"

GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
hdr()  { echo; echo "${BLD}$*${RST}"; printf '%s\n' "------------------------------------------------------------"; }
warn() { echo "  ${YLW}!${RST} $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE_MB="${2:-50}"; shift 2 ;;
    --live) LIVE_ONLY=1; shift ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

BYTES=$(( SIZE_MB * 1000000 ))
URL="https://speed.cloudflare.com/__down?bytes=${BYTES}"

# Скачивает и возвращает скорость в Мбит/с. $1 — интерфейс или пусто (напрямую).
measure() {
  local iface="${1:-}" args=() bps
  args=(-s -o /dev/null -w '%{speed_download}' --max-time 120)
  [[ -n "${iface}" ]] && args+=(--interface "${iface}")
  bps="$(curl "${args[@]}" "${URL}" 2>/dev/null || echo 0)"
  # curl отдаёт байты в секунду, иногда с дробной частью
  awk -v b="${bps}" 'BEGIN { printf "%.1f", b * 8 / 1000000 }'
}

# --- Текущий поток ----------------------------------------------------------------
hdr "Что идёт прямо сейчас"
echo "  (замер за 3 секунды)"
declare -A RX0 TX0
while read -r iface rx tx; do
  RX0["${iface}"]="${rx}"; TX0["${iface}"]="${tx}"
done < <(awk -F'[: ]+' 'NR>2 {gsub(/ /,"",$2); print $2, $3, $11}' /proc/net/dev)

sleep 3

printf "  %-12s %14s %12s\n" "интерфейс" "приём" "отдача"
while read -r iface rx tx; do
  [[ "${iface}" == "lo" ]] && continue
  local_rx0="${RX0[${iface}]:-0}"; local_tx0="${TX0[${iface}]:-0}"
  d_rx=$(( (rx - local_rx0) * 8 / 3 ))
  d_tx=$(( (tx - local_tx0) * 8 / 3 ))
  # Молчащие интерфейсы не показываем, чтобы не загромождать вывод
  (( d_rx < 8000 && d_tx < 8000 )) && continue
  printf "  %-12s %9.2f Мбит %7.2f Мбит\n" "${iface}" \
    "$(awk -v v="${d_rx}" 'BEGIN{print v/1000000}')" \
    "$(awk -v v="${d_tx}" 'BEGIN{print v/1000000}')"
done < <(awk -F'[: ]+' 'NR>2 {gsub(/ /,"",$2); print $2, $3, $11}' /proc/net/dev)

[[ "${LIVE_ONLY}" == "1" ]] && exit 0

# --- Замер скорости ---------------------------------------------------------------
hdr "Скорость загрузки (${SIZE_MB} МБ с Cloudflare)"

echo -n "  напрямую через интернет : "
DIRECT="$(measure)"
echo "${DIRECT} Мбит/с"

if ip link show "${WG_IF}" >/dev/null 2>&1; then
  echo -n "  через туннель ${WG_IF}      : "
  TUNNEL="$(measure "${WG_IF}")"
  echo "${TUNNEL} Мбит/с"

  # Туннель всегда медленнее прямого канала; вопрос только насколько
  if awk -v d="${DIRECT}" -v t="${TUNNEL}" 'BEGIN { exit !(d > 0 && t < d * 0.3) }'; then
    warn "Туннель отдаёт меньше трети от прямого канала."
    warn "Обычные причины: MTU, загруженный выходной сервер, дальний маршрут."
    warn "Проверить MTU:  bash noads-exit/measure-youtube-path.sh"
  fi
else
  warn "Интерфейса ${WG_IF} нет — no-ads туннель не поднят, мерить нечего."
fi

# --- Задержка ---------------------------------------------------------------------
hdr "Задержка"
for host in 1.1.1.1 youtube.com; do
  RTT="$(ping -c 4 -q -W 3 "${host}" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {printf "%.0f", $5}')"
  printf "  %-14s %s\n" "${host}" "${RTT:-нет ответа} мс"
done

# --- Со стороны клиента -----------------------------------------------------------
SRV_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
PROXY_PORT="$(ss -tlnp 2>/dev/null | awk '/sing-box/ && /0\.0\.0\.0:/ {split($4,a,":"); print a[2]; exit}')"

hdr "Проверить со своей машины"
echo "  Через прокси (то, что реально получают клиенты):"
echo "    curl -x http://${SRV_IP:-IP}:${PROXY_PORT:-1537} -o /dev/null \\"
echo "      -w 'скорость: %{speed_download} Б/с\\n' \\"
echo "      'https://speed.cloudflare.com/__down?bytes=50000000'"
echo
echo "  Точный замер канала до сервера (нужен iperf3 с обеих сторон):"
echo "    на сервере :  iperf3 -s -p 5201"
echo "    у себя     :  iperf3 -c ${SRV_IP:-IP} -p 5201 -R"
echo
echo "  Поток в реальном времени, пока смотришь видео:"
echo "    sudo bash measure-speed.sh --live"
