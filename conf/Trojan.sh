#!/bin/bash

# ================================
# Trojan 节点配置管理（X 内核 / xrayls）
# 输出碎片式配置：conf/trojan-NN.json（可被 xrayls -confdir 合并）
# 格式与 conf/http.sh 一致（list / add / delete 菜单式节点脚本）
#
# ⚠ X 内核说明（调研结论）：
#   - Xray 26.x 已移除 Trojan 的 flow（XTLS Vision 为 VLESS 专属），
#     内核实测报：“The feature Flow for Trojan has been removed.”
#   - Trojan 协议自身的 TLS 由 streamSettings 统一处理，因此 security 可
#     任意切换 none / tls / reality（同为不良林 AnyReality 三层模型）。
#
# 默认「最高配置」（最安全、最快、最隐蔽）：
#   - 安全层   : REALITY（偷取伪装域名真证书，无证书负担）
#   - maxTimeDiff: 40000（默认官方 0=不限时，最高配启用 40s 防重放）
#   - UDP      : 开启（trojan 内建 UDP-in-TCP-fec 支持）
#   - sniffing : 开启（destOverride http,tls）
#   可选项：裸 Trojan（security none，仅受控/内网链路）、Trojan+TLS（需自有证书，生态最老，仅兼容用）
# 客户端兼容性（实测）：X 内核 / v2rayN / mihomo（注意 trojan 用 `sni` 字段，不是 servername）/
#                      sing-box 均支持 trojan+reality。
# 输出三件套：
#   conf/trojan-NN.json          服务端碎片
#   out/trojan-NN.json           X 内核客户端出站
#   out/trojan-client-NN.yaml    mihomo (Clash.Meta) 客户端
#   out/trojan-share-NN.txt      分享链接 trojan://…
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
PROTO="trojan"
XRAY_BASE="${XRAY_BASE_DIR:-/root/catmi/xray}"
CONF_DIR="$XRAY_BASE/conf"
OUT_DIR="$XRAY_BASE/out"
INSTALL_DIR="/root/catmi/xray"
XRAY_BIN="$INSTALL_DIR/xrayls"
mkdir -p "$CONF_DIR" "$OUT_DIR"

# ================================
# 随机生成函数
# ================================
random_port() { shuf -i 10000-60000 -n 1; }
random_pass() { tr -dc A-Za-z0-9 </dev/urandom | head -c 20; }

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
# Batch 模式（被全协议一键生成 conf/batch.sh 调用时 X_BATCH=1）
#   - safe_read/safe_read_port 全部直接采用默认值（各协议"默认最高配置"），不等待交互
#   - 默认端口改为批量连续分配：X_BATCH_PORT_START-END 内取第一个空闲端口
#     （跳过本机已监听 + conf/ 碎片已用 + 本批已分配），游标持久化于
#     $CONF_DIR/.batch-ports，保证同一批内多协议端口互不重复
#   - 单协议（交互）模式行为完全不变
# ================================
X_BATCH_PORT_STATE="$CONF_DIR/.batch-ports"

batch_conf_used_ports() {
    jq -r '.inbounds[0].port // empty' "$CONF_DIR"/*.json 2>/dev/null | sort -un
}

batch_alloc_port() {
    local start="${X_BATCH_PORT_START:-}" end="${X_BATCH_PORT_END:-}" p used
    if [[ ! "$start" =~ ^[0-9]+$ || ! "$end" =~ ^[0-9]+$ ]]; then
        random_free_port          # 无批量端口范围时回退原有随机逻辑
        return
    fi
    used=$(batch_conf_used_ports)
    for (( p=start; p<=end; p++ )); do
        (( p >= 1 && p <= 65535 )) || continue
        grep -qx "$p" "$X_BATCH_PORT_STATE" 2>/dev/null && continue
        grep -qx "$p" <<<"$used" && continue
        port_in_use "$p" && continue
        echo "$p" >> "$X_BATCH_PORT_STATE"
        echo "$p"
        return
    done
    echo ""
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

    if [[ "${X_BATCH:-0}" == "1" ]]; then
        print_info "Batch 模式: ${prompt} = ${default}"
        echo "$default"
        return
    fi

    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

safe_read_port() {
    local default="$1"
    local input

    if [[ "${X_BATCH:-0}" == "1" ]]; then
        default=$(batch_alloc_port)
        if [[ -z "$default" ]]; then
            print_error "批量端口范围 $X_BATCH_PORT_START-$X_BATCH_PORT_END 已耗尽，回退随机空闲端口"
            default=$(random_free_port)
        fi
        print_info "Batch 模式: 自动分配端口 = $default"
        echo "$default"
        return
    fi

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
# 编号系统（trojan-NN.json）
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
    print_title "当前 Trojan 配置列表"

    shopt -s nullglob
    local files=("$CONF_DIR"/$PROTO-*.json)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "没有找到任何 Trojan 配置"
        return 1
    fi

    echo -e "${CYAN}编号 | 端口 | 安全层 | Tag${RESET}" >&2
    echo "--------------------------------------------------------" >&2

    local f num sec tag
    for f in "${files[@]}"; do
        num=$(basename "$f" | sed -E "s/^${PROTO}-([0-9]+)\.json$/\1/")
        sec=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$f" 2>/dev/null)
        tag=$(jq -r '.inbounds[0].tag' "$f" 2>/dev/null)
        echo -e "${GREEN}${num}${RESET}) Tag: ${BLUE}${tag}${RESET} | 安全层: ${YELLOW}${sec}${RESET} | 需要: $(
            [[ "$sec" == "tls" ]] && echo "自有域名+证书" || echo "无")" >&2
    done

    echo "--------------------------------------------------------" >&2
    return 0
}

# ================================
# 新增配置（默认最高配置 = Trojan + REALITY）
# ================================
add_config() {
    print_title "新增 Trojan 配置"

    # ---- 端口（默认：随机高位空闲端口）----
    default_port=$(random_free_port)
    lport=$(safe_read_port "$default_port")

    # ---- Trojan 密码（默认随机 20 位强密码）----
    TJPASS=$(random_pass)
    printf "是否自定义 Trojan 密码？回车=自动生成(推荐): " >&2
    read pw_custom
    pw_custom=$(clean_input "$pw_custom")
    [[ -n "$pw_custom" ]] && TJPASS="$pw_custom"

    # ---- 安全层（默认最高配置 REALITY；XTLS/flow 已被 Xray 移除，选配不可用）----
    local security="reality"
    echo >&2
    echo "安全层选配（默认最高配置：REALITY，最安全 / 最快 / 最隐蔽，无需证书）："
    echo "  回车 = Trojan + REALITY（最高配置）"
    echo "  1) 关闭安全层（裸 Trojan，security none；仅限受控/内网链路，公网极易被识别）"
    # 注：Xray 26.x 已移除 Trojan 的 flow（XTLS），“Trojan+XTLS-Vision”组合不存在；
    #     最强隐蔽度由 REALITY 层提供。
    printf "选择 (默认回车=REALITY): " >&2
    read yn
    yn=$(clean_input "$yn")
    if [[ "$yn" == "1" ]]; then
        security="none"
    fi

    if [[ "$security" == "reality" ]]; then
        # ---- 伪装域名/密钥复用专职维护脚本（与 Reality.sh / Shadowsocks.sh 同一套）----
        source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
        source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
        update_env "/root/catmi/catmi.env" mode xray
        print_info "正在检测/更新 Reality 伪装域名（domains.sh）..."
        bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh) \
            || { print_error "domains.sh 执行失败"; return 1; }
        print_info "正在生成 Reality 密钥（conf/XRevise.sh）..."
        bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/XRevise.sh) \
            || { print_error "XRevise.sh 执行失败"; return 1; }
        load_env "$INSTALL_DIR/install_info.env" || return 1
        load_env "/root/catmi/catmi.env" || return 1
        local v
        for v in PRIVATE_KEY PUBLIC_KEY short_id dest_server PUBLIC_IP link_ip; do
            [[ -n "${!v}" ]] || { print_error "缺少必要变量：$v（Reality 层无法生成）"; return 1; }
        done
        printf "伪装域名 (回车使用 domains.sh 优选的 %s): " "$dest_server" >&2
        read dest
        DEST_R=$(clean_input "$dest")
        [[ -z "$DEST_R" ]] && DEST_R="$dest_server"
        R_TARGET="$DEST_R:443"
        R_PK="$PUBLIC_KEY"
        R_PRIV="$PRIVATE_KEY"
        R_SID="$short_id"
    fi

    next=$(get_next_index)
    tag_name="TROJAN-${next}"

    # ---- 按安全层生成模板片段 ----
    local STREAM_BLOCK="" CL_STREAM="" SEC_LABEL="none（裸 Trojan）"
    if [[ "$security" == "reality" ]]; then
        read -r -d '' STREAM_BLOCK <<RB
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "$R_TARGET",
          "serverNames": ["$DEST_R"],
          "privateKey": "$R_PRIV",
          "shortIds": ["$R_SID"],
          "maxTimeDiff": 40000
        }
      },
RB
        read -r -d '' CL_STREAM <<RC
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$DEST_R",
      "fingerprint": "chrome",
      "publicKey": "$R_PK",
      "shortId": "$R_SID",
      "spiderX": "/"
    }
  },
RC
        # 统一缩进（纯美观，JSON 语义合法）
        STREAM_BLOCK=$(printf '%s\n' "$STREAM_BLOCK" | sed '/^[[:space:]]*$/d; s/^[[:space:]]*//' | sed 's/^/      /')
        CL_STREAM=$(printf '%s\n' "$CL_STREAM" | sed '/^[[:space:]]*$/d; s/^[[:space:]]*//' | sed 's/^/    /')
    fi

    file="$CONF_DIR/$PROTO-$next.json"

    cat > "$file" <<EOF
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $lport,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "$TJPASS"
          }
        ]
      },
$STREAM_BLOCK
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

    # ---- X 内核客户端出站 ----
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    cat > "$OUT_DIR/$PROTO-$next.json" <<EOF
{
  "protocol": "trojan",
  "settings": {
    "servers": [
      {
        "address": "$server_ip",
        "port": ${lport},
        "password": "$TJPASS"
      }
    ]
  },
$CL_STREAM
  "tag": "out-trojan-$next"
}
EOF

    # ---- 分享链接 ----
    if [[ "$security" == "reality" ]]; then
        echo "trojan://${TJPASS}@${server_ip}:${lport}?security=reality&sni=${DEST_R}&type=tcp&fp=chrome&pbk=${R_PK}&sid=${R_SID}#Trojan-${next}" \
            > "$OUT_DIR/$PROTO-share-$next.txt"
    else
        echo "trojan://${TJPASS}@${server_ip}:${lport}#Trojan-${next}" \
            > "$OUT_DIR/$PROTO-share-$next.txt"
    fi

    # ---- mihomo (Clash.Meta) YAML 客户端 ----
    if [[ "$security" == "reality" ]]; then
        cat > "$OUT_DIR/$PROTO-client-$next.yaml" <<EOF
# mihomo (Clash.Meta) 客户端配置 —— Trojan-$next（REALITY 版）
# 注意：mihomo trojan 的 SNI 字段是 sni（不是 servername），reality-opts 需配公钥
proxies:
  - name: Trojan-$next
    type: trojan
    server: $server_ip
    port: $lport
    password: $TJPASS
    tls: true
    udp: true
    network: tcp
    sni: $DEST_R
    reality-opts:
      public-key: $R_PK
      short-id: $R_SID
    client-fingerprint: chrome
EOF
    else
        cat > "$OUT_DIR/$PROTO-client-$next.yaml" <<EOF
# mihomo (Clash.Meta) 客户端配置 —— Trojan-$next（裸 Trojan）
# ⚠ 无 TLS/Reality 保护，仅限受控/内网链路使用
proxies:
  - name: Trojan-$next
    type: trojan
    server: $server_ip
    port: $lport
    password: $TJPASS
    udp: true
EOF
    fi

    print_ok "新增 Trojan 配置成功（默认最高配置）"
    echo -e "编号: $next\n监听: 0.0.0.0:$lport\n安全层: $([ "$security" = "reality" ] && echo "REALITY（target=$R_TARGET pbk=${R_PK:0:10}... sid=$R_SID）" || echo 'none（裸 Trojan，仅内网）')\n密码: ${TJPASS}\nTag: $tag_name\n入站碎片: $file\n客户端文件(X内核): $OUT_DIR/$PROTO-$next.json\n客户端文件(M内核YAML): $OUT_DIR/$PROTO-client-$next.yaml\n分享链接: $OUT_DIR/$PROTO-share-$next.txt" >&2
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
        print_ok "已删除编号 $num 的 Trojan 配置（含客户端文件与分享链接）"
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
        print_warn "当前没有 Trojan 分享链接文件"
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
        print_title "Trojan 配置管理"

        echo "1) 查看所有配置" >&2
        echo "2) 新增配置（默认最高配置：Trojan + REALITY）" >&2
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

# 直跑入口: add = 由 Batch Generator (conf/batch.sh) 无交互调用;
# 不带参数 = 原有交互菜单 (单协议行为不变)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == "add" ]]; then
        add_config
    else
        config_menu
    fi
fi
