#!/usr/bin/env bash
#
# setup-origin.sh — сервер-источник для схемы «VLESS через российский CDN».
#
# Что делает:
#   1. выпускает сертификат Let's Encrypt для поддомена-источника;
#   2. поднимает отдельный виртуальный хост nginx: по секретному пути трафик
#      уходит в Xray, по любому другому — отдаётся обычный сайт-заглушка;
#   3. ничего не меняет в уже работающих конфигах nginx.
#
# Чем отличается от инструкции в репозитории ServerTechnologies: там конфиг
# пишется поверх /etc/nginx/sites-available/default с директивой default_server,
# что на сервере с уже работающими сайтами сносит их все разом.
#
# Запуск:
#   sudo bash setup-origin.sh --domain origin.example.ru --email me@example.ru
#   sudo bash setup-origin.sh --domain origin.example.ru --email me@example.ru \
#        --port 8081 --path /api/stream
#
set -euo pipefail

DOMAIN=""; EMAIL=""; XRAY_PORT="8081"; SECRET_PATH=""

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[x]${RST} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Запусти с sudo"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email)  EMAIL="${2:-}"; shift 2 ;;
    --port)   XRAY_PORT="${2:-}"; shift 2 ;;
    --path)   SECRET_PATH="${2:-}"; shift 2 ;;
    *) err "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

[[ -n "${DOMAIN}" ]] || { err "Укажи поддомен-источник:  --domain origin.example.ru"; exit 1; }
[[ -n "${EMAIL}"  ]] || { err "Укажи почту для Let's Encrypt:  --email me@example.ru"; exit 1; }
[[ "${XRAY_PORT}" =~ ^[0-9]+$ ]] || { err "--port должен быть числом"; exit 1; }

# Путь по умолчанию — случайный: предсказуемый /api/stream легко перебрать
if [[ -z "${SECRET_PATH}" ]]; then
  SECRET_PATH="/$(head -c 9 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 10)/stream"
  info "Секретный путь сгенерирован: ${SECRET_PATH}"
fi
[[ "${SECRET_PATH}" == /* ]] || SECRET_PATH="/${SECRET_PATH}"

# --- Проверки до изменений ------------------------------------------------------
command -v nginx >/dev/null 2>&1 || { err "nginx не установлен"; exit 1; }
command -v certbot >/dev/null 2>&1 || {
  info "Ставлю certbot из пакетов..."
  apt-get update -qq
  apt-get install -y -qq certbot python3-certbot-nginx
}

SRV_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
RESOLVED="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}')"
if [[ -z "${RESOLVED}" ]]; then
  err "${DOMAIN} не резолвится. Создай A-запись на ${SRV_IP:-адрес сервера} и подожди."
  exit 1
fi
if [[ "${RESOLVED}" != "${SRV_IP}" ]]; then
  err "${DOMAIN} указывает на ${RESOLVED}, а сервер — ${SRV_IP}."
  err "Сертификат не выпустится. Поправь A-запись и повтори."
  exit 1
fi
info "A-запись в порядке: ${DOMAIN} -> ${SRV_IP}"

if ss -tlnp 2>/dev/null | grep -qE "[.:]${XRAY_PORT}[[:space:]]"; then
  err "Порт ${XRAY_PORT} уже занят — выбери другой через --port."
  ss -tlnp | grep -E "[.:]${XRAY_PORT}[[:space:]]" | sed 's/^/    /' >&2
  exit 1
fi

VHOST="/etc/nginx/sites-available/${DOMAIN}"
[[ -e "${VHOST}" ]] && { err "Конфиг ${VHOST} уже существует — убери его или возьми другое имя."; exit 1; }

# --- 1. Сайт-заглушка ------------------------------------------------------------
WEBROOT="/var/www/${DOMAIN}"
mkdir -p "${WEBROOT}"
if [[ ! -f "${WEBROOT}/index.html" ]]; then
  info "Кладу страницу-заглушку в ${WEBROOT}"
  cat > "${WEBROOT}/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Media Gateway</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 0; display: grid;
         place-items: center; min-height: 100vh; background: #f6f7f9; color: #1c1e21; }
  main { text-align: center; padding: 2rem; }
  h1 { font-weight: 600; font-size: 1.5rem; margin: 0 0 .5rem; }
  p  { color: #65676b; margin: 0; }
</style>
</head>
<body>
  <main>
    <h1>Media Gateway</h1>
    <p>Service is running.</p>
  </main>
</body>
</html>
HTMLEOF
fi

# --- 2. Временный хост на 80, чтобы certbot прошёл проверку ----------------------
# Сертификата ещё нет, поэтому ssl-блок писать нельзя: nginx не стартует без файла.
info "Готовлю временный хост для проверки домена..."
cat > "${VHOST}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        root ${WEBROOT};
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOF
ln -sf "${VHOST}" "/etc/nginx/sites-enabled/${DOMAIN}"

if ! nginx -t 2>/dev/null; then
  err "nginx забраковал временный конфиг — откатываю."
  rm -f "/etc/nginx/sites-enabled/${DOMAIN}" "${VHOST}"
  nginx -t
  exit 1
fi
systemctl reload nginx

# --- 3. Сертификат ----------------------------------------------------------------
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
  info "Сертификат для ${DOMAIN} уже есть, выпуск пропускаю."
else
  info "Выпускаю сертификат Let's Encrypt..."
  if ! certbot certonly --webroot -w "${WEBROOT}" -d "${DOMAIN}" \
       --non-interactive --agree-tos -m "${EMAIL}"; then
    err "Certbot не справился. Временный хост оставлен, чтобы можно было повторить."
    err "Частые причины: A-запись не разошлась, порт 80 закрыт снаружи."
    exit 1
  fi
fi

# --- 4. Боевой конфиг --------------------------------------------------------------
info "Пишу рабочий виртуальный хост..."
cat > "${VHOST}" <<EOF
# Сервер-источник для VLESS/XHTTP за CDN. Создан setup-origin.sh.
# Трафик VPN приходит на ${SECRET_PATH} и уходит в Xray на 127.0.0.1:${XRAY_PORT}.
# Всё остальное отдаётся как обычный сайт — чтобы случайный посетитель
# (или проверяющий) видел работающую страницу, а не закрытый порт.

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    # CDN периодически опрашивает источник; отдаём ему дешёвый ответ
    location = /health {
        default_type application/json;
        return 200 '{"status":"ok","service":"media-gateway","version":"4.2.1"}';
    }

    location ${SECRET_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # XHTTP — длинные потоковые запросы. Любая буферизация их ломает:
        # данные копятся в nginx вместо того, чтобы идти клиенту.
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffer_size 32k;
        proxy_buffers 8 32k;
        client_max_body_size 0;
        add_header X-Accel-Buffering no always;
        add_header Cache-Control "no-store, no-transform" always;

        access_log /var/log/nginx/xhttp_access.log;
    }

    location / {
        root ${WEBROOT};
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOF

if ! nginx -t; then
  err "nginx забраковал рабочий конфиг — выключаю хост, остальные сайты не пострадали."
  rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
  exit 1
fi
systemctl reload nginx
info "nginx перезагружен, остальные сайты не затронуты."

# --- 5. Проверка ---------------------------------------------------------------------
echo
info "Проверяю..."
HEALTH="$(curl -s --max-time 10 "https://${DOMAIN}/health" || true)"
[[ "${HEALTH}" == *'"status":"ok"'* ]] && info "https://${DOMAIN}/health отвечает" \
                                       || warn "/health не ответил — проверь DNS и порт 443"

SITE_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMAIN}/" || true)"
[[ "${SITE_CODE}" == "200" ]] && info "сайт-заглушка отдаётся (200)" \
                              || warn "заглушка вернула код ${SITE_CODE}"

# Xray ещё не запущен, так что 502 здесь — правильный ответ
PATH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMAIN}${SECRET_PATH}" || true)"
echo "    секретный путь отвечает кодом ${PATH_CODE} (502 — норма, пока Xray не поднят)"

cat <<SUMMARY

${BLD}Источник готов${RST}
  домен        : ${DOMAIN}
  секретный путь: ${SECRET_PATH}
  порт Xray    : 127.0.0.1:${XRAY_PORT}
  корень сайта : ${WEBROOT}
  сертификат   : ${CERT_DIR}

${BLD}Дальше${RST}
  1. Поставить 3x-ui:
       bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
     Панель лучше повесить на 127.0.0.1 и ходить в неё через SSH-туннель —
     иначе она торчит в интернет. Туннель с твоей машины:
       ssh -p 4118 -L 2053:127.0.0.1:2053 root@${SRV_IP}

  2. В панели обновить ЯДРО Xray (не версию панели) — нужен выпуск с
     поддержкой uplinkHTTPMethod, иначе через CDN ничего не пойдёт.

  3. Создать входящее подключение по шаблону из инструкции, указав
     порт ${XRAY_PORT} и path ${SECRET_PATH}.

  4. Yandex Cloud: сертификат в Certificate Manager на второй домен
     (тот, что пойдёт в CNAME), затем CDN-ресурс с источником ${DOMAIN}.

${BLD}Если что-то пойдёт не так${RST}
  Выключить этот хост, не трогая остальные:
     rm /etc/nginx/sites-enabled/${DOMAIN} && systemctl reload nginx
SUMMARY
