#!/usr/bin/env bash
#
# check-health.sh — проверка состояния всего стека: Amnezia, YouTube-роутинг,
# прокси и возможные конфликты между ними.
#
# Только читает, ничего не меняет.
#
# Запуск:  sudo bash check-health.sh
#
set -uo pipefail   # без -e: проверки должны доходить до конца, даже если часть падает

BRIDGE_IF="${BRIDGE_IF:-amn0}"
TUN_IF="${TUN_IF:-singbox0}"
WG_IF="${WG_IF:-wgru}"
FWMARK="${FWMARK:-0x77}"
RT_TABLE="${RT_TABLE:-200}"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok()   { echo "  ${GRN}✓${RST} $*"; }
bad()  { echo "  ${RED}✗${RST} $*"; PROBLEMS=$((PROBLEMS+1)); }
warn() { echo "  ${YLW}!${RST} $*"; WARNINGS=$((WARNINGS+1)); }
hdr()  { echo; echo "${BLD}$*${RST}"; printf '%s\n' "------------------------------------------------------------"; }

PROBLEMS=0; WARNINGS=0

[[ "${EUID}" -ne 0 ]] && { echo "Запусти с sudo"; exit 1; }

# --- Amnezia: контейнеры --------------------------------------------------------
hdr "Amnezia: контейнеры"
if ! command -v docker >/dev/null 2>&1; then
  bad "docker не установлен"
else
  AMN_CONTAINERS="$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -i amnezia || true)"
  if [[ -z "${AMN_CONTAINERS}" ]]; then
    bad "нет запущенных контейнеров Amnezia"
    STOPPED="$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -i amnezia || true)"
    [[ -n "${STOPPED}" ]] && echo "${STOPPED}" | sed 's/^/      остановлен: /'
  else
    echo "${AMN_CONTAINERS}" | while IFS=$'\t' read -r name status; do
      echo "  ${GRN}✓${RST} ${name} — ${status}"
    done
  fi
fi

# --- Amnezia: мост и маршрутизация ----------------------------------------------
hdr "Amnezia: сеть"
if ip link show "${BRIDGE_IF}" >/dev/null 2>&1; then
  BR_IP="$(ip -4 -o addr show "${BRIDGE_IF}" 2>/dev/null | awk '{print $4}')"
  ok "мост ${BRIDGE_IF} поднят (${BR_IP:-адреса нет})"
  [[ -z "${BR_IP}" ]] && bad "у ${BRIDGE_IF} нет IPv4-адреса"
else
  bad "моста ${BRIDGE_IF} нет — Amnezia не поднялась"
fi

FWD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
[[ "${FWD}" == "1" ]] && ok "ip_forward включён" || bad "ip_forward выключен — клиенты не выйдут в интернет"

if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE; then
  ok "NAT (MASQUERADE) настроен"
else
  bad "нет правил MASQUERADE — трафик клиентов не будет выходить наружу"
fi

# --- Проверка изнутри контейнера ------------------------------------------------
hdr "Проверка изнутри контейнера Amnezia"
CONT="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i 'amnezia-awg' | head -1 || true)"
if [[ -z "${CONT}" ]]; then
  warn "контейнер amnezia-awg не найден — пропускаю"
else
  if docker exec "${CONT}" ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
    ok "из контейнера есть интернет"
  else
    bad "из контейнера НЕТ интернета — клиенты работать не будут"
  fi
  RESOLVED="$(docker exec "${CONT}" getent hosts google.com 2>/dev/null | head -1 || true)"
  [[ -n "${RESOLVED}" ]] && ok "DNS резолвится (${RESOLVED%% *})" || bad "DNS из контейнера не работает"

  # Подключённые клиенты
  PEERS="$(docker exec "${CONT}" wg show 2>/dev/null | grep -c '^peer:' || echo 0)"
  RECENT="$(docker exec "${CONT}" wg show all latest-handshakes 2>/dev/null \
    | awk -v now="$(date +%s)" '$3 != "" && $3 > 0 && (now-$3) < 600' | wc -l || echo 0)"
  if [[ "${PEERS}" -gt 0 ]]; then
    ok "клиентов заведено: ${PEERS}, активных за 10 минут: ${RECENT}"
  else
    warn "в контейнере нет ни одного клиента (peers) — конфиги ещё не розданы?"
  fi
fi

# --- YouTube-роутинг ------------------------------------------------------------
hdr "YouTube-роутинг"
if systemctl is-active --quiet sing-box; then
  ok "sing-box работает"
else
  bad "sing-box не работает (journalctl -u sing-box -n 30 --no-pager -l)"
fi

ip link show "${TUN_IF}" >/dev/null 2>&1 && ok "интерфейс ${TUN_IF} поднят" || bad "нет интерфейса ${TUN_IF}"

if ip rule show 2>/dev/null | grep -q "fwmark ${FWMARK} lookup ${RT_TABLE}"; then
  ok "правило маршрутизации по метке на месте"
else
  bad "нет правила 'fwmark ${FWMARK} lookup ${RT_TABLE}'"
fi

RT="$(ip route show table "${RT_TABLE}" 2>/dev/null)"
if [[ -n "${RT}" ]]; then
  ok "таблица ${RT_TABLE}: ${RT}"
else
  bad "таблица ${RT_TABLE} пуста — помеченный трафик пойдёт мимо туннеля"
fi

MARK_TCP="$(iptables -t mangle -L PREROUTING -n -v 2>/dev/null | awk '/tcp dpt:443/ {print $1; exit}')"
MARK_UDP="$(iptables -t mangle -L PREROUTING -n -v 2>/dev/null | awk '/udp dpt:443/ {print $1; exit}')"
if [[ -n "${MARK_TCP}" ]]; then
  ok "маркировка работает: TCP=${MARK_TCP} UDP=${MARK_UDP:-0} пакетов"
else
  bad "нет правила маркировки трафика клиентов"
fi

if ip link show "${WG_IF}" >/dev/null 2>&1; then
  HS="$(wg show "${WG_IF}" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
  NOW="$(date +%s)"
  if [[ -n "${HS}" && "${HS}" != "0" ]]; then
    AGE=$(( NOW - HS ))
    if [[ "${AGE}" -lt 300 ]]; then
      ok "туннель ${WG_IF} живой (handshake ${AGE} сек назад)"
    else
      warn "последний handshake ${WG_IF} был ${AGE} сек назад — возможно, выход отвалился"
    fi
  else
    bad "handshake с ${WG_IF} не состоялся — YouTube-выход не работает"
  fi
else
  warn "интерфейса ${WG_IF} нет — YouTube-роутинг выключен?"
fi

# --- Конфликт сохранённых правил с Docker ---------------------------------------
hdr "Риск конфликта сохранённых правил с Docker"
RULES_FILE="/etc/iptables/rules.v4"
if [[ -f "${RULES_FILE}" ]]; then
  DOCKER_SAVED="$(grep -cE '^(:DOCKER|-A DOCKER|-A POSTROUTING.*docker|-A FORWARD.*docker)' "${RULES_FILE}" 2>/dev/null || echo 0)"
  if [[ "${DOCKER_SAVED}" -gt 0 ]]; then
    warn "в ${RULES_FILE} сохранено ${DOCKER_SAVED} правил Docker."
    echo "      Docker создаёт их сам при старте. Восстановление копии до его запуска"
    echo "      может дать дубли или сломать сеть контейнеров после перезагрузки."
    echo "      Лечится: очистить файл от docker-правил (см. подсказку ниже)."
  else
    ok "правил Docker в сохранённой копии нет"
  fi
else
  ok "iptables-persistent не сохранял правила (${RULES_FILE} отсутствует)"
fi

DUP="$(iptables -t nat -S POSTROUTING 2>/dev/null | sort | uniq -d | head -3)"
[[ -n "${DUP}" ]] && { warn "есть дублирующиеся правила NAT:"; echo "${DUP}" | sed 's/^/      /'; } \
                  || ok "дублей в NAT не видно"

# --- Порты Amnezia ---------------------------------------------------------------
hdr "Порты Amnezia"
PORTS="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -i amnezia || true)"
if [[ -n "${PORTS}" ]]; then
  echo "${PORTS}" | sed 's/^/  /'
else
  warn "не удалось получить список портов"
fi

# --- Итог -------------------------------------------------------------------------
hdr "Итог"
if [[ "${PROBLEMS}" -eq 0 && "${WARNINGS}" -eq 0 ]]; then
  echo "  ${GRN}Всё в порядке.${RST}"
elif [[ "${PROBLEMS}" -eq 0 ]]; then
  echo "  ${YLW}Проблем нет, но есть замечания: ${WARNINGS}${RST}"
else
  echo "  ${RED}Найдено проблем: ${PROBLEMS}${RST}, замечаний: ${WARNINGS}"
fi
echo
echo "Если нашлись docker-правила в сохранённой копии — убрать их так:"
echo "  iptables-save | grep -vE 'docker|DOCKER|br-[0-9a-f]{12}|${BRIDGE_IF}' > ${RULES_FILE}.clean"
echo "  # сверить глазами, затем:  mv ${RULES_FILE}.clean ${RULES_FILE}"
