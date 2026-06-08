#!/bin/bash

APP_NAME="Mundo Proxy"
APP_DIR="/etc/mundoproxy"
BIN_DIR="$APP_DIR/bin"
SH_DIR="$APP_DIR/sh"
CONFIG_FILE="$APP_DIR/config.json"
CERT_DIR="$APP_DIR/cert"
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"
MUNDO_CA_DIR="$APP_DIR/mundo-ca"
MUNDO_CA_ROOT_KEY_FILE="$MUNDO_CA_DIR/root.key"
MUNDO_CA_ROOT_CERT_FILE="$MUNDO_CA_DIR/root.crt"
MUNDO_CA_ROOT_SERIAL_FILE="$MUNDO_CA_DIR/root.srl"
MUNDO_CA_CLIENT_KEY_FILE="$MUNDO_CA_DIR/client.key"
MUNDO_CA_CLIENT_CERT_FILE="$MUNDO_CA_DIR/client.crt"
MUNDO_CA_CLIENT_KEYPAIR_FILE="$MUNDO_CA_DIR/client-keypair.b64"
MUNDO_CA_CLIENT_PUBLIC_KEY_FILE="$MUNDO_CA_DIR/client-public-key.b64"
MUNDO_CA_CLIENT_CERT_B64_FILE="$MUNDO_CA_DIR/client-certificate.b64"
MUNDO_CA_ROOT_CERT_B64_FILE="$MUNDO_CA_DIR/root-ca-certificate.b64"
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
NODE_DIR="$APP_DIR/nodes"
URI_DIR="$APP_DIR/uris"
NGINX_CONF_FILE="/etc/nginx/conf.d/mundoproxy.conf"
BRUTAL_PROFILE_FILE="$APP_DIR/brutal.env"
TCP_BRUTAL_URL="${TCP_BRUTAL_URL:-https://tcp.hy2.sh/}"
TCP_BRUTAL_REPO="${TCP_BRUTAL_REPO:-https://github.com/apernet/tcp-brutal.git}"
TCP_BRUTAL_SRC_DIR="${TCP_BRUTAL_SRC_DIR:-/usr/local/src/tcp-brutal}"
MUNDO_BRUTAL_REPO="${MUNDO_BRUTAL_REPO:-https://github.com/Mundo-Connect/Mundo-Brutal.git}"
MUNDO_BRUTAL_SRC_DIR="${MUNDO_BRUTAL_SRC_DIR:-/usr/local/src/mundo-brutal}"

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

kernel_headers_ready() {
    local rel
    rel="$(uname -r)"
    [ -e "/lib/modules/$rel/build/Makefile" ] ||
    [ -d "/usr/src/kernels/$rel" ] ||
    [ -d "/usr/src/linux-headers-$rel" ]
}

apt_install_one_of() {
    local pkg
    for pkg in "$@"; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" && return 0
    done
    return 1
}

ensure_kernel_headers() {
    kernel_headers_ready && return 0
    local manager rel
    manager="$(detect_pkg_manager)"
    rel="$(uname -r)"
    warn "未检测到当前内核 headers/build 目录，尝试安装: $rel"
    case "$manager" in
        apt)
            apt-get update -y || true
            apt_install_one_of "linux-headers-$rel" linux-headers-amd64 linux-headers-generic || true
            ;;
        dnf)
            dnf install -y "kernel-devel-$rel" kernel-headers || dnf install -y kernel-devel kernel-headers || true
            ;;
        yum)
            yum install -y "kernel-devel-$rel" kernel-headers || yum install -y kernel-devel kernel-headers || true
            ;;
        apk)
            apk add --no-cache linux-headers "$(alpine_kernel_dev_package)" || true
            ;;
    esac
    kernel_headers_ready
}

alpine_kernel_dev_package() {
    local rel flavor
    rel="$(uname -r)"
    flavor="${rel##*-}"
    [ -n "$flavor" ] && [ "$flavor" != "$rel" ] || flavor="lts"
    printf "linux-%s-dev" "$flavor"
}

install_alpine_build_deps() {
    apk add --no-cache git make clang kmod linux-headers musl-dev "$(alpine_kernel_dev_package)" ||
    apk add --no-cache git make clang kmod linux-headers musl-dev
}

update_git_source() {
    local repo="$1"
    local dir="$2"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" pull --ff-only
        return $?
    fi
    mkdir -p "$(dirname "$dir")"
    git clone --depth 1 "$repo" "$dir"
}

install_module_from_source() {
    local dir="$1"
    local module module_name target_dir
    make -C "$dir" clean >/dev/null 2>&1 || true
    make -C "$dir" || return 1
    make -C "$dir" install || {
        module="$(find "$dir" -type f -name '*.ko' 2>/dev/null | head -n 1)"
        [ -n "$module" ] || return 1
        target_dir="/lib/modules/$(uname -r)/extra"
        mkdir -p "$target_dir"
        install -m 644 "$module" "$target_dir/$(basename "$module")"
    }
    depmod -a 2>/dev/null || true
    module="$(find "$dir" "/lib/modules/$(uname -r)" -type f -name '*.ko*' 2>/dev/null | head -n 1)"
    [ -n "$module" ] || return 1
    module_name="$(basename "$module")"
    module_name="${module_name%%.ko*}"
    mkdir -p /etc/modules-load.d
    echo "$module_name" > "/etc/modules-load.d/$module_name.conf"
    touch /etc/modules
    grep -qxF "$module_name" /etc/modules || echo "$module_name" >> /etc/modules
    modprobe "$module_name" 2>/dev/null || insmod "$module" 2>/dev/null || true
}

install_mundo_brutal() {
    local manager
    manager="$(detect_pkg_manager)"
    if [ "$manager" = "apk" ]; then
        install_alpine_build_deps || return 1
    else
        ensure_kernel_headers || return 1
        command -v git >/dev/null 2>&1 || case "$manager" in
            apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y git ;;
            dnf) dnf install -y git ;;
            yum) yum install -y git ;;
        esac
        command -v make >/dev/null 2>&1 || case "$manager" in
            apt) DEBIAN_FRONTEND=noninteractive apt-get install -y make gcc ;;
            dnf) dnf install -y make gcc ;;
            yum) yum install -y make gcc ;;
        esac
    fi
    update_git_source "$MUNDO_BRUTAL_REPO" "$MUNDO_BRUTAL_SRC_DIR" &&
    install_module_from_source "$MUNDO_BRUTAL_SRC_DIR"
}

install_tcp_brutal() {
    local manager
    manager="$(detect_pkg_manager)"
    if [ "$manager" = "apk" ]; then
        install_alpine_build_deps &&
        update_git_source "$TCP_BRUTAL_REPO" "$TCP_BRUTAL_SRC_DIR" &&
        install_module_from_source "$TCP_BRUTAL_SRC_DIR"
        return $?
    fi
    ensure_kernel_headers || return 1
    command -v curl >/dev/null 2>&1 || case "$manager" in
        apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ;;
        dnf) dnf install -y curl ;;
        yum) yum install -y curl ;;
    esac
    bash <(curl -fsSL "$TCP_BRUTAL_URL")
}

write_brutal_profile() {
    local enabled="$1"
    local mbps="$2"
    mkdir -p "$APP_DIR"
    cat > "$BRUTAL_PROFILE_FILE" <<EOF
BRUTAL_ENABLED='$enabled'
BRUTAL_MBPS='$mbps'
EOF
    chmod 600 "$BRUTAL_PROFILE_FILE"
}

load_brutal_profile() {
    BRUTAL_ENABLED=0
    BRUTAL_MBPS=100
    [ -f "$BRUTAL_PROFILE_FILE" ] && . "$BRUTAL_PROFILE_FILE"
}

core_brutal_args() {
    load_brutal_profile
    [ "${BRUTAL_ENABLED:-0}" = "1" ] || return 0
    printf " -brutal %s" "${BRUTAL_MBPS:-100}"
}

configure_brutal() {
    require_root
    say "${blue}Brutal 配置${none}"
    say "  1) 安装 Mundo X Brutal 并启用"
    say "  2) 安装 TCP Brutal 并启用"
    say "  3) 只启用核心 brutal 参数"
    say "  4) 禁用"
    say "  0) 取消"
    local choice mbps
    read -r -p "请选择 [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        1)
            install_mundo_brutal || warn "Mundo X Brutal 安装失败，仍会保存配置，核心启动时会探测，不支持则自动禁用。"
            ;;
        2)
            install_tcp_brutal || warn "TCP Brutal 安装失败，仍会保存配置，核心启动时会探测，不支持则自动禁用。"
            ;;
        3)
            ;;
        4)
            write_brutal_profile 0 100
            ok "Brutal 已禁用。"
            restart_service_quiet
            return 0
            ;;
        0)
            return 0
            ;;
        *)
            warn "无效选择。"
            return 0
            ;;
    esac
    mbps="$(prompt_default "速率 Mbps" "100")"
    [[ "$mbps" =~ ^[0-9]+$ ]] || err "Mbps 必须是数字。"
    [ "$mbps" -gt 0 ] || mbps=100
    write_brutal_profile 1 "$mbps"
    ok "Brutal 已启用: ${mbps}Mbps。核心启动时会自动探测 mundo/brutal，支持才生效。"
    restart_service_quiet
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

yes_no_default_yes() {
    local prompt="$1"
    local value
    read -r -p "$prompt [Y/n]: " value
    case "$value" in
        n|N|no|NO) return 1 ;;
        *) return 0 ;;
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

base64_one_line() {
    openssl base64 -A
}

normalize_base64_value() {
    local value="$1"
    value="$(printf "%s" "$value" | tr -d '[:space:]')"
    [ -n "$value" ] || return 1
    case $((${#value} % 4)) in
        0) ;;
        2) value="${value}==" ;;
        3) value="${value}=" ;;
        *) return 1 ;;
    esac
    printf "%s" "$value"
}

hex_to_stream() {
    local hex="$1"
    local escaped=""
    local i
    [ $((${#hex} % 2)) -eq 0 ] || return 1
    for ((i = 0; i < ${#hex}; i += 2)); do
        escaped="$escaped\\x${hex:i:2}"
    done
    printf "%b" "$escaped"
}

hex_to_base64() {
    hex_to_stream "$1" | base64_one_line
}

hex_to_file() {
    hex_to_stream "$1" > "$2"
}

base64_to_hex() {
    local value
    value="$(normalize_base64_value "$1")" || return 1
    printf "%s" "$value" | openssl base64 -d -A 2>/dev/null | od -An -tx1 -v | tr -d ' \n'
}

cert_file_to_base64_der() {
    openssl x509 -in "$1" -outform DER | base64_one_line
}

json_host_field() {
    local host="$1"
    local indent="${2:-6}"
    local spaces
    is_ip_address "$host" && return 0
    spaces="$(printf "%*s" "$indent" "")"
    printf ',\n%s"host": "%s"' "$spaces" "$host"
}

json_authority_field() {
    local host="$1"
    local indent="${2:-6}"
    local spaces
    is_ip_address "$host" && return 0
    spaces="$(printf "%*s" "$indent" "")"
    printf ',\n%s"authority": "%s"' "$spaces" "$host"
}

json_mundo_ca_field() {
    local ca_cert="$1"
    local indent="${2:-6}"
    local spaces
    [ -n "$ca_cert" ] || return 0
    spaces="$(printf "%*s" "$indent" "")"
    printf ',\n%s"mundoCA": {\n%s  "caCertificate": "%s"\n%s}' "$spaces" "$spaces" "$ca_cert" "$spaces"
}

is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

mundo_ca_supported_protocol() {
    case "$1" in
        mx|trojan|vless|vmess|anytls) return 0 ;;
        *) return 1 ;;
    esac
}

mundo_ca_supported_transport() {
    case "$1" in
        mc1|mundordp|mundosql|xhttp|grpc|websocket) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_openssl_sm2() {
    command -v openssl >/dev/null 2>&1 || err "未找到 openssl，无法生成 MundoCA。"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if ! openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:SM2 -out "$tmp_dir/sm2.key" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        err "当前 OpenSSL 不支持 SM2，请升级到支持 SM2 的 OpenSSL 后重试。"
    fi
    rm -rf "$tmp_dir"
}

extract_sm2_private_hex() {
    local key_file="$1"
    openssl pkey -in "$key_file" -text -noout 2>/dev/null | awk '
        /^[[:space:]]*priv:/ { mode = "priv"; next }
        /^[[:space:]]*pub:/ { mode = ""; next }
        mode == "priv" {
            gsub(/[^0-9A-Fa-f]/, "", $0)
            printf "%s", $0
        }
    '
}

extract_sm2_public_hex() {
    local key_file="$1"
    openssl pkey -in "$key_file" -text -noout 2>/dev/null | awk '
        /^[[:space:]]*pub:/ { mode = "pub"; next }
        /^[[:space:]]*ASN1 OID:/ { mode = ""; next }
        mode == "pub" {
            gsub(/[^0-9A-Fa-f]/, "", $0)
            printf "%s", $0
        }
    '
}

validate_sm2_public_hex() {
    local hex="$1"
    [ "${#hex}" -eq 130 ] || return 1
    [ "${hex:0:2}" = "04" ] || return 1
    [[ "$hex" =~ ^[0-9A-Fa-f]+$ ]]
}

write_sm2_public_spki_der() {
    local public_hex="$1"
    local out_file="$2"
    local spki_hex
    validate_sm2_public_hex "$public_hex" || return 1
    spki_hex="3059301306072A8648CE3D020106082A811CCF5501822D034200${public_hex}"
    [ $(( ${#spki_hex} / 2 )) -eq 91 ] || return 1
    hex_to_file "$spki_hex" "$out_file"
}

ensure_mundo_ca_root() {
    ensure_openssl_sm2
    mkdir -p "$MUNDO_CA_DIR"
    chmod 700 "$MUNDO_CA_DIR"
    if [ -s "$MUNDO_CA_ROOT_KEY_FILE" ] && [ -s "$MUNDO_CA_ROOT_CERT_FILE" ]; then
        return 0
    fi
    rm -f "$MUNDO_CA_ROOT_KEY_FILE" "$MUNDO_CA_ROOT_CERT_FILE" "$MUNDO_CA_ROOT_SERIAL_FILE"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:SM2 -out "$MUNDO_CA_ROOT_KEY_FILE" >/dev/null 2>&1 || err "MundoCA Root 私钥生成失败。"
    openssl req -new -x509 -sm3 -days 3650 \
        -key "$MUNDO_CA_ROOT_KEY_FILE" \
        -out "$MUNDO_CA_ROOT_CERT_FILE" \
        -subj "/CN=MundoCA Root" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,digitalSignature" >/dev/null 2>&1 || err "MundoCA Root 证书生成失败。"
    chmod 600 "$MUNDO_CA_ROOT_KEY_FILE"
}

generate_sm2_client_key() {
    rm -f "$MUNDO_CA_CLIENT_KEY_FILE"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:SM2 -out "$MUNDO_CA_CLIENT_KEY_FILE" >/dev/null 2>&1 || err "客户端 SM2 私钥生成失败。"
    chmod 600 "$MUNDO_CA_CLIENT_KEY_FILE"
}

issue_mundo_ca_client_certificate_from_key() {
    local key_file="$1"
    local csr_file="$MUNDO_CA_DIR/client.csr"
    local ext_file="$MUNDO_CA_DIR/client.ext"
    rm -f "$csr_file" "$ext_file" "$MUNDO_CA_CLIENT_CERT_FILE"
    openssl req -new -key "$key_file" -out "$csr_file" -subj "/CN=MundoCA Client" >/dev/null 2>&1 || err "客户端证书请求生成失败。"
    printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n" > "$ext_file"
    openssl x509 -req -in "$csr_file" \
        -CA "$MUNDO_CA_ROOT_CERT_FILE" \
        -CAkey "$MUNDO_CA_ROOT_KEY_FILE" \
        -CAcreateserial \
        -out "$MUNDO_CA_CLIENT_CERT_FILE" \
        -days 365 -sm3 \
        -extfile "$ext_file" >/dev/null 2>&1 || err "客户端 SM2 证书签发失败。"
    rm -f "$csr_file" "$ext_file"
}

issue_mundo_ca_client_certificate_from_public() {
    local public_hex="$1"
    local pub_der="$MUNDO_CA_DIR/client-public.der"
    local pub_pem="$MUNDO_CA_DIR/client-public.pem"
    local csr_conf="$MUNDO_CA_DIR/client-public.cnf"
    local csr_file="$MUNDO_CA_DIR/client-public.csr"
    local ext_file="$MUNDO_CA_DIR/client-public.ext"
    write_sm2_public_spki_der "$public_hex" "$pub_der" || err "公钥必须是 65 字节非压缩 SM2 公钥。"
    openssl pkey -pubin -inform DER -in "$pub_der" -out "$pub_pem" >/dev/null 2>&1 || err "公钥解析失败，请确认是 SM2 非压缩公钥。"
    cat > "$csr_conf" <<EOF
[ req ]
distinguished_name = dn
prompt = no

[ dn ]
CN = MundoCA Client
EOF
    openssl req -new -config "$csr_conf" -key "$MUNDO_CA_ROOT_KEY_FILE" -subj "/CN=MundoCA Client" -out "$csr_file" >/dev/null 2>&1 || err "客户端证书请求生成失败。"
    printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n" > "$ext_file"
    openssl x509 -req -in "$csr_file" \
        -force_pubkey "$pub_pem" \
        -CA "$MUNDO_CA_ROOT_CERT_FILE" \
        -CAkey "$MUNDO_CA_ROOT_KEY_FILE" \
        -CAcreateserial \
        -out "$MUNDO_CA_CLIENT_CERT_FILE" \
        -days 365 -sm3 \
        -extfile "$ext_file" >/dev/null 2>&1 || err "客户端 SM2 证书签发失败。"
    rm -f "$pub_der" "$pub_pem" "$csr_conf" "$csr_file" "$ext_file"
}

choose_mundo_ca_auth() {
    local protocol="$1"
    local transport="$2"
    CA_ENABLED=0
    CA_CERT_B64=""
    CLIENT_CERT_B64=""
    CLIENT_PRIVATE_KEY_B64=""
    CLIENT_PUBLIC_KEY_B64=""
    CLIENT_KEYPAIR_B64=""
    CLIENT_KEYPAIR_GENERATED=0

    mundo_ca_supported_protocol "$protocol" && mundo_ca_supported_transport "$transport" || return 0

    say ""
    say "${cyan}认证方式${none}"
    say "默认使用 UUID/token/password。启用 MundoCA 后，节点只校验证书，不再使用 UUID/token/password 作为用户认证。"
    if ! yes_no_default_no "启用 MundoCA 证书式认证"; then
        return 0
    fi

    CA_ENABLED=1
    ensure_mundo_ca_root

    if yes_no_default_yes "一键生成客户端 SM2 公私钥和证书"; then
        generate_sm2_client_key
        local private_hex public_hex
        private_hex="$(extract_sm2_private_hex "$MUNDO_CA_CLIENT_KEY_FILE")"
        public_hex="$(extract_sm2_public_hex "$MUNDO_CA_CLIENT_KEY_FILE")"
        [ "${#private_hex}" -eq 64 ] || err "客户端私钥提取失败。"
        validate_sm2_public_hex "$public_hex" || err "客户端公钥提取失败。"
        issue_mundo_ca_client_certificate_from_key "$MUNDO_CA_CLIENT_KEY_FILE"
        CLIENT_PRIVATE_KEY_B64="$(hex_to_base64 "$private_hex")"
        CLIENT_PUBLIC_KEY_B64="$(hex_to_base64 "$public_hex")"
        CLIENT_KEYPAIR_B64="$(hex_to_base64 "${private_hex}${public_hex}")"
        CLIENT_KEYPAIR_GENERATED=1
    else
        local public_key_value public_hex
        read -r -p "客户端非压缩 SM2 公钥 Base64（65 字节，0x04 开头）: " public_key_value
        public_hex="$(base64_to_hex "$public_key_value")" || err "公钥 Base64 无效。"
        validate_sm2_public_hex "$public_hex" || err "公钥必须是 65 字节非压缩 SM2 公钥。"
        issue_mundo_ca_client_certificate_from_public "$public_hex"
        CLIENT_PUBLIC_KEY_B64="$(hex_to_base64 "$public_hex")"
    fi

    CA_CERT_B64="$(cert_file_to_base64_der "$MUNDO_CA_ROOT_CERT_FILE")"
    CLIENT_CERT_B64="$(cert_file_to_base64_der "$MUNDO_CA_CLIENT_CERT_FILE")"
    [ -n "$CA_CERT_B64" ] || err "Root CA 证书导出失败。"
    [ -n "$CLIENT_CERT_B64" ] || err "客户端证书导出失败。"
    printf "%s\n" "$CA_CERT_B64" > "$MUNDO_CA_ROOT_CERT_B64_FILE"
    printf "%s\n" "$CLIENT_CERT_B64" > "$MUNDO_CA_CLIENT_CERT_B64_FILE"
    [ -n "$CLIENT_PUBLIC_KEY_B64" ] && printf "%s\n" "$CLIENT_PUBLIC_KEY_B64" > "$MUNDO_CA_CLIENT_PUBLIC_KEY_FILE"
    [ -n "$CLIENT_KEYPAIR_B64" ] && printf "%s\n" "$CLIENT_KEYPAIR_B64" > "$MUNDO_CA_CLIENT_KEYPAIR_FILE"
    chmod 600 "$MUNDO_CA_DIR"/* 2>/dev/null || true
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
        "6"|"mundosql")
            echo "mundosql"
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
        err "只有 mx 支持 ws、grpc、xhttp、mundosql；$CHOSEN_PROTOCOL 只能使用 mc1 或 mundordp。"
    }
}

transport_display_name() {
    case "$1" in
        mc1) echo "mc1" ;;
        mundordp) echo "mundordp" ;;
        xhttp) echo "xhttp" ;;
        grpc) echo "grpc" ;;
        websocket) echo "ws" ;;
        mundosql) echo "mundosql" ;;
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
        mundosql) name="$protocol-mundosql" ;;
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
        mundosql) echo "3306" ;;
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
    say "  mundosql (MundoSQL，仅 mx，默认端口 3306)"
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
    mkdir -p "$APP_DIR" "$BIN_DIR" "$SH_DIR/src" "$CERT_DIR" "$LOG_DIR" "$NODE_DIR" "$URI_DIR"
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
    local cert_file="${2:-$CERT_FILE}"
    local key_file="${3:-$KEY_FILE}"
    if is_ip_address "$host"; then
        cat <<EOF
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "$cert_file",
          "keyFile": "$key_file"
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
          "certificateFile": "$cert_file",
          "keyFile": "$key_file"
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
    local reverse_proxy="$5"
    local ca_cert="${6:-}"
    local password="${7:-}"
    local cert_file="${8:-$CERT_FILE}"
    local key_file="${9:-$KEY_FILE}"
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
$(render_tls_settings "$host" "$cert_file" "$key_file"),
    "mc1Settings": {
      "path": "$path"$(json_host_field "$host" 6),
      "mode": "$mc1_mode",
      "disableH3Upload": $mc1_disable_h3$(json_mundo_ca_field "$ca_cert" 6)
    }
  }
EOF
            ;;
        mundordp)
            cat <<EOF
{
    "network": "mundordp",
$(render_tls_settings "$host" "$cert_file" "$key_file"),
    "mundordpSettings": {
      "username": "$username",
      "useTLSCertificate": true$(json_mundo_ca_field "$ca_cert" 6)
    }
  }
EOF
            ;;
        mundosql)
            cat <<EOF
{
    "network": "mundosql",
$(render_tls_settings "$host" "$cert_file" "$key_file"),
    "mundosqlSettings": {
      "username": "$username",
      "password": "$password",
      "database": "app",
      "connections": 1$(json_mundo_ca_field "$ca_cert" 6)
    }
  }
EOF
            ;;
        xhttp)
            cat <<EOF
{
    "network": "xhttp",
$(render_tls_settings "$host" "$cert_file" "$key_file"),
    "xhttpSettings": {
      "path": "$path"$(json_host_field "$host" 6),
      "mode": "auto"$(json_mundo_ca_field "$ca_cert" 6)
    }
  }
EOF
            ;;
        grpc)
            cat <<EOF
{
    "network": "grpc",
$(render_tls_settings "$host" "$cert_file" "$key_file"),
    "grpcSettings": {
      "serviceName": "$service_name"$(json_authority_field "$host" 6),
      "multiMode": true,
      "idle_timeout": 0,
      "health_check_timeout": 0,
      "permit_without_stream": false,
      "initial_windows_size": 0$(json_mundo_ca_field "$ca_cert" 6)
    }
  }
EOF
            ;;
        websocket)
            cat <<EOF
{
    "network": "websocket",
$(render_tls_settings "$host" "$cert_file" "$key_file"),
    "wsSettings": {
      "path": "$path"$(json_host_field "$host" 6)$(json_mundo_ca_field "$ca_cert" 6)
    }
  }
EOF
            ;;
    esac
}

render_inbound_json() {
    local protocol="$1"
    local transport="$2"
    local port="$3"
    local token="$4"
    local host="$5"
    local path="$6"
    local username="$7"
    local listen_addr="$8"
    local reverse_proxy="${9}"
    local ca_enabled="${10:-0}"
    local ca_cert="${11:-}"
    local cert_file="${12:-$CERT_FILE}"
    local key_file="${13:-$KEY_FILE}"
    local tag="${14:-$protocol-$transport}"
    local stream_settings
    local inbound_settings
    stream_settings="$(render_stream_settings "$transport" "$host" "$path" "$username" "$reverse_proxy" "$ca_cert" "$token" "$cert_file" "$key_file")"
    inbound_settings="$(render_inbound_settings "$protocol" "$token" "$ca_enabled")"

    cat <<EOF
    {
      "tag": "$tag",
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
EOF
}

write_config() {
    local protocol="$1"
    local transport="$2"
    local port="$3"
    local token="$4"
    local host="$5"
    local path="$6"
    local username="$7"
    local listen_addr="$8"
    local reverse_proxy="${9}"
    local ca_enabled="${10:-0}"
    local ca_cert="${11:-}"

    ensure_dirs
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "access": "$ACCESS_LOG",
    "error": "$ERROR_LOG",
    "loglevel": "warning"
  },
  "inbounds": [
$(render_inbound_json "$protocol" "$transport" "$port" "$token" "$host" "$path" "$username" "$listen_addr" "$reverse_proxy" "$ca_enabled" "$ca_cert" "$CERT_FILE" "$KEY_FILE" "$protocol-$transport")
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
    local ca_enabled="${3:-0}"
    if [ "$ca_enabled" = "1" ]; then
        case "$protocol" in
            mx)
                cat <<EOF
{
        "users": []
      }
EOF
                ;;
            trojan|vless|vmess)
                cat <<EOF
{
        "clients": []$( [ "$protocol" = "vless" ] && printf ',\n        "decryption": "none"' )
      }
EOF
                ;;
            anytls)
                cat <<EOF
{
        "users": [
          {
            "password": "$(random_hex 16)"
          }
        ]
      }
EOF
                ;;
        esac
        return 0
    fi
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
    local ech_mode="$9"
    local reverse_proxy="${10}"
    local external_port="${11}"
    local core_port="${12}"
    local cdn_enabled="${13:-0}"
    local ca_enabled="${14:-0}"
    local ca_cert_b64="${15:-}"
    local client_cert_b64="${16:-}"
    local client_public_key_b64="${17:-}"
    local client_keypair_file="${18:-}"
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
ECH_MODE='$ech_mode'
REVERSE_PROXY='$reverse_proxy'
CDN_ENABLED='$cdn_enabled'
CA_ENABLED='$ca_enabled'
MUNDO_CA_CERTIFICATE='$ca_cert_b64'
MUNDO_CA_CLIENT_CERTIFICATE='$client_cert_b64'
MUNDO_CA_CLIENT_PUBLIC_KEY='$client_public_key_b64'
MUNDO_CA_CLIENT_KEYPAIR_FILE='$client_keypair_file'
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
    local client_cert="${11:-}"
    local uri_type
    uri_type="$(uri_transport_name "$transport")"
    local mc1_mode="auto"
    if [ "$transport" = "mc1" ] && [ "$reverse_proxy" = "1" ]; then
        mc1_mode="h2"
    fi

    local query="security=tls&type=$(url_encode "$uri_type")&encryption=none"
    if [ "$transport" != "mundosql" ]; then
        query="$query&fp=chrome"
    fi
    if [ "$transport" != "mundosql" ] && ! is_ip_address "$server_host"; then
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
        mundosql)
            query="$query&username=$(url_encode "$username")"
            ;;
    esac

    if [ "$ech_mode" != "off" ]; then
        query="$query&echMode=$(url_encode "$ech_mode")"
    else
        query="$query&echMode=off"
    fi
    if [ -n "$client_cert" ]; then
        query="$query&mundoCA=$(url_encode "$client_cert")"
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
    local client_cert="${11:-}"
    build_client_uri "$protocol" "$transport" "$port" "$token" "$connect_host" "$server_host" "$path" "$username" "$ech_mode" "$reverse_proxy" "$client_cert" > "$CLIENT_URI_FILE"
    chmod 600 "$CLIENT_URI_FILE"
}

write_client_uris_to_files() {
    local normal_file="$1"
    local ech_file="$2"
    local protocol="$3"
    local transport="$4"
    local port="$5"
    local token="$6"
    local connect_host="$7"
    local server_host="$8"
    local path="$9"
    local username="${10}"
    local reverse_proxy="${11:-0}"
    local client_cert="${12:-}"
    mkdir -p "$(dirname "$normal_file")" "$(dirname "$ech_file")"
    build_client_uri "$protocol" "$transport" "$port" "$token" "$connect_host" "$server_host" "$path" "$username" "off" "$reverse_proxy" "$client_cert" > "$normal_file"
    chmod 600 "$normal_file"
    if ech_capable_transport "$protocol" "$transport" && ! is_ip_address "$server_host"; then
        build_client_uri "$protocol" "$transport" "$port" "$token" "$connect_host" "$server_host" "$path" "$username" "always" "$reverse_proxy" "$client_cert" > "$ech_file"
        chmod 600 "$ech_file"
    else
        rm -f "$ech_file"
    fi
}

write_client_uris() {
    write_client_uris_to_files "$CLIENT_URI_FILE" "$CLIENT_URI_ECH_FILE" "$@"
}

sanitize_node_id() {
    local value="$1"
    value="$(printf "%s" "$value" | tr -cd 'A-Za-z0-9._-')"
    [ -n "$value" ] || value="node"
    printf "%s" "$value"
}

node_profile_path() {
    printf "%s/%s.env" "$NODE_DIR" "$(sanitize_node_id "$1")"
}

node_uri_path() {
    printf "%s/%s.uri" "$URI_DIR" "$(sanitize_node_id "$1")"
}

node_ech_uri_path() {
    printf "%s/%s-ech.uri" "$URI_DIR" "$(sanitize_node_id "$1")"
}

unique_node_id() {
    local base
    local id
    local index=2
    base="$(sanitize_node_id "$1-$2-$3")"
    id="$base"
    while [ -f "$(node_profile_path "$id")" ]; do
        id="$base-$index"
        index=$((index + 1))
    done
    printf "%s" "$id"
}

collect_node_files() {
    NODE_FILES=()
    local file
    for file in "$NODE_DIR"/*.env; do
        [ -f "$file" ] || continue
        NODE_FILES+=("$file")
    done
}

node_profile_count() {
    collect_node_files
    printf "%s" "${#NODE_FILES[@]}"
}

source_node_profile() {
    local file="$1"
    NODE_ID=""
    PROTOCOL="mx"
    TRANSPORT=""
    PORT=""
    CORE_PORT=""
    TOKEN=""
    HOST=""
    CLIENT_HOST=""
    PATH_VALUE="/"
    RDP_USERNAME="Administrator"
    REVERSE_PROXY="0"
    CDN_ENABLED="0"
    CA_ENABLED="0"
    MUNDO_CA_CERTIFICATE=""
    MUNDO_CA_CLIENT_CERTIFICATE=""
    MUNDO_CA_CLIENT_PUBLIC_KEY=""
    MUNDO_CA_CLIENT_KEYPAIR_FILE=""
    LISTEN_ADDR="0.0.0.0"
    NODE_CERT_FILE="$CERT_FILE"
    NODE_KEY_FILE="$KEY_FILE"
    NODE_URI_FILE=""
    NODE_ECH_URI_FILE=""
    TAG=""
    # shellcheck disable=SC1090
    . "$file"
    NODE_ID="${NODE_ID:-$(basename "$file" .env)}"
    CLIENT_HOST="${CLIENT_HOST:-$HOST}"
    TAG="${TAG:-$NODE_ID}"
    NODE_CERT_FILE="${NODE_CERT_FILE:-$CERT_FILE}"
    NODE_KEY_FILE="${NODE_KEY_FILE:-$KEY_FILE}"
    NODE_URI_FILE="${NODE_URI_FILE:-$(node_uri_path "$NODE_ID")}"
    NODE_ECH_URI_FILE="${NODE_ECH_URI_FILE:-$(node_ech_uri_path "$NODE_ID")}"
}

write_node_profile() {
    local node_id="$1"
    local protocol="$2"
    local transport="$3"
    local external_port="$4"
    local core_port="$5"
    local token="$6"
    local host="$7"
    local client_host="$8"
    local path="$9"
    local username="${10}"
    local reverse_proxy="${11}"
    local cdn_enabled="${12:-0}"
    local ca_enabled="${13:-0}"
    local ca_cert_b64="${14:-}"
    local client_cert_b64="${15:-}"
    local client_public_key_b64="${16:-}"
    local client_keypair_file="${17:-}"
    local listen_addr="${18:-0.0.0.0}"
    local cert_file="${19:-$CERT_FILE}"
    local key_file="${20:-$KEY_FILE}"
    local normal_uri_file="${21:-$(node_uri_path "$node_id")}"
    local ech_uri_file="${22:-$(node_ech_uri_path "$node_id")}"
    local tag
    tag="$(sanitize_node_id "$node_id")"
    mkdir -p "$NODE_DIR" "$URI_DIR"
    cat > "$(node_profile_path "$node_id")" <<EOF
NODE_ID='$tag'
TAG='$tag'
PROTOCOL='$protocol'
TRANSPORT='$transport'
PORT='$external_port'
CORE_PORT='$core_port'
TOKEN='$token'
HOST='$host'
CLIENT_HOST='$client_host'
PATH_VALUE='$path'
RDP_USERNAME='$username'
REVERSE_PROXY='$reverse_proxy'
CDN_ENABLED='$cdn_enabled'
CA_ENABLED='$ca_enabled'
MUNDO_CA_CERTIFICATE='$ca_cert_b64'
MUNDO_CA_CLIENT_CERTIFICATE='$client_cert_b64'
MUNDO_CA_CLIENT_PUBLIC_KEY='$client_public_key_b64'
MUNDO_CA_CLIENT_KEYPAIR_FILE='$client_keypair_file'
LISTEN_ADDR='$listen_addr'
NODE_CERT_FILE='$cert_file'
NODE_KEY_FILE='$key_file'
NODE_URI_FILE='$normal_uri_file'
NODE_ECH_URI_FILE='$ech_uri_file'
EOF
    chmod 600 "$(node_profile_path "$node_id")"
}

migrate_profile_to_nodes() {
    ensure_dirs
    [ "$(node_profile_count)" -gt 0 ] && return 0
    [ -f "$PROFILE_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$PROFILE_FILE"
    local protocol="${PROTOCOL:-mx}"
    local transport="${TRANSPORT:-mc1}"
    local external_port="${PORT:-${CORE_PORT:-443}}"
    local core_port="${CORE_PORT:-$external_port}"
    local token="${TOKEN:-}"
    local host="${HOST:-apple.com}"
    local client_host="${CLIENT_HOST:-$host}"
    local path="${PATH_VALUE:-/}"
    local username="${RDP_USERNAME:-Administrator}"
    local reverse_proxy="${REVERSE_PROXY:-0}"
    local cdn_enabled="${CDN_ENABLED:-0}"
    local ca_enabled="${CA_ENABLED:-0}"
    local listen_addr="0.0.0.0"
    local node_id
    [ "$reverse_proxy" = "1" ] && listen_addr="127.0.0.1"
    node_id="$(unique_node_id "$protocol" "$transport" "$external_port")"
    write_node_profile "$node_id" "$protocol" "$transport" "$external_port" "$core_port" "$token" "$host" "$client_host" "$path" "$username" "$reverse_proxy" "$cdn_enabled" "$ca_enabled" "${MUNDO_CA_CERTIFICATE:-}" "${MUNDO_CA_CLIENT_CERTIFICATE:-}" "${MUNDO_CA_CLIENT_PUBLIC_KEY:-}" "${MUNDO_CA_CLIENT_KEYPAIR_FILE:-}" "$listen_addr" "$CERT_FILE" "$KEY_FILE" "$(node_uri_path "$node_id")" "$(node_ech_uri_path "$node_id")"
    [ -f "$CLIENT_URI_FILE" ] && cp "$CLIENT_URI_FILE" "$(node_uri_path "$node_id")"
    [ -f "$CLIENT_URI_ECH_FILE" ] && cp "$CLIENT_URI_ECH_FILE" "$(node_ech_uri_path "$node_id")"
}

write_config_from_nodes() {
    ensure_dirs
    collect_node_files
    [ "${#NODE_FILES[@]}" -gt 0 ] || return 1
    {
        cat <<EOF
{
  "log": {
    "access": "$ACCESS_LOG",
    "error": "$ERROR_LOG",
    "loglevel": "warning"
  },
  "inbounds": [
EOF
        local first=1
        local file
        for file in "${NODE_FILES[@]}"; do
            source_node_profile "$file"
            if [ "$first" -eq 0 ]; then
                printf ",\n"
            fi
            render_inbound_json "$PROTOCOL" "$TRANSPORT" "$CORE_PORT" "$TOKEN" "$HOST" "$PATH_VALUE" "$RDP_USERNAME" "$LISTEN_ADDR" "$REVERSE_PROXY" "$CA_ENABLED" "$MUNDO_CA_CERTIFICATE" "$NODE_CERT_FILE" "$NODE_KEY_FILE" "$TAG"
            first=0
        done
        cat <<EOF

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
    } > "$CONFIG_FILE"
}

listen_conflicts_existing_node() {
    local listen_addr="$1"
    local core_port="$2"
    collect_node_files
    local file
    for file in "${NODE_FILES[@]}"; do
        source_node_profile "$file"
        [ "$LISTEN_ADDR" = "$listen_addr" ] && [ "$CORE_PORT" = "$core_port" ] && return 0
    done
    return 1
}

nginx_location_path() {
    local transport="$1"
    local path="$2"
    case "$transport" in
        grpc) echo "/" ;;
        *) echo "$path" ;;
    esac
}

nginx_server_name() {
    local host="$1"
    if is_domain_name "$host"; then
        printf "%s" "$host"
    else
        printf "_"
    fi
}

nginx_group_exists() {
    local key="$1"
    local item
    for item in "${NGINX_GROUPS[@]}"; do
        [ "$item" = "$key" ] && return 0
    done
    return 1
}

write_all_nginx_config() {
    migrate_profile_to_nodes
    collect_node_files
    NGINX_GROUPS=()
    local has_reverse_proxy=0
    local has_websocket=0
    local file
    for file in "${NODE_FILES[@]}"; do
        source_node_profile "$file"
        [ "$REVERSE_PROXY" = "1" ] || continue
        has_reverse_proxy=1
        [ "$TRANSPORT" = "websocket" ] && has_websocket=1
        local group_key="$PORT|$HOST|$NODE_CERT_FILE|$NODE_KEY_FILE"
        nginx_group_exists "$group_key" || NGINX_GROUPS+=("$group_key")
    done

    if [ "$has_reverse_proxy" -eq 0 ]; then
        remove_nginx_config
        return 0
    fi

    install_nginx
    mkdir -p "$(dirname "$NGINX_CONF_FILE")"
    {
        if [ "$has_websocket" -eq 1 ]; then
            cat <<EOF
map \$http_upgrade \$mundo_connection_upgrade {
    default upgrade;
    '' close;
}

EOF
        fi
        local group
        for group in "${NGINX_GROUPS[@]}"; do
            local group_port group_host group_cert group_key_file
            IFS='|' read -r group_port group_host group_cert group_key_file <<< "$group"
            cat <<EOF
server {
    listen $group_port ssl http2;
    server_name $(nginx_server_name "$group_host");

    ssl_certificate $group_cert;
    ssl_certificate_key $group_key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    client_max_body_size 0;

EOF
            local seen_locations=" "
            for file in "${NODE_FILES[@]}"; do
                source_node_profile "$file"
                [ "$REVERSE_PROXY" = "1" ] || continue
                [ "$PORT|$HOST|$NODE_CERT_FILE|$NODE_KEY_FILE" = "$group" ] || continue
                local location_path
                location_path="$(nginx_location_path "$TRANSPORT" "$PATH_VALUE")"
                case "$seen_locations" in
                    *" $location_path "*) err "Nginx 反代路径冲突: $group_host:$group_port $location_path" ;;
                esac
                seen_locations="$seen_locations$location_path "
                if [ "$TRANSPORT" = "grpc" ]; then
                    cat <<EOF
    location $location_path {
        grpc_pass grpcs://127.0.0.1:$CORE_PORT;
        grpc_ssl_server_name on;
        grpc_ssl_name $HOST;
        grpc_ssl_verify off;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
    }

EOF
                elif [ "$TRANSPORT" = "websocket" ]; then
                    cat <<EOF
    location ^~ $location_path {
        proxy_pass https://127.0.0.1:$CORE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$mundo_connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_server_name on;
        proxy_ssl_name $HOST;
        proxy_ssl_verify off;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

EOF
                else
                    cat <<EOF
    location ^~ $location_path {
        proxy_pass https://127.0.0.1:$CORE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_server_name on;
        proxy_ssl_name $HOST;
        proxy_ssl_verify off;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_hide_header Alt-Svc;
    }

EOF
                fi
            done
            cat <<EOF
}

EOF
        done
    } > "$NGINX_CONF_FILE"

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

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi
    return 1
}

port_owner_hint() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" {print; exit}'
        return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" {print; exit}'
        return 0
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n '2p'
        return 0
    fi
    return 0
}

configure() {
    require_root
    ensure_dirs

    local no_restart=0
    local append=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-restart) no_restart=1 ;;
            --append) append=1 ;;
        esac
        shift
    done

    if [ "$append" -eq 1 ]; then
        migrate_profile_to_nodes
        say "${blue}新增入站${none}"
    else
        say "${blue}生成配置${none}"
    fi

    local protocol
    local transport
    choose_protocol_transport
    protocol="$CHOSEN_PROTOCOL"
    transport="$CHOSEN_TRANSPORT"
    local ech_mode="off"
    local default_port
    default_port="$(default_port_for_transport "$transport")"
    choose_mundo_ca_auth "$protocol" "$transport"
    local external_port
    external_port="$(prompt_default "端口" "$default_port")"
    [[ "$external_port" =~ ^[0-9]+$ ]] || err "端口必须是数字。"
    [ "$external_port" -ge 1 ] && [ "$external_port" -le 65535 ] || err "端口范围必须是 1-65535。"
    local node_id
    if [ "$append" -eq 1 ]; then
        node_id="$(unique_node_id "$protocol" "$transport" "$external_port")"
        CERT_FILE="$CERT_DIR/$node_id.crt"
        KEY_FILE="$CERT_DIR/$node_id.key"
    else
        node_id="$(sanitize_node_id "$protocol-$transport-$external_port")"
        CERT_FILE="$CERT_DIR/server.crt"
        KEY_FILE="$CERT_DIR/server.key"
    fi

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
    if [ "$transport" != "mundordp" ] && [ "$transport" != "mundosql" ]; then
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
    if [ "$CA_ENABLED" = "1" ]; then
        token="$token_default"
        token_label="MundoCA"
    else
        token="$(prompt_default "$token_label" "$token_default")"
        token="$(printf "%s" "$token" | tr -cd 'A-Za-z0-9._~:/+=-')"
        [ -n "$token" ] || err "token 不能为空。"
        case "$protocol" in
            vless|vmess)
                is_uuid "$token" || err "$protocol 需要 UUID。"
                ;;
        esac
    fi

    local username="Administrator"
    if [ "$transport" = "mundordp" ]; then
        username="$(prompt_default "用户名" "Administrator")"
        username="$(printf "%s" "$username" | tr -cd 'A-Za-z0-9._@-')"
        [ -n "$username" ] || username="Administrator"
    elif [ "$transport" = "mundosql" ]; then
        username="$(prompt_default "数据库用户名" "mundouser")"
        username="$(printf "%s" "$username" | tr -cd 'A-Za-z0-9._@-')"
        [ -n "$username" ] || username="mundouser"
    fi

    local reverse_proxy=0
    local core_port="$external_port"
    local listen_addr="0.0.0.0"
    if [ "$transport" != "mundordp" ] && [ "$transport" != "mundosql" ]; then
        if [ "$external_port" = "443" ] && port_in_use 443; then
            warn "检测到 443 端口已有监听程序。"
            local owner
            owner="$(port_owner_hint 443)"
            [ -n "$owner" ] && warn "$owner"
        fi
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
    if [ "$append" -eq 1 ] && listen_conflicts_existing_node "$listen_addr" "$core_port"; then
        err "已有入站监听 $listen_addr:$core_port，请换一个端口。"
    fi

    local node_uri_file
    local node_ech_uri_file
    node_uri_file="$(node_uri_path "$node_id")"
    node_ech_uri_file="$(node_ech_uri_path "$node_id")"
    if [ "$append" -eq 0 ]; then
        rm -f "$NODE_DIR"/*.env "$URI_DIR"/*.uri
    fi
    write_node_profile "$node_id" "$protocol" "$transport" "$external_port" "$core_port" "$token" "$host" "$client_host" "$path" "$username" "$reverse_proxy" "$CDN_ENABLED" "$CA_ENABLED" "$CA_CERT_B64" "$CLIENT_CERT_B64" "$CLIENT_PUBLIC_KEY_B64" "$MUNDO_CA_CLIENT_KEYPAIR_FILE" "$listen_addr" "$CERT_FILE" "$KEY_FILE" "$node_uri_file" "$node_ech_uri_file"
    write_client_uris_to_files "$node_uri_file" "$node_ech_uri_file" "$protocol" "$transport" "$external_port" "$token" "$client_host" "$host" "$path" "$username" "$reverse_proxy" "$CLIENT_CERT_B64"
    write_config_from_nodes
    if [ "$append" -eq 0 ]; then
        write_profile "$protocol" "$transport" "$core_port" "$token" "$host" "$client_host" "$path" "$username" "$ech_mode" "$reverse_proxy" "$external_port" "$core_port" "$CDN_ENABLED" "$CA_ENABLED" "$CA_CERT_B64" "$CLIENT_CERT_B64" "$CLIENT_PUBLIC_KEY_B64" "$MUNDO_CA_CLIENT_KEYPAIR_FILE"
        write_client_uris "$protocol" "$transport" "$external_port" "$token" "$client_host" "$host" "$path" "$username" "$reverse_proxy" "$CLIENT_CERT_B64"
    else
        warn "已保留主 URI 文件；新增入站 URI 写入: $node_uri_file"
    fi
    write_all_nginx_config

    ok "配置已生成"
    say "配置文件: $CONFIG_FILE"
    say "普通 URI 文件: $node_uri_file"
    [ -f "$node_ech_uri_file" ] && say "ECH URI 文件: $node_ech_uri_file"
    [ "$append" -eq 0 ] && say "兼容 URI 文件: $CLIENT_URI_FILE"
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
    [ "$transport" != "mundordp" ] && [ "$transport" != "mundosql" ] && say "路径: $path"
    [ "$transport" = "mundordp" ] && say "用户名: $username"
    [ "$transport" = "mundosql" ] && say "数据库用户名: $username"
    if [ "$CA_ENABLED" = "1" ]; then
        say "认证: MundoCA"
        say "Root CA: $MUNDO_CA_ROOT_CERT_B64_FILE"
        say "客户端证书: $MUNDO_CA_CLIENT_CERT_B64_FILE"
        [ -n "$CLIENT_PUBLIC_KEY_B64" ] && say "客户端公钥 Base64: $CLIENT_PUBLIC_KEY_B64"
        if [ "$CLIENT_KEYPAIR_GENERATED" = "1" ]; then
            say ""
            say "${yellow}请立即保存以下客户端密钥对。格式为 Base64(privateKey[32] || publicKey[65])。${none}"
            say "$CLIENT_KEYPAIR_B64"
            say "密钥对文件: $MUNDO_CA_CLIENT_KEYPAIR_FILE"
        fi
    else
        say "$token_label: $token"
    fi
    say "普通 URI: $(cat "$node_uri_file")"
    [ -f "$node_ech_uri_file" ] && say "ECH URI: $(cat "$node_ech_uri_file")"

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
            say "可手动运行: mp run"
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
    local ca_enabled="0"
    local ca_client_cert=""
    local ca_public_key=""
    local ca_keypair_file=""
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
        ca_enabled="${CA_ENABLED:-0}"
        ca_client_cert="${MUNDO_CA_CLIENT_CERTIFICATE:-}"
        ca_public_key="${MUNDO_CA_CLIENT_PUBLIC_KEY:-}"
        ca_keypair_file="${MUNDO_CA_CLIENT_KEYPAIR_FILE:-}"
    fi

    say "${cyan}Mundo Proxy${none}"
    [ -n "$transport" ] && say "协议: $protocol"
    [ -n "$transport" ] && say "传输: $(transport_display_name "$transport")"
    [ -n "$port" ] && say "端口: $port"
    [ -n "$host" ] && say "服务器: $host"
    [ "$cdn_enabled" = "1" ] && [ -n "$client_host" ] && say "连接地址: $client_host"
    [ -n "$path_value" ] && [ "$transport" != "mundordp" ] && [ "$transport" != "mundosql" ] && say "路径: $path_value"
    [ "$transport" = "mundordp" ] && say "用户名: $rdp_username"
    [ "$transport" = "mundosql" ] && say "数据库用户名: $rdp_username"
    if [ "$ca_enabled" = "1" ]; then
        say "认证: MundoCA"
        [ -n "$ca_public_key" ] && say "客户端公钥 Base64: $ca_public_key"
        [ -n "$ca_client_cert" ] && say "客户端证书: $MUNDO_CA_CLIENT_CERT_B64_FILE"
        [ -n "$ca_keypair_file" ] && [ -f "$ca_keypair_file" ] && say "客户端密钥对: $ca_keypair_file"
    fi
    if [ "$reverse_proxy" = "1" ]; then
        say "反代: Nginx -> 127.0.0.1:$core_port"
    elif [ -n "$core_port" ]; then
        say "监听: 0.0.0.0:$core_port"
    fi
    say "配置文件: $CONFIG_FILE"
    collect_node_files
    if [ "${#NODE_FILES[@]}" -gt 0 ]; then
        say ""
        say "入站列表:"
        local index=1
        local file
        for file in "${NODE_FILES[@]}"; do
            source_node_profile "$file"
            say "[$index] $TAG  $PROTOCOL + $(transport_display_name "$TRANSPORT")  $PORT -> $LISTEN_ADDR:$CORE_PORT"
            [ "$CDN_ENABLED" = "1" ] && say "    连接地址: $CLIENT_HOST"
            if [ "$TRANSPORT" = "mundordp" ]; then
                say "    用户名: $RDP_USERNAME"
            elif [ "$TRANSPORT" = "mundosql" ]; then
                say "    数据库用户名: $RDP_USERNAME"
            elif [ -n "$PATH_VALUE" ]; then
                say "    路径: $PATH_VALUE"
            fi
            [ "$REVERSE_PROXY" = "1" ] && say "    反代: Nginx -> 127.0.0.1:$CORE_PORT"
            [ "$CA_ENABLED" = "1" ] && say "    认证: MundoCA"
            if [ -f "$NODE_URI_FILE" ]; then
                say "    普通 URI:"
                sed 's/^/    /' "$NODE_URI_FILE"
            fi
            if [ -f "$NODE_ECH_URI_FILE" ]; then
                say "    ECH URI:"
                sed 's/^/    /' "$NODE_ECH_URI_FILE"
            fi
            index=$((index + 1))
        done
        say ""
        return 0
    fi
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
    load_brutal_profile
    if [ "${BRUTAL_ENABLED:-0}" = "1" ]; then
        exec "$CORE_BIN" run -c "$CONFIG_FILE" -brutal "${BRUTAL_MBPS:-100}"
    fi
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
  mp add-node  新增入站
  mp del-node  删除入站
  mp brutal    配置 TCP Brutal / Mundo X Brutal
  mp restart   重启
  mp status    状态
  mp autostart 开关开机启动
  mp log       日志
  mp error-log 错误日志
  mp uninstall 卸载
EOF
}

sync_primary_profile_from_first_node() {
    collect_node_files
    [ "${#NODE_FILES[@]}" -gt 0 ] || return 0
    source_node_profile "${NODE_FILES[0]}"
    write_profile "$PROTOCOL" "$TRANSPORT" "$CORE_PORT" "$TOKEN" "$HOST" "$CLIENT_HOST" "$PATH_VALUE" "$RDP_USERNAME" "off" "$REVERSE_PROXY" "$PORT" "$CORE_PORT" "$CDN_ENABLED" "$CA_ENABLED" "$MUNDO_CA_CERTIFICATE" "$MUNDO_CA_CLIENT_CERTIFICATE" "$MUNDO_CA_CLIENT_PUBLIC_KEY" "$MUNDO_CA_CLIENT_KEYPAIR_FILE"
    if [ -f "$NODE_URI_FILE" ]; then
        cp "$NODE_URI_FILE" "$CLIENT_URI_FILE"
        chmod 600 "$CLIENT_URI_FILE"
    fi
    if [ -f "$NODE_ECH_URI_FILE" ]; then
        cp "$NODE_ECH_URI_FILE" "$CLIENT_URI_ECH_FILE"
        chmod 600 "$CLIENT_URI_ECH_FILE"
    else
        rm -f "$CLIENT_URI_ECH_FILE"
    fi
}

stop_service_quiet() {
    if systemd_available && systemctl list-unit-files mundoproxy.service >/dev/null 2>&1; then
        systemctl stop mundoproxy >/dev/null 2>&1 || true
    elif openrc_available && [ -f "$OPENRC_SERVICE_FILE" ]; then
        rc-service mundoproxy stop >/dev/null 2>&1 || true
    fi
}

restart_service_quiet() {
    if systemd_available && systemctl list-unit-files mundoproxy.service >/dev/null 2>&1; then
        systemctl restart mundoproxy >/dev/null 2>&1 || true
    elif openrc_available && [ -f "$OPENRC_SERVICE_FILE" ]; then
        rc-service mundoproxy restart >/dev/null 2>&1 || true
    fi
}

delete_node() {
    require_root
    migrate_profile_to_nodes
    collect_node_files
    if [ "${#NODE_FILES[@]}" -eq 0 ]; then
        warn "没有可删除的入站。"
        return 0
    fi
    say "${blue}删除入站${none}"
    local index=1
    local file
    for file in "${NODE_FILES[@]}"; do
        source_node_profile "$file"
        say "  $index) $TAG  $PROTOCOL + $(transport_display_name "$TRANSPORT")  $PORT -> $LISTEN_ADDR:$CORE_PORT"
        index=$((index + 1))
    done
    local choice
    read -r -p "选择要删除的入站编号 [0取消]: " choice
    [ -n "$choice" ] || choice=0
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "无效编号。"; return 0; }
    [ "$choice" -gt 0 ] || return 0
    [ "$choice" -le "${#NODE_FILES[@]}" ] || { warn "无效编号。"; return 0; }
    local selected="${NODE_FILES[$((choice - 1))]}"
    source_node_profile "$selected"
    if [ "${#NODE_FILES[@]}" -eq 1 ]; then
        warn "这是最后一个入站，删除后会同步停止服务。"
        yes_no_default_no "确认删除最后一个入站" || return 0
        rm -f "$selected" "$NODE_URI_FILE" "$NODE_ECH_URI_FILE" "$CONFIG_FILE" "$PROFILE_FILE" "$CLIENT_URI_FILE" "$CLIENT_URI_ECH_FILE"
        remove_nginx_config
        stop_service_quiet
        ok "最后一个入站已删除，服务已停止。"
        return 0
    fi
    yes_no_default_no "确认删除 $TAG" || return 0
    rm -f "$selected" "$NODE_URI_FILE" "$NODE_ECH_URI_FILE"
    write_config_from_nodes
    write_all_nginx_config
    sync_primary_profile_from_first_node
    restart_service_quiet
    ok "入站已删除，配置已重建。"
}

menu() {
    while true; do
        show_info
        say ""
        say "${blue}菜单${none}"
        say "  1) 显示配置"
        say "  2) 重新配置"
        say "  3) 新增入站"
        say "  4) 删除入站"
        say "  5) 重启"
        say "  6) 状态"
        say "  7) 开机启动 $(autostart_status_label)"
        say "  8) Brutal 配置"
        say "  9) 错误日志"
        say " 10) 卸载"
        say "  0) 退出"
        local choice
        read -r -p "请选择 [1]: " choice
        case "${choice:-1}" in
            1) show_info ;;
            2) configure ;;
            3) configure --append ;;
            4) delete_node ;;
            5) restart_service ;;
            6) status_service ;;
            7)
                if autostart_enabled; then
                    disable_autostart
                else
                    enable_autostart
                fi
                ;;
            8) configure_brutal ;;
            9) show_log "$ERROR_LOG" ;;
            10) uninstall_mundo_proxy ;;
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
        add-node|add|append)
            configure --append
            ;;
        del-node|delete-node|remove-node)
            delete_node
            ;;
        brutal)
            configure_brutal
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
