#!/usr/bin/env bash
#
# archive-site.sh — собрать сайт в один архив, а потом (отдельным запуском)
# аккуратно снести его с сервера.
#
# Сайт — это не только папка с кодом: ещё конфиги nginx, systemd-юнит,
# сертификаты Let's Encrypt и база. Удалять по частям руками — верный способ
# что-нибудь забыть, а потом обнаружить, что нужное уже не вернуть.
#
# Два режима, и это намеренно:
#
#   Архивация (по умолчанию) — только читает:
#     sudo bash archive-site.sh --domain example.ru --app-dir /opt/App \
#          --service appsvc --db appdb
#
#   Удаление — требует готовый архив и проверяет его перед тем, как что-то тронуть:
#     sudo bash archive-site.sh --remove --archive /root/archives/example.ru-….tar.gz \
#          --domain example.ru --app-dir /opt/App --service appsvc --db appdb
#
set -euo pipefail

DOMAIN=""; APP_DIR=""; SERVICE=""; ARCHIVE=""; OUT_DIR="/root/archives"
REMOVE=0; ASSUME_YES=0
KEEP=()   # поддомены, которые остаются жить
DBS=()    # базы; --db можно указать несколько раз

# postgres не может зайти в /root и сыплет предупреждениями — работаем из /tmp
pg() { (cd /tmp && sudo -u postgres "$@"); }

# systemctl list-unit-files показывает не всё: отключённый или нестандартно
# установленный юнит в выдачу может не попасть, а systemctl cat находит его всегда
service_exists() {
  systemctl cat "$1" >/dev/null 2>&1 && return 0
  local f
  for f in "/etc/systemd/system/$1.service" "/lib/systemd/system/$1.service" \
           "/usr/lib/systemd/system/$1.service"; do
    [[ -f "${f}" ]] && return 0
  done
  return 1
}

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }
hdr()  { echo; echo "${BLD}$*${RST}"; printf '%s\n' "------------------------------------------------------------"; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)  DOMAIN="${2:-}"; shift 2 ;;
    --app-dir) APP_DIR="${2:-}"; shift 2 ;;
    --service) SERVICE="${2:-}"; shift 2 ;;
    --db)      DBS+=("${2:-}"); shift 2 ;;
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --out)     OUT_DIR="${2:-}"; shift 2 ;;
    --keep)    KEEP+=("${2:-}"); shift 2 ;;
    --remove)  REMOVE=1; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    *) err "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

[[ -n "${DOMAIN}" ]] || { err "Укажи домен:  --domain example.ru"; exit 1; }

# Остаётся ли это имя жить
is_kept() {
  local name="$1" k
  for k in ${KEEP+"${KEEP[@]}"}; do
    [[ "${name}" == "${k}" ]] && return 0
  done
  return 1
}

# Конфиги nginx ищем по содержимому, а не по имени файла: вхост может
# называться как угодно, а домен внутри — это факт. Файлы, где встречается
# сохраняемый поддомен, пропускаем целиком: лучше оставить лишнее, чем снести
# работающий сайт.
find_vhosts() {
  local f k
  while read -r f; do
    [[ -z "${f}" ]] && continue
    local skip=0
    for k in ${KEEP+"${KEEP[@]}"}; do
      if grep -qE "server_name[^;]*(^|[[:space:].])${k//./\\.}([[:space:];]|$)" "${f}" 2>/dev/null; then
        skip=1; break
      fi
    done
    [[ "${skip}" == "0" ]] && echo "${f}"
  done < <(grep -rlE "server_name[^;]*(^|[[:space:].])${DOMAIN//./\\.}" \
             /etc/nginx/sites-available/ /etc/nginx/conf.d/ 2>/dev/null || true)
  # Без этого функция возвращает статус последней проверки: если последний файл
  # оказался сохраняемым, под set -e скрипт молча обрывался прямо здесь.
  return 0
}

# Сертификаты: и сам домен, и его поддомены, кроме сохраняемых
find_certs() {
  local d name
  for d in /etc/letsencrypt/live/*/; do
    [[ -d "${d}" ]] || continue
    name="$(basename "${d}")"
    [[ "${name}" == "${DOMAIN}" || "${name}" == *".${DOMAIN}" ]] || continue
    is_kept "${name}" && continue
    echo "${name}"
  done
  return 0
}

############################################################################
# РЕЖИМ 1: архивация
############################################################################
if [[ "${REMOVE}" == "0" ]]; then
  hdr "Что относится к ${DOMAIN}"

  if [[ ${#KEEP[@]} -gt 0 ]]; then
    echo "  ${YLW}остаются нетронутыми:${RST} ${KEEP[*]}"
    echo
  fi

  VHOSTS="$(find_vhosts)"
  if [[ -n "${VHOSTS}" ]]; then
    echo "  конфиги nginx:"; echo "${VHOSTS}" | sed 's/^/    /'
  else
    warn "конфигов nginx с этим доменом не найдено"
  fi

  CERTS="$(find_certs)"
  if [[ -n "${CERTS}" ]]; then
    echo "  сертификаты:"; echo "${CERTS}" | sed 's/^/    /'
  else
    echo "  сертификаты: не найдены"
  fi

  if [[ -n "${APP_DIR}" ]]; then
    if [[ -d "${APP_DIR}" ]]; then
      echo "  код: ${APP_DIR} ($(du -sh "${APP_DIR}" 2>/dev/null | cut -f1))"
    else
      warn "каталог ${APP_DIR} не существует"
      APP_DIR=""
    fi
  fi

  if [[ -n "${SERVICE}" ]]; then
    if service_exists "${SERVICE}"; then
      echo "  служба: ${SERVICE} ($(systemctl is-active "${SERVICE}" 2>/dev/null || true), $(systemctl is-enabled "${SERVICE}" 2>/dev/null || true))"
    else
      warn "служба ${SERVICE} не найдена"
      SERVICE=""
    fi
  fi

  if [[ ${#DBS[@]} -gt 0 ]]; then
    for _db in "${DBS[@]}"; do
      if pg psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "${_db}"; then
        SIZE="$(pg psql -tAc "SELECT pg_size_pretty(pg_database_size('${_db}'))" 2>/dev/null || echo '?')"
        echo "  база: ${_db} (${SIZE})"
      else
        err "базы ${_db} в PostgreSQL нет. Список:"
        pg psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -v '^\s*$' | sed 's/^/    /'
        exit 1
      fi
    done
  else
    warn "базы не указаны (--db) — в архив не попадут"
  fi

  # --- Собираем ---------------------------------------------------------------
  hdr "Собираю архив"
  mkdir -p "${OUT_DIR}"
  STAMP="$(date +%Y%m%d-%H%M)"
  WORK="$(mktemp -d)"
  trap 'rm -rf "${WORK}"' EXIT
  STAGE="${WORK}/${DOMAIN}"
  mkdir -p "${STAGE}"/{nginx,systemd,letsencrypt,db,app}

  if [[ -n "${VHOSTS}" ]]; then
    while read -r f; do
      [[ -n "${f}" ]] && cp -a "${f}" "${STAGE}/nginx/" || true
    done <<< "${VHOSTS}"
    # Какие из них были включены — иначе при восстановлении не угадать
    ls -la /etc/nginx/sites-enabled/ > "${STAGE}/nginx/_sites-enabled.txt" 2>/dev/null || true
    info "конфиги nginx сохранены"
  fi

  if [[ -n "${SERVICE}" ]]; then
    systemctl cat "${SERVICE}" > "${STAGE}/systemd/${SERVICE}.txt" 2>/dev/null || true
    for p in "/etc/systemd/system/${SERVICE}.service" "/etc/systemd/system/${SERVICE}.service.d"; do
      [[ -e "${p}" ]] && cp -a "${p}" "${STAGE}/systemd/" || true
    done
    info "юнит ${SERVICE} сохранён"
  fi

  if [[ -n "${CERTS}" ]]; then
    while read -r c; do
      [[ -z "${c}" ]] && continue
      # live — это симлинки в archive, поэтому копируем и то, и другое
      cp -rL "/etc/letsencrypt/live/${c}" "${STAGE}/letsencrypt/${c}" 2>/dev/null || true
      [[ -f "/etc/letsencrypt/renewal/${c}.conf" ]] && \
        cp -a "/etc/letsencrypt/renewal/${c}.conf" "${STAGE}/letsencrypt/" || true
    done <<< "${CERTS}"
    info "сертификаты сохранены"
  fi

  for _db in ${DBS+"${DBS[@]}"}; do
    info "Выгружаю базу ${_db} (это может занять время)..."
    DUMP_ERR="${WORK}/${_db}.stderr"
    # Ошибки pg_dump НЕ прячем: молчаливо усечённый дамп — худшее, что может
    # случиться с архивом, который делают перед удалением
    if ! pg pg_dump -Fc "${_db}" > "${STAGE}/db/${_db}.dump" 2>"${DUMP_ERR}"; then
      err "pg_dump не справился с ${_db} — архив не собран, ничего не удалено:"
      sed 's/^/    /' "${DUMP_ERR}" >&2
      exit 1
    fi
    [[ -s "${DUMP_ERR}" ]] && { warn "pg_dump что-то сообщил по ${_db}:"; sed 's/^/    /' "${DUMP_ERR}"; }

    # Сверяем дамп с базой по числу строк: размер файла обманчив, потому что
    # объём базы складывается в основном из индексов и неубранного мусора
    ROWS_DB="$(pg psql -tAd "${_db}" -c \
      "SELECT COALESCE(SUM(n_live_tup),0) FROM pg_stat_user_tables" 2>/dev/null || echo '?')"
    TABLES_DUMP="$(pg_restore -l "${STAGE}/db/${_db}.dump" 2>/dev/null | grep -c 'TABLE DATA' || true)"
    info "база ${_db}: $(du -sh "${STAGE}/db/${_db}.dump" | cut -f1), таблиц с данными ${TABLES_DUMP}, строк в базе ${ROWS_DB}"
    if [[ "${ROWS_DB}" =~ ^[0-9]+$ && "${ROWS_DB}" -gt 0 && "${TABLES_DUMP}" -eq 0 ]]; then
      err "В базе есть строки, но в дампе нет ни одной таблицы с данными."
      err "Архив негодный — ничего не удаляй."
      exit 1
    fi
  done

  if [[ -n "${APP_DIR}" ]]; then
    info "Копирую код из ${APP_DIR}..."
    # venv и node_modules восстанавливаются установкой зависимостей, место зря не тратим
    tar -cf - -C "$(dirname "${APP_DIR}")" \
        --exclude='*/node_modules' --exclude='*/venv' --exclude='*/.venv' \
        --exclude='*/__pycache__' --exclude='*/.git/objects' \
        "$(basename "${APP_DIR}")" | tar -xf - -C "${STAGE}/app/"
    info "код скопирован"
  fi

  # Опись: без неё через полгода не вспомнить, что откуда
  cat > "${STAGE}/MANIFEST.txt" <<MEOF
Архив сайта ${DOMAIN}
Собран: $(date -Is)
Сервер: $(hostname) $(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')

Что внутри:
  nginx/        конфиги виртуальных хостов (+ список включённых на момент архивации)
  systemd/      юнит службы ${SERVICE:-—} и его drop-in'ы
  letsencrypt/  сертификаты и файлы обновления
  db/           дампы PostgreSQL (${DBS[*]:-—}), формат custom (pg_restore)
  app/          код из ${APP_DIR:-—} без node_modules, venv и кэшей

Как восстановить:
  база   : sudo -u postgres createdb ИМЯ
           sudo -u postgres pg_restore -d ИМЯ db/ИМЯ.dump
  код    : скопировать app/ обратно, поставить зависимости заново
  nginx  : вернуть файлы в /etc/nginx/sites-available/, создать симлинки, nginx -t
  служба : вернуть юнит, systemctl daemon-reload, systemctl enable --now
  сертиф.: проще выпустить заново через certbot, чем восстанавливать
MEOF

  ARCHIVE_PATH="${OUT_DIR}/${DOMAIN}-${STAMP}.tar.gz"
  tar -czf "${ARCHIVE_PATH}" -C "${WORK}" "${DOMAIN}"
  chmod 600 "${ARCHIVE_PATH}"

  # Проверяем, что архив читается — без этого «архив готов» ничего не значит
  if ! tar -tzf "${ARCHIVE_PATH}" >/dev/null 2>&1; then
    err "Архив не читается! Ничего не удаляй."
    exit 1
  fi

  hdr "Готово"
  echo "  архив : ${ARCHIVE_PATH}"
  echo "  размер: $(du -sh "${ARCHIVE_PATH}" | cut -f1)"
  echo
  echo "В архиве есть приватные ключи сертификатов — права 600, никуда не выкладывай."
  echo
  echo "Скачать к себе:"
  echo "  scp -P 4118 root@$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'):${ARCHIVE_PATH} ."
  echo
  echo "Посмотреть содержимое:"
  echo "  tar -tzf ${ARCHIVE_PATH}"
  echo
  echo "${BLD}Скачай и проверь архив, и только потом удаляй:${RST}"
  DB_ARGS=""; for _db in ${DBS+"${DBS[@]}"}; do DB_ARGS+=" --db ${_db}"; done
  KEEP_ARGS=""; for _k in ${KEEP+"${KEEP[@]}"}; do KEEP_ARGS+=" --keep ${_k}"; done
  echo "  sudo bash archive-site.sh --remove --archive ${ARCHIVE_PATH} \\"
  echo "    --domain ${DOMAIN}${KEEP_ARGS}${APP_DIR:+ --app-dir ${APP_DIR}}${SERVICE:+ --service ${SERVICE}}${DB_ARGS}"
  exit 0
fi

############################################################################
# РЕЖИМ 2: удаление
############################################################################
[[ -n "${ARCHIVE}" ]] || { err "Удаление без архива не делаю. Укажи --archive"; exit 1; }
[[ -f "${ARCHIVE}" ]] || { err "Архива ${ARCHIVE} нет"; exit 1; }

hdr "Проверяю архив"
tar -tzf "${ARCHIVE}" >/dev/null 2>&1 || { err "Архив повреждён — удаление отменено"; exit 1; }
LIST="$(tar -tzf "${ARCHIVE}")"
info "архив читается, файлов: $(echo "${LIST}" | wc -l)"

# Сверяем, что в архиве действительно лежит то, что собираемся удалять
# Ищем сопоставлением строк, а не через "echo | grep -q": grep закрывает ввод на
# первом же совпадении, echo получает SIGPIPE, и при pipefail успешная проверка
# выглядит провалившейся — тем вернее, чем раньше в списке нашлось нужное.
for _db in ${DBS+"${DBS[@]}"}; do
  [[ "${LIST}" == *"db/${_db}.dump"* ]] \
    || { err "В архиве нет дампа базы ${_db} — удаление отменено"; exit 1; }
  info "дамп базы ${_db} на месте"
done
if [[ -n "${APP_DIR}" ]]; then
  [[ "${LIST}" == *"app/$(basename "${APP_DIR}")/"* ]] \
    || { err "В архиве нет кода из ${APP_DIR} — удаление отменено"; exit 1; }
  info "код на месте"
fi

hdr "Будет удалено"
VHOSTS="$(find_vhosts)"
[[ -n "${VHOSTS}" ]] && { echo "  конфиги nginx:"; echo "${VHOSTS}" | sed 's/^/    /'; } || true
[[ -n "${SERVICE}" ]] && echo "  служба: ${SERVICE} (остановлена и отключена)" || true
[[ -n "${APP_DIR}" && -d "${APP_DIR}" ]] && echo "  каталог: ${APP_DIR}" || true
[[ ${#DBS[@]} -gt 0 ]] && echo "  базы PostgreSQL: ${DBS[*]}" || true
CERTS="$(find_certs)"
[[ -n "${CERTS}" ]] && { echo "  сертификаты:"; echo "${CERTS}" | sed 's/^/    /'; } || true
echo
echo "  ${YLW}Остальные сайты и службы не затрагиваются.${RST}"

if [[ "${ASSUME_YES}" == "0" ]]; then
  echo
  read -r -p "Введи UDALIT заглавными, чтобы подтвердить: " CONFIRM
  [[ "${CONFIRM}" == "UDALIT" ]] || { info "Отменено, ничего не тронуто."; exit 0; }
fi

hdr "Удаляю"

if [[ -n "${SERVICE}" ]] && service_exists "${SERVICE}"; then
  systemctl disable --now "${SERVICE}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  rm -rf "/etc/systemd/system/${SERVICE}.service.d"
  systemctl daemon-reload
  info "служба ${SERVICE} остановлена и удалена"
fi

if [[ -n "${VHOSTS}" ]]; then
  while read -r f; do
    [[ -z "${f}" ]] && continue
    rm -f "/etc/nginx/sites-enabled/$(basename "${f}")"
    rm -f "${f}"
  done <<< "${VHOSTS}"
  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    info "конфиги nginx удалены, остальные сайты работают"
  else
    err "nginx ругается на оставшуюся конфигурацию — проверь:  nginx -t"
  fi
fi

for _db in ${DBS+"${DBS[@]}"}; do
  pg dropdb --if-exists "${_db}" && info "база ${_db} удалена" \
    || warn "не удалось удалить базу ${_db}"
done

if [[ -n "${APP_DIR}" && -d "${APP_DIR}" ]]; then
  rm -rf "${APP_DIR}"
  info "каталог ${APP_DIR} удалён"
fi

if [[ -n "${CERTS}" ]] && command -v certbot >/dev/null 2>&1; then
  while read -r c; do
    [[ -z "${c}" ]] && continue
    certbot delete --cert-name "${c}" --non-interactive >/dev/null 2>&1 \
      && info "сертификат ${c} удалён" || warn "сертификат ${c} удалить не вышло"
  done <<< "${CERTS}"
fi

hdr "Готово"
echo "  Архив остался: ${ARCHIVE}"
if [[ ${#KEEP[@]} -gt 0 ]]; then
  echo "  Зону ${DOMAIN} у регистратора НЕ удаляй — на ней живёт ${KEEP[*]}."
  echo "  Снять можно только записи удалённого сайта."
else
  echo "  Не забудь снять DNS-записи домена у регистратора."
fi
