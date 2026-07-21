#!/usr/bin/env bash

set -e

APP_NAME="Mundo Proxy"
APP_DIR="/etc/mundoproxy"
BIN_DIR="$APP_DIR/bin"
SH_DIR="$APP_DIR/sh"
CONFIG_FILE="$APP_DIR/config.json"
NODE_DIR="$APP_DIR/nodes"
LOG_DIR="/var/log/mundoproxy"
SERVICE_FILE="/etc/systemd/system/mundoproxy.service"
OPENRC_SERVICE_FILE="/etc/init.d/mundoproxy"
FREEBSD_SERVICE_FILE="/usr/local/etc/rc.d/mundoproxy"
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

systemd_available() {
    command -v systemctl >/dev/null 2>&1
}

openrc_available() {
    command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1
}

freebsd_available() {
    [ "$(uname -s)" = "FreeBSD" ] && command -v service >/dev/null 2>&1
}

service_installed() {
    [ -x "$CORE_BIN" ] ||
    [ -f "$SERVICE_FILE" ] ||
    [ -f "$OPENRC_SERVICE_FILE" ] ||
    [ -f "$FREEBSD_SERVICE_FILE" ] ||
    [ -f "$CONFIG_FILE" ]
}

service_running() {
    if freebsd_available && [ -x "$FREEBSD_SERVICE_FILE" ]; then
        service mundoproxy onestatus >/dev/null 2>&1 && return 0
    fi
    if systemd_available && systemctl list-unit-files mundoproxy.service >/dev/null 2>&1; then
        systemctl is-active --quiet mundoproxy && return 0
    fi
    if openrc_available && [ -f "$OPENRC_SERVICE_FILE" ]; then
        rc-service mundoproxy status >/dev/null 2>&1 && return 0
    fi
    pgrep -f "$CORE_BIN -c $CONFIG_FILE" >/dev/null 2>&1 ||
    pgrep -f "$CORE_BIN run -c $CONFIG_FILE" >/dev/null 2>&1 ||
    pgrep -f "$COMMAND_BIN run" >/dev/null 2>&1
}

stop_service_if_installed() {
    if freebsd_available && [ -x "$FREEBSD_SERVICE_FILE" ]; then
        service mundoproxy stop >/dev/null 2>&1 || true
    elif systemd_available && systemctl list-unit-files mundoproxy.service >/dev/null 2>&1; then
        systemctl stop mundoproxy >/dev/null 2>&1 || true
    elif openrc_available && [ -f "$OPENRC_SERVICE_FILE" ]; then
        rc-service mundoproxy stop >/dev/null 2>&1 || true
    else
        pkill -f "$CORE_BIN -c $CONFIG_FILE" >/dev/null 2>&1 || true
        pkill -f "$CORE_BIN run -c $CONFIG_FILE" >/dev/null 2>&1 || true
        pkill -f "$COMMAND_BIN run" >/dev/null 2>&1 || true
    fi
}

detect_pkg_manager() {
    if command -v pkg >/dev/null 2>&1 && [ "$(uname -s)" = "FreeBSD" ]; then
        echo pkg
    elif command -v apt-get >/dev/null 2>&1; then
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
    if freebsd_available; then
        command -v ifconfig >/dev/null 2>&1 || missing="$missing ifconfig"
    else
        command -v ip >/dev/null 2>&1 || missing="$missing iproute"
    fi
    if command -v update-ca-certificates >/dev/null 2>&1 || command -v trust >/dev/null 2>&1 || [ -r /etc/ssl/cert.pem ]; then
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
        pkg)
            pkg install -y openssl ca_root_nss
            ;;
        apt)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y openssl ca-certificates iproute2
            ;;
        dnf)
            dnf install -y openssl ca-certificates iproute
            ;;
        yum)
            yum install -y openssl ca-certificates iproute
            ;;
        apk)
            apk add --no-cache openssl ca-certificates iproute2
            ;;
    esac

    command -v openssl >/dev/null 2>&1 || err "openssl 安装失败。"
    if ! freebsd_available; then
        command -v ip >/dev/null 2>&1 || warn "iproute 未安装成功，将继续使用公网探测和本机网卡地址。"
    fi
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mundo Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$COMMAND_BIN run
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
command="$COMMAND_BIN"
command_args="run"
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

write_freebsd_service() {
    mkdir -p "$(dirname "$FREEBSD_SERVICE_FILE")"
    cat > "$FREEBSD_SERVICE_FILE" <<EOF
#!/bin/sh
# PROVIDE: mundoproxy
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="mundoproxy"
rcvar="mundoproxy_enable"
load_rc_config "\$name"
: \${mundoproxy_enable:="NO"}

pidfile="/var/run/mundoproxy.pid"
command="/usr/sbin/daemon"
command_args="-f -P \${pidfile} -r -R 3 -o $LOG_DIR/service.log $COMMAND_BIN run"
required_files="$COMMAND_BIN $CORE_BIN $CONFIG_FILE"
start_precmd="mundoproxy_prestart"

mundoproxy_prestart() {
    ulimit -S -n "\$(ulimit -H -n)" 2>/dev/null || true
}

run_rc_command "\$1"
EOF
    chmod 555 "$FREEBSD_SERVICE_FILE"
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
#!/usr/bin/env bash
exec "$SH_DIR/src/init.sh" "\$@"
EOF
    chmod +x "$COMMAND_BIN"
}

enable_service() {
    local should_start="${1:-1}"
    if freebsd_available; then
        write_freebsd_service
        sysrc mundoproxy_enable=YES >/dev/null
        if [ "$should_start" -eq 1 ]; then
            service mundoproxy start
        else
            service mundoproxy stop >/dev/null 2>&1 || true
        fi
    elif systemd_available; then
        write_service
        systemctl daemon-reload
        systemctl enable mundoproxy >/dev/null 2>&1 || true
        if [ "$should_start" -eq 1 ]; then
            systemctl start mundoproxy
        else
            systemctl stop mundoproxy >/dev/null 2>&1 || true
        fi
    elif openrc_available; then
        write_openrc_service
        rc-update add mundoproxy default >/dev/null 2>&1 || true
        if [ "$should_start" -eq 1 ]; then
            rc-service mundoproxy start
        else
            rc-service mundoproxy stop >/dev/null 2>&1 || true
        fi
    else
        warn "未检测到 FreeBSD rc.d、systemd 或 OpenRC，请手动运行：mp run"
    fi
}

nodes_exist() {
    [ -d "$NODE_DIR" ] && find "$NODE_DIR" -type f -name '*.env' -print -quit 2>/dev/null | grep -q .
}

first_run_config() {
    say "首次安装：按回车会自动安装并输出可直接使用的 URI；输入 n 可手动配置。"
    if [ -t 0 ]; then
        local answer
        read -r -p "是否自动安装？[Y/n]: " answer
        case "$answer" in
            n|N|no|NO)
                "$SH_DIR/src/init.sh" config --no-restart
                return
                ;;
        esac
    fi
    "$SH_DIR/src/init.sh" quick-install --no-restart
}

usage() {
    cat <<EOF
Mundo Proxy 安装脚本

用法:
  ./install.sh             安装并生成配置
  ./install.sh onekey      一键安装并输出 URI
  ./install.sh --deps      安装依赖
  ./install.sh --uninstall 卸载
  ./install.sh --help      帮助

要求:
  install.sh 同目录需要有 mundoproxy 文件。

首次安装:
  没有配置或没有节点时，按回车自动安装并输出 URI；输入 n 进入手动配置。
EOF
}

main() {
    local onekey_mode=0
    case "${1:-}" in
        -h|--help|help)
            usage
            exit 0
            ;;
        onekey|quick|quick-install|first-run)
            onekey_mode=1
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
                if freebsd_available; then
                    service mundoproxy stop >/dev/null 2>&1 || true
                    sysrc -x mundoproxy_enable >/dev/null 2>&1 || true
                elif command -v systemctl >/dev/null 2>&1; then
                    systemctl stop mundoproxy >/dev/null 2>&1 || true
                    systemctl disable mundoproxy >/dev/null 2>&1 || true
                    systemctl reset-failed mundoproxy >/dev/null 2>&1 || true
                elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
                    rc-service mundoproxy stop >/dev/null 2>&1 || true
                    rc-update del mundoproxy default >/dev/null 2>&1 || true
                fi
                rm -f "$SERVICE_FILE" "$OPENRC_SERVICE_FILE" "$FREEBSD_SERVICE_FILE" "$COMMAND_BIN" "$CORE_BIN" "$CORE_BACKUP_BIN"
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

    local update_mode=0
    local was_running=0
    if service_installed; then
        update_mode=1
        if service_running; then
            was_running=1
        fi
        warn "检测到已安装，执行更新（保留现有配置）"
        stop_service_if_installed
    fi

    if [ "$update_mode" -eq 1 ]; then
        say "${blue}Mundo Proxy 更新${none}"
    else
        say "${blue}Mundo Proxy 安装${none}"
    fi
    say "内核来源: $core_source"

    install_dependencies
    install_files "$source_dir" "$core_source"

    local configured_new=0
    if [ "$onekey_mode" -eq 1 ]; then
        "$SH_DIR/src/init.sh" quick-install --reset --no-restart
        configured_new=1
    elif [ "$update_mode" -eq 1 ] && [ -s "$CONFIG_FILE" ] && nodes_exist; then
        warn "更新模式保留配置文件: $CONFIG_FILE"
    elif [ ! -s "$CONFIG_FILE" ] || ! nodes_exist; then
        first_run_config
        configured_new=1
    else
        warn "已存在配置文件: $CONFIG_FILE"
        read -r -p "是否重新生成配置? [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES) "$SH_DIR/src/init.sh" config --no-restart ;;
        esac
    fi

    if [ "$update_mode" -eq 1 ]; then
        [ "$configured_new" -eq 1 ] && was_running=1
        enable_service "$was_running"
        if [ "$was_running" -eq 1 ]; then
            ok "更新完成，服务已重新启动。"
        else
            ok "更新完成，服务保持停止。"
        fi
    else
        enable_service 1
        ok "安装完成。"
    fi
    if [ "$onekey_mode" -eq 0 ] && [ "$configured_new" -eq 0 ]; then
        say ""
        "$SH_DIR/src/init.sh" info
    fi
}

main "$@"
