#!/bin/bash

# ====================================================
# PTERODACTYL MANAGER - V5.3 LOCAL TUNNEL BUILD
# ====================================================

set -o pipefail

SCRIPT_VERSION="5.4"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'

# Default config (akan di-override oleh CONFIG_FILE jika ada)
DB_USER="pterodactyl"
DB_NAME="panel"
BACKUP_ROOT="/root/backup"
PANEL_DIR="/var/www/pterodactyl"
WINGS_DIR="/etc/pterodactyl"
PHP_VERSION="8.3"
LOG_FILE="/var/log/ptero-manager.log"
BACKUP_RETENTION_DAYS=7
BACKUP_MAX_COUNT=10
DISCORD_WEBHOOK=""
MYSQL_ROOT_PASS=""
DB_PASS=""
PANEL_DOMAIN=""
DEPLOY_MODE="tunnel"     # tunnel | public
LE_EMAIL=""

CONFIG_FILE="/root/.ptero-manager.conf"
AUTO_BACKUP_SCRIPT="/usr/local/sbin/ptero-auto-backup.sh"
AUTO_BACKUP_CNF="/etc/ptero-manager/db.cnf"
SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-}"
LOCK_FILE="/var/run/ptero-manager.lock"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
CUSTOM_BANNER=""
QUIET_MODE=0

function load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE" 2>/dev/null || true
    fi
}

function save_config() {
    [ "$(id -u)" -eq 0 ] || return 0
    local _old_umask
    _old_umask=$(umask)
    umask 077
    cat > "$CONFIG_FILE" <<CONF
# Ptero Manager Config - jangan edit manual saat script jalan
DB_USER="$DB_USER"
DB_NAME="$DB_NAME"
BACKUP_ROOT="$BACKUP_ROOT"
PANEL_DIR="$PANEL_DIR"
WINGS_DIR="$WINGS_DIR"
PHP_VERSION="$PHP_VERSION"
BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS
BACKUP_MAX_COUNT=$BACKUP_MAX_COUNT
DISCORD_WEBHOOK="$DISCORD_WEBHOOK"
SCRIPT_UPDATE_URL="$SCRIPT_UPDATE_URL"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
CUSTOM_BANNER="$CUSTOM_BANNER"
PANEL_DOMAIN="$PANEL_DOMAIN"
DEPLOY_MODE="$DEPLOY_MODE"
LE_EMAIL="$LE_EMAIL"
CONF
    chmod 600 "$CONFIG_FILE"
    umask "$_old_umask"
}

load_config

# ====================================================
# HELPERS
# ====================================================

function pause() {
    read -r -p "Tekan Enter untuk lanjut..."
}

function log_msg() {
    local message="$1"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%F %T')] $message" >> "$LOG_FILE" 2>/dev/null || true
}

function status_short() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        printf "${GREEN}UP${NC}"
    elif systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
        printf "${RED}DOWN${NC}"
    else
        printf "${YELLOW}MISS${NC}"
    fi
}

function header() {
    clear 2>/dev/null || true
    local disk_usage mem_usage
    disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo '-')
    mem_usage=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || echo '-')
    echo -e "${BLUE}====================================================${NC}"
    if [ -n "$CUSTOM_BANNER" ]; then
        printf '%b       %s%b\n' "$CYAN" "$CUSTOM_BANNER" "$NC"
    fi
    echo -e "       PTERODACTYL LOCAL MANAGER V${SCRIPT_VERSION}"
    echo -e "      (Local Server + Cloudflare Tunnel/Connector)"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "Uptime : $(uptime -p 2>/dev/null || echo '-')"
    echo -e "RAM    : $mem_usage"
    echo -e "Disk   : $disk_usage"
    echo -e "Status : Wings:$(status_short wings) Nginx:$(status_short nginx) DB:$(status_short mariadb) Redis:$(status_short redis-server) CF:$(status_short cloudflared)"
    if command -v ifstat >/dev/null 2>&1; then
        echo -e "Traffic: $(ifstat 1 1 2>/dev/null | tail -1 | awk '{print "IN: "$1" KB/s | OUT: "$2" KB/s"}')"
    fi
    echo -e "----------------------------------------------------"
}

function notify() {
    local message="$1"
    command -v curl >/dev/null 2>&1 || return 0
    if [ -n "$DISCORD_WEBHOOK" ]; then
        local escaped
        escaped=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
        curl -fsS -H "Content-Type: application/json" -X POST \
            -d "{\"content\": \"$escaped\"}" "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
    fi
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -fsS -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "text=$message" \
            --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi
}

function acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    if ! command -v flock >/dev/null 2>&1; then
        # fallback non-atomik (sangat jarang: flock biasanya selalu ada di Debian/Ubuntu)
        if [ -e "$LOCK_FILE" ]; then
            local pid
            pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                fail "Operasi lain sedang berjalan (PID $pid). Tunggu selesai atau hapus $LOCK_FILE."
                return 1
            fi
        fi
        echo "$$" > "$LOCK_FILE"
        return 0
    fi
    # Atomik via flock — fd 9 dipegang selama proses hidup
    exec 9>"$LOCK_FILE" || { fail "Tidak bisa membuka lock file $LOCK_FILE."; return 1; }
    if ! flock -n 9; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        fail "Operasi lain sedang berjalan${pid:+ (PID $pid)}. Tunggu selesai dulu."
        exec 9>&-
        return 1
    fi
    echo "$$" >&9
    return 0
}

function release_lock() {
    # Tutup fd lock (otomatis melepas flock) lalu hapus file
    exec 9>&- 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

function sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        echo "-"
    fi
}

function qprint() {
    [ "$QUIET_MODE" = "1" ] && return 0
    echo -e "$@"
}

function notify_detail() {
    local title="$1"
    local body="$2"
    local disk_info mem_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo '-')
    mem_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || echo '-')
    notify "**[$title]** $body | Disk: $disk_info | RAM: $mem_info | $(date '+%F %T')"
}

function fail() {
    echo -e "${RED}ERROR: $1${NC}"
    log_msg "ERROR: $1"
    return 1
}

function confirm_action() {
    local prompt="$1"
    local answer
    echo -e "${YELLOW}$prompt${NC}"
    read -r -p "Ketik 'lanjut' untuk melanjutkan: " answer
    [ "$answer" = "lanjut" ]
}

function require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Jalankan script sebagai root: sudo bash ptero.sh"
        return 1
    fi
}

function require_debian_family() {
    if ! command -v apt >/dev/null 2>&1; then
        fail "Script ini ditujukan untuk Ubuntu/Debian yang memakai apt."
        return 1
    fi
}

function validate_domain() {
    local d="$1"
    d=$(printf '%s' "$d" | sed -E 's#^https?://##; s#/.*$##')
    if echo "$d" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
        printf '%s' "$d"
        return 0
    fi
    return 1
}

function pick_from_list() {
    local prompt="$1"; shift
    local arr=("$@")
    local i=0
    if [ "${#arr[@]}" -eq 0 ]; then
        return 1
    fi
    for item in "${arr[@]}"; do
        i=$((i+1))
        echo -e "  ${CYAN}[$i]${NC} $item" >&2
    done
    local pick
    read -r -p "$prompt " pick
    if ! echo "$pick" | grep -Eq '^[0-9]+$'; then
        return 1
    fi
    if [ "$pick" -lt 1 ] || [ "$pick" -gt "${#arr[@]}" ]; then
        return 1
    fi
    printf '%s' "${arr[$((pick-1))]}"
    return 0
}

function require_panel() {
    if [ ! -f "$PANEL_DIR/artisan" ]; then
        fail "Panel belum ditemukan di $PANEL_DIR."
        pause
        return 1
    fi
}

function validate_db_password() {
    # Whitelist karakter aman buat MySQL CREATE USER, .env Laravel, dan MySQL option file.
    # Ditolak: kutip ('"`), backslash, dollar, spasi, newline (rawan injection / parsing rusak).
    local pass="$1"
    local min="${2:-8}"
    local len=${#pass}
    if [ "$len" -lt "$min" ]; then
        fail "Password terlalu pendek (minimal $min karakter)."
        return 1
    fi
    if [ "$len" -gt 64 ]; then
        fail "Password terlalu panjang (maksimal 64 karakter)."
        return 1
    fi
    if [[ "$pass" =~ [[:space:]] ]]; then
        fail "Password tidak boleh mengandung spasi/tab/newline."
        return 1
    fi
    # Hanya izinkan: huruf, angka, dan _-.@#%+=:,/!~^*()[]{}<>?|;&
    if [[ ! "$pass" =~ ^[A-Za-z0-9_.@#%+=:,/!~^*()\[\]{}\<\>?\|\;\&-]+$ ]]; then
        fail "Password mengandung karakter terlarang. Hindari: ' \" \` \\ \$ dan whitespace."
        return 1
    fi
    return 0
}

function safe_reload_nginx() {
    # Wajib lulus 'nginx -t' sebelum reload/restart, supaya nginx tidak down karena salah config.
    if ! command -v nginx >/dev/null 2>&1; then
        return 0
    fi
    if ! nginx -t >/dev/null 2>&1; then
        fail "Nginx config invalid — tidak di-reload. Jalankan 'nginx -t' untuk detail."
        return 1
    fi
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
}

function _mk_mysql_cnf() {
    # Tulis credentials ke temp file mode 600 supaya tidak bocor lewat ps/proc.
    # Args: <user> <password> [host]
    local user="$1" pass="$2" host="${3:-127.0.0.1}"
    local cnf
    cnf=$(mktemp /tmp/.ptmycnf.XXXXXX) || return 1
    chmod 600 "$cnf"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$user"
        printf 'password=%s\n' "$pass"
        printf 'host=%s\n' "$host"
    } > "$cnf"
    printf '%s' "$cnf"
}

function mysql_secure() {
    # mysql_secure <user> <pass> [mysql args...]
    local user="$1" pass="$2"; shift 2
    local cnf rc
    cnf=$(_mk_mysql_cnf "$user" "$pass") || return 1
    mysql --defaults-extra-file="$cnf" "$@"
    rc=$?
    rm -f "$cnf"
    return $rc
}

function mysqldump_secure() {
    # mysqldump_secure <user> <pass> [mysqldump args...]
    local user="$1" pass="$2"; shift 2
    local cnf rc
    cnf=$(_mk_mysql_cnf "$user" "$pass") || return 1
    mysqldump --defaults-extra-file="$cnf" "$@"
    rc=$?
    rm -f "$cnf"
    return $rc
}

function mysqlcheck_secure() {
    local user="$1" pass="$2"; shift 2
    local cnf rc
    cnf=$(_mk_mysql_cnf "$user" "$pass") || return 1
    mysqlcheck --defaults-extra-file="$cnf" "$@"
    rc=$?
    rm -f "$cnf"
    return $rc
}

function mysql_root() {
    if [ -n "$MYSQL_ROOT_PASS" ]; then
        mysql_secure root "$MYSQL_ROOT_PASS" "$@"
    else
        mysql "$@"
    fi
}

function ask_mysql_root_password() {
    read -r -s -p "Password root MariaDB/MySQL (kosongkan jika tanpa password): " MYSQL_ROOT_PASS
    echo
}

function set_env_value() {
    local key="$1"
    local value="$2"
    local file="${3:-$PANEL_DIR/.env}"
    local escaped
    escaped=$(printf '%s' "$value" | sed 's/[&]/\\&/g; s|[/]|\\/|g')
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${escaped}/" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

function service_status_line() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  ${GREEN}[RUNNING]${NC} $service"
    elif systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${service}.service"; then
        echo -e "  ${RED}[STOPPED]${NC} $service"
    else
        echo -e "  ${YELLOW}[MISSING]${NC} $service"
    fi
}

# ====================================================
# INSTALL
# ====================================================

function install_base_dependencies() {
    echo -e "${GREEN}[*] Menginstall dependency sistem...${NC}"
    apt update
    DEBIAN_FRONTEND=noninteractive apt upgrade -y
    DEBIAN_FRONTEND=noninteractive apt install -y \
        curl ca-certificates gnupg2 sudo lsb-release tar unzip git \
        mariadb-server redis-server nginx ufw ifstat cron \
        software-properties-common apt-transport-https

    if ! apt-cache show "php${PHP_VERSION}-cli" >/dev/null 2>&1; then
        add-apt-repository ppa:ondrej/php -y
        apt update
    fi

    DEBIAN_FRONTEND=noninteractive apt install -y \
        "php${PHP_VERSION}" "php${PHP_VERSION}-common" "php${PHP_VERSION}-cli" \
        "php${PHP_VERSION}-gd" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-fpm" \
        "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-intl"

    if ! command -v composer >/dev/null 2>&1; then
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
    fi

    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com/ | CHANNEL=stable bash
    fi

    systemctl enable --now docker mariadb redis-server cron "php${PHP_VERSION}-fpm"
}

function install_wings_binary() {
    echo -e "${BLUE}[*] Menginstall / update Wings...${NC}"
    mkdir -p "$WINGS_DIR"
    local tmp="/tmp/wings.new"
    if ! curl -fsSL -o "$tmp" \
            "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"; then
        rm -f "$tmp"
        fail "Gagal download Wings binary."
        return 1
    fi
    chmod +x "$tmp"
    if ! "$tmp" --version >/dev/null 2>&1; then
        rm -f "$tmp"
        fail "Wings binary baru rusak/tidak valid. Binary lama tidak diganti."
        return 1
    fi
    mv -f "$tmp" /usr/local/bin/wings
    echo -e "${GREEN}[OK]${NC} Wings $(/usr/local/bin/wings --version 2>/dev/null | head -1)"
}

function provision_services() {
    require_root || return 1
    echo -e "${BLUE}[*] Membuat service systemd dan konfigurasi Nginx...${NC}"
    mkdir -p /etc/systemd/system /etc/nginx/sites-available /etc/nginx/sites-enabled "$WINGS_DIR"

    cat > /etc/systemd/system/wings.service <<UNIT
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=$WINGS_DIR
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/pteroq.service <<UNIT
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service mariadb.service
StartLimitIntervalSec=180
StartLimitBurst=30

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

    write_nginx_config

    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    rm -f /etc/nginx/sites-enabled/default
    systemctl daemon-reload
    systemctl enable wings pteroq >/dev/null 2>&1 || true
    nginx -t && systemctl restart nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true
    echo -e "${GREEN}[OK] Service dan Nginx sudah diprovision (mode: ${DEPLOY_MODE:-tunnel}).${NC}"
}

function write_nginx_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    local mode="${DEPLOY_MODE:-tunnel}"
    local server_name="${PANEL_DOMAIN:-_}"

    if [ "$mode" = "public" ]; then
        local cert_path="/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem"
        local key_path="/etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem"
        if [ -z "$PANEL_DOMAIN" ] || [ ! -f "$cert_path" ]; then
            # Belum ada cert LE — pakai self-signed snakeoil sementara
            DEBIAN_FRONTEND=noninteractive apt install -y ssl-cert >/dev/null 2>&1 || true
            cert_path="/etc/ssl/certs/ssl-cert-snakeoil.pem"
            key_path="/etc/ssl/private/ssl-cert-snakeoil.key"
        fi
        cat > /etc/nginx/sites-available/pterodactyl.conf <<'NGINX'
server {
    listen 80;
    server_name __PANEL_SERVER_NAME__;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name __PANEL_SERVER_NAME__;

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate __SSL_CERT__;
    ssl_certificate_key __SSL_KEY__;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M";
        fastcgi_param PHP_VALUE "post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTPS on;
    }

    location ~ /\.ht { deny all; }
}
NGINX
        sed -i \
            -e "s|__PANEL_SERVER_NAME__|$server_name|g" \
            -e "s|__SSL_CERT__|$cert_path|g" \
            -e "s|__SSL_KEY__|$key_path|g" \
            /etc/nginx/sites-available/pterodactyl.conf
    else
        # Mode tunnel: tetap pakai HTTPS di nginx (loopback) supaya
        # Cloudflare bisa pakai mode "Full (Strict)" end-to-end.
        # Default cert: self-signed; bisa diganti ke Cloudflare Origin Cert.
        local cert_path="/etc/ssl/ptero/fullchain.pem"
        local key_path="/etc/ssl/ptero/privkey.pem"
        ensure_self_signed_cert "$server_name"
        cat > /etc/nginx/sites-available/pterodactyl.conf <<'NGINX'
server {
    listen 80;
    server_name __PANEL_SERVER_NAME__;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name __PANEL_SERVER_NAME__;

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate __SSL_CERT__;
    ssl_certificate_key __SSL_KEY__;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M";
        fastcgi_param PHP_VALUE "post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTPS on;
    }

    location ~ /\.ht { deny all; }
}
NGINX
        sed -i \
            -e "s|__PANEL_SERVER_NAME__|$server_name|g" \
            -e "s|__SSL_CERT__|$cert_path|g" \
            -e "s|__SSL_KEY__|$key_path|g" \
            /etc/nginx/sites-available/pterodactyl.conf
    fi
}

function ensure_self_signed_cert() {
    local cn="${1:-localhost}"
    local dir="/etc/ssl/ptero"
    local crt="$dir/fullchain.pem"
    local key="$dir/privkey.pem"
    mkdir -p "$dir"
    chmod 750 "$dir"
    # Regenerate kalau belum ada / CN tidak cocok / mau expired (<30 hari)
    local need=0
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        need=1
    else
        if ! openssl x509 -in "$crt" -noout -subject 2>/dev/null | grep -q "CN *= *$cn"; then
            need=1
        fi
        if openssl x509 -in "$crt" -noout -checkend $((30*86400)) >/dev/null 2>&1; then
            : # masih valid lebih dari 30 hari
        else
            need=1
        fi
    fi
    if [ "$need" -eq 1 ]; then
        command -v openssl >/dev/null 2>&1 || \
            DEBIAN_FRONTEND=noninteractive apt install -y openssl >/dev/null 2>&1 || true
        openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
            -keyout "$key" -out "$crt" \
            -subj "/CN=$cn/O=Pterodactyl Local/OU=ptero-manager" \
            -addext "subjectAltName=DNS:$cn,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 || true
        chmod 600 "$key"
        chmod 644 "$crt"
    fi
}

function install_cf_origin_cert() {
    require_root || return 1
    header
    echo -e "${BLUE}Pasang Cloudflare Origin Certificate (mode tunnel, Full Strict)${NC}"
    echo -e "${YELLOW}Ambil dari: Cloudflare Dashboard > SSL/TLS > Origin Server > Create Certificate.${NC}"
    echo -e "${YELLOW}Pilih PEM, salin certificate (full chain) dan private key.${NC}"
    echo
    local dir="/etc/ssl/ptero"
    mkdir -p "$dir"
    chmod 750 "$dir"
    echo -e "${CYAN}Tempel CERTIFICATE (akhiri dengan baris berisi: END)${NC}"
    : > "$dir/fullchain.pem"
    while IFS= read -r line; do
        [ "$line" = "END" ] && break
        printf '%s\n' "$line" >> "$dir/fullchain.pem"
    done
    echo -e "${CYAN}Tempel PRIVATE KEY (akhiri dengan baris berisi: END)${NC}"
    : > "$dir/privkey.pem"
    while IFS= read -r line; do
        [ "$line" = "END" ] && break
        printf '%s\n' "$line" >> "$dir/privkey.pem"
    done
    if ! openssl x509 -in "$dir/fullchain.pem" -noout >/dev/null 2>&1; then
        fail "Certificate yang ditempel tidak valid."
        rm -f "$dir/fullchain.pem" "$dir/privkey.pem"
        pause
        return 1
    fi
    if ! openssl rsa -in "$dir/privkey.pem" -check -noout >/dev/null 2>&1 \
         && ! openssl pkey -in "$dir/privkey.pem" -noout >/dev/null 2>&1; then
        fail "Private key tidak valid."
        rm -f "$dir/fullchain.pem" "$dir/privkey.pem"
        pause
        return 1
    fi
    chmod 644 "$dir/fullchain.pem"
    chmod 600 "$dir/privkey.pem"
    DEPLOY_MODE="tunnel"
    save_config
    write_nginx_config
    nginx -t && systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    log_msg "Cloudflare Origin Certificate dipasang"
    echo -e "${GREEN}Origin Certificate aktif. Set Cloudflare SSL/TLS mode ke 'Full (Strict)'.${NC}"
    pause
}

function setup_database() {
    ask_mysql_root_password
    local _tries=0
    while :; do
        read -r -s -p "Password database untuk user $DB_USER (min 8 char): " DB_PASS
        echo
        if validate_db_password "$DB_PASS" 8; then
            break
        fi
        _tries=$((_tries+1))
        [ "$_tries" -ge 3 ] && { fail "Gagal 3x. Batal."; return 1; }
    done
    local db_pass_sql
    db_pass_sql=$(printf "%s" "$DB_PASS" | sed "s/'/''/g")
    if ! mysql_root -e "
        CREATE DATABASE IF NOT EXISTS $DB_NAME
            CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
        ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
        GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'127.0.0.1';
        FLUSH PRIVILEGES;
    "; then
        fail "Setup database gagal (password root MySQL salah / MariaDB tidak jalan)."
        return 1
    fi
}

function install_panel_files() {
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ':80$'; then
        local using
        using=$(ss -lntp 2>/dev/null | awk '/:80 / {print $NF}' | head -1)
        echo -e "${YELLOW}Peringatan: port 80 sudah dipakai oleh: $using${NC}"
        echo -e "${YELLOW}Stop service tersebut dulu (mis. apache2) sebelum lanjut.${NC}"
        read -r -p "Lanjutkan tetap? [y/N]: " GO
        [[ "$GO" =~ ^[Yy]$ ]] || return 1
    fi
    read -r -p "Domain panel Cloudflare, contoh https://panel.domain.com [http://localhost]: " APP_URL
    APP_URL=${APP_URL:-http://localhost}
    read -r -p "Timezone [Asia/Jakarta]: " APP_TIMEZONE
    APP_TIMEZONE=${APP_TIMEZONE:-Asia/Jakarta}

    if [ -d "$PANEL_DIR" ] && [ -n "$(ls -A "$PANEL_DIR" 2>/dev/null)" ]; then
        read -r -p "Folder panel sudah berisi file. Timpa? [y/N]: " OVERWRITE
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Install panel dibatalkan.${NC}"
            return 0
        fi
        rm -rf "$PANEL_DIR"
    fi

    mkdir -p "$PANEL_DIR"
    local tmp="/tmp/panel.tar.gz"
    rm -f "$tmp"
    if ! curl -fsSL --retry 3 --max-time 300 \
            https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
            -o "$tmp"; then
        rm -f "$tmp"
        fail "Gagal download panel.tar.gz."
        return 1
    fi
    if ! tar -tzf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        fail "panel.tar.gz rusak/tidak valid."
        return 1
    fi
    if ! tar -xzf "$tmp" -C "$PANEL_DIR"; then
        rm -f "$tmp"
        fail "Ekstrak panel.tar.gz gagal."
        return 1
    fi
    rm -f "$tmp"

    cd "$PANEL_DIR" || return 1
    cp .env.example .env
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader \
        || { fail "composer install gagal."; return 1; }

    set_env_value APP_URL "$APP_URL"
    set_env_value APP_TIMEZONE "$APP_TIMEZONE"
    set_env_value DB_HOST "127.0.0.1"
    set_env_value DB_PORT "3306"
    set_env_value DB_DATABASE "$DB_NAME"
    set_env_value DB_USERNAME "$DB_USER"
    set_env_value DB_PASSWORD "$DB_PASS"
    set_env_value CACHE_DRIVER "redis"
    set_env_value SESSION_DRIVER "redis"
    set_env_value QUEUE_CONNECTION "redis"
    set_env_value REDIS_HOST "127.0.0.1"
    # Cloudflare tunnel proxy trust
    set_env_value TRUSTED_PROXIES "*"

    php artisan key:generate --force \
        || { fail "php artisan key:generate gagal."; return 1; }
    php artisan migrate --seed --force \
        || { fail "Migrasi database gagal (cek koneksi DB & kredensial)."; return 1; }
    php artisan storage:link >/dev/null 2>&1 || true
    chown -R www-data:www-data "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"

    echo -e "${YELLOW}Buat akun admin panel sekarang.${NC}"
    php artisan p:user:make
}

function install_all() {
    require_root || return 1
    require_debian_family || return 1
    log_msg "Full install dimulai"
    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT
    install_base_dependencies || { release_lock; trap - EXIT; return 1; }
    install_wings_binary       || { release_lock; trap - EXIT; return 1; }
    setup_database             || { release_lock; trap - EXIT; return 1; }
    install_panel_files        || { release_lock; trap - EXIT; return 1; }
    provision_services         || { release_lock; trap - EXIT; return 1; }
    setup_logrotate
    save_config
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx "php${PHP_VERSION}-fpm" pteroq 2>/dev/null || true
    else
        fail "Nginx config invalid. Service nginx tidak di-restart. Jalankan 'nginx -t' untuk detail."
        systemctl restart "php${PHP_VERSION}-fpm" pteroq 2>/dev/null || true
    fi
    log_msg "Full install selesai"
    notify_detail "INSTALL" "Full install Pterodactyl selesai."
    echo -e "${GREEN}Selesai. Panel terpasang.${NC}"
    echo -e "${YELLOW}Langkah selanjutnya:${NC}"
    echo -e "  1. Setup Cloudflare Tunnel (menu 7 atau 8)"
    echo -e "  2. Set Domain Panel Cloudflare (menu 9)"
    echo -e "  3. Generate config Wings dari Panel API (menu 10)"
    echo -e "  4. Jalankan: systemctl start wings"
    pause
}

function install_panel_only() {
    require_root || return 1
    require_debian_family || return 1
    if [ -f "$PANEL_DIR/.env" ]; then
        echo -e "${YELLOW}Panel sudah terpasang di $PANEL_DIR.${NC}"
        confirm_action "Reinstall ulang panel? (data lama akan ditimpa)" \
            || { echo "Dibatalkan."; pause; return 0; }
    fi
    log_msg "Install panel-only dimulai"
    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT

    install_base_dependencies || { release_lock; trap - EXIT; return 1; }
    setup_database || { release_lock; trap - EXIT; return 1; }
    install_panel_files || { release_lock; trap - EXIT; return 1; }
    provision_services || { release_lock; trap - EXIT; return 1; }
    setup_logrotate
    save_config
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx "php${PHP_VERSION}-fpm" pteroq 2>/dev/null || true
    else
        fail "Nginx config invalid. Skip restart nginx."
        systemctl restart "php${PHP_VERSION}-fpm" pteroq 2>/dev/null || true
    fi

    log_msg "Install panel-only selesai"
    notify_detail "INSTALL PANEL" "Panel Pterodactyl (tanpa Wings) terpasang."
    echo -e "${GREEN}Panel terpasang (mode panel-only, tanpa Wings).${NC}"
    echo -e "${YELLOW}Berguna untuk:${NC}"
    echo -e "  - Server panel terpisah dari node Wings"
    echo -e "  - Reinstall panel tanpa mengganggu Wings yang sedang berjalan"
    echo
    echo -e "${YELLOW}Langkah selanjutnya:${NC}"
    echo -e "  1. Setup Cloudflare Tunnel (menu 7/8)"
    echo -e "  2. Set Domain Panel (menu 9)"
    echo -e "  3. Buat admin user (menu 22)"
    release_lock
    trap - EXIT
    pause
}

function install_wings_only_full() {
    require_root || return 1
    require_debian_family || return 1
    log_msg "Install wings-only dimulai"
    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT

    echo -e "${BLUE}[*] Install dependency dasar untuk Wings (docker, curl, tar)...${NC}"
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y \
        curl ca-certificates gnupg2 sudo lsb-release tar unzip cron \
        software-properties-common apt-transport-https ufw

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Install Docker...${NC}"
        curl -fsSL https://get.docker.com/ | CHANNEL=stable bash
    fi
    systemctl enable --now docker cron 2>/dev/null || true

    install_wings_binary || { release_lock; trap - EXIT; return 1; }

    mkdir -p "$WINGS_DIR" /var/lib/pterodactyl/volumes
    if [ ! -f /etc/systemd/system/wings.service ]; then
        echo -e "${BLUE}[*] Membuat systemd unit Wings...${NC}"
        cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service
StartLimitIntervalSec=180
StartLimitBurst=30

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
    fi
    systemctl enable wings 2>/dev/null || true
    save_config

    log_msg "Install wings-only selesai"
    notify_detail "INSTALL WINGS" "Wings node terpasang (binary + service)."
    echo -e "${GREEN}Wings terpasang sebagai node terpisah.${NC}"
    echo -e "${YELLOW}Langkah selanjutnya:${NC}"
    echo -e "  1. Di panel: buat Node baru -> copy config.yml-nya"
    echo -e "  2. Simpan ke $WINGS_DIR/config.yml"
    echo -e "     ATAU pakai menu 10 untuk generate otomatis dari API panel"
    echo -e "  3. Jalankan: systemctl start wings"
    echo -e "  4. Cek log: journalctl -u wings -f"
    release_lock
    trap - EXIT
    pause
}

# ====================================================
# UPDATE & MAINTENANCE
# ====================================================

function update_panel() {
    require_root || return 1
    require_panel || return 1
    acquire_lock || { pause; return 1; }
    # Pastikan panel SELALU keluar dari maintenance mode + lock dilepas,
    # walau script ke-Ctrl-C atau ada langkah yang gagal.
    trap '
        cd "$PANEL_DIR" 2>/dev/null && php artisan up >/dev/null 2>&1 || true
        release_lock
    ' EXIT INT TERM

    cd "$PANEL_DIR" || { release_lock; trap - EXIT INT TERM; return 1; }

    local tmp="/tmp/panel.tar.gz.new"
    rm -f "$tmp"
    echo -e "${BLUE}[*] Download panel terbaru...${NC}"
    if ! curl -fsSL --retry 3 --max-time 300 \
            https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
            -o "$tmp"; then
        rm -f "$tmp"
        fail "Gagal download panel.tar.gz. Update dibatalkan, panel TIDAK diubah."
        return 1
    fi
    # Verifikasi tarball valid sebelum disentuh apa-apa
    if ! tar -tzf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        fail "panel.tar.gz rusak/tidak valid. Update dibatalkan, panel TIDAK diubah."
        return 1
    fi

    php artisan down --message="Sedang update, tunggu sebentar." >/dev/null 2>&1 || true

    if ! tar -xzf "$tmp" -C "$PANEL_DIR"; then
        rm -f "$tmp"
        fail "Ekstrak panel.tar.gz gagal."
        return 1
    fi
    rm -f "$tmp"

    chmod -R 755 storage bootstrap/cache 2>/dev/null || true
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader \
        || { fail "composer install gagal."; return 1; }
    php artisan view:clear >/dev/null 2>&1 || true
    php artisan config:clear >/dev/null 2>&1 || true
    if ! php artisan migrate --seed --force; then
        fail "Migrasi database gagal. Panel akan dikembalikan ke mode online."
        return 1
    fi
    php artisan queue:restart >/dev/null 2>&1 || true
    chown -R www-data:www-data "$PANEL_DIR"
    php artisan up >/dev/null 2>&1 || true
    systemctl restart pteroq nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true

    log_msg "Panel diupdate"
    notify_detail "UPDATE PANEL" "Update panel selesai sukses."
    echo -e "${GREEN}Panel berhasil diupdate.${NC}"
    release_lock
    trap - EXIT INT TERM
    pause
}

function update_wings_only() {
    require_root || return 1
    echo -e "${BLUE}[*] Update Wings ke versi terbaru...${NC}"
    local was_running=0
    systemctl is-active --quiet wings && was_running=1
    systemctl stop wings 2>/dev/null || true
    if ! install_wings_binary; then
        # Pastikan kalau Wings sebelumnya jalan, kita tetap nyalakan binary lama.
        [ "$was_running" = "1" ] && systemctl start wings 2>/dev/null || true
        return 1
    fi
    systemctl start wings 2>/dev/null || true
    log_msg "Wings diupdate"
    echo -e "${GREEN}Wings berhasil diupdate.${NC}"
    pause
}

function deep_maintenance() {
    require_root || return 1
    echo -e "${BLUE}[*] Membersihkan log, cache, Docker, dan update Wings...${NC}"
    find "$PANEL_DIR/storage/logs" -type f -name '*.log' -delete 2>/dev/null || true
    find /var/lib/docker/containers -type f -name '*-json.log' \
        -exec truncate -s 0 {} \; 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true
    systemctl stop wings 2>/dev/null || true
    pkill -9 wings 2>/dev/null || true
    install_wings_binary || return 1
    provision_services || return 1
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx "php${PHP_VERSION}-fpm" pteroq wings 2>/dev/null || true
    else
        fail "Nginx config invalid. Skip restart nginx."
        systemctl restart "php${PHP_VERSION}-fpm" pteroq wings 2>/dev/null || true
    fi
    log_msg "Deep maintenance selesai"
    echo -e "${GREEN}Maintenance selesai.${NC}"
    pause
}

function panel_maintenance_mode() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    local status="UP (online)"
    if [ -f "$PANEL_DIR/storage/framework/down" ] || [ -f "$PANEL_DIR/storage/framework/maintenance.php" ]; then
        status="${YELLOW}DOWN (maintenance)${NC}"
    else
        status="${GREEN}UP (online)${NC}"
    fi
    echo -e "Status panel saat ini: $status"
    echo
    echo -e "${CYAN}1) Aktifkan Maintenance Mode (panel down)${NC}"
    echo -e "${CYAN}2) Nonaktifkan Maintenance Mode (panel up)${NC}"
    read -r -p "Pilih [1/2]: " MM_OPT
    case "$MM_OPT" in
        1)
            read -r -p "Pesan maintenance [Sedang maintenance, kembali lagi nanti.]: " MM_MSG
            MM_MSG=${MM_MSG:-Sedang maintenance, kembali lagi nanti.}
            php artisan down --message="$MM_MSG"
            log_msg "Panel maintenance mode diaktifkan"
            echo -e "${YELLOW}Panel sekarang dalam mode maintenance.${NC}"
            ;;
        2)
            php artisan up
            log_msg "Panel maintenance mode dinonaktifkan"
            echo -e "${GREEN}Panel kembali online.${NC}"
            ;;
        *)
            echo -e "${YELLOW}Pilihan tidak valid.${NC}"
            ;;
    esac
    pause
}

# ====================================================
# BACKUP & RESTORE
# ====================================================

function backup_db_only() {
    require_root || return 1
    read -r -s -p "Password database user $DB_USER: " DB_PASS
    echo
    if [ -z "$DB_PASS" ]; then
        fail "Password database tidak boleh kosong."
        pause
        return 1
    fi
    local dest
    dest="$BACKUP_ROOT/db_only_$(date +%F_%H-%M-%S).sql"
    mkdir -p "$BACKUP_ROOT"
    echo -e "${BLUE}[*] Backup database saja...${NC}"
    if mysqldump_secure "$DB_USER" "$DB_PASS" -h 127.0.0.1 "$DB_NAME" > "$dest"; then
        local size
        size=$(du -sh "$dest" | awk '{print $1}')
        log_msg "Backup DB only sukses: $dest ($size)"
        notify_detail "BACKUP DB" "Backup database selesai: $(basename "$dest") ($size)"
        echo -e "${GREEN}Backup database selesai: $dest ($size)${NC}"
    else
        rm -f "$dest"
        fail "Backup database gagal."
    fi
    pause
}

function backup_system() {
    require_root || return 1
    read -r -s -p "Password database user $DB_USER: " DB_PASS
    echo
    backup_system_with_password "$DB_PASS" "yes"
}

function backup_system_with_password() {
    local backup_password="$1"
    local interactive="${2:-no}"

    acquire_lock || { [ "$interactive" = "yes" ] && pause; return 1; }
    trap 'release_lock' EXIT

    local dest_dir dest start_ts end_ts duration
    dest_dir="ptero_$(date +%F_%H-%M-%S)"
    dest="$BACKUP_ROOT/$dest_dir"
    mkdir -p "$dest"
    start_ts=$(date +%s)

    log_msg "Backup dimulai: $dest"
    qprint "${BLUE}[*] Memulai backup database, panel, Wings, dan volume...${NC}"

    if mysqldump_secure "$DB_USER" "$backup_password" -h 127.0.0.1 "$DB_NAME" \
            > "$dest/panel_db.sql"; then

        tar -czf "$dest/panel_files.tar.gz" -C /var/www pterodactyl 2>/dev/null || true
        [ -d "$WINGS_DIR" ] && cp -a "$WINGS_DIR" "$dest/wings_config"
        if [ -d /var/lib/pterodactyl/volumes ]; then
            tar -czf "$dest/server_volumes.tar.gz" -C /var/lib pterodactyl/volumes
        fi

        # Verifikasi integritas + checksum SHA256
        local failed=0
        : > "$dest/CHECKSUMS.sha256"
        for f in panel_db.sql panel_files.tar.gz server_volumes.tar.gz; do
            if [ -f "$dest/$f" ]; then
                if [ ! -s "$dest/$f" ]; then
                    qprint "${RED}PERINGATAN: $f kosong/rusak!${NC}"
                    log_msg "PERINGATAN: backup file $f kosong"
                    failed=1
                else
                    local hash
                    hash=$(sha256_of "$dest/$f")
                    echo "$hash  $f" >> "$dest/CHECKSUMS.sha256"
                fi
            fi
        done

        local total_size
        total_size=$(du -sh "$dest" | awk '{print $1}')

        local rclone_status="skip"
        if command -v rclone >/dev/null 2>&1 && [ -f /root/.ptero_rclone ]; then
            local r_info
            r_info=$(cat /root/.ptero_rclone)
            qprint "${BLUE}[*] Upload backup ke cloud...${NC}"
            if rclone copy "$dest" "$r_info/$dest_dir" --progress 2>&1; then
                rclone_status="ok"
                notify_detail "BACKUP CLOUD" "Backup cloud OK: $dest_dir ($total_size)"
            else
                rclone_status="fail"
                qprint "${RED}Upload cloud GAGAL.${NC}"
                log_msg "Upload cloud gagal untuk $dest_dir"
                notify_detail "BACKUP CLOUD GAGAL" "Upload cloud gagal: $dest_dir"
            fi
        fi

        cleanup_old_backups
        end_ts=$(date +%s)
        duration=$((end_ts - start_ts))
        log_msg "Backup sukses: $dest ($total_size, ${duration}s, cloud=$rclone_status)"

        if [ "$failed" -eq 0 ]; then
            notify_detail "BACKUP OK" "Backup lokal selesai: $dest_dir ($total_size, ${duration}s)"
            qprint "${GREEN}Backup selesai di $dest ($total_size, ${duration}s)${NC}"
            qprint "${CYAN}Checksum tersimpan: $dest/CHECKSUMS.sha256${NC}"
        else
            notify_detail "BACKUP WARN" "Backup selesai DENGAN PERINGATAN: $dest_dir"
            qprint "${YELLOW}Backup selesai tapi ada file yang kosong. Cek di $dest${NC}"
        fi
    else
        rm -rf "$dest"
        log_msg "Backup gagal"
        notify_detail "BACKUP GAGAL" "Backup database gagal! Periksa password."
        fail "Backup database gagal. Periksa password database."
    fi

    release_lock
    trap - EXIT

    if [ "$interactive" = "yes" ]; then
        pause
    fi
}

function preview_backup() {
    local b="$1"
    echo -e "${BLUE}=== Preview Backup ===${NC}"
    echo -e "Path     : $b"
    echo -e "Tanggal  : $(stat -c %y "$b" 2>/dev/null | cut -d. -f1)"
    echo -e "Total    : $(du -sh "$b" 2>/dev/null | awk '{print $1}')"
    echo
    if [ -f "$b/panel_db.sql" ]; then
        echo -e "  ${GREEN}[v]${NC} Database  : $(du -sh "$b/panel_db.sql" | awk '{print $1}')"
    fi
    if [ -f "$b/panel_files.tar.gz" ]; then
        echo -e "  ${GREEN}[v]${NC} Panel     : $(du -sh "$b/panel_files.tar.gz" | awk '{print $1}')"
    fi
    if [ -d "$b/wings_config" ]; then
        echo -e "  ${GREEN}[v]${NC} Wings cfg : $(du -sh "$b/wings_config" | awk '{print $1}')"
    fi
    if [ -f "$b/server_volumes.tar.gz" ]; then
        echo -e "  ${GREEN}[v]${NC} Volume    : $(du -sh "$b/server_volumes.tar.gz" | awk '{print $1}')"
    fi
    if [ -f "$b/CHECKSUMS.sha256" ]; then
        echo
        echo -e "${CYAN}Verifikasi checksum:${NC}"
        ( cd "$b" && sha256sum -c CHECKSUMS.sha256 2>&1 | sed 's/^/  /' )
    else
        echo -e "  ${YELLOW}(tidak ada checksum)${NC}"
    fi
    echo
}

function restore_system() {
    require_root || return 1
    header
    echo -e "${YELLOW}PERINGATAN: Restore akan menimpa data panel sesuai komponen yang dipilih.${NC}"

    local BACKUP_PATH=""
    mapfile -t BACKUPS < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        fail "Tidak ada backup tersedia di $BACKUP_ROOT."
        pause
        return 1
    fi
    echo -e "${BLUE}Daftar backup tersedia:${NC}"
    BACKUP_PATH=$(pick_from_list "Pilih nomor backup:" "${BACKUPS[@]}") || {
        fail "Pilihan tidak valid."; pause; return 1
    }
    echo
    preview_backup "$BACKUP_PATH"

    echo -e "${CYAN}Komponen yang ingin di-restore:${NC}"
    echo "1) Lengkap (database + panel + wings + volume)"
    echo "2) Database saja"
    echo "3) Panel files saja"
    echo "4) Wings config saja"
    echo "5) Server volumes saja"
    echo "0) Batal"
    read -r -p "Pilih [0-5]: " RMODE
    [ "$RMODE" = "0" ] && { echo "Dibatalkan."; pause; return 0; }
    if ! echo "$RMODE" | grep -Eq '^[1-5]$'; then
        fail "Pilihan tidak valid."; pause; return 1
    fi

    confirm_action "Lanjut restore mode $RMODE dari: $BACKUP_PATH ?" \
        || { echo "Dibatalkan."; pause; return 1; }

    if [ ! -d "$BACKUP_PATH" ]; then
        fail "Folder backup tidak ditemukan."; pause; return 1
    fi

    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT

    case "$RMODE" in
        1)
            for required in panel_db.sql panel_files.tar.gz; do
                if [ ! -f "$BACKUP_PATH/$required" ]; then
                    fail "File backup wajib tidak ada: $required"
                    release_lock; trap - EXIT; pause; return 1
                fi
            done
            ;;
        2) [ -f "$BACKUP_PATH/panel_db.sql" ] || { fail "panel_db.sql tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
        3) [ -f "$BACKUP_PATH/panel_files.tar.gz" ] || { fail "panel_files.tar.gz tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
        4) [ -d "$BACKUP_PATH/wings_config" ] || { fail "wings_config tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
        5) [ -f "$BACKUP_PATH/server_volumes.tar.gz" ] || { fail "server_volumes.tar.gz tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
    esac

    ask_mysql_root_password
    read -r -s -p "Password database untuk user $DB_USER: " DB_PASS
    echo
    local db_pass_sql
    db_pass_sql=$(printf "%s" "$DB_PASS" | sed "s/'/''/g")

    log_msg "Restore dimulai dari: $BACKUP_PATH (mode $RMODE)"
    systemctl stop wings pteroq nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true

    # Helper: kalau gagal di tengah restore, jangan tinggalkan panel mati.
    _restore_abort() {
        fail "$1"
        systemctl start "php${PHP_VERSION}-fpm" nginx pteroq wings 2>/dev/null || true
        notify_detail "RESTORE GAGAL" "Restore mode $RMODE dari $(basename "$BACKUP_PATH") gagal: $1"
        release_lock; trap - EXIT; pause; return 1
    }

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "2" ]; then
        mysql_root -e "
            DROP DATABASE IF EXISTS $DB_NAME;
            CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
            CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
            ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
            GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'127.0.0.1';
            FLUSH PRIVILEGES;
        " || { _restore_abort "Gagal menyiapkan database (cek password root)."; return 1; }
        mysql_secure "$DB_USER" "$DB_PASS" -h 127.0.0.1 "$DB_NAME" < "$BACKUP_PATH/panel_db.sql" \
            || { _restore_abort "Restore database gagal."; return 1; }
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "3" ]; then
        rm -rf "$PANEL_DIR"
        tar -xzf "$BACKUP_PATH/panel_files.tar.gz" -C /var/www \
            || { _restore_abort "Ekstrak panel_files.tar.gz gagal."; return 1; }
        chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
        chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
        set_env_value TRUSTED_PROXIES "*"
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "4" ]; then
        mkdir -p "$WINGS_DIR"
        [ -d "$BACKUP_PATH/wings_config" ] && cp -a "$BACKUP_PATH/wings_config/." "$WINGS_DIR/"
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "5" ]; then
        mkdir -p /var/lib/pterodactyl/volumes
        if [ -f "$BACKUP_PATH/server_volumes.tar.gz" ]; then
            tar -xzf "$BACKUP_PATH/server_volumes.tar.gz" -C /var/lib \
                || { _restore_abort "Ekstrak server_volumes.tar.gz gagal."; return 1; }
        fi
    fi

    provision_services
    systemctl start "php${PHP_VERSION}-fpm" nginx pteroq wings 2>/dev/null || true
    log_msg "Restore selesai dari: $BACKUP_PATH (mode $RMODE)"
    notify_detail "RESTORE OK" "Restore mode $RMODE dari $(basename "$BACKUP_PATH") selesai."
    echo -e "${GREEN}Restore selesai.${NC}"
    release_lock
    trap - EXIT
    pause
}

function list_backups() {
    require_root || return 1
    header
    echo -e "${BLUE}Daftar backup di $BACKUP_ROOT:${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."
    else
        local i=0
        while IFS= read -r bdir; do
            i=$((i+1))
            local size
            size=$(du -sh "$bdir" 2>/dev/null | awk '{print $1}')
            echo -e "  ${CYAN}[$i]${NC} $(basename "$bdir")  ${YELLOW}($size)${NC}"
        done < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
        [ "$i" -eq 0 ] && echo "Backup belum ada."
    fi
    echo
    pause
}

function cleanup_old_backups() {
    [ -d "$BACKUP_ROOT" ] || return 0
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ptero_*' \
        -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -rf {} \; 2>/dev/null || true
    local count
    count=$(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null | wc -l)
    if [ "$count" -gt "$BACKUP_MAX_COUNT" ]; then
        ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null \
            | tail -n +"$((BACKUP_MAX_COUNT + 1))" | xargs -r rm -rf
    fi
}

function delete_backup() {
    require_root || return 1
    header
    mapfile -t BACKUPS < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        echo -e "${YELLOW}Belum ada backup.${NC}"
        pause
        return 0
    fi
    echo -e "${BLUE}Pilih backup yang akan dihapus:${NC}"
    local target
    target=$(pick_from_list "Nomor backup:" "${BACKUPS[@]}") || {
        echo -e "${YELLOW}Dibatalkan.${NC}"; pause; return 0;
    }
    confirm_action "Hapus permanen: $target?" || { echo "Batal."; pause; return 0; }
    rm -rf "$target"
    log_msg "Backup dihapus: $target"
    echo -e "${GREEN}Backup dihapus.${NC}"
    pause
}

function schedule_auto_backup() {
    require_root || return 1
    read -r -s -p "Password database $DB_USER untuk auto backup: " AUTO_DB_PASS
    echo
    if ! validate_db_password "$AUTO_DB_PASS" 8; then
        pause
        return 1
    fi
    read -r -p "Jam backup harian [03:00]: " BACKUP_TIME
    BACKUP_TIME=${BACKUP_TIME:-03:00}
    if ! echo "$BACKUP_TIME" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
        fail "Format jam tidak valid (00:00–23:59). Gunakan HH:MM, contoh 03:00."
        pause
        return 1
    fi
    local hour minute script_path
    hour=${BACKUP_TIME%:*}
    minute=${BACKUP_TIME#*:}
    script_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    # Simpan kredensial di MySQL option file root-only (mode 600), tidak di body script.
    mkdir -p "$(dirname "$AUTO_BACKUP_CNF")"
    chmod 700 "$(dirname "$AUTO_BACKUP_CNF")"
    local _old_umask
    _old_umask=$(umask); umask 077
    {
        printf '[client]\n'
        printf 'user=%s\n' "$DB_USER"
        printf 'password=%s\n' "$AUTO_DB_PASS"
        printf 'host=127.0.0.1\n'
    } > "$AUTO_BACKUP_CNF"
    chmod 600 "$AUTO_BACKUP_CNF"
    umask "$_old_umask"
    cat > "$AUTO_BACKUP_SCRIPT" <<AUTO
#!/bin/bash
exec bash '$script_path' --auto-backup --cnf '$AUTO_BACKUP_CNF'
AUTO
    chmod 700 "$AUTO_BACKUP_SCRIPT"
    setup_logrotate
    cat > /etc/cron.d/ptero-manager-backup <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$minute $hour * * * root $AUTO_BACKUP_SCRIPT >> $LOG_FILE 2>&1
CRON
    systemctl restart cron 2>/dev/null || true
    log_msg "Backup otomatis dijadwalkan setiap $BACKUP_TIME"
    echo -e "${GREEN}Backup otomatis aktif setiap jam $BACKUP_TIME.${NC}"
    echo -e "${YELLOW}Kredensial DB tersimpan di $AUTO_BACKUP_CNF (root-only, mode 600).${NC}"
    pause
}

function setup_logrotate() {
    [ "$(id -u)" -eq 0 ] || return 0
    cat > /etc/logrotate.d/ptero-manager <<LOGROT
$LOG_FILE {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
LOGROT
}

# ====================================================
# CLOUDFLARE TUNNEL
# ====================================================

function install_cloudflared() {
    require_root || return 1
    require_debian_family || return 1
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Menginstall cloudflared...${NC}"
        curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
            -o /tmp/cloudflared.deb
        apt install -y /tmp/cloudflared.deb
        rm -f /tmp/cloudflared.deb
    else
        echo -e "${YELLOW}cloudflared sudah terpasang.${NC}"
    fi
}

function setup_cloudflare_tunnel() {
    require_root || return 1
    install_cloudflared || return 1
    echo -e "${YELLOW}Ambil token dari: Cloudflare Zero Trust > Networks > Tunnels > Connector.${NC}"
    echo -e "${YELLOW}Public hostname di Cloudflare arahkan ke service: http://localhost:80${NC}"
    read -r -p "Token Cloudflare Tunnel: " CF_TOKEN
    if [ -z "$CF_TOKEN" ]; then
        fail "Token tidak boleh kosong."
        pause
        return 1
    fi
    cloudflared service install "$CF_TOKEN"
    systemctl enable --now cloudflared
    log_msg "Cloudflare Connector token dipasang"
    echo -e "${GREEN}Cloudflare Connector aktif.${NC}"
    pause
}

function setup_cloudflare_named_tunnel() {
    require_root || return 1
    require_debian_family || return 1
    install_cloudflared || return 1
    read -r -p "Nama tunnel [pterodactyl-local]: " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-pterodactyl-local}
    read -r -p "Domain panel Cloudflare, contoh panel.domain.com: " TUNNEL_DOMAIN
    TUNNEL_DOMAIN=$(validate_domain "$TUNNEL_DOMAIN") || {
        fail "Format domain tidak valid."
        pause
        return 1
    }

    echo -e "${YELLOW}Jika belum login, browser akan diminta untuk authorize akun Cloudflare.${NC}"
    cloudflared tunnel login || return 1

    if ! cloudflared tunnel list | awk '{print $2}' | grep -qx "$TUNNEL_NAME"; then
        cloudflared tunnel create "$TUNNEL_NAME" || return 1
    fi

    local tunnel_id credentials_file
    tunnel_id=$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$2 == name {print $1; exit}')
    credentials_file="/root/.cloudflared/${tunnel_id}.json"
    mkdir -p /etc/cloudflared
    cat > /etc/cloudflared/config.yml <<CFCONFIG
tunnel: $tunnel_id
credentials-file: $credentials_file

ingress:
  - hostname: $TUNNEL_DOMAIN
    service: https://localhost:443
    originRequest:
      noTLSVerify: true
      httpHostHeader: $TUNNEL_DOMAIN
  - service: http_status:404
CFCONFIG

    cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_DOMAIN" || true
    cloudflared service install >/dev/null 2>&1 || true
    systemctl enable --now cloudflared

    if [ -f "$PANEL_DIR/.env" ]; then
        set_env_value APP_URL "https://$TUNNEL_DOMAIN"
        set_env_value TRUSTED_PROXIES "*"
        cd "$PANEL_DIR" || return 1
        php artisan config:clear >/dev/null 2>&1 || true
        php artisan cache:clear >/dev/null 2>&1 || true
    fi
    PANEL_DOMAIN="$TUNNEL_DOMAIN"
    save_config
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        sed -i "s/server_name .*/server_name $TUNNEL_DOMAIN;/" \
            /etc/nginx/sites-available/pterodactyl.conf
        nginx -t && systemctl reload nginx
    fi
    log_msg "Named tunnel $TUNNEL_NAME aktif untuk $TUNNEL_DOMAIN"
    echo -e "${GREEN}Named Tunnel aktif: https://$TUNNEL_DOMAIN -> http://localhost:80${NC}"
    pause
}

function set_panel_domain() {
    require_root || return 1
    read -r -p "Domain panel Cloudflare, contoh panel.domain.com: " RAW_DOMAIN
    local domain_only
    domain_only=$(validate_domain "$RAW_DOMAIN") || {
        fail "Format domain tidak valid."
        pause
        return 1
    }
    local panel_url="https://$domain_only"
    PANEL_DOMAIN="$domain_only"
    save_config
    if [ -f "$PANEL_DIR/.env" ]; then
        set_env_value APP_URL "$panel_url"
        set_env_value TRUSTED_PROXIES "*"
        cd "$PANEL_DIR" || return 1
        php artisan config:clear >/dev/null 2>&1 || true
        php artisan cache:clear >/dev/null 2>&1 || true
        php artisan queue:restart >/dev/null 2>&1 || true
        chown www-data:www-data "$PANEL_DIR/.env" 2>/dev/null || true
    fi
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        sed -i "s/server_name .*/server_name $domain_only;/" \
            /etc/nginx/sites-available/pterodactyl.conf
        nginx -t && systemctl reload nginx
    fi
    log_msg "Domain panel diset ke $panel_url"
    echo -e "${GREEN}Domain panel diset ke $panel_url.${NC}"
    pause
}

# ====================================================
# FIREWALL
# ====================================================

function setup_firewall() {
    require_root || return 1
    local mode="${DEPLOY_MODE:-tunnel}"
    echo -e "${BLUE}[*] Mengkonfigurasi UFW (mode: $mode)...${NC}"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "SSH"
    if [ "$mode" = "public" ]; then
        ufw allow 80/tcp  comment "HTTP (Let's Encrypt + redirect)"
        ufw allow 443/tcp comment "HTTPS Panel"
    else
        # Tunnel: nginx hanya diakses oleh cloudflared di loopback
        ufw allow from 127.0.0.1 to any port 80  comment "HTTP loopback (tunnel)"
        ufw allow from 127.0.0.1 to any port 443 comment "HTTPS loopback (tunnel)"
        ufw deny  80/tcp  comment "Block HTTP publik (tunnel mode)"
        ufw deny  443/tcp comment "Block HTTPS publik (tunnel mode)"
    fi
    ufw allow 8080/tcp comment "Wings HTTP"
    ufw allow 2022/tcp comment "Wings SFTP"
    ufw --force enable
    ufw status verbose
    log_msg "UFW dikonfigurasi (mode $mode)"
    pause
}

# ====================================================
# MODE DEPLOY (tunnel vs public IP)
# ====================================================

function select_deploy_mode() {
    require_root || return 1
    header
    echo -e "${BLUE}Mode Deploy${NC}"
    echo -e "Mode saat ini: ${CYAN}${DEPLOY_MODE:-tunnel}${NC}"
    echo
    echo "1) tunnel  -> Server lokal/VPS tanpa IP publik (Cloudflare Tunnel terminasi TLS)"
    echo "2) public  -> Server dengan IP publik + HTTPS Let's Encrypt langsung"
    echo "0) Batal"
    read -r -p "Pilih [0-2]: " M
    case "$M" in
        1) DEPLOY_MODE="tunnel" ;;
        2) DEPLOY_MODE="public" ;;
        *) echo "Dibatalkan."; pause; return 0 ;;
    esac
    save_config

    # Sync TRUSTED_PROXIES sesuai mode
    if [ -f "$PANEL_DIR/.env" ]; then
        if [ "$DEPLOY_MODE" = "public" ]; then
            set_env_value TRUSTED_PROXIES "127.0.0.1"
        else
            set_env_value TRUSTED_PROXIES "*"
        fi
        cd "$PANEL_DIR" && php artisan config:clear >/dev/null 2>&1 || true
    fi

    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        if confirm_action "Generate ulang konfigurasi Nginx untuk mode '$DEPLOY_MODE'?"; then
            write_nginx_config
            nginx -t && systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        fi
    fi
    log_msg "Mode deploy diset: $DEPLOY_MODE"
    echo -e "${GREEN}Mode di-set ke: $DEPLOY_MODE${NC}"
    pause
}

function setup_letsencrypt() {
    require_root || return 1
    require_debian_family || return 1
    if [ "${DEPLOY_MODE:-tunnel}" != "public" ]; then
        echo -e "${YELLOW}Mode saat ini '${DEPLOY_MODE:-tunnel}'. Let's Encrypt biasanya dipakai pada mode 'public'.${NC}"
        echo -e "${YELLOW}Pertimbangkan ganti mode dulu via menu Pilih Mode Deploy.${NC}"
        confirm_action "Lanjut tetap setup HTTPS sekarang?" || { pause; return 0; }
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Install certbot...${NC}"
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y certbot python3-certbot-nginx
    fi

    read -r -p "Domain panel (contoh panel.domain.com) [${PANEL_DOMAIN:-}]: " RAW
    RAW=${RAW:-$PANEL_DOMAIN}
    local domain
    domain=$(validate_domain "$RAW") || { fail "Format domain tidak valid."; pause; return 1; }
    read -r -p "Email untuk notifikasi LE [${LE_EMAIL:-}]: " EMAIL
    EMAIL=${EMAIL:-$LE_EMAIL}
    if [ -z "$EMAIL" ]; then
        fail "Email wajib diisi."; pause; return 1
    fi

    # Pre-flight DNS check
    local server_ip resolved_ip
    server_ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    resolved_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1; exit}')
    echo -e "${CYAN}IP server      : ${server_ip:-tidak terdeteksi}${NC}"
    echo -e "${CYAN}A-record domain: ${resolved_ip:-tidak terdeteksi}${NC}"
    if [ -n "$server_ip" ] && [ -n "$resolved_ip" ] && [ "$server_ip" != "$resolved_ip" ]; then
        echo -e "${YELLOW}DNS belum mengarah ke server ini. Cert HTTP-01 kemungkinan gagal.${NC}"
        confirm_action "Lanjutkan tetap?" || { pause; return 1; }
    fi

    # Pastikan port 80 reachable
    if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ':80$'; then
        echo -e "${BLUE}[*] Nginx belum listen :80, generate config dasar...${NC}"
        PANEL_DOMAIN="$domain"
        DEPLOY_MODE="public"
        save_config
        provision_services
    fi

    PANEL_DOMAIN="$domain"
    LE_EMAIL="$EMAIL"
    DEPLOY_MODE="public"
    save_config

    # Pastikan ada server block sementara untuk HTTP-01
    write_nginx_config
    nginx -t && systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true

    if certbot --nginx --non-interactive --agree-tos -m "$EMAIL" -d "$domain" --redirect --keep-until-expiring; then
        # Setelah cert tersedia, tulis ulang config kita supaya pakai path LE (bukan modifikasi certbot)
        write_nginx_config
        nginx -t && systemctl reload nginx 2>/dev/null || true
        systemctl enable --now certbot.timer 2>/dev/null || true

        if [ -f "$PANEL_DIR/.env" ]; then
            set_env_value APP_URL "https://$domain"
            set_env_value TRUSTED_PROXIES "127.0.0.1"
            cd "$PANEL_DIR" && php artisan config:clear >/dev/null 2>&1 || true
        fi
        log_msg "Let's Encrypt cert diterbitkan untuk $domain"
        notify_detail "HTTPS OK" "Sertifikat Let's Encrypt aktif untuk $domain"
        echo -e "${GREEN}HTTPS aktif: https://$domain${NC}"
        echo -e "${CYAN}Auto-renewal via systemd timer 'certbot.timer'.${NC}"
    else
        fail "Penerbitan cert gagal. Cek DNS, port 80 terbuka di firewall, dan /var/log/letsencrypt/."
    fi
    pause
}

function setup_fail2ban() {
    require_root || return 1
    require_debian_family || return 1
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Install fail2ban...${NC}"
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y fail2ban
    fi
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/ptero-manager.conf <<'F2B'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ssh

[nginx-http-auth]
enabled  = true
filter   = nginx-http-auth
port     = http,https
logpath  = /var/log/nginx/error.log

[nginx-botsearch]
enabled  = true
filter   = nginx-botsearch
port     = http,https
logpath  = /var/log/nginx/access.log
F2B
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    log_msg "Fail2ban dipasang"
    echo -e "${GREEN}Fail2ban aktif (jail: sshd, nginx-http-auth, nginx-botsearch).${NC}"
    fail2ban-client status 2>/dev/null | sed 's/^/  /'
    pause
}

function fail2ban_status() {
    require_root || return 1
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${YELLOW}Fail2ban belum terpasang.${NC}"; pause; return 0
    fi
    header
    echo -e "${BLUE}Status Fail2ban${NC}"
    fail2ban-client status 2>/dev/null | sed 's/^/  /'
    echo
    for jail in sshd nginx-http-auth nginx-botsearch; do
        if fail2ban-client status "$jail" >/dev/null 2>&1; then
            echo -e "${CYAN}== $jail ==${NC}"
            fail2ban-client status "$jail" | sed 's/^/  /'
            echo
        fi
    done
    pause
}

# ====================================================
# MONITORING & HEALTH
# ====================================================

function health_check() {
    require_root || return 1
    header
    echo -e "${BLUE}Status Service:${NC}"
    service_status_line nginx
    service_status_line "php${PHP_VERSION}-fpm"
    service_status_line mariadb
    service_status_line redis-server
    service_status_line docker
    service_status_line wings
    service_status_line pteroq
    service_status_line cloudflared

    echo
    echo -e "${BLUE}Port Aktif:${NC}"
    ss -lntp 2>/dev/null | grep -E ':(80|443|8080|2022|3306|6379)\b' \
        || echo "  Tidak ada port penting yang terdeteksi."

    echo
    echo -e "${BLUE}Disk & RAM:${NC}"
    df -h / | awk 'NR==2 {printf "  Disk: %s / %s (%s)\n", $3, $2, $5}'
    free -h | awk '/^Mem:/ {printf "  RAM:  %s / %s\n", $3, $2}'

    # Peringatan disk hampir penuh
    local disk_pct
    disk_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    if [ -n "$disk_pct" ] && [ "$disk_pct" -ge 85 ]; then
        echo -e "  ${RED}PERINGATAN: Disk sudah ${disk_pct}% penuh!${NC}"
        notify_detail "DISK WARNING" "Disk server ${disk_pct}% penuh!"
    fi

    echo
    echo -e "${BLUE}Panel & Wings:${NC}"
    if [ -f "$PANEL_DIR/artisan" ]; then
        echo -e "  ${GREEN}[OK]${NC} Panel ditemukan di $PANEL_DIR"
        grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | sed 's/^/  /'
        grep '^TRUSTED_PROXIES=' "$PANEL_DIR/.env" 2>/dev/null | sed 's/^/  /'
    else
        echo -e "  ${RED}[MISSING]${NC} Panel tidak ditemukan"
    fi
    if [ -f "$WINGS_DIR/config.yml" ]; then
        echo -e "  ${GREEN}[OK]${NC} Config Wings ditemukan"
    else
        echo -e "  ${YELLOW}[INFO]${NC} Config Wings belum ditemukan (generate dari panel)"
    fi

    echo
    echo -e "${BLUE}Cloudflare Tunnel:${NC}"
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared tunnel list 2>/dev/null \
            || echo "  Cloudflared terpasang. Jika memakai token connector, cek dashboard Cloudflare."
    else
        echo -e "  ${YELLOW}Cloudflared belum terpasang.${NC}"
    fi

    echo
    echo -e "${BLUE}Cek konektivitas panel via tunnel:${NC}"
    if [ -f "$PANEL_DIR/.env" ]; then
        local app_url
        app_url=$(grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
        if [ -n "$app_url" ] && [ "$app_url" != "http://localhost" ]; then
            local code
            code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "$app_url" 2>/dev/null || echo "000")
            if echo "$code" | grep -Eq '^(200|302|301)$'; then
                echo -e "  ${GREEN}[OK]${NC} $app_url -> HTTP $code"
            else
                echo -e "  ${RED}[GAGAL]${NC} $app_url -> HTTP $code"
            fi
        else
            echo -e "  ${YELLOW}APP_URL belum dikonfigurasi.${NC}"
        fi
    fi

    log_msg "Health check dijalankan"
    pause
}

function info_system() {
    require_root || return 1
    header
    echo -e "${BLUE}Informasi Sistem Lengkap:${NC}"
    echo
    echo -e "${CYAN}OS:${NC}"
    grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | sed 's/^/  /'
    uname -r | sed 's/^/  Kernel: /'
    echo
    echo -e "${CYAN}Versi Komponen:${NC}"
    printf "  %-18s %s\n" "PHP:" "$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '-')"
    printf "  %-18s %s\n" "Nginx:" "$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "MariaDB/MySQL:" "$(mysql --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "Redis:" "$(redis-cli --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "Docker:" "$(docker --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "Composer:" "$(composer --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "Cloudflared:" "$(cloudflared --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    if [ -f /usr/local/bin/wings ]; then
        printf "  %-18s %s\n" "Wings:" "$(/usr/local/bin/wings --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    else
        printf "  %-18s %s\n" "Wings:" "tidak terpasang"
    fi
    echo
    echo -e "${CYAN}Panel:${NC}"
    if [ -f "$PANEL_DIR/artisan" ]; then
        printf "  %-18s %s\n" "Version:" "$(cd "$PANEL_DIR" && php artisan tinker --execute='echo app()->version();' 2>/dev/null | tail -1 || echo '-')"
        grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | sed 's/^/  /'
    else
        echo "  Panel belum terpasang."
    fi
    pause
}

function view_logs_menu() {
    require_root || return 1
    while true; do
        header
        echo "1) Log Wings (real-time)"
        echo "2) Log Queue Worker (real-time)"
        echo "3) Log Nginx error"
        echo "4) Log Panel Laravel"
        echo "5) Log Manager Script"
        echo "0) Kembali"
        read -r -p "Pilih [0-5]: " LOG_OPT
        case "$LOG_OPT" in
            1)
                if command -v journalctl >/dev/null 2>&1; then
                    journalctl -fu wings --no-pager
                elif [ -f /var/log/syslog ]; then
                    tail -f /var/log/syslog
                else
                    echo "Log Wings tidak tersedia (journalctl & /var/log/syslog tidak ada)."
                fi
                ;;
            2)
                if command -v journalctl >/dev/null 2>&1; then
                    journalctl -fu pteroq --no-pager
                else
                    echo "journalctl tidak tersedia."
                fi
                ;;
            3) tail -f /var/log/nginx/error.log 2>/dev/null || echo "Log Nginx tidak ditemukan." ;;
            4)
                local plog
                plog=$(ls -t "$PANEL_DIR/storage/logs/"*.log 2>/dev/null | head -1)
                if [ -n "$plog" ]; then
                    tail -f "$plog"
                else
                    echo "Log panel tidak ditemukan."
                fi
                ;;
            5) tail -f "$LOG_FILE" 2>/dev/null || echo "Log manager belum ada." ;;
            0) return 0 ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function check_wings_connection() {
    require_root || return 1
    header
    echo -e "${BLUE}Memeriksa koneksi Wings ke Panel...${NC}"
    echo
    if ! systemctl is-active --quiet wings; then
        echo -e "${RED}Wings tidak berjalan.${NC}"
    else
        echo -e "${GREEN}Wings sedang berjalan.${NC}"
    fi
    if [ -f "$WINGS_DIR/config.yml" ]; then
        echo -e "${GREEN}Config Wings ditemukan.${NC}"
        local panel_url
        panel_url=$(grep 'remote:' "$WINGS_DIR/config.yml" 2>/dev/null | awk '{print $2}')
        [ -n "$panel_url" ] && echo -e "  Panel URL di config Wings: $panel_url"
    else
        echo -e "${RED}Config Wings tidak ditemukan di $WINGS_DIR/config.yml${NC}"
        echo -e "${YELLOW}Generate config Wings dari: Panel > Admin > Nodes > [nama node] > Configuration${NC}"
    fi
    echo
    echo -e "${BLUE}Log Wings terbaru:${NC}"
    journalctl -u wings --no-pager -n 20 2>/dev/null \
        || echo "Log Wings tidak tersedia via journalctl."
    log_msg "Check Wings connection dijalankan"
    pause
}

# ====================================================
# USER & DATABASE MANAGEMENT
# ====================================================

function create_admin_user() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    php artisan p:user:make
    log_msg "Create user panel dijalankan"
    pause
}

function reset_admin_password() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    read -r -p "Username atau email admin: " ADMIN_USER
    if [ -z "$ADMIN_USER" ]; then
        fail "Username tidak boleh kosong."
        pause
        return 1
    fi
    php artisan p:user:edit "$ADMIN_USER"
    log_msg "Reset password admin: $ADMIN_USER"
    pause
}

function change_db_password() {
    require_root || return 1
    require_panel || return 1
    ask_mysql_root_password
    read -r -s -p "Password database BARU untuk user $DB_USER (min 8 char): " NEW_DB_PASS
    echo
    if ! validate_db_password "$NEW_DB_PASS" 8; then
        pause
        return 1
    fi
    if [ -z "$NEW_DB_PASS" ]; then
        fail "Password tidak boleh kosong."
        pause
        return 1
    fi
    local db_pass_sql
    db_pass_sql=$(printf "%s" "$NEW_DB_PASS" | sed "s/'/''/g")
    mysql_root -e "
        ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
        FLUSH PRIVILEGES;
    " || { fail "Gagal mengubah password di MariaDB."; pause; return 1; }
    set_env_value DB_PASSWORD "$NEW_DB_PASS"
    cd "$PANEL_DIR" || return 1
    php artisan config:clear >/dev/null 2>&1 || true
    php artisan queue:restart >/dev/null 2>&1 || true
    chown www-data:www-data "$PANEL_DIR/.env" 2>/dev/null || true
    systemctl restart pteroq "php${PHP_VERSION}-fpm" 2>/dev/null || true

    # Auto-update kredensial di file cnf auto-backup jika ada
    if [ -f "$AUTO_BACKUP_CNF" ] || [ -f "$AUTO_BACKUP_SCRIPT" ]; then
        mkdir -p "$(dirname "$AUTO_BACKUP_CNF")"
        chmod 700 "$(dirname "$AUTO_BACKUP_CNF")"
        local _old_umask
        _old_umask=$(umask); umask 077
        {
            printf '[client]\n'
            printf 'user=%s\n' "$DB_USER"
            printf 'password=%s\n' "$NEW_DB_PASS"
            printf 'host=127.0.0.1\n'
        } > "$AUTO_BACKUP_CNF"
        chmod 600 "$AUTO_BACKUP_CNF"
        umask "$_old_umask"
        # Pastikan wrapper script juga pakai versi cnf-based
        local script_path
        script_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
        cat > "$AUTO_BACKUP_SCRIPT" <<AUTO
#!/bin/bash
exec bash '$script_path' --auto-backup --cnf '$AUTO_BACKUP_CNF'
AUTO
        chmod 700 "$AUTO_BACKUP_SCRIPT"
        echo -e "${GREEN}Kredensial auto-backup juga diperbarui.${NC}"
    fi

    log_msg "Password database $DB_USER diubah"
    echo -e "${GREEN}Password database berhasil diubah dan .env diperbarui.${NC}"
    pause
}

# ====================================================
# OPTIMASI
# ====================================================

function discord_setup() {
    require_root || return 1
    header
    echo -e "${BLUE}Setup Discord Webhook${NC}"
    echo -e "Webhook saat ini: ${CYAN}${DISCORD_WEBHOOK:-belum diset}${NC}"
    echo
    echo "1) Set/ubah URL webhook"
    echo "2) Test kirim pesan"
    echo "3) Hapus webhook"
    echo "0) Kembali"
    read -r -p "Pilih [0-3]: " WH_OPT
    case "$WH_OPT" in
        1)
            read -r -p "URL webhook Discord: " NEW_URL
            if ! echo "$NEW_URL" | grep -Eq '^https://discord(app)?\.com/api/webhooks/'; then
                fail "URL webhook tidak valid."; pause; return 1
            fi
            DISCORD_WEBHOOK="$NEW_URL"
            save_config
            echo -e "${GREEN}Webhook tersimpan.${NC}"
            ;;
        2)
            if [ -z "$DISCORD_WEBHOOK" ]; then
                fail "Webhook belum diset."; pause; return 1
            fi
            notify_detail "TEST" "Pesan test dari Ptero Manager V$SCRIPT_VERSION"
            echo -e "${GREEN}Pesan test dikirim. Cek channel Discord Anda.${NC}"
            ;;
        3)
            DISCORD_WEBHOOK=""
            save_config
            echo -e "${GREEN}Webhook dihapus.${NC}"
            ;;
        *) return 0 ;;
    esac
    pause
}

function restart_all_services() {
    require_root || return 1
    echo -e "${BLUE}[*] Restart semua service Pterodactyl...${NC}"
    for svc in mariadb redis-server "php${PHP_VERSION}-fpm" nginx pteroq wings cloudflared; do
        if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
            echo -n "  - $svc ... "
            if systemctl restart "$svc" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}GAGAL${NC}"
            fi
        fi
    done
    if [ -f "$PANEL_DIR/artisan" ]; then
        cd "$PANEL_DIR" && php artisan queue:restart >/dev/null 2>&1 || true
    fi
    log_msg "Restart semua service"
    pause
}

function check_script_update() {
    require_root || return 1
    header
    if [ -z "$SCRIPT_UPDATE_URL" ]; then
        echo -e "${YELLOW}URL update belum diset.${NC}"
        echo
        read -r -p "Masukkan URL raw script (contoh https://.../ptero.sh) atau kosong untuk batal: " URL
        if [ -z "$URL" ]; then return 0; fi
        SCRIPT_UPDATE_URL="$URL"
        save_config
    fi
    echo -e "${BLUE}Cek versi terbaru dari $SCRIPT_UPDATE_URL ...${NC}"
    local tmp="/tmp/ptero.sh.new"
    if ! curl -fsSL "$SCRIPT_UPDATE_URL" -o "$tmp"; then
        rm -f "$tmp"; fail "Gagal download script terbaru."; pause; return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"; fail "Script terbaru rusak (syntax error)."; pause; return 1
    fi
    local new_ver
    new_ver=$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)
    echo -e "Versi sekarang : ${CYAN}$SCRIPT_VERSION${NC}"
    echo -e "Versi terbaru  : ${CYAN}${new_ver:-unknown}${NC}"
    if [ "$new_ver" = "$SCRIPT_VERSION" ]; then
        echo -e "${GREEN}Sudah versi terbaru.${NC}"
        rm -f "$tmp"; pause; return 0
    fi
    confirm_action "Update script ke versi $new_ver?" || { rm -f "$tmp"; pause; return 0; }
    local current
    current=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    cp -f "$current" "${current}.bak"
    mv -f "$tmp" "$current"
    chmod +x "$current"
    log_msg "Script di-update ke versi $new_ver"
    echo -e "${GREEN}Script berhasil di-update. Backup lama: ${current}.bak${NC}"
    echo -e "${YELLOW}Jalankan ulang script untuk memuat versi baru.${NC}"
    pause
    exit 0
}

function generate_wings_config_api() {
    require_root || return 1
    require_panel || return 1
    install_wings_binary || return 1
    header
    echo -e "${BLUE}Generate Wings config.yml dari Panel API${NC}"
    echo -e "${YELLOW}Ambil token konfigurasi dari: Panel > Admin > Nodes > [node] > Configuration > Generate Token${NC}"
    echo
    read -r -p "Panel URL (contoh https://panel.domain.com): " P_URL
    read -r -p "Node ID (angka, lihat di URL admin/nodes/<id>): " N_ID
    read -r -s -p "Token konfigurasi node: " N_TOKEN
    echo
    if [ -z "$P_URL" ] || [ -z "$N_ID" ] || [ -z "$N_TOKEN" ]; then
        fail "Panel URL, Node ID, dan token wajib diisi."; pause; return 1
    fi
    mkdir -p "$WINGS_DIR"
    if ! curl -fsSL -H "Authorization: Bearer $N_TOKEN" -H "Accept: application/vnd.pterodactyl.v1+json" \
            "${P_URL%/}/api/application/nodes/$N_ID/configuration" \
            -o "$WINGS_DIR/config.yml"; then
        fail "Gagal mengambil config dari panel. Cek URL/token/Node ID."; pause; return 1
    fi
    if [ ! -s "$WINGS_DIR/config.yml" ] || ! grep -q '^token:' "$WINGS_DIR/config.yml"; then
        fail "Config yang diterima tidak valid."
        rm -f "$WINGS_DIR/config.yml"; pause; return 1
    fi
    chmod 600 "$WINGS_DIR/config.yml"
    systemctl restart wings 2>/dev/null || true
    log_msg "Wings config.yml di-generate via API untuk node $N_ID"
    echo -e "${GREEN}Wings config tersimpan di $WINGS_DIR/config.yml${NC}"
    pause
}

function export_config() {
    require_root || return 1
    save_config
    local out="/root/ptero-manager-export-$(date +%F_%H-%M-%S).conf"
    cp "$CONFIG_FILE" "$out" 2>/dev/null || true
    {
        echo "# Pterodactyl Manager Export"
        echo "# Versi: $SCRIPT_VERSION  Tanggal: $(date)"
        echo
        [ -f "$PANEL_DIR/.env" ] && grep -E '^(APP_URL|APP_TIMEZONE|DB_DATABASE|DB_USERNAME|TRUSTED_PROXIES)=' "$PANEL_DIR/.env"
        echo
        echo "# Cron auto-backup:"
        cat /etc/cron.d/ptero-manager-backup 2>/dev/null
    } >> "$out"
    chmod 600 "$out"
    echo -e "${GREEN}Konfigurasi diekspor ke: $out${NC}"
    pause
}

function optimize_server() {
    require_root || return 1
    header
    echo -e "${BLUE}[*] Mengoptimasi server untuk mesin kecil...${NC}"
    echo

    # PHP: tuning memory & upload
    local php_ini="/etc/php/${PHP_VERSION}/fpm/conf.d/99-ptero-tuning.ini"
    cat > "$php_ini" <<PHPINI
memory_limit = 256M
upload_max_filesize = 100M
post_max_size = 100M
max_execution_time = 120
opcache.enable = 1
opcache.memory_consumption = 128
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 0
PHPINI
    echo -e "  ${GREEN}[OK]${NC} PHP tuning: $php_ini"

    # MariaDB: tuning ringan
    local my_cnf="/etc/mysql/conf.d/ptero-tuning.cnf"
    cat > "$my_cnf" <<MYCNF
[mysqld]
innodb_buffer_pool_size = 128M
query_cache_type = 1
query_cache_size = 32M
max_connections = 100
wait_timeout = 60
interactive_timeout = 60
MYCNF
    echo -e "  ${GREEN}[OK]${NC} MariaDB tuning: $my_cnf"

    # Redis: batas memori
    local redis_conf="/etc/redis/conf.d/ptero-tuning.conf"
    mkdir -p /etc/redis/conf.d
    cat > "$redis_conf" <<REDISCONF
maxmemory 128mb
maxmemory-policy allkeys-lru
REDISCONF
    if ! grep -q "include /etc/redis/conf.d" /etc/redis/redis.conf 2>/dev/null; then
        echo "include /etc/redis/conf.d/*.conf" >> /etc/redis/redis.conf
    fi
    echo -e "  ${GREEN}[OK]${NC} Redis tuning: $redis_conf"

    systemctl restart "php${PHP_VERSION}-fpm" mariadb redis-server 2>/dev/null || true
    log_msg "Optimasi server kecil diterapkan"
    echo
    echo -e "${GREEN}Optimasi selesai.${NC} (revert via menu Repair > Revert Optimasi)"
    pause
}

function optimize_revert() {
    require_root || return 1
    echo -e "${BLUE}[*] Membatalkan tuning optimasi...${NC}"
    rm -f "/etc/php/${PHP_VERSION}/fpm/conf.d/99-ptero-tuning.ini"
    rm -f /etc/mysql/conf.d/ptero-tuning.cnf
    rm -f /etc/redis/conf.d/ptero-tuning.conf
    sed -i '\#include /etc/redis/conf.d/\*\.conf#d' /etc/redis/redis.conf 2>/dev/null || true
    systemctl restart "php${PHP_VERSION}-fpm" mariadb redis-server 2>/dev/null || true
    log_msg "Optimasi server di-revert"
    echo -e "${GREEN}Tuning dibatalkan, kembali ke default.${NC}"
    pause
}

# ====================================================
# FITUR LANJUTAN V5.4
# ====================================================

function telegram_setup() {
    require_root || return 1
    header
    echo -e "${BLUE}Setup Telegram Notifikasi${NC}"
    echo -e "Bot Token saat ini: ${CYAN}${TELEGRAM_BOT_TOKEN:+(terisi)}${TELEGRAM_BOT_TOKEN:-belum diset}${NC}"
    echo -e "Chat ID saat ini  : ${CYAN}${TELEGRAM_CHAT_ID:-belum diset}${NC}"
    echo
    echo "1) Set Bot Token + Chat ID"
    echo "2) Test kirim pesan"
    echo "3) Hapus konfigurasi Telegram"
    echo "0) Kembali"
    read -r -p "Pilih [0-3]: " TG
    case "$TG" in
        1)
            read -r -p "Bot Token (dari @BotFather): " T_TOKEN
            read -r -p "Chat ID (kirim pesan ke bot, lalu cek getUpdates): " T_CHAT
            if [ -z "$T_TOKEN" ] || [ -z "$T_CHAT" ]; then
                fail "Token dan Chat ID wajib diisi."; pause; return 1
            fi
            TELEGRAM_BOT_TOKEN="$T_TOKEN"
            TELEGRAM_CHAT_ID="$T_CHAT"
            save_config
            echo -e "${GREEN}Konfigurasi Telegram tersimpan.${NC}"
            ;;
        2)
            if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
                fail "Belum dikonfigurasi."; pause; return 1
            fi
            notify_detail "TEST TG" "Pesan test dari Ptero Manager V$SCRIPT_VERSION"
            echo -e "${GREEN}Pesan test dikirim ke Telegram.${NC}"
            ;;
        3)
            TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
            save_config
            echo -e "${GREEN}Konfigurasi Telegram dihapus.${NC}"
            ;;
    esac
    pause
}

function set_custom_banner() {
    require_root || return 1
    echo -e "Banner saat ini: ${CYAN}${CUSTOM_BANNER:-(kosong)}${NC}"
    read -r -p "Banner baru (kosongkan untuk hapus): " NB
    CUSTOM_BANNER="$NB"
    save_config
    echo -e "${GREEN}Banner tersimpan.${NC}"
    pause
}

function script_rollback() {
    require_root || return 1
    local current bak
    current=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    bak="${current}.bak"
    if [ ! -f "$bak" ]; then
        fail "File backup tidak ditemukan: $bak"; pause; return 1
    fi
    confirm_action "Rollback script ke versi sebelum self-update?" \
        || { echo "Batal."; pause; return 0; }
    cp -f "$current" "${current}.tmp"
    mv -f "$bak" "$current"
    mv -f "${current}.tmp" "$bak"
    chmod +x "$current"
    log_msg "Script di-rollback dari .bak"
    echo -e "${GREEN}Rollback selesai. Jalankan ulang script.${NC}"
    pause
    exit 0
}

function backup_stats() {
    require_root || return 1
    header
    echo -e "${BLUE}Statistik Backup${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."; pause; return 0
    fi
    local total count
    count=$(ls -1d "$BACKUP_ROOT"/ptero_* 2>/dev/null | wc -l)
    total=$(du -sh "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}')
    echo -e "Jumlah backup : ${CYAN}$count${NC}"
    echo -e "Total ukuran  : ${CYAN}$total${NC}"
    if [ "$count" -gt 0 ]; then
        local newest oldest biggest smallest
        newest=$(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null | head -1)
        oldest=$(ls -1dtr "$BACKUP_ROOT"/ptero_* 2>/dev/null | head -1)
        biggest=$(du -s "$BACKUP_ROOT"/ptero_* 2>/dev/null | sort -rn | head -1)
        smallest=$(du -s "$BACKUP_ROOT"/ptero_* 2>/dev/null | sort -n | head -1)
        echo -e "Terbaru       : $(basename "$newest") ($(stat -c %y "$newest" 2>/dev/null | cut -d. -f1))"
        echo -e "Tertua        : $(basename "$oldest") ($(stat -c %y "$oldest" 2>/dev/null | cut -d. -f1))"
        echo -e "Terbesar      : $(basename "$(echo "$biggest" | awk '{print $2}')") ($(echo "$biggest" | awk '{printf "%.1fM", $1/1024}'))"
        echo -e "Terkecil      : $(basename "$(echo "$smallest" | awk '{print $2}')") ($(echo "$smallest" | awk '{printf "%.1fM", $1/1024}'))"
        echo
        echo -e "Retensi  : $BACKUP_RETENTION_DAYS hari (max $BACKUP_MAX_COUNT backup)"
    fi
    if [ -f /etc/cron.d/ptero-manager-backup ]; then
        echo
        echo -e "${BLUE}Jadwal backup otomatis:${NC}"
        grep -E '^[0-9]' /etc/cron.d/ptero-manager-backup | sed 's/^/  /'
    fi
    pause
}

function db_optimize() {
    require_root || return 1
    require_panel || return 1
    read -r -s -p "Password database $DB_USER: " DBP
    echo
    echo -e "${BLUE}[*] Menjalankan OPTIMIZE TABLE + auto-repair...${NC}"
    if mysqlcheck_secure "$DB_USER" "$DBP" -h 127.0.0.1 --auto-repair --optimize "$DB_NAME"; then
        log_msg "Database $DB_NAME dioptimasi"
        echo -e "${GREEN}Optimasi database selesai.${NC}"
    else
        fail "Optimasi gagal. Periksa password / kredensial."
    fi
    pause
}

function security_audit() {
    require_root || return 1
    header
    echo -e "${BLUE}Security Audit${NC}"
    echo
    local issues=0

    if [ -f "$PANEL_DIR/.env" ]; then
        local perm owner
        perm=$(stat -c %a "$PANEL_DIR/.env" 2>/dev/null)
        owner=$(stat -c %U "$PANEL_DIR/.env" 2>/dev/null)
        if [ "$perm" != "640" ] && [ "$perm" != "600" ]; then
            echo -e "  ${YELLOW}[WARN]${NC} .env permission $perm (rekomendasi 640)"
            issues=$((issues+1))
        else
            echo -e "  ${GREEN}[OK]${NC} .env permission $perm"
        fi
        if [ "$owner" != "www-data" ] && [ "$owner" != "root" ]; then
            echo -e "  ${YELLOW}[WARN]${NC} .env owner: $owner"
            issues=$((issues+1))
        fi
    fi

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q 'Status: active'; then
            echo -e "  ${GREEN}[OK]${NC} UFW aktif"
        else
            echo -e "  ${RED}[FAIL]${NC} UFW tidak aktif"
            issues=$((issues+1))
        fi
    fi

    if [ -f /etc/ssh/sshd_config ]; then
        if grep -Eq '^\s*PermitRootLogin\s+yes' /etc/ssh/sshd_config; then
            echo -e "  ${YELLOW}[WARN]${NC} SSH PermitRootLogin yes (rekomendasi prohibit-password)"
            issues=$((issues+1))
        else
            echo -e "  ${GREEN}[OK]${NC} SSH root login restricted"
        fi
        if grep -Eq '^\s*PasswordAuthentication\s+yes' /etc/ssh/sshd_config; then
            echo -e "  ${YELLOW}[WARN]${NC} SSH password auth aktif"
            issues=$((issues+1))
        fi
    fi

    if [ -f "$PANEL_DIR/.env" ]; then
        local dbpw
        dbpw=$(grep '^DB_PASSWORD=' "$PANEL_DIR/.env" | cut -d= -f2-)
        if [ "${#dbpw}" -lt 12 ]; then
            echo -e "  ${RED}[FAIL]${NC} DB password terlalu pendek (${#dbpw} karakter)"
            issues=$((issues+1))
        else
            echo -e "  ${GREEN}[OK]${NC} DB password panjang ${#dbpw} karakter"
        fi
    fi

    local php_v db_v
    php_v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
    if [ -n "$php_v" ]; then
        if echo "$php_v" | awk -F. '{ exit !($1 < 8 || ($1 == 8 && $2 < 1)) }'; then
            echo -e "  ${YELLOW}[WARN]${NC} PHP $php_v sudah tua"
            issues=$((issues+1))
        else
            echo -e "  ${GREEN}[OK]${NC} PHP versi $php_v"
        fi
    fi

    local open_ports
    open_ports=$(ss -lntH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | tr '\n' ' ')
    echo -e "  ${BLUE}[INFO]${NC} Port listen: $open_ports"

    echo
    if [ "$issues" -eq 0 ]; then
        echo -e "${GREEN}Tidak ada masalah keamanan terdeteksi.${NC}"
    else
        echo -e "${YELLOW}Ditemukan $issues isu keamanan.${NC}"
    fi
    log_msg "Security audit dijalankan ($issues isu)"
    pause
}

function panel_user_manager() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    while true; do
        header
        echo -e "${BLUE}Manajemen User Panel${NC}"
        echo "1) List semua user"
        echo "2) Buat user baru"
        echo "3) Edit user (reset pass / set admin)"
        echo "4) Hapus user"
        echo "0) Kembali"
        read -r -p "Pilih [0-4]: " UO
        case "$UO" in
            1) php artisan p:user:list 2>/dev/null || echo "Command p:user:list tidak tersedia di versi panel ini."; pause ;;
            2) php artisan p:user:make; pause ;;
            3)
                read -r -p "Username/email: " U
                [ -n "$U" ] && php artisan p:user:edit "$U"
                pause
                ;;
            4)
                read -r -p "Username/email yang akan dihapus: " U
                if [ -n "$U" ]; then
                    confirm_action "Hapus user $U? Tidak bisa di-undo." && php artisan p:user:delete "$U"
                fi
                pause
                ;;
            0) return 0 ;;
        esac
    done
}

function bulk_server_action() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    header
    echo -e "${BLUE}Bulk Action Server Pterodactyl${NC}"
    echo "1) Suspend semua server"
    echo "2) Unsuspend semua server"
    echo "3) Restart semua container Wings"
    echo "0) Batal"
    read -r -p "Pilih [0-3]: " BO
    case "$BO" in
        1)
            confirm_action "Suspend SEMUA server panel?" || { pause; return 0; }
            php artisan tinker --execute='Pterodactyl\Models\Server::query()->update(["suspended" => true]); echo "OK";' 2>&1 | tail -3
            log_msg "Bulk suspend semua server"
            ;;
        2)
            confirm_action "Unsuspend SEMUA server panel?" || { pause; return 0; }
            php artisan tinker --execute='Pterodactyl\Models\Server::query()->update(["suspended" => false]); echo "OK";' 2>&1 | tail -3
            log_msg "Bulk unsuspend semua server"
            ;;
        3)
            confirm_action "Restart SEMUA container Pterodactyl di Docker?" || { pause; return 0; }
            # Docker --filter name= adalah substring, BUKAN regex.
            # Container Pterodactyl dinamai pakai UUID server (36 char hex+dash),
            # jadi kita filter manual via grep -E pada nama.
            mapfile -t containers < <(
                docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null \
                    | awk '$2 ~ /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/ {print $1}'
            )
            if [ "${#containers[@]}" -eq 0 ]; then
                echo "Tidak ada container Pterodactyl yang berjalan."
            else
                docker restart "${containers[@]}"
                echo -e "${GREEN}${#containers[@]} container di-restart.${NC}"
                log_msg "Bulk restart ${#containers[@]} container"
            fi
            ;;
    esac
    pause
}

function wings_watchdog_setup() {
    require_root || return 1
    echo -e "${BLUE}Setup Wings Watchdog${NC}"
    echo "Watchdog akan cek Wings tiap 5 menit dan restart jika DOWN."
    confirm_action "Pasang watchdog?" || { pause; return 0; }
    cat > /usr/local/sbin/ptero-wings-watchdog.sh <<'WATCH'
#!/bin/bash
LOG=/var/log/ptero-manager.log
if ! systemctl is-active --quiet wings; then
    echo "[$(date '+%F %T')] Watchdog: Wings DOWN, mencoba restart..." >> "$LOG"
    systemctl restart wings
fi
WATCH
    chmod 700 /usr/local/sbin/ptero-wings-watchdog.sh
    cat > /etc/cron.d/ptero-wings-watchdog <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/sbin/ptero-wings-watchdog.sh
CRON
    systemctl restart cron 2>/dev/null || true
    log_msg "Wings watchdog dipasang"
    echo -e "${GREEN}Watchdog aktif (cek tiap 5 menit).${NC}"
    pause
}

function wings_watchdog_remove() {
    require_root || return 1
    rm -f /usr/local/sbin/ptero-wings-watchdog.sh /etc/cron.d/ptero-wings-watchdog
    systemctl restart cron 2>/dev/null || true
    log_msg "Wings watchdog dihapus"
    echo -e "${GREEN}Watchdog dihapus.${NC}"
    pause
}

function help_screen() {
    header
    cat <<HELP
${BLUE}=== BANTUAN PTERO MANAGER V$SCRIPT_VERSION ===${NC}

${CYAN}Konsep dasar:${NC}
  Mendukung 2 mode deploy:
    - tunnel  : server lokal/VPS tanpa IP publik, akses via Cloudflare Tunnel.
    - public  : server dengan IP publik, akses via HTTPS Let's Encrypt langsung.
  Pilih mode dulu di menu 47 sebelum install/regenerate Nginx.

${CYAN}Alur instalasi mode TUNNEL (tanpa IP publik):${NC}
  Nginx tetap pakai HTTPS di port 443 loopback (default self-signed cert).
  Cloudflared diarahkan ke https://localhost:443 dengan noTLSVerify, jadi
  Cloudflare bisa pakai SSL mode 'Full' atau 'Full (Strict)' end-to-end.
  1. Menu 47 -> Pilih mode 'tunnel'
  2. Menu 1  -> Full Install Panel + Wings (auto-generate self-signed cert)
  3. Menu 7/8 -> Setup Cloudflare Tunnel (token connector ATAU named tunnel)
  4. Menu 9  -> Set domain panel
  5. Menu 10 -> Generate config Wings dari Panel API
  6. Menu 30 -> Setup UFW (otomatis blokir 80/443 publik)
  7. Menu 51 -> (opsional) Pasang Cloudflare Origin Cert utk Full (Strict)
  8. Menu 16 -> Aktifkan backup otomatis terjadwal

${CYAN}Alur instalasi mode PUBLIC (dengan IP publik):${NC}
  1. Menu 47 -> Pilih mode 'public'
  2. Pastikan A-record domain mengarah ke IP server (bisa cek di menu 48)
  3. Menu 1  -> Full Install Panel + Wings
  4. Menu 48 -> Setup HTTPS Let's Encrypt (auto certbot + auto-renew)
  5. Menu 10 -> Generate config Wings dari Panel API
  6. Menu 30 -> Setup UFW (otomatis buka 80/443)
  7. Menu 49 -> Setup Fail2ban (proteksi brute-force SSH/HTTP)
  8. Menu 16 -> Aktifkan backup otomatis terjadwal

${CYAN}Tips harian:${NC}
  - Pakai menu 17 (Health Check) untuk cek service & konektivitas tunnel
  - Pakai menu 19 (Log real-time) untuk debug Wings/queue/nginx
  - Backup sebelum update: menu 11 -> menu 2 (update panel)
  - Restore selektif: hanya database / panel / wings / volume saja

${CYAN}Keamanan:${NC}
  - Jalankan menu 35 (Security Audit) berkala
  - File config tersimpan di $CONFIG_FILE (root only)
  - Lock file: $LOCK_FILE (mencegah backup paralel)

${CYAN}File penting:${NC}
  - Script         : $0
  - Panel          : $PANEL_DIR
  - Wings config   : $WINGS_DIR/config.yml
  - Backup         : $BACKUP_ROOT
  - Log manager    : $LOG_FILE

${CYAN}Mode quiet (untuk cron):${NC}
  bash ptero.sh --quiet --auto-backup
HELP
    pause
}

# ====================================================
# REPAIR & SETUP
# ====================================================

function fix_permissions() {
    require_root || return 1
    if [ ! -d "$PANEL_DIR" ]; then
        fail "Folder panel tidak ditemukan: $PANEL_DIR"
        pause
        return 1
    fi
    chown -R www-data:www-data "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
    systemctl restart pteroq nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true
    echo -e "${GREEN}Permission panel diperbaiki.${NC}"
    pause
}

function fix_nginx_config() {
    require_root || return 1
    provision_services
    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}Nginx diperbaiki/restart.${NC}"
    else
        fail "Nginx config invalid — tidak di-restart. Cek output 'nginx -t' di atas."
    fi
}

function fix_queue_worker() {
    require_root || return 1
    provision_services
    systemctl restart pteroq 2>/dev/null || true
    if [ -f "$PANEL_DIR/artisan" ]; then
        cd "$PANEL_DIR" || return 1
        php artisan queue:restart 2>/dev/null || true
    fi
    echo -e "${GREEN}Queue worker diperbaiki/restart.${NC}"
}

function fix_redis_service() {
    require_root || return 1
    systemctl enable --now redis-server
    systemctl restart redis-server
    echo -e "${GREEN}Redis diperbaiki/restart.${NC}"
}

function fix_wings_service() {
    require_root || return 1
    install_wings_binary || return 1
    provision_services || return 1
    systemctl restart wings 2>/dev/null || true
    echo -e "${GREEN}Wings diperbaiki/restart.${NC}"
}

function reset_node_network() {
    require_root || return 1
    if ! command -v docker >/dev/null 2>&1; then
        fail "Docker belum terinstall."; pause; return 1
    fi
    confirm_action "Reset Docker network 'pterodactyl_nw'? Semua container Wings akan di-restart." \
        || { echo "Dibatalkan."; pause; return 0; }

    systemctl stop wings 2>/dev/null || true

    # Lepas semua container yang masih nempel sebelum hapus, kalau tidak 'rm' akan gagal.
    local attached
    mapfile -t attached < <(docker network inspect pterodactyl_nw \
        -f '{{range $k,$v := .Containers}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null)
    for c in "${attached[@]}"; do
        [ -n "$c" ] && docker network disconnect -f pterodactyl_nw "$c" 2>/dev/null || true
    done

    # Recreate dengan opsi resmi Pterodactyl (bridge name, subnet, MTU, ICC).
    # Kalau pakai default 'docker network create' aja, Wings rusak: bridge name
    # bukan 'pterodactyl0', subnet bentrok, dsb. Selalu pasang opsi standar ini.
    docker network rm pterodactyl_nw 2>/dev/null || true
    if ! docker network create \
            --driver bridge \
            --subnet 172.18.0.0/16 \
            --gateway 172.18.0.1 \
            -o "com.docker.network.bridge.name=pterodactyl0" \
            -o "com.docker.network.driver.mtu=1500" \
            -o "com.docker.network.bridge.enable_icc=true" \
            -o "com.docker.network.bridge.enable_ip_masquerade=true" \
            -o "com.docker.network.bridge.host_binding_ipv4=0.0.0.0" \
            pterodactyl_nw 2>/dev/null; then
        fail "Gagal membuat ulang network pterodactyl_nw. Cek 'docker network ls'."
        systemctl start wings 2>/dev/null || true
        pause; return 1
    fi
    systemctl start wings 2>/dev/null || true
    log_msg "Docker network pterodactyl_nw direset"
    echo -e "${GREEN}Network node direset dengan opsi resmi Pterodactyl.${NC}"
    pause
}

function repair_menu() {
    require_root || return 1
    while true; do
        header
        echo "1) Fix Permission Panel"
        echo "2) Fix Nginx Config (Cloudflare-ready)"
        echo "3) Fix Queue Worker"
        echo "4) Fix Redis"
        echo "5) Fix Wings Service (reinstall + restart)"
        echo "6) Reset Docker Network Node"
        echo "7) Update Wings Saja"
        echo "8) Fix Trusted Proxy (TRUSTED_PROXIES)"
        echo "9) Revert Optimasi Server"
        echo "10) Restart Semua Service"
        echo "0) Kembali"
        read -r -p "Pilih [0-10]: " REPAIR_OPT
        case "$REPAIR_OPT" in
            1) fix_permissions ;;
            2) fix_nginx_config; pause ;;
            3) fix_queue_worker; pause ;;
            4) fix_redis_service; pause ;;
            5) fix_wings_service; pause ;;
            6) reset_node_network ;;
            7) update_wings_only ;;
            8)
                require_panel || continue
                set_env_value TRUSTED_PROXIES "*"
                cd "$PANEL_DIR" && php artisan config:clear >/dev/null 2>&1 || true
                echo -e "${GREEN}TRUSTED_PROXIES diset ke *.${NC}"; pause
                ;;
            9) optimize_revert ;;
            10) restart_all_services ;;
            0) return 0 ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function setup_rclone_storage() {
    require_root || return 1
    if ! command -v rclone >/dev/null 2>&1; then
        curl -fsSL https://rclone.org/install.sh | bash
    fi
    echo -e "${YELLOW}Pastikan remote sudah dibuat dengan: rclone config${NC}"
    read -r -p "Remote name: " RN
    read -r -p "Folder tujuan: " RF
    if [ -z "$RN" ] || [ -z "$RF" ]; then
        fail "Remote name dan folder wajib diisi."
        pause
        return 1
    fi
    echo "$RN:$RF" > /root/.ptero_rclone
    chmod 600 /root/.ptero_rclone
    echo -e "${GREEN}Rclone storage tersimpan.${NC}"
    pause
}

function create_swap() {
    require_root || return 1
    if swapon --show | grep -q '/swapfile'; then
        echo -e "${YELLOW}Swapfile sudah aktif.${NC}"
        pause
        return 0
    fi
    read -r -p "Size swap, contoh 2G: " SS
    if [ -z "$SS" ]; then
        fail "Size swap wajib diisi."
        pause
        return 1
    fi
    fallocate -l "$SS" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo -e "${GREEN}Swap aktif.${NC}"
    pause
}

function deep_uninstall() {
    require_root || return 1
    header
    echo -e "${RED}PERINGATAN: Ini akan menghapus panel, Wings, database, volume server, dan service terkait.${NC}"
    confirm_action "Uninstall total akan menghapus semua data Pterodactyl." \
        || { echo "Uninstall dibatalkan."; pause; return 1; }
    read -r -p "Ketik 'yakin' untuk hapus total: " CONFIRM
    if [ "$CONFIRM" = "yakin" ]; then
        systemctl stop wings pteroq cloudflared nginx mariadb redis-server 2>/dev/null || true
        systemctl disable wings pteroq cloudflared 2>/dev/null || true
        rm -rf "$PANEL_DIR" "$WINGS_DIR" /var/lib/pterodactyl \
            /usr/local/bin/wings \
            /etc/systemd/system/wings.service /etc/systemd/system/pteroq.service \
            /etc/cloudflared /root/.cloudflared \
            /usr/local/sbin/ptero-auto-backup.sh /etc/cron.d/ptero-manager-backup
        rm -f /etc/nginx/sites-enabled/pterodactyl.conf \
              /etc/nginx/sites-available/pterodactyl.conf
        ask_mysql_root_password
        mysql_root -e "
            DROP DATABASE IF EXISTS $DB_NAME;
            DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';
            FLUSH PRIVILEGES;
        " 2>/dev/null || true
        if command -v docker >/dev/null 2>&1; then
            mapfile -t containers < <(docker ps -aq 2>/dev/null)
            if [ "${#containers[@]}" -gt 0 ]; then
                docker stop "${containers[@]}" 2>/dev/null || true
                docker rm "${containers[@]}" 2>/dev/null || true
            fi
        fi
        systemctl daemon-reload
        if nginx -t >/dev/null 2>&1; then
            systemctl restart nginx 2>/dev/null || true
        fi
        log_msg "Deep uninstall selesai"
        echo -e "${GREEN}Pterodactyl berhasil dihapus.${NC}"
    else
        echo -e "${YELLOW}Uninstall dibatalkan.${NC}"
    fi
    pause
}

# ====================================================
# FITUR TAMBAHAN — 3 MENU PRIORITAS
# ====================================================

# --- BACKUP & RESTORE: Verify Backup Integrity ---
function verify_backup() {
    require_root || return 1
    header
    echo -e "${BLUE}Verify Backup Integrity${NC}"
    echo -e "${YELLOW}Cek apakah arsip backup masih utuh & bisa dibaca (deteksi korup sebelum kepepet restore).${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        fail "Folder backup belum ada: $BACKUP_ROOT"; pause; return 1
    fi
    mapfile -t BACKUPS < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        fail "Tidak ada backup tersedia."; pause; return 1
    fi

    echo "1) Verifikasi 1 backup (pilih)"
    echo "2) Verifikasi SEMUA backup (lebih lama)"
    echo "0) Batal"
    read -r -p "Pilih [0-2]: " VOPT
    local targets=()
    case "$VOPT" in
        1)
            local pick
            pick=$(pick_from_list "Pilih backup:" "${BACKUPS[@]}") || {
                fail "Pilihan tidak valid."; pause; return 1
            }
            targets=("$pick")
            ;;
        2) targets=("${BACKUPS[@]}") ;;
        *) echo "Dibatalkan."; pause; return 0 ;;
    esac

    local total=${#targets[@]} ok=0 bad=0 i=0
    for b in "${targets[@]}"; do
        i=$((i+1))
        echo
        echo -e "${CYAN}[$i/$total] $(basename "$b")${NC}"
        local b_ok=1

        # 1. tar.gz files: tar -tzf  (-tzf cek struktur + dekompresi gzip)
        local f
        for f in panel_files.tar.gz server_volumes.tar.gz; do
            if [ -f "$b/$f" ]; then
                if tar -tzf "$b/$f" >/dev/null 2>&1; then
                    echo -e "  ${GREEN}[OK]${NC}    $f ($(du -sh "$b/$f" 2>/dev/null | awk '{print $1}'))"
                else
                    echo -e "  ${RED}[KORUP]${NC} $f"
                    b_ok=0
                fi
            fi
        done

        # 2. SQL dump: cek bukan kosong + sintaks dasar
        if [ -f "$b/panel_db.sql" ]; then
            if [ ! -s "$b/panel_db.sql" ]; then
                echo -e "  ${RED}[KORUP]${NC} panel_db.sql kosong"
                b_ok=0
            elif ! head -c 4096 "$b/panel_db.sql" | grep -qiE 'mysql dump|mariadb dump|^-- |create table|insert into'; then
                echo -e "  ${YELLOW}[WARN]${NC} panel_db.sql tidak terlihat seperti SQL dump valid"
                b_ok=0
            else
                echo -e "  ${GREEN}[OK]${NC}    panel_db.sql ($(du -sh "$b/panel_db.sql" 2>/dev/null | awk '{print $1}'))"
            fi
        fi

        # 3. Wings config: cek YAML dasar
        if [ -d "$b/wings_config" ]; then
            if [ -f "$b/wings_config/config.yml" ] && grep -q '^token:' "$b/wings_config/config.yml" 2>/dev/null; then
                echo -e "  ${GREEN}[OK]${NC}    wings_config/config.yml"
            else
                echo -e "  ${YELLOW}[WARN]${NC} wings_config tanpa config.yml valid"
            fi
        fi

        # 4. Checksum SHA256 kalau ada
        if [ -f "$b/CHECKSUMS.sha256" ]; then
            if ( cd "$b" && sha256sum -c CHECKSUMS.sha256 >/dev/null 2>&1 ); then
                echo -e "  ${GREEN}[OK]${NC}    SHA256 checksum cocok"
            else
                echo -e "  ${RED}[GAGAL]${NC} SHA256 checksum tidak cocok!"
                b_ok=0
            fi
        else
            echo -e "  ${YELLOW}[INFO]${NC} Tidak ada CHECKSUMS.sha256"
        fi

        if [ "$b_ok" -eq 1 ]; then
            ok=$((ok+1))
            echo -e "  ${GREEN}=> SEHAT${NC}"
        else
            bad=$((bad+1))
            echo -e "  ${RED}=> BERMASALAH${NC}"
        fi
    done

    echo
    echo -e "${BLUE}Ringkasan: ${GREEN}$ok sehat${NC}, ${RED}$bad bermasalah${NC} (dari $total).${NC}"
    log_msg "Verify backup: $ok OK / $bad bad / $total total"
    if [ "$bad" -gt 0 ]; then
        notify_detail "BACKUP CORRUPT" "$bad backup terdeteksi korup. Cek menu Verify Backup."
    fi
    pause
}

# --- MANAJEMEN: List Admin Users ---
function list_admin_users() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${BLUE}Daftar User Panel (admin & root admin)${NC}"
    echo
    read -r -s -p "Password database $DB_USER: " DBP
    echo
    if [ -z "$DBP" ]; then
        fail "Password kosong."; pause; return 1
    fi

    # Query langsung ke DB (lebih cepat & tidak butuh artisan tinker)
    local sql='
        SELECT
            id,
            username,
            email,
            CASE WHEN root_admin=1 THEN "YES" ELSE "no" END AS root,
            CASE WHEN use_totp=1 THEN "YES" ELSE "no" END AS twofa,
            COALESCE(DATE_FORMAT(updated_at, "%Y-%m-%d %H:%i"), "-") AS last_update,
            COALESCE(DATE_FORMAT(created_at, "%Y-%m-%d"), "-") AS created
        FROM users
        ORDER BY root_admin DESC, id ASC;
    '
    local out
    if ! out=$(mysql_secure "$DB_USER" "$DBP" -h 127.0.0.1 -D "$DB_NAME" \
                            --batch --table -e "$sql" 2>&1); then
        fail "Query gagal. Cek password DB / nama DB."
        echo "$out" | head -3 | sed 's/^/  /'
        pause; return 1
    fi
    echo "$out"
    echo
    local total admins twofa_on
    total=$(echo "$out" | grep -cE '^\| +[0-9]+ +\|')
    admins=$(echo "$out" | awk -F'|' 'NR>3 && $5 ~ /YES/ {c++} END{print c+0}')
    twofa_on=$(echo "$out" | awk -F'|' 'NR>3 && $6 ~ /YES/ {c++} END{print c+0}')
    echo -e "${CYAN}Total user : ${total}${NC}"
    echo -e "${CYAN}Root admin : ${admins}${NC}"
    echo -e "${CYAN}Pakai 2FA  : ${twofa_on}${NC}"
    if [ "$admins" -gt 0 ] && [ "$twofa_on" -lt "$admins" ]; then
        echo -e "${YELLOW}PERINGATAN: ada admin tanpa 2FA aktif.${NC}"
    fi
    log_msg "List admin users dijalankan ($total user, $admins admin)"
    pause
}

# --- SERVER & REPAIR: Live Container Resource Stats ---
function container_resource_stats() {
    require_root || return 1
    header
    echo -e "${BLUE}Resource Pakai per Container Pterodactyl${NC}"
    echo
    if ! command -v docker >/dev/null 2>&1; then
        fail "Docker belum terpasang."; pause; return 1
    fi
    # Container Pterodactyl pakai nama UUID v4
    local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    mapfile -t containers < <(docker ps --format '{{.Names}}' 2>/dev/null \
                              | awk -v re="$uuid_re" '$0 ~ re')
    if [ "${#containers[@]}" -eq 0 ]; then
        echo -e "${YELLOW}Tidak ada container Pterodactyl yang sedang berjalan.${NC}"
        pause; return 0
    fi

    echo -e "${CYAN}== docker stats (snapshot) ==${NC}"
    docker stats --no-stream \
        --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' \
        "${containers[@]}" 2>/dev/null

    echo
    echo -e "${CYAN}== Disk per server volume ==${NC}"
    local vol_root="/var/lib/pterodactyl/volumes"
    if [ -d "$vol_root" ]; then
        printf "  %-40s %10s\n" "UUID" "SIZE"
        local c size
        for c in "${containers[@]}"; do
            if [ -d "$vol_root/$c" ]; then
                size=$(du -sh "$vol_root/$c" 2>/dev/null | awk '{print $1}')
                printf "  %-40s %10s\n" "$c" "${size:-?}"
            fi
        done
    else
        echo -e "  ${YELLOW}Folder volume tidak ditemukan: $vol_root${NC}"
    fi

    echo
    echo -e "${CYAN}== Top 5 CPU ==${NC}"
    docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' "${containers[@]}" 2>/dev/null \
        | sort -k2 -hr | head -5 | sed 's/^/  /'

    echo
    echo -e "${CYAN}== Top 5 Memori ==${NC}"
    docker stats --no-stream --format '{{.Name}} {{.MemPerc}}' "${containers[@]}" 2>/dev/null \
        | sort -k2 -hr | head -5 | sed 's/^/  /'

    log_msg "Container resource stats dijalankan (${#containers[@]} container)"
    pause
}

# --- MANAJEMEN: Clear Panel Cache ---
function clear_panel_cache() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${BLUE}Clear Panel Cache${NC}"
    echo -e "${YELLOW}Bersihkan cache Laravel, view, config, route, OPcache, lalu re-cache untuk produksi.${NC}"
    echo
    cd "$PANEL_DIR" || { fail "Folder panel tidak ditemukan."; pause; return 1; }

    local steps_ok=0 steps_fail=0
    _do() {
        local label="$1"; shift
        if "$@" >/dev/null 2>&1; then
            echo -e "  ${GREEN}[OK]${NC}    $label"
            steps_ok=$((steps_ok+1))
        else
            echo -e "  ${YELLOW}[SKIP]${NC}  $label"
            steps_fail=$((steps_fail+1))
        fi
    }

    _do "view:clear"   php artisan view:clear
    _do "cache:clear"  php artisan cache:clear
    _do "config:clear" php artisan config:clear
    _do "route:clear"  php artisan route:clear
    _do "event:clear"  php artisan event:clear
    _do "queue:restart" php artisan queue:restart

    # Hapus file kompilasi manual sebagai fallback
    rm -f "$PANEL_DIR"/bootstrap/cache/{config,routes,packages,services,events}.php 2>/dev/null || true
    echo -e "  ${GREEN}[OK]${NC}    bootstrap/cache/*.php dibersihkan manual"

    # Re-cache untuk produksi
    _do "config:cache" php artisan config:cache
    _do "route:cache"  php artisan route:cache

    # Reset OPcache via PHP-FPM kalau modul ada
    if php -m 2>/dev/null | grep -qi opcache; then
        if php -r 'function_exists("opcache_reset") && opcache_reset();' 2>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC}    OPcache di-reset (CLI)"
        fi
        # Reload php-fpm juga supaya OPcache worker FPM ter-reset
        if systemctl reload "php${PHP_VERSION}-fpm" 2>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC}    php${PHP_VERSION}-fpm di-reload (OPcache worker reset)"
        fi
    fi

    chown -R www-data:www-data "$PANEL_DIR/bootstrap/cache" "$PANEL_DIR/storage" 2>/dev/null || true

    echo
    echo -e "${BLUE}Selesai: ${GREEN}${steps_ok} OK${NC}, ${YELLOW}${steps_fail} dilewati${NC}.${NC}"
    log_msg "Clear panel cache ($steps_ok OK / $steps_fail skip)"
    pause
}

# --- SERVER & REPAIR: Auto-Fix Panel (one-click panel doctor) ---
function auto_fix_panel() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${BLUE}Auto-Fix Panel (panel doctor)${NC}"
    echo -e "${YELLOW}Perbaiki ownership, permission, cache, restart service, lalu uji koneksi.${NC}"
    echo
    local fixed=0

    # 1. Ownership & permission
    echo -e "${CYAN}== 1. Ownership & permission ==${NC}"
    if chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} chown www-data $PANEL_DIR"
        fixed=$((fixed+1))
    fi
    if chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} chmod 755 storage & bootstrap/cache"
        fixed=$((fixed+1))
    fi
    if [ -f "$PANEL_DIR/.env" ]; then
        chmod 640 "$PANEL_DIR/.env" 2>/dev/null && \
            echo -e "  ${GREEN}[OK]${NC} chmod 640 .env" && fixed=$((fixed+1))
        chown root:www-data "$PANEL_DIR/.env" 2>/dev/null && \
            echo -e "  ${GREEN}[OK]${NC} chown root:www-data .env" && fixed=$((fixed+1))
    fi

    # 2. Bersihkan cache (panggil clear_panel_cache versi singkat)
    echo
    echo -e "${CYAN}== 2. Clear cache ==${NC}"
    cd "$PANEL_DIR" || { fail "Folder panel hilang."; pause; return 1; }
    local cmd
    for cmd in "view:clear" "cache:clear" "config:clear" "route:clear"; do
        if php artisan "$cmd" >/dev/null 2>&1; then
            echo -e "  ${GREEN}[OK]${NC} php artisan $cmd"
            fixed=$((fixed+1))
        fi
    done
    rm -f "$PANEL_DIR"/bootstrap/cache/{config,routes,packages,services,events}.php 2>/dev/null || true
    php artisan queue:restart >/dev/null 2>&1 || true

    # 3. Validasi nginx
    echo
    echo -e "${CYAN}== 3. Validasi konfigurasi Nginx ==${NC}"
    if nginx -t >/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} nginx -t valid"
    else
        echo -e "  ${RED}[FAIL]${NC} nginx -t invalid:"
        nginx -t 2>&1 | sed 's/^/    /'
    fi

    # 4. Restart service
    echo
    echo -e "${CYAN}== 4. Restart service ==${NC}"
    local svc
    for svc in redis-server "php${PHP_VERSION}-fpm" nginx pteroq; do
        if systemctl restart "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC} restart $svc"
            fixed=$((fixed+1))
        else
            echo -e "  ${YELLOW}[SKIP]${NC} $svc (tidak ada / gagal)"
        fi
    done

    # 5. Uji HTTP panel
    echo
    echo -e "${CYAN}== 5. Uji koneksi panel ==${NC}"
    local app_url code
    app_url=$(grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    if [ -n "$app_url" ]; then
        code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "$app_url" 2>/dev/null || echo "000")
        if echo "$code" | grep -Eq '^(200|301|302)$'; then
            echo -e "  ${GREEN}[OK]${NC} $app_url -> HTTP $code"
        else
            echo -e "  ${RED}[FAIL]${NC} $app_url -> HTTP $code"
            echo -e "  ${YELLOW}Cek tunnel/DNS atau lihat log: journalctl -u nginx -n 30${NC}"
        fi
    else
        echo -e "  ${YELLOW}[SKIP]${NC} APP_URL belum diset di .env"
    fi

    # 6. Status service singkat
    echo
    echo -e "${CYAN}== 6. Status service ==${NC}"
    for svc in nginx "php${PHP_VERSION}-fpm" mariadb redis-server pteroq wings; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC}    $svc"
        else
            echo -e "  ${YELLOW}[STOP]${NC}  $svc"
        fi
    done

    echo
    echo -e "${GREEN}Auto-fix selesai. Total $fixed langkah perbaikan dijalankan.${NC}"
    log_msg "Auto-fix panel dijalankan ($fixed langkah)"
    notify_detail "PANEL FIX" "Auto-fix panel dijalankan ($fixed langkah)."
    pause
}

# --- BACKUP & RESTORE: Cleanup Orphan / Partial Backups ---
function cleanup_orphan_backups() {
    require_root || return 1
    header
    echo -e "${BLUE}Cleanup Orphan / Partial Backups${NC}"
    echo -e "${YELLOW}Cari folder backup yang gagal di tengah jalan (tidak lengkap atau terlalu kecil).${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."; pause; return 0
    fi

    mapfile -t BACKUPS < <(ls -1d "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        echo "Tidak ada backup tersedia."; pause; return 0
    fi

    local orphans=() reasons=()
    local b size_kb has_db has_files
    for b in "${BACKUPS[@]}"; do
        [ -d "$b" ] || continue
        size_kb=$(du -sk "$b" 2>/dev/null | awk '{print $1}')
        size_kb=${size_kb:-0}
        has_db=0; has_files=0
        [ -s "$b/panel_db.sql" ]         && has_db=1
        [ -s "$b/panel_files.tar.gz" ]   && has_files=1

        if [ "$has_db" -eq 0 ] && [ "$has_files" -eq 0 ]; then
            orphans+=("$b")
            reasons+=("kosong: tidak ada panel_db.sql & panel_files.tar.gz")
        elif [ "$size_kb" -lt 1024 ]; then
            orphans+=("$b")
            reasons+=("terlalu kecil (${size_kb} KB) — kemungkinan backup gagal di tengah")
        fi
    done

    if [ "${#orphans[@]}" -eq 0 ]; then
        echo -e "${GREEN}Tidak ada backup orphan/partial. Semua backup terlihat lengkap.${NC}"
        pause; return 0
    fi

    echo -e "${YELLOW}Ditemukan ${#orphans[@]} backup mencurigakan:${NC}"
    echo
    local i
    for i in "${!orphans[@]}"; do
        printf "  %2d) %s\n      ${RED}%s${NC}\n" \
            "$((i+1))" "$(basename "${orphans[$i]}")" "${reasons[$i]}"
    done
    echo
    local total_kb=0
    for b in "${orphans[@]}"; do
        size_kb=$(du -sk "$b" 2>/dev/null | awk '{print $1}')
        total_kb=$((total_kb + ${size_kb:-0}))
    done
    local total_mb=$((total_kb / 1024))
    echo -e "${CYAN}Total disk yang akan dibebaskan: ~${total_mb} MB${NC}"
    echo

    if ! confirm_action "Hapus semua ${#orphans[@]} folder backup mencurigakan di atas?"; then
        echo "Dibatalkan."; pause; return 0
    fi

    local removed=0
    for b in "${orphans[@]}"; do
        if rm -rf -- "$b" 2>/dev/null; then
            removed=$((removed+1))
            echo -e "  ${GREEN}[hapus]${NC} $(basename "$b")"
        else
            echo -e "  ${RED}[gagal]${NC} $(basename "$b")"
        fi
    done
    log_msg "Cleanup orphan backup: $removed/${#orphans[@]} dihapus (~${total_mb} MB)"
    echo
    echo -e "${GREEN}$removed folder dihapus, ~${total_mb} MB dibebaskan.${NC}"
    pause
}

# --- MANAJEMEN: Drop & Reset Database (DESTRUCTIVE) ---
function drop_reset_database() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${RED}===== DROP & RESET DATABASE PANEL =====${NC}"
    echo -e "${YELLOW}Operasi ini akan MENGHAPUS database panel '$DB_NAME' dan membuatnya ulang KOSONG.${NC}"
    echo -e "${YELLOW}Semua user, server, node, lokasi, schedule, dll. akan HILANG.${NC}"
    echo -e "${YELLOW}Tapi server runtime di Wings (volumes) tidak ikut terhapus.${NC}"
    echo
    echo -e "${CYAN}Database target : ${RED}$DB_NAME${NC}"
    echo -e "${CYAN}DB user         : $DB_USER${NC}"
    echo

    # Konfirmasi 2-langkah: ketik nama DB persis
    read -r -p "Untuk konfirmasi, ketik nama database persis ('$DB_NAME'): " TYPED
    if [ "$TYPED" != "$DB_NAME" ]; then
        fail "Nama database tidak cocok. Dibatalkan."; pause; return 1
    fi
    confirm_action "BENERAN drop database '$DB_NAME' & reset semua data panel?" \
        || { echo "Dibatalkan."; pause; return 0; }

    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT

    # 1. Auto-backup DB dulu (wajib, biar bisa rollback)
    echo
    echo -e "${BLUE}[*] Backup DB dulu sebelum drop (safety net)...${NC}"
    read -r -s -p "Password database $DB_USER (untuk backup): " DBP
    echo
    if [ -z "$DBP" ]; then
        fail "Password kosong. Drop dibatalkan."
        release_lock; trap - EXIT; return 1
    fi
    mkdir -p "$BACKUP_ROOT"
    local safety_dir="$BACKUP_ROOT/ptero_PRE_DROP_$(date +%F_%H-%M-%S)"
    mkdir -p "$safety_dir"
    if ! mysqldump_secure "$DB_USER" "$DBP" -h 127.0.0.1 \
            --single-transaction --routines --triggers \
            "$DB_NAME" > "$safety_dir/panel_db.sql" 2>/dev/null; then
        rm -rf "$safety_dir"
        fail "Backup pra-drop GAGAL (password salah?). Drop dibatalkan demi keamanan."
        release_lock; trap - EXIT; return 1
    fi
    if [ ! -s "$safety_dir/panel_db.sql" ]; then
        rm -rf "$safety_dir"
        fail "Backup pra-drop kosong. Drop dibatalkan demi keamanan."
        release_lock; trap - EXIT; return 1
    fi
    ( cd "$safety_dir" && sha256sum panel_db.sql > CHECKSUMS.sha256 ) 2>/dev/null || true
    echo -e "  ${GREEN}[OK]${NC} Backup pra-drop: $safety_dir"

    # 2. Maintenance mode
    echo
    cd "$PANEL_DIR" 2>/dev/null && \
        php artisan down --message="Database sedang di-reset." >/dev/null 2>&1 || true

    # 3. Drop & recreate
    echo -e "${BLUE}[*] Drop & recreate database...${NC}"
    ask_mysql_root_password
    if ! mysql_root -e "
        DROP DATABASE IF EXISTS \`$DB_NAME\`;
        CREATE DATABASE \`$DB_NAME\`
            CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
        FLUSH PRIVILEGES;
    "; then
        fail "DROP/CREATE database gagal. Coba restore dari: $safety_dir/panel_db.sql"
        ( cd "$PANEL_DIR" && php artisan up >/dev/null 2>&1 ) || true
        release_lock; trap - EXIT; return 1
    fi
    echo -e "  ${GREEN}[OK]${NC} Database '$DB_NAME' di-recreate kosong."

    # 4. Migrate fresh
    echo
    echo -e "${BLUE}[*] Migrate fresh + seed...${NC}"
    cd "$PANEL_DIR" || { fail "Folder panel hilang."; release_lock; trap - EXIT; return 1; }
    if ! php artisan migrate --seed --force; then
        fail "Migrasi gagal. DB sudah kosong. Restore dari: $safety_dir/panel_db.sql"
        php artisan up >/dev/null 2>&1 || true
        release_lock; trap - EXIT; return 1
    fi

    # 5. Bersihkan cache & up
    php artisan config:clear >/dev/null 2>&1 || true
    php artisan cache:clear  >/dev/null 2>&1 || true
    php artisan queue:restart >/dev/null 2>&1 || true
    php artisan up >/dev/null 2>&1 || true

    echo
    echo -e "${GREEN}Database panel berhasil di-reset.${NC}"
    echo -e "${YELLOW}Backup pra-drop tersimpan di: $safety_dir${NC}"
    echo -e "${YELLOW}Buat ulang akun admin via menu 22 (Buat User/Admin Panel).${NC}"
    log_msg "Database $DB_NAME di-drop & reset (backup: $safety_dir)"
    notify_detail "DB RESET" "Database panel direset. Backup: $safety_dir"
    release_lock
    trap - EXIT
    pause
}

# --- SERVER & REPAIR: Flush Redis Cache ---
function flush_redis_cache() {
    require_root || return 1
    if ! command -v redis-cli >/dev/null 2>&1; then
        fail "redis-cli tidak ditemukan."; pause; return 1
    fi
    if ! redis-cli ping 2>/dev/null | grep -q PONG; then
        fail "Redis tidak merespon (service mati / port lain?)."; pause; return 1
    fi

    header
    echo -e "${BLUE}Flush Redis Cache${NC}"
    echo -e "${YELLOW}Bersihkan session, queue, dan cache panel di Redis.${NC}"
    echo -e "${YELLOW}Efek: semua user akan ke-logout, queue job pending HILANG.${NC}"
    echo
    echo -e "${CYAN}Info Redis:${NC}"
    local used keys_total
    used=$(redis-cli info memory 2>/dev/null | awk -F: '/^used_memory_human/ {gsub(/\r/,"",$2); print $2}')
    keys_total=$(redis-cli info keyspace 2>/dev/null | awk -F'[=,]' '/^db/ {sum+=$2} END{print sum+0}')
    echo -e "  Memori : ${used:-?}"
    echo -e "  Keys   : ${keys_total:-0}"
    redis-cli info keyspace 2>/dev/null | grep '^db' | sed 's/^/  /'
    echo

    echo "1) Flush DB 0 saja (paling aman, biasanya cukup)"
    echo "2) FLUSHALL — hapus SEMUA database Redis (lebih agresif)"
    echo "0) Batal"
    read -r -p "Pilih [0-2]: " FOPT
    case "$FOPT" in
        1)
            confirm_action "Flush Redis DB 0 sekarang?" \
                || { echo "Dibatalkan."; pause; return 0; }
            if redis-cli -n 0 FLUSHDB >/dev/null 2>&1; then
                echo -e "${GREEN}[OK] Redis DB 0 di-flush.${NC}"
                log_msg "Redis FLUSHDB 0 dijalankan"
            else
                fail "FLUSHDB gagal."
            fi
            ;;
        2)
            confirm_action "FLUSHALL — hapus SEMUA database Redis sekarang?" \
                || { echo "Dibatalkan."; pause; return 0; }
            if redis-cli FLUSHALL >/dev/null 2>&1; then
                echo -e "${GREEN}[OK] Semua Redis DB di-flush.${NC}"
                log_msg "Redis FLUSHALL dijalankan"
            else
                fail "FLUSHALL gagal."
            fi
            ;;
        *) echo "Dibatalkan."; pause; return 0 ;;
    esac

    # Restart queue worker supaya state bersih
    if [ -f "$PANEL_DIR/artisan" ]; then
        ( cd "$PANEL_DIR" && php artisan queue:restart >/dev/null 2>&1 ) || true
    fi
    systemctl restart pteroq 2>/dev/null || true
    echo -e "${YELLOW}Queue worker (pteroq) di-restart. User perlu login ulang.${NC}"
    pause
}

# --- BACKUP & RESTORE: Prune Old Backups Now ---
function prune_old_backups_now() {
    require_root || return 1
    header
    echo -e "${BLUE}Prune Old Backups (manual)${NC}"
    echo -e "${YELLOW}Aplikasikan retention sekarang juga, tidak nunggu cron.${NC}"
    echo -e "${CYAN}Retention: $BACKUP_RETENTION_DAYS hari, max $BACKUP_MAX_COUNT backup.${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."; pause; return 0
    fi

    # Hitung kandidat hapus berdasarkan umur
    mapfile -t old_by_age < <(find "$BACKUP_ROOT" -maxdepth 1 -type d \
        -name 'ptero_*' -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null)

    # Hitung kandidat hapus berdasarkan jumlah max
    mapfile -t all_sorted < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    local old_by_count=()
    if [ "${#all_sorted[@]}" -gt "$BACKUP_MAX_COUNT" ]; then
        local idx
        for idx in "${!all_sorted[@]}"; do
            if [ "$idx" -ge "$BACKUP_MAX_COUNT" ]; then
                old_by_count+=("${all_sorted[$idx]}")
            fi
        done
    fi

    # Gabung & dedupe
    declare -A seen=()
    local victims=() v
    for v in "${old_by_age[@]}" "${old_by_count[@]}"; do
        [ -z "$v" ] && continue
        if [ -z "${seen[$v]:-}" ]; then
            seen[$v]=1
            victims+=("$v")
        fi
    done

    if [ "${#victims[@]}" -eq 0 ]; then
        echo -e "${GREEN}Tidak ada backup yang melanggar retention. Tidak ada yang dihapus.${NC}"
        echo -e "  Total backup saat ini: ${#all_sorted[@]} (limit: $BACKUP_MAX_COUNT)"
        pause; return 0
    fi

    echo -e "${YELLOW}Backup yang akan DIHAPUS (${#victims[@]} folder):${NC}"
    local total_kb=0 size_kb age
    for v in "${victims[@]}"; do
        size_kb=$(du -sk "$v" 2>/dev/null | awk '{print $1}')
        size_kb=${size_kb:-0}
        total_kb=$((total_kb + size_kb))
        age=$(stat -c %y "$v" 2>/dev/null | cut -d. -f1)
        printf "  - %-40s  %6s MB  (%s)\n" "$(basename "$v")" \
            "$((size_kb/1024))" "${age:-?}"
    done
    local total_mb=$((total_kb / 1024))
    echo
    echo -e "${CYAN}Total disk yang akan dibebaskan: ~${total_mb} MB${NC}"
    echo

    if ! confirm_action "Hapus ${#victims[@]} backup di atas sekarang?"; then
        echo "Dibatalkan."; pause; return 0
    fi

    local removed=0
    for v in "${victims[@]}"; do
        if rm -rf -- "$v" 2>/dev/null; then
            removed=$((removed+1))
            echo -e "  ${GREEN}[hapus]${NC} $(basename "$v")"
        else
            echo -e "  ${RED}[gagal]${NC} $(basename "$v")"
        fi
    done
    echo
    echo -e "${GREEN}$removed/${#victims[@]} backup dihapus, ~${total_mb} MB dibebaskan.${NC}"
    log_msg "Prune backup manual: $removed dihapus (~${total_mb} MB)"
    pause
}

# ====================================================
# ENTRYPOINT
# ====================================================

function self_check() {
    bash -n "$0" || return 1
    local missing=0 fn
    for fn in install_all install_panel_only install_wings_only_full \
              update_panel update_wings_only provision_services write_nginx_config \
              deep_maintenance check_script_update setup_cloudflare_tunnel \
              setup_cloudflare_named_tunnel set_panel_domain generate_wings_config_api \
              backup_system backup_db_only restore_system list_backups delete_backup \
              schedule_auto_backup health_check info_system view_logs_menu \
              check_wings_connection discord_setup create_admin_user \
              reset_admin_password change_db_password panel_maintenance_mode \
              export_config panel_user_manager bulk_server_action repair_menu \
              setup_firewall setup_rclone_storage create_swap optimize_server \
              restart_all_services security_audit db_optimize wings_watchdog_setup \
              wings_watchdog_remove telegram_setup set_custom_banner backup_stats \
              script_rollback help_screen deep_uninstall \
              select_deploy_mode setup_letsencrypt setup_fail2ban fail2ban_status \
              ensure_self_signed_cert install_cf_origin_cert \
              _mk_mysql_cnf mysql_secure mysqldump_secure mysqlcheck_secure \
              validate_db_password safe_reload_nginx \
              acquire_lock release_lock sha256_of qprint preview_backup \
              load_config save_config notify_detail \
              verify_backup list_admin_users container_resource_stats \
              clear_panel_cache auto_fix_panel cleanup_orphan_backups \
              drop_reset_database flush_redis_cache prune_old_backups_now; do
        if ! declare -F "$fn" >/dev/null; then
            echo "MISSING: $fn"; missing=$((missing+1))
        fi
    done
    if [ "$missing" -gt 0 ]; then
        echo "Self-check GAGAL: $missing fungsi hilang."
        return 1
    fi
    echo "Sintaks OK. Semua fitur V$SCRIPT_VERSION tersedia."
    echo "Catatan: Jalankan di Ubuntu/Debian sebagai root."
}

if [ "${1:-}" = "--self-check" ]; then
    self_check
    exit $?
fi

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET_MODE=1 ;;
    esac
done

if [[ " $* " == *" --auto-backup "* ]]; then
    require_root || exit 1
    # Sumber password: --cnf <path> (default $AUTO_BACKUP_CNF) atau env PTERO_DB_PASS (legacy)
    AUTO_PASS=""
    AUTO_CNF=""
    prev=""
    for arg in "$@"; do
        if [ "$prev" = "--cnf" ]; then
            AUTO_CNF="$arg"
        fi
        prev="$arg"
    done
    [ -z "$AUTO_CNF" ] && [ -f "$AUTO_BACKUP_CNF" ] && AUTO_CNF="$AUTO_BACKUP_CNF"
    if [ -n "$AUTO_CNF" ] && [ -f "$AUTO_CNF" ]; then
        AUTO_PASS=$(awk -F= '
            /^[[:space:]]*password[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, "", $0); print; exit
            }' "$AUTO_CNF")
    fi
    [ -z "$AUTO_PASS" ] && AUTO_PASS="${PTERO_DB_PASS:-}"
    if [ -z "$AUTO_PASS" ]; then
        fail "Kredensial DB tidak ditemukan untuk auto-backup (cnf: ${AUTO_CNF:-none})."
        exit 1
    fi
    backup_system_with_password "$AUTO_PASS" "no"
    rc=$?
    AUTO_PASS=""
    exit $rc
fi

while true; do
    header
    echo -e "${CYAN}--- INSTALL & UPDATE ---${NC}"
    echo "1)  Full Install Panel + Wings"
    echo "2)  Update Panel"
    echo "3)  Update Wings Saja"
    echo "4)  Provision Web & Services"
    echo "5)  Deep Maintenance"
    echo "6)  Cek Update Script (self-update)"
    echo
    echo -e "${CYAN}--- CLOUDFLARE TUNNEL ---${NC}"
    echo "7)  Setup Cloudflare Connector Token"
    echo "8)  Setup Cloudflare Named Tunnel"
    echo "9)  Set Domain Panel Cloudflare"
    echo "10) Generate Wings config.yml dari Panel API"
    echo
    echo -e "${CYAN}--- BACKUP & RESTORE ---${NC}"
    echo "11) Backup System Lengkap (Local + Cloud)"
    echo "12) Backup Database Saja"
    echo "13) Restore dari Backup (pilih nomor)"
    echo "14) List Backup"
    echo "15) Hapus Backup (pilih nomor)"
    echo "16) Backup Otomatis Terjadwal"
    echo
    echo -e "${CYAN}--- MONITORING ---${NC}"
    echo "17) Health Check Service"
    echo "18) Informasi Sistem Lengkap"
    echo "19) Lihat Log Real-time"
    echo "20) Cek Koneksi Wings ke Panel"
    echo "21) Setup/Test Discord Webhook"
    echo
    echo -e "${CYAN}--- MANAJEMEN ---${NC}"
    echo "22) Buat User/Admin Panel"
    echo "23) Reset Password Admin"
    echo "24) Ganti Password Database"
    echo "25) Maintenance Mode Panel"
    echo "26) Export Konfigurasi"
    echo "27) Manajemen User Panel (list/edit/hapus)"
    echo "28) Bulk Action Server (suspend/restart all)"
    echo
    echo -e "${CYAN}--- SERVER & REPAIR ---${NC}"
    echo "29) Repair Menu Lengkap"
    echo "30) Setup UFW Firewall"
    echo "31) Setup Rclone Cloud Storage"
    echo "32) Create Swap File"
    echo "33) Optimasi Server Kecil"
    echo "34) Restart Semua Service"
    echo "35) Security Audit"
    echo "36) Optimasi Database (OPTIMIZE TABLE)"
    echo "37) Setup Wings Watchdog (auto-restart)"
    echo "38) Hapus Wings Watchdog"
    echo
    echo -e "${CYAN}--- LANJUTAN V5.4 ---${NC}"
    echo "39) Setup Telegram Notifikasi"
    echo "40) Set Custom Banner"
    echo "41) Statistik Backup"
    echo "42) Rollback Script (.bak)"
    echo "43) Bantuan / Help"
    echo
    echo -e "${CYAN}--- INSTALL TERPISAH ---${NC}"
    echo "45) Install Panel Saja (tanpa Wings)"
    echo "46) Install Wings Saja (node terpisah)"
    echo
    echo -e "${CYAN}--- MODE DEPLOY (tunnel / public IP) ---${NC}"
    echo "47) Pilih Mode Deploy (saat ini: ${DEPLOY_MODE:-tunnel})"
    echo "48) Setup HTTPS Let's Encrypt (mode public)"
    echo "49) Setup Fail2ban (proteksi brute-force)"
    echo "50) Status Fail2ban"
    echo "51) Pasang Cloudflare Origin Cert (mode tunnel, Full Strict)"
    echo
    echo -e "${CYAN}--- FITUR TAMBAHAN ---${NC}"
    echo "52) Verify Backup Integrity (cek backup tidak korup)"
    echo "53) List Admin Users (audit akses panel)"
    echo "54) Live Container Stats (CPU/RAM/Disk per server)"
    echo "55) Clear Panel Cache (fix error setelah update/edit .env)"
    echo "56) Auto-Fix Panel (panel doctor: perm + cache + restart + test)"
    echo "57) Cleanup Orphan Backups (hapus backup gagal/partial)"
    echo "59) Flush Redis Cache (fix session/queue stuck)"
    echo "60) Prune Old Backups Now (aplikasikan retention manual)"
    echo
    echo -e "${RED}58) Drop & Reset Database Panel (DESTRUCTIVE)${NC}"
    echo -e "${RED}44) Deep Uninstall (Hapus Bersih)${NC}"
    echo "0)  Keluar"
    echo
    read -r -p "Pilih [0-60]: " OPT
    case "$OPT" in
        1)  install_all ;;
        2)  update_panel ;;
        3)  update_wings_only ;;
        4)  if provision_services; then
                if nginx -t >/dev/null 2>&1; then
                    systemctl restart nginx wings pteroq 2>/dev/null || true
                else
                    fail "Nginx config invalid. Skip restart nginx."
                    systemctl restart wings pteroq 2>/dev/null || true
                fi
            fi
            pause ;;
        5)  deep_maintenance ;;
        6)  check_script_update ;;
        7)  setup_cloudflare_tunnel ;;
        8)  setup_cloudflare_named_tunnel ;;
        9)  set_panel_domain ;;
        10) generate_wings_config_api ;;
        11) backup_system ;;
        12) backup_db_only ;;
        13) restore_system ;;
        14) list_backups ;;
        15) delete_backup ;;
        16) schedule_auto_backup ;;
        17) health_check ;;
        18) info_system ;;
        19) view_logs_menu ;;
        20) check_wings_connection ;;
        21) discord_setup ;;
        22) create_admin_user ;;
        23) reset_admin_password ;;
        24) change_db_password ;;
        25) panel_maintenance_mode ;;
        26) export_config ;;
        27) panel_user_manager ;;
        28) bulk_server_action ;;
        29) repair_menu ;;
        30) setup_firewall ;;
        31) setup_rclone_storage ;;
        32) create_swap ;;
        33) optimize_server ;;
        34) restart_all_services ;;
        35) security_audit ;;
        36) db_optimize ;;
        37) wings_watchdog_setup ;;
        38) wings_watchdog_remove ;;
        39) telegram_setup ;;
        40) set_custom_banner ;;
        41) backup_stats ;;
        42) script_rollback ;;
        43) help_screen ;;
        44) deep_uninstall ;;
        45) install_panel_only ;;
        46) install_wings_only_full ;;
        47) select_deploy_mode ;;
        48) setup_letsencrypt ;;
        49) setup_fail2ban ;;
        50) fail2ban_status ;;
        51) install_cf_origin_cert ;;
        52) verify_backup ;;
        53) list_admin_users ;;
        54) container_resource_stats ;;
        55) clear_panel_cache ;;
        56) auto_fix_panel ;;
        57) cleanup_orphan_backups ;;
        58) drop_reset_database ;;
        59) flush_redis_cache ;;
        60) prune_old_backups_now ;;
        0)  exit 0 ;;
        *)  echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
    esac
done
