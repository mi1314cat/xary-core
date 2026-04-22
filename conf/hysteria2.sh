#!/bin/bash

set -euo pipefail

# ================================
# 颜色
# ================================
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"
BLUE="\e[34m"; MAGENTA="\e[35m"; CYAN="\e[36m"
BOLD="\e[1m"; RESET="\e[0m"

log() { echo -e "$1" >&2; }
info() { log "${CYAN}[Info]${RESET} $1"; }
ok() { log "${GREEN}[OK]${RESET}  $1"; }
err() { log "${RED}[Error]${RESET} $1"; }

title() {
    log "${MAGENTA}${BOLD}╔══════════════════════════════════════╗"
    log "║ $1"
    log "╚══════════════════════════════════════╝${RESET}"
}

# ================================
# 路径
# ================================
BASE="/root/catmi/xray"
CONF="$BASE/conf"
mkdir -p "$CONF"

# ================================
# UUID（无依赖）
# ================================
uuid() {
    cat /proc/sys/kernel/random/uuid
}

# ================================
# 域名策略
# ================================
domain() {
    ((RANDOM%2)) && echo "cloudflare.com" || echo "bing.com"
}

# ================================
# 端口检测
# ================================
port_used() {
    ss -tuln 2>/dev/null | grep -q ":$1 "
}

ask_port() {
    local d="$1" p
    while true; do
        read -r -p "端口 (默认 $d): " p >&2
        p=${p:-$d}
        [[ $p =~ ^[0-9]+$ ]] || { err "必须数字"; continue; }
        ((p>=1 && p<=65535)) || { err "范围错误"; continue; }
        port_used "$p" && { err "占用"; continue; }
        echo "$p"; return
    done
}

# ================================
# IP 检测（无污染）
# ================================
listen_ip() {
    local has4=false has6=false

    ip -4 addr show scope global | grep -q inet && has4=true
    ip -6 addr show scope global | grep -q inet6 && has6=true

    {
        info "检测到："
        $has4 && echo "  IPv4"
        $has6 && echo "  IPv6"
        echo "1 IPv4"
        echo "2 IPv6"
        echo "3 自动"
    } >&2

    read -r -p "选择(默认1): " c >&2
    c=${c:-1}

    case $c in
        2) echo "::" ;;
        3)
            $has4 && ! $has6 && echo "0.0.0.0" || \
            ! $has4 && $has6 && echo "::" || \
            echo "0.0.0.0"
        ;;
        *) echo "0.0.0.0" ;;
    esac
}

# ================================
# 证书
# ================================
gen_cert() {
    local d="$1"
    CRT="$BASE/$d.crt"
    KEY="$BASE/$d.key"

    [[ -f $CRT && -f $KEY ]] && return

    info "生成证书: $d"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY" -out "$CRT" \
        -days 365 -subj "/CN=$d" >/dev/null 2>&1

    ok "证书OK"
}


# ================================
# 新增
# ================================
add() {
    title "新增"

    local ip default_ip port uid d file lip

    default_ip=$(curl -4 -s ip.sb || hostname -I | awk '{print $1}')
    read -r -p "服务器IP($default_ip): " ip >&2
    ip=${ip:-$default_ip}

    lip=$(listen_ip)

    port=$(ask_port $((RANDOM%20000+20000)))
    uid=$(uuid)
    d=$(domain)

    gen_cert "$d"

    file="$CONF/hy2-$(date +%s).json"

cat > "$file" <<EOF
{
  "inbounds":[
    {
      "listen":"$lip",
      "port":$port,
      "protocol":"hysteria",
      "settings":{
        "version":2,
        "clients":[{"auth":"$uid"}]
      },
      "streamSettings":{
        "network":"hysteria",
        "security":"tls",
        "tlsSettings":{
          "alpn":["h3"],
          "certificates":[
            {
              "certificateFile":"$BASE/$d.crt",
              "keyFile":"$BASE/$d.key",
              "domain":"$d"
            }
          ]
        }
      }
    }
  ]
}
EOF

    jq empty "$file" || { err "JSON错误"; rm -f "$file"; return; }

    link="hysteria2://$uid@$ip:$port?sni=$d&insecure=1#hy2"

    ok "完成"
    echo -e "\n$link\n"

    
}

# ================================
# 列表
# ================================
list() {
    title "列表"
    for f in "$CONF"/*.json; do
        [[ -f $f ]] || continue
        jq empty "$f" 2>/dev/null || continue

        p=$(jq -r '.inbounds[0].port' "$f")
        u=$(jq -r '.inbounds[0].settings.clients[0].auth' "$f")
        d=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].domain' "$f")

        echo "$p | $u | $d"
    done
}

# ================================
# 删除
# ================================
del() {
    list
    read -r -p "输入端口删除: " p >&2

    for f in "$CONF"/*.json; do
        jq -e ".inbounds[0].port==$p" "$f" >/dev/null 2>&1 || continue

        d=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].domain' "$f")
        rm -f "$f" "$BASE/$d.crt" "$BASE/$d.key"

        ok "已删"
        
        return
    done

    err "没找到"
}

# ================================
# 菜单
# ================================
while true; do
    title "Hysteria2"

    echo "1 新增"
    echo "2 查看"
    echo "3 删除"
    echo "0 退出"

    read -r -p "选择: " c

    case $c in
        1) add ;;
        2) list ;;
        3) del ;;
        0) exit ;;
    esac

    read -r -p "回车继续..."
done
