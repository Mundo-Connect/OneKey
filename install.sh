#!/bin/bash

set -e

APP_NAME="Mundo Proxy"
APP_DIR="/etc/mundoproxy"
BIN_DIR="$APP_DIR/bin"
SH_DIR="$APP_DIR/sh"
CONFIG_FILE="$APP_DIR/config.json"
LOG_DIR="/var/log/mundoproxy"
SERVICE_FILE="/etc/systemd/system/mundoproxy.service"
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
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "当前系统没有 systemctl，已完成文件安装，请手动运行：mundoproxy run -c $CONFIG_FILE"
        return 0
    fi

    write_service
    systemctl daemon-reload
    systemctl enable mundoproxy >/dev/null 2>&1 || true
    systemctl restart mundoproxy
}

usage() {
    cat <<EOF
Mundo Proxy 本地安装脚本

用法:
  ./install.sh             安装依赖、复制本地 mundoproxy 内核、生成配置并启动服务
  ./install.sh --deps      只安装依赖
  ./install.sh --uninstall 卸载 Mundo Proxy
  ./install.sh --help      显示帮助

要求:
  编译好的静态内核文件必须与 install.sh 在同一目录，文件名为 mundoproxy。
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
                rm -f "$SERVICE_FILE" "$COMMAND_BIN"
                rm -rf "$APP_DIR" "$LOG_DIR"
            fi
            exit 0
            ;;
    esac

    require_root
    local source_dir
    source_dir="$(script_dir)"
    local core_source
    core_source="$(find_core_source "$source_dir")" || err "未找到本地 Mundo Proxy 内核。请把已编译好的 mundoproxy 放在 install.sh 同一目录。"

    say "${blue}Mundo Proxy 本地部署${none}"
    say "源码主页: https://github.com/Mundo-Connect"
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
    say "脚本来源: Mundo Connect 专用本地部署脚本 (GPLv3)"
    say "GitHub: https://github.com/Mundo-Connect"
    say "管理命令: mp"
    say "内核命令: mundoproxy"
    say ""
    "$SH_DIR/src/init.sh" info
}

main "$@"
