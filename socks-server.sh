#!/usr/bin/env bash
#
# socks-server.sh — SOCKS5-прокси на базе sing-box (замена Dante).
#
# Зачем вместо Dante: пакета dante-server нет в Debian 13, а sing-box и так уже
# стоит и работает. Главный плюс — трафик прокси проходит через те же правила
# маршрутизации sing-box, что и трафик VPN-клиентов: ютуб-домены сами уходят в
# no-ads туннель по SNI. Отдельная маркировка по --uid-owner больше не нужна.
#
# Настройки сохраняются в /etc/sing-box/socks-server.json и подхватываются при
# перегенерации конфига скриптами *-youtube-exit.sh — то есть переживают
# смену ключа или WG-выхода.
#
# Запуск:
#   sudo bash socks-server.sh --port 1537 --user kostya            # пароль сгенерируется
#   sudo bash socks-server.sh --port 1537 --user kostya --pass 'свой-пароль'
#   sudo bash socks-server.sh --port 1537 --no-auth                # без пароля (НЕ НАДО)
#   sudo bash socks-server.sh --off                                # выключить
#
set -euo pipefail

CONF_DIR="/etc/sing-box"
CONF="${CONF_DIR}/config.json"
FRAGMENT="${CONF_DIR}/socks-server.json"
TAG="socks-public"

PORT=""; USERNAME=""; PASSWORD=""; NOAUTH=0; OFF=0

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    PORT="${2:-}"; shift 2 ;;
    --user)    USERNAME="${2:-}"; shift 2 ;;
    --pass)    PASSWORD="${2:-}"; shift 2 ;;
    --no-auth) NOAUTH=1; shift ;;
    --off)     OFF=1; shift ;;
    *) err "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

[[ -f "${CONF}" ]] || { err "Нет ${CONF} — сначала настрой YouTube-роутинг."; exit 1; }

# --- Выключение ----------------------------------------------------------------
if [[ "${OFF}" == "1" ]]; then
  info "Выключаю SOCKS-сервер..."
  rm -f "${FRAGMENT}"
  python3 - "${CONF}" "${TAG}" <<'PYEOF'
import json, sys
path, tag = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg["inbounds"] = [i for i in cfg.get("inbounds", []) if i.get("tag") != tag]
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
PYEOF
  systemctl restart sing-box
  info "Готово — порт закрыт."
  exit 0
fi

# --- Проверка аргументов --------------------------------------------------------
[[ -n "${PORT}" ]] || { err "Укажи порт:  --port 1537"; exit 1; }
[[ "${PORT}" =~ ^[0-9]+$ ]] || { err "Порт должен быть числом"; exit 1; }

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

# --- Пишем фрагмент и вставляем в конфиг ---------------------------------------
info "Настраиваю SOCKS-инбаунд на порту ${PORT}..."
umask 077
python3 - "${FRAGMENT}" "${TAG}" "${PORT}" "${NOAUTH}" "${USERNAME}" "${PASSWORD}" <<'PYEOF'
import json, sys
frag_path, tag, port, noauth, user, password = sys.argv[1:7]
inbound = {
    "type": "socks",
    "tag": tag,
    "listen": "0.0.0.0",
    "listen_port": int(port),
}
if noauth != "1":
    inbound["users"] = [{"username": user, "password": password}]
json.dump(inbound, open(frag_path, "w"), indent=2, ensure_ascii=False)
PYEOF
chmod 600 "${FRAGMENT}"

NEW_CONF="${CONF}.new"
python3 - "${CONF}" "${FRAGMENT}" "${NEW_CONF}" "${TAG}" <<'PYEOF'
import json, sys
conf_path, frag_path, out_path, tag = sys.argv[1:5]
cfg = json.load(open(conf_path))
frag = json.load(open(frag_path))
# убираем прежний такой же инбаунд, если был, и добавляем свежий
cfg["inbounds"] = [i for i in cfg.get("inbounds", []) if i.get("tag") != tag]
cfg["inbounds"].append(frag)
json.dump(cfg, open(out_path, "w"), indent=2, ensure_ascii=False)
PYEOF

if ! sing-box check -c "${NEW_CONF}"; then
  rm -f "${NEW_CONF}"
  err "sing-box забраковал конфиг — рабочий не тронут."
  exit 1
fi
mv -f "${NEW_CONF}" "${CONF}"

systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box || {
  err "sing-box не запустился:  journalctl -u sing-box -n 30 --no-pager -l"
  exit 1
}

if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
  info "Порт ${PORT} слушается."
else
  warn "Порт ${PORT} не виден в ss — проверь журнал."
fi

SRV_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"

echo
echo "${BLD}SOCKS5-прокси готов${RST}"
echo "  адрес : ${SRV_IP:-IP_СЕРВЕРА}"
echo "  порт  : ${PORT}"
if [[ "${NOAUTH}" == "0" ]]; then
  echo "  логин : ${USERNAME}"
  echo "  пароль: ${PASSWORD}"
  echo
  warn "Пароль показан один раз — сохрани его. Он лежит в ${FRAGMENT} (режим 600)."
else
  echo "  вход  : без пароля"
fi
echo
echo "YouTube через этот прокси уйдёт в no-ads туннель автоматически —"
echo "отдельная маркировка не нужна, sing-box решает по SNI."
echo
echo "Выключить:  sudo bash socks-server.sh --off"
