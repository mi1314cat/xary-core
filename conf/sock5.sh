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
# 打印函数（全部输出到 stderr，避免污染变量）
# ================================
print_info()  { echo -e "${CYAN}[Info]${RESET} $1" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}  $1" >&2; }
print_error() { echo -e "${RED}[Error]${RESET} $1" >&2; }

print_title() {
    echo -e "${MAGENTA}${BOLD}" >&2
    echo "╔══════════════════════════════════════════════╗" >&2
    printf "║ %-42s ║\n" "$1" >&2
    echo "╚══════════════════════════════════════════════╝" >&2
    echo -e "${RESET}" >&2
}

# ================================
# 基础变量
# ================================
PROTO="socks"
CONF_DIR="/root/catmi/xray/conf"
mkdir -p "$CONF_DIR"

# ================================
# 随机生成函数
# ================================
random_port() { shuf -i 10000-60000 -n 1; }
random_user() { tr -dc A-Za-z0-9 </dev/urandom | head -c 8; }
random_pass() { tr -dc A-Za-z0-9 </dev/urandom | head -c 12; }

# ================================
# 端口检测
# ================================
port_in_use() {
    ss -tuln | awk '{print $5}' | grep -E -q "(:|])$1$"
}

random_free_port() {
    while true; do
        port=$(random_port)
        if ! port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
}

# ================================
# 安全输入（过滤控制字符）
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

safe_read() {
    local prompt="$1"
    local default="$2"
    local input

    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

safe_read_port() {
    local default="$1"
    local input

    while true; do
        printf "请输入本地监听端口 (默认: %s): " "$default" >&2
        read input
        input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口已占用"; continue; }

        echo "$port"
        return
    done
}

# ================================
# IPv4 / IPv6 自动检测
# ================================
detect_listen_ip() {
    local has_ipv4=false
    local has_ipv6=false

    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true

    if $has_ipv4 && ! $has_ipv6; then echo "ipv4"
    elif ! $has_ipv4 && $has_ipv6; then echo "ipv6"
    elif $has_ipv4 && $has_ipv6; then echo "dual"
    else echo "none"
    fi
}

# ================================
# 监听地址选择
# ================================
choose_listen_ip() {
    local detect="$1"

    print_info "自动检测结果："
    [[ "$detect" == "ipv4" ]] && echo "  - 检测到 IPv4" >&2
    [[ "$detect" == "ipv6" ]] && echo "  - 检测到 IPv6" >&2
    [[ "$detect" == "dual" ]] && echo "  - 检测到 IPv4 + IPv6" >&2
    [[ "$detect" == "none" ]] && echo "  - 未检测到公网 IP" >&2

    echo >&2
    echo "请选择监听地址：" >&2
    echo "1) IPv4 (0.0.0.0)" >&2
    echo "2) IPv6 (::)" >&2
    echo "3) 自动推荐" >&2

    printf "选择 (默认 1): " >&2
    read choice
    choice=$(clean_input "$choice")

    case "$choice" in
        2) echo "::" ;;
        3)
            case "$detect" in
                ipv4) echo "0.0.0.0" ;;
                ipv6) echo "::" ;;
                dual) echo "0.0.0.0" ;;
                none) echo "0.0.0.0" ;;
            esac
            ;;
        *) echo "0.0.0.0" ;;
    esac
}

# ================================
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 SOCKS 配置列表"

    echo -e "${CYAN}编号 | 用户名 | 密码 | 本地端口 | Tag${RESET}" >&2
    echo "--------------------------------------------------------" >&2

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)
        lport=$(jq -r '.inbounds[0].port' "$f")
        user=$(jq -r '.inbounds[0].settings.accounts[0].user' "$f")
        pass=$(jq -r '.inbounds[0].settings.accounts[0].pass' "$f")
        tag=$(jq -r '.inbounds[0].tag' "$f")

        echo -e "${GREEN}$num${RESET}) 用户: ${YELLOW}$user${RESET} | 密码: ${MAGENTA}$pass${RESET} | 端口: ${CYAN}$lport${RESET} | Tag: ${BLUE}$tag${RESET}" >&2
    done

    echo "--------------------------------------------------------" >&2
}

# ================================
# 新增配置
# ================================
add_config() {
    print_title "新增 SOCKS 配置"

    detect=$(detect_listen_ip)
    listen_ip=$(choose_listen_ip "$detect")

    default_port=$(random_free_port)
    default_user=$(random_user)
    default_pass=$(random_pass)

    lport=$(safe_read_port "$default_port")
    SOCKS_USERNAME=$(safe_read "请输入 SOCKS 用户名" "$default_user")
    SOCKS_PASSWORD=$(safe_read "请输入 SOCKS 密码" "$default_pass")

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
    echo -e "编号: $next\n监听地址: $listen_ip\n端口: $lport\n用户名: $SOCKS_USERNAME\n密码: $SOCKS_PASSWORD\nTag: $tag_name" >&2
}

# ================================
# 删除配置
# ================================
delete_config() {
    list_configs

    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")

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

        echo "1) 查看所有配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "0) 返回主菜单" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case $c in
            1)
                list_configs
                printf "按回车继续..." >&2
                read
            ;;
            2)
                add_config
                printf "按回车继续..." >&2
                read
            ;;
            3)
                delete_config
                printf "按回车继续..." >&2
                read
            ;;
            0)
                return   # ← 返回主菜单，不暂停
            ;;
            *)
                print_error "无效选项"
                printf "按回车继续..." >&2
                read
            ;;
        esac
    done
}

config_menu
