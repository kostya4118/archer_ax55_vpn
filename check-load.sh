#!/usr/bin/env bash
#
# check-load.sh — кто ест ресурсы сервера: процессор, память, диск, сеть.
#
# Только читает, ничего не меняет и не останавливает.
#
# Запуск:  sudo bash check-load.sh
#
set -uo pipefail

GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
hdr() { echo; echo "${BLD}$*${RST}"; printf '%s\n' "------------------------------------------------------------"; }
note() { echo "  ${YLW}!${RST} $*"; }

[[ "${EUID}" -ne 0 ]] && echo "${YLW}Лучше с sudo — иначе не видно чужих процессов.${RST}"

# --- Общая картина ---------------------------------------------------------------
hdr "Нагрузка сейчас"
CPUS="$(nproc 2>/dev/null || echo 1)"
LOAD="$(awk '{print $1, $2, $3}' /proc/loadavg)"
LOAD1="$(awk '{print $1}' /proc/loadavg)"
echo "  ядер: ${CPUS}   load average (1/5/15 мин): ${LOAD}"
# load выше числа ядер означает очередь: задачи ждут процессор
awk -v l="${LOAD1}" -v c="${CPUS}" 'BEGIN { if (l > c) exit 0; exit 1 }' \
  && note "load выше числа ядер — процессор в очереди, сервер тормозит" \
  || echo "  ${GRN}✓${RST} запас по процессору есть"

echo
uptime | sed 's/^/  /'

# --- Память ----------------------------------------------------------------------
hdr "Память"
free -h | sed 's/^/  /'
SWAP_USED="$(free -m | awk '/^Swap:/ {print $3}')"
[[ "${SWAP_USED:-0}" -gt 100 ]] && note "занято ${SWAP_USED} МБ подкачки — памяти не хватает, всё упирается в диск"

OOM="$(dmesg -T 2>/dev/null | grep -ci 'out of memory' || true)"
[[ "${OOM:-0}" -gt 0 ]] && note "в журнале ядра ${OOM} записей об OOM — процессы уже убивали из-за нехватки памяти"

# --- Топ процессов ---------------------------------------------------------------
hdr "Больше всего процессора"
ps -eo pcpu,pmem,rss,etimes,comm --sort=-pcpu 2>/dev/null | head -11 \
  | awk 'NR==1 {printf "  %-6s %-6s %-9s %-10s %s\n", "CPU%", "MEM%", "RSS(МБ)", "живёт", "процесс"; next}
         {printf "  %-6s %-6s %-9.0f %-10s %s\n", $1, $2, $3/1024, ($4>86400 ? int($4/86400)" дн" : int($4/3600)" ч"), $5}'

hdr "Больше всего памяти"
ps -eo pcpu,pmem,rss,comm --sort=-rss 2>/dev/null | head -11 \
  | awk 'NR==1 {printf "  %-6s %-6s %-9s %s\n", "CPU%", "MEM%", "RSS(МБ)", "процесс"; next}
         {printf "  %-6s %-6s %-9.0f %s\n", $1, $2, $3/1024, $4}'

# --- Контейнеры ------------------------------------------------------------------
hdr "Контейнеры"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # --no-stream: один снимок, иначе команда не вернёт управление
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' 2>/dev/null | sed 's/^/  /' \
    || echo "  не удалось снять статистику"
  echo
  STOPPED="$(docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | wc -l)"
  [[ "${STOPPED}" -gt 0 ]] && note "остановленных контейнеров: ${STOPPED} (место занимают, ресурсы — нет)"
else
  echo "  Docker не установлен или не отвечает"
fi

# --- Службы ----------------------------------------------------------------------
hdr "Запущенные службы"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | awk '{print $1}' | sed 's/^/  /' || echo "  не удалось получить список"

# --- Диск ------------------------------------------------------------------------
hdr "Диск"
df -h / 2>/dev/null | sed 's/^/  /'
USED_PCT="$(df --output=pcent / 2>/dev/null | tr -dc '0-9')"
[[ "${USED_PCT:-0}" -gt 85 ]] && note "диск занят на ${USED_PCT}% — стоит почистить"

if command -v journalctl >/dev/null 2>&1; then
  JSIZE="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | head -1)"
  [[ -n "${JSIZE}" ]] && echo "  журналы systemd занимают: ${JSIZE}"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo
  docker system df 2>/dev/null | sed 's/^/  /'
fi

# --- Ожидание диска --------------------------------------------------------------
hdr "Ожидание диска"
if command -v vmstat >/dev/null 2>&1; then
  # Вторая строка vmstat — усреднение за интервал, первая всегда с момента загрузки
  WA="$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $16}')"
  echo "  iowait: ${WA:-?}%"
  [[ "${WA:-0}" -gt 20 ]] && note "процессор ждёт диск — узкое место в дисковых операциях, а не в вычислениях"
else
  echo "  vmstat не установлен (apt install procps)"
fi

# --- Открытые порты --------------------------------------------------------------
hdr "Что слушает сеть"
ss -tulnp 2>/dev/null | awk 'NR==1 || /LISTEN|UNCONN/' | sed 's/^/  /' | head -25

echo
echo "${BLD}Как это читать${RST}"
echo "  Процесс в верхних строках обоих списков — главный кандидат на отключение."
echo "  Службу можно выключить так:   systemctl disable --now <имя>"
echo "  Контейнер:                    docker stop <имя> && docker update --restart=no <имя>"
echo "  Освободить место от Docker:   docker system prune -a   (удалит неиспользуемые образы)"
echo "  Подрезать журналы:            journalctl --vacuum-size=200M"
