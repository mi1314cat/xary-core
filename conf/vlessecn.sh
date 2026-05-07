#!/bin/bash

# ================================
# 依赖检查
# ================================
if ! command -v jq &>/dev/null; then
    echo -e "\e[31m[ERROR]\e[0m 需要安装 jq，请执行: apt install -y jq 或 yum install -y jq"
    exit 1
fi

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
PROTO="vless-tcp-mlkem"
PROTO_NAME="VLESS-TCP-ML-KEM"
CONF_DIR="/root/catmi/xray/conf"
XRAYLS_BIN="/root/catmi/xray/xrayls"   # 必需，用于生成 ML-KEM 密钥

# 备用固定密钥（当 xrayls 不可用时自动使用）
FALLBACK_ENC="mlkem768x25519plus.native.600s.OEYSQhMul9UVxme8omvFtznEWqQViMIEORBJp0fVKekmjMwzBj1NwCikhruSYboDfvnnCS2XTXjWOv1W7PAw4w"

mkdir -p "$CONF_DIR"

# ================================
# 随机生成函数
# ================================
random_port() { shuf -i 10000-60000 -n 1; }

# 修正后的端口检测：精确匹配行末 ":端口号"
port_in_use() { ss -tuln | awk '{print $5}' | grep -q ":${1}$"; }

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
clean_input() { echo "$1" | tr -d '\000-\037'; }

safe_read() {
    local prompt="$1" default="$2" input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "请输入监听端口 (1-65535, 默认: %s): " "$default" >&2
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
    local used=() i=1 f base
    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.json; do
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
    local has_ipv4=false has_ipv6=false
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
    local detect="$1" choice
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
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 ${PROTO_NAME} 配置列表"

    echo -e "${CYAN}编号 | 监听地址 | 端口 | UUID | Tag${RESET}" >&2
    echo "--------------------------------------------------------------------------------" >&2

    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .json | cut -d'-' -f2)
        if ! jq empty "$f" 2>/dev/null; then
            echo -e "${RED}[损坏]${RESET} $num (无法解析 JSON)" >&2
            continue
        fi
        lport=$(jq -r '.inbounds[0].port' "$f")
        listen=$(jq -r '.inbounds[0].listen' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$f")
        tag=$(jq -r '.inbounds[0].tag' "$f")
        echo -e "${GREEN}$num${RESET}) ${YELLOW}$listen${RESET} | ${CYAN}$lport${RESET} | ${MAGENTA}$uuid${RESET} | Tag: ${WHITE}$tag${RESET}" >&2
    done
    echo "--------------------------------------------------------------------------------" >&2
}

# ================================
# 公网 IP 获取（支持手动输入）
# ================================
get_public_ip() {
    local ipv4 ipv6 choice manual_ip
    ipv4=$(curl -s4 --connect-timeout 3 https://api.ipify.org 2>/dev/null || true)
    ipv6=$(curl -s6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || true)

    if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
        print_error "无法自动检测公网 IP，请手动输入"
        while true; do
            printf "请输入服务器公网 IP（IPv4 或 IPv6）: " >&2
            read manual_ip
            manual_ip=$(clean_input "$manual_ip")
            if [[ "$manual_ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
                echo "$manual_ip"
                return
            fi
            print_error "IP 格式无效"
        done
    fi

    echo "请选择对外 IP:" >&2
    [ -n "$ipv4" ] && echo "1) IPv4: $ipv4" >&2
    [ -n "$ipv6" ] && echo "2) IPv6: $ipv6" >&2
    echo "3) 手动输入" >&2

    while true; do
        printf "选择 (默认 1): " >&2
        read choice
        choice=$(clean_input "${choice:-1}")
        case $choice in
            1) [ -n "$ipv4" ] && { echo "$ipv4"; return; } || print_error "IPv4 不可用" ;;
            2) [ -n "$ipv6" ] && { echo "$ipv6"; return; } || print_error "IPv6 不可用" ;;
            3) printf "输入 IP: " >&2; read manual_ip
               manual_ip=$(clean_input "$manual_ip")
               if [[ "$manual_ip" =~ ^[0-9a-fA-F:.]+$ ]]; then echo "$manual_ip"; return; fi
               print_error "格式无效" ;;
            *) print_error "选项无效" ;;
        esac
    done
}

# ================================
# UUID 生成 + 校验
# ================================
generate_uuid() {
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$uuid"
    else
        print_error "UUID 生成失败，请检查系统环境"
        exit 1
    fi
}

# ================================
# ML-KEM 参数生成（核心优化）
# ================================
generate_mlkem() {
    if [ ! -x "$XRAYLS_BIN" ]; then
        print_error "未找到 xrayls 可执行文件: $XRAYLS_BIN"
        print_info "将使用备用固定加密密钥（功能不受影响）"
        SERVER_DEC="$FALLBACK_ENC"
        CLIENT_ENC="$FALLBACK_ENC"
        return 0
    fi

    print_info "正在通过 xrayls 生成 ML-KEM 参数..."
    local output
    output=$("$XRAYLS_BIN" vlessenc 2>/dev/null || true)
    if [ -z "$output" ]; then
        print_error "xrayls vlessenc 无输出，回退到固定密钥"
        SERVER_DEC="$FALLBACK_ENC"
        CLIENT_ENC="$FALLBACK_ENC"
        return 0
    fi

    SERVER_DEC=$(echo "$output" | grep -oP '"decryption"\s*:\s*"\K[^"]+' | tail -1)
    CLIENT_ENC=$(echo "$output" | grep -oP '"encryption"\s*:\s*"\K[^"]+' | tail -1)

    if [ -z "$SERVER_DEC" ] || [ -z "$CLIENT_ENC" ]; then
        print_error "解析 ML-KEM 参数失败，回退到固定密钥"
        SERVER_DEC="$FALLBACK_ENC"
        CLIENT_ENC="$FALLBACK_ENC"
    else
        print_info "服务端 decryption: $SERVER_DEC"
        print_info "客户端 encryption: $CLIENT_ENC"
    fi
}

# ================================
# 新增配置（使用 jq 动态生成 JSON）
# ================================
add_config() {
    print_title "新增 ${PROTO_NAME} 配置"

    # 1. 监听地址
    local detect=$(detect_listen_ip)
    local listen_ip=$(choose_listen_ip "$detect")

    # 2. 端口
    local default_port=$(random_free_port)
    local lport=$(safe_read_port "$default_port")

    # 3. 公网 IP
    local PUBLIC_IP=$(get_public_ip)
    local link_ip
    if [[ "$PUBLIC_IP" =~ : ]]; then
        link_ip="[$PUBLIC_IP]"
    else
        link_ip="$PUBLIC_IP"
    fi

    # 4. UUID
    local UUID=$(generate_uuid)

    # 5. ML-KEM 密钥（调用动态生成函数）
    generate_mlkem

    # 6. 索引与文件名
    local next=$(get_next_index)
    local tag_name="${PROTO}-${next}"
    local file="$CONF_DIR/$PROTO-$next.json"

    # 7. 使用 jq 安全生成 JSON
    jq -n \
        --arg listen "$listen_ip" \
        --argjson port "$lport" \
        --arg tag "$tag_name" \
        --arg uuid "$UUID" \
        --arg dec "$SERVER_DEC" \
        '{
            inbounds: [{
                listen: $listen,
                port: $port,
                tag: $tag,
                protocol: "vless",
                settings: {
                    clients: [{id: $uuid}],
                    decryption: $dec
                },
                streamSettings: {
                    network: "tcp"
                }
            }]
        }' > "$file"

    # 8. 验证 JSON
    if ! jq empty "$file" 2>/dev/null; then
        print_error "生成的 JSON 无效，请检查！文件：$file"
        cat "$file" >&2
        exit 1
    fi

    print_ok "新增 ${PROTO_NAME} 配置成功"
    echo -e "编号: $next\n监听地址: $listen_ip\n端口: $lport\nUUID: $UUID\nTag: $tag_name" >&2
    echo >&2

# 确保目录存在
mkdir -p /root/catmi/xray/out


    # 9. 客户端链接（移除无效的 flow 参数，只保留必要参数）
    print_info "=== 客户端链接 ==="
    link="vless://${UUID}@${link_ip}:${lport}?type=tcp&encryption=${CLIENT_ENC}#vless-tcp-mlkem" 
    # 追加写入文件
    echo "$link" >> /root/catmi/xray/out/${PROTO_NAME}.txt

    # 10. YAML 示例
    print_info "=== YAML 客户端配置示例 ==="
    cat >&2 <<EOF
- name: vless-tcp-mlkem-$next
  type: vless
  server: $PUBLIC_IP
  port: $lport
  uuid: $UUID
  encryption: $CLIENT_ENC
  network: tcp
  flow: ""   # TCP 无需 flow，可省略此行
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
    local num_fmt=$(printf "%02d" "$num")
    local file="$CONF_DIR/$PROTO-$num_fmt.json"

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

# ================================
# 程序入口
# ================================
config_menu
