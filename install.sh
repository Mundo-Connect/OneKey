#!/bin/bash

set -e

APP_NAME="Mundo Proxy"
APP_DIR="/etc/mundoproxy"
BIN_DIR="$APP_DIR/bin"
SH_DIR="$APP_DIR/sh"
CONFIG_FILE="$APP_DIR/config.json"
LOG_DIR="/var/log/mundoproxy"
SERVICE_FILE="/etc/systemd/system/mundoproxy.service"
OPENRC_SERVICE_FILE="/etc/init.d/mundoproxy"
COMMAND_BIN="/usr/local/bin/mp"
CORE_BIN="/usr/local/bin/mundoproxy"
CORE_BACKUP_BIN="$BIN_DIR/mundoproxy"

red='\033[31m'
yellow='\033[33m'
green='\033[92m'
blue='\033[94m'
none='\033[0m'

say() { printf "%b\n" "$*"; }
ok() { say "${green}$*${none}"; }
warn() { say "${yellow}$*${none}"; }
err() { say "${red}$*${none}"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || err "请使用 root 权限运行。"
}

script_dir() {
    local src="${BASH_SOURCE[0]}"
    while [ -h "$src" ]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

find_core_source() {
    local dir="$1"
    local candidate
    for candidate in "$dir/mundoproxy" "$dir/mundoproxy-core"; do
        if [ -f "$candidate" ] && [ "$candidate" != "$0" ]; then
            printf "%s" "$candidate"
            return 0
        fi
    done
    return 1
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

install_dependencies() {
    local missing=""
    command -v openssl >/dev/null 2>&1 || missing="$missing openssl"
    if command -v update-ca-certificates >/dev/null 2>&1 || command -v trust >/dev/null 2>&1; then
        :
    else
        missing="$missing ca-certificates"
    fi
    [ -z "$missing" ] && {
        ok "依赖已满足。"
        return 0
    }

    local manager
    manager="$(detect_pkg_manager)"
    [ -n "$manager" ] || err "无法识别包管理器，请手动安装: openssl ca-certificates"

    warn "安装依赖:$missing"
    case "$manager" in
        apt)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y openssl ca-certificates
            ;;
        dnf)
            dnf install -y openssl ca-certificates
            ;;
        yum)
            yum install -y openssl ca-certificates
            ;;
        apk)
            apk add --no-cache openssl ca-certificates
            ;;
    esac

    command -v openssl >/dev/null 2>&1 || err "openssl 安装失败。"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mundo Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CORE_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_openrc_service() {
    cat > "$OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="Mundo Proxy"
description="Mundo Proxy"
command="$CORE_BIN"
command_args="run -c $CONFIG_FILE"
command_background="yes"
pidfile="/run/mundoproxy.pid"
output_log="$LOG_DIR/service.log"
error_log="$LOG_DIR/service.err"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$OPENRC_SERVICE_FILE"
}

install_files() {
    local source_dir="$1"
    local core_source="$2"

    mkdir -p "$BIN_DIR" "$SH_DIR/src" "$LOG_DIR"

    install -m 0755 "$core_source" "$CORE_BIN"
    install -m 0755 "$core_source" "$CORE_BACKUP_BIN"
    install -m 0755 "$source_dir/install.sh" "$BIN_DIR/install.sh"

    if [ -d "$source_dir/src" ]; then
        cp -R "$source_dir/src/." "$SH_DIR/src/"
        chmod +x "$SH_DIR/src/init.sh"
    else
        err "缺少 src 目录，无法安装管理脚本。"
    fi

    cat > "$COMMAND_BIN" <<EOF
#!/bin/bash
exec "$SH_DIR/src/init.sh" "\$@"
EOF
    chmod +x "$COMMAND_BIN"
}

enable_service() {
    if command -v systemctl >/dev/null 2>&1; then
        write_service
        systemctl daemon-reload
        systemctl enable mundoproxy >/dev/null 2>&1 || true
        systemctl restart mundoproxy
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        write_openrc_service
        rc-update add mundoproxy default >/dev/null 2>&1 || true
        rc-service mundoproxy restart
    else
        warn "未检测到 systemd 或 OpenRC，请手动运行：mundoproxy run -c $CONFIG_FILE"
    fi
}

usage() {
    cat <<EOF
Mundo Proxy 安装脚本

用法:
  ./install.sh             安装并生成配置
  ./install.sh --deps      安装依赖
  ./install.sh --uninstall 卸载
  ./install.sh --help      帮助

要求:
  install.sh 同目录需要有 mundoproxy 文件。
EOF
}

main() {
    case "${1:-}" in
        -h|--help|help)
            usage
            exit 0
            ;;
        --deps|deps)
            require_root
            install_dependencies
            exit 0
            ;;
        --uninstall|uninstall|remove)
            require_root
            if [ -x "$SH_DIR/src/init.sh" ]; then
                "$SH_DIR/src/init.sh" uninstall
            else
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl stop mundoproxy >/dev/null 2>&1 || true
                    systemctl disable mundoproxy >/dev/null 2>&1 || true
                    systemctl reset-failed mundoproxy >/dev/null 2>&1 || true
                elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
                    rc-service mundoproxy stop >/dev/null 2>&1 || true
                    rc-update del mundoproxy default >/dev/null 2>&1 || true
                fi
                rm -f "$SERVICE_FILE" "$OPENRC_SERVICE_FILE" "$COMMAND_BIN" "$CORE_BIN" "$CORE_BACKUP_BIN"
                rm -rf "$APP_DIR" "$LOG_DIR"
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl daemon-reload >/dev/null 2>&1 || true
                fi
            fi
            exit 0
            ;;
    esac

    require_root
    local source_dir
    source_dir="$(script_dir)"
    local core_source
    core_source="$(find_core_source "$source_dir")" || err "未找到本地 Mundo Proxy 内核。请把已编译好的 mundoproxy 放在 install.sh 同一目录。"

    say "${blue}Mundo Proxy 安装${none}"
    say "内核来源: $core_source"

    install_dependencies
    install_files "$source_dir" "$core_source"

    if [ ! -s "$CONFIG_FILE" ]; then
        "$SH_DIR/src/init.sh" config --no-restart
    else
        warn "已存在配置文件: $CONFIG_FILE"
        read -r -p "是否重新生成配置? [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES) "$SH_DIR/src/init.sh" config --no-restart ;;
        esac
    fi

    enable_service
    ok "安装完成。"
    say ""
    "$SH_DIR/src/init.sh" info
}

main "$@"
