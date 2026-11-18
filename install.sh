#!/bin/sh
# ============================================================================
# telemt-web-proxy — автоустановка Telemt (MTProto + WEB) прокси для Telegram
#
# Разворачивает:
#   * бинарь telemt из релизов github.com/telemt/telemt (с проверкой sha256)
#   * /etc/telemt/config.toml: MTProxy-listener + WEB-listener на loopback
#   * nginx: TLS-терминацию и проксирование на WEB-listener
#   * Let's Encrypt сертификат через certbot (webroot, порт 80)
#   * systemd-юнит telemt.service
#
# Режимы работы nginx (--mode):
#   direct — nginx сам слушает 443 и терминирует TLS (чистый сервер);
#   sni    — stream-блок с ssl_preread на 443: домен прокси -> TLS-vhost
#            на loopback, остальной SNI -> fallback-бэкенд (напр. xray).
#
# Использование:
#   curl -fsSL <raw-url>/install.sh | sh
#   sh install.sh --domain proxy.example.com --mode sni --sni-fallback 127.0.0.1:7443
# ============================================================================
set -eu

# ------------------------------ параметры -----------------------------------
REPO="telemt/telemt"
BIN_NAME="telemt"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/telemt"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
WORK_DIR="/opt/telemt"
SERVICE_NAME="telemt"

DOMAIN=""                  # публичный FQDN; по умолчанию <IP>.sslip.io
PUBLIC_IP=""               # автодетект, можно переопределить --ip
PUBLIC_PORT=443            # публичный HTTPS-порт (nginx listen / stream listen)
MODE="direct"              # direct | sni
SNI_FALLBACK="127.0.0.1:7443"
WEB_PORT=18080             # loopback WEB-listener telemt
MTPROXY_PORT=18443         # loopback MTProto-listener telemt
MTPROXY_PUBLIC=0           # 1 -> MTProto слушает 0.0.0.0
TLS_VHOST_PORT=18444       # loopback TLS-vhost nginx (только режим sni)
DECOY_PORT=8080            # loopback-порт встроенного decoy-сайта
DECOY_UPSTREAM=""          # внешний decoy, напр. http://127.0.0.1:8080
DECOY_GIVEN=0              # 1 -> --decoy передан, встроенный сайт не ставим
SECRET=""                  # 32 hex; генерируется, если не задан
SECRET_MODE="dd"           # dd | plain
USER_NAME="webuser"
CARRIER="https"            # https | https-lanes | websocket | websocket-lanes
BASE_PATH=""               # base_path vhost'а, напр. telegram/web
VERSION="latest"           # тег релиза telemt или latest
EMAIL=""                   # e-mail для certbot (иначе --register-unsafely-without-email)
LOG_LEVEL="normal"         # debug|verbose|normal|silent
MAX_SESSIONS=16
MAX_STREAMS=512
MAX_STREAMS_PER_SESSION=64
DO_UNINSTALL=0
DO_PURGE=0
SKIP_CERT=0

SUDO=""
TEMP_DIR=""

# ------------------------------ утилиты -------------------------------------
say()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

  --domain FQDN          публичный домен (по умолчанию <публичный-IP>.sslip.io)
  --ip A.B.C.D           публичный IP (автодетект, если не задан)
  --port N               публичный HTTPS-порт (def 443; tg://webproxy требует 443)
  --mode direct|sni      direct: nginx держит 443 сам;
                         sni: ssl_preread на 443, домен -> loopback TLS-vhost
  --sni-fallback H:P     куда слать прочий SNI в режиме sni (def 127.0.0.1:7443)
  --secret HEX32         секрет пользователя (генерируется автоматически)
  --secret-mode dd|plain режим секрета для WEB-ссылки (def dd)
  --user NAME            имя пользователя прокси (def webuser)
  --carrier C            https|https-lanes|websocket|websocket-lanes (def https)
  --base-path P          base_path vhost'а, напр. telegram/web (def пусто)
  --web-port N           loopback порт WEB-listener telemt (def 18080)
  --mtproxy-port N       порт MTProto-listener (def 18443, loopback)
  --tls-vhost-port N     loopback порт TLS-vhost nginx в режиме sni (def 18444)
  --mtproxy-public       MTProto-listener на 0.0.0.0 (выдаст tg://proxy ссылку)
  --decoy URL            внешний decoy-upstream, напр. http://127.0.0.1:8080
                         (по умолчанию ставится встроенный статический сайт)
  --email EMAIL          e-mail для Let's Encrypt
  --version TAG          версия telemt (def latest)
  --skip-cert            пропустить выпуск сертификата (если уже есть)
  --uninstall            удалить сервис и конфиги (оставить данные)
  --purge                uninstall + удалить бинарь, конфиги, данные, юзера
  -h, --help             эта справка
EOF
    exit 0
}

need_root() {
    if [ "$(id -u)" -eq 0 ]; then SUDO="";
    elif command -v sudo >/dev/null 2>&1; then SUDO="sudo";
    else die "нужен root или sudo"; fi
}

fetch() { # url dst
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2";
    elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1";
    else die "нужен curl или wget"; fi
}

fetch_stdout() { # url
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1";
    else wget -q -O - "$1"; fi
}

pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
    elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y "$@"
    elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -Sy --noconfirm "$@"
    elif command -v apk >/dev/null 2>&1; then $SUDO apk add "$@"
    else die "неизвестный пакетный менеджер — установите вручную: $*"; fi
}

detect_arch() {
    a="$(uname -m)"
    case "$a" in
        x86_64|amd64)
            if grep -q avx2 /proc/cpuinfo 2>/dev/null && grep -q bmi2 /proc/cpuinfo 2>/dev/null; then
                echo "x86_64-v3"   # v3-сборка; при 404 откатимся на x86_64
            else echo "x86_64"; fi ;;
        aarch64|arm64) echo "aarch64" ;;
        *) die "неподдерживаемая архитектура: $a" ;;
    esac
}

detect_libc() {
    if command -v ldd >/dev/null 2>&1 && (ldd --version 2>&1 || true) | grep -qi musl; then
        echo "musl"; return
    fi
    grep -qE '^ID="?alpine"?' /etc/os-release 2>/dev/null && { echo "musl"; return; }
    echo "gnu"
}

gen_secret() {
    s="$(command -v openssl >/dev/null 2>&1 && openssl rand -hex 16 2>/dev/null || true)"
    [ "${#s}" -eq 32 ] || s="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "${#s}" -eq 32 ] || die "не удалось сгенерировать секрет"
    echo "$s"
}

detect_public_ip() {
    for url in ifconfig.me api.ipify.org ipinfo.io/ip; do
        ip="$(fetch_stdout "https://$url" 2>/dev/null | tr -d '[:space:]' || true)" || true
        case "$ip" in
            ''|*[!0-9.]*) continue ;;
            *) echo "$ip"; return 0 ;;
        esac
    done
    return 1
}

# nginx >= 1.25.1 использует директиву "http2 on;", старые — "listen ... http2"
nginx_http2_modern() {
    v="$(nginx -v 2>&1 | sed 's/.*nginx\///' | tr -d ' ')"
    major="$(printf '%s' "$v" | cut -d. -f1)"; minor="$(printf '%s' "$v" | cut -d. -f2)"
    [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 25 ]; }
}

# ------------------------------ аргументы -----------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --domain)          DOMAIN="$2"; shift 2 ;;
        --ip)              PUBLIC_IP="$2"; shift 2 ;;
        --port)            PUBLIC_PORT="$2"; shift 2 ;;
        --mode)            MODE="$2"; shift 2 ;;
        --sni-fallback)    SNI_FALLBACK="$2"; shift 2 ;;
        --secret)          SECRET="$2"; shift 2 ;;
        --secret-mode)     SECRET_MODE="$2"; shift 2 ;;
        --user)            USER_NAME="$2"; shift 2 ;;
        --carrier)         CARRIER="$2"; shift 2 ;;
        --base-path)       BASE_PATH="$2"; shift 2 ;;
        --web-port)        WEB_PORT="$2"; shift 2 ;;
        --mtproxy-port)    MTPROXY_PORT="$2"; shift 2 ;;
        --tls-vhost-port)  TLS_VHOST_PORT="$2"; shift 2 ;;
        --mtproxy-public)  MTPROXY_PUBLIC=1; shift ;;
        --decoy)           DECOY_UPSTREAM="$2"; DECOY_GIVEN=1; shift 2 ;;
        --email)           EMAIL="$2"; shift 2 ;;
        --version)         VERSION="$2"; shift 2 ;;
        --log-level)       LOG_LEVEL="$2"; shift 2 ;;
        --skip-cert)       SKIP_CERT=1; shift ;;
        --uninstall)       DO_UNINSTALL=1; shift ;;
        --purge)           DO_UNINSTALL=1; DO_PURGE=1; shift ;;
        -h|--help)         usage ;;
        *) die "неизвестная опция: $1 (см. --help)" ;;
    esac
done

[ "$MODE" = "direct" ] || [ "$MODE" = "sni" ] || die "--mode: только direct или sni"
[ "$SECRET_MODE" = "dd" ] || [ "$SECRET_MODE" = "plain" ] || die "--secret-mode: dd или plain"
case "$PUBLIC_PORT" in ''|*[!0-9]*) die "--port должен быть числом" ;; esac
[ "$PUBLIC_PORT" -ge 1 ] && [ "$PUBLIC_PORT" -le 65535 ] || die "--port: диапазон 1-65535"

STREAM_BEGIN="# >>> telemt-web-proxy stream >>>"
STREAM_END="# <<< telemt-web-proxy stream <<<"

# ------------------------------ uninstall -----------------------------------
do_uninstall() {
    need_root
    say ">>> Удаление telemt-web-proxy"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload || true
    fi
    rm -f /etc/nginx/conf.d/telemt-*.conf 2>/dev/null || true
    # убираем наш stream-блок из nginx.conf (между маркерами)
    if [ -f /etc/nginx/nginx.conf ] && grep -qF "$STREAM_BEGIN" /etc/nginx/nginx.conf; then
        sed -i "/$(printf '%s' "$STREAM_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$STREAM_END" | sed 's/[][\.*^$/]/\\&/g')/d" /etc/nginx/nginx.conf
        say "  stream-блок удалён из nginx.conf"
    fi
    rm -f /etc/letsencrypt/renewal-hooks/deploy/telemt-nginx.sh
    if command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi
    if [ "$DO_PURGE" -eq 1 ]; then
        rm -rf "$CONFIG_DIR" "$WORK_DIR" /var/www/telemt-decoy
        rm -f "${INSTALL_DIR}/${BIN_NAME}"
        id telemt >/dev/null 2>&1 && userdel telemt 2>/dev/null || true
        say "  бинарь, конфигурация, данные и пользователь telemt удалены"
        say "  сертификаты Let's Encrypt оставлены в /etc/letsencrypt"
    fi
    say ">>> Готово"
    exit 0
}

[ "$DO_UNINSTALL" -eq 1 ] && do_uninstall

# ------------------------------ установка -----------------------------------
need_root
say ">>> [1/9] Проверка окружения"
command -v systemctl >/dev/null 2>&1 || die "нужен systemd"
for c in tar gzip sed awk grep dd od tr; do
    command -v "$c" >/dev/null 2>&1 || die "не найдена команда: $c"
done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || pkg_install curl

if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(detect_public_ip)" || die "не удалось определить публичный IP — задайте --ip"
fi
say "  публичный IP: $PUBLIC_IP"

if [ -z "$DOMAIN" ]; then
    DOMAIN="${PUBLIC_IP}.sslip.io"   # magic-DNS, как на эталонном сервере
    say "  домен не задан — используем $DOMAIN"
fi

if [ -z "$SECRET" ]; then SECRET="$(gen_secret)"; fi
case "$SECRET" in *[!0-9a-fA-F]*) die "секрет должен быть hex" ;; esac
[ "${#SECRET}" -eq 32 ] || die "секрет должен быть ровно 32 hex-символа"
SECRET="$(printf '%s' "$SECRET" | tr 'A-F' 'a-f')"

[ -z "$DECOY_UPSTREAM" ] && DECOY_UPSTREAM="http://127.0.0.1:${DECOY_PORT}"

say ">>> [2/9] Установка пакетов: nginx, certbot, openssl"
# в режиме sni нужен stream-модуль nginx (ssl_preread)
STREAM_PKG=""
if [ "$MODE" = "sni" ]; then
    if command -v apt-get >/dev/null 2>&1; then STREAM_PKG="libnginx-mod-stream"
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then STREAM_PKG="nginx-mod-stream"
    elif command -v apk >/dev/null 2>&1; then STREAM_PKG="nginx-mod-stream"
    fi
fi
# shellcheck disable=SC2086
pkg_install nginx certbot openssl $STREAM_PKG 2>/dev/null || pkg_install nginx certbot openssl || true
command -v nginx >/dev/null 2>&1 || die "nginx не установлен"
command -v certbot >/dev/null 2>&1 || die "certbot не установлен"

say ">>> [3/9] Пользователь и каталоги"
if ! id telemt >/dev/null 2>&1; then
    nologin_bin="$(command -v nologin 2>/dev/null || echo /bin/false)"
    groupadd -r telemt 2>/dev/null || true
    useradd -r -g telemt -d "$WORK_DIR" -s "$nologin_bin" -c "Telemt Proxy" telemt 2>/dev/null \
        || useradd -r -d "$WORK_DIR" -s "$nologin_bin" telemt
fi
mkdir -p "$WORK_DIR" "$CONFIG_DIR" /var/www/acme
chown telemt:telemt "$WORK_DIR"; chmod 750 "$WORK_DIR"
chown telemt:telemt "$CONFIG_DIR"; chmod 750 "$CONFIG_DIR"

say ">>> [4/9] ACME-виртхост на :80 и decoy-сайт"

# :80 — только ACME-challenge и редирект на https (с портом, если не 443)
if [ "$PUBLIC_PORT" -eq 443 ]; then HTTPS_REDIRECT='https://$host$request_uri';
else HTTPS_REDIRECT="https://\$host:${PUBLIC_PORT}\$request_uri"; fi
cat > /etc/nginx/conf.d/telemt-acme.conf <<EOF
# telemt-web-proxy: ACME http-01 + редирект
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 ${HTTPS_REDIRECT}; }
}
EOF

# встроенный decoy — минимальная заглушка на loopback (только если --decoy не задан)
if [ "$DECOY_GIVEN" -eq 0 ]; then
    mkdir -p /var/www/telemt-decoy
    cat > /var/www/telemt-decoy/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Welcome</title>
<style>body{font-family:sans-serif;background:#f4f6f8;color:#333;text-align:center;padding:60px 20px}
.card{max-width:520px;margin:auto;background:#fff;border-radius:12px;padding:32px;box-shadow:0 4px 16px rgba(0,0,0,.08)}
h1{font-size:22px;margin:0 0 8px}p{color:#667;font-size:14px}</style></head>
<body><div class="card"><h1>It works</h1>
<p>This site is under construction. Please check back later.</p></div></body></html>
EOF
    cat > /etc/nginx/conf.d/telemt-decoy.conf <<EOF
# telemt-web-proxy: decoy-сайт для маскировки (только loopback)
server {
    listen 127.0.0.1:${DECOY_PORT};
    server_name _;
    root /var/www/telemt-decoy;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
fi

nginx -t 2>/dev/null || { # конфликт default_server на :80 — убираем флаг
    sed -i 's/listen 80 default_server;/listen 80;/' /etc/nginx/conf.d/telemt-acme.conf
    nginx -t || die "nginx -t не прошёл — проверьте конфигурацию"
}
systemctl enable --now nginx 2>/dev/null || systemctl restart nginx

say ">>> [5/9] Сертификат Let's Encrypt для $DOMAIN"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
if [ "$SKIP_CERT" -eq 0 ] && [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
    if [ -n "$EMAIL" ]; then CB_AUTH="--email $EMAIL"; else CB_AUTH="--register-unsafely-without-email"; fi
    # shellcheck disable=SC2086
    certbot certonly --webroot -w /var/www/acme -d "$DOMAIN" \
        --non-interactive --agree-tos $CB_AUTH \
        || die "certbot не выпустил сертификат. Проверьте DNS ($DOMAIN -> $PUBLIC_IP) и порт 80"
else
    say "  сертификат уже есть или --skip-cert — пропускаю"
fi
[ -f "${CERT_DIR}/fullchain.pem" ] || die "нет ${CERT_DIR}/fullchain.pem"

# хук: перезагрузка nginx после продления
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/telemt-nginx.sh <<'EOF'
#!/bin/sh
nginx -t && systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/telemt-nginx.sh

say ">>> [6/9] Загрузка telemt ($VERSION)"
TEMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TEMP_DIR"' EXIT
ARCH="$(detect_arch)"; LIBC="$(detect_libc)"
download_telemt() { # arch
    f="${BIN_NAME}-$1-linux-${LIBC}.tar.gz"
    if [ "$VERSION" = "latest" ]; then
        base="https://github.com/${REPO}/releases/latest/download"
    else
        base="https://github.com/${REPO}/releases/download/${VERSION}"
    fi
    fetch "${base}/${f}" "${TEMP_DIR}/telemt.tar.gz" || return 1
    if fetch "${base}/${f}.sha256" "${TEMP_DIR}/telemt.sha256" 2>/dev/null; then
        exp="$(awk '{print $1}' "${TEMP_DIR}/telemt.sha256" | head -1)"
        act="$(sha256sum "${TEMP_DIR}/telemt.tar.gz" | awk '{print $1}')"
        [ -n "$exp" ] && [ "$exp" = "$act" ] || die "sha256 не сошёлся"
    else
        warn "sha256-манифест не найден — пропускаю проверку"
    fi
}
if [ "$ARCH" = "x86_64-v3" ]; then
    download_telemt x86_64-v3 || { warn "v3-сборка недоступна, качаю x86_64"; download_telemt x86_64; }
else
    download_telemt "$ARCH"
fi
tar -xzf "${TEMP_DIR}/telemt.tar.gz" -C "$TEMP_DIR" || die "не удалось распаковать архив"
bin_src="$(find "$TEMP_DIR" -name "$BIN_NAME" -type f | head -1)"
[ -n "$bin_src" ] || die "бинарь не найден в архиве"
install -m 0755 "$bin_src" "${INSTALL_DIR}/${BIN_NAME}"

say ">>> [7/9] Конфиг ${CONFIG_FILE}"
MTPROXY_BIND="127.0.0.1"; [ "$MTPROXY_PUBLIC" -eq 1 ] && MTPROXY_BIND="0.0.0.0"
cat > "$CONFIG_FILE" <<EOF
show_link = ["${USER_NAME}"]

[general]
prefer_ipv6 = false
fast_mode = true
use_middle_proxy = false
log_level = "${LOG_LEVEL}"

[network]
ipv4 = true
ipv6 = false
prefer = 4

[access.users]
${USER_NAME} = "${SECRET}"

[server]
listen_addr_ipv4 = "127.0.0.1"

[[server.listeners]]
ip = "${MTPROXY_BIND}"
port = ${MTPROXY_PORT}
transport = "mtproxy"

[[server.listeners]]
ip = "127.0.0.1"
port = ${WEB_PORT}
transport = "web"
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[web]
enabled = true
carrier = "${CARRIER}"
decoy_fasttrack_mode = "off"
http_connection_capacity_action = "drop"

[[web.vhosts]]
host = "${DOMAIN}"
base_path = "${BASE_PATH}"
public_addr = "${PUBLIC_IP}:${PUBLIC_PORT}"

[web.vhosts.decoy]
mode = "http_upstream"
upstream = "${DECOY_UPSTREAM}"

[[web.vhosts.profiles]]
user = "${USER_NAME}"
secret_mode = "${SECRET_MODE}"
max_sessions = ${MAX_SESSIONS}
max_streams = ${MAX_STREAMS}
max_streams_per_session = ${MAX_STREAMS_PER_SESSION}

[[upstreams]]
type = "direct"
enabled = true
weight = 10
EOF
chown root:telemt "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"

say ">>> [8/9] nginx TLS-конфигурация (режим: $MODE)"
if nginx_http2_modern; then
    H2_LISTEN="ssl"; H2_DIRECTIVE="    http2 on;"
else
    H2_LISTEN="ssl http2"; H2_DIRECTIVE=""
fi

if [ "$MODE" = "sni" ]; then
    TLS_LISTEN="listen 127.0.0.1:${TLS_VHOST_PORT} ${H2_LISTEN};"
else
    TLS_LISTEN="listen ${PUBLIC_PORT} ${H2_LISTEN};"
fi

cat > /etc/nginx/conf.d/telemt-web.conf <<EOF
# telemt-web-proxy: TLS-терминация -> telemt WEB listener
map \$http_upgrade \$telemt_connection_upgrade {
    default upgrade;
    ''      '';
}

upstream telemt_web {
    server 127.0.0.1:${WEB_PORT};
    keepalive 64;
}

server {
    ${TLS_LISTEN}
${H2_DIRECTIVE}
    server_name ${DOMAIN};
    access_log /var/log/nginx/telemt_access.log combined;

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    client_max_body_size 50m;

    location / {
        proxy_pass http://telemt_web;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$telemt_connection_upgrade;

        proxy_connect_timeout 5s;
        proxy_send_timeout 65s;
        proxy_read_timeout 65s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_next_upstream off;
    }
}
EOF

if [ "$MODE" = "sni" ]; then
    if grep -qE '^\s*stream\s*\{' /etc/nginx/nginx.conf; then
        die "в nginx.conf уже есть stream {}-блок — добавьте маршрутизацию SNI вручную:
  ${DOMAIN} -> 127.0.0.1:${TLS_VHOST_PORT};  default -> ${SNI_FALLBACK}"
    fi
    cat >> /etc/nginx/nginx.conf <<EOF

${STREAM_BEGIN}
stream {
    map \$ssl_preread_server_name \$telemt_backend {
        ${DOMAIN}  telemt_ssl;
        default            sni_fallback;
    }
    upstream telemt_ssl { server 127.0.0.1:${TLS_VHOST_PORT}; }
    upstream sni_fallback { server ${SNI_FALLBACK}; }
    server {
        listen ${PUBLIC_PORT};
        proxy_pass \$telemt_backend;
        ssl_preread on;
    }
}
${STREAM_END}
EOF
fi

nginx -t || die "nginx -t не прошёл"
systemctl reload nginx

say ">>> [9/9] systemd-сервис telemt"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Telemt MTProxy & WEB Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=${WORK_DIR}
ExecStart=${INSTALL_DIR}/${BIN_NAME} ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 2
systemctl is-active --quiet "$SERVICE_NAME" \
    || { warn "сервис не поднялся — смотрите journalctl -u ${SERVICE_NAME}"; }

say ""
say "============================================================"
say " УСТАНОВКА ЗАВЕРШЕНА"
say "============================================================"
say "  Домен:        $DOMAIN"
say "  Публичный IP: $PUBLIC_IP"
say "  Порт:         $PUBLIC_PORT"
say "  Пользователь: $USER_NAME"
say "  Секрет:       $SECRET"
say "  Режим nginx:  $MODE"
say ""
if [ "$PUBLIC_PORT" -ne 443 ]; then
    say ""
    warn "порт ${PUBLIC_PORT} != 443: ссылки tg://webproxy в Telegram Desktop"
    warn "работают только на 443. Подключение: ${DOMAIN}:${PUBLIC_PORT}"
fi
say ""
say "  WEB-ссылка (Telegram Desktop):"
if [ "$SECRET_MODE" = "dd" ]; then
    say "    tg://webproxy?server=${DOMAIN}&secret=dd${SECRET}"
else
    say "    tg://webproxy?server=${DOMAIN}&secret=${SECRET}"
fi
if [ "$MTPROXY_PUBLIC" -eq 1 ]; then
    say ""
    say "  MTProto-ссылка (порт ${MTPROXY_PORT}):"
    say "    tg://proxy?server=${PUBLIC_IP}&port=${MTPROXY_PORT}&secret=dd${SECRET}"
fi
say ""
say "  Полезное:"
say "    journalctl -u ${SERVICE_NAME} -f     # логи telemt"
say "    systemctl status ${SERVICE_NAME}     # статус"
say "    sh install.sh --uninstall            # удаление"
say "============================================================"
