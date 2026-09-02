#!/usr/bin/env bash
# ============================================================
# xrayclient-reverse.sh — Xray 反向代理【客户端】(主动回连侧)
# 对应 gostc.sh：运行在 RN/有服务的机器上，主动回连服务端(家)，
# 把本机某个服务端口通过反向隧道暴露给服务端入口。
#
# 用法: bash xrayclient-reverse.sh
# 测试: REV_BASE_DIR=/tmp/xrev bash xrayclient-reverse.sh
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
ENV_DIR="$BASE_DIR/reverse-client"
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

REVERSE_IN_TAG="reverse-in"
REVERSE_DIRECT_TAG="reverse-direct"

clean_input() { echo "$1" | tr -d '\000-\037'; }

port_in_use() { ss -tuln 2>/dev/null | awk '{print $5}' | grep -E -q "(:|])$1$"; }

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
        echo "$port"; return
    done
}

# ---------------- 环境文件 ----------------
next_id() {
    local n
    n=$(ls "$ENV_DIR"/push-*.env 2>/dev/null | wc -l)
    echo $((n + 1))
}
env_file() { echo "$ENV_DIR/push-$(printf '%02d' "$1").env"; }

# ---------------- 生成 RN 侧 reverse 配置片段 ----------------
gen_client_conf() {
    # 参数: id uuid server_addr server_port mode path target
    local id=$1 uuid=$2 saddr=$3 sport=$4 mode=$5 path=$6 target=$7
    local id2
    id2=$(printf '%02d' "$id")

    # mode: cf = 走 CF+wss(443), direct = 直连 tcp(服务器端口)
    if [ "$mode" = "cf" ]; then
        # wss: tls + ws path
        local stream
        stream=$(cat <<EOF
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": { "serverName": "$saddr" },
        "wsSettings": { "path": "$path" }
      }
EOF
)
        local conn_port=443
    else
        # 直连 tcp
        local stream
        stream=$(cat <<EOF
      "streamSettings": { "network": "tcp" }
EOF
)
        local conn_port=$sport
    fi

    cat > "$CONF_DIR/revcli-$id2.in.json" <<EOF
{
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "${REVERSE_IN_TAG}-$id2",
      "settings": {
        "address": "$saddr",
        "port": $conn_port,
        "encryption": "none",
        "id": "$uuid",
        "reverse": { "tag": "${REVERSE_IN_TAG}-$id2" }
      },
      $stream
    },
    {
      "protocol": "freedom",
      "tag": "${REVERSE_DIRECT_TAG}-$id2",
      "settings": { "redirect": "127.0.0.1:$target" }
    }
  ]
}
EOF
}

# ---------------- routing 合并 ----------------
# RN 侧 out-routing.json: 幂等加入 reverse-in-XX -> reverse-direct-XX
merge_routing() {
    local rt_file="$CONF_DIR/out-routing.json"
    local last_rt=""
    for f in "$CONF_DIR"/*.json; do
        if grep -q '"routing"' "$f" 2>/dev/null; then last_rt="$f"; fi
    done
    if [ -z "$last_rt" ]; then
        rt_file="$CONF_DIR/out-routing.json"
        echo '{"routing":{"rules":[]}}' > "$rt_file"
        last_rt="$rt_file"
    fi
    command -v jq >/dev/null 2>&1 || { print_error "需要 jq"; return 1; }

    local payload="{}"
    for f in "$ENV_DIR"/push-*.env; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC1090
        source "$f"
        [ -z "$PUSH_ID" ] && continue
        local id2 rin rdir
        id2=$(printf '%02d' "$PUSH_ID")
        rin="${REVERSE_IN_TAG}-$id2"
        rdir="${REVERSE_DIRECT_TAG}-$id2"
        payload=$(jq --arg rin "$rin" --arg rdir "$rdir" \
            '._meta.reverses += [{inbound:$rin, outbound:$rdir}]' <<< "$payload")
    done
    jq --argjson rev "$payload" '
        . as $root |
        (.routing.rules // []) as $old |
        ($old | map(select((.inboundTag[0] // "") | startswith("reverse-in-") | not))) as $keep |
        ($rev._meta.reverses // [] | map({inboundTag:[.inbound], outboundTag:.outbound})) as $newrev |
        $root | .routing.rules = ($keep + $newrev)
    ' "$last_rt" > "$last_rt.tmp" && mv "$last_rt.tmp" "$last_rt"
    print_ok "routing 已合并 → $last_rt"
}

# ---------------- CRUD ----------------
list_pushes() {
    print_title "反向推送列表（客户端）"
    echo -e "${CYAN}编号 | UUID前缀 | 回连地址 | 本地目标端口 | 状态${RESET}" >&2
    echo "------------------------------------------------------------------------" >&2
    local found=0
    for f in "$ENV_DIR"/push-*.env; do
        [ -f "$f" ] || continue
        found=1
        # shellcheck disable=SC1090
        source "$f"
        local id2 st svc_active
        id2=$(printf '%02d' "$PUSH_ID")
        # 推送由 xrayls.service 统一管理: 状态 = 服务active + 目标端口在监听
        svc_active="no"
        systemctl is-active --quiet "$SYSTEMD" 2>/dev/null && svc_active="yes"
        if [ "$svc_active" = "yes" ] && port_in_use "$PUSH_TARGET_PORT"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi
        local mode_label
        [ "$PUSH_MODE" = "cf" ] && mode_label="CF+wss" || mode_label="直连"
        echo -e "${GREEN}${PUSH_ID}${RESET}) ${YELLOW}${PUSH_UUID:0:12}...${RESET} | ${BLUE}${mode_label}: $PUSH_SERVER_ADDR:${PUSH_SERVER_PORT}${RESET} | 目标 ${BLUE}127.0.0.1:$PUSH_TARGET_PORT${RESET} | $st" >&2
        echo "     WS路径: $PUSH_PATH" >&2
    done
    [ "$found" = 0 ] && echo "  (无推送)" >&2
    echo "------------------------------------------------------------------------" >&2
}

add_push() {
    print_title "新增反向推送（客户端 → 服务端）"
    local id
    id=$(next_id)
    local id2
    id2=$(printf '%02d' "$id")

    echo -e "${YELLOW}本机要暴露给服务端的服务端口（reverse-direct 落地端口）${RESET}" >&2
    local target
    target=$(safe_read_port 0)
    (( target >= 1 )) || { print_error "目标端口必须>0"; return; }

    echo -e "${YELLOW}连接模式${RESET}" >&2
    echo "  1) 走 Cloudflare/nginx (wss:443 + WS路径, 服务端在NAT后推荐)" >&2
    echo "  2) 直接 TCP 连接服务端端口 (服务端有公网端口时)" >&2
    read -r m
    m=$(clean_input "$m")
    local mode="cf"
    case "$m" in
        2) mode="direct" ;;
        1|"") mode="cf" ;;
        *) mode="cf" ;;
    esac

    local saddr
    saddr=$(safe_read "服务端域名/IP" "")

    echo -e "${YELLOW}UUID（与服务端隧道一致）${RESET}" >&2
    local uuid
    uuid=$(safe_read "UUID" "")

    if [ "$mode" = "cf" ]; then
        echo -e "${YELLOW}WS 路径（服务端 control 入站的 WS path）${RESET}" >&2
        local path
        path=$(safe_read "WS路径" "/")
        PUSH_SERVER_PORT=443
    else
        echo -e "${YELLOW}服务端端口（VLESS control 端口，直连用，这是远端端口不做本地占用检查）${RESET}" >&2
        local sport
        while true; do
            printf "请输入服务端端口 (默认: 443): " >&2
            read -r sport
            sport=$(clean_input "$sport")
            sport="${sport:-443}"
            [[ "$sport" =~ ^[0-9]+$ ]] && (( sport >= 1 && sport <= 65535 )) && break
            print_error "端口必须是 1-65535 的数字"
        done
        PUSH_SERVER_PORT=$sport
        PUSH_PATH=""
    fi
    [ -z "$saddr" ] && { print_error "服务端地址不能为空"; return; }
    [ -z "$uuid" ] && { print_error "UUID不能为空"; return; }

    local env
    env=$(env_file "$id")
    cat > "$env" <<EOF
PUSH_ID=$id
PUSH_MODE=$mode
PUSH_SERVER_ADDR=$saddr
PUSH_SERVER_PORT=${PUSH_SERVER_PORT:-443}
PUSH_PATH=${path:-}
PUSH_UUID=$uuid
PUSH_TARGET_PORT=$target
EOF

    gen_client_conf "$id" "$uuid" "$saddr" "${PUSH_SERVER_PORT:-443}" "$mode" "${path:-}" "$target" >/dev/null
    merge_routing
    validate_and_restart

    print_ok "反向推送 #$id 创建成功"
    echo "  本机端口: $target → 服务端(家)" >&2
    echo "  模式: $mode  $saddr:${PUSH_SERVER_PORT:-443}  path=${path:-}" >&2
}

validate_and_restart() {
    echo "=== 配置校验 ($(basename "$XRAY_BIN")) ===" >&2
    if "$XRAY_BIN" run -test -confdir "$CONF_DIR" >/tmp/revcli-test.log 2>&1; then
        print_ok "Configuration OK."
    else
        print_error "配置无效:"
        grep -aiE 'failed|error' /tmp/revcli-test.log | head -5 >&2 || tail -10 /tmp/revcli-test.log >&2
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

del_push() {
    list_pushes
    printf "请输入要删除的编号: " >&2
    read -r num
    num=$(clean_input "$num")
    local env id2
    env=$(env_file "$num")
    [ -f "$env" ] || { print_error "推送 #$num 不存在"; return; }
    id2=$(printf '%02d' "$num")
    read -r -p "确认删除推送 #$num? [y/N]: " ans >&2
    [[ "$ans" =~ ^[Yy]$ ]] || { print_info "已取消"; return; }
    # 移除 conf 片段 (无独立进程, 由 xrayls.service 统一管理)
    rm -f "$CONF_DIR/revcli-$id2.in.json"
    rm -f "$env"
    merge_routing
    validate_and_restart
    print_ok "已删除推送 #$num"
}

del_all() {
    read -r -p "确认删除所有推送? (yes/no): " ans >&2
    [ "$ans" != "yes" ] && { print_info "已取消"; return; }
    rm -f "$ENV_DIR"/push-*.env "$CONF_DIR"/revcli-*.in.json
    merge_routing
    print_ok "已删除全部推送"
}

test_push() {
    list_pushes
    printf "请输入要测试的编号: " >&2
    read -r num
    num=$(clean_input "$num")
    local env
    env=$(env_file "$num")
    [ -f "$env" ] || { print_error "推送 #$num 不存在"; return; }
    # shellcheck disable=SC1090
    source "$env"
    print_info "测试反向链路: 通过服务端 portal → 本机 $PUSH_TARGET_PORT ..."
    print_info "请在服务端执行: 访问 portal 端口测试（见服务端日志 access.log）"
    print_info "本机检查: 目标端口 $PUSH_TARGET_PORT 是否有监听"
    ss -tlnp 2>/dev/null | grep ":$PUSH_TARGET_PORT " | head -2 || \
        print_warn "本机 $PUSH_TARGET_PORT 未监听, 确认该服务确实在运行"
}

# ---------------- 菜单 ----------------
menu() {
    while true; do
        print_title "Xray 反向代理客户端面板"
        echo " 1) 查看推送列表" >&2
        echo " 2) 新增推送" >&2
        echo " 3) 校验配置/重启服务" >&2
        echo " 4) 删除某推送" >&2
        echo " 5) 删除全部推送" >&2
        echo " 6) 测试某推送" >&2
        echo " 0) 退出" >&2
        printf "请选择: " >&2
        read -r c
        c=$(clean_input "$c")
        case "$c" in
            1) list_pushes; printf "\n按回车继续..." >&2; read -r ;;
            2) add_push;   printf "\n按回车继续..." >&2; read -r ;;
            3) validate_and_restart; printf "\n按回车继续..." >&2; read -r ;;
            4) del_push;   printf "\n按回车继续..." >&2; read -r ;;
            5) del_all;    printf "\n按回车继续..." >&2; read -r ;;
            6) test_push;  printf "\n按回车继续..." >&2; read -r ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "\n按回车继续..." >&2; read -r ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    menu
fi