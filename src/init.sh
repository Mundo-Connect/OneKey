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
COMMAND_BIN="/usr/local/bin/mp"
CORE_BIN="/usr/local/bin/mundoproxy"
CORE_BACKUP_BIN="$BIN_DIR/mundoproxy"
CLIENT_URI_FILE="$APP_DIR/client.uri"
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

transport_display_name() {
    case "$1" in
        mc1) echo "Mundo Connect 1 (mc1)" ;;
        mundordp) echo "Mundo Connect RDP Protocol (mundordp)" ;;
        xhttp) echo "XHTTP (xhttp)" ;;
        grpc) echo "gRPC (grpc)" ;;
        websocket) echo "WebSocket (websocket)" ;;
        *) echo "$1" ;;
    esac
}

uri_transport_name() {
    case "$1" in
        websocket) echo "ws" ;;
        *) echo "$1" ;;
    esac
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

choose_transport() {
    say "请选择传输协议:"
    say "  1) Mundo Connect 1 (mc1，推荐)"
    say "  2) Mundo Connect RDP Protocol (mundordp，推荐)"
    say "  3) XHTTP (xhttp，可过 CDN)"
    say "  4) gRPC (grpc)"
    say "  5) WebSocket (websocket，可过 CDN)"
    local choice
    read -r -p "传输协议 [1]: " choice
    normalize_transport "${choice:-1}" || err "不支持的传输协议。"
}

choose_ech_mode() {
    local transport="$1"
    if ! ech_capable_transport "$transport"; then
        echo "off"
        return 0
    fi
    say "请选择节点模式:"
    say "  1) Mundo Connect"
    say "  2) Mundo Connect + ECH"
    local choice
    read -r -p "节点模式 [1]: " choice
    case "${choice:-1}" in
        1) echo "off" ;;
        2) echo "always" ;;
        *) err "不支持的节点模式。" ;;
    esac
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
        warn "未配置受信任证书，将为域名 $host 生成自签名证书。"
    else
        cn="$(random_desktop_name)"
        warn "未使用域名或输入的是 IP，将生成随机自签名证书: $cn"
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

render_tls_settings() {
    local host="$1"
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
    service_name="$(service_name_for_path "$path")"
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
      "host": "$host",
      "path": "$path",
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
      "host": "$host",
      "path": "$path",
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
      "authority": "$host",
      "serviceName": "$service_name",
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
      "host": "$host",
      "path": "$path"
    }
  }
EOF
            ;;
    esac
}

write_config() {
    local transport="$1"
    local port="$2"
    local token="$3"
    local host="$4"
    local path="$5"
    local username="$6"
    local connections="$7"
    local listen_addr="$8"
    local reverse_proxy="$9"
    local stream_settings
    stream_settings="$(render_stream_settings "$transport" "$host" "$path" "$username" "$connections" "$reverse_proxy")"

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
      "tag": "mundo-x-$transport",
      "listen": "$listen_addr",
      "port": $port,
      "protocol": "mx",
      "settings": {
        "users": [
          {
            "token": "$token"
          }
        ]
      },
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

write_profile() {
    local transport="$1"
    local port="$2"
    local token="$3"
    local host="$4"
    local path="$5"
    local username="$6"
    local connections="$7"
    local ech_mode="$8"
    local reverse_proxy="$9"
    local external_port="${10}"
    local core_port="${11}"
    cat > "$PROFILE_FILE" <<EOF
TRANSPORT='$transport'
PORT='$external_port'
CORE_PORT='$core_port'
TOKEN='$token'
HOST='$host'
PATH_VALUE='$path'
RDP_USERNAME='$username'
RDP_CONNECTIONS='$connections'
ECH_MODE='$ech_mode'
REVERSE_PROXY='$reverse_proxy'
EOF
    chmod 600 "$PROFILE_FILE"
}

build_client_uri() {
    local transport="$1"
    local port="$2"
    local token="$3"
    local host="$4"
    local path="$5"
    local username="$6"
    local ech_mode="$7"
    local reverse_proxy="${8:-0}"
    local uri_type
    uri_type="$(uri_transport_name "$transport")"
    local mc1_mode="auto"
    if [ "$transport" = "mc1" ] && [ "$reverse_proxy" = "1" ]; then
        mc1_mode="h2"
    fi

    local query="security=tls&type=$(url_encode "$uri_type")&sni=$(url_encode "$host")&fp=chrome&encryption=none"
    case "$transport" in
        mc1)
            query="$query&path=$(url_encode "$path")&host=$(url_encode "$host")&mode=$(url_encode "$mc1_mode")"
            ;;
        xhttp)
            query="$query&path=$(url_encode "$path")&host=$(url_encode "$host")&mode=auto"
            ;;
        websocket)
            query="$query&path=$(url_encode "$path")&host=$(url_encode "$host")"
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

    printf "mx://%s@%s:%s?%s#%s" \
        "$(url_encode "$token")" \
        "$(uri_authority_host "$host")" \
        "$port" \
        "$query" \
        "$(url_encode "Mundo X $(transport_display_name "$transport")")"
}

write_client_uri() {
    local transport="$1"
    local port="$2"
    local token="$3"
    local host="$4"
    local path="$5"
    local username="$6"
    local ech_mode="$7"
    local reverse_proxy="${8:-0}"
    build_client_uri "$transport" "$port" "$token" "$host" "$path" "$username" "$ech_mode" "$reverse_proxy" > "$CLIENT_URI_FILE"
    chmod 600 "$CLIENT_URI_FILE"
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

    say "${blue}生成 Mundo Proxy 配置${none}"
    say "协议固定为 Mundo X (mx)。推荐传输为 Mundo Connect 1 (mc1) 或 Mundo Connect RDP Protocol (mundordp)。"

    local transport
    transport="$(choose_transport)"
    local ech_mode
    ech_mode="$(choose_ech_mode "$transport")"
    local default_port
    default_port="$(default_port_for_transport "$transport")"
    local external_port
    external_port="$(prompt_default "对外端口" "$default_port")"
    [[ "$external_port" =~ ^[0-9]+$ ]] || err "端口必须是数字。"
    [ "$external_port" -ge 1 ] && [ "$external_port" -le 65535 ] || err "端口范围必须是 1-65535。"

    local host
    host="$(prompt_default "服务器地址（域名或 IP，客户端 URI 会使用这个地址）" "")"
    host="$(sanitize_host "$host")"
    [ -n "$host" ] || err "服务器地址不能为空。"

    local path
    path="$(prompt_default "HTTP 类传输路径" "/$(random_hex 6)")"
    path="$(sanitize_path "$path")"

    local token
    token="$(prompt_default "Mundo X token" "$(random_hex 16)")"
    token="$(printf "%s" "$token" | tr -cd 'A-Za-z0-9._~:/+=-')"
    [ -n "$token" ] || err "token 不能为空。"

    local username="Administrator"
    local connections=1
    if [ "$transport" = "mundordp" ]; then
        username="$(prompt_default "RDP 用户名" "Administrator")"
        username="$(printf "%s" "$username" | tr -cd 'A-Za-z0-9._@-')"
        [ -n "$username" ] || username="Administrator"
        connections="$(prompt_default "RDP HTTP/2 channel 连接数" "1")"
        [[ "$connections" =~ ^[0-9]+$ ]] || connections=1
        [ "$connections" -ge 1 ] && [ "$connections" -le 255 ] || connections=1
    fi

    local reverse_proxy=0
    local core_port="$external_port"
    local listen_addr="0.0.0.0"
    if [ "$transport" != "mundordp" ]; then
        if [ "$external_port" != "443" ]; then
            warn "SSL 对外端口不是 443。"
            if yes_no_default_no "是否启用 Nginx 反代，让 Nginx 对外监听 $external_port，Mundo Proxy 仅监听 127.0.0.1"; then
                reverse_proxy=1
            fi
        elif yes_no_default_no "是否启用 Nginx 反代"; then
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
        core_port="$(prompt_default "Mundo Proxy 内部监听端口" "$default_core_port")"
        [[ "$core_port" =~ ^[0-9]+$ ]] || err "内部端口必须是数字。"
        [ "$core_port" -ge 1 ] && [ "$core_port" -le 65535 ] || err "内部端口范围必须是 1-65535。"
        [ "$core_port" != "$external_port" ] || err "反代模式下内部端口不能和对外端口相同。"
        listen_addr="127.0.0.1"
    fi

    generate_self_signed_cert "$host"
    write_config "$transport" "$core_port" "$token" "$host" "$path" "$username" "$connections" "$listen_addr" "$reverse_proxy"
    write_profile "$transport" "$core_port" "$token" "$host" "$path" "$username" "$connections" "$ech_mode" "$reverse_proxy" "$external_port" "$core_port"
    write_client_uri "$transport" "$external_port" "$token" "$host" "$path" "$username" "$ech_mode" "$reverse_proxy"
    if [ "$reverse_proxy" -eq 1 ]; then
        write_nginx_config "$transport" "$external_port" "$core_port" "$host" "$path"
    else
        remove_nginx_config
    fi

    ok "配置已写入: $CONFIG_FILE"
    ok "客户端 URI 已写入: $CLIENT_URI_FILE"
    say "协议: Mundo X (mx)"
    say "传输: $(transport_display_name "$transport")"
    if [ "$ech_mode" = "always" ]; then
        say "节点模式: Mundo Connect + ECH"
    else
        say "节点模式: Mundo Connect"
    fi
    say "对外端口: $external_port"
    if [ "$reverse_proxy" -eq 1 ]; then
        say "反代: Nginx -> 127.0.0.1:$core_port"
        [ "$transport" = "mc1" ] && say "Mundo Connect 1 反代模式: 已使用 H2 并关闭 H3 上传"
    else
        say "监听: $listen_addr:$core_port"
    fi
    say "服务器地址/Host/SNI: $host"
    [ "$transport" != "mundordp" ] && say "路径: $path"
    [ "$transport" = "mundordp" ] && say "用户名: $username"
    say "Token: $token"
    say "URI: $(cat "$CLIENT_URI_FILE")"

    if [ "$no_restart" -eq 0 ] && systemd_available && systemctl list-unit-files mundoproxy.service >/dev/null 2>&1; then
        systemctl restart mundoproxy
        ok "服务已重启。"
    fi
}

start_service() {
    require_root
    systemd_available || err "当前系统没有 systemctl。"
    systemctl start mundoproxy
}

stop_service() {
    require_root
    systemd_available || err "当前系统没有 systemctl。"
    systemctl stop mundoproxy
}

restart_service() {
    require_root
    systemd_available || err "当前系统没有 systemctl。"
    systemctl restart mundoproxy
}

status_service() {
    if systemd_available && systemctl list-unit-files mundoproxy.service >/dev/null 2>&1; then
        systemctl status mundoproxy --no-pager
    else
        warn "未安装 systemd 服务。"
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
    local transport=""
    local port=""
    local core_port=""
    local host=""
    local path_value=""
    local ech_mode=""
    local reverse_proxy=""
    local rdp_username=""
    if [ -f "$PROFILE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$PROFILE_FILE"
        transport="${TRANSPORT:-}"
        port="${PORT:-}"
        core_port="${CORE_PORT:-}"
        host="${HOST:-}"
        path_value="${PATH_VALUE:-}"
        ech_mode="${ECH_MODE:-off}"
        reverse_proxy="${REVERSE_PROXY:-0}"
        rdp_username="${RDP_USERNAME:-Administrator}"
    fi

    say "${cyan}Mundo Proxy${none}"
    say "脚本来源: Mundo Connect 专用本地部署脚本 (GPLv3)"
    say "GitHub: https://github.com/Mundo-Connect"
    say "管理命令: mp"
    [ -n "$transport" ] && say "协议: Mundo X (mx)"
    [ -n "$transport" ] && say "传输: $(transport_display_name "$transport")"
    if [ -n "$ech_mode" ]; then
        if [ "$ech_mode" = "always" ]; then
            say "节点模式: Mundo Connect + ECH"
        else
            say "节点模式: Mundo Connect"
        fi
    fi
    [ -n "$port" ] && say "对外端口: $port"
    [ -n "$host" ] && say "服务器地址/Host/SNI: $host"
    [ -n "$path_value" ] && [ "$transport" != "mundordp" ] && say "路径: $path_value"
    [ "$transport" = "mundordp" ] && say "用户名: $rdp_username"
    if [ "$reverse_proxy" = "1" ]; then
        say "反代: Nginx -> 127.0.0.1:$core_port"
    elif [ -n "$core_port" ]; then
        say "监听: 0.0.0.0:$core_port"
    fi
    say "配置: $CONFIG_FILE"
    if [ -f "$CLIENT_URI_FILE" ]; then
        say ""
        say "客户端 URI:"
        cat "$CLIENT_URI_FILE"
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
    fi
    rm -f "$SERVICE_FILE" "$COMMAND_BIN" "$CORE_BIN" "$CORE_BACKUP_BIN"
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
Mundo Proxy 管理脚本

命令:
  mp                 打开菜单
  mp install         重新执行本地安装脚本
  mp deps            安装运行依赖
  mp config          重新生成 Mundo X 配置
  mp start           启动服务
  mp stop            停止服务
  mp restart         重启服务
  mp status          查看状态
  mp log             查看 access 日志
  mp error-log       查看 error 日志
  mp info            查看安装信息
  mp run             前台运行内核
  mp uninstall       卸载并删除 Mundo Proxy

说明:
  mundoproxy 是内核二进制；mp 是管理快捷指令。

协议说明:
  默认生成 Mundo X (mx)。
  推荐传输 Mundo Connect 1 (mc1) 与 Mundo Connect RDP Protocol (mundordp)。
  可选传输还包括 XHTTP、gRPC、WebSocket。
  Mundo Connect + ECH 只用于 Mundo X + WebSocket、Mundo X + Mundo Connect 1、Mundo X + XHTTP。
EOF
}

menu() {
    while true; do
        show_info
        say ""
        say "${blue}Mundo Proxy 管理菜单${none}"
        say "  1) 查看信息"
        say "  2) 重新生成配置"
        say "  3) 重启服务"
        say "  4) 查看状态"
        say "  5) 查看错误日志"
        say "  6) 卸载 Mundo Proxy"
        say "  0) 退出"
        local choice
        read -r -p "请选择 [1]: " choice
        case "${choice:-1}" in
            1) show_info ;;
            2) configure ;;
            3) restart_service ;;
            4) status_service ;;
            5) show_log "$ERROR_LOG" ;;
            6) uninstall_mundo_proxy ;;
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
