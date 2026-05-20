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
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; MAGENTA="\e[35m"; WHITE="\e[97m"; BOLD="\e[1m"; RESET="\e[0m"

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
PROTO="reverse-client"
PROTO_NAME="Xray Reverse Client"
CONF_DIR="/root/catmi/xray/conf"
OUT_DIR="/root/catmi/xray/out"
XRAYLS_BIN="/root/catmi/xray/xrayls"

FALLBACK_ENC="mlkem768x25519plus.native.600s.OEYSQhMul9UVxme8omvFtznEWqQViMIEORBJp0fVKekmjMwzBj1NwCikhruSYboDfvnnCS2XTXjWOv1W7PAw4w"

mkdir -p "$CONF_DIR" "$OUT_DIR"

# ================================
# 随机端口
# ================================
random_port() { shuf -i 10000-60000 -n 1; }
port_in_use() { ss -tuln | awk '{print $5}' | grep -q ":${1}$"; }

random_free_port() {
    while true; do
        p=$(random_port)
        if ! port_in_use "$p"; then echo "$p"; return; fi
    done
}

clean_input() { echo "$1" | tr -d '\000-\037'; }

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "请输入本地反向入口端口 (默认 %s): " "$default" >&2
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
# UUID
# ================================
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# ================================
# ML-KEM（仅用于获取默认值）
# ================================
generate_mlkem() {
    if [ ! -x "$XRAYLS_BIN" ]; then
        SERVER_DEC="$FALLBACK_ENC"
        CLIENT_ENC="$FALLBACK_ENC"
        return
    fi

    local out=$("$XRAYLS_BIN" vlessenc 2>/dev/null)
    SERVER_DEC=$(echo "$out" | grep -oP '"decryption"\s*:\s*"\K[^"]+')
    CLIENT_ENC=$(echo "$out" | grep -oP '"encryption"\s*:\s*"\K[^"]+')

    [[ -z "$SERVER_DEC" ]] && SERVER_DEC="$FALLBACK_ENC"
    [[ -z "$CLIENT_ENC" ]] && CLIENT_ENC="$FALLBACK_ENC"
}

# ================================
# 自动编号（01、02、03…）
# ================================
get_next_index() {
    local used=() i=1 f base
    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.json; do
        base=$(basename "$f")
        if [[ "$base" =~ ^${PROTO}-([0-9]+)\.json$ ]]; then
            used+=("${BASH_REMATCH[1]}")
        fi
    done
    if ((${#used[@]} == 0)); then printf "%02d\n" 1; return; fi
    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do [[ "$n" -ne "$i" ]] && break; ((i++)); done
    printf "%02d\n" "$i"
}

# ================================
# 监听地址选择
# ================================
choose_listen_ip() {
    echo "请选择本地监听地址：" >&2
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
# 列出所有配置
# ================================
list_configs() {
    print_title "当前 ${PROTO_NAME} 配置列表"

    echo -e "${CYAN}编号 | 监听地址 | 本地端口 | 服务端地址 | 服务端端口 | UUID | Encryption${RESET}" >&2
    echo "--------------------------------------------------------------------------------------------------------" >&2

    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)

        # 提取入站信息
        listen=$(jq -r '.inbounds[0].listen' "$f")
        local_port=$(jq -r '.inbounds[0].port' "$f")

        # 提取出站中 vless 协议的信息
        server_addr=$(jq -r '.outbounds[] | select(.protocol=="vless") | .settings.address' "$f")
        server_port=$(jq -r '.outbounds[] | select(.protocol=="vless") | .settings.port' "$f")
        uuid=$(jq -r '.outbounds[] | select(.protocol=="vless") | .settings.id' "$f")
        encryption=$(jq -r '.outbounds[] | select(.protocol=="vless") | .settings.encryption' "$f")

        echo -e "${GREEN}$num${RESET}) ${YELLOW}$listen${RESET} | ${CYAN}$local_port${RESET} | ${WHITE}$server_addr${RESET} | ${CYAN}$server_port${RESET} | ${MAGENTA}$uuid${RESET} | ${BLUE}$encryption${RESET}" >&2
    done
    echo "--------------------------------------------------------------------------------------------------------" >&2
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
        # 同步删除客户端记录文件中与该编号相关的条目
        if [[ -f "$OUT_DIR/${PROTO}.txt" ]]; then
            sed -i "/^\[$num_fmt\] /d" "$OUT_DIR/${PROTO}.txt" 2>/dev/null
        fi
        if [[ -f "$OUT_DIR/${PROTO}.yaml" ]]; then
            awk -v num="$num_fmt" '
                BEGIN { skip=0 }
                /^# \['"$num_fmt"'\]/ { skip=1; next }
                skip && /^$/ { skip=0; next }
                !skip { print }
            ' "$OUT_DIR/${PROTO}.yaml" > "$OUT_DIR/${PROTO}.yaml.tmp" && mv "$OUT_DIR/${PROTO}.yaml.tmp" "$OUT_DIR/${PROTO}.yaml"
        fi
        print_ok "已删除编号 $num_fmt 的 ${PROTO_NAME} 配置及记录"
    else
        print_error "编号 $num_fmt 不存在"
    fi
}

# ================================
# 新增配置
# ================================
add_config() {
    print_title "新增反向代理客户端配置"

    # 服务端信息录入
    printf "请输入服务端 IP 或域名: " >&2
    read SERVER_ADDR
    SERVER_ADDR=$(clean_input "$SERVER_ADDR")
    [[ -z "$SERVER_ADDR" ]] && { print_error "服务端地址不能为空"; return; }

    printf "请输入服务端 VLESS 端口: " >&2
    read SERVER_PORT
    SERVER_PORT=$(clean_input "$SERVER_PORT")
    [[ -z "$SERVER_PORT" ]] && { print_error "服务端端口不能为空"; return; }

    printf "请输入服务端 UUID: " >&2
    read UUID
    UUID=$(clean_input "$UUID")
    [[ -z "$UUID" ]] && { print_error "UUID 不能为空"; return; }

    printf "请输入服务端提供的 encryption (ML-KEM): " >&2
    read CLIENT_ENC
    CLIENT_ENC=$(clean_input "$CLIENT_ENC")
    if [[ -z "$CLIENT_ENC" ]]; then
        print_info "未输入 encryption，使用 fallback 值"
        generate_mlkem
        CLIENT_ENC="$FALLBACK_ENC"
    fi

    local listen_ip=$(choose_listen_ip)
    local local_port=$(safe_read_port "$(random_free_port)")
    local next=$(get_next_index)

    local reverse_in="reverse-in-${next}"
    local reverse_direct="reverse-direct-${next}"

    local file="$CONF_DIR/$PROTO-$next.json"

    jq -n \
        --arg listen "$listen_ip" \
        --argjson lport "$local_port" \
        --arg addr "$SERVER_ADDR" \
        --argjson sport "$SERVER_PORT" \
        --arg uuid "$UUID" \
        --arg enc "$CLIENT_ENC" \
        --arg rin "$reverse_in" \
        --arg rout "$reverse_direct" \
        '{
            inbounds: [
                {
                    listen: $listen,
                    port: $lport,
                    protocol: "dokodemo-door",
                    tag: $rin,
                    settings: { address: "127.0.0.1" }
                }
            ],
            outbounds: [
                {
                    protocol: "vless",
                    tag: "reverse-out",
                    settings: {
                        address: $addr,
                        port: $sport,
                        id: $uuid,
                        encryption: $enc,
                        flow: "xtls-rprx-vision",
                        reverse: { tag: $rin }
                    }
                },
                {
                    protocol: "freedom",
                    tag: $rout,
                    settings: { redirect: "127.0.0.1:80" }
                }
            ],
            routing: {
                rules: [
                    {
                        inboundTag: [$rin],
                        outboundTag: $rout
                    }
                ]
            }
        }' > "$file"

    print_ok "客户端配置已生成：$file"

    # ============================
    # 保存配置记录（用于管理）
    # ============================
    # 纯文本记录
    echo "[$next] 本地端口: $local_port | 服务端: $SERVER_ADDR:$SERVER_PORT | UUID: $UUID | encryption: $CLIENT_ENC" >> "$OUT_DIR/${PROTO}.txt"

    # YAML 记录
    cat >> "$OUT_DIR/${PROTO}.yaml" <<EOF

# [$next] reverse-client-${next}
name: reverse-client-${next}
type: reverse-client
local_listen: $listen_ip
local_port: $local_port
server_addr: $SERVER_ADDR
server_port: $SERVER_PORT
uuid: $UUID
encryption: $CLIENT_ENC
flow: xtls-rprx-vision
reverse_in_tag: $reverse_in
reverse_direct_tag: $reverse_direct
EOF

    # ============================
    # 控制台输出
    # ============================
    print_info "=== 客户端信息 ==="
    echo "编号: $next" >&2
    echo "监听地址: $listen_ip" >&2
    echo "本地反向入口端口: $local_port" >&2
    echo "服务端地址: $SERVER_ADDR" >&2
    echo "服务端端口: $SERVER_PORT" >&2
    echo "UUID: $UUID" >&2
    echo "encryption: $CLIENT_ENC" >&2
    echo "Reverse-In Tag: $reverse_in" >&2
    echo "Reverse-Direct Tag: $reverse_direct" >&2
    echo >&2
    print_ok "配置记录已保存到 $OUT_DIR/${PROTO}.txt 和 $OUT_DIR/${PROTO}.yaml"
}

# ================================
# 主菜单
# ================================
menu() {
    while true; do
        print_title "反向代理客户端管理"
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
                echo "退出" >&2
                exit 0
                ;;
            *)
                print_error "无效选项"
                printf "按回车继续..." >&2
                read
                ;;
        esac
    done
}

menu
