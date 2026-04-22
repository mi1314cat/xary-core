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
# 打印函数（全部输出到 stderr）
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
# 基础变量
# ================================
PROTO="hysteria"
BASE_DIR="/root/catmi/xray"
CONF_DIR="$BASE_DIR/conf"
mkdir -p "$CONF_DIR"

# Hysteria2 专用证书目录
CERT_DIR="$BASE_DIR/Hysteria2"
mkdir -p "$CERT_DIR"

# ================================
# 输入清理
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

# ================================
# 安全输入（不会污染 JSON）
# ================================
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
        printf "请输入监听端口 (默认: %s): " "$default" >&2
        read input
        input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        ss -tuln | awk '{print $5}' | grep -E -q "(:|])$port$" && { print_error "端口已占用"; continue; }

        echo "$port"
        return
    done
}

# ================================
# 随机生成工具
# ================================
random_domain() {
    sub=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    num=$((RANDOM % 90 + 10))
    echo "cdn-${sub}-${num}.com"
}

# ================================
# 自动修复 uuidgen 缺失
# ================================
ensure_uuidgen() {
    if ! command -v uuidgen >/dev/null 2>&1; then
        print_info "uuidgen 未安装，正在自动安装..."
        apt update -y >/dev/null 2>&1
        apt install uuid-runtime -y >/dev/null 2>&1
        print_ok "uuidgen 安装完成"
    fi
}

# ================================
# IP 检测
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
# 证书目录（修复：放在 Hysteria2 文件夹）
# ================================
CERT_DIR="$BASE_DIR/Hysteria2"
mkdir -p "$CERT_DIR"

# ================================
# 自动修复 uuidgen 缺失问题
# ================================
ensure_uuidgen() {
    if ! command -v uuidgen >/dev/null 2>&1; then
        print_info "uuidgen 未安装，正在自动安装..."
        apt update -y >/dev/null 2>&1
        apt install uuid-runtime -y >/dev/null 2>&1
        print_ok "uuidgen 安装完成"
    fi
}

# ================================
# 生成自签证书（放入 Hysteria2 目录）
# ================================
generate_self_signed_cert() {
    local domain="$1"

    CERT_FILE="$CERT_DIR/cert-$domain.crt"
    KEY_FILE="$CERT_DIR/key-$domain.key"

    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] && return

    print_info "生成自签证书: $domain"

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -subj "/CN=$domain" >/dev/null 2>&1

    print_ok "证书生成成功"
}

# ================================
# 获取下一个编号（01、02、03…）
# ================================
get_next_index() {
    ls "$CONF_DIR"/$PROTO-*.json 2>/dev/null | \
    sed -E 's/.*-([0-9]+)\.json/\1/' | sort -n | tail -1
}

# ================================
# 新增配置（核心修复版）
# ================================
add_config() {
    print_title "新增 Hysteria2 配置"

    ensure_uuidgen

    default_ip=$(curl -4 -s ip.sb || hostname -I | awk '{print $1}')
    server_ip=$(safe_read "服务器 IP" "$default_ip")

    detect=$(detect_listen_ip)
    listen_ip=$(choose_listen_ip "$detect")

    default_port=$((RANDOM % 20000 + 20000))
    while port_in_use "$default_port"; do
        default_port=$((RANDOM % 20000 + 20000))
    done

    hysteria_port=$(safe_read_port "$default_port")
    uuid=$(uuidgen | tr 'A-Z' 'a-z')
    domain=$(random_domain)

    generate_self_signed_cert "$domain"

    next=$(get_next_index)
    next=$((next + 1))
    index=$(printf "%02d" $next)

    file="$CONF_DIR/$PROTO-$index.json"

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

    link="hysteria2://$uuid@$server_ip:$hysteria_port?sni=$domain&insecure=1#hysteria-$index"

    print_ok "配置生成成功"
    echo -e "编号: $index\n端口: $hysteria_port\nUUID: $uuid\n域名: $domain\n监听: $listen_ip\n配置文件: $file" >&2
    echo -e "\n客户端链接:\n$link" >&2
}
# ================================
# 显示配置（修复 UUID 显示）
# ================================
list_configs() {
    print_title "Hysteria2 配置列表"

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)
        port=$(jq -r '.inbounds[0].port' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].auth' "$f")
        domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].domain' "$f")

        printf "${GREEN}%s${RESET}) 端口:${BLUE}%s${RESET}  UUID:${MAGENTA}%s${RESET}  域名:${YELLOW}%s${RESET}\n" \
        "$num" "$port" "$uuid" "$domain" >&2
    done
}

# ================================
# 删除配置（自动删除证书）
# ================================
delete_config() {
    list_configs
    printf "输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")

    file="$CONF_DIR/$PROTO-$(printf "%02d" $num).json"

    if [[ -f "$file" ]]; then
        domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].domain' "$file")

        rm -f "$file"
        rm -f "$CERT_DIR/cert-$domain.crt" "$CERT_DIR/key-$domain.key"

        print_ok "已删除配置 $num（含证书）"
    else
        print_error "编号不存在"
    fi
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Hysteria2 管理面板"

        echo "1) 查看配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case $c in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        printf "按回车继续..." >&2
        read
    done
}

main_menu
