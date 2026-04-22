#!/bin/bash

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
RESET="\e[0m"

# ================================
# 打印函数
# ================================
print_info() {
    echo -e "${CYAN}[Info]${RESET} $1"
}

print_ok() {
    echo -e "${GREEN}[OK]${RESET} $1"
}

print_error() {
    echo -e "${RED}[Error]${RESET} $1"
}
detect_listen_ip() {
    local has_ipv4=false
    local has_ipv6=false

    # 检测真实 IPv4（排除 127.0.0.1）
    if ip -4 addr show scope global | grep -q "inet "; then
        has_ipv4=true
    fi

    # 检测真实 IPv6（排除 fe80::）
    if ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]"; then
        has_ipv6=true
    fi

    print_info "自动检测结果："
    $has_ipv4 && echo "  - 检测到 IPv4"
    $has_ipv6 && echo "  - 检测到 IPv6"
    (! $has_ipv4 && ! $has_ipv6) && echo "  - 未检测到公网 IP（可能是 NAT 或容器环境）"

    echo
    echo "请选择监听地址："
    echo "1) IPv4 (0.0.0.0)"
    echo "2) IPv6 (::)"
    echo "3) 全部自动（根据检测结果推荐）"

    printf "选择 (默认 1): "
    read choice

    case "$choice" in
        2)
            echo "::"
            ;;
        3)
            if $has_ipv4 && ! $has_ipv6; then
                echo "0.0.0.0"
            elif ! $has_ipv4 && $has_ipv6; then
                echo "::"
            elif $has_ipv4 && $has_ipv6; then
                echo "0.0.0.0"
            else
                echo "0.0.0.0"
            fi
            ;;
        *)
            echo "0.0.0.0"
            ;;
    esac
}

ask_port_with_default() {
    local default="$1"
    local input

    while true; do
        read -p "$(echo -e ${YELLOW}请输入本地监听端口${RESET}) (回车默认: $default): " input
        port="${input:-$default}"

        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            print_error "端口必须是数字"
            continue
        fi

        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            print_error "端口必须在 1-65535 范围内"
            continue
        fi

        if port_in_use "$port"; then
            print_error "端口 $port 已被占用，请重新输入"
            continue
        fi

        echo "$port"
        return
    done
}
print_title() {
    echo -e "${MAGENTA}${BOLD}"
    echo "╔══════════════════════════════════════╗"
    printf "║ %-36s ║\n" "$1"
    echo "╚══════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ================================
# 基础变量
# ================================
PROTO="tunnel"
CONF_DIR="/root/catmi/xray/conf"
mkdir -p "$CONF_DIR"

# ================================
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 $PROTO 配置列表"

    echo -e "${CYAN}编号 | 本地端口 → 目标地址 | 协议${RESET}"
    echo "-------------------------------------"

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)

        ip=$(jq -r '.inbounds[0].settings.address' "$f")
        port=$(jq -r '.inbounds[0].settings.port' "$f")
        net=$(jq -r '.inbounds[0].settings.network' "$f")
        lport=$(jq -r '.inbounds[0].port' "$f")

        echo -e "${GREEN}$num${RESET}) 本地端口 ${BLUE}$lport${RESET} → ${YELLOW}$ip${RESET}:${CYAN}$port${RESET} (${MAGENTA}$net${RESET})"
    done

    echo "-------------------------------------"
}

# ================================
# 新增配置
# ================================
add_config() {
    print_title "新增 $PROTO 配置"

    lport=$(ask_port_with_default "$default_port")
    read -p "$(echo -e ${YELLOW}请输入目标 IP${RESET}): " ip
    read -p "$(echo -e ${YELLOW}请输入目标端口${RESET}): " tport
    listen_ip=$(detect_listen_ip)

    echo -e "${CYAN}请选择协议类型:${RESET}"
    echo -e "${CYAN}1)${RESET} tcp"
    echo -e "${CYAN}2)${RESET} udp"
    read -p "$(echo -e ${YELLOW}请输入选项${RESET}): " choice

    case "$choice" in
        1) net="tcp" ;;
        2) net="udp" ;;
        *)
            print_error "无效选项，默认使用 tcp"
            net="tcp"
            ;;
    esac

    next=$(ls "$CONF_DIR"/$PROTO-*.json 2>/dev/null | wc -l)
    next=$((next + 1))

    file="$CONF_DIR/$PROTO-$(printf "%02d" $next).json"

    cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "$listen_ip",
      "port": $lport,
      "protocol": "$PROTO",
      "settings": {
        "address": "$ip",
        "port": $tport,
        "network": "$net",
        "followRedirect": false,
        "userLevel": 0
      },
      "tag": "$PROTO$next"
    }
  ]
}
EOF

    print_ok "新增 $PROTO 配置成功"
    echo -e "${GREEN}编号:${RESET} $next"
    echo -e "${GREEN}本地端口:${RESET} $lport"
    echo -e "${GREEN}转发到:${RESET} $ip:$tport ($net)"
}

# ================================
# 删除配置
# ================================
delete_config() {
    list_configs

    read -p "$(echo -e ${RED}请输入要删除的编号${RESET}): " num
    file="$CONF_DIR/$PROTO-$(printf "%02d" $num).json"

    if [[ -f "$file" ]]; then
        rm -f "$file"
        print_ok "已删除编号 $num 的 $PROTO 配置"
    else
        print_error "编号 $num 不存在"
    fi
}

# ================================
# 主菜单
# ================================
config_menu() {
    while true; do
        print_title "$PROTO 配置管理"

        echo -e "${CYAN}1)${RESET} 查看所有配置"
        echo -e "${CYAN}2)${RESET} 新增配置"
        echo -e "${CYAN}3)${RESET} 删除配置"
        echo -e "${CYAN}0)${RESET} 退出脚本"

        read -p "$(echo -e ${YELLOW}请选择${RESET}): " c

        case $c in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        read -p "按回车继续..."
    done
}

config_menu
