#!/usr/bin/env bash
#
# setup-amnezia-dns-redirect.sh
#
# Для случая, когда Amnezia работает в Docker-контейнерах (amnezia-awg и т.п.),
# подключённых к сети `amnezia-dns-net`. Тогда wg-интерфейс спрятан внутри
# контейнера, а AdGuard Home стоит на хосте. Этот скрипт настраивает, чтобы
# ВСЕ VPN-клиенты автоматически ходили в AdGuard на хосте — без правки конфигов
# на каждом устройстве.
#
# Что делает:
#   1. Разрешает порт 53 на хосте из docker-подсети Amnezia.
#   2. Ставит прозрачный перехват DNS (DNAT): любой запрос клиента на порт 53
#      перенаправляется в AdGuard на хосте, даже если в конфиге прописан 1.1.1.1.
#   3. Сохраняет правила, чтобы пережили перезагрузку.
#
# Требуется, чтобы AdGuard Home уже был установлен (см. install-adguard.sh) и
# слушал порт 53 на всех интерфейсах.
#
# Запуск:  sudo bash setup-amnezia-dns-redirect.sh
#
set -euo pipefail

# ---- Настройки (обычно определяются автоматически) -------------------------
DOCKER_NET="${DOCKER_NET:-amnezia-dns-net}"   # имя docker-сети Amnezia
ADGUARD_IP="${ADGUARD_IP:-}"                  # адрес хоста в этой сети (шлюз)
NET_SUBNET="${NET_SUBNET:-}"                  # подсеть этой сети
BRIDGE_IF="${BRIDGE_IF:-}"                    # имя bridge-интерфейса на хосте
# ----------------------------------------------------------------------------

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info()  { echo "${GRN}[+]${RST} $*"; }
warn()  { echo "${YLW}[!]${RST} $*"; }
err()   { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo:  sudo bash $0"; exit 1; }
command -v docker  >/dev/null || { err "docker не найден"; exit 1; }
command -v iptables >/dev/null || { err "iptables не найден"; exit 1; }

# --- Автоопределение параметров docker-сети ---------------------------------
if [[ -z "${ADGUARD_IP}" ]]; then
  ADGUARD_IP="$(docker network inspect "${DOCKER_NET}" \
    -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
fi
if [[ -z "${NET_SUBNET}" ]]; then
  NET_SUBNET="$(docker network inspect "${DOCKER_NET}" \
    -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
fi
[[ -z "${ADGUARD_IP}" || -z "${NET_SUBNET}" ]] && {
  err "Не удалось определить сеть '${DOCKER_NET}'. Проверь: docker network ls"
  err "Или задай вручную: sudo ADGUARD_IP=172.29.172.1 NET_SUBNET=172.29.172.0/24 bash $0"
  exit 1
}
if [[ -z "${BRIDGE_IF}" ]]; then
  BRIDGE_IF="$(ip -o -4 addr show 2>/dev/null | \
    awk -v ip="${ADGUARD_IP}" '$4 ~ "^"ip"/" {print $2; exit}')"
fi
[[ -z "${BRIDGE_IF}" ]] && {
  err "Не удалось определить bridge-интерфейс для ${ADGUARD_IP}."
  err "Задай вручную: sudo BRIDGE_IF=amn0 bash $0"
  exit 1
}

info "Docker-сеть : ${DOCKER_NET}"
info "Подсеть     : ${NET_SUBNET}"
info "AdGuard (хост): ${ADGUARD_IP}"
info "Bridge      : ${BRIDGE_IF}"
echo

# --- Проверка, что AdGuard слушает порт 53 ----------------------------------
if ! ss -tulpn 2>/dev/null | grep -q ':53 '; then
  warn "Никто не слушает порт 53. Сначала установи AdGuard Home (install-adguard.sh)."
fi

# --- 1. Разрешаем DNS из docker-подсети -------------------------------------
info "Разрешаю порт 53 из ${NET_SUBNET}..."
for proto in udp tcp; do
  iptables -C INPUT -p "${proto}" --dport 53 -s "${NET_SUBNET}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p "${proto}" --dport 53 -s "${NET_SUBNET}" -j ACCEPT
done

# --- 2. Прозрачный перехват DNS (DNAT) --------------------------------------
info "Ставлю прозрачный перехват DNS: всё с порта 53 -> ${ADGUARD_IP}..."
for proto in udp tcp; do
  iptables -t nat -C PREROUTING -i "${BRIDGE_IF}" -p "${proto}" --dport 53 \
    ! -d "${ADGUARD_IP}" -j DNAT --to-destination "${ADGUARD_IP}" 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "${BRIDGE_IF}" -p "${proto}" --dport 53 \
    ! -d "${ADGUARD_IP}" -j DNAT --to-destination "${ADGUARD_IP}"
done

# --- 3. Сохраняем правила ----------------------------------------------------
info "Сохраняю правила iptables..."
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
else
  export DEBIAN_FRONTEND=noninteractive
  echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
  echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true
  apt-get install -y iptables-persistent >/dev/null 2>&1 && netfilter-persistent save || \
    warn "Не удалось поставить iptables-persistent. Сохрани правила вручную."
fi

echo
echo "${BLD}Готово!${RST} Все VPN-клиенты теперь ходят в AdGuard автоматически."
echo
echo "Проверка (запрос к 'чужому' DNS должен вернуться от AdGuard):"
echo "  docker exec amnezia-awg nslookup doubleclick.net 1.1.1.1   # ждём 0.0.0.0"
echo
warn "Видео-реклама в самом YouTube так не убирается — нужны клиентские"
warn "решения (uBlock Origin / ReVanced / SmartTube). См. README.md, Часть 2."
