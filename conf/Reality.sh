#!/bin/bash

# ================================
# Reality 节点配置管理（X 内核 / xrayls）
# 输出为 xary-core 碎片式配置：conf/reality-NN.json
# 格式与 conf/http.sh 完全一致（list / add / delete 菜单式节点脚本）
#
# 伪装域名 dest_server 由专职维护脚本 domains.sh 负责：
#   https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh
#   （自动从 TLS1.3+h2 安全域名池现场优选，并写入 catmi.env / install_info.env）
#
# 默认「最高配置」：
#   - flow: xtls-rprx-vision            （Xray 官方唯一推荐的 Reality flow）
#   - 加密: ML-KEM-768 后量子 VLESS Encryption（SERVER_DEC，来自 xrayls vlessenc）
#   - realitySettings.maxTimeDiff = 40000（默认 0=不限时，最高配启用 40s 防重放）
#   - sniffing          = 开启（destOverride http,tls,quic）
# 可选项（默认均为最高配置，回车即可）：
#   - 端口（默认随机高位空闲端口）
#   - 伪装域名（默认 domains.sh 优选结果）
#   - 纯 X25519 / ML-KEM-768（默认 ML-KEM）
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
PROTO="reality"
CONF_DIR="/root/catmi/xray/conf"
OUT_DIR="/root/catmi/xray/out"
INSTALL_DIR="/root/catmi/xray"
XRAY_BIN="$INSTALL_DIR/xrayls"
mkdir -p "$CONF_DIR" "$OUT_DIR"

# ================================
# 随机生成函数
# ================================
random_port() { shuf -i 10000-60000 -n 1; }
random_short_id() { openssl rand -hex 16 | head -c 16; }

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
# 编号系统（reality-NN.json）
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
# 环境准备：伪装域名(domains.sh) + 密钥(xrayls/XRevise.sh)
# · 伪装域名维护脚本：domains.sh 生成并持久化 dest_server
# · 密钥脚本：conf/XRevise.sh 生成 x25519 密钥对 / UUID / short_id / ML-KEM 串
# ================================
prepare_env() {
    local CATMIENV_FILE="/root/catmi/catmi.env"
    if [[ ! -x "$XRAY_BIN" ]]; then
        print_error "未找到 xrayls（$XRAY_BIN），请先运行安装脚本（面板选项 1）"
        return 1
    fi
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
    update_env "$CATMIENV_FILE" mode xray

    print_info "正在检测/更新 Reality 伪装域名（domains.sh）..."
    bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh) \
        || { print_error "domains.sh 执行失败"; return 1; }

    print_info "正在生成 Reality 密钥与节点参数（conf/XRevise.sh）..."
    bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/XRevise.sh) \
        || { print_error "XRevise.sh 执行失败"; return 1; }

    load_env "$INSTALL_DIR/install_info.env"   || return 1
    load_env "/root/catmi/catmi.env"           || return 1

    local v
    for v in UUID PRIVATE_KEY PUBLIC_KEY short_id dest_server SERVER_DEC CLIENT_ENC PUBLIC_IP link_ip; do
        [[ -n "${!v}" ]] || { print_error "缺少必要变量：$v"; return 1; }
    done
    return 0
}

# ================================
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 Reality 配置列表"

    shopt -s nullglob
    local files=("$CONF_DIR"/$PROTO-*.json)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "没有找到任何 Reality 配置"
        return 1
    fi

    echo -e "${CYAN}编号 | 端口 | UUID | flow | SNI${RESET}" >&2
    echo "--------------------------------------------------------" >&2

    local f num port flow sni
    for f in "${files[@]}"; do
        num=$(basename "$f" | sed -E "s/^${PROTO}-([0-9]+)\.json$/\1/")
        port=$(jq -r '.inbounds[0].port' "$f" 2>/dev/null)
        uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$f" 2>/dev/null)
        flow=$(jq -r '.inbounds[0].settings.clients[0].flow' "$f" 2>/dev/null)
        sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$f" 2>/dev/null)
        echo -e "${GREEN}${num}${RESET}) 端口: ${YELLOW}${port}${RESET} | UUID: ${MAGENTA}${uuid}${RESET} | flow: ${CYAN}${flow}${RESET} | SNI: ${BLUE}${sni}${RESET}" >&2
    done

    echo "--------------------------------------------------------" >&2
    return 0
}

# ================================
# 新增配置（默认最高配置）
# ================================
add_config() {
    print_title "新增 Reality 配置"

    prepare_env || return 1

    # ---- 端口（默认：随机高位空闲端口）----
    default_port=$(random_free_port)
    lport=$(safe_read_port "$default_port")

    # ---- 伪装域名（默认：domains.sh 优选的 dest_server）----
    DEST=$(safe_read "请输入 Reality 伪装域名 (SNI/dest)" "$dest_server")

    # ---- 可选降级询问（默认全部最高配置）----
    local encryption_mode="mldsa"
    printf "默认使用最高配置：ML-KEM-768 后量子 VLESS Encryption。\n" >&2
    printf "回车=最高配置；选择降级为纯 X25519 (decryption none) 请输入 1: " >&2
    read yn
    yn=$(clean_input "$yn")
    [[ "$yn" == "1" ]] && encryption_mode="plain"

    local flow="xtls-rprx-vision"
    printf "flow 默认 xtls-rprx-vision（官方唯一推荐）。输入 1 降级为无 flow: " >&2
    read yn
    yn=$(clean_input "$yn")
    [[ "$yn" == "1" ]] && flow="none" && encryption_mode="plain"

    next=$(get_next_index)
    tag_name="REALITY-${next}"

    # ---- decryption 字段（服务端）----
    local decryption="none"
    [[ "$encryption_mode" == "mldsa" ]] && decryption="$SERVER_DEC"

    # ---- 客户端 encryption参数（分享链接用）----
    local link_enc=""
    [[ "$encryption_mode" == "mldsa" ]] && link_enc="&encryption=${CLIENT_ENC}"

    file="$CONF_DIR/$PROTO-$next.json"

cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $lport,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "$flow"
          }
        ],
        "decryption": "$decryption"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "${DEST}:443",
          "serverNames": ["$DEST"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$short_id"],
          "maxTimeDiff": 40000,
          "xver": 0
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
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

    # ---- X 内核客户端出站配置（out/ 目录，必须使用 vnext 结构）----
    cat > "$OUT_DIR/$PROTO-$next.json" <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "${link_ip}",
        "port": ${lport},
        "users": [
          {
            "id": "$UUID",
            "encryption": "$([ "$encryption_mode" = "mldsa" ] && echo "$CLIENT_ENC" || echo none)",
            "flow": "$flow"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$DEST",
      "fingerprint": "chrome",
      "publicKey": "$PUBLIC_KEY",
      "shortId": "$short_id",
      "spiderX": "/"
    }
  },
  "tag": "out-reality-$next"
}
EOF

    # ---- mihomo (Clash.Meta) YAML 客户端文件（M 内核）----
    cat > "$OUT_DIR/$PROTO-client-$next.yaml" <<EOF
# mihomo (Clash.Meta) 客户端配置 —— Reality-$next
# M 内核需为支持 VLESS Encryption（mlkem768）的新版本；旧版 M 内核请选纯 X25519 模式重新生成
proxies:
  - name: Reality-$next
    type: vless
    server: $PUBLIC_IP
    port: $lport
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: $flow
    servername: $DEST
    encryption: $([ "$encryption_mode" = "mldsa" ] && echo "$CLIENT_ENC" || echo none)
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $short_id
    client-fingerprint: chrome
EOF

    # ---- 分享链接 ----
    echo "vless://${UUID}@${link_ip}:${lport}?flow=${flow}&security=reality&sni=${DEST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${short_id}&type=tcp${link_enc}#Reality-${next}" \
        > "$OUT_DIR/$PROTO-share-$next.txt"

    print_ok "新增 Reality 配置成功（最高配置）"
    echo -e "编号: $next\n监听: 0.0.0.0:$lport\nUUID: $UUID\nflow: $flow\n加密: $([ "$encryption_mode" = "mldsa" ] && echo 'ML-KEM-768 (PQ 量子抗性)' || echo '纯 X25519 (无 PQ)')\nSNI/target: ${DEST}:443\nmaxTimeDiff: 40000\nTag: $tag_name\n入站碎片: $file\n客户端文件(X内核): $OUT_DIR/$PROTO-$next.json\n客户端文件(M内核YAML): $OUT_DIR/$PROTO-client-$next.yaml\n分享链接: $OUT_DIR/$PROTO-share-$next.txt" >&2
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
        print_ok "已删除编号 $num 的 Reality 配置（含客户端文件与分享链接）"
    else
        print_error "编号 $num 不存在"
    fi
}

# ================================
# 显示客户端配置（复用 out/ 文件）
# ================================
show_client() {
    shopt -s nullglob
    local files=("$OUT_DIR"/$PROTO-share-*.txt)
    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "当前没有 Reality 分享链接文件"
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
        print_title "Reality 配置管理"

        echo "1) 查看所有配置" >&2
        echo "2) 新增配置（默认最高配置：vision + ML-KEM-768 + maxTimeDiff）" >&2
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
