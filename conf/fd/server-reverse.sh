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
PROTO="reverse-server"
PROTO_NAME="Xray Reverse Server (WS)"
CONF_DIR="/root/catmi/xray/conf"
OUT_DIR="/root/catmi/xray/out"
XRAYLS_BIN="/root/catmi/xray/xrayls"

FALLBACK_ENC="mlkem768x25519plus.native.600s.OEYSQhMul9UVxme8omvFtznEWqQViMIEORBJp0fVKekmjMwzBj1NwCikhruSYboDfvnnCS2XTXjWOv1W7PAw4w"

mkdir -p "$CONF_DIR" "$OUT_DIR"

# ================================
# 随机路径（用于 WebSocket）
# ================================
random_path() { echo "/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)"; }

# ================================
# 随机端口及工具
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
        printf "请输入端口 (默认 %s): " "$default" >&2
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
# ML-KEM（清理换行符）
# ================================
generate_mlkem() {
    if [ ! -x "$XRAYLS_BIN" ]; then
        SERVER_DEC="$FALLBACK_ENC"
        CLIENT_ENC="$FALLBACK_ENC"
        return
    fi

    local out=$("$XRAYLS_BIN" vlessenc 2>/dev/null)
    SERVER_DEC=$(echo "$out" | grep -oP '"decryption"\s*:\s*"\K[^"]+' | tr -d '\n\r')
    CLIENT_ENC=$(echo "$out" | grep -oP '"encryption"\s*:\s*"\K[^"]+' | tr -d '\n\r')

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
# 获取公网 IP（用于客户端链接）
# ================================
get_public_ip() {
    local ipv4 ipv6
    ipv4=$(curl -s4 --connect-timeout 3 https://api.ipify.org 2>/dev/null)
    ipv6=$(curl -s6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null)

    if [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
        echo "请选择要使用的公网 IP:" >&2
        echo "1) IPv4: $ipv4" >&2
        echo "2) IPv6: $ipv6" >&2
        read -p "选择 (默认 1): " ip_choice
        ip_choice=${ip_choice:-1}
        if [ "$ip_choice" -eq 2 ]; then
            echo "$ipv6"
        else
            echo "$ipv4"
        fi
    elif [ -n "$ipv4" ]; then
        echo "$ipv4"
    elif [ -n "$ipv6" ]; then
        echo "$ipv6"
    else
        echo "0.0.0.0"
    fi
}

# ================================
# 列出所有配置
# ================================
list_configs() {
    print_title "当前 ${PROTO_NAME} 配置列表"

    echo -e "${CYAN}编号 | 监听地址 | VLESS端口 | Portal端口 | UUID | WS路径 | Portal Tag${RESET}" >&2
    echo "------------------------------------------------------------------------------------------------" >&2

    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.json; do
        [[ -f "$f" ]] || continue

        base=$(basename "$f")
        if [[ "$base" =~ ${PROTO}-([0-9]+)\.json ]]; then
            num="${BASH_REMATCH[1]}"
        else
            continue
        fi

        listen=$(jq -r '.inbounds[0].listen' "$f")
        vport=$(jq -r '.inbounds[0].port' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$f")
        pport=$(jq -r '.inbounds[1].port' "$f")
        ptag=$(jq -r '.inbounds[1].tag' "$f")
        wspath=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // "未设置"' "$f")

        echo -e "${GREEN}$num${RESET}) ${YELLOW}$listen${RESET} | ${CYAN}$vport${RESET} | ${CYAN}$pport${RESET} | ${MAGENTA}$uuid${RESET} | ${BLUE}$wspath${RESET} | ${WHITE}$ptag${RESET}" >&2
    done
    echo "------------------------------------------------------------------------------------------------" >&2
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
        rm -f "$OUT_DIR/${PROTO}-${num_fmt}.link"
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
        print_ok "已删除编号 $num_fmt 的 ${PROTO_NAME} 配置及客户端记录"
    else
        print_error "编号 $num_fmt 不存在"
    fi
}

# ================================
# 新增配置（WebSocket）
# ================================
add_config() {
    print_title "新增反向代理服务端配置 (WebSocket)"

    local listen_ip=$(choose_listen_ip)
    local vless_port=$(safe_read_port "$(random_free_port)")
    local portal_port=$(safe_read_port "$(random_free_port)")
    local UUID=$(generate_uuid)
    local next=$(get_next_index)

    local portal_tag="portal-${next}"
    local reverse_tag="reverse-out-${next}"

    # WebSocket 路径
    default_path=$(random_path)
    printf "请输入 WebSocket 路径 (默认 %s): " "$default_path" >&2
    read ws_path
    ws_path=$(clean_input "$ws_path")
    [[ -z "$ws_path" ]] && ws_path="$default_path"
    [[ "$ws_path" != /* ]] && ws_path="/$ws_path"

    generate_mlkem

    local file="$CONF_DIR/$PROTO-$next.json"

    jq -n \
        --arg listen "$listen_ip" \
        --argjson vport "$vless_port" \
        --argjson pport "$portal_port" \
        --arg uuid "$UUID" \
        --arg dec "$SERVER_DEC" \
        --arg portal "$portal_tag" \
        --arg rev "$reverse_tag" \
        --arg path "$ws_path" \
        '{
            inbounds: [
                {
                    listen: $listen,
                    port: $vport,
                    protocol: "vless",
                    settings: {
                        decryption: $dec,
                        clients: [
                            {
                                id: $uuid,
                                flow: "xtls-rprx-vision",
                                reverse: { tag: $rev }
                            }
                        ]
                    },
                    streamSettings: {
                        network: "ws",
                        wsSettings: {
                            path: $path
                        }
                    }
                },
                {
                    listen: $listen,
                    port: $pport,
                    protocol: "socks",
                    tag: $portal,
                    settings: { auth: "noauth" }
                }
            ],
            routing: {
                rules: [
                    {
                        inboundTag: [$portal],
                        outboundTag: $rev
                    }
                ]
            },
            outbounds: [
                { protocol: "freedom" }
            ]
        }' > "$file"

    print_ok "服务端配置已生成：$file"

    # ============================
    # 生成客户端链接并保存
    # ============================
    PUBLIC_IP=$(get_public_ip)
    if [[ "$PUBLIC_IP" =~ : ]]; then
        link_ip="[$PUBLIC_IP]"
    else
        link_ip="$PUBLIC_IP"
    fi

    CLEAN_ENC=$(echo "$CLIENT_ENC" | tr -d '\n\r')
    # 注意：flow 在 WebSocket 下通常无效，但保留不影响连接；可以移除 flow 参数，这里保持原有风格
    link="vless://${UUID}@${link_ip}:${vless_port}?encryption=${CLEAN_ENC}&flow=xtls-rprx-vision&type=ws&path=${ws_path}#reverse-server-${next}"

    echo "[$next] $link" >> "$OUT_DIR/${PROTO}.txt"
    echo "$link" > "$OUT_DIR/${PROTO}-${next}.link"

    cat >> "$OUT_DIR/${PROTO}.yaml" <<EOF

# [$next] reverse-server-${next}
- name: reverse-server-${next}
  type: vless
  server: $PUBLIC_IP
  port: $vless_port
  uuid: $UUID
  encryption: $CLEAN_ENC
  flow: xtls-rprx-vision
  network: ws
  ws-opts:
    path: $ws_path
EOF

    print_info "=== 服务端信息 ==="
    echo "编号: $next" >&2
    echo "监听地址: $listen_ip" >&2
    echo "VLESS 端口: $vless_port" >&2
    echo "Portal 端口: $portal_port" >&2
    echo "UUID: $UUID" >&2
    echo "WebSocket 路径: $ws_path" >&2
    echo "客户端 encryption: $CLEAN_ENC" >&2
    echo "Portal Tag: $portal_tag" >&2
    echo "Reverse Tag: $reverse_tag" >&2
    echo >&2

    print_info "=== 客户端链接 ==="
    echo "$link" >&2
    echo >&2

    print_info "=== YAML 客户端配置示例 ==="
    cat >&2 <<EOF
- name: reverse-server-${next}
  type: vless
  server: $PUBLIC_IP
  port: $vless_port
  uuid: $UUID
  encryption: $CLEAN_ENC
  flow: xtls-rprx-vision
  network: ws
  ws-opts:
    path: $ws_path
EOF
    echo >&2
}

# ================================
# 显示客户端链接（同前，直接 cat .link 文件）
# ================================
show_vless_links() {
    print_title "客户端 VLESS 链接 (WebSocket)"

    local link_file="$OUT_DIR/${PROTO}.txt"
    if [[ ! -f "$link_file" ]]; then
        print_error "未找到链接文件: $link_file"
        return
    fi

    local -a nums ports uuid_pre
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([0-9]+)\]\ (vless://.*) ]]; then
            local num="${BASH_REMATCH[1]}"
            local link="${BASH_REMATCH[2]}"
            nums+=("$num")
            local port=$(echo "$link" | grep -oP ':\K[0-9]+(?=\?)' | head -1)
            local uuid_head=$(echo "$link" | grep -oP 'vless://\K[^@]+' | head -1 | cut -c1-8)
            ports+=("$port")
            uuid_pre+=("$uuid_head")
        fi
    done < "$link_file"

    if [ ${#nums[@]} -eq 0 ]; then
        print_error "没有找到任何客户端链接"
        return
    fi

    echo -e "${CYAN}编号 | VLESS端口 | UUID（前8位）${RESET}" >&2
    echo "----------------------------------------" >&2
    for i in "${!nums[@]}"; do
        echo -e "${GREEN}${nums[$i]}${RESET})   ${CYAN}${ports[$i]}${RESET}   ${YELLOW}${uuid_pre[$i]}...${RESET}" >&2
    done
    echo "----------------------------------------" >&2

    printf "请输入要查看的编号 (0 返回): " >&2
    read input_num
    input_num=$(clean_input "$input_num")
    [[ "$input_num" == "0" ]] && return

    if [[ "$input_num" =~ ^[0-9]+$ ]] && (( input_num < 10 )); then
        input_num="0$input_num"
    fi

    local link_file_indiv="$OUT_DIR/${PROTO}-${input_num}.link"
    if [[ -f "$link_file_indiv" ]]; then
        echo >&2
        print_ok "完整 VLESS 链接（单行，直接复制）:" >&2
        cat "$link_file_indiv"
        echo >&2
        print_info "链接已保存至: $link_file_indiv" >&2
    else
        print_error "编号 $input_num 不存在或链接文件缺失"
    fi
}

# ================================
# 主菜单
# ================================
menu() {
    while true; do
        print_title "反向代理服务端管理 (WebSocket)"
        echo "1) 查看所有配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "4) 显示客户端链接" >&2
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
            4)
                show_vless_links
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
