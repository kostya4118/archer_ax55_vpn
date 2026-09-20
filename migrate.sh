#!/usr/bin/env bash
#
# migrate.sh — перенос настроек YouTube-роутинга на другой сервер.
#
# Переносит только НАШУ часть (WireGuard-выход, конфиг sing-box, Dante).
# Сама Amnezia ставится заново через её приложение — её ключи и клиентские
# конфиги здесь не участвуют.
#
#   sudo bash migrate.sh backup            # на СТАРОМ сервере -> архив
#   sudo bash migrate.sh restore <архив>   # на НОВОМ сервере
#
# Порядок переезда:
#   1. backup на старом сервере
#   2. на новом сервере поставить Amnezia (через приложение) — нужен amn0
#   3. скопировать архив на новый сервер и restore
#
set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }

MODE="${1:-}"

# Временная папка объявлена глобально: trap срабатывает уже после выхода из
# функции, и локальная переменная к тому моменту не видна (set -u -> падение).
WORKDIR=""
cleanup() { [[ -n "${WORKDIR}" ]] && rm -rf "${WORKDIR}"; return 0; }
trap cleanup EXIT

# --- BACKUP -------------------------------------------------------------------
do_backup() {
  local stamp; stamp="$(date +%Y%m%d-%H%M)"
  WORKDIR="$(mktemp -d)"; local work="${WORKDIR}"
  local out="/root/noads-backup-${stamp}.tar.gz"

  info "Собираю конфиги..."
  mkdir -p "${work}/wireguard" "${work}/sing-box" "${work}/dante"

  # WireGuard-выходы (wgru и т.п.) — внутри приватные ключи
  local found_wg=0
  for f in /etc/wireguard/*.conf; do
    [[ -e "$f" ]] || continue
    cp -a "$f" "${work}/wireguard/"
    echo "    $(basename "$f")"
    found_wg=1
  done
  [[ "${found_wg}" == "0" ]] && warn "WireGuard-конфигов не найдено."

  # sing-box
  if [[ -f /etc/sing-box/config.json ]]; then
    cp -a /etc/sing-box/config.json "${work}/sing-box/"
    echo "    sing-box/config.json"
  else
    warn "Конфиг sing-box не найден."
  fi

  # Dante
  if [[ -f /etc/danted.conf ]]; then
    cp -a /etc/danted.conf "${work}/dante/"
    echo "    danted.conf"
  fi

  # Шпаргалка: что было настроено
  {
    echo "# Снимок настроек, $(date)"
    echo
    echo "## Интерфейсы"
    ip -o -4 addr show 2>/dev/null | awk '{print "  "$2" "$4}'
    echo
    echo "## Прокси-выход в sing-box"
    python3 -c "
import json
try:
    c = json.load(open('/etc/sing-box/config.json'))
    for o in c.get('outbounds', []):
        print('  ', o.get('tag'), o.get('type'), o.get('server',''), o.get('bind_interface',''))
except Exception as e:
    print('  (не прочитан:', e, ')')
" 2>/dev/null || true
    echo
    echo "## Правила маркировки"
    iptables -t mangle -S PREROUTING 2>/dev/null | grep -- '--set-mark' || echo "  нет"
    iptables -t mangle -S OUTPUT 2>/dev/null | grep -- '--set-mark' || true
  } > "${work}/SNAPSHOT.txt"

  tar czf "${out}" -C "${work}" .
  chmod 600 "${out}"

  echo
  echo "${BLD}Готово:${RST} ${out}"
  echo
  warn "В архиве ПРИВАТНЫЕ КЛЮЧИ WireGuard — не выкладывай его никуда."
  echo
  echo "Скопировать на новый сервер (выполнять на своём компьютере):"
  echo "  scp root@$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo СТАРЫЙ_IP):${out} ."
  echo "  scp $(basename "${out}") root@НОВЫЙ_IP:/root/"
}

# --- RESTORE ------------------------------------------------------------------
do_restore() {
  local archive="${1:-}"
  [[ -f "${archive}" ]] || { err "Архив не найден: ${archive}"; exit 1; }

  if ! ip link show amn0 >/dev/null 2>&1; then
    err "Нет интерфейса amn0 — сначала установи Amnezia на этот сервер"
    err "(через её приложение), потом запускай restore."
    exit 1
  fi

  WORKDIR="$(mktemp -d)"; local work="${WORKDIR}"
  tar xzf "${archive}" -C "${work}"

  info "Ставлю пакеты..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard iptables-persistent >/dev/null 2>&1 || \
    apt-get install -y wireguard iptables-persistent

  if ! command -v sing-box >/dev/null 2>&1; then
    info "Ставлю sing-box..."
    curl -fsSL https://sing-box.app/install.sh | sh
  fi

  info "Возвращаю конфиги..."
  umask 077
  mkdir -p /etc/wireguard
  for f in "${work}"/wireguard/*.conf; do
    [[ -e "$f" ]] || continue
    cp -a "$f" /etc/wireguard/
    chmod 600 "/etc/wireguard/$(basename "$f")"
    echo "    $(basename "$f")"
  done

  if [[ -f "${work}/dante/danted.conf" ]]; then
    warn "danted.conf восстановлен, но в нём прописан СТАРЫЙ адрес сервера."
    warn "Поправь 'internal:' и 'external:' на новый IP, иначе Dante не поднимется."
    cp -a "${work}/dante/danted.conf" /etc/danted.conf
  fi

  echo
  echo "${BLD}Конфиги на месте.${RST} Осталось поднять роутинг:"
  echo
  echo "  cd ~/archer_ax55_vpn"
  echo "  sudo bash noads-exit/wg-youtube-exit.sh /etc/wireguard/wgru.conf"
  echo
  echo "Скрипт сам поднимет туннель, подберёт MTU, настроит sing-box и маркировку"
  echo "под новый сервер. Старые правила iptables намеренно не переносятся —"
  echo "имена интерфейсов могут отличаться, чище собрать заново."
  echo
  if [[ -f "${work}/SNAPSHOT.txt" ]]; then
    echo "Что было на старом сервере — в ${BLD}/root/SNAPSHOT-old.txt${RST}"
    cp -a "${work}/SNAPSHOT.txt" /root/SNAPSHOT-old.txt
  fi
}

case "${MODE}" in
  backup)  do_backup ;;
  restore) do_restore "${2:-}" ;;
  *)
    echo "Использование:"
    echo "  sudo bash $0 backup            # на старом сервере"
    echo "  sudo bash $0 restore <архив>   # на новом сервере"
    exit 1
    ;;
esac
