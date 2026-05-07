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
PROTO="vless-WS"                     # 用于文件名/tag
PROTO_NAME="VLESS-WS-MLKEM"       # 用于显示
CONF_DIR="/root/catmi/xray/conf"
XRAYLS_BIN="/root/catmi/xray/xrayls"

mkdir -p "$CONF_DIR"

# ================================
# 随机生成函数
# ================================
random_port() { shuf -i 10000-60000 -n 1; }
random_path() { echo "/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)"; }

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
        printf "请输入监听端口 (默认: %s): " "$default" >&2
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

get_next_index() {
    local used=() i=1
    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.json; do
        local base
        base=$(basename "$f")
        if [[ "$base" =~ ^${PROTO}-([0-9]+)\.json$ ]]; then
            used+=("${BASH_REMATCH[1]}")
        fi
    done
    if ((${#used[@]} == 0)); then
        printf "%02d\n" 1
        return
    fi
    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done
    printf "%02d\n" "$i"
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
    echo "3) 本机回环 (127.0.0.1)" >&2

    printf "选择 (默认 1): " >&2
    read choice
    choice=$(clean_input "$choice")

    case "$choice" in
        2) echo "::" ;;
        3) echo "127.0.0.1" ;;
        *) echo "0.0.0.0" ;;
    esac
}

# ================================
# ML-KEM 生成
# ================================
generate_mlkem() {
    print_info "正在生成 ML-KEM（后量子加密 PQ）参数..."

    if [ ! -x "$XRAYLS_BIN" ]; then
        print_error "未找到 xrayls 可执行文件：$XRAYLS_BIN"
        exit 1
    fi

    VLESSENC_OUTPUT=$("$XRAYLS_BIN" vlessenc 2>/dev/null || true)

    if [ -z "$VLESSENC_OUTPUT" ]; then
        print_error "xrayls vlessenc 无输出，无法生成 ML-KEM PQ 加密串"
        exit 1
    fi

    CLEAN_OUTPUT=$(echo "$VLESSENC_OUTPUT" | tr '\n' ' ')

    SERVER_DEC=$(echo "$CLEAN_OUTPUT" | grep -oP '"decryption"\s*:\s*"\K[^"]+' | tail -n 1)
    CLIENT_ENC=$(echo "$CLEAN_OUTPUT" | grep -oP '"encryption"\s*:\s*"\K[^"]+' | tail -n 1)

    if [[ -z "$SERVER_DEC" || -z "$CLIENT_ENC" ]]; then
        print_error "无法解析 ML-KEM-768 加密串"
        echo "$VLESSENC_OUTPUT"
        exit 1
    fi

    print_info "ML-KEM 服务端 decryption: $SERVER_DEC"
    print_info "ML-KEM 客户端 encryption: $CLIENT_ENC"
}

# ================================
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 ${PROTO_NAME} 配置列表"

    echo -e "${CYAN}编号 | 监听地址 | 端口 | UUID | WS 路径 | Tag${RESET}" >&2
    echo "--------------------------------------------------------------------------------" >&2

    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)
        lport=$(jq -r '.inbounds[0].port' "$f")
        listen=$(jq -r '.inbounds[0].listen' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$f")
        wspath=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$f")
        tag=$(jq -r '.inbounds[0].tag' "$f")

        echo -e "${GREEN}$num${RESET}) ${YELLOW}$listen${RESET} | ${CYAN}$lport${RESET} | ${MAGENTA}$uuid${RESET} | ${BLUE}$wspath${RESET} | Tag: ${WHITE}$tag${RESET}" >&2
    done

    echo "--------------------------------------------------------------------------------" >&2
}

# ================================
# 新增配置
# ================================
add_config() {
    print_title "新增 ${PROTO_NAME} 配置"

    detect=$(detect_listen_ip)
    listen_ip=$(choose_listen_ip "$detect")

    default_port=$(random_free_port)
    lport=$(safe_read_port "$default_port")

    # 获取公网 IP（IPv4/IPv6）
    PUBLIC_IP_V4=$(curl -s4 https://api.ipify.org || true)
    PUBLIC_IP_V6=$(curl -s6 https://api64.ipify.org || true)

    if [ -z "$PUBLIC_IP_V4" ] && [ -z "$PUBLIC_IP_V6" ]; then
        print_error "无法检测公网 IP（IPv4/IPv6），请检查网络或手动填写"
        exit 1
    fi

    echo "请选择要使用的公网 IP 地址:"
    [ -n "$PUBLIC_IP_V4" ] && echo "1. IPv4: $PUBLIC_IP_V4"
    [ -n "$PUBLIC_IP_V6" ] && echo "2. IPv6: $PUBLIC_IP_V6"
    read -p "请输入对应的数字选择 [默认1]: " IP_CHOICE
    IP_CHOICE=${IP_CHOICE:-1}

    if [ "$IP_CHOICE" -eq 2 ] && [ -n "$PUBLIC_IP_V6" ]; then
        PUBLIC_IP="$PUBLIC_IP_V6"
    else
        PUBLIC_IP="${PUBLIC_IP_V4:-$PUBLIC_IP_V6}"
    fi

    # IPv6 需要中括号
    if [[ "$PUBLIC_IP" =~ : ]]; then
        link_ip="[$PUBLIC_IP]"
    else
        link_ip="$PUBLIC_IP"
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    default_path=$(random_path)
    WS_PATH1=$(safe_read "请输入 WS 路径" "$default_path")
    WS_PATH1=$(clean_input "$WS_PATH1")
    [[ "$WS_PATH1" != /* ]] && WS_PATH1="/$WS_PATH1"

    generate_mlkem

    next=$(get_next_index)
    tag_name="${PROTO}${next}"
    file="$CONF_DIR/$PROTO-$next.json"

cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "$listen_ip",
      "port": $lport,
      "tag": "$tag_name",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "$SERVER_DEC"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH1"
        }
      }
    }
  ]
}
EOF

    print_ok "新增 ${PROTO_NAME} 配置成功"
    echo -e "编号: $next\n监听地址: $listen_ip\n端口: $lport\nUUID: $UUID\nWS 路径: $WS_PATH1\nTag: $tag_name" >&2
    echo >&2

    # ============================
    #   保存客户端文件（优化版）
    # ============================

    mkdir -p /root/catmi/xray/out

    # 生成客户端链接
    link="vless://${UUID}@${link_ip}:${lport}?type=ws&path=${WS_PATH1}&encryption=${CLIENT_ENC}#vless-ws-mlkem"

    # ① 保存链接（按协议分类）
    echo "[$next] $link" >> /root/catmi/xray/out/${PROTO}.txt

    # ② 保存 YAML（按协议分类）
cat >> /root/catmi/xray/out/${PROTO}.yaml <<EOF

# [$next] vless-ws-mlkem-$next
- name: vless-ws-mlkem-$next
  type: vless
  server: $PUBLIC_IP
  port: $lport
  uuid: $UUID
  encryption: $CLIENT_ENC
  network: ws
  ws-opts:
    path: $WS_PATH1
EOF

    # ============================
    #   控制台输出
    # ============================

    print_info "=== 客户端链接 ==="
    echo "$link" >&2
    echo >&2

    print_info "=== YAML 客户端配置示例 ==="
    cat >&2 <<EOF
- name: vless-ws-mlkem-$next
  type: vless
  server: $PUBLIC_IP
  port: $lport
  uuid: $UUID
  encryption: $CLIENT_ENC
  network: ws
  ws-opts:
    path: $WS_PATH1
EOF
    echo >&2
}


# ================================
# 删除配置
# ================================
delete_config() {
    list_configs

    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    num_fmt=$(printf "%02d" "$num")

    file="$CONF_DIR/$PROTO-$num_fmt.json"

    if [[ -f "$file" ]]; then
        rm -f "$file"
        print_ok "已删除编号 $num_fmt 的 ${PROTO_NAME} 配置"
    else
        print_error "编号 $num_fmt 不存在"
    fi
}

# ================================
# 主菜单
# ================================
config_menu() {
    while true; do
        print_title "${PROTO_NAME} 配置管理"

        echo "1) 查看所有配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "0) 退出" >&2

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
                return
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
