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

print_title() {
    echo -e "${MAGENTA}${BOLD}"
    echo "╔══════════════════════════════════════╗"
    printf "║ %-36s ║\n" "$1"
    echo "╚══════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ================================
# 协议类型
# ================================
PROTO="socks"
CONF_DIR="/root/catmi/xray/conf"
mkdir -p "$CONF_DIR"

# ================================
# 随机生成函数
# ================================
random_port() {
    shuf -i 10000-60000 -n 1
}

random_user() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 8
}

random_pass() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 12
}

# 检查端口是否占用
port_in_use() {
    local port=$1
    ss -tuln | awk '{print $5}' | grep -E -q "(:|])${port}$"
}

# 生成未占用的随机端口
random_free_port() {
    while true; do
        port=$(random_port)
        if ! port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
}

# 输入函数（支持默认值）
ask_with_default() {
    local prompt="$1"
    local default="$2"
    local var

    read -p "$(echo -e ${YELLOW}$prompt${RESET}) (回车默认: $default): " var
    echo "${var:-$default}"
}

# 输入端口（保证不占用）
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
detect_listen_ip() {
    local has_ipv4=false
    local has_ipv6=false

    ip -4 addr show scope global | grep -q inet && has_ipv4=true
    ip -6 addr show scope global | grep -q inet6 && has_ipv6=true

    if $has_ipv4 && ! $has_ipv6; then
        print_info "检测到仅 IPv4，使用 0.0.0.0"
        echo "0.0.0.0"
        return
    fi

    if ! $has_ipv4 && $has_ipv6; then
        print_info "检测到仅 IPv6，使用 ::"
        echo "::"
        return
    fi

    if $has_ipv4 && $has_ipv6; then
        print_info "检测到双栈网络"
        echo "1) IPv4 (0.0.0.0)"
        echo "2) IPv6 (::)"
        printf "请选择监听地址 (默认 1): "
        read choice
        [[ "$choice" == "2" ]] && echo "::" || echo "0.0.0.0"
        return
    fi

    print_error "未检测到有效 IP，默认使用 0.0.0.0"
    echo "0.0.0.0"
}

# ================================
# 显示所有 SOCKS 配置
# ================================
list_configs() {
    print_title "当前 SOCKS 配置列表"
    echo -e "${CYAN}编号 | 用户名 | 密码 | 本地端口 | Tag${RESET}"
    echo "-----------------------------------------------"

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)

        lport=$(jq -r '.inbounds[0].port' "$f")
        user=$(jq -r '.inbounds[0].settings.accounts[0].user' "$f")
        pass=$(jq -r '.inbounds[0].settings.accounts[0].pass' "$f")
        tag=$(jq -r '.inbounds[0].tag' "$f")

        echo -e "${GREEN}$num${RESET}) 用户: ${YELLOW}$user${RESET} | 密码: ${MAGENTA}$pass${RESET} | 端口: ${CYAN}$lport${RESET} | Tag: ${BLUE}$tag${RESET}"
    done

    echo "-----------------------------------------------"
}

# ================================
# 新增 SOCKS 配置
# ================================
add_config() {
    print_title "新增 SOCKS 配置"

    # 自动检测监听地址（IPv4 / IPv6）
    listen_ip=$(detect_listen_ip)

    # 生成随机默认值（保证端口不冲突）
    default_port=$(random_free_port)
    default_user=$(random_user)
    default_pass=$(random_pass)

    # 让用户选择或使用默认值（端口保证不冲突）
    lport=$(ask_port_with_default "$default_port")
    SOCKS_USERNAME=$(ask_with_default "请输入 SOCKS 用户名" "$default_user")
    SOCKS_PASSWORD=$(ask_with_default "请输入 SOCKS 密码" "$default_pass")

    # 自动找下一个编号
    next=$(ls "$CONF_DIR"/$PROTO-*.json 2>/dev/null | wc -l)
    next=$((next + 1))
    tag_name="${PROTO}${next}"

    file="$CONF_DIR/$PROTO-$(printf "%02d" $next).json"

cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "$listen_ip",
      "port": $lport,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$SOCKS_USERNAME",
            "pass": "$SOCKS_PASSWORD"
          }
        ]
      },
      "tag": "$tag_name"
    }
  ]
}
EOF

    print_ok "新增 SOCKS 配置成功"
    echo -e "${GREEN}编号:${RESET} $next"
    echo -e "${GREEN}监听地址:${RESET} $listen_ip"
    echo -e "${GREEN}端口:${RESET} $lport"
    echo -e "${GREEN}用户名:${RESET} $SOCKS_USERNAME"
    echo -e "${GREEN}密码:${RESET} $SOCKS_PASSWORD"
    echo -e "${GREEN}Tag:${RESET} $tag_name"
}

# ================================
# 删除 SOCKS 配置
# ================================
delete_config() {
    list_configs

    read -p "$(echo -e ${RED}请输入要删除的编号${RESET}): " num
    file="$CONF_DIR/$PROTO-$(printf "%02d" $num).json"

    if [[ -f "$file" ]]; then
        rm -f "$file"
        print_ok "已删除编号 $num 的 SOCKS 配置"
    else
        print_error "编号 $num 不存在"
    fi
}

# ================================
# 主菜单
# ================================
config_menu() {
    while true; do
        print_title "SOCKS 配置管理"

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
