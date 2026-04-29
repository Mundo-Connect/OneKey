#!/bin/bash

APP_NAME="Mundo Proxy"
APP_DIR="/etc/mundoproxy"
BIN_DIR="$APP_DIR/bin"
SH_DIR="$APP_DIR/sh"
CONFIG_FILE="$APP_DIR/config.json"
CERT_DIR="$APP_DIR/cert"
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"
LOG_DIR="/var/log/mundoproxy"
ACCESS_LOG="$LOG_DIR/access.log"
ERROR_LOG="$LOG_DIR/error.log"
SERVICE_FILE="/etc/systemd/system/mundoproxy.service"
OPENRC_SERVICE_FILE="/etc/init.d/mundoproxy"
COMMAND_BIN="/usr/local/bin/mp"
CORE_BIN="/usr/local/bin/mundoproxy"
CORE_BACKUP_BIN="$BIN_DIR/mundoproxy"
CLIENT_URI_FILE="$APP_DIR/client.uri"
CLIENT_URI_ECH_FILE="$APP_DIR/client-ech.uri"
PROFILE_FILE="$APP_DIR/profile.env"
NGINX_CONF_FILE="/etc/nginx/conf.d/mundoproxy.conf"

red='\033[31m'
yellow='\033[33m'
green='\033[92m'
blue='\033[94m'
cyan='\033[96m'
none='\033[0m'

say() { printf "%b\n" "$*"; }
ok() { say "${green}$*${none}"; }
warn() { say "${yellow}$*${none}"; }
err() { say "${red}$*${none}"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || err "请使用 root 权限运行。"
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1
}

openrc_available() {
    command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v yum >/dev/null 2>&1; then
        echo yum
    elif command -v apk >/dev/null 2>&1; then
        echo apk
    else
        echo ""
    fi
}

install_nginx() {
    command -v nginx >/dev/null 2>&1 && return 0
    local manager
    manager="$(detect_pkg_manager)"
    [ -n "$manager" ] || err "无法识别包管理器，请手动安装 nginx openssl。"
    warn "正在安装 Nginx 和 OpenSSL。"
    case "$manager" in
        apt)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y nginx openssl ca-certificates
            ;;
        dnf)
            dnf install -y nginx openssl ca-certificates
            ;;
        yum)
            yum install -y nginx openssl ca-certificates
            ;;
        apk)
            apk add --no-cache nginx openssl ca-certificates
            ;;
    esac
    command -v nginx >/dev/null 2>&1 || err "Nginx 安装失败。"
}

install_certbot() {
    command -v certbot >/dev/null 2>&1 && return 0
    local manager
    manager="$(detect_pkg_manager)"
    [ -n "$manager" ] || return 1
    warn "安装 certbot。"
    case "$manager" in
        apt)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
            ;;
        dnf)
            dnf install -y certbot
            ;;
        yum)
            yum install -y certbot
            ;;
        apk)
            apk add --no-cache certbot
            ;;
    esac
    command -v certbot >/dev/null 2>&1
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value
    read -r -p "$prompt [$default]: " value
    if [ -z "$value" ]; then
        printf "%s" "$default"
    else
        printf "%s" "$value"
    fi
}

yes_no_default_no() {
    local prompt="$1"
    local value
    read -r -p "$prompt [y/N]: " value
    case "$value" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

random_hex() {
    local bytes="${1:-16}"
    openssl rand -hex "$bytes"
}

random_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    local hex
    hex="$(random_hex 16)"
    printf "%s-%s-%s-%s-%s" "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

random_desktop_name() {
    printf "DESKTOP-%s" "$(random_hex 3 | tr '[:lower:]' '[:upper:]')"
}

is_ip_address() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    [[ "$value" == *:* ]] && return 0
    return 1
}

is_domain_name() {
    local value="$1"
    [ -n "$value" ] || return 1
    is_ip_address "$value" && return 1
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]]
}

sanitize_host() {
    printf "%s" "$1" | tr -cd 'A-Za-z0-9.:-'
}

sanitize_path() {
    local value="$1"
    value="${value%%\?*}"
    value="$(printf "%s" "$value" | tr -cd 'A-Za-z0-9._~/-')"
    [ -n "$value" ] || value="/$(random_hex 6)"
    [[ "$value" == /* ]] || value="/$value"
    printf "%s" "$value"
}

url_encode() {
    local input="$1"
    local output=""
    local i char hex
    LC_ALL=C
    for ((i = 0; i < ${#input}; i++)); do
        char="${input:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-])
                output+="$char"
                ;;
            *)
                printf -v hex '%%%02X' "'$char"
                output+="$hex"
                ;;
        esac
    done
    printf "%s" "$output"
}

service_name_for_path() {
    local value="${1#/}"
    value="$(printf "%s" "$value" | tr -cd 'A-Za-z0-9._-')"
    [ -n "$value" ] || value="MundoConnect"
    printf "%s" "$value"
}

normalize_protocol() {
    case "$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')" in
        ""|"mx"|"mundo-x"|"mundo x")
            echo "mx"
            ;;
        "trojan")
            echo "trojan"
            ;;
        "vless")
            echo "vless"
            ;;
        "vmess")
            echo "vmess"
            ;;
        "anytls"|"any-tls")
            echo "anytls"
            ;;
        *)
            return 1
            ;;
    esac
}

normalize_transport() {
    case "$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')" in
        ""|"1"|"mc1"|"mundo-connect-1"|"mundo connect 1")
            echo "mc1"
            ;;
        "2"|"mundordp"|"rdp"|"3389"|"mundo connect rdp protocol")
            echo "mundordp"
            ;;
        "3"|"xhttp"|"splithttp")
            echo "xhttp"
            ;;
        "4"|"grpc")
            echo "grpc"
            ;;
        "5"|"ws"|"websocket")
            echo "websocket"
            ;;
        *)
            return 1
            ;;
    esac
}

protocol_supports_transport() {
    local protocol="$1"
    local transport="$2"
    if [ "$protocol" = "mx" ]; then
        return 0
    fi
    case "$transport" in
        mc1|mundordp) return 0 ;;
        *) return 1 ;;
    esac
}

parse_protocol_transport() {
    local raw="$1"
    local value protocol_part transport_part
    value="$(printf "%s" "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    value="${value//＋/+}"
    if [ -z "$value" ]; then
        protocol_part="mx"
        transport_part="mundordp"
    elif [[ "$value" == *+* ]]; then
        protocol_part="${value%%+*}"
        transport_part="${value#*+}"
    elif normalize_transport "$value" >/dev/null 2>&1; then
        protocol_part="mx"
        transport_part="$value"
    elif normalize_protocol "$value" >/dev/null 2>&1; then
        protocol_part="$value"
        transport_part="mc1"
    else
        return 1
    fi

    CHOSEN_PROTOCOL="$(normalize_protocol "$protocol_part")" || return 1
    CHOSEN_TRANSPORT="$(normalize_transport "$transport_part")" || return 1
    protocol_supports_transport "$CHOSEN_PROTOCOL" "$CHOSEN_TRANSPORT" || {
        err "只有 mx 支持 ws、grpc、xhttp；$CHOSEN_PROTOCOL 只能使用 mc1 或 mundordp。"
    }
}

transport_display_name() {
    case "$1" in
        mc1) echo "mc1" ;;
        mundordp) echo "mundordp" ;;
        xhttp) echo "xhttp" ;;
        grpc) echo "grpc" ;;
        websocket) echo "ws" ;;
        *) echo "$1" ;;
    esac
}

uri_transport_name() {
    case "$1" in
        websocket) echo "ws" ;;
        *) echo "$1" ;;
    esac
}

uri_node_name() {
    local protocol="$1"
    local transport="$2"
    local ech_mode="$3"
    local name
    case "$transport" in
        mc1) name="$protocol-mc1" ;;
        mundordp) name="$protocol-rdp" ;;
        xhttp) name="$protocol-xhttp" ;;
        grpc) name="$protocol-grpc" ;;
        websocket) name="$protocol-ws" ;;
        *) name="$protocol" ;;
    esac
    if [ "$ech_mode" = "always" ]; then
        name="$name-ech"
    fi
    printf "%s" "$name"
}

uri_authority_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf "[%s]" "$host"
    else
        printf "%s" "$host"
    fi
}

ech_capable_transport() {
    local protocol="$1"
    local transport="$2"
    [ "$protocol" = "mx" ] || return 1
    case "$transport" in
        mc1|xhttp|websocket) return 0 ;;
        *) return 1 ;;
    esac
}

cdn_capable_transport() {
    case "$1" in
        mc1|xhttp|websocket) return 0 ;;
        *) return 1 ;;
    esac
}

default_port_for_transport() {
    case "$1" in
        mundordp) echo "3389" ;;
        *) echo "443" ;;
    esac
}

choose_protocol_transport() {
    say "输入协议+传输（回车使用 mx+mundordp）:"
    say "协议:"
    say "  mx (Mundo X)"
    say "  trojan (Trojan)"
    say "  vless (VLESS)"
    say "  vmess (VMess)"
    say "  anytls (AnyTLS)"
    say "传输:"
    say "  ${green}mundordp (Mundo Connect RDP Protocol，所有协议支持)${none}"
    say "  ${green}mc1 (Mundo Connect 1，所有协议支持，CDN)${none}"
    say "  xhttp (XHTTP，仅 mx，CDN)"
    say "  grpc (gRPC，仅 mx)"
    say "  ws (WebSocket，仅 mx，CDN)"
    local choice
    read -r -p "协议+传输 [mx+mundordp]: " choice
    parse_protocol_transport "$choice" || err "不支持的协议或传输。"
}

choose_server_host() {
    local value
    read -r -p "域名或服务器IP地址 [apple.com]: " value
    value="$(sanitize_host "$value")"
    if [ -z "$value" ]; then
        SERVER_HOST="apple.com"
        SERVER_HOST_DEFAULTED=1
    else
        SERVER_HOST="$value"
        SERVER_HOST_DEFAULTED=0
    fi
}

choose_cdn_address() {
    local transport="$1"
    local default_host="$2"
    CLIENT_HOST="$default_host"
    CDN_ENABLED=0
    if cdn_capable_transport "$transport" && yes_no_default_no "使用 CDN 优选地址"; then
        CLIENT_HOST="$(prompt_default "CDN 优选地址" "$default_host")"
        CLIENT_HOST="$(sanitize_host "$CLIENT_HOST")"
        [ -n "$CLIENT_HOST" ] || CLIENT_HOST="$default_host"
        CDN_ENABLED=1
    fi
}

ensure_dirs() {
    mkdir -p "$APP_DIR" "$BIN_DIR" "$SH_DIR/src" "$CERT_DIR" "$LOG_DIR"
    touch "$ACCESS_LOG" "$ERROR_LOG"
}

generate_self_signed_cert() {
    local host="$1"
    local cn
    local san=""

    ensure_dirs
    if is_domain_name "$host"; then
        cn="$host"
        san="subjectAltName=DNS:$host"
        warn "将生成自签名证书: $host"
    else
        cn="$(random_desktop_name)"
        warn "将生成自签名证书: $cn"
    fi

    rm -f "$CERT_FILE" "$KEY_FILE"
    if [ -n "$san" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/CN=$cn" -addext "$san" >/dev/null 2>&1 || err "自签名证书生成失败，请确认 openssl 可用。"
    else
        openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/CN=$cn" >/dev/null 2>&1 || err "自签名证书生成失败，请确认 openssl 可用。"
    fi
    chmod 600 "$KEY_FILE"
}

try_certbot_cert() {
    local host="$1"
    local live_dir="/etc/letsencrypt/live/$host"
    install_certbot || return 1
    certbot certonly --standalone --preferred-challenges http \
        --non-interactive --agree-tos --register-unsafely-without-email \
        -d "$host" || return 1
    [ -s "$live_dir/fullchain.pem" ] && [ -s "$live_dir/privkey.pem" ] || return 1
    CERT_FILE="$live_dir/fullchain.pem"
    KEY_FILE="$live_dir/privkey.pem"
    return 0
}

prepare_certificate() {
    local host="$1"
    if is_domain_name "$host" && yes_no_default_no "使用 certbot 申请证书（需要 80 端口）"; then
        if try_certbot_cert "$host"; then
            ok "已使用 certbot 证书。"
            return 0
        fi
        warn "certbot 失败，改用自签名证书。"
    fi
    generate_self_signed_cert "$host"
}

render_tls_settings() {
    local host="$1"
    if is_ip_address "$host"; then
        cat <<EOF
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "$CERT_FILE",
          "keyFile": "$KEY_FILE"
        }
      ]
    }
EOF
        return 0
    fi
    cat <<EOF
    "security": "tls",
    "tlsSettings": {
      "serverName": "$host",
      "certificates": [
        {
          "certificateFile": "$CERT_FILE",
          "keyFile": "$KEY_FILE"
        }
      ]
    }
EOF
}

render_stream_settings() {
    local transport="$1"
    local host="$2"
    local path="$3"
    local username="$4"
    local connections="$5"
    local reverse_proxy="$6"
    local service_name
    local mc1_mode="auto"
    local mc1_disable_h3="false"
    local host_line=""
    local authority_line=""
    service_name="$(service_name_for_path "$path")"
    if ! is_ip_address "$host"; then
        host_line="\"host\": \"$host\","
        authority_line="\"authority\": \"$host\","
    fi
    if [ "$reverse_proxy" = "1" ] && [ "$transport" = "mc1" ]; then
        mc1_mode="h2"
        mc1_disable_h3="true"
    fi

    case "$transport" in
        mc1)
            cat <<EOF
{
    "network": "mc1",
$(render_tls_settings "$host"),
    "mc1Settings": {
      "path": "$path",
      $host_line
      "mode": "$mc1_mode",
      "disableH3Upload": $mc1_disable_h3
    }
  }
EOF
            ;;
        mundordp)
            cat <<EOF
{
    "network": "mundordp",
$(render_tls_settings "$host"),
    "mundordpSettings": {
      "username": "$username",
      "useTLSCertificate": true,
      "connections": $connections
    }
  }
EOF
            ;;
        xhttp)
            cat <<EOF
{
    "network": "xhttp",
$(render_tls_settings "$host"),
    "xhttpSettings": {
      "path": "$path",
      $host_line
      "mode": "auto"
    }
  }
EOF
            ;;
        grpc)
            cat <<EOF
{
    "network": "grpc",
$(render_tls_settings "$host"),
    "grpcSettings": {
      "serviceName": "$service_name",
      $authority_line
      "multiMode": true,
      "idle_timeout": 0,
      "health_check_timeout": 0,
      "permit_without_stream": false,
      "initial_windows_size": 0
    }
  }
EOF
            ;;
        websocket)
            cat <<EOF
{
    "network": "websocket",
$(render_tls_settings "$host"),
    "wsSettings": {
      "path": "$path"
      ${host_line:+,}
      ${host_line%,}
    }
  }
EOF
            ;;
    esac
}

write_config() {
    local protocol="$1"
    local transport="$2"
    local port="$3"
    local token="$4"
    local host="$5"
    local path="$6"
    local username="$7"
    local connections="$8"
    local listen_addr="$9"
    local reverse_proxy="${10}"
    local stream_settings
    local inbound_settings
    stream_settings="$(render_stream_settings "$transport" "$host" "$path" "$username" "$connections" "$reverse_proxy")"
    inbound_settings="$(render_inbound_settings "$protocol" "$token")"

    ensure_dirs
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "access": "$ACCESS_LOG",
    "error": "$ERROR_LOG",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "$protocol-$transport",
      "listen": "$listen_addr",
      "port": $port,
      "protocol": "$protocol",
      "settings": $inbound_settings,
      "streamSettings": $stream_settings,
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF
}

render_inbound_settings() {
    local protocol="$1"
    local token="$2"
    case "$protocol" in
        mx)
            cat <<EOF
{
        "users": [
          {
            "token": "$token"
          }
        ]
      }
EOF
            ;;
        trojan)
            cat <<EOF
{
        "clients": [
          {
            "password": "$token"
          }
        ]
      }
EOF
            ;;
        anytls)
            cat <<EOF
{
        "users": [
          {
            "password": "$token"
          }
        ]
      }
EOF
            ;;
        vless)
            cat <<EOF
{
        "clients": [
          {
            "id": "$token"
          }
        ],
        "decryption": "none"
      }
EOF
            ;;
        vmess)
            cat <<EOF
{
        "clients": [
          {
            "id": "$token",
            "security": "auto"
          }
        ]
      }
EOF
            ;;
    esac
}

write_profile() {
    local protocol="$1"
    local transport="$2"
    local port="$3"
    local token="$4"
    local host="$5"
    local client_host="$6"
    local path="$7"
    local username="$8"
    local connections="$9"
    local ech_mode="${10}"
    local reverse_proxy="${11}"
    local external_port="${12}"
    local core_port="${13}"
    local cdn_enabled="${14:-0}"
    cat > "$PROFILE_FILE" <<EOF
PROTOCOL='$protocol'
TRANSPORT='$transport'
PORT='$external_port'
CORE_PORT='$core_port'
TOKEN='$token'
HOST='$host'
CLIENT_HOST='$client_host'
PATH_VALUE='$path'
RDP_USERNAME='$username'
RDP_CONNECTIONS='$connections'
ECH_MODE='$ech_mode'
REVERSE_PROXY='$reverse_proxy'
CDN_ENABLED='$cdn_enabled'
EOF
    chmod 600 "$PROFILE_FILE"
}

build_client_uri() {
    local protocol="$1"
    local transport="$2"
    local port="$3"
    local token="$4"
    local connect_host="$5"
    local server_host="$6"
    local path="$7"
    local username="$8"
    local ech_mode="$9"
    local reverse_proxy="${10:-0}"
    local uri_type
    uri_type="$(uri_transport_name "$transport")"
    local mc1_mode="auto"
    if [ "$transport" = "mc1" ] && [ "$reverse_proxy" = "1" ]; then
        mc1_mode="h2"
    fi

    local query="security=tls&type=$(url_encode "$uri_type")&fp=chrome&encryption=none"
    if ! is_ip_address "$server_host"; then
        query="$query&sni=$(url_encode "$server_host")"
    fi
    case "$transport" in
        mc1)
            query="$query&path=$(url_encode "$path")"
            if ! is_ip_address "$server_host"; then
                query="$query&host=$(url_encode "$server_host")"
            fi
            query="$query&mode=$(url_encode "$mc1_mode")"
            ;;
        xhttp)
            query="$query&path=$(url_encode "$path")"
            if ! is_ip_address "$server_host"; then
                query="$query&host=$(url_encode "$server_host")"
            fi
            query="$query&mode=auto"
            ;;
        websocket)
            query="$query&path=$(url_encode "$path")"
            if ! is_ip_address "$server_host"; then
                query="$query&host=$(url_encode "$server_host")"
            fi
            ;;
        grpc)
            query="$query&serviceName=$(url_encode "$(service_name_for_path "$path")")"
            ;;
        mundordp)
            query="$query&username=$(url_encode "$username")"
            ;;
    esac

    if [ "$ech_mode" != "off" ]; then
        query="$query&echMode=$(url_encode "$ech_mode")"
    else
        query="$query&echMode=off"
    fi

    printf "%s://%s@%s:%s?%s#%s" \
        "$protocol" \
        "$(url_encode "$token")" \
        "$(uri_authority_host "$connect_host")" \
        "$port" \
        "$query" \
        "$(url_encode "$(uri_node_name "$protocol" "$transport" "$ech_mode")")"
}

write_client_uri() {
    local protocol="$1"
    local transport="$2"
    local port="$3"
    local token="$4"
    local connect_host="$5"
    local server_host="$6"
    local path="$7"
    local username="$8"
    local ech_mode="$9"
    local reverse_proxy="${10:-0}"
    build_client_uri "$protocol" "$transport" "$port" "$token" "$connect_host" "$server_host" "$path" "$username" "$ech_mode" "$reverse_proxy" > "$CLIENT_URI_FILE"
    chmod 600 "$CLIENT_URI_FILE"
}

write_client_uris() {
    local protocol="$1"
    local transport="$2"
    local port="$3"
    local token="$4"
    local connect_host="$5"
    local server_host="$6"
    local path="$7"
    local username="$8"
    local reverse_proxy="${9:-0}"
    build_client_uri "$protocol" "$transport" "$port" "$token" "$connect_host" "$server_host" "$path" "$username" "off" "$reverse_proxy" > "$CLIENT_URI_FILE"
    chmod 600 "$CLIENT_URI_FILE"
    if ech_capable_transport "$protocol" "$transport" && ! is_ip_address "$server_host"; then
        build_client_uri "$protocol" "$transport" "$port" "$token" "$connect_host" "$server_host" "$path" "$username" "always" "$reverse_proxy" > "$CLIENT_URI_ECH_FILE"
        chmod 600 "$CLIENT_URI_ECH_FILE"
    else
        rm -f "$CLIENT_URI_ECH_FILE"
    fi
}

nginx_location_path() {
    local transport="$1"
    local path="$2"
    case "$transport" in
        grpc) echo "/" ;;
        *) echo "$path" ;;
    esac
}

write_nginx_config() {
    local transport="$1"
    local external_port="$2"
    local core_port="$3"
    local host="$4"
    local path="$5"
    local location_path
    location_path="$(nginx_location_path "$transport" "$path")"

    install_nginx
    mkdir -p "$(dirname "$NGINX_CONF_FILE")"

    if [ "$transport" = "grpc" ]; then
        cat > "$NGINX_CONF_FILE" <<EOF
server {
    listen $external_port ssl http2;
    server_name _;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    client_max_body_size 0;

    location / {
        grpc_pass grpcs://127.0.0.1:$core_port;
        grpc_ssl_server_name on;
        grpc_ssl_name $host;
        grpc_ssl_verify off;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
    }
}
EOF
    elif [ "$transport" = "websocket" ]; then
        cat > "$NGINX_CONF_FILE" <<EOF
map \$http_upgrade \$mundo_connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen $external_port ssl http2;
    server_name _;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    client_max_body_size 0;

    location ^~ $location_path {
        proxy_pass https://127.0.0.1:$core_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$mundo_connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_server_name on;
        proxy_ssl_name $host;
        proxy_ssl_verify off;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF
    else
        cat > "$NGINX_CONF_FILE" <<EOF
server {
    listen $external_port ssl http2;
    server_name _;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    client_max_body_size 0;

    location ^~ $location_path {
        proxy_pass https://127.0.0.1:$core_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_server_name on;
        proxy_ssl_name $host;
        proxy_ssl_verify off;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_hide_header Alt-Svc;
    }
}
EOF
    fi

    nginx -t || err "Nginx 配置检查失败。"
    if systemd_available; then
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx
    else
        nginx -s reload >/dev/null 2>&1 || nginx
    fi
}

remove_nginx_config() {
    [ -f "$NGINX_CONF_FILE" ] || return 0
    rm -f "$NGINX_CONF_FILE"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && {
            if systemd_available; then
                systemctl reload nginx >/dev/null 2>&1 || true
            else
                nginx -s reload >/dev/null 2>&1 || true
            fi
        }
    fi
}

configure() {
    require_root
    ensure_dirs

    local no_restart=0
    if [ "${1:-}" = "--no-restart" ]; then
        no_restart=1
    fi

    say "${blue}生成配置${none}"

    local protocol
    local transport
    choose_protocol_transport
    protocol="$CHOSEN_PROTOCOL"
    transport="$CHOSEN_TRANSPORT"
    local ech_mode="off"
    local default_port
    default_port="$(default_port_for_transport "$transport")"
    local external_port
    external_port="$(prompt_default "端口" "$default_port")"
    [[ "$external_port" =~ ^[0-9]+$ ]] || err "端口必须是数字。"
    [ "$external_port" -ge 1 ] && [ "$external_port" -le 65535 ] || err "端口范围必须是 1-65535。"

    local host
    local client_host
    choose_server_host
    host="$SERVER_HOST"
    if [ "$SERVER_HOST_DEFAULTED" = "1" ]; then
        generate_self_signed_cert "$host"
    else
        prepare_certificate "$host"
    fi
    choose_cdn_address "$transport" "$host"
    client_host="$CLIENT_HOST"

    local path="/"
    if [ "$transport" != "mundordp" ]; then
        path="$(prompt_default "路径" "/$(random_hex 6)")"
        path="$(sanitize_path "$path")"
    fi

    local token
    local token_label="Token"
    local token_default
    case "$protocol" in
        vless|vmess)
            token_label="UUID"
            token_default="$(random_uuid)"
            ;;
        trojan|anytls)
            token_label="Password"
            token_default="$(random_hex 16)"
            ;;
        *)
            token_default="$(random_hex 16)"
            ;;
    esac
    token="$(prompt_default "$token_label" "$token_default")"
    token="$(printf "%s" "$token" | tr -cd 'A-Za-z0-9._~:/+=-')"
    [ -n "$token" ] || err "token 不能为空。"
    case "$protocol" in
        vless|vmess)
            is_uuid "$token" || err "$protocol 需要 UUID。"
            ;;
    esac

    local username="Administrator"
    local connections=1
    if [ "$transport" = "mundordp" ]; then
        username="$(prompt_default "用户名" "Administrator")"
        username="$(printf "%s" "$username" | tr -cd 'A-Za-z0-9._@-')"
        [ -n "$username" ] || username="Administrator"
        connections="$(prompt_default "连接数" "1")"
        [[ "$connections" =~ ^[0-9]+$ ]] || connections=1
        [ "$connections" -ge 1 ] && [ "$connections" -le 255 ] || connections=1
    fi

    local reverse_proxy=0
    local core_port="$external_port"
    local listen_addr="0.0.0.0"
    if [ "$transport" != "mundordp" ]; then
        if [ "$external_port" != "443" ]; then
            warn "当前端口不是 443。"
            if yes_no_default_no "启用 Nginx 反代"; then
                reverse_proxy=1
            fi
        elif yes_no_default_no "启用 Nginx 反代"; then
            reverse_proxy=1
        fi
    fi
    if [ "$reverse_proxy" -eq 1 ]; then
        local default_core_port
        default_core_port=$((external_port + 10000))
        if [ "$default_core_port" -gt 65535 ]; then
            default_core_port=$((external_port - 10000))
        fi
        [ "$default_core_port" -ge 1 ] || default_core_port=1443
        core_port="$(prompt_default "后端端口" "$default_core_port")"
        [[ "$core_port" =~ ^[0-9]+$ ]] || err "内部端口必须是数字。"
        [ "$core_port" -ge 1 ] && [ "$core_port" -le 65535 ] || err "内部端口范围必须是 1-65535。"
        [ "$core_port" != "$external_port" ] || err "反代模式下内部端口不能和对外端口相同。"
        listen_addr="127.0.0.1"
    fi

    write_config "$protocol" "$transport" "$core_port" "$token" "$host" "$path" "$username" "$connections" "$listen_addr" "$reverse_proxy"
    write_profile "$protocol" "$transport" "$core_port" "$token" "$host" "$client_host" "$path" "$username" "$connections" "$ech_mode" "$reverse_proxy" "$external_port" "$core_port" "$CDN_ENABLED"
    write_client_uris "$protocol" "$transport" "$external_port" "$token" "$client_host" "$host" "$path" "$username" "$reverse_proxy"
    if [ "$reverse_proxy" -eq 1 ]; then
        write_nginx_config "$transport" "$external_port" "$core_port" "$host" "$path"
    else
        remove_nginx_config
    fi

    ok "配置已生成"
    say "配置文件: $CONFIG_FILE"
    say "普通 URI 文件: $CLIENT_URI_FILE"
    [ -f "$CLIENT_URI_ECH_FILE" ] && say "ECH URI 文件: $CLIENT_URI_ECH_FILE"
    say "协议: $protocol"
    say "传输: $(transport_display_name "$transport")"
    say "端口: $external_port"
    if [ "$reverse_proxy" -eq 1 ]; then
        say "反代: Nginx -> 127.0.0.1:$core_port"
    else
        say "监听: $listen_addr:$core_port"
    fi
    say "服务器: $host"
    [ "$client_host" != "$host" ] && say "连接地址: $client_host"
    [ "$transport" != "mundordp" ] && say "路径: $path"
    [ "$transport" = "mundordp" ] && say "用户名: $username"
    say "$token_label: $token"
    say "普通 URI: $(cat "$CLIENT_URI_FILE")"
    [ -f "$CLIENT_URI_ECH_FILE" ] && say "ECH URI: $(cat "$CLIENT_URI_ECH_FILE")"

    if [ "$no_restart" -eq 0 ] && systemd_available && systemctl list-unit-files mundoproxy.service >/dev/null 2>&1; then
        systemctl restart mundoproxy
        ok "服务已重启。"
    elif [ "$no_restart" -eq 0 ] && openrc_available && [ -f "$OPENRC_SERVICE_FILE" ]; then
        rc-service mundoproxy restart
        ok "服务已重启。"
    fi
}

start_service() {
    require_root
    if systemd_available; then
        systemctl start mundoproxy
    elif openrc_available; then
        rc-service mundoproxy start
    else
        err "未检测到 systemd 或 OpenRC。"
    fi
}

stop_service() {
    require_root
    if systemd_available; then
        systemctl stop mundoproxy
    elif openrc_available; then
        rc-service mundoproxy stop
    else
        err "未检测到 systemd 或 OpenRC。"
    fi
}

restart_service() {
    require_root
    if systemd_available; then
        systemctl restart mundoproxy
    elif openrc_available; then
        rc-service mundoproxy restart
    else
        err "未检测到 systemd 或 OpenRC。"
    fi
}

autostart_enabled() {
    if systemd_available; then
        systemctl is-enabled mundoproxy >/dev/null 2>&1
        return $?
    fi
    if openrc_available; then
        rc-update show default 2>/dev/null | grep -q '^ *mundoproxy'
        return $?
    fi
    return 1
}

autostart_status_label() {
    if autostart_enabled; then
        printf "%b" "${green}[当前已开启]${none}"
    else
        printf "%b" "${red}[当前已关闭]${none}"
    fi
}

enable_autostart() {
    require_root
    if systemd_available; then
        [ -f "$SERVICE_FILE" ] || err "服务文件不存在: $SERVICE_FILE"
        systemctl enable mundoproxy >/dev/null
    elif openrc_available; then
        [ -f "$OPENRC_SERVICE_FILE" ] || err "服务文件不存在: $OPENRC_SERVICE_FILE"
        rc-update add mundoproxy default >/dev/null
    else
        err "未检测到 systemd 或 OpenRC。"
    fi
    ok "开机启动已开启。"
}

disable_autostart() {
    require_root
    if systemd_available; then
        systemctl disable mundoproxy >/dev/null 2>&1 || true
    elif openrc_available; then
        rc-update del mundoproxy default >/dev/null 2>&1 || true
    else
        err "未检测到 systemd 或 OpenRC。"
    fi
    ok "开机启动已关闭。"
}

status_service() {
    if systemd_available && systemctl list-unit-files mundoproxy.service >/dev/null 2>&1; then
        systemctl status mundoproxy --no-pager
    elif openrc_available && [ -f "$OPENRC_SERVICE_FILE" ]; then
        rc-service mundoproxy status
    else
        warn "未安装服务。"
        if [ -x "$CORE_BIN" ]; then
            say "可手动运行: mundoproxy run -c $CONFIG_FILE"
        fi
    fi
}

show_log() {
    local file="$1"
    if [ -f "$file" ]; then
        tail -n 120 -f "$file"
    else
        warn "日志文件不存在: $file"
    fi
}

show_info() {
    local protocol="mx"
    local transport=""
    local port=""
    local core_port=""
    local host=""
    local client_host=""
    local path_value=""
    local ech_mode=""
    local reverse_proxy=""
    local cdn_enabled="0"
    local rdp_username=""
    if [ -f "$PROFILE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$PROFILE_FILE"
        protocol="${PROTOCOL:-mx}"
        transport="${TRANSPORT:-}"
        port="${PORT:-}"
        core_port="${CORE_PORT:-}"
        host="${HOST:-}"
        client_host="${CLIENT_HOST:-$host}"
        path_value="${PATH_VALUE:-}"
        ech_mode="${ECH_MODE:-off}"
        reverse_proxy="${REVERSE_PROXY:-0}"
        cdn_enabled="${CDN_ENABLED:-0}"
        rdp_username="${RDP_USERNAME:-Administrator}"
    fi

    say "${cyan}Mundo Proxy${none}"
    [ -n "$transport" ] && say "协议: $protocol"
    [ -n "$transport" ] && say "传输: $(transport_display_name "$transport")"
    [ -n "$port" ] && say "端口: $port"
    [ -n "$host" ] && say "服务器: $host"
    [ "$cdn_enabled" = "1" ] && [ -n "$client_host" ] && say "连接地址: $client_host"
    [ -n "$path_value" ] && [ "$transport" != "mundordp" ] && say "路径: $path_value"
    [ "$transport" = "mundordp" ] && say "用户名: $rdp_username"
    if [ "$reverse_proxy" = "1" ]; then
        say "反代: Nginx -> 127.0.0.1:$core_port"
    elif [ -n "$core_port" ]; then
        say "监听: 0.0.0.0:$core_port"
    fi
    say "配置文件: $CONFIG_FILE"
    if [ -f "$CLIENT_URI_FILE" ]; then
        say ""
        say "普通 URI:"
        cat "$CLIENT_URI_FILE"
        say ""
    fi
    if [ -f "$CLIENT_URI_ECH_FILE" ]; then
        say "ECH URI:"
        cat "$CLIENT_URI_ECH_FILE"
        say ""
    fi
}

uninstall_mundo_proxy() {
    require_root
    warn "即将卸载 Mundo Proxy，并删除 $APP_DIR 与 $LOG_DIR。"
    read -r -p "确认卸载? [y/N]: " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) say "已取消。"; exit 0 ;;
    esac

    if systemd_available; then
        systemctl stop mundoproxy >/dev/null 2>&1 || true
        systemctl disable mundoproxy >/dev/null 2>&1 || true
        systemctl reset-failed mundoproxy >/dev/null 2>&1 || true
    elif openrc_available; then
        rc-service mundoproxy stop >/dev/null 2>&1 || true
        rc-update del mundoproxy default >/dev/null 2>&1 || true
    fi
    rm -f "$SERVICE_FILE" "$OPENRC_SERVICE_FILE" "$COMMAND_BIN" "$CORE_BIN" "$CORE_BACKUP_BIN"
    remove_nginx_config
    rm -rf "$APP_DIR" "$LOG_DIR"
    if systemd_available; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    ok "已卸载 Mundo Proxy。"
}

run_core() {
    [ -x "$CORE_BIN" ] || err "内核不存在: $CORE_BIN"
    exec "$CORE_BIN" run -c "$CONFIG_FILE"
}

install_again() {
    require_root
    if [ -x "$BIN_DIR/install.sh" ]; then
        exec "$BIN_DIR/install.sh"
    fi
    err "未找到已安装的 install.sh。请回到本地解压目录执行 ./install.sh。"
}

help_msg() {
    cat <<EOF
Mundo Proxy

命令:
  mp           菜单
  mp info      显示配置和 URI
  mp config    重新生成配置
  mp restart   重启
  mp status    状态
  mp autostart 开关开机启动
  mp log       日志
  mp error-log 错误日志
  mp uninstall 卸载
EOF
}

menu() {
    while true; do
        show_info
        say ""
        say "${blue}菜单${none}"
        say "  1) 显示配置"
        say "  2) 重新配置"
        say "  3) 重启"
        say "  4) 状态"
        say "  5) 开机启动 $(autostart_status_label)"
        say "  6) 错误日志"
        say "  7) 卸载"
        say "  0) 退出"
        local choice
        read -r -p "请选择 [1]: " choice
        case "${choice:-1}" in
            1) show_info ;;
            2) configure ;;
            3) restart_service ;;
            4) status_service ;;
            5)
                if autostart_enabled; then
                    disable_autostart
                else
                    enable_autostart
                fi
                ;;
            6) show_log "$ERROR_LOG" ;;
            7) uninstall_mundo_proxy ;;
            0) exit 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

main() {
    case "${1:-}" in
        ""|menu)
            menu
            ;;
        help|-h|--help)
            help_msg
            ;;
        install)
            install_again
            ;;
        deps)
            require_root
            "$BIN_DIR/install.sh" --deps
            ;;
        config|configure)
            shift
            configure "$@"
            ;;
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            restart_service
            ;;
        enable-autostart|autostart-on|enable-boot)
            enable_autostart
            ;;
        disable-autostart|autostart-off|disable-boot)
            disable_autostart
            ;;
        autostart)
            if autostart_enabled; then
                disable_autostart
            else
                enable_autostart
            fi
            ;;
        status)
            status_service
            ;;
        log)
            show_log "$ACCESS_LOG"
            ;;
        error-log|logerr|error)
            show_log "$ERROR_LOG"
            ;;
        info)
            show_info
            ;;
        run)
            run_core
            ;;
        uninstall|remove|delete)
            uninstall_mundo_proxy
            ;;
        *)
            help_msg
            exit 1
            ;;
    esac
}

main "$@"
