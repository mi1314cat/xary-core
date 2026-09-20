#!/bin/bash

# ================================
# Shadowsocks-2022 节点配置管理（X 内核 / xrayls）
# 输出为 xary-core 碎片式配置：conf/ss2022-NN.json
# 格式与 conf/http.sh 完全一致（list / add / delete 菜单式节点脚本）
#
# 协议版本说明（调研结论）：
#   Shadowsocks 2022（SIP022，shadowsocks.org 2026-07 最新规范）是现行版本，
#   并非老协议：BLAKE3 子密钥派生、强制重放保护（salt 存 60s）、
#   防 DPI 探测设计（单次读取、不泄露消费字节数）、UDP session 化。
#   需要避免的是「旧版 AEAD（aes-256-gcm / chacha20 等 2017 版）」，那才是易被识别的一代。
#
# X 内核说明：Xray-core 打印了弃用横幅，建议新节点优先用 VLESS Encryption，
#   但 SS2022 由 Xray 完整支持（xtls.github.io/config/inbounds/shadowsocks.html），
#   客户端生态（mihomo / sing-box / v2rayN 等）兼容性极好。
#
# 默认「最高配置」：
#   - method   : 2022-blake3-aes-256-gcm（硬件 AES-NI，官方推荐，64 位强加密）
#   - PSK      : openssl rand -base64 32（32 字节，随机生成）
#   - UDP      : 开启（SS2022 UDP = session 化中继，开销低且可靠）
#   - sniffing : 开启（destOverride http,tls,quic）
#   可选项（默认最高配置）：端口（默认随机高位空闲端口）
# 输出三件套：
#   conf/ss2022-NN.json          服务端碎片（xrayls -confdir 合并）
#   out/ss2022-NN.json           X 内核客户端出站
#   out/ss2022-client-NN.yaml    mihomo (Clash.Meta) 客户端
#   out/ss2022-share-NN.txt      分享链接 ss://qenc://…（SIP002 引用格式）
# ================================

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
print_warn()  { echo -e "${YELLOW}[Warn]${RESET} $1" >&2; }
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
PROTO="ss2022"
CONF_DIR="/root/catmi/xray/conf"
OUT_DIR="/root/catmi/xray/out"
INSTALL_DIR="/root/catmi/xray"
XRAY_BIN="$INSTALL_DIR/xrayls"
mkdir -p "$CONF_DIR" "$OUT_DIR"

# ================================
# 随机生成函数
# ================================
random_port() { shuf -i 10000-60000 -n 1; }
# 按方法生成正确长度的 base64 PSK（SIP022: 直接使用密码学安全随机串，绝不复用旧 EVP_BytesToKey）
gen_psk() {
    local method="$1"
    case "$method" in
        "2022-blake3-aes-128-gcm") openssl rand -base64 16 | tr -d '\n' ;;
        "2022-blake3-chacha20-poly1305") openssl rand -base64 32 | tr -d '\n' ;;
        *) openssl rand -base64 32 | tr -d '\n' ;; # 2022-blake3-aes-256-gcm
    esac
}

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

# ================================
# 编号系统（ss2022-NN.json）
# ================================
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
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 Shadowsocks-2022 配置列表"

    shopt -s nullglob
    local files=("$CONF_DIR"/$PROTO-*.json)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "没有找到任何 Shadowsocks-2022 配置"
        return 1
    fi

    echo -e "${CYAN}编号 | 端口 | 方法 | Tag${RESET}" >&2
    echo "--------------------------------------------------------" >&2

    local f num method tag udp
    for f in "${files[@]}"; do
        num=$(basename "$f" | sed -E "s/^${PROTO}-([0-9]+)\.json$/\1/")
        method=$(jq -r '.inbounds[0].settings.method' "$f" 2>/dev/null)
        tag=$(jq -r '.inbounds[0].tag' "$f" 2>/dev/null)
        udp=$(jq -r '.inbounds[0].settings.network // ""' "$f" 2>/dev/null)
        echo -e "${GREEN}${num}${RESET}) Tag: ${BLUE}${tag}${RESET} | 方法: ${YELLOW}${method}${RESET} | 网络: ${CYAN}${udp:-tcp+udp}${RESET}" >&2
    done

    echo "--------------------------------------------------------" >&2
    return 0
}

# ================================
# 新增配置（默认最高配置）
# ================================
add_config() {
    print_title "新增 Shadowsocks-2022 配置"

    # ---- 端口（默认：随机高位空闲端口）----
    default_port=$(random_free_port)
    lport=$(safe_read_port "$default_port")

    # ---- 加密方法（默认：最高配置 aes-256-gcm）----
    local method="2022-blake3-aes-256-gcm"
    echo >&2
    echo "默认使用最高配置：2022-blake3-aes-256-gcm（AES-NI 硬件加速，防重放+防探测）。" >&2
    echo "可选：" >&2
    echo "  1) 2022-blake3-aes-128-gcm      （16字节 PSK，老设备兼容性好）" >&2
    echo "  2) 2022-blake3-chacha20-poly1305（无 AES 硬件加速设备用）" >&2
    echo "  回车 = 使用最高配置 (aes-256-gcm)" >&2
    printf "选择: " >&2
    read yn
    yn=$(clean_input "$yn")
    case "$yn" in
        1) method="2022-blake3-aes-128-gcm" ;;
        2) method="2022-blake3-chacha20-poly1305" ;;
        *) method="2022-blake3-aes-256-gcm" ;;
    esac

    # ---- PSK（SIP022 规范：crypto-secure 随机 base64 PSK，禁止旧 EVP_BytesToKey 密码）----
    PSK=$(gen_psk "$method")
    printf "是否自定义 PSK？回车=自动生成(推荐): " >&2
    read psk_custom
    psk_custom=$(clean_input "$psk_custom")
    [[ -n "$psk_custom" ]] && PSK="$psk_custom"

    # PSK 长度校验（base64 解码字节数必须与方法匹配）
    PSK_BYTES=$(printf '%s' "$PSK" | openssl base64 -d -A 2>/dev/null | wc -c)
    expected=32
    [[ "$method" == "2022-blake3-aes-128-gcm" ]] && expected=16
    if (( PSK_BYTES != expected )); then
        print_error "PSK 长度错误：${method} 需要 ${expected} 字节 (获得 ${PSK_BYTES} 字节)"
        return 1
    fi

    # ---- UDP 与 sniffing（默认最高配置：开启 UDP，SS2022 UDP 会话化中继）----
    local network="tcp,udp"
    echo >&2
    echo "UDP 中继默认开启（SS2022 UDP 为 session 化中继）。" >&2
    printf "不启用 UDP 请输入 1 (默认启用): " >&2
    read yn
    yn=$(clean_input "$yn")
    [[ "$yn" == "1" ]] && network="tcp"

    next=$(get_next_index)
    tag_name="SS2022-${next}"

    file="$CONF_DIR/$PROTO-$next.json"

cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $lport,
      "protocol": "shadowsocks",
      "settings": {
        "method": "$method",
        "password": "$PSK",
        "network": "$network"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": false
      },
      "tag": "$tag_name"
    }
  ]
}
EOF

    # 配置自检（碎片文件单独测试）；失败则清理，不留坏文件
    if ! "$XRAY_BIN" -test -config "$file" >/dev/null 2>&1; then
        print_error "生成的配置无法通过内核测试：$file（已清理，原因如下）"
        "$XRAY_BIN" -test -config "$file" 2>&1 | tail -5
        rm -f "$file"
        return 1
    fi

    # ---- X 内核客户端出站（vnet 结构）----
    cat > "$OUT_DIR/$PROTO-$next.json" <<EOF
{
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "$(hostname -I 2>/dev/null | awk '{print $1}')",
        "port": ${lport},
        "method": "$method",
        "password": "$PSK",
        "uot": true
      }
    ]
  },
  "tag": "out-ss2022-$next"
}
EOF

    # ---- 分享链接（SIP002 引用格式：ss://base64(method:password)@host:port）----
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    userinfo=$(printf '%s' "$method:$PSK" | openssl base64 -A | tr -d '=' | tr '/+' '_-')
    echo "ss://${userinfo}@${server_ip}:${lport}#SS2022-${next}" > "$OUT_DIR/$PROTO-share-$next.txt"

    # ---- mihomo (Clash.Meta) YAML 客户端 ----
    cat > "$OUT_DIR/$PROTO-client-$next.yaml" <<EOF
# mihomo (Clash.Meta) 客户端配置 —— SS2022-$next
# 方法与 PSK 与服务端完全一致；mihomo / sing-box / v2rayN 均支持 SS2022
proxies:
  - name: SS2022-$next
    type: ss
    server: $server_ip
    port: $lport
    cipher: $method
    password: "$PSK"
    udp: $([ "$network" = "tcp,udp" ] && echo true || echo false)
EOF

    print_ok "新增 Shadowsocks-2022 配置成功（最高配置）"
    echo -e "编号: $next\n监听: 0.0.0.0:$lport\n方法: $method\nPSK: ${PSK:0:10}...(${PSK_BYTES} 字节)\nUDP: $([ "$network" = "tcp,udp" ] && echo '已开启 (session 化中继)' || echo '未开启')\nTag: $tag_name\n入站碎片: $file\n客户端文件(X内核): $OUT_DIR/$PROTO-$next.json\n客户端文件(M内核YAML): $OUT_DIR/$PROTO-client-$next.yaml\n分享链接: $OUT_DIR/$PROTO-share-$next.txt" >&2
}

# ================================
# 删除配置
# ================================
delete_config() {
    list_configs || return

    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")

    file="$CONF_DIR/$PROTO-$(printf "%02d" $num).json"

    if [[ -f "$file" ]]; then
        rm -f "$file" "$OUT_DIR/$PROTO-$num.json" "$OUT_DIR/$PROTO-client-$num.yaml" "$OUT_DIR/$PROTO-share-$num.txt"
        print_ok "已删除编号 $num 的 Shadowsocks-2022 配置（含客户端文件与分享链接）"
    else
        print_error "编号 $num 不存在"
    fi
}

# ================================
# 显示客户端配置
# ================================
show_client() {
    shopt -s nullglob
    local files=("$OUT_DIR"/$PROTO-share-*.txt)
    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "当前没有 Shadowsocks-2022 分享链接文件"
        return
    fi
    for f in "${files[@]}"; do
        echo -e "\n===== $f ====="
        cat "$f"
    done
}

# ================================
# 主菜单
# ================================
config_menu() {
    if ! command -v jq >/dev/null 2>&1; then
        print_error "缺少 jq（列表解析需要），请先安装：apt install -y jq"
        return
    fi

    while true; do
        print_title "Shadowsocks-2022 配置管理"

        echo "1) 查看所有配置" >&2
        echo "2) 新增配置（默认最高配置：aes-256-gcm + UDP 开启）" >&2
        echo "3) 删除配置" >&2
        echo "4) 查看客户端链接" >&2
        echo "0) 返回主菜单" >&2

        printf "请选择: " >&2
        read c || exit 0  # EOF 时退出，避免无限菜单循环
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
                show_client
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
