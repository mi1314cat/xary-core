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

print_info()  { echo -e "${CYAN}[Info]${RESET} $1"; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}  $1"; }
print_error() { echo -e "${RED}[Error]${RESET} $1"; }

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
PROTO="hysteria"
BASE_DIR="/root/catmi/xray"
CONF_DIR="$BASE_DIR/conf"
CERT_FILE="$BASE_DIR/cert.crt"
KEY_FILE="$BASE_DIR/cert.key"

mkdir -p "$CONF_DIR"

# ================================
# 工具函数
# ================================
random_uuid() {
    # 简单 UUID（32位十六进制）
    tr -dc 'a-f0-9' </dev/urandom | head -c 32
}

random_domain() {
    # 简单伪装域名生成
    sub=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    num=$((RANDOM % 90 + 10))
    echo "cdn-${sub}-${num}.com"
}

port_in_use() {
    local port=$1
    ss -tuln | awk '{print $5}' | grep -E -q "(:|])${port}$"
}

ask_port() {
    local default="$1"
    local input
    while true; do
        read -p "$(echo -e ${YELLOW}请输入 Hysteria2 监听端口${RESET} (回车默认: $default): " input
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

ask_with_default() {
    local prompt="$1"
    local default="$2"
    local var
    read -p "$(echo -e ${YELLOW}$prompt${RESET} (回车默认: $default): " var
    echo "${var:-$default}"
}

generate_self_signed_cert() {
    local domain="$1"

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_info "检测到已有证书，将继续使用：$CERT_FILE / $KEY_FILE"
        return
    fi

    print_info "正在为域名 $domain 生成自签证书..."
    mkdir -p "$BASE_DIR"

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -subj "/CN=$domain" >/dev/null 2>&1

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_ok "自签证书生成完成："
        echo "  证书: $CERT_FILE"
        echo "  私钥: $KEY_FILE"
    else
        print_error "证书生成失败，请检查 openssl 是否安装"
    fi
}

# ================================
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 Hysteria2 配置列表"
    echo -e "${CYAN}编号 | 端口 | UUID | 伪装域名${RESET}"
    echo "-----------------------------------------------------"

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .json | cut -d'-' -f2)

        port=$(jq -r '.inbounds[0].port' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].auth' "$f")
        domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].domain // empty' "$f")
        # 如果没有 domain 字段，就从证书文件名推不出来，这里兼容老配置
        [[ -z "$domain" ]] && domain="(未记录)"

        echo -e "${GREEN}$num${RESET}) 端口: ${BLUE}$port${RESET} | UUID: ${MAGENTA}$uuid${RESET} | 域名: ${YELLOW}$domain${RESET}"
    done

    echo "-----------------------------------------------------"
}

# ================================
# 新增 Hysteria2 配置
# ================================
add_config() {
    print_title "新增 Hysteria2 配置"

    # 询问服务器 IP（用于生成客户端链接）
    server_ip=$(ask_with_default "请输入服务器 IP" "你的服务器IP")

    # 生成随机端口（默认）
    default_port=$((RANDOM % 20000 + 20000))
    while port_in_use "$default_port"; do
        default_port=$((RANDOM % 20000 + 20000))
    done
    hysteria_port=$(ask_port "$default_port")

    # 生成 UUID（auth）
    uuid=$(random_uuid)

    # 生成伪装域名
    domain=$(random_domain)

    # 生成/复用自签证书
    generate_self_signed_cert "$domain"

    # 自动找下一个编号
    next=$(ls "$CONF_DIR"/$PROTO-*.json 2>/dev/null | wc -l)
    next=$((next + 1))
    tag_name="${PROTO}${next}"

    file="$CONF_DIR/$PROTO-$(printf "%02d" $next).json"

    # 这里额外在 tlsSettings.certificates[0] 里加一个自定义字段 "domain" 方便面板读取
    cat <<EOF > "$file"
{
  "inbounds": [
    {
      "tag": "$tag_name",
      "listen": "::",
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
        "hysteriaSettings": {
          "version": 2
        },
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "cert.crt",
              "keyFile": "cert.key",
              "domain": "$domain"
            }
          ]
        },
        "finalmask": {}
      }
    }
  ]
}
EOF

    # 生成客户端链接
    client_link="hysteria2://$uuid@$server_ip:$hysteria_port?sni=$domain&insecure=1#Hysteria2"

    print_ok "Hysteria2 配置已生成："
    echo -e "${GREEN}编号:${RESET} $next"
    echo -e "${GREEN}Tag:${RESET} $tag_name"
    echo -e "${GREEN}监听端口:${RESET} $hysteria_port"
    echo -e "${GREEN}UUID(auth):${RESET} $uuid"
    echo -e "${GREEN}伪装域名:${RESET} $domain"
    echo -e "${GREEN}证书路径:${RESET} $CERT_FILE"
    echo -e "${GREEN}私钥路径:${RESET} $KEY_FILE"
    echo -e "${GREEN}配置文件:${RESET} $file"
    echo
    echo -e "${CYAN}客户端链接:${RESET}"
    echo "$client_link"
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
        print_ok "已删除编号 $num 的 Hysteria2 配置"
    else
        print_error "编号 $num 不存在"
    fi
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Hysteria2 配置管理"

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

main_menu
