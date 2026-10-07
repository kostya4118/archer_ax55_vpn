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
URL_OVERRIDE=""
WG_IF="${WG_IF:-wgru}"
MEASURE_MBIT=""; MEASURE_NOTE=""

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
hdr()  { echo; echo "${BLD}$*${RST}"; printf '%s\n' "------------------------------------------------------------"; }
warn() { echo "  ${YLW}!${RST} $*"; }
err()  { echo "  ${RED}x${RST} $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE_MB="${2:-50}"; shift 2 ;;
    --url)  URL_OVERRIDE="${2:-}"; shift 2 ;;
    --live) LIVE_ONLY=1; shift ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

BYTES=$(( SIZE_MB * 1000000 ))

# Источники пробуем по очереди: публичные файлы то переезжают, то начинают
# отдавать 403 отдельным сетям, и один жёстко зашитый адрес регулярно подводит.
CANDIDATES=(
  "https://speed.cloudflare.com/__down?bytes=${BYTES}"
  "http://speedtest.selectel.ru/100MB"
  "http://ipv4.download.thinkbroadband.com/100MB.zip"
)

pick_url() {
  local u code
  for u in "${CANDIDATES[@]}"; do
    # без "|| echo 000": curl и при неудаче печатает свой %{http_code},
    # и запасное значение просто склеивалось с ним в "000000"
    code="$(curl -s -o /dev/null -r 0-1023 -w '%{http_code}' --max-time 15 "${u}" 2>/dev/null)"
    code="${code:-000}"
    # 206 — сервер отдал запрошенный кусок, 200 — отдал бы целиком
    if [[ "${code}" == "200" || "${code}" == "206" ]]; then
      echo "${u}"; return 0
    fi
    echo "  ${YLW}!${RST} ${u} — ответил ${code}, пропускаю" >&2
  done
  return 1
}

# Скачивает и возвращает скорость в Мбит/с. $1 — интерфейс или пусто (напрямую).
# Результат пишем в MEASURE_MBIT, причину неудачи — в MEASURE_NOTE: нули без
# объяснения выглядят как медленный канал, хотя файл мог просто не скачаться.
measure() {
  local iface="${1:-}" args=() out rc bps code size
  args=(-s -o /dev/null -w '%{speed_download} %{http_code} %{size_download}' --max-time 120)
  [[ -n "${iface}" ]] && args+=(--interface "${iface}")
  out="$(curl "${args[@]}" "${URL}" 2>/dev/null)"; rc=$?
  read -r bps code size <<< "${out:-0 000 0}"
  MEASURE_NOTE=""
  if [[ "${rc}" -ne 0 ]]; then
    MEASURE_NOTE="curl завершился с кодом ${rc}"
  elif [[ "${code}" != "200" ]]; then
    MEASURE_NOTE="сервер ответил ${code}"
  elif [[ "${size:-0}" -lt 1000000 ]]; then
    MEASURE_NOTE="скачалось всего ${size} байт — замер недостоверен"
  fi
  MEASURE_MBIT="$(awk -v b="${bps:-0}" 'BEGIN { printf "%.1f", b * 8 / 1000000 }')"
}

# --- Текущий поток ----------------------------------------------------------------
hdr "Что идёт прямо сейчас"
echo "  (замер за 3 секунды)"
# Счётчики берём из /sys, а не из /proc/net/dev: там колонки разъезжаются, как
# только счётчик дорастает до ширины поля, и имя интерфейса слипается с числом.
counters() {
  local dev
  for dev in /sys/class/net/*; do
    [[ -e "${dev}/statistics/rx_bytes" ]] || continue
    echo "$(basename "${dev}") $(<"${dev}/statistics/rx_bytes") $(<"${dev}/statistics/tx_bytes")"
  done
}

declare -A RX0 TX0
while read -r iface rx tx; do
  RX0["${iface}"]="${rx}"; TX0["${iface}"]="${tx}"
done < <(counters)

sleep 3

printf "  %-12s %14s %14s\n" "интерфейс" "приём" "отдача"
while read -r iface rx tx; do
  [[ "${iface}" == "lo" ]] && continue
  d_rx=$(( (rx - ${RX0[${iface}]:-0}) * 8 / 3 ))
  d_tx=$(( (tx - ${TX0[${iface}]:-0}) * 8 / 3 ))
  # Молчащие интерфейсы не показываем, чтобы не загромождать вывод
  (( d_rx < 8000 && d_tx < 8000 )) && continue
  printf "  %-12s %9.2f Мбит %9.2f Мбит\n" "${iface}" \
    "$(awk -v v="${d_rx}" 'BEGIN{print v/1000000}')" \
    "$(awk -v v="${d_tx}" 'BEGIN{print v/1000000}')"
done < <(counters)

[[ "${LIVE_ONLY}" == "1" ]] && exit 0

# --- Замер скорости ---------------------------------------------------------------
hdr "Скорость загрузки"

if [[ -n "${URL_OVERRIDE}" ]]; then
  URL="${URL_OVERRIDE}"
else
  URL="$(pick_url || true)"
  [[ -z "${URL}" ]] && { err "Ни один тестовый источник не отвечает."; \
    err "Задай свой:  --url https://пример/файл"; exit 1; }
fi
echo "  источник: ${URL}"
echo

echo -n "  напрямую через интернет : "
measure; DIRECT="${MEASURE_MBIT}"
echo "${DIRECT} Мбит/с"
[[ -n "${MEASURE_NOTE}" ]] && warn "${MEASURE_NOTE}"

if [[ -n "${MEASURE_NOTE}" ]]; then
  warn "Прямой замер не удался, сравнивать не с чем."
  warn "Проверь источник вручную:  curl -sS -o /dev/null -w '%{http_code}\\n' '${URL}'"
  warn "Другой источник можно задать:  --url https://пример/файл"
fi

if ip link show "${WG_IF}" >/dev/null 2>&1; then
  echo -n "  через туннель ${WG_IF}      : "
  measure "${WG_IF}"; TUNNEL="${MEASURE_MBIT}"
  echo "${TUNNEL} Мбит/с"
  [[ -n "${MEASURE_NOTE}" ]] && warn "${MEASURE_NOTE}"

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
# Порт прокси ищем среди тех, что sing-box слушает на всех адресах: у него есть и
# внутренние слушатели на адресе tun-интерфейса, они клиентам недоступны.
PROXY_PORT="$(ss -tlnp 2>/dev/null | awk '/sing-box/ && $4 ~ /^0\.0\.0\.0:/ {split($4,a,":"); print a[2]; exit}')"

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
