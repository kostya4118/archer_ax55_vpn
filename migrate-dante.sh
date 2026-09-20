#!/usr/bin/env bash
#
# migrate-dante.sh — поднять Dante (SOCKS-прокси) на новом сервере.
#
# Конфиг с прежнего сервера восстанавливается через migrate.sh, но в нём
# прописан СТАРЫЙ адрес в директивах internal:/external: — с ним danted просто
# не стартует ("cannot bind"). Скрипт определяет адрес нового сервера,
# подставляет его и поднимает службу.
#
# Заодно возвращает правило маркировки, чтобы YouTube-трафик, идущий через
# Dante, тоже уходил в no-ads туннель (обычная маркировка ловит только
# транзитный трафик VPN-клиентов, а Dante — локальный процесс, его соединения
# идут через цепочку OUTPUT).
#
# Запуск:  sudo bash migrate-dante.sh
#          sudo bash migrate-dante.sh 1.2.3.4   # если адрес надо задать явно
#
set -euo pipefail

CONF="${CONF:-/etc/danted.conf}"
FWMARK="${FWMARK:-0x77}"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }
[[ -f "${CONF}" ]] || { err "Нет ${CONF} — сначала восстанови конфиги: sudo bash migrate.sh restore <архив>"; exit 1; }

# --- 1. Ставим пакет ----------------------------------------------------------
if ! command -v danted >/dev/null 2>&1; then
  info "Ставлю dante-server..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq dante-server >/dev/null 2>&1 || apt-get install -y dante-server
fi

# --- 2. Определяем адрес нового сервера ---------------------------------------
NEW_IP="${1:-}"
if [[ -z "${NEW_IP}" ]]; then
  # Адрес, с которого сервер реально ходит в интернет — именно его слушает danted
  NEW_IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
fi
[[ -n "${NEW_IP}" ]] || { err "Не удалось определить IP. Передай явно: sudo bash $0 <IP>"; exit 1; }
info "Адрес этого сервера: ${NEW_IP}"

OLD_IP="$(grep -oE '^[[:space:]]*(internal|external):[[:space:]]*[0-9]+(\.[0-9]+){3}' "${CONF}" \
  | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1 || true)"
if [[ -n "${OLD_IP}" ]]; then
  info "В конфиге сейчас прописан: ${OLD_IP}"
  [[ "${OLD_IP}" == "${NEW_IP}" ]] && info "Адрес уже актуальный, менять нечего."
else
  warn "В конфиге нет явного IP (возможно, указан интерфейс) — проверь вручную."
fi

# --- 3. Подставляем новый адрес ------------------------------------------------
if [[ -n "${OLD_IP}" && "${OLD_IP}" != "${NEW_IP}" ]]; then
  cp -a "${CONF}" "${CONF}.bak-$(date +%Y%m%d-%H%M)"
  info "Бэкап: ${CONF}.bak-*"
  sed -i "s/\b${OLD_IP}\b/${NEW_IP}/g" "${CONF}"
  info "Заменил ${OLD_IP} -> ${NEW_IP}"
fi

echo
echo "${BLD}Что получилось:${RST}"
grep -E '^[[:space:]]*(internal|external|user\.|logoutput)' "${CONF}" | sed 's/^/  /'
echo

# --- 4. Запускаем --------------------------------------------------------------
info "Запускаю danted..."
systemctl enable danted >/dev/null 2>&1 || true
if ! systemctl restart danted; then
  err "danted не стартовал. Смотри:  journalctl -u danted -n 30 --no-pager -l"
  exit 1
fi
sleep 1

PORT="$(grep -oE '^[[:space:]]*internal:.*port[[:space:]]*=[[:space:]]*[0-9]+' "${CONF}" \
  | grep -oE '[0-9]+$' | head -1 || true)"
if [[ -n "${PORT}" ]]; then
  if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
    info "Слушает порт ${PORT} — порядок."
  else
    warn "Порт ${PORT} не слушается, хотя служба запущена. Проверь журнал."
  fi
fi

# --- 5. Маркировка трафика Dante ----------------------------------------------
# Воркеры danted работают под непривилегированным пользователем (обычно
# nobody) — по нему и матчим, чтобы не зацепить остальной трафик сервера.
OWNER="$(grep -oE '^[[:space:]]*user\.notprivileged:[[:space:]]*[A-Za-z0-9_-]+' "${CONF}" \
  | awk '{print $2}' | head -1 || true)"
OWNER="${OWNER:-nobody}"

if ip link show singbox0 >/dev/null 2>&1; then
  info "Возвращаю маркировку YouTube-трафика Dante (пользователь '${OWNER}')..."
  for proto in tcp udp; do
    iptables -t mangle -C OUTPUT -m owner --uid-owner "${OWNER}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}" 2>/dev/null || \
      iptables -t mangle -A OUTPUT -m owner --uid-owner "${OWNER}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}"
  done
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null || true
else
  warn "Интерфейс singbox0 не поднят — маркировку пропускаю."
  warn "Сначала подними YouTube-роутинг, потом:  sudo bash noads-exit/route-dante-output.sh ${OWNER}"
fi

echo
echo "${BLD}Готово.${RST}"
echo
echo "Проверки:"
echo "  systemctl status danted --no-pager"
echo "  ss -tlnp | grep danted"
echo
warn "Не забудь: клиентам нужно поменять адрес прокси на ${NEW_IP}"
[[ -n "${PORT}" ]] && warn "(порт прежний: ${PORT})"
warn "И открыть этот порт в файрволе провайдера, если он там фильтруется."
