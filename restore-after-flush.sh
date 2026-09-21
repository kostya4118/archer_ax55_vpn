#!/usr/bin/env bash
#
# restore-after-flush.sh — вернуть сеть в рабочее состояние после `iptables -F`
# (например, после аварийного восстановления доступа через VNC-консоль).
#
# Флаш сносит вообще все правила: NAT для Amnezia, цепочки Docker и маркировку
# YouTube-трафика. Само по себе это не восстановится — контейнеры продолжают
# работать, но их трафик наружу не выходит.
#
# Что делает скрипт:
#   1. убирает сохранённую копию правил (она и есть источник проблемы);
#   2. перезапускает Docker — он пересоздаёт свои цепочки и NAT для Amnezia;
#   3. перезапускает sing-box — его ExecStartPost возвращает policy routing
#      и маркировку YouTube-трафика.
#
# Запуск:  sudo bash restore-after-flush.sh
#
set -uo pipefail

BRIDGE_IF="${BRIDGE_IF:-amn0}"
TUN_IF="${TUN_IF:-singbox0}"
FWMARK="${FWMARK:-0x77}"
RT_TABLE="${RT_TABLE:-200}"
ROUTE_UP="/usr/local/sbin/noads-route-up.sh"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }

# --- 1. Политики цепочек ------------------------------------------------------
# На всякий случай: если скрипт запускают сразу после аварийного флаша, политика
# INPUT могла остаться DROP — тогда следующий разрыв связи снова запрёт снаружи.
for chain in INPUT FORWARD OUTPUT; do
  POLICY="$(iptables -S "${chain}" 2>/dev/null | awk -v c="${chain}" '$1=="-P" && $2==c {print $3; exit}')"
  if [[ "${POLICY}" != "ACCEPT" ]]; then
    warn "Политика ${chain} была ${POLICY:-неизвестна} — ставлю ACCEPT."
    iptables -P "${chain}" ACCEPT
  fi
done
info "Политики цепочек: ACCEPT."

# --- 2. Сохранённая копия правил ---------------------------------------------
# Файл создавался нашими же вызовами `netfilter-persistent save`. В нём лежит
# слепок правил Docker, который при загрузке накатывается РАНЬШЕ самого Docker:
# дубли, сломанная сеть контейнеров, а в худшем случае закрытый доступ на сервер.
REMOVED=0
for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
  if [[ -f "${f}" ]]; then
    mv -f "${f}" "${f}.disabled-$(date +%Y%m%d-%H%M)"
    info "Убрал ${f} (переименован, не удалён — можно посмотреть глазами)."
    REMOVED=1
  fi
done
[[ "${REMOVED}" == "0" ]] && info "Сохранённых копий правил нет — хорошо."

if systemctl is-enabled --quiet netfilter-persistent 2>/dev/null; then
  systemctl disable netfilter-persistent >/dev/null 2>&1 \
    && info "Отключил автозагрузку netfilter-persistent." \
    || warn "Не удалось отключить netfilter-persistent — проверь вручную."
fi

# --- 3. Docker: пересоздать цепочки ------------------------------------------
if command -v docker >/dev/null 2>&1; then
  info "Перезапускаю Docker (он пересоздаст свои цепочки и NAT)..."
  systemctl restart docker
  sleep 5

  # Контейнеры с restart-политикой поднимутся сами; остальные подтолкнём
  STOPPED="$(docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | grep -i amnezia || true)"
  if [[ -n "${STOPPED}" ]]; then
    while read -r c; do
      [[ -z "${c}" ]] && continue
      info "Поднимаю контейнер ${c}..."
      docker start "${c}" >/dev/null 2>&1 || warn "не удалось запустить ${c}"
    done <<< "${STOPPED}"
    sleep 3
  fi

  RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -ci amnezia || true)"
  if [[ "${RUNNING:-0}" -gt 0 ]]; then
    info "Контейнеров Amnezia запущено: ${RUNNING}"
  else
    err "Контейнеры Amnezia не поднялись — смотри: docker ps -a"
  fi
else
  warn "Docker не установлен — пропускаю."
fi

# --- 4. YouTube-роутинг -------------------------------------------------------
if systemctl list-unit-files 2>/dev/null | grep -q '^sing-box'; then
  info "Перезапускаю sing-box (вернёт маршруты и маркировку)..."
  systemctl restart sing-box
  sleep 3
  if systemctl is-active --quiet sing-box; then
    info "sing-box работает."
  else
    err "sing-box не запустился:  journalctl -u sing-box -n 40 --no-pager -l"
  fi
else
  warn "sing-box не установлен — YouTube-роутинг пропускаю."
fi

# Хелпер мог остаться от старой версии скрипта, где маркировки в нём не было
if [[ -x "${ROUTE_UP}" ]] && ! grep -q mangle "${ROUTE_UP}"; then
  warn "Хелпер ${ROUTE_UP} старой версии — маркировку он не ставит."
  warn "Перенастрой выход заново, чтобы правило переживало перезагрузку:"
  warn "  sudo bash noads-exit/wg-youtube-exit.sh /etc/wireguard/${WG_IF:-wgru}.conf"
  info "Пока что добавляю правило вручную."
  for proto in tcp udp; do
    iptables -t mangle -C PREROUTING -i "${BRIDGE_IF}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}" 2>/dev/null || \
      iptables -t mangle -A PREROUTING -i "${BRIDGE_IF}" -p "${proto}" --dport 443 -j MARK --set-mark "${FWMARK}"
  done
fi

# --- 5. Короткая сверка -------------------------------------------------------
echo
echo "${BLD}Сверка${RST}"
iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE \
  && info "NAT (MASQUERADE) на месте" || err "правил MASQUERADE нет — клиенты не выйдут в интернет"
ip rule show 2>/dev/null | grep -q "fwmark ${FWMARK} lookup ${RT_TABLE}" \
  && info "правило по метке на месте" || warn "нет правила 'fwmark ${FWMARK} lookup ${RT_TABLE}'"
[[ -n "$(ip route show table "${RT_TABLE}" 2>/dev/null)" ]] \
  && info "таблица ${RT_TABLE} заполнена" || warn "таблица ${RT_TABLE} пуста"
iptables -t mangle -S PREROUTING 2>/dev/null | grep -q "MARK --set-xmark ${FWMARK}" \
  && info "маркировка YouTube-трафика на месте" || warn "маркировки нет"

echo
echo "Подробная проверка:  sudo bash check-health.sh"
