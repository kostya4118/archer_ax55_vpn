#!/usr/bin/env bash
#
# proxy-server.sh — HTTP и/или SOCKS5 прокси на базе sing-box (замена Dante).
#
# Зачем вместо Dante: пакета dante-server нет в Debian 13, а sing-box и так уже
# стоит и работает. Главный плюс — трафик прокси проходит через те же правила
# маршрутизации sing-box, что и трафик VPN-клиентов: ютуб-домены сами уходят в
# no-ads туннель по SNI. Отдельная маркировка по --uid-owner не нужна.
#
# Настройки сохраняются в /etc/noads-proxy.json и подхватываются при
# перегенерации конфига скриптами *-youtube-exit.sh — то есть переживают смену
# ключа или WG-выхода.
#
# Запуск:
#   sudo bash proxy-server.sh --port 1537 --user kostya                  # HTTP (по умолчанию)
#   sudo bash proxy-server.sh --type socks --port 1537 --user kostya
#   sudo bash proxy-server.sh --type both  --port 1537 --socks-port 1080 --user kostya
#   sudo bash proxy-server.sh --port 1537 --user kostya --pass 'свой-пароль'
#   sudo bash proxy-server.sh --port 1537 --no-auth                      # без пароля (НЕ НАДО)
#   sudo bash proxy-server.sh --off                                      # выключить
#
set -euo pipefail

CONF_DIR="/etc/sing-box"
CONF="${CONF_DIR}/config.json"
# ВАЖНО: фрагмент лежит ВНЕ /etc/sing-box. Служба стартует с "-C /etc/sing-box",
# то есть sing-box читает оттуда ВСЕ .json и сливает в один конфиг — посторонний
# файл в этой папке роняет запуск ("cannot unmarshal array into option._Options").
FRAGMENT="/etc/noads-proxy.json"
# Прежние версии клали фрагмент внутрь /etc/sing-box — их надо убрать оттуда.
LEGACY_FRAGMENTS=("${CONF_DIR}/proxy-server.json" "${CONF_DIR}/socks-server.json")
HTTP_TAG="http-public"
SOCKS_TAG="socks-public"

TYPE="http"; PORT=""; SOCKS_PORT=""; USERNAME=""; PASSWORD=""; NOAUTH=0; OFF=0

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)       TYPE="${2:-}"; shift 2 ;;
    --port)       PORT="${2:-}"; shift 2 ;;
    --socks-port) SOCKS_PORT="${2:-}"; shift 2 ;;
    --user)       USERNAME="${2:-}"; shift 2 ;;
    --pass)       PASSWORD="${2:-}"; shift 2 ;;
    --no-auth)    NOAUTH=1; shift ;;
    --off)        OFF=1; shift ;;
    *) err "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

# --- sing-box: ставим и заводим минимальный конфиг, если его ещё нет ----------
# Скрипт должен работать и на сервере без YouTube-роутинга — например, на
# старом, где прокси нужен сам по себе. Если конфиг уже есть, он не трогается:
# прокси просто добавляется к нему отдельным inbound'ом.
if [[ "${OFF}" == "0" ]] && ! command -v sing-box >/dev/null 2>&1; then
  info "Устанавливаю sing-box..."
  curl -fsSL https://sing-box.app/install.sh | sh
  command -v sing-box >/dev/null 2>&1 || { err "sing-box не установился"; exit 1; }
fi

if [[ ! -f "${CONF}" ]]; then
  [[ "${OFF}" == "1" ]] && { err "Нет ${CONF} — выключать нечего."; exit 1; }
  info "Конфига ${CONF} нет — создаю минимальный (весь трафик напрямую)."
  mkdir -p "${CONF_DIR}"
  cat > "${CONF}" <<'JSONEOF'
{
  "log": { "level": "warn" },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" }
    ],
    "final": "direct-out",
    "auto_detect_interface": true
  }
}
JSONEOF
  systemctl enable sing-box >/dev/null 2>&1 || true
fi

# Подбираем за прежними версиями: фрагмент в каталоге конфигов ломает запуск
for _old in "${LEGACY_FRAGMENTS[@]}"; do
  if [[ -f "${_old}" ]]; then
    warn "Убираю фрагмент из каталога конфигов: ${_old}"
    [[ -f "${FRAGMENT}" ]] || mv -f "${_old}" "${FRAGMENT}"
    rm -f "${_old}"
  fi
done

# --- Выключение ----------------------------------------------------------------
if [[ "${OFF}" == "1" ]]; then
  info "Выключаю прокси..."
  rm -f "${FRAGMENT}" "${LEGACY_FRAGMENTS[@]}"
  python3 - "${CONF}" "${HTTP_TAG}" "${SOCKS_TAG}" <<'PYEOF'
import json, sys
path = sys.argv[1]
tags = set(sys.argv[2:])
cfg = json.load(open(path))
cfg["inbounds"] = [i for i in cfg.get("inbounds", []) if i.get("tag") not in tags]
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
PYEOF
  systemctl restart sing-box
  info "Готово — порты закрыты."
  exit 0
fi

# --- Проверка аргументов --------------------------------------------------------
case "${TYPE}" in
  http|socks|both) ;;
  *) err "--type должен быть http, socks или both"; exit 1 ;;
esac

[[ -n "${PORT}" ]] || { err "Укажи порт:  --port 1537"; exit 1; }
[[ "${PORT}" =~ ^[0-9]+$ ]] || { err "Порт должен быть числом"; exit 1; }

if [[ "${TYPE}" == "both" ]]; then
  [[ -n "${SOCKS_PORT}" ]] || { err "Для --type both укажи второй порт:  --socks-port 1080"; exit 1; }
  [[ "${SOCKS_PORT}" =~ ^[0-9]+$ ]] || { err "--socks-port должен быть числом"; exit 1; }
  [[ "${SOCKS_PORT}" != "${PORT}" ]] || { err "Порты должны отличаться"; exit 1; }
fi

if [[ "${NOAUTH}" == "0" ]]; then
  [[ -n "${USERNAME}" ]] || { err "Укажи пользователя (--user) либо явно --no-auth"; exit 1; }
  if [[ -z "${PASSWORD}" ]]; then
    PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
    info "Пароль сгенерирован."
  fi
else
  warn "Прокси будет БЕЗ пароля и доступен всему интернету."
  warn "Его найдут сканеры и начнут гонять чужой трафик от имени сервера —"
  warn "за это хостеры блокируют VPS. Лучше задай --user и --pass."
fi

# --- Порт занят кем-то ещё? ------------------------------------------------------
# Лучше разобраться сразу, чем собрать конфиг и получить "bind: address already
# in use" уже после подмены рабочего файла. Dante останавливаем — его и заменяем;
# на любом другом процессе выходим, ничего не трогая.
port_busy() { ss -tln 2>/dev/null | grep -qE "[.:]${1}[[:space:]]"; }

free_port() {
  local port="$1" line name pid
  line="$(ss -tlnp 2>/dev/null | grep -E "[.:]${port}[[:space:]]" | head -1)"
  [[ -z "${line}" ]] && return 0
  [[ "${line}" == *sing-box* ]] && return 0   # наш же процесс, рестарт освободит

  name="$(sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p' <<< "${line}")"
  pid="$(sed -n 's/.*pid=\([0-9]\+\).*/\1/p' <<< "${line}")"

  if [[ "${name}" != "danted" && "${name}" != "sockd" ]]; then
    err "Порт ${port} занят процессом '${name:-неизвестно}':"
    echo "    ${line}" >&2
    err "Останови его или возьми другой порт (--port)."
    exit 1
  fi

  # Имя юнита у Dante разнится между сборками, а иногда он и вовсе запущен мимо
  # systemd — поэтому сначала пробуем все варианты, потом просто гасим процесс.
  info "Порт ${port} держит ${name} — останавливаю, его и заменяем."
  for unit in danted sockd dante-server; do
    systemctl disable --now "${unit}" >/dev/null 2>&1 || true
  done
  sleep 1
  if port_busy "${port}" && [[ -n "${pid}" ]]; then
    warn "Служба не остановилась — завершаю процесс ${pid}."
    kill "${pid}" 2>/dev/null || true
    sleep 2
  fi
  port_busy "${port}" && { err "Порт ${port} всё ещё занят. Разберись вручную:  ss -tlnp | grep ${port}"; exit 1; }
  return 0
}

for _p in "${PORT}" ${SOCKS_PORT:+${SOCKS_PORT}}; do
  free_port "${_p}"
done

# --- Собираем фрагмент ----------------------------------------------------------
info "Настраиваю прокси (${TYPE})..."
umask 077
python3 - "${FRAGMENT}" "${TYPE}" "${PORT}" "${SOCKS_PORT}" "${NOAUTH}" "${USERNAME}" "${PASSWORD}" "${HTTP_TAG}" "${SOCKS_TAG}" <<'PYEOF'
import json, sys
frag_path, ptype, port, socks_port, noauth, user, password, http_tag, socks_tag = sys.argv[1:10]

users = None if noauth == "1" else [{"username": user, "password": password}]

def inbound(kind, tag, listen_port):
    ib = {"type": kind, "tag": tag, "listen": "0.0.0.0", "listen_port": int(listen_port)}
    if users:
        ib["users"] = users
    return ib

inbounds = []
if ptype in ("http", "both"):
    inbounds.append(inbound("http", http_tag, port))
if ptype == "socks":
    inbounds.append(inbound("socks", socks_tag, port))
elif ptype == "both":
    inbounds.append(inbound("socks", socks_tag, socks_port))

json.dump(inbounds, open(frag_path, "w"), indent=2, ensure_ascii=False)
PYEOF
chmod 600 "${FRAGMENT}"

# --- Вставляем в боевой конфиг --------------------------------------------------
NEW_CONF="${CONF}.new"
python3 - "${CONF}" "${FRAGMENT}" "${NEW_CONF}" "${HTTP_TAG}" "${SOCKS_TAG}" <<'PYEOF'
import json, sys
conf_path, frag_path, out_path = sys.argv[1:4]
tags = set(sys.argv[4:])
cfg = json.load(open(conf_path))
frag = json.load(open(frag_path))
if isinstance(frag, dict):
    frag = [frag]
cfg["inbounds"] = [i for i in cfg.get("inbounds", []) if i.get("tag") not in tags]
cfg["inbounds"].extend(frag)
json.dump(cfg, open(out_path, "w"), indent=2, ensure_ascii=False)
PYEOF

if ! sing-box check -c "${NEW_CONF}"; then
  rm -f "${NEW_CONF}"
  err "sing-box забраковал конфиг — рабочий не тронут."
  exit 1
fi
mv -f "${NEW_CONF}" "${CONF}"

# --- Осиротевший хелпер маршрутизации --------------------------------------------
# Если на сервере когда-то был YouTube-роутинг, а потом его отключили, drop-in с
# ExecStartPost мог остаться. Хелпер не найдёт tun-интерфейс, вернёт ошибку — и
# systemd повалит всю службу, хотя сам прокси при этом полностью исправен.
DROPIN="/etc/systemd/system/sing-box.service.d/noads-route.conf"
if [[ -f "${DROPIN}" ]] && ! grep -q '"type"[[:space:]]*:[[:space:]]*"tun"' "${CONF}"; then
  warn "В конфиге нет tun-инбаунда — убираю оставшийся хелпер маршрутизации."
  rm -f "${DROPIN}"
  rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
  systemctl daemon-reload
fi

systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box || {
  err "sing-box не запустился:  journalctl -u sing-box -n 30 --no-pager -l"
  exit 1
}

for p in "${PORT}" ${SOCKS_PORT:+${SOCKS_PORT}}; do
  if ss -tlnp 2>/dev/null | grep -q ":${p}"; then
    info "Порт ${p} слушается."
  else
    warn "Порт ${p} не виден в ss — проверь журнал."
  fi
done

SRV_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"

echo
echo "${BLD}Прокси готов${RST}"
echo "  адрес : ${SRV_IP:-IP_СЕРВЕРА}"
case "${TYPE}" in
  http)  echo "  HTTP  : порт ${PORT}" ;;
  socks) echo "  SOCKS5: порт ${PORT}" ;;
  both)  echo "  HTTP  : порт ${PORT}"; echo "  SOCKS5: порт ${SOCKS_PORT}" ;;
esac
if [[ "${NOAUTH}" == "0" ]]; then
  echo "  логин : ${USERNAME}"
  echo "  пароль: ${PASSWORD}"
  echo
  warn "Пароль показан один раз — сохрани его. Он лежит в ${FRAGMENT} (режим 600)."
  warn "Логин и пароль идут по сети в открытом виде (так устроены и HTTP, и"
  warn "SOCKS5-аутентификация) — не используй тот же пароль где-то ещё."
else
  echo "  вход  : без пароля"
fi
echo
if grep -qi 'youtube' "${CONF}"; then
  echo "YouTube через прокси уйдёт в no-ads туннель автоматически —"
  echo "отдельная маркировка не нужна, sing-box решает по SNI."
else
  echo "Весь трафик прокси идёт напрямую: на этом сервере no-ads туннель не настроен."
  echo "Если он нужен:  sudo bash noads-exit/wg-youtube-exit.sh /путь/к/конфигу.conf"
fi
echo
echo "Выключить:  sudo bash proxy-server.sh --off"
