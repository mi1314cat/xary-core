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

print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1"; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1"; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1"; }

print_title() {
    printf "${MAGENTA}${BOLD}"
    printf "╔══════════════════════════════════════╗\n"
    printf "║ %-36s ║\n" "$1"
    printf "╚══════════════════════════════════════╝\n"
    printf "${RESET}"
}

# ================================
# 基础变量
# ================================
PROTO="hysteria"
BASE_DIR="/root/catmi/xray"
CONF_DIR="$BASE_DIR/conf"
mkdir -p "$CONF_DIR"

CERT_FILE=""
KEY_FILE=""

# ================================
# 依赖检查
# ================================
command -v jq >/dev/null 2>&1 || {
    print_error "未安装 jq，请先执行: apt install jq -y"
    exit 1
}

# ================================
# 工具函数
# ================================
random_uuid() {
    uuidgen | tr 'A-Z' 'a-z'
}

random_domain() {
    sub=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    num=$((RANDOM % 90 + 10))
    echo "cdn-${sub}-${num}.com"
}

port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | awk '{print $5}' | grep -E -q "(:|])$1$"
    else
        netstat -tuln | awk '{print $4}' | grep -E -q "(:|])$1$"
    fi
}

ask_port() {
    local default="$1"
    local input
    while true; do
        printf "请输入 Hysteria2 监听端口 (默认: %s): " "$default"
        read input
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口已占用"; continue; }

        echo "$port"
        return
    done
}

detect_listen_ip() {
    local has_ipv4=false
    local has_ipv6=false

    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true

    print_info "自动检测结果："
    $has_ipv4 && echo "  - 检测到 IPv4"
    $has_ipv6 && echo "  - 检测到 IPv6"
    (! $has_ipv4 && ! $has_ipv6) && echo "  - 未检测到公网 IP"

    echo
    echo "请选择监听地址："
    echo "1) IPv4 (0.0.0.0)"
    echo "2) IPv6 (::)"
    echo "3) 自动推荐"

    printf "选择 (默认 1): "
    read choice

    case "$choice" in
        2) echo "::" ;;
        3)
            if $has_ipv4 && ! $has_ipv6; then echo "0.0.0.0"
            elif ! $has_ipv4 && $has_ipv6; then echo "::"
            else echo "0.0.0.0"
            fi
            ;;
        *) echo "0.0.0.0" ;;
    esac
}


generate_self_signed_cert() {
    local domain="$1"

    CERT_FILE="$BASE_DIR/cert-$domain.crt"
    KEY_FILE="$BASE_DIR/key-$domain.key"

    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] && return

    print_info "生成证书: $domain"

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -subj "/CN=$domain" >/dev/null 2>&1

    [[ -f "$CERT_FILE" ]] && print_ok "证书生成成功"
}

get_next_index() {
    ls "$CONF_DIR"/$PROTO-*.json 2>/dev/null | \
    sed -E 's/.*-([0-9]+)\.json/\1/' | sort -n | tail -1
}

# ================================
# 显示配置
# ================================
list_configs() {
    print_title "配置列表"

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .json | cut -d'-' -f2)

        port=$(jq -r '.inbounds[0].port' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].auth' "$f")
        domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].domain' "$f")

        printf "${GREEN}%s${RESET}) 端口:${BLUE}%s${RESET} UUID:${MAGENTA}%s${RESET} 域名:${YELLOW}%s${RESET}\n" \
        "$num" "$port" "$uuid" "$domain"
    done
}

# ================================
# 新增配置
# ================================
add_config() {
    print_title "新增配置"

    default_ip=$(curl -4 -s ip.sb || hostname -I | awk '{print $1}')
    read -p "服务器IP (默认:$default_ip): " server_ip
    server_ip="${server_ip:-$default_ip}"

    listen_ip=$(detect_listen_ip)

    default_port=$((RANDOM % 20000 + 20000))
    while port_in_use "$default_port"; do
        default_port=$((RANDOM % 20000 + 20000))
    done

    hysteria_port=$(ask_port "$default_port")
    uuid=$(random_uuid)
    domain=$(random_domain)

    generate_self_signed_cert "$domain"

    next=$(get_next_index)
    next=$((next + 1))
    file="$CONF_DIR/$PROTO-$(printf "%02d" $next).json"

cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "$listen_ip",
      "port": $hysteria_port,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "$uuid"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [
            {
              "certificateFile": "$CERT_FILE",
              "keyFile": "$KEY_FILE",
              "domain": "$domain"
            }
          ]
        }
      }
    }
  ]
}
EOF

    link="hysteria2://$uuid@$server_ip:$hysteria_port?sni=$domain&insecure=1#hy2"

    print_ok "配置生成成功"
    echo "端口: $hysteria_port"
    echo "UUID: $uuid"
    echo "域名: $domain"
    echo "监听: $listen_ip"
    echo "配置: $file"
    echo -e "\n客户端:\n$link"
}

# ================================
# 删除配置
# ================================
delete_config() {
    list_configs
    read -p "输入编号: " num

    file="$CONF_DIR/$PROTO-$(printf "%02d" $num).json"

    if [[ -f "$file" ]]; then
        domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].domain' "$file")
        rm -f "$file"
        rm -f "$BASE_DIR/cert-$domain.crt" "$BASE_DIR/key-$domain.key"
        print_ok "已删除"
    else
        print_error "不存在"
    fi
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Hysteria2 管理"

        echo "1) 查看"
        echo "2) 新增"
        echo "3) 删除"
        echo "0) 退出"

        read -p "选择: " c

        case $c in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            0) exit ;;
            *) print_error "无效" ;;
        esac

        read -p "回车继续..."
    done
}

main_menu
