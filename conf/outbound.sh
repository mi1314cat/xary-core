#!/bin/bash

# ================================
# outbound.sh — Xray 出站节点管理脚本
# hysteria2.sh（入站脚本）的孪生版本：
#   - 同样的彩色输出 / print_* / print_title / safe_read 风格
#   - 同样以 conf 目录 JSON 片段为数据载体（Xray -confdir 合并）
#   - 每出站一个 conf/out-NN.json，tag = out-NN
#   - 入站→出站映射写入 conf/out-routing.json（与 nginx.json 的 routing 追加共存）
#   - 支持 VLESS / VMess / Trojan / Shadowsocks / Hysteria2 / Freedom
#   - 交互极简：只填 IP / 端口 / 密钥等核心字段，其余默认；也可直接粘贴分享链接导入
# 用法： bash outbound.sh   （测试时可 OUTBOUND_BASE_DIR=... 覆盖基础目录）
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
# 打印函数（全部输出到 stderr，与入站脚本一致）
# ================================
print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ================================
# 基础变量
# ================================
BASE_DIR="${OUTBOUND_BASE_DIR:-/root/catmi/xray}"
CONF_DIR="$BASE_DIR/conf"
OB_PREFIX="out"
ROUTING_FILE="$CONF_DIR/out-routing.json"
DEFAULT_OUTBOUND="direct"

# Xray 二进制（配置校验用）
XRAY_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_BIN" ]]; then
    for c in /root/catmi/xray/xrayls /usr/local/bin/xray xrayls; do
        command -v "$c" >/dev/null 2>&1 && { XRAY_BIN=$(command -v "$c"); break; }
    done
fi

mkdir -p "$CONF_DIR"

# ================================
# 输入清理
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

# ================================
# 安全输入（不会污染 JSON）
# ================================
safe_read() {
    local prompt="$1"
    local default="$2"
    local input

    if [[ -n "$default" ]]; then
        printf "%s (默认: %s): " "$prompt" "$default" >&2
    else
        printf "%s: " "$prompt" >&2
    fi
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

# 数字输入（1-65535，出站端口不检查本机占用）
safe_read_int() {
    local prompt="$1"
    local default="$2"
    local input

    while true; do
        printf "%s (默认: %s): " "$prompt" "$default" >&2
        read input
        input=$(clean_input "$input")
        input="${input:-$default}"
        [[ "$input" =~ ^[0-9]+$ ]] || { print_error "必须是数字"; continue; }
        (( input >= 1 && input <= 65535 )) || { print_error "范围 1-65535"; continue; }
        echo "$input"
        return
    done
}

# 单选输入（默认值直接回车）
safe_choose() {
    local prompt="$1"
    local default="$2"
    local input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

# 随机 UUID（缺 uuidgen 自动安装，与入站脚本一致）
ensure_uuidgen() {
    if ! command -v uuidgen >/dev/null 2>&1; then
        print_info "uuidgen 未安装，正在自动安装..."
        apt update -y >/dev/null 2>&1
        apt install uuid-runtime -y >/dev/null 2>&1
        print_ok "uuidgen 安装完成"
    fi
}

# ================================
# 获取下一个出站编号（01、02、03…）
# ================================
get_next_index() {
    local used=() i=1
    shopt -s nullglob
    for f in "$CONF_DIR"/${OB_PREFIX}-*.json; do
        local base
        base=$(basename "$f")
        if [[ "$base" =~ ^${OB_PREFIX}-([0-9]+)\.json$ ]]; then
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
# 出站文件工具
# ================================
out_file() { printf "%s/%s-%02d.json" "$CONF_DIR" "$OB_PREFIX" "$1"; }
out_tag()  { printf "%s-%02d" "$OB_PREFIX" "$1"; }

# 列出 out-*.json 编号（已排序）
out_numbers() {
    local f n
    shopt -s nullglob
    for f in "$CONF_DIR"/${OB_PREFIX}-*.json; do
        n=$(basename "$f" .json | sed "s/^${OB_PREFIX}-//")
        [[ "$n" =~ ^[0-9]+$ ]] && echo "$n"
    done | sort -n
}

# ================================
# 全部入站 tag（扫描 conf 目录非出站片段）
# ================================
inbound_tags() {
    local f t
    shopt -s nullglob
    for f in "$CONF_DIR"/*.json; do
        [[ "$(basename "$f")" == ${OB_PREFIX}-*.json ]] && continue
        [[ "$(basename "$f")" == out-routing.json ]] && continue
        while IFS= read -r t; do
            [[ -n "$t" ]] && echo "$t"
        done < <(jq -r '.inbounds[]?.tag // empty' "$f" 2>/dev/null)
    done | sort -u
}

# ================================
# 分享链接解析（极简导入：只问粘贴，不问字段）
# ================================
# 读取 URL 查询参数： get_param "k=v&k2=v2" key
get_param() {
    local qs="$1" key="$2" pair
    IFS='&' read -ra pairs <<< "$qs"
    for pair in "${pairs[@]}"; do
        [[ "${pair%%=*}" == "$key" ]] && echo "${pair#*=}" && return
    done
}

urldecode() { printf '%b' "${1//%/\\x}"; }

# hysteria2://pass@host:port?sni=..&insecure=1&pin=sha256hex#name
parse_hysteria2() {
    local url="$1" rest frag qs base userinfo hostport
    rest=${url#hysteria2://}
    frag=${rest##*#}; [[ "$frag" == "$rest" ]] && frag=""
    rest=${rest%%#*}
    qs=${rest#*\?}; [[ "$qs" == "$rest" ]] && qs=""
    base=${rest%%\?*}
    userinfo=${base%%@*}; hostport=${base##*@}
    OB_NAME=${frag:-Hysteria2}
    OB_PASS=$userinfo
    OB_ADDR=${hostport%%:*}
    OB_PORT=${hostport##*:}
    [[ -z "$OB_PORT" || "$OB_PORT" == "$OB_ADDR" ]] && OB_PORT=443
    OB_SNI=$(get_param "$qs" sni); [[ -z "$OB_SNI" ]] && OB_SNI=$OB_ADDR
    OB_PIN=$(get_param "$qs" pin)
    [[ -z "$OB_PIN" ]] && OB_PIN=$(get_param "$qs" pinnedPeerCertSha256)
    [[ -z "$OB_PIN" ]] && OB_PIN=$(get_param "$qs" sha256)
    OB_POOL=""; OB_SEND=""
}

# vless://uuid@host:port?type=&security=&sni=&fp=&pbk=&sid=&spx=&flow=&path=&host=#name
parse_vless() {
    local url="$1" rest frag qs base userinfo hostport
    rest=${url#vless://}
    frag=${rest##*#}; [[ "$frag" == "$rest" ]] && frag=""
    rest=${rest%%#*}
    qs=${rest#*\?}; [[ "$qs" == "$rest" ]] && qs=""
    base=${rest%%\?*}
    userinfo=${base%%@*}; hostport=${base##*@}
    OB_NAME=${frag:-VLESS}
    OB_UUID=$userinfo
    OB_ADDR=${hostport%%:*}
    OB_PORT=${hostport##*:}
    [[ -z "$OB_PORT" || "$OB_PORT" == "$OB_ADDR" ]] && OB_PORT=443
    OB_NET=$(get_param "$qs" type);        [[ -z "$OB_NET" ]] && OB_NET=tcp
    OB_SEC=$(get_param "$qs" security);    [[ -z "$OB_SEC" ]] && OB_SEC=none
    OB_SNI=$(get_param "$qs" sni)
    OB_FP=$(get_param "$qs" fp);           [[ -z "$OB_FP" ]] && OB_FP=chrome
    OB_PUB=$(get_param "$qs" pbk)
    OB_SID=$(get_param "$qs" sid)
    OB_SPX=$(get_param "$qs" spx);         [[ -z "$OB_SPX" ]] && OB_SPX=/
    OB_FLOW=$(get_param "$qs" flow)
    OB_WS_PATH=$(get_param "$qs" path);    [[ -z "$OB_WS_PATH" ]] && OB_WS_PATH=/
    OB_WS_HOST=$(get_param "$qs" host)
    OB_GRPC=$(get_param "$qs" serviceName);[[ -z "$OB_GRPC" ]] && OB_GRPC=grpc
    OB_XHTTP_PATH=$(get_param "$qs" path); [[ -z "$OB_XHTTP_PATH" ]] && OB_XHTTP_PATH=/
    OB_XHTTP_HOST=$(get_param "$qs" host)
    OB_ALPN=$(get_param "$qs" alpn)
    OB_POOL=""; OB_SEND=""
}

# trojan://pass@host:port?sni=..#name
parse_trojan() {
    local url="$1" rest frag qs base userinfo hostport
    rest=${url#trojan://}
    frag=${rest##*#}; [[ "$frag" == "$rest" ]] && frag=""
    rest=${rest%%#*}
    qs=${rest#*\?}; [[ "$qs" == "$rest" ]] && qs=""
    base=${rest%%\?*}
    userinfo=${base%%@*}; hostport=${base##*@}
    OB_NAME=${frag:-Trojan}
    OB_PASS=$userinfo
    OB_ADDR=${hostport%%:*}
    OB_PORT=${hostport##*:}
    [[ -z "$OB_PORT" || "$OB_PORT" == "$OB_ADDR" ]] && OB_PORT=443
    OB_SNI=$(get_param "$qs" sni); [[ -z "$OB_SNI" ]] && OB_SNI=$OB_ADDR
    OB_INSECURE=$(get_param "$qs" allowInsecure); [[ -z "$OB_INSECURE" ]] && OB_INSECURE=0
    OB_POOL=""; OB_SEND=""
}

# ss://BASE64(method:pass)@host:port 或 ss://method:pass@host:port#name
parse_ss() {
    local url="$1" rest frag qs base userinfo hostport decoded
    rest=${url#ss://}
    frag=${rest##*#}; [[ "$frag" == "$rest" ]] && frag=""
    rest=${rest%%#*}
    base=${rest%%\?*}
    userinfo=${base%%@*}; hostport=${base##*@}
    OB_NAME=${frag:-Shadowsocks}
    if [[ "$userinfo" == *:* ]]; then
        OB_METHOD=${userinfo%%:*}; OB_PASS=${userinfo#*:}
    else
        decoded=$(echo "$userinfo" | base64 -d 2>/dev/null)
        if [[ "$decoded" == *:* ]]; then
            OB_METHOD=${decoded%%:*}; OB_PASS=${decoded#*:}
        else
            print_error "无法解析 ss:// 链接（需要 base64 的 method:password）"; return 1
        fi
    fi
    OB_ADDR=${hostport%%:*}
    OB_PORT=${hostport##*:}
    [[ -z "$OB_PORT" || "$OB_PORT" == "$OB_ADDR" ]] && OB_PORT=8388
    OB_POOL=""; OB_SEND=""
}

# vmess://BASE64(JSON)#name
parse_vmess() {
    local url="$1" b64 json
    b64=${url#vmess://}
    b64=${b64%%#*}
    # 尾部 #name 在截断后丢失，单独取
    json=$(echo "$b64" | base64 -d 2>/dev/null) || { print_error "vmess 链接解析失败"; return 1; }
    OB_NAME=$(echo "$json" | jq -r '.ps // "VMess"' 2>/dev/null)
    OB_UUID=$(echo "$json" | jq -r '.id // empty' 2>/dev/null)
    OB_ADDR=$(echo "$json" | jq -r '.add // empty' 2>/dev/null)
    OB_PORT=$(echo "$json" | jq -r '.port // 443' 2>/dev/null)
    OB_NET=$(echo "$json" | jq -r '.net // "tcp"' 2>/dev/null)
    OB_WS_PATH=$(echo "$json" | jq -r '.path // "/"' 2>/dev/null)
    [[ "$OB_WS_PATH" == none ]] && OB_WS_PATH=/
    OB_WS_HOST=$(echo "$json" | jq -r '.host // empty' 2>/dev/null)
    OB_GRPC=$(echo "$json" | jq -r '.path // "grpc"' 2>/dev/null)
    tls=$(echo "$json" | jq -r '.tls // "none"' 2>/dev/null)
    if [[ "$tls" == "tls" ]]; then OB_SEC=tls; OB_SNI=$(echo "$json" | jq -r '.sni // .host // empty' 2>/dev/null); else OB_SEC=none; OB_SNI=""; fi
    OB_FP=chrome; OB_POOL=""; OB_SEND=""
}

# 统一导入入口
import_link() {
    print_title "导入分享链接"
    printf "粘贴链接 (hysteria2:// / vless:// / vmess:// / trojan:// / ss://): " >&2
    read url
    url=$(clean_input "$url")
    [[ -z "$url" ]] && { print_error "未输入链接"; return 1; }

    local proto
    proto=${url%%://*}
    case "$proto" in
        hysteria2) parse_hysteria2 "$url" ;;
        vless)     parse_vless "$url" ;;
        vmess)     parse_vmess "$url" || return 1 ;;
        trojan)    parse_trojan "$url" ;;
        ss)        parse_ss "$url" || return 1 ;;
        *) print_error "不支持的协议: $proto"; return 1 ;;
    esac

    local name wproto
    name=$(safe_read "显示名称" "$OB_NAME")
    OB_NAME=${name:-$OB_NAME}

    wproto=$proto
    [[ "$proto" == "ss" ]] && wproto=shadowsocks
    write_outbound "$wproto"
    print_ok "已导入 $proto 出站：$OB_NAME → $OB_ADDR:$OB_PORT"
}

# ================================
# 协议 JSON 生成器（纯输出，供测试直接调用）
# 使用全局 OB_* 变量
# ================================
# VLESS 出站
vless_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg uuid "$OB_UUID" --arg flow "$OB_FLOW" \
        --arg net "$OB_NET" --arg sec "$OB_SEC" --arg sni "$OB_SNI" \
        --arg fp "$OB_FP" --arg pub "$OB_PUB" --arg sid "$OB_SID" --arg spx "$OB_SPX" \
        --arg wsp "$OB_WS_PATH" --arg wsh "$OB_WS_HOST" --arg grpc "$OB_GRPC" \
        --arg xp "$OB_XHTTP_PATH" --arg xh "$OB_XHTTP_HOST" --arg send "$OB_SEND" \
        --arg pool "$OB_POOL" \
        '
        def settings:
          {network: $net}
          + (if $net == "ws" then {wsSettings: ({path: $wsp}
              + (if $wsh != "" then {headers: {Host: $wsh}} else {} end))} else {} end)
          + (if $net == "grpc" then {grpcSettings: {serviceName: $grpc}} else {} end)
          + (if $net == "xhttp" then {xhttpSettings: ({path: $xp}
              + (if $xh != "" then {host: $xh} else {} end))} else {} end)
          + (if $net == "tcp" then {tcpSettings: {}} else {} end)
          + (if $sec == "none" then {security: "none"} else {} end)
          + (if $sec == "tls" then {security: "tls", tlsSettings: {serverName: $sni, fingerprint: $fp, allowInsecure: false}} else {} end)
          + (if $sec == "reality" then {security: "reality", realitySettings: {serverName: $sni, fingerprint: $fp, publicKey: $pub, shortId: $sid, spiderX: $spx}} else {} end)
        ;
        {_meta: ({name:$name, proto:"vless"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
         outbounds: [{protocol:"vless", tag:$tag,
                      settings:{vnext:[{address:$addr, port:($port|tonumber),
                                        users:[{id:$uuid, encryption:"none", flow:$flow}]}]},
                      streamSettings: settings}
                     + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# VMess 出站
vmess_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg uuid "$OB_UUID" \
        --arg net "$OB_NET" --arg sec "$OB_SEC" --arg sni "$OB_SNI" --arg fp "$OB_FP" \
        --arg wsp "$OB_WS_PATH" --arg wsh "$OB_WS_HOST" --arg grpc "$OB_GRPC" \
        --arg send "$OB_SEND" --arg pool "$OB_POOL" \
        '
        def settings:
          {network: $net}
          + (if $net == "ws" then {wsSettings: ({path: $wsp}
              + (if $wsh != "" then {headers: {Host: $wsh}} else {} end))} else {} end)
          + (if $net == "grpc" then {grpcSettings: {serviceName: $grpc}} else {} end)
          + (if $net == "tcp" then {tcpSettings: {}} else {} end)
          + (if $sec == "none" then {security: "none"} else {} end)
          + (if $sec == "tls" then {security: "tls", tlsSettings: {serverName: $sni, fingerprint: $fp, allowInsecure: false}} else {} end)
        ;
        {_meta: ({name:$name, proto:"vmess"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
         outbounds: [{protocol:"vmess", tag:$tag,
                      settings:{vnext:[{address:$addr, port:($port|tonumber),
                                        users:[{id:$uuid, alterId:0, security:"auto"}]}]},
                      streamSettings: settings}
                     + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# Trojan 出站
trojan_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg pass "$OB_PASS" \
        --arg net "$OB_NET" --arg sec "$OB_SEC" --arg sni "$OB_SNI" --arg fp "$OB_FP" \
        --arg wsp "$OB_WS_PATH" --arg wsh "$OB_WS_HOST" \
        --arg send "$OB_SEND" --arg pool "$OB_POOL" \
        '
        def settings:
          {network: $net}
          + (if $net == "ws" then {wsSettings: ({path: $wsp}
              + (if $wsh != "" then {headers: {Host: $wsh}} else {} end))} else {} end)
          + (if $net == "tcp" then {tcpSettings: {}} else {} end)
          + (if $sec == "none" then {security: "none"} else {} end)
          + (if $sec == "tls" then {security: "tls", tlsSettings: {serverName: $sni, fingerprint: $fp, allowInsecure: false}} else {} end)
        ;
        {_meta: ({name:$name, proto:"trojan"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
         outbounds: [{protocol:"trojan", tag:$tag,
                      settings:{servers:[{address:$addr, port:($port|tonumber), password:$pass, level:0}]},
                      streamSettings: settings}
                     + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# Shadowsocks 出站
ss_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg method "$OB_METHOD" --arg pass "$OB_PASS" \
        --arg send "$OB_SEND" --arg pool "$OB_POOL" \
        '{_meta: ({name:$name, proto:"shadowsocks"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
          outbounds: [{protocol:"shadowsocks", tag:$tag,
                       settings:{servers:[{address:$addr, port:($port|tonumber), method:$method, password:$pass, level:0}]}}
                      + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# Hysteria2 出站（原生 QUIC）
# 协议标识 "hysteria" + settings.version=2（官方 Xray 模型）
# 关键：必须配 streamSettings.network="hysteria" 激活 QUIC 传输，否则默认走 TCP！
# 结构：settings 只放 version/address/port；auth 放 hysteriaSettings；TLS 放 tlsSettings
# pinnedPeerCertSha256 = 节点证书 SHA256（allowInsecure 已被官方移除）
#   获取方式: xrayls tls ping 或 QUIC 握手抓取，也可用 serve_cert_hash 辅助
hy2_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg pass "$OB_PASS" --arg sni "$OB_SNI" \
        --arg pin "$OB_PIN" --arg send "$OB_SEND" --arg pool "$OB_POOL" \
        '{_meta: ({name:$name, proto:"hysteria2"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
          outbounds: [{protocol:"hysteria", tag:$tag,
                       settings:{version:2, address:$addr, port:($port|tonumber)},
                       streamSettings:{network:"hysteria", security:"tls",
                         tlsSettings:{serverName:$sni, pinnedPeerCertSha256:$pin},
                         hysteriaSettings:{version:2, auth:$pass}}}
                      + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# Freedom 出站（本机直连，可指定源IPv4/IPv6）
freedom_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" \
        --arg send "$OB_SEND" --arg pool "$OB_POOL" \
        '{_meta: ({name:$name, proto:"freedom"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
          outbounds: [{protocol:"freedom", tag:$tag, settings:{}}
                      + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# 统一写文件
write_outbound() { # $1=proto
    local proto="$1" next tag json
    next=$(get_next_index)
    tag=$(out_tag "$next")
    case "$proto" in
        vless)       json=$(vless_json "$tag") ;;
        vmess)       json=$(vmess_json "$tag") ;;
        trojan)      json=$(trojan_json "$tag") ;;
        shadowsocks) json=$(ss_json "$tag") ;;
        hysteria2)   json=$(hy2_json "$tag") ;;
        freedom)     json=$(freedom_json "$tag") ;;
        *) print_error "未知协议 $proto"; return 1 ;;
    esac
    [[ -n "$json" ]] || { print_error "JSON 生成失败"; return 1; }
    echo "$json" | jq . > "$CONF_DIR/$OB_PREFIX-$next.json"
    print_ok "已写入 $CONF_DIR/$OB_PREFIX-$next.json (tag=$tag)"
}

# ================================
# IPv6 /64 地址池
# ================================
# 自动检测本机 /64 前缀（2409:8a20:1c93:5460::/64 形式）
# 注意：/64 子网 = 地址前 4 组（后 4 组是接口标识，不属前缀）
detect_v6_prefix() {
    local line net
    line=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 .*\/64/ && !/temporary/ {print $2; exit}')
    [[ -z "$line" ]] && line=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 .*\/64/ {print $2; exit}')
    [[ -z "$line" ]] && return 1
    net=$(echo "$line" | tr 'A-F' 'a-f' | awk -F: '{printf "%s:%s:%s:%s::/64", $1,$2,$3,$4}')
    echo "$net"
}

# 当前已分配池地址（扫描所有出站片段 _meta.pool.address）
used_v6_addresses() {
    local f
    shopt -s nullglob
    for f in "$CONF_DIR"/${OB_PREFIX}-*.json; do
        jq -r '._meta.pool.address // empty' "$f" 2>/dev/null
    done
}

# 规范化 IPv6：小写、展开 ::、逐组去前导零（与内核 ip addr 显示格式对齐）
# 例：2001:470:c:cf:0c00:04be:5753:2d2b → 2001:470:c:cf:c00:4be:5753:2d2b
#     2001:470:c:cf::2 → 2001:470:c:cf:0:0:0:2
canon6() {
    echo "$1" | awk -F: '
    {
        n = split($0, g, ":")
        zi = 0
        for (i=1; i<=n; i++) if (g[i]=="") { zi=i; break }
        delete ng; k=0
        if (zi>0) {
            for (i=1; i<zi; i++) ng[++k]=g[i]
            for (i=1; i<=9-n; i++) ng[++k]="0"
            for (i=zi+1; i<=n; i++) ng[++k]=g[i]
        } else {
            for (i=1; i<=n; i++) ng[++k]=g[i]
        }
        out=""
        for (i=1; i<=k; i++) {
            v=tolower(ng[i]); sub(/^0+/, "", v); if (v=="") v="0"
            out = out (i==1 ? "" : ":") v
        }
        print out
    }'
}

# 地址是否已在本机接口上（规范格式比对，容忍前导零省略 / :: 压缩）
addr_on_iface() {
    local want addr
    want=$(canon6 "$1" 2>/dev/null) || return 1
    [[ -n "$want" ]] || return 1
    while read -r addr; do
        [[ "$(canon6 "$addr")" == "$want" ]] && return 0
    done < <(ip -6 addr show 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="inet6"){a=$(i+1); sub(/\/.*/,"",a); print a}}')
    return 1
}

# 默认出口网卡（优先 IPv6 默认路由——HE 隧道等场景 v4/v6 默认口不同）
iface_name() {
    local v6 v4
    v6=$(ip -6 route show default 2>/dev/null | head -1 | awk '{print $5}')
    [[ -n "$v6" ]] && { echo "$v6"; return; }
    v4=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    [[ -n "$v4" ]] && { echo "$v4"; return; }
    echo ""
}

# 在指定前缀内生成一个未使用的随机 IPv6（全小写、无 ::、非全零、不重复、8 组合法）
# 用法: gen_v6_address "2409:8a20:1c93:5460::/64"
gen_v6_address() {
    local prefix="$1" net iid cand i
    prefix=$(echo "$prefix" | tr 'A-F' 'a-f')
    net=$(echo "$prefix" | sed 's/::\/64$//')
    [[ -z "$net" ]] && { print_error "前缀格式错误: $prefix"; return 1; }
    # 网段必须是恰好 4 组
    [[ "$net" =~ ^[0-9a-f]{1,4}(:[0-9a-f]{1,4}){3}$ ]] || { print_error "不是合法 /64 前缀: $prefix"; return 1; }
    for i in $(seq 1 50); do
        iid=$(printf '%04x:%04x:%04x:%04x' \
            $((RANDOM % 65536)) $((RANDOM % 65536)) \
            $((RANDOM % 65536)) $((RANDOM % 65536)))
        # 避免生成 :: （不允许四个组全零）
        [[ "$iid" == "0000:0000:0000:0000" ]] && continue
        cand="$net:$iid"
        # 必须为 8 组合法 IPv6（每组允许 1-4 位，如 2001:470:c:cf 前缀）
        [[ "$cand" =~ ^[0-9a-f]{1,4}(:[0-9a-f]{1,4}){7}$ ]] || continue
        # 避免重复 / 避免已在网卡
        used_v6_addresses | grep -qix "$cand" && continue
        addr_on_iface "$cand" && continue
        echo "$cand"
        return 0
    done
    print_error "50 次尝试后仍无法分配不重复的 IPv6"
    return 1
}

# 找到持有该 IPv6 前缀地址的接口（HE 隧道等：v6 地址在隧道口，与 v4 默认口不同）
# 注意去壳：隧道接口在 ip addr 里显示为 he-ipv6@NONE，必须剥掉 @ 后缀
prefix_iface() { # $1 = 2001:470:c:cf::/64
    local net="$1"
    [[ -z "$net" ]] && return 1
    net=${net%::/*}
    ip -6 addr show 2>/dev/null | awk -v n="$net" '
        /^[0-9]+: / { dev=$2; sub(/:$/, "", dev); sub(/@.*/, "", dev) }
        /inet6 /    { if ($2 ~ "^" n ":") { print dev; exit } }'
}

# 把地址挂到网卡（/128 源地址，nodad 跳过 DAD 避免 tentative 不可用；已存在则跳过）
# 返回 0=确认已在网卡上；返回 1=挂载失败（调用方必须中止，避免写出"假配置"）
# 网卡选择优先级：前缀所属接口 > v6 默认路由口 > v4 默认路由口
assign_v6() {
    local addr="$1" prefix="$2" iface addout rc
    # 防呆开关：仅当显式设置 OUTBOUND_NO_ASSIGN=1（自动化测试）时才跳过真实挂载
    [[ -n "$OUTBOUND_NO_ASSIGN" ]] && return 0
    addr_on_iface "$addr" && return 0
    if [[ -n "$prefix" ]]; then
        iface=$(prefix_iface "$prefix")
    fi
    [[ -z "$iface" ]] && iface=$(iface_name)
    if [[ -z "$iface" ]]; then
        print_error "找不到可挂载网卡（无默认路由且前缀内无地址），源IP: $addr"
        return 1
    fi
    # 防御：去 @ 后缀（隧道口显示 he-ipv6@NONE，实际设备名 he-ipv6）
    iface=${iface%%@*}
    print_info "挂载: ip -6 addr add $addr/128 dev $iface nodad"
    addout=$(ip -6 addr add "$addr/128" dev "$iface" nodad 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        print_error "挂载失败(exit=$rc): ip -6 addr add $addr/128 dev $iface nodad"
        [[ -n "$addout" ]] && printf "  └─ 内核/工具报错: %s\n" "$addout" >&2
        return 1
    fi
    # 等 1 秒再复查（避免内核异步时序）
    sleep 1
    if addr_on_iface "$addr"; then
        print_ok "源IPv6 已挂载: $addr/128 dev $iface"
        return 0
    fi
    # --- 诊断转储：add 成功但复查不到，把现场完整打出来 ---
    print_error "挂载后复查未通过: $addr 不在任何网卡上"
    printf "  └─ add 输出(exit=0): %s\n" "${addout:-（无输出）}" >&2
    printf "  └─ ip -6 addr show 中含该前缀的行:\n" >&2
    ip -6 addr show 2>/dev/null | grep -iE "inet6|$(echo "${prefix:-$addr}" | cut -d: -f1-4)" | head -25 | sed 's/^/      /' >&2
    printf "  └─ 目标接口状态: " >&2
    ip link show dev "$iface" 2>&1 | head -2 | sed 's/^/      /' >&2
    return 1
}

# 出口自检：用指定源 IPv6 访问公网并核对出口地址（HE 隧道等环境可即时发现不通）
egress_check() { # $1 = 源IPv6（可选；为空则用默认源）
    local addr="$1" got
    if [[ -n "$addr" ]]; then
        got=$(curl -6 --interface "$addr" -s --max-time 10 https://ipv6.icanhazip.com 2>/dev/null)
        [[ -z "$got" ]] && got=$(curl -6 --interface "$addr" -s --max-time 10 https://api6.ipify.org 2>/dev/null)
    else
        got=$(curl -6 -s --max-time 10 https://ipv6.icanhazip.com 2>/dev/null)
    fi
    got=$(echo "$got" | head -1)
    if [[ -n "$got" ]]; then
        if [[ -n "$addr" && "$(canon6 "$got")" == "$(canon6 "$addr")" ]]; then
            print_ok "出口自检✓ 出口IP = $got（与分配地址一致）"
        elif [[ -n "$addr" ]]; then
            print_info "出口自检: 出口=$got ≠ 分配地址=$addr（NAT 或运营商改写源地址）"
        else
            print_ok "IPv6 出口正常: $got"
        fi
    else
        print_info "出口自检未通过：该源IPv6 暂不通公网（若 HE 隧道未配置/未启动则属预期）"
    fi
}

# 移除网卡上的池地址（删除出站时调用；按实际持有地址的接口删除）
release_v6() {
    local addr="$1" dev
    addr_on_iface "$addr" || return 0
    dev=$(ip -6 addr show 2>/dev/null | awk -v a="$addr/" '
        /^[0-9]+: / { d=$2; sub(/:$/, "", d); sub(/@.*/, "", d) }
        /inet6 /    { if ($2 ~ "^" a) { print d; exit } }')
    [[ -n "$dev" ]] && ip -6 addr del "$addr/128" dev "$dev" 2>/dev/null
}

# 读取/设置池前缀（持久化在 out-routing.json 的 _meta.ipv6Pool）
pool_prefix() {
    jq -r '._meta.ipv6Pool // empty' "$ROUTING_FILE" 2>/dev/null
}
set_pool_prefix() {
    local prefix="$1"
    if [[ -f "$ROUTING_FILE" ]]; then
        jq --arg p "$prefix" '._meta.ipv6Pool=$p' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    else
        echo "{\"_meta\": {\"ipv6Pool\": \"$prefix\"}}" > "$ROUTING_FILE"
    fi
}

# ================================
# 入站→出站绑定（routing 生成）
# ================================
# 读取当前绑定表 bindings（入站tag -> 出站tag）
read_bindings() {
    jq -r '._meta.bindings // {} | to_entries[] | "\(.key)=\(.value)"' "$ROUTING_FILE" 2>/dev/null
}

# 统一的 rules 重组：分流规则(splitRules)在前 → 绑定规则(bindings) → ads→block
# 供 outbound.sh / split.sh 共用（fork 的 routing 后读覆盖先读，故全写进同一文件）
rebuild_routing_rules() {
    local file="$1"
    # 分流规则数组（split.sh 管理的，含全局规则和按入站规则）
    local splits
    splits=$(jq -c '._meta.splitRules // []' "$file" 2>/dev/null)
    # 绑定表
    local -A B=()
    local entry k v
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        k=${entry%%=*}; v=${entry#*=}
        B[$k]=$v
    done < <(jq -r '._meta.bindings // {} | to_entries[] | "\(.key)=\(.value)"' "$file" 2>/dev/null)

    # 组装绑定规则
    local jrules='[]'
    for k in "${!B[@]}"; do
        jrules=$(jq --arg k "$k" --arg v "${B[$k]}" \
            '. + [{inboundTag: [$k], outboundTag: $v}]' <<< "$jrules")
    done

    # 最终 rules = 分流 + 绑定 + ads→block
    jq -n --argjson splits "$splits" --argjson binds "$jrules" \
        '{routing: {rules: ($splits + $binds + [{domain:["geosite:category-ads-all"], outboundTag:"block"}])}}'
}

# 写入绑定表并重新生成 routing.rules（保留 splitRules 与 dualStack 元信息）
write_routing() {
    local newmeta
    newmeta=$(rebuild_routing_rules "$ROUTING_FILE")
    if [[ -f "$ROUTING_FILE" ]]; then
        # 保留 _meta 其余字段（bindings/splitRules/dualStack），仅替换 routing
        jq --argjson nr "$(jq '.routing' <<< "$newmeta")" \
            '.routing = $nr' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    else
        # 全新文件：从绑定表重建 _meta.bindings
        local bb
        bb=$(jq -r '._meta.bindings // {}' <<< '{}')
        jq -n --argjson bbind "$bb" --argjson nr "$(jq '.routing' <<< "$newmeta")" \
            '{_meta: {bindings: $bbind}, routing: $nr}' > "$ROUTING_FILE"
    fi
    print_ok "已写入 $ROUTING_FILE"
}

# ================================
# CRUD
# ================================
add_outbound() {
    print_title "新增出站"
    echo "请选择协议：" >&2
    echo "  1) VLESS" >&2
    echo "  2) VMess" >&2
    echo "  3) Trojan" >&2
    echo "  4) Shadowsocks" >&2
    echo "  5) Hysteria2" >&2
    echo "  6) Freedom（本机直连 / 指定源IP）" >&2
    echo "  7) 导入分享链接" >&2
    echo "  0) 返回" >&2
    read c
    c=$(clean_input "$c")
    case "$c" in
        1) wizard_vless ;;
        2) wizard_vmess ;;
        3) wizard_trojan ;;
        4) wizard_ss ;;
        5) wizard_hy2 ;;
        6) wizard_freedom ;;
        7) import_link ;;
        0) return ;;
        *) print_error "无效选项" ;;
    esac
}

wizard_vless() {
    ensure_uuidgen
    OB_NAME=$(safe_read "显示名称" "")
    OB_ADDR=$(safe_read "服务器 IP/域名" "")
    [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
    OB_PORT=$(safe_read_int "端口" 443)
    OB_UUID=$(safe_read "UUID" "$(uuidgen | tr 'A-Z' 'a-z')")
    local net_choice
    net_choice=$(safe_choose "传输: 1)tcp 2)ws 3)grpc 4)xhttp" 1)
    case "$net_choice" in
        2) OB_NET=ws ;;
        3) OB_NET=grpc ;;
        4) OB_NET=xhttp ;;
        *) OB_NET=tcp ;;
    esac
    local sec_choice
    sec_choice=$(safe_choose "安全: 1)none 2)tls 3)reality" 1)
    case "$sec_choice" in
        2)
            OB_SEC=tls
            OB_SNI=$(safe_read "SNI" "$OB_ADDR")
            OB_FP=chrome
            ;;
        3)
            OB_SEC=reality
            OB_SNI=$(safe_read "SNI(伪装域名)" "www.microsoft.com")
            OB_PUB=$(safe_read "PublicKey" "")
            [[ -z "$OB_PUB" ]] && { print_error "Reality 需要 PublicKey"; return 1; }
            OB_SID=$(safe_read "ShortID" "036cbb71")
            OB_FP=chrome
            OB_SPX=/
            ;;
        *) OB_SEC=none ;;
    esac
    OB_FLOW=$(safe_read "Flow(可空, 默认不填)" "")
    OB_WS_PATH=/; OB_WS_HOST=""; OB_GRPC=grpc; OB_XHTTP_PATH=/; OB_XHTTP_HOST=""
    case "$OB_NET" in
        ws)    OB_WS_PATH=$(safe_read "WS Path" "/"); OB_WS_HOST=$(safe_read "WS Host(可空)" "") ;;
        grpc)  OB_GRPC=$(safe_read "gRPC serviceName" "grpc") ;;
        xhttp) OB_XHTTP_PATH=$(safe_read "XHTTP Path" "/") ;;
    esac
    OB_SEND=$(safe_read "源IP绑定(可空)" "")
    write_outbound vless
}

wizard_vmess() {
    ensure_uuidgen
    OB_NAME=$(safe_read "显示名称" "")
    OB_ADDR=$(safe_read "服务器 IP/域名" "")
    [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
    OB_PORT=$(safe_read_int "端口" 443)
    OB_UUID=$(safe_read "UUID" "$(uuidgen | tr 'A-Z' 'a-z')")
    local net_choice
    net_choice=$(safe_choose "传输: 1)tcp 2)ws 3)grpc" 1)
    case "$net_choice" in
        2) OB_NET=ws ;;
        3) OB_NET=grpc ;;
        *) OB_NET=tcp ;;
    esac
    local sec_choice
    sec_choice=$(safe_choose "TLS: 1)关闭 2)开启" 1)
    if [[ "$sec_choice" == "2" ]]; then
        OB_SEC=tls
        OB_SNI=$(safe_read "SNI" "$OB_ADDR")
        OB_FP=chrome
    else
        OB_SEC=none; OB_SNI=""; OB_FP=chrome
    fi
    OB_WS_PATH=/; OB_WS_HOST=""; OB_GRPC=grpc
    case "$OB_NET" in
        ws)    OB_WS_PATH=$(safe_read "WS Path" "/"); OB_WS_HOST=$(safe_read "WS Host(可空)" "") ;;
        grpc)  OB_GRPC=$(safe_read "gRPC serviceName" "grpc") ;;
    esac
    OB_SEND=$(safe_read "源IP绑定(可空)" "")
    write_outbound vmess
}

wizard_trojan() {
    OB_NAME=$(safe_read "显示名称" "")
    OB_ADDR=$(safe_read "服务器 IP/域名" "")
    [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
    OB_PORT=$(safe_read_int "端口" 443)
    OB_PASS=$(safe_read "密码" "")
    local net_choice
    net_choice=$(safe_choose "传输: 1)tcp 2)ws" 1)
    [[ "$net_choice" == "2" ]] && OB_NET=ws || OB_NET=tcp
    local sec_choice
    sec_choice=$(safe_choose "TLS: 1)开启 2)关闭" 1)
    if [[ "$sec_choice" == "1" ]]; then
        OB_SEC=tls; OB_SNI=$(safe_read "SNI" "$OB_ADDR"); OB_FP=chrome
    else
        OB_SEC=none; OB_SNI=""; OB_FP=chrome
    fi
    OB_WS_PATH=/; OB_WS_HOST=""
    [[ "$OB_NET" == "ws" ]] && { OB_WS_PATH=$(safe_read "WS Path" "/"); OB_WS_HOST=$(safe_read "WS Host(可空)" ""); }
    OB_SEND=$(safe_read "源IP绑定(可空)" "")
    write_outbound trojan
}

wizard_ss() {
    OB_NAME=$(safe_read "显示名称" "")
    OB_ADDR=$(safe_read "服务器 IP/域名" "")
    [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
    OB_PORT=$(safe_read_int "端口" 8388)
    OB_METHOD=$(safe_read "加密方式" "aes-256-gcm")
    OB_PASS=$(safe_read "密码" "")
    OB_SEND=$(safe_read "源IP绑定(可空)" "")
    write_outbound shadowsocks
}

wizard_hy2() {
    echo "Hysteria2 出站添加方式：" >&2
    echo "  1) 粘贴分享链接 (hysteria2://...)" >&2
    echo "  2) 手动填写" >&2
    local m
    read m; m=$(clean_input "$m")
    if [[ "$m" == "1" ]]; then
        local link
        link=$(safe_read "粘贴 hysteria2:// 链接" "")
        [[ -z "$link" ]] && { print_error "链接不能为空"; return 1; }
        parse_hysteria2 "$link"
        OB_PIN=${OB_PIN:-}
        if [[ -z "$OB_PIN" ]]; then
            print_info "链接中无证书hash(pin)。没有 pin 时 xrayls 会校验证书，自签/CN-only证书将被拒。"
            print_info "可稍后在 split.sh/面板里补，或手动输入节点证书 SHA256:"
            OB_PIN=$(safe_read "节点证书 SHA256(可空)" "")
        fi
    else
        OB_NAME=$(safe_read "显示名称" "")
        OB_ADDR=$(safe_read "服务器 IP/域名" "")
        [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
        OB_PORT=$(safe_read_int "端口" 443)
        OB_PASS=$(safe_read "密钥/密码" "")
        [[ -z "$OB_PASS" ]] && { print_error "密钥不能为空"; return 1; }
        OB_SNI=$(safe_read "SNI(默认=地址)" "$OB_ADDR")
        print_info "证书校验: xrayls 要求 pinnedPeerCertSha256 (allowInsecure 已移除)。"
        print_info "获取节点证书 hash 示例: openssl s_client -connect <地址>:<端口> ... 或留空由服务端验证"
        OB_PIN=$(safe_read "节点证书 SHA256(可空)" "")
    fi
    OB_POOL=""; OB_SEND=""
    [[ -z "$OB_SNI" ]] && OB_SNI=$OB_ADDR
    write_outbound hysteria2
}

wizard_freedom() {
    OB_NAME=$(safe_read "显示名称" "")
    OB_SEND=""; OB_POOL=""
    echo "直连类型：" >&2
    echo "  1) 默认直连（无指定源IP）" >&2
    echo "  2) 指定 IPv4 源IP" >&2
    echo "  3) 自动分配 IPv6（/64 池）" >&2
    echo "  4) 双栈智能落地（IPv4站走IPv4 + IPv6站走IPv6）" >&2
    read ftype
    ftype=$(clean_input "$ftype")
    case "$ftype" in
        2)
            print_info "本机 IPv4:"
            ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | sed 's/^/  /' >&2
            OB_SEND=$(safe_read "源IPv4" "")
            [[ -n "$OB_SEND" ]] || { print_error "源IPv4 不能为空"; return 1; }
            ;;
        3)
            local prefix detected
            prefix=$(pool_prefix) || true
            if [[ -n "$prefix" ]]; then
                print_info "使用已保存的 IPv6 前缀: $prefix"
                prefix=$(safe_read "IPv6 前缀" "$prefix")
            else
                detected=$(detect_v6_prefix) || true
                if [[ -n "$detected" ]]; then
                    print_info "已自动检测到 IPv6 /64 子网: $detected（直接回车即使用）"
                    prefix=$(safe_read "IPv6 前缀" "$detected")
                else
                    print_info "未自动检测到 IPv6 /64（该服务器可能没有 SLAAC /64）"
                    prefix=$(safe_read "IPv6 前缀" "")
                fi
            fi
            [[ -z "$prefix" ]] && { print_error "前缀不能为空（如 2001:db8:abcd:1234::/64）"; return 1; }
            # 持久化
            set_pool_prefix "$prefix"
            local addr
            addr=$(gen_v6_address "$prefix") || return 1
            assign_v6 "$addr" "$prefix" || return 1
            egress_check "$addr"
            OB_SEND=$addr
            OB_POOL="${prefix}|${addr}"
            print_ok "已分配源IPv6: $addr"
            ;;
        4)
            wizard_dualstack
            return $?
            ;;
        *) ;;
    esac
    write_outbound freedom
}

# 检测本机公网 IPv4（优先非私有、默认路由出口）
detect_public_ipv4() {
    local v4
    v4=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)
    [[ -z "$v4" ]] && v4=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    echo "$v4"
}

# 取/建 v4域名名单出站（只建一个，复用），返回 tag
# 双栈：v4域名单 → v4freedom出站；其余 → v6freedom出站
# 一次调用创建 v4出站 + v6出站 两个，并把信息记入 routing._meta.dualStack
wizard_dualstack() {
    print_title "双栈智能落地（IPv4站走IPv4 + IPv6站走IPv6）"
    # 1) 确定前缀
    local prefix detected
    prefix=$(pool_prefix) || true
    if [[ -z "$prefix" ]]; then
        detected=$(detect_v6_prefix) || true
        if [[ -n "$detected" ]]; then
            print_info "已自动检测到 IPv6 /64: $detected"
            prefix=$(safe_read "IPv6 前缀" "$detected")
        else
            print_info "未检测到 IPv6 /64"
            prefix=$(safe_read "IPv6 前缀" "")
        fi
        [[ -z "$prefix" ]] && { print_error "前缀不能为空"; return 1; }
        set_pool_prefix "$prefix"
    else
        print_info "使用已保存的 IPv6 前缀: $prefix"
    fi

    # 2) 本机公网 IPv4 作为 v4 落地
    local v4
    v4=$(detect_public_ipv4)
    if [[ -z "$v4" ]]; then
        print_info "未检测到公网 IPv4，请输入（或直接回车让 v4 站也走默认双栈）:"
        v4=$(safe_read "公网IPv4" "")
    else
        print_info "检测到公网 IPv4: $v4"
        local v4in
        v4in=$(safe_read "IPv4落地地址" "$v4")
        [[ -n "$v4in" ]] && v4=$v4in
    fi

    # 3) 创建 v6 出站
    local v6addr
    v6addr=$(gen_v6_address "$prefix") || return 1
    assign_v6 "$v6addr" "$prefix" || return 1
    egress_check "$v6addr"

    # 4) 取编号，写两个出站（先写 v6，再取 v4 编号，避免重复）
    local n6 n4 tag6 tag4
    n6=$(get_next_index)
    tag6=$(out_tag "$n6")
    # v6 出站
    jq -n --arg t "$tag6" --arg a "$v6addr" --arg p "$prefix" --arg nm "双栈IPv6" \
        '{_meta:{name:$nm, proto:"freedom", pool:{prefix:$p, address:$a}}, outbounds:[{protocol:"freedom",tag:$t,settings:{},sendThrough:$a}]}' \
        > "$CONF_DIR/$OB_PREFIX-$n6.json"
    # v6 文件已写入，此时取 v4 编号必然不同
    n4=$(get_next_index)
    tag4=$(out_tag "$n4")
    # v4 出站（若 v4 地址为空，则用默认 direct 语义=不带 sendThrough，走本机默认）
    if [[ -n "$v4" ]]; then
        jq -n --arg t "$tag4" --arg a "$v4" --arg nm "双栈IPv4" \
            '{_meta:{name:$nm, proto:"freedom"}, outbounds:[{protocol:"freedom",tag:$t,settings:{},sendThrough:$a}]}' \
            > "$CONF_DIR/$OB_PREFIX-$n4.json"
    else
        jq -n --arg t "$tag4" --arg nm "双栈IPv4" \
            '{_meta:{name:$nm, proto:"freedom"}, outbounds:[{protocol:"freedom",tag:$t,settings:{}}]}' \
            > "$CONF_DIR/$OB_PREFIX-$n4.json"
    fi
    print_ok "已创建: $tag4 (IPv4落地=$v4) + $tag6 (IPv6落地=$v6addr)"

    # 5) 写入分流规则：v4域名名单(全局) → v4出站；其余走绑定
    #    统一写 _meta.splitRules（分流规则数组，与 split.sh 共用）
    local dss
    dss=$(jq -n --arg v4 "$tag4" \
        '[{type:"field", domain:["domain:browserleaks.com","domain:matrix.tencent.com","domain:baidu.com","domain:douyin.com","domain:taobao.com"], outboundTag:$v4}]')
    if [[ -f "$ROUTING_FILE" ]]; then
        jq --argjson ds "$dss" '._meta.splitRules = ((._meta.splitRules // []) + $ds)' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    else
        jq -n --argjson ds "$dss" '{_meta:{bindings:{}, splitRules:$ds}}' > "$ROUTING_FILE"
    fi
    write_routing
    print_ok "双栈智能落地完成：纯IPv4站→$tag4（全局分流），IPv6站→$tag6"
    print_info "提示：把该入站通过菜单7绑定到 $tag6，即可让该入站获得双栈能力（v4站自动走IPv4）"
    return 0
}

# 查看/编辑双栈 v4 域名名单（操作 _meta.splitRules 里的全局规则）
dual_domains() {
    print_title "双栈 v4 域名名单"
    if [[ ! -f "$ROUTING_FILE" ]] || [[ "$(jq '._meta.splitRules // [] | length' "$ROUTING_FILE" 2>/dev/null)" == "0" ]]; then
        print_info "尚未配置双栈落地（菜单2→6 Freedom→4）或无分流规则"
        return 0
    fi
    # 找到 v4 站分流的规则（含 browserleaks 的全局规则）
    local idx tags
    idx=$(jq -r '._meta.splitRules | to_entries | map(select(.value.domain // [] | index("domain:browserleaks.com"))) | .[0].key // empty' "$ROUTING_FILE" 2>/dev/null)
    if [[ -z "$idx" ]]; then
        print_info "未找到双栈 v4 分流规则（含 browserleaks.com 的那条）"
        return 0
    fi
    echo "当前 v4 域名名单（这些站走IPv4落地）:" >&2
    jq -r "._meta.splitRules[$idx].domain[]" "$ROUTING_FILE" 2>/dev/null | sed 's/^/  /' >&2
    echo "v4出站=$(jq -r "._meta.splitRules[$idx].outboundTag" "$ROUTING_FILE")" >&2
    printf "新增域名(如 example.com，回车跳过): " >&2
    local nd
    read nd; nd=$(clean_input "$nd")
    if [[ -n "$nd" ]]; then
        nd=${nd#domain:}
        jq --argjson i "$idx" --arg d "domain:$nd" '._meta.splitRules[$i].domain += [$d] | ._meta.splitRules[$i].domain |= unique' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
        write_routing
        print_ok "已加入: $nd"
    fi
    printf "移除域名(输完整域名，回车跳过): " >&2
    local rm
    read rm; rm=$(clean_input "$rm")
    if [[ -n "$rm" ]]; then
        rm=${rm#domain:}
        jq --argjson i "$idx" --arg d "domain:$rm" '._meta.splitRules[$i].domain |= map(select(. != $d))' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
        write_routing
        print_ok "已移除: $rm"
    fi
}

list_outbounds() {
    print_title "出站列表"
    local n f proto name tag addr port src meta cnt
    local total=0
    for n in $(out_numbers); do
        f=$(out_file "$n")
        proto=$(jq -r '._meta.proto // "?"' "$f")
        name=$(jq -r '._meta.name // empty' "$f")
        tag=$(jq -r '.outbounds[0].tag // empty' "$f")
        addr=$(jq -r '.outbounds[0].settings.vnext[0].address // .outbounds[0].settings.servers[0].address // .outbounds[0].settings.address // empty' "$f")
        port=$(jq -r '.outbounds[0].settings.vnext[0].port // .outbounds[0].settings.servers[0].port // .outbounds[0].settings.port // empty' "$f")
        src=$(jq -r '.outbounds[0].sendThrough // empty' "$f")
        cnt=$(read_bindings | grep -c "=${tag}$" || true)
        printf "${GREEN}%s${RESET}) ${YELLOW}%s${RESET} [%s] tag=${BLUE}%s${RESET} %s:%s\n" \
            "$n" "$name" "$proto" "$tag" "${addr:-直连}" "${port:-}" >&2
        [[ -n "$src" ]] && printf "      源IP: ${CYAN}%s${RESET}  被绑定入站数: %s\n" "$src" "$cnt" >&2
        total=$((total+1))
    done
    [[ $total -eq 0 ]] && print_info "暂无出站，请先新增"
}

# 选择一个出站编号
pick_outbound() {
    local n
    printf "输入出站编号: " >&2
    read n
    n=$(clean_input "$n")
    [[ "$n" =~ ^[0-9]+$ ]] || { print_error "编号无效"; return 1; }
    [[ -f "$(out_file "$n")" ]] || { print_error "出站 $n 不存在"; return 1; }
    echo "$n"
}

show_outbound() {
    local n f
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    print_title "出站详情 $n"
    jq . "$f" >&2
}

edit_outbound() {
    list_outbounds
    local n f
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    print_title "修改出站 $n"
    echo "  1) 向导修改（重新填写核心信息）" >&2
    echo "  2) 直接编辑原始 JSON（自由定制）" >&2
    echo "  3) 重新分配 IPv6 源地址" >&2
    echo "  0) 返回" >&2
    read c
    c=$(clean_input "$c")
    case "$c" in
        1)
            # 向导修改：只更新核心字段，其余（传输/安全等）保留原 JSON 原样，尊重自由定制
            local oldname oldaddr oldport proto
            oldname=$(jq -r '._meta.name // empty' "$f")
            oldaddr=$(jq -r '.outbounds[0].settings.vnext[0].address // .outbounds[0].settings.servers[0].address // .outbounds[0].settings.address // empty' "$f")
            oldport=$(jq -r '.outbounds[0].settings.vnext[0].port // .outbounds[0].settings.servers[0].port // .outbounds[0].settings.port // empty' "$f")
            proto=$(jq -r '._meta.proto' "$f")
            OB_NAME=$(safe_read "显示名称" "$oldname")
            OB_ADDR=$(safe_read "服务器 IP/域名" "$oldaddr")
            OB_PORT=$(safe_read_int "端口" "$oldport")
            OB_SEND=$(safe_read "源IP绑定(当前: $(jq -r '.outbounds[0].sendThrough // "无"' "$f"))" "$(jq -r '.outbounds[0].sendThrough // empty' "$f")")

            local nu
            case "$proto" in
                vless|vmess)
                    nu=$(safe_read "UUID" "$(jq -r '.outbounds[0].settings.vnext[0].users[0].id' "$f")")
                    jq --arg name "$OB_NAME" --arg addr "$OB_ADDR" --arg port "$OB_PORT" \
                       --arg uuid "$nu" --arg send "$OB_SEND" \
                       '._meta.name=$name |
                        .outbounds[0].settings.vnext[0].address=$addr |
                        .outbounds[0].settings.vnext[0].port=($port|tonumber) |
                        .outbounds[0].settings.vnext[0].users[0].id=$uuid |
                        .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
                trojan)
                    nu=$(safe_read "密码" "$(jq -r '.outbounds[0].settings.servers[0].password' "$f")")
                    jq --arg name "$OB_NAME" --arg addr "$OB_ADDR" --arg port "$OB_PORT" \
                       --arg pass "$nu" --arg send "$OB_SEND" \
                       '._meta.name=$name |
                        .outbounds[0].settings.servers[0].address=$addr |
                        .outbounds[0].settings.servers[0].port=($port|tonumber) |
                        .outbounds[0].settings.servers[0].password=$pass |
                        .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
                shadowsocks)
                    nu=$(safe_read "密码" "$(jq -r '.outbounds[0].settings.servers[0].password' "$f")")
                    local mm
                    mm=$(safe_read "加密方式" "$(jq -r '.outbounds[0].settings.servers[0].method' "$f")")
                    jq --arg name "$OB_NAME" --arg addr "$OB_ADDR" --arg port "$OB_PORT" \
                       --arg pass "$nu" --arg method "$mm" --arg send "$OB_SEND" \
                       '._meta.name=$name |
                        .outbounds[0].settings.servers[0].address=$addr |
                        .outbounds[0].settings.servers[0].port=($port|tonumber) |
                        .outbounds[0].settings.servers[0].password=$pass |
                        .outbounds[0].settings.servers[0].method=$method |
                        .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
                hysteria2)
                    nu=$(safe_read "密钥/密码" "$(jq -r '.outbounds[0].settings.password' "$f")")
                    local sni2
                    sni2=$(safe_read "SNI" "$(jq -r '.outbounds[0].settings.tls.serverName' "$f")")
                    jq --arg name "$OB_NAME" --arg addr "$OB_ADDR" --arg port "$OB_PORT" \
                       --arg pass "$nu" --arg sni "$sni2" --arg send "$OB_SEND" \
                       '._meta.name=$name |
                        .outbounds[0].settings.address=$addr |
                        .outbounds[0].settings.port=($port|tonumber) |
                        .outbounds[0].settings.password=$pass |
                        .outbounds[0].settings.tls.serverName=$sni |
                        .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
                freedom)
                    jq --arg name "$OB_NAME" --arg send "$OB_SEND" \
                       '._meta.name=$name | .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
            esac
            print_ok "已更新 out-$n"
            ;;
        2)
            nano "$f"
            print_ok "已保存（注意保持 JSON 合法，运行菜单 9 校验）"
            ;;
        3)
            local prefix addr
            prefix=$(jq -r '._meta.pool.prefix // empty' "$f")
            if [[ -z "$prefix" ]]; then
                prefix=$(pool_prefix) || true
                if [[ -z "$prefix" ]]; then
                    prefix=$(detect_v6_prefix) || true
                    [[ -n "$prefix" ]] && print_info "已自动检测到 IPv6 前缀: $prefix"
                fi
                [[ -z "$prefix" ]] && { print_error "未找到 IPv6 前缀，请先在池菜单中设置"; return 1; }
            fi
            addr=$(gen_v6_address "$prefix") || return 1
            assign_v6 "$addr" "$prefix" || return 1
            # 释放旧的
            local old
            old=$(jq -r '._meta.pool.address // empty' "$f")
            [[ -n "$old" ]] && release_v6 "$old"
            jq --arg pa "$prefix" --arg aa "$addr" \
                '._meta.pool = {prefix:$pa, address:$aa} | .outbounds[0].sendThrough = $aa' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
            print_ok "新源IPv6: $addr（注意：如需更换网卡地址请先删旧）"
            ;;
        0) return ;;
        *) print_error "无效选项" ;;
    esac
}

copy_outbound() {
    list_outbounds
    local n f nn proto tag name
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    nn=$(get_next_index)
    tag=$(out_tag "$nn")
    proto=$(jq -r '._meta.proto' "$f")
    name=$(jq -r '._meta.name // empty' "$f")
    name=$(safe_read "新显示名称" "${name}-副本")
    OB_POOL=""
    # 若源是 freedom v6，分配新地址
    if [[ "$proto" == "freedom" && -n "$(jq -r '._meta.pool.address // empty' "$f")" ]]; then
        local prefix addr
        prefix=$(jq -r '._meta.pool.prefix' "$f")
        addr=$(gen_v6_address "$prefix") || return 1
        assign_v6 "$addr" "$prefix" || return 1
        OB_POOL="${prefix}|${addr}"
        print_ok "为副本分配新源IPv6: $addr"
    fi
    jq --arg tag "$tag" --arg name "$name" \
       --arg pool "$OB_POOL" \
       '.outbounds[0].tag=$tag | ._meta.name=$name |
        if $pool != "" then ._meta.pool = {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])} | .outbounds[0].sendThrough = ($pool|split("|")[1]) else ._meta.pool = null | del(.outbounds[0].sendThrough) end' \
       "$f" > "$(out_file "$nn")"
    print_ok "已复制为 out-$nn (tag=$tag)"
}

delete_outbound() {
    list_outbounds
    local n f tag deps yn
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    tag=$(out_tag "$n")

    # 保护 direct / block（它们属于 nginx.json）
    if [[ "$tag" == "direct" || "$tag" == "block" ]]; then
        print_error "$tag 是基础出站，不允许删除"
        return 1
    fi

    deps=$(read_bindings | grep "=${tag}$" | cut -d= -f1)
    if [[ -n "$deps" ]]; then
        print_error "警告：$tag 当前被以下入站使用："
        echo "$deps" | sed 's/^/  /' >&2
        printf "删除后这些入站将自动恢复为默认出站(${DEFAULT_OUTBOUND})。是否继续? [y/N]: " >&2
        read yn
        yn=$(clean_input "$yn")
        [[ "$yn" == "y" || "$yn" == "Y" ]] || { print_info "已取消"; return; }
        # 移除绑定
        if [[ -f "$ROUTING_FILE" ]]; then
            jq --arg t "$tag" '._meta.bindings |= with_entries(select(.value != $t))' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
        fi
    else
        printf "确认删除出站 $n ($tag) ? [y/N]: " >&2
        read yn
        yn=$(clean_input "$yn")
        [[ "$yn" == "y" || "$yn" == "Y" ]] || { print_info "已取消"; return; }
    fi

    # 释放 IPv6
    local old
    old=$(jq -r '._meta.pool.address // empty' "$f")
    [[ -n "$old" ]] && release_v6 "$old"

    rm -f "$f"
    write_routing
    print_ok "已删除出站 $n ($tag)"
}

# ================================
# 出站测试
# ================================
say() { printf "${CYAN}%-18s${RESET} %s\n" "$1" "$2" >&2; }

test_outbound() {
    list_outbounds
    local n f proto addr port sni send v6
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    proto=$(jq -r '._meta.proto' "$f")
    addr=$(jq -r '.outbounds[0].settings.vnext[0].address // .outbounds[0].settings.servers[0].address // .outbounds[0].settings.address // empty' "$f")
    port=$(jq -r '.outbounds[0].settings.vnext[0].port // .outbounds[0].settings.servers[0].port // .outbounds[0].settings.port // empty' "$f")
    sni=$(jq -r '.outbounds[0].settings.tls.serverName // .outbounds[0].streamSettings.tlsSettings.serverName // .outbounds[0].streamSettings.realitySettings.serverName // empty' "$f")
    send=$(jq -r '.outbounds[0].sendThrough // empty' "$f")

    print_title "测试出站 out-$n ($proto)"

    # 1. DNS
    if [[ "$addr" =~ ^[0-9a-fA-F:]+$ && "$addr" != *"."* ]]; then
        say "DNS" "地址是纯 IPv6，跳过 DNS 解析"
    elif [[ "$addr" =~ ^[0-9.]+$ ]]; then
        say "DNS" "地址是纯 IPv4，跳过 DNS 解析"
    else
        if getent ahosts "$addr" >/dev/null 2>&1; then
            say "DNS" "解析成功: $(getent ahosts "$addr" | head -1 | awk '{print $1}')"
        else
            say "DNS" "解析失败"
        fi
    fi

    # 2. TCP 连接
    if timeout 5 bash -c "echo > /dev/tcp/$addr/$port" 2>/dev/null; then
        say "TCP" "$addr:$port 连通"
    else
        say "TCP" "$addr:$port 连接失败（可能被墙或端口不通）"
    fi

    # 3. TLS 握手（tls/reality/hy2/trojan）
    if [[ -n "$sni" && -x "$(command -v openssl)" ]]; then
        if echo | timeout 8 openssl s_client -connect "$addr:$port" -servername "$sni" 2>/dev/null | grep -q "CONNECTION ESTABLISHED"; then
            say "TLS" "握手成功 (sni=$sni)"
        else
            say "TLS" "握手失败（Reality 或证书校验属正常，以实际流量为准）"
        fi
    fi

    # 4. 代理握手 / 出口验证：Freedom 有源IP时实测出口
    if [[ "$proto" == "freedom" ]]; then
        if [[ -n "$send" ]]; then
            if [[ "$send" == *":"* ]]; then
                # 源IPv6：先确认已挂载到网卡，未挂载则尝试补救并明示
                if ! addr_on_iface "$send"; then
                    say "源IP" "地址 $send 未挂载到任何网卡！正在尝试挂载..."
                    assign_v6 "$send" "$(jq -r '._meta.pool.prefix // empty' "$f")" || say "源IP" "⚠️ 挂载失败：该出站当前不可用，请检查 IPv6 路由/隧道"
                fi
                out=$(curl -6 --interface "$send" -s --max-time 12 https://api6.ipify.org 2>/dev/null; curl -6 --interface "$send" -s --max-time 12 https://ipv6.icanhazip.com 2>/dev/null)
                got=$(echo "$out" | head -1)
                if [[ -n "$got" ]]; then
                    say "出口IPv6" "出口=$got (期望=$send) $([[ "$got" == "$send" ]] && echo -e "${GREEN}一致✓${RESET}" || echo -e "${YELLOW}不一致!${RESET}")"
                else
                    say "出口IPv6" "无法通过该源IP访问公网（检查 IPv6 路由/隧道/防火墙）"
                fi
            else
                got=$(curl -4 --interface "$send" -s --max-time 12 https://api.ipify.org 2>/dev/null)
                if [[ -n "$got" ]]; then
                    say "出口IPv4" "出口=$got (期望=$send) $([[ "$got" == "$send" ]] && echo -e "${GREEN}一致✓${RESET}" || echo -e "${YELLOW}不一致!${RESET}")"
                else
                    say "出口IPv4" "无法通过该源IP访问公网"
                fi
            fi
        else
            msg=$(curl -4 -s --max-time 12 https://api.ipify.org 2>/dev/null)
            say "出口IPv4" "默认出口 IPv4: ${msg:-未知}"
        fi
    else
        say "代理" "远程节点连通性已测（完整代理路径需通过入站映射后访问验证）"
    fi
}

# ================================
# 一键更换落地 IPv6（手动按需"用完即换"，每次换一个全新随机源IP）
# 单出站方案：生成新IP → 挂载 → 写回 → 释放旧IP → 重启
# ================================
rotate_out6() {
    local n f prefix old tag
    print_title "更换落地 IPv6（手动按需）"
    # 只处理 Freedom 带源IPv6 的出站
    local -a v6n=()
    for n in $(out_numbers); do
        f=$(out_file "$n")
        [[ "$(jq -r '.outbounds[0].protocol' "$f")" == "freedom" ]] || continue
        [[ "$(jq -r '.outbounds[0].sendThrough // empty' "$f")" == *":"* ]] && v6n+=("$n")
    done
    if ((${#v6n[@]} == 0)); then
        print_error "没有带源IPv6 的 Freedom 出站。请先在 菜单2→6 Freedom→3 自动分配IPv6 创建一个。"
        return 1
    fi
    if ((${#v6n[@]} == 1)); then
        n=${v6n[0]}
        print_info "将更换 Freedom 出站 $(out_tag "$n")"
    else
        echo "选择要更换落地IP的出站：" >&2
        local i
        for i in "${!v6n[@]}"; do
            local num=${v6n[$i]} ot
            ot=$(out_tag "$num")
            echo "  $((i+1))) $ot" >&2
        done
        printf "请选择: " >&2; read sel; sel=$(clean_input "$sel")
        [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#v6n[@]} )) || { print_error "无效选择"; return 1; }
        n=${v6n[$((sel-1))]}
    fi
    f=$(out_file "$n")
    tag=$(out_tag "$n")
    old=$(jq -r '.outbounds[0].sendThrough' "$f")
    # 前缀：优先出站 _meta.pool.prefix，其次池前缀，再次自动检测
    prefix=$(jq -r '._meta.pool.prefix // empty' "$f")
    [[ -z "$prefix" ]] && prefix=$(pool_prefix)
    [[ -z "$prefix" ]] && prefix=$(detect_v6_prefix) || true
    [[ -z "$prefix" ]] && { print_error "无法确定 IPv6 池前缀（请先在池菜单设置）"; return 1; }
    print_info "新IP将取自前缀: $prefix"
    printf "确认更换 ${tag} 的落地IPv6 (当前 $old)？y/N: " >&2
    read c; c=$(clean_input "$c")
    [[ "$c" == "y" || "$c" == "Y" ]] || { print_info "已取消"; return 1; }

    local addr
    addr=$(gen_v6_address "$prefix") || return 1
    # 挂载新地址（失败则中止，绝不留假配置）
    assign_v6 "$addr" "$prefix" || return 1
    # 写回（更新 _meta.pool 与 sendThrough）
    if ! jq --arg pa "$prefix" --arg aa "$addr" \
        '._meta.pool = {prefix:$pa, address:$aa} | .outbounds[0].sendThrough = $aa' "$f" > "${f}.tmp" 2>/dev/null; then
        release_v6 "$addr"; print_error "写回配置失败，已撤销新IP"; return 1
    fi
    mv "${f}.tmp" "$f"
    # 释放旧地址（新IP已用，若冲突释放旧IP）
    [[ -n "$old" && "$old" != "$addr" ]] && release_v6 "$old"
    print_ok "已更换: ${tag} 落地IPv6 = $addr"
    egress_check "$addr"
    # 提示重启使 live 进程加载
    [[ -n "$1" ]] && return 0
    printf "重启 xrayls 使新IP生效? [y/N]: " >&2; read rr; rr=$(clean_input "$rr")
    if [[ "$rr" == "y" || "$rr" == "Y" ]]; then
        restart_xrayls
    else
        print_info "未重启。新IP已挂载并写入配置，但 xrayls 仍用旧出站。请稍后菜单9 重启。"
    fi
    return 0
}

# 批量预生成多个 IPv6（不写配置，只挂载+显示，供手动挑选/备用）
gen_pool_batch() {
    print_title "批量生成落地 IPv6（备用池）"
    local prefix cnt i a
    prefix=$(pool_prefix) || true
    [[ -z "$prefix" ]] && prefix=$(detect_v6_prefix) || true
    [[ -z "$prefix" ]] && { print_error "无法确定前缀（请先在池菜单设置）"; return 1; }
    printf "前缀 %s；生成数量(默认8): " "$prefix" >&2; read cnt; cnt=$(clean_input "$cnt"); cnt=${cnt:-8}
    [[ "$cnt" =~ ^[0-9]+$ ]] || { print_error "数量非法"; return 1; }
    (( cnt > 200 )) && cnt=200
    echo "已生成(已挂载到网卡，可任选一个写进出站):" >&2
    for i in $(seq 1 "$cnt"); do
        a=$(gen_v6_address "$prefix") || continue
        assign_v6 "$a" "$prefix" 2>/dev/null
        echo "  $a" >&2
    done
    echo "提示: 通过 菜单3 修改出站→填写源IP 使用；不想要的可手动删除: ip -6 addr del <ip>/128 dev <网卡>" >&2
}

# ================================
# 绑定管理
# ================================
# 判断出站是否 v6-only（freedom + sendThrough 为 IPv6）——绑定到它会打不开 v4-only 站
is_v6only_outbound() {
    local f="$1"
    local proto send
    proto=$(jq -r '.outbounds[0].protocol' "$f" 2>/dev/null)
    send=$(jq -r '.outbounds[0].sendThrough // empty' "$f" 2>/dev/null)
    [[ "$proto" == "freedom" && "$send" == *":"* ]]
}

bind_menu() {
    print_title "入站 → 出站绑定管理"
    [[ -f "$ROUTING_FILE" ]] || echo '{"_meta":{"bindings":{}}}' > "$ROUTING_FILE"
    local -a ins outs
    mapfile -t ins < <(inbound_tags)
    mapfile -t outs < <(out_numbers)

    if ((${#ins[@]} == 0)); then
        print_info "未发现任何入站（conf 目录里没有 inbounds 片段）"
        return
    fi
    if ((${#outs[@]} == 0)); then
        print_info "尚无出站，请先新增"
        return
    fi

    while true; do
        echo "请选择入站：" >&2
        for i in "${!ins[@]}"; do
            printf "  %d) %s\n" $((i+1)) "${ins[$i]}" >&2
        done
        printf "  0) 退出\n" >&2
        printf "选择: " >&2
        read x
        x=$(clean_input "$x")
        [[ -z "$x" || "$x" == "0" ]] && break
        if (( x < 1 || x > ${#ins[@]} )); then print_error "无效入站"; continue; fi
        local inbound="${ins[$((x-1))]}"

        echo "请选择出站（${inbound} 将绑定到）：" >&2
        for i in "${!outs[@]}"; do
            local ot otname
            ot=$(out_tag "${outs[$i]}")
            otname=$(jq -r '._meta.name // empty' "$(out_file "${outs[$i]}")")
            printf "  %d) %s (%s)\n" $((i+1)) "$ot" "$otname" >&2
        done
        printf "  %d) 默认出站 (%s)\n" $(( ${#outs[@]}+1 )) "$DEFAULT_OUTBOUND" >&2
        printf "选择: " >&2
        read y
        y=$(clean_input "$y")
        [[ -z "$y" ]] && continue
        if (( y == ${#outs[@]}+1 )); then
            # 绑定到默认 → 移除绑定
            jq --arg k "$inbound" '._meta.bindings |= del(.[$k])' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" 2>/dev/null && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE" 2>/dev/null
            print_ok "$inbound → 默认出站($DEFAULT_OUTBOUND)"
        elif (( y >= 1 && y <= ${#outs[@]} )); then
            local ot=$(out_tag "${outs[$((y-1))]}")
            if [[ -f "$ROUTING_FILE" ]]; then
                jq --arg k "$inbound" --arg v "$ot" '._meta.bindings[$k]=$v' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
            else
                jq -n --arg k "$inbound" --arg v "$ot" '{_meta:{bindings:{($k):$v}}}' > "$ROUTING_FILE"
            fi
            print_ok "$inbound → $ot"
            # v6-only 出站警示：纯IPv6落地打不开纯IPv4网站
            if is_v6only_outbound "$(out_file "${outs[$((y-1))]}")"; then
                print_error "⚠ 警告：$ot 是纯IPv6落地（sendThrough=IPv6），纯IPv4网站（browserleaks/matrix/github等）将无法访问！"
                print_info "建议：用 split.sh 给这些站加分流规则指到 direct/v4 落地；或改用菜单7绑定默认出站(direct，双栈自动)。"
            fi
        else
            print_error "无效出站"
        fi
        write_routing
        printf "继续绑定其它入站？回车继续 / 0 结束: " >&2
        read z
        [[ "$z" == "0" ]] && break
    done
    validate_config
}

# ================================
# 查看映射
# ================================
view_mapping() {
    print_title "Inbound → Outbound"
    echo "==================================================" >&2
    printf "${BOLD}%-16s %-14s %s${RESET}\n" "入站" "出站" "类型" >&2
    echo "--------------------------------------------------" >&2
    local tag bind
    for tag in $(inbound_tags); do
        bind=$(read_bindings | grep "^${tag}=" | cut -d= -f2)
        if [[ -n "$bind" ]]; then
            local bname bproto
            bname=$(jq -r --arg t "$bind" '._meta.name // empty' "$CONF_DIR/out-$(printf "%02d" ${bind#out-}).json" 2>/dev/null || echo "$bind")
            bproto=$(jq -r '._meta.proto // "?"' "$CONF_DIR/out-$(printf "%02d" ${bind#out-}).json" 2>/dev/null || echo "?")
            printf "%-16s %-14s %s\n" "$tag" "${bname:-$bind}" "$bproto" >&2
        else
            printf "%-16s %-14s %s\n" "$tag" "默认(${DEFAULT_OUTBOUND})" "freedom" >&2
        fi
    done
    echo "--------------------------------------------------" >&2
    echo "带源IP的出站：" >&2
    local n f
    for n in $(out_numbers); do
        f=$(out_file "$n")
        local src pool
        src=$(jq -r '.outbounds[0].sendThrough // empty' "$f")
        pool=$(jq -r '._meta.pool.address // empty' "$f")
        if [[ -n "$pool" || -n "$src" ]]; then
            printf "  %s  SourceIP: %s\n" "$(out_tag "$n")" "${pool:-$src}" >&2
        fi
    done
}

# ================================
# IPv6 地址池菜单
# ================================
pool_menu() {
    while true; do
        print_title "IPv6 地址池管理"
        local cur
        cur=$(pool_prefix)
        echo "当前池前缀: ${cur:-未设置}" >&2
        echo "  1) 检测/设置前缀" >&2
        echo "  2) 查看已分配地址" >&2
        echo "  3) 分配一个新地址并写入出站" >&2
        echo "  0) 返回" >&2
        read c
        c=$(clean_input "$c")
        case "$c" in
            1)
                local detected=""
                detected=$(detect_v6_prefix) || true
                [[ -n "$detected" ]] && print_info "自动检测到 IPv6 /64: $detected（回车使用）"
                local p
                p=$(safe_read "IPv6 前缀(/64)" "${cur:-$detected}")
                [[ -n "$p" ]] && { set_pool_prefix "$p"; print_ok "前缀已设置: $p"; }
                ;;
            2)
                local n f ad
                for n in $(out_numbers); do
                    f=$(out_file "$n")
                    ad=$(jq -r '._meta.pool.address // empty' "$f")
                    [[ -n "$ad" ]] && printf "  %s → %s\n" "$(out_tag "$n")" "$ad" >&2
                done
                ;;
            3)
                local prefix addr
                prefix=$(pool_prefix) || true
                if [[ -z "$prefix" ]]; then
                    prefix=$(detect_v6_prefix) || true
                    [[ -n "$prefix" ]] && print_info "已自动检测到 IPv6 前缀: $prefix"
                fi
                [[ -z "$prefix" ]] && { print_error "未检测到 IPv6 /64，请先在选项 1 手动设置前缀"; continue; }
                addr=$(gen_v6_address "$prefix") || continue
                assign_v6 "$addr" "$prefix" || continue
                print_ok "新地址: $addr（已挂载；可在 修改出站 → 3. 重新分配IPv6 写入某出站）"
                ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        printf "按回车继续..." >&2; read
    done
}

# ================================
# 校验 / 重启
# ================================
validate_config() {
    if [[ -z "$XRAY_BIN" ]]; then
        print_error "未找到 xray 二进制，无法校验"
        return 1
    fi
    print_title "校验 Xray 配置"
    local out
    out=$("$XRAY_BIN" run -test -confdir "$CONF_DIR" 2>&1)
    if [[ "$out" == *"Configuration OK."* ]]; then
        print_ok "Configuration OK."
    else
        print_error "配置校验失败："
        echo "$out" | tail -8 >&2
    fi
}

restart_xrayls() {
    if systemctl list-unit-files 2>/dev/null | grep -qw "xrayls.service"; then
        systemctl restart xrayls
        sleep 1
        systemctl is-active --quiet xrayls && print_ok "xrayls 已重启" || print_error "xrayls 重启失败"
    elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -qw "xray.service"; then
        systemctl restart xray
        print_ok "xray 已重启"
    else
        print_error "未找到 xray 服务，请手动重启"
    fi
}

# ================================
# 落地自检：配置 / 绑定完整性 / 服务 / IPv6 出口 / MTU 一体体检
# ================================
out_tag_exists() { # $1 = 出站 tag，扫描全部片段（含 nginx.json 的 direct/block）
    local f c
    shopt -s nullglob
    for f in "$CONF_DIR"/*.json; do
        [[ "$(basename "$f")" == "${OB_PREFIX}-routing.json" ]] && continue
        c=$(jq -r --arg t "$1" '([.outbounds[]? | select(.tag==$t)] | length)' "$f" 2>/dev/null)
        [[ "$c" == "1" ]] && return 0
    done
    return 1
}

# 单个落地地址的出口/MTU 实测
diag_egress() { # $1 = 源IPv6
    local a="$1" got res
    local -a pcmd=()
    command -v ping6 >/dev/null 2>&1 && pcmd=(ping6)
    command -v ping6 >/dev/null 2>&1 || { command -v ping >/dev/null 2>&1 && pcmd=(ping -6); }

    # ICMP 源地址绑定能力探测（inetutils 版 ping6 不支持 -I，自动降级）
    if ((${#pcmd[@]} == 0)); then
        res="invalid option"
    else
        res=$("${pcmd[@]}" -c 1 -w 1 -I ::1 ::1 2>&1)
    fi
    if [[ "$res" == *"invalid option"* || "$res" == *"unrecognized"* ]]; then
        printf "  [ICMP] 本机 ping 工具不支持指定源地址，已跳过 ICMP/MTU 探测（以 HTTP/HTTPS 判定为准）\n" >&2
    else
        printf "  [ICMP] %s %s ... " "${pcmd[*]}" "$a" >&2
        res=$("${pcmd[@]}" -c 2 -w 3 -I "$a" ipv6.icanhazip.com 2>&1)
        if [[ "$res" == *"received"* && "$res" != *"0 received"* && "$res" != *"100% packet loss"* ]]; then echo "通 ✓" >&2
        else echo "不通 ✗（若 HTTP/HTTPS 均通 → 多为 ISP 过滤 ICMPv6，可忽略）" >&2; fi

        printf "  [MTU]  1200B 包: " >&2
        res=$("${pcmd[@]}" -c 2 -w 3 -s 1200 -I "$a" ipv6.icanhazip.com 2>&1)
        if [[ "$res" == *"received"* && "$res" != *"0 received"* && "$res" != *"100% packet loss"* ]]; then echo "通" >&2
        else echo "不通 ✗（隧道疑似异常）" >&2; fi
        printf "  [MTU]  1400B 包(总1448<1480): " >&2
        res=$("${pcmd[@]}" -c 2 -w 3 -s 1400 -I "$a" ipv6.icanhazip.com 2>&1)
        if [[ "$res" == *"received"* && "$res" != *"0 received"* && "$res" != *"100% packet loss"* ]]; then echo "通" >&2
        else
            echo "不通 ✗" >&2
            printf "  └─ 修复建议: %s\n" "ip -6 route replace ::/0 dev <隧道口> mtu 1280" >&2
        fi
    fi

    got=$(curl -6 --interface "$a" -s --max-time 8 http://ipv6.icanhazip.com 2>/dev/null | head -1)
    if [[ -n "$got" ]]; then
        if [[ "$(canon6 "$got")" == "$(canon6 "$a")" ]]; then printf "  [HTTP ] 通，出口=%s ✓\n" "$got" >&2
        else printf "  [HTTP ] 通，出口=%s（≠ 本地址，运营商改写/NAT）\n" "$got" >&2; fi
    else printf "  [HTTP ] 不通 ✗（已挂载但出不去 → 隧道路由或防火墙）\n" >&2; fi

    got=$(curl -6 --interface "$a" -s --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | head -1)
    if [[ -n "$got" ]]; then
        if [[ "$(canon6 "$got")" == "$(canon6 "$a")" ]]; then printf "  [HTTPS] 通，出口=%s ✓\n" "$got" >&2
        else printf "  [HTTPS] 通，出口=%s（≠ 本地址）\n" "$got" >&2; fi
    else printf "  [HTTPS] 不通 ✗（HTTP通而HTTPS不通 → 典型 PMTU 黑洞，建议压 MTU: ip -6 route replace ::/0 dev <隧道口> mtu 1280）\n" >&2; fi
}

diag_landing() {
    print_title "落地自检（配置 · 绑定 · 服务 · IPv6出口 · MTU）"
    local n f tag proto send pp vout v4got dev
    local -a nr outs ins
    local -a v6_outs=()

    # 1) 出站配置现状
    echo "[1] 出站片段:" >&2
    mapfile -t nr < <(out_numbers)
    if ((${#nr[@]} == 0)); then
        echo "    （无 out-*.json）" >&2
    else
        for n in "${nr[@]}"; do
            f=$(out_file "$n")
            tag=$(out_tag "$n")
            proto=$(jq -r '.outbounds[0].protocol // "?"' "$f")
            send=$(jq -r '.outbounds[0].sendThrough // empty' "$f")
            if [[ "$proto" == "freedom" && -n "$send" && "$send" == *":"* ]]; then
                v6_outs+=("$tag|$send")
                printf "    %s (%s) 源IPv6=%s\n" "$tag" "$proto" "$send" >&2
            else
                printf "    %s (%s) 无源IP绑定\n" "$tag" "$proto" >&2
            fi
        done
    fi

    # 2) 绑定完整性（映射指向不存在的出站 = xrayls 可能起不来）
    echo "[2] 入站→出站绑定表:" >&2
    if [[ ! -f "$ROUTING_FILE" ]]; then
        echo "    out-routing.json 不存在（尚未做任何绑定）" >&2
    elif [[ -z "$(jq -r '._meta.bindings // empty | keys[]' "$ROUTING_FILE" 2>/dev/null)" ]]; then
        echo "    绑定表为空" >&2
    else
        mapfile -t ins < <(inbound_tags)
        while IFS='=' read -r ib ob; do
            [[ -z "$ib" || -z "$ob" ]] && continue
            printf "    %s → %s" "$ib" "$ob" >&2
            if ! out_tag_exists "$ob"; then
                printf "   ★ 找不到出站 %s（xrayls -test 会失败/起不来！）\n" "$ob" >&2
            else
                echo "" >&2
            fi
            if ! [[ " ${ins[*]} " == *" $ib "* ]]; then
                print_info "    （提示）入站 $ib 在 conf 中无对应 inbounds 片段"
            fi
        done < <(jq -r '._meta.bindings | to_entries[] | "\(.key)=\(.value)"' "$ROUTING_FILE" 2>/dev/null)
    fi

    # 3) 服务状态 + 二进制
    echo "[3] 服务 / 二进制:" >&2
    printf "    xrayls 服务: " >&2
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -qw "xrayls.service"; then
        echo "$(systemctl is-active xrayls)" >&2
    elif pgrep -f "xrayls|xray " >/dev/null 2>&1; then
        echo "运行中(pgrep)" >&2
    else
        echo "未运行" >&2
    fi
    printf "    xray 二进制: %s\n" "${XRAY_BIN:-未找到}" >&2

    # 4) 全配置校验（-test）
    if [[ -n "$XRAY_BIN" ]]; then
        echo "[4] 配置校验 (run -test -confdir):" >&2
        vout=$("$XRAY_BIN" run -test -confdir "$CONF_DIR" 2>&1)
        if [[ "$vout" == *"Configuration OK."* ]]; then
            printf "    "; print_ok "Configuration OK."
        else
            print_error "    校验失败："
            echo "$vout" | tail -6 | sed 's/^/    /' >&2
        fi
    fi

    # 5) 池前缀
    pp=$(pool_prefix)
    printf "[5] IPv6 池前缀: %s\n" "${pp:-（未设置）}" >&2

    # 6) 逐落地地址实测
    if ((${#v6_outs[@]} == 0)); then
        echo "[6] 无带源IPv6 的 Freedom 出站（跳过出口实测；可在菜单 2→6→3 创建）" >&2
    else
        local o tag2 a
        for o in "${v6_outs[@]}"; do
            tag2=${o%%|*}; a=${o##*|}
            echo "[6] 落地出站 $tag2 源IPv6=$a:" >&2
            if addr_on_iface "$a"; then
                printf "    "; print_ok "已挂载到网卡"
                diag_egress "$a"
            else
                print_error "    ★ 未挂载到任何网卡！此出站必然不可用"
                printf "    └─ 修复: 菜单 3 修改出站 → 3.重新分配IPv6，或手动\n" >&2
                printf "       ip -6 addr add %s/128 dev <网卡> nodad\n" "$a" >&2
            fi
        done
    fi

    # 7) IPv4 基线（排除整机断网干扰；多端点回退，避免单个 API 误报）
    echo "[7] IPv4 出口基线:" >&2
    local v4got v4ep
    for v4ep in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
        v4got=$(curl -4 -s --max-time 8 "$v4ep" 2>/dev/null | head -1)
        [[ -n "$v4got" ]] && break
    done
    printf "    出口IPv4: %s\n" "${v4got:-无法连通（多端点全失败 → 整机 v4 网络异常，与落地IP无关，先修服务器）}" >&2

    printf "\n诊断结束：把以上输出发出来即可定位问题\n" >&2
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Xray 出站管理面板"

        echo "1) 查看出站" >&2
        echo "2) 新增出站" >&2
        echo "3) 修改出站" >&2
        echo "4) 删除出站" >&2
        echo "5) 复制出站" >&2
        echo "6) 测试出站" >&2
        echo "7) 入站→出站绑定管理" >&2
        echo "8) 查看入站→出站映射" >&2
        echo "9) 校验配置 / 重启服务" >&2
        echo "10) IPv6 地址池管理" >&2
        echo "11) 落地自检（IPv6出口/MTU/配置体检）" >&2
        echo "12) 一键更换落地 IPv6（用完即换）" >&2
        echo "13) 批量生成落地 IPv6（备用池）" >&2
        echo "14) 双栈 v4 域名名单管理" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case $c in
            1) list_outbounds ;;
            2) add_outbound ;;
            3) edit_outbound ;;
            4) delete_outbound ;;
            5) copy_outbound ;;
            6) test_outbound ;;
            7) bind_menu ;;
            8) view_mapping ;;
            9)
                print_title "校验 / 重启"
                validate_config
                printf "重启 xrayls 服务? [y/N]: " >&2
                read rr
                rr=$(clean_input "$rr")
                [[ "$rr" == "y" || "$rr" == "Y" ]] && restart_xrayls
                ;;
            10) pool_menu ;;
            11) diag_landing ;;
            12) rotate_out6 ;;
            13) gen_pool_batch ;;
            14) dual_domains ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        printf "按回车继续..." >&2
        read
    done
}

# 支持被 source 后直接调用内部函数做自动化测试
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_menu
fi