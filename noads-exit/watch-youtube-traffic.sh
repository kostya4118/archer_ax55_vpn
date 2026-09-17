#!/usr/bin/env bash
#
# watch-youtube-traffic.sh — живой просмотр того, как ходит YouTube-трафик:
# какие домены sing-box видит по SNI и в какой outbound их отправляет.
#
# По умолчанию sing-box логирует только ошибки (level=warn), поэтому скрипт
# временно поднимает уровень до info, показывает поток решений маршрутизации,
# а по Ctrl+C возвращает всё как было.
#
# Запуск:  sudo bash watch-youtube-traffic.sh
#          sudo bash watch-youtube-traffic.sh --all   # без фильтра по доменам
#
set -euo pipefail

WG_IF="${WG_IF:-wgru}"
CONF="${CONF:-/etc/sing-box/config.json}"
FILTER='youtube|googlevideo|ytimg|ggpht|wg-out|proxy-out'
[[ "${1:-}" == "--all" ]] && FILTER='.'

GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }

[[ "${EUID}" -ne 0 ]] && { echo "Запусти с sudo:  sudo bash $0"; exit 1; }
[[ -f "${CONF}" ]] || { echo "Нет ${CONF} — sing-box не настроен?"; exit 1; }

set_level() {
  python3 - "${CONF}" "$1" <<'PYEOF'
import json, sys
path, level = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault("log", {})["level"] = level
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PYEOF
}

restore() {
  echo
  info "Возвращаю уровень логов обратно (warn)..."
  set_level warn
  systemctl restart sing-box >/dev/null 2>&1 || true
  info "Готово."
}
trap restore EXIT INT TERM

# --- Состояние туннеля до начала ---------------------------------------------
if ip link show "${WG_IF}" >/dev/null 2>&1; then
  echo "${BLD}WireGuard (${WG_IF}) сейчас:${RST}"
  wg show "${WG_IF}" latest-handshakes | awk '{print "  последний handshake (unix):", $2}'
  wg show "${WG_IF}" transfer | awk '{print "  принято:", $2, "байт | отправлено:", $3, "байт"}'
  echo
else
  warn "Интерфейс ${WG_IF} не поднят — ютуб через WireGuard сейчас не идёт."
  echo
fi

info "Поднимаю детальность логов sing-box до info..."
set_level info
systemctl restart sing-box
sleep 2

echo
echo "${BLD}Теперь открой видео на YouTube — ниже пойдут соединения.${RST}"
echo "Ищи строки вида: 'outbound/direct[wg-out]: outbound connection to ...googlevideo.com'"
echo "${YLW}Ctrl+C — закончить и вернуть тихие логи.${RST}"
echo

journalctl -u sing-box -f --no-pager -l --since "now" \
  | grep --line-buffered -Ei "${FILTER}"
