#!/bin/bash

# ================================
# verify.sh — xrayls 配置校验 / 服务重启 独立模块
# 设计给 xray-panel.sh 面板复用：
#   - 单独运行: bash verify.sh        （校验 + 可选重启）
#   - 被面板 source 后调用 verify_xray / restart_xrayls
# 风格与 outbound.sh / split.sh 一致
# ================================

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
MAGENTA="\e[35m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

# ================================
# 打印函数（stderr）
# ================================
print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ================================
# 基础变量（可被面板覆盖）
# ================================
INSTALL_DIR="${VERIFY_INSTALL_DIR:-/root/catmi/xray}"
CONF_DIR="$INSTALL_DIR/conf"
SERVICE_NAME="xrayls"

XRAY_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_BIN" ]]; then
    for c in "$INSTALL_DIR/xrayls" /usr/local/bin/xray xrayls; do
        command -v "$c" >/dev/null 2>&1 && { XRAY_BIN=$(command -v "$c"); break; }
    done
    [[ -z "$XRAY_BIN" && -x "$INSTALL_DIR/xrayls" ]] && XRAY_BIN="$INSTALL_DIR/xrayls"
fi

# ================================
# 配置校验（confdir 或单文件都支持）
# ================================
validate_config() {
    if [[ -z "$XRAY_BIN" ]]; then
        print_error "未找到 xray 二进制，无法校验"
        return 1
    fi
    local out
    # 优先 confdir；若无 conf 目录则用主 config.json
    if [[ -d "$CONF_DIR" ]] && ls "$CONF_DIR"/*.json >/dev/null 2>&1; then
        out=$("$XRAY_BIN" run -test -confdir "$CONF_DIR" 2>&1)
    elif [[ -f "$INSTALL_DIR/config.json" ]]; then
        out=$("$XRAY_BIN" run -test -c "$INSTALL_DIR/config.json" 2>&1)
    else
        print_error "未找到配置（conf 目录或 config.json）"
        return 1
    fi
    if [[ "$out" == *"Configuration OK."* ]]; then
        print_ok "Configuration OK."
        return 0
    else
        print_error "配置校验失败："
        echo "$out" | tail -10 >&2
        return 1
    fi
}

# ================================
# 服务状态
# ================================
xray_status() {
    if systemctl list-unit-files 2>/dev/null | grep -qw "$SERVICE_NAME.service"; then
        local st
        st=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
        if [[ "$st" == "active" ]]; then
            print_ok "服务状态: active (运行中)"
        else
            print_error "服务状态: $st"
        fi
        local since
        since=$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null)
        [[ -n "$since" ]] && print_info "启动时间: $since"
        return 0
    fi
    print_error "未找到 $SERVICE_NAME 服务"
    return 1
}

# ================================
# 重启服务（systemd；无 systemd 回退直接 kill+拉起）
# ================================
restart_xrayls() {
    print_title "重启 $SERVICE_NAME"
    if systemctl list-unit-files 2>/dev/null | grep -qw "$SERVICE_NAME.service"; then
        systemctl restart "$SERVICE_NAME"
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            print_ok "$SERVICE_NAME 已重启 (active)"
            return 0
        else
            print_error "$SERVICE_NAME 重启失败"
            journalctl -u "$SERVICE_NAME" -n 8 --no-pager 2>/dev/null | tail -8 >&2
            return 1
        fi
    elif [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]]; then
        # 简易回退：杀掉旧进程重启
        pkill -f "$XRAY_BIN" 2>/dev/null
        sleep 1
        nohup "$XRAY_BIN" run -confdir "$CONF_DIR" >> "$INSTALL_DIR/error.log" 2>&1 &
        sleep 2
        print_ok "已用 nohup 重启 $SERVICE_NAME"
        return 0
    else
        print_error "未找到 $SERVICE_NAME 服务或二进制，无法重启"
        return 1
    fi
}

# ================================
# 校验 + 可选重启（面板一键）
# ================================
verify_xray() {
    print_title "校验 xrayls 配置"
    validate_config
    xray_status
    printf "重启 $SERVICE_NAME 服务? [y/N]: " >&2
    read rr
    rr=$(echo "$rr" | tr -d '\000-\037')
    if [[ "$rr" == "y" || "$rr" == "Y" ]]; then
        restart_xrayls
    else
        print_info "未重启。如需生效请手动重启。"
    fi
}

# ================================
# 直跑入口
# ================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        status) xray_status ;;
        check)  validate_config ;;
        restart) restart_xrayls ;;
        *)      verify_xray ;;
    esac
fi