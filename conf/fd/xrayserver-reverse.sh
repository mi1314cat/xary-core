#!/usr/bin/env bash
# ============================================================
# xrayserver-reverse.sh — Xray 反向代理【服务端】(公网入口侧)
# 对应 gosts.sh：运行在"家/公网入口"机器，接收 RN(客户端) 回连，
# 把外部访问通过反向隧道送回 RN 的本地服务端口。
#
# 用法: bash xrayserver-reverse.sh
# 测试: REV_BASE_DIR=/tmp/xrev bash xrayserver-reverse.sh
# ============================================================

set -e

# ---------------- 颜色 ----------------
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"
MAGENTA="\e[35m"; CYAN="\e[36m"; WHITE="\e[97m"; BOLD="\e[1m"; RESET="\e[0m"

print_info()  { echo -e "${CYAN}[Info]${RESET} $1" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}  $1" >&2; }
print_error() { echo -e "${RED}[Error]${RESET} $1" >&2; }
print_warn()  { echo -e "${YELLOW}[注意]${RESET} $1" >&2; }
print_title() {
    echo -e "${MAGENTA}${BOLD}" >&2
    echo "╔══════════════════════════════════════════════╗" >&2
    printf "║ %-42s ║\n" "$1" >&2
    echo "╚══════════════════════════════════════════════╝" >&2
    echo -e "${RESET}" >&2
}

# ---------------- 路径 ----------------
BASE_DIR="${REV_BASE_DIR:-/root/catmi/xray}"
CONF_DIR="$BASE_DIR/conf"
ENV_DIR="$BASE_DIR/reverse-server"
XRAY_BIN=""
SYSTEMD="xrayls.service"

mkdir -p "$CONF_DIR" "$ENV_DIR"

detect_xray() {
    if [ -n "$XRAY_BIN" ]; then return; fi
    for b in /root/catmi/xray/xrayls /usr/local/bin/xrayls /usr/local/bin/xray /usr/bin/xray; do
        [ -x "$b" ] && { XRAY_BIN="$b"; return; }
    done
    print_error "未找到 xrayls/xray 二进制"
    exit 1
}
detect_xray

# 服务端 control 入站的固定 tag 前缀
CTL_TAG_PREFIX="rev-ctl"
PTL_TAG_PREFIX="rev-portal"
REVERSE_OUT_TAG="reverse-out"

clean_input() { echo "$1" | tr -d '\000-\037'; }
uuid_gen()    { cat /proc/sys/kernel/random/uuid; }

port_in_use() { ss -tuln 2>/dev/null | awk '{print $5}' | grep -E -q "(:|])$1$"; }

random_free_port() {
    while true; do
        p=$(shuf -i 20000-50000 -n 1)
        if ! port_in_use "$p"; then echo "$p"; return; fi
    done
}

safe_read() {
    local prompt="$1" default="$2" input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read -r input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "请输入端口 (默认: %s): " "$default" >&2
        read -r input
        input=$(clean_input "$input")
        port="${input:-$default}"
        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口 $port 已占用"; continue; }
        echo "$port"; return
    done
}

# ---------------- 环境文件 ----------------
next_id() {
    local n
    n=$(ls "$ENV_DIR"/tunnel-*.env 2>/dev/null | wc -l)
    echo $((n + 1))
}

env_file() { echo "$ENV_DIR/tunnel-$(printf '%02d' "$1").env"; }

# ---------------- 生成家侧 reverse 配置片段 ----------------
# 每一个隧道 = control client(UUID) 一个 + portal tunnel 入站一个

gen_reverse_conf() {
    # 参数: id uuid ctl_port ctl_path ptl_port server_path
    local id=$1 uuid=$2 ctl_port=$3 ctl_path=$4 ptl_port=$5 server_path=$6
    local id2
    id2=$(printf '%02d' "$id")

    # VLESS+WS control 入站 + tunnel portal 入站（service 端）
    cat > "$CONF_DIR/revsrv-$id2.in.json" <<EOF
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $ctl_port,
      "protocol": "vless",
      "tag": "${CTL_TAG_PREFIX}-$id2",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "$uuid",
            "reverse": { "tag": "${REVERSE_OUT_TAG}-$id2" }
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$ctl_path" }
      }
    },
    {
      "listen": "0.0.0.0",
      "port": $ptl_port,
      "protocol": "tunnel",
      "tag": "${PTL_TAG_PREFIX}-$id2"
    }
  ]
}
EOF

    # routing 规则片段（由脚本统一合并到 out-routing.json）
    # server_path = 该隧道在对外 nginx/CF 的路径（供用户在 nginx 处配置，脚本仅记录）
    echo "SYNC_OBJ_READY"
}

# ---------------- routing 合并 ----------------
# 家侧 out-routing.json 或其他 routing 文件: 幂等加入 portal -> reverse-out 规则
merge_routing() {
    local rt_file="$CONF_DIR/out-routing.json"
    # 找现有 routing 文件（最后读的为准）
    local last_rt=""
    for f in "$CONF_DIR"/*.json; do
        if grep -q '"routing"' "$f" 2>/dev/null; then
            last_rt="$f"
        fi
    done
    if [ -z "$last_rt" ]; then
        rt_file="$CONF_DIR/out-routing.json"
        echo '{"routing":{"rules":[]}}' > "$rt_file"
        last_rt="$rt_file"
    fi
    # jq 同步: 把每个 rev-portal-XX 入站 → reverse-out-XX 规则加进 rules
    if ! command -v jq >/dev/null 2>&1; then
        print_error "需要 jq"; return 1
    fi
    # 以 _meta.reverses 记录每个隧道的 routing 关系
    local payload="{}"
    for f in "$ENV_DIR"/tunnel-*.env; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC1090
        source "$f"
        [ -z "$REV_ID" ] && continue
        local id2 revout ptl
        id2=$(printf '%02d' "$REV_ID")
        revout="${REVERSE_OUT_TAG}-$id2"
        ptl="${PTL_TAG_PREFIX}-$id2"
        payload=$(jq --arg ptl "$ptl" --arg revout "$revout" \
            '._meta.reverses += [{portal:$ptl, out:$revout}]' <<< "$payload")
    done
    # 重新生成 routing.rules = 原 rules(去掉旧 rev 规则) + 新 rev 规则
    jq --argjson rev "$payload" '
        . as $root |
        (.routing.rules // []) as $old |
        ($old | map(select((.inboundTag[0] // "") | startswith("rev-portal-") | not))) as $keep |
        ($rev._meta.reverses // [] | map({inboundTag:[.portal], outboundTag:.out})) as $newrev |
        $root | .routing.rules = ($keep + $newrev)
    ' "$last_rt" > "$last_rt.tmp" && mv "$last_rt.tmp" "$last_rt"
    print_ok "routing 已合并 → $last_rt"
}

# ---------------- CRUD ----------------
list_tunnels() {
    print_title "反向代理隧道列表（服务端）"
    echo -e "${CYAN}编号 | UUID | control端口:WS路径 | portal端口 | 状态${RESET}" >&2
    echo "-------------------------------------------------------------------" >&2
    local found=0
    for f in "$ENV_DIR"/tunnel-*.env; do
        [ -f "$f" ] || continue
        found=1
        # shellcheck disable=SC1090
        source "$f"
        local id2 st svc_active
        id2=$(printf '%02d' "$REV_ID")
        # 隧道由 xrayls.service 统一管理: 状态 = 服务active + 隧道端口在监听
        svc_active="no"
        systemctl is-active --quiet "$SYSTEMD" 2>/dev/null && svc_active="yes"
        if [ "$svc_active" = "yes" ] && port_in_use "$REV_PTL_PORT"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi
        echo -e "${GREEN}${REV_ID}${RESET}) ${YELLOW}$REV_UUID${RESET} | ${BLUE}$REV_CTL_PORT${RESET}:${MAGENTA}$REV_CTL_PATH${RESET} | portal ${BLUE}$REV_PTL_PORT${RESET} | $st" >&2
        echo "     对内目标: $REV_NAME (RN 127.0.0.1:$REV_TARGET_PORT)" >&2
        echo "     nginx路径/域名: $REV_SERVER_PATH" >&2
        echo "     回连地址(RN配置用): ${REV_SERVER_ADDR:-未设}" >&2
    done
    [ "$found" = 0 ] && echo "  (无隧道)" >&2
    echo "-------------------------------------------------------------------" >&2
}

add_tunnel() {
    print_title "新增服务端隧道 (VLESS+WS reverse)"
    local id
    id=$(next_id)
    local id2
    id2=$(printf '%02d' "$id")

    echo -e "${YELLOW}隧道标识(给这个映射起个名字, 如 vmess-01)${RESET}" >&2
    local name
    name=$(safe_read "名称" "tunnel-$id")

    echo -e "${YELLOW}RN 侧要映射的本地端口(该流量在RN落地到哪个服务端口)${RESET}" >&2
    local target
    while true; do
        printf "请输入 RN 本地目标端口: " >&2
        read -r target
        target=$(clean_input "$target")
        [[ "$target" =~ ^[0-9]+$ ]] && (( target >= 1 && target <= 65535 )) && break
        print_error "目标端口必须是 1-65535 的数字"
    done

    echo -e "${YELLOW}Control 端口(家侧, RN 回连的 VLESS+WS 入口端口)${RESET}" >&2
    local ctl_port
    ctl_port=$(safe_read_port "$(random_free_port)")

    echo -e "${YELLOW}Control WS 路径(外部 nginx location 前缀, 需与 nginx 配置一致)${RESET}" >&2
    local ctl_path
    ctl_path=$(safe_read "WS路径" "/$(cat /proc/sys/kernel/random/uuid | cut -d'-' -f1)")

    echo -e "${YELLOW}Portal 端口(家侧, 对外入口 tunnel 端口)${RESET}" >&2
    local ptl_port
    ptl_port=$(safe_read_port "$(random_free_port)")

    echo -e "${YELLOW}对外入口路径(nginx location, 例如 /HCaVHO3U)${RESET}" >&2
    print_info "一般把外部访问路径写进本机 nginx: location <路径> → 127.0.0.1:<portal端口>"
    local server_path
    server_path=$(safe_read "对外路径(可为空)" "")

    echo -e "${YELLOW}RN 回连我家使用什么地址(可留空: 默认提示用域名+CF路径)${RESET}" >&2
    local server_addr
    server_addr=$(safe_read "服务端地址(域名/IP)" "")

    local uuid
    uuid=$(uuid_gen)
    local env
    env=$(env_file "$id")
    cat > "$env" <<EOF
REV_ID=$id
REV_NAME=$name
REV_UUID=$uuid
REV_TARGET_PORT=$target
REV_CTL_PORT=$ctl_port
REV_CTL_PATH=$ctl_path
REV_PTL_PORT=$ptl_port
REV_SERVER_PATH=$server_path
REV_SERVER_ADDR=$server_addr
EOF

    # 生成 conf 片段
    gen_reverse_conf "$id" "$uuid" "$ctl_port" "$ctl_path" "$ptl_port" "$server_path" >/dev/null
    merge_routing
    validate_and_restart

    print_ok "服务端隧道 #$id 创建成功"
    echo "  名称: $name" >&2
    echo "  UUID: $uuid" >&2
    echo "  Control: 0.0.0.0:$ctl_port (WS path $ctl_path)" >&2
    echo "  Portal: 0.0.0.0:$ptl_port" >&2
    echo "" >&2
    print_info "RN 端配置要点 (xrayclient-reverse.sh 用):"
    echo "  回连地址: ${server_addr:-<你家域名>}:443 (若走CF+nginx则 path=$ctl_path)" >&2
    echo "  UUID: $uuid  →  RN 本地目标: 127.0.0.1:$target" >&2
}

validate_and_restart() {
    echo "=== 配置校验 ($(basename "$XRAY_BIN")) ===" >&2
    if "$XRAY_BIN" run -test -confdir "$CONF_DIR" >/tmp/rev-test.log 2>&1; then
        print_ok "Configuration OK."
    else
        print_error "配置无效:"
        grep -aiE 'failed|error' /tmp/rev-test.log | head -5 >&2 || tail -10 /tmp/rev-test.log >&2
        return 1
    fi
    if systemctl list-unit-files "$SYSTEMD" >/dev/null 2>&1; then
        read -r -p "重启 $SYSTEMD 生效? [y/N]: " ans >&2
        case "$ans" in
            y|Y) systemctl restart "$SYSTEMD" && print_ok "已重启 $SYSTEMD" ;;
            *) print_info "跳过重启（配置已写入，稍后手动重启生效）" ;;
        esac
    fi
}

del_tunnel() {
    list_tunnels
    printf "请输入要删除的编号: " >&2
    read -r num
    num=$(clean_input "$num")
    local env id2
    env=$(env_file "$num")
    [ -f "$env" ] || { print_error "隧道 #$num 不存在"; return; }
    id2=$(printf '%02d' "$num")
    read -r -p "确认删除隧道 #$num? [y/N]: " ans >&2
    [[ "$ans" =~ ^[Yy]$ ]] || { print_info "已取消"; return; }
    # 移除 conf 片段 (无独立进程, 由 xrayls.service 统一管理)
    rm -f "$CONF_DIR/revsrv-$id2.in.json"
    rm -f "$env"
    merge_routing
    validate_and_restart
    print_ok "已删除隧道 #$num"
}

del_all() {
    read -r -p "确认删除所有服务端隧道? (yes/no): " ans >&2
    [ "$ans" != "yes" ] && { print_info "已取消"; return; }
    rm -f "$ENV_DIR"/tunnel-*.env "$CONF_DIR"/revsrv-*.in.json
    merge_routing
    print_ok "已删除全部隧道"
}

show_client_config() {
    list_tunnels
    printf "请输入要查看客户端配置的编号: " >&2
    read -r num
    num=$(clean_input "$num")
    local env
    env=$(env_file "$num")
    [ -f "$env" ] || { print_error "隧道 #$num 不存在"; return; }
    # shellcheck disable=SC1090
    source "$env"
    echo "" >&2
    echo -e "${BOLD}========== RN 客户端配置 (隧道 #$REV_ID: $REV_NAME) ==========${RESET}" >&2
    echo "  服务端地址: ${REV_SERVER_ADDR:-<你家域名>}" >&2
    echo -e "  端口: 443 (走CF+nginx) 或 ${BLUE}$REV_CTL_PORT${RESET} (直连)" >&2
    echo -e "  WS 路径: ${MAGENTA}$REV_CTL_PATH${RESET}" >&2
    echo -e "  UUID: ${GREEN}$REV_UUID${RESET}" >&2
    echo -e "  RN 本地目标端口: ${BLUE}$REV_TARGET_PORT${RESET} (reverse-direct 落地)" >&2
    echo -e "  若走 nginx 入口: nginx location $REV_SERVER_PATH → 127.0.0.1:$REV_PTL_PORT" >&2
}

# ---------------- 菜单 ----------------
menu() {
    while true; do
        print_title "Xray 反向代理服务端面板"
        echo " 1) 查看隧道列表" >&2
        echo " 2) 新增隧道" >&2
        echo " 3) 校验配置/重启服务" >&2
        echo " 4) 删除某隧道" >&2
        echo " 5) 删除全部隧道" >&2
        echo " 6) 生成客户端配置" >&2
        echo " 0) 退出" >&2
        printf "请选择: " >&2
        read -r c
        c=$(clean_input "$c")
        case "$c" in
            1) list_tunnels; printf "\n按回车继续..." >&2; read -r ;;
            2) add_tunnel;  printf "\n按回车继续..." >&2; read -r ;;
            3) validate_and_restart; printf "\n按回车继续..." >&2; read -r ;;
            4) del_tunnel;  printf "\n按回车继续..." >&2; read -r ;;
            5) del_all;     printf "\n按回车继续..." >&2; read -r ;;
            6) show_client_config; printf "\n按回车继续..." >&2; read -r ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "\n按回车继续..." >&2; read -r ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    menu
fi