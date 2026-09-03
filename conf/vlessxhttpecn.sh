#!/bin/bash

# ================================
# VLESS-XHTTP/WS + ECH + ML-KEM 管理脚本 (Xray 内核版)
# 特性: WS/XHTTP 二选一 | CDN直连/Nginx转发二选一 | ECH (CDN-ECH 或 直连原生) | ML-KEM PQ
# 服务端: 生成独立 json -> include 合并入 xrayls config.json
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
PROTO="vless-xhttp"                     # 用于文件名/tag
PROTO_NAME="VLESS-XHTTP/WS-ECH-MLKEM"
CONF_DIR="/root/catmi/xray/conf"
OUT_DIR="/root/catmi/xray/out"
MAIN_CONF="/root/catmi/xray/config.json"
XRAYLS_BIN="/root/catmi/xray/xrayls"

mkdir -p "$CONF_DIR" "$OUT_DIR"

# ================================
# 随机生成函数
# ================================
random_port() { shuf -i 10000-60000 -n 1; }
random_path() { echo "/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)"; }

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

# ================================
# URL 编码 (分享链接 ech= 参数用)
# ================================
urlencode() {
    local s="$1" i c out=""
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9_.~-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
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
    local input port

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
# 获取下一个可用编号
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
# IPv4 / IPv6 自动检测
# ================================
detect_listen_ip() {
    local has_ipv4=false
    local has_ipv6=false

    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true

    if $has_ipv4 && ! $has_ipv6; then echo "ipv4"
    elif ! $has_ipv4 && $has_ipv6; then echo "ipv6"
    elif $has_ipv4 && $has_ipv6; then echo "dual"
    else echo "none"
    fi
}

# ================================
# ML-KEM-768 (VLESS Encryption, PQ 后量子) 生成
# ================================
generate_mlkem() {
    print_info "正在生成 ML-KEM-768（后量子加密 PQ）参数..."

    if [ ! -x "$XRAYLS_BIN" ]; then
        print_error "未找到 xrayls 可执行文件：$XRAYLS_BIN"
        return 1
    fi

    VLESSENC_OUTPUT=$("$XRAYLS_BIN" vlessenc 2>/dev/null || true)

    if [ -z "$VLESSENC_OUTPUT" ]; then
        print_error "xrayls vlessenc 无输出，无法生成 ML-KEM PQ 加密串"
        return 1
    fi

    CLEAN_OUTPUT=$(echo "$VLESSENC_OUTPUT" | tr '\n' ' ')

    # 取 ML-KEM-768 (Post-Quantum) 那组 (最后一组 decryption/encryption)
    SERVER_DEC=$(echo "$CLEAN_OUTPUT" | grep -oP '"decryption"\s*:\s*"\K[^"]+' | tail -n 1)
    CLIENT_ENC=$(echo "$CLEAN_OUTPUT" | grep -oP '"encryption"\s*:\s*"\K[^"]+' | tail -n 1)

    if [[ -z "$SERVER_DEC" || -z "$CLIENT_ENC" ]]; then
        print_error "无法解析 ML-KEM-768 加密串"
        return 1
    fi

    print_info "ML-KEM 服务端 decryption: ${SERVER_DEC:0:40}..."
    print_info "ML-KEM 客户端 encryption: ${CLIENT_ENC:0:40}..."
}

# ================================
# ECH 生成 (Xray 原生, 仅直连 ECH 模式需要)
# 输入: ECH_DOMAIN (生成的 ECHConfigs 里的 serverName)
# 输出: ECH_SERVER_KEYS (服务端 tlsSettings.echServerKeys)
#       ECH_CONFIG_LIST (客户端可 pin 的 ECHConfigList, 也可不配自动发现)
# ================================
generate_ech() {
    local domain="$1"
    ECH_SERVER_KEYS=""
    ECH_CONFIG_LIST=""

    print_info "正在生成 ECH (Encrypted Client Hello) 密钥对..."

    local out
    out=$("$XRAYLS_BIN" tls ech --serverName "$domain" 2>/dev/null || true)

    ECH_CONFIG_LIST=$(echo "$out" | grep -A1 "ECH config list:" | tail -1 | tr -d ' ')
    ECH_SERVER_KEYS=$(echo "$out" | grep -A1 "ECH server keys:" | tail -1 | tr -d ' ')

    if [[ -z "$ECH_SERVER_KEYS" || -z "$ECH_CONFIG_LIST" ]]; then
        print_error "xray tls ech 输出解析失败"
        return 1
    fi

    print_ok "ECH 密钥生成成功 (serverName: $domain)"
}

# ================================
# 证书选择
# 输出: CERT_FILE (PEM路径), KEY_FILE, CERT_DOMAIN (证书序列号/域名)
# ================================
ask_cert() {
    CERT_FILE=""
    KEY_FILE=""
    CERT_DOMAIN=""

    local found=() i=1 choice
    shopt -s nullglob
    for f in /root/catmi/*.crt; do
        [[ -f "$f" ]] && found+=("$f")
    done

    if ((${#found[@]} > 0)); then
        echo "  检测到已有证书:" >&2
        for f in "${found[@]}"; do
            local dom
            dom=$(basename "$f" .crt | sed 's/cert-//')
            # 检查同名 key 是否存在
            local key="${f%.crt}.key"
            if [[ -f "$key" ]]; then
                echo "    $i) $dom (有密钥)" >&2
            else
                echo "    $i) $dom (无密钥, 忽略)" >&2
            fi
            found[$((i-1))]="${f}|${key}"
            ((i++))
        done
        echo "    $i) 生成新证书" >&2
        printf "  选择证书 (默认 $i): " >&2
        read -r choice
        choice=$(clean_input "$choice")

        if [[ -n "$choice" ]] && [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
            local pair="${found[$((choice-1))]}"
            local crt="${pair%%|*}"
            local key="${pair##*|}"
            if [[ -f "$crt" && -f "$key" ]]; then
                CERT_FILE="$crt"
                KEY_FILE="$key"
                CERT_DOMAIN=$(basename "$crt" .crt | sed 's/cert-//')
                print_ok "使用证书: $CERT_DOMAIN"
                return 0
            fi
        fi
    fi

    generate_cert
}

# ================================
# 生成自签证书 (当无可用证书时)
# ================================
generate_cert() {
    print_info "生成自签证书..."
    local dom
    dom=$(safe_read "证书域名" "cloudflare.com")

    CERT_DOMAIN="$dom"
    CERT_FILE="/root/catmi/cert-$dom.crt"
    KEY_FILE="/root/catmi/cert-$dom.key"

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_ok "已有证书: $dom"
        return 0
    fi

    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY_FILE" -out "$CERT_FILE" \
        -days 3650 -subj "/CN=$dom" >/dev/null 2>&1

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_ok "自签证书已生成: $dom (有效期 10 年)"
    else
        print_error "证书生成失败"
        exit 1
    fi
}

# ================================
# 特性询问: 传输 / 接入 / ECH 形态
# ================================
ask_features() {
    local yn
    VLESS_TRANSPORT=""        # ws | xhttp
    ACCESS_MODE="cdn"         # cdn(0.0.0.0) | nginx(127.0.0.1)
    ECH_MODE="cdn"            # cdn(Cloudflare ECH) | direct(xray 原生 ECH)
    MLKEM_ENABLED=true

    echo "  传输方式 (二选一):" >&2
    echo "  1) WS (WebSocket, CDN 最兼容, 推荐)" >&2
    echo "  2) XHTTP (XHTTP+CDN, 抗识别更强)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) VLESS_TRANSPORT="xhttp" ;;
        *) VLESS_TRANSPORT="ws" ;;
    esac

    echo "  接入方式:" >&2
    echo "  1) CDN 直连 (监听 0.0.0.0, Cloudflare 回源到端口, 最直接)" >&2
    echo "  2) Nginx 转发 (监听 127.0.0.1, 走 nginx 路径匹配统一入口)" >&2
    printf "  选择 (默认1): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        2) ACCESS_MODE="nginx" ;;
        *) ACCESS_MODE="cdn" ;;
    esac

    printf "启用 ML-KEM-768 后量子加密 (vlessenc)? (Y/n): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        n|N) MLKEM_ENABLED=false ;;
        *) MLKEM_ENABLED=true ;;
    esac

    if [[ "$ACCESS_MODE" = "cdn" ]]; then
        echo "  ECH 形态:" >&2
        echo "  1) CDN-ECH (Cloudflare 边缘处理 ECH, 无需服务器密钥, 推荐)" >&2
        echo "  2) 直连 ECH (Xray 原生 echServerKeys, 需 TLS1.3)" >&2
        printf "  选择 (默认1): " >&2
        read -r yn
        case "$(clean_input "$yn")" in
            2) ECH_MODE="direct" ;;
            *) ECH_MODE="cdn" ;;
        esac
    else
        # Nginx 模式 = 走 CDN 到 nginx -> TLS 回源 -> xray
        # ECH 由 Cloudflare 边缘处理 (CDN-ECH) 或 xray 原生 (直连 ECH, nginx 透明透传 TLS)
        echo "  ECH 形态:" >&2
        echo "  1) CDN-ECH (Cloudflare 边缘处理 ECH, 推荐)" >&2
        echo "  2) 直连 ECH (Xray 原生 echServerKeys, nginx 透传 TLS)" >&2
        printf "  选择 (默认1): " >&2
        read -r yn
        case "$(clean_input "$yn")" in
            2) ECH_MODE="direct" ;;
            *) ECH_MODE="cdn" ;;
        esac
    fi
}

# ================================
# 渲染 Nginx location 转发片段 (两种接入方式都生成, 存文件供复制)
# ================================
render_nginx_conf() {
    local path idx
    idx="${index:-$num2}"
    NGINX_FILE="$OUT_DIR/${PROTO}_nginx-$idx.conf"
    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
        path="$XHTTP_PATH"
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (XHTTP, 端口 $VLESS_PORT)
# 放入 nginx conf.d 站点 server{} 块内即可 (回源走 TLS)
location $path {
    proxy_ssl_server_name on;
    proxy_pass https://127.0.0.1:$VLESS_PORT;
    proxy_http_version 1.1;
}
EOF
    else
        path="$WS_PATH"
        cat > "$NGINX_FILE" <<EOF
# ${PROTO}-$idx (WS, 端口 $VLESS_PORT)
# 放入 nginx conf.d 站点 server{} 块内即可 (回源走 TLS + WebSocket 升级)
location $path {
    proxy_ssl_server_name on;                 # 回源时 TLS SNI
    proxy_pass https://127.0.0.1:$VLESS_PORT; # https:// -> nginx 做 TLS 回源
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;      # WebSocket 升级 (map.conf 已备)
    proxy_set_header Connection \$connection_upgrade;
}
EOF
    fi
    print_ok "Nginx 转发片段: $NGINX_FILE"
    echo -e "${CYAN}  ----- Nginx 配置片段 -----${RESET}" >&2
    cat "$NGINX_FILE" >&2
}

# ================================
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 ${PROTO_NAME} 配置列表"

    local found=false
    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        found=true

        num=$(basename "$f" .json | sed "s/^$PROTO-//")
        lport=$(jq -r '.inbounds[0].port' "$f")
        listen=$(jq -r '.inbounds[0].listen' "$f")
        tag=$(jq -r '.inbounds[0].tag' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$f")

        # transport 判断
        net=$(jq -r '.inbounds[0].streamSettings.network' "$f")
        if [[ "$net" = "xhttp" ]]; then
            path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$f")
        else
            path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$f")
        fi
        # ECH 判断 (echServerKeys 存在 = 直连 ECH)
        ech=$(jq -r 'if .inbounds[0].streamSettings.tlsSettings.echServerKeys then "直连ECH" else "CDN-ECH" end' "$f" 2>/dev/null)
        [[ "$ech" = "null" ]] && ech="CDN-ECH"

        echo -e "${GREEN}$num${RESET}) ${YELLOW}$listen${RESET}:${CYAN}$lport${RESET} | ${MAGENTA}$uuid${RESET} | ${BLUE}$net $path${RESET} | $ech | Tag: ${WHITE}$tag${RESET}" >&2
    done

    if ! $found; then
        print_warn "暂无 ${PROTO_NAME} 配置"
    fi
}

# ================================
# 新增配置
# ================================
add_config() {
    print_title "新增 ${PROTO_NAME} 配置"

    # 1. 传输/接入/ECH 询问
    ask_features

    # 2. 端口
    default_port=$(random_free_port)
    VLESS_PORT=$(safe_read_port "$default_port")

    # 3. 公网 IP (分享链接用)
    PUBLIC_IP_V4=$(curl -s4 https://api.ipify.org || true)
    PUBLIC_IP_V6=$(curl -s6 https://api64.ipify.org || true)

    if [ -z "$PUBLIC_IP_V4" ] && [ -z "$PUBLIC_IP_V6" ]; then
        print_error "无法检测公网 IP（IPv4/IPv6），请检查网络或手动填写"
        exit 1
    fi
    PUBLIC_IP="${PUBLIC_IP_V4:-$PUBLIC_IP_V6}"
    if [[ "$PUBLIC_IP" =~ : ]]; then
        link_ip="[$PUBLIC_IP]"
    else
        link_ip="$PUBLIC_IP"
    fi

    # 4. UUID + 路径
    UUID=$(cat /proc/sys/kernel/random/uuid)
    next=$(get_next_index)
    index="$next"

    # 路径默认随机, 避免与其他协议/节点路径冲突 (nginx 按路径路由)
    default_path=$(random_path)
    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
        XHTTP_PATH=$(safe_read "请输入 XHTTP 路径 (带尾斜杠)" "$default_path")
        XHTTP_PATH=$(clean_input "$XHTTP_PATH")
        [[ "$XHTTP_PATH" != /* ]] && XHTTP_PATH="/$XHTTP_PATH"
        [[ "$XHTTP_PATH" != */ ]] && XHTTP_PATH="$XHTTP_PATH/"
        XHTTP_MODE="auto"
        WS_PATH=""
        print_info "XHTTP 路径: $XHTTP_PATH (mode: auto)"
    else
        WS_PATH=$(safe_read "请输入 WS 路径" "$default_path")
        WS_PATH=$(clean_input "$WS_PATH")
        [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"
        XHTTP_PATH=""
        print_info "WS 路径: $WS_PATH"
    fi

    # 5. ML-KEM PQ 加密 (可选)
    SERVER_DEC="none"
    CLIENT_ENC=""
    if $MLKEM_ENABLED; then
        if ! generate_mlkem; then
            print_warn "ML-KEM 生成失败, 降级为无加密"
            SERVER_DEC="none"
            CLIENT_ENC=""
        fi
    else
        print_info "ML-KEM 已关闭 (decryption: none, 兼容所有 vless 客户端)"
    fi

    # 6. 证书
    ask_cert

    # 7. ECH
    ECH_SERVER_KEYS=""
    ECH_CONFIG_LIST=""
    if [[ "$ECH_MODE" = "direct" ]]; then
        if ! generate_ech "$CERT_DOMAIN"; then
            print_warn "ECH 生成失败, 继续但不启用服务端 ECH"
        fi
    fi

    # 8. 监听地址
    LISTEN_ADDR="0.0.0.0"
    [[ "$ACCESS_MODE" = "nginx" ]] && LISTEN_ADDR="127.0.0.1"

    # 9. 写入服务端 json (独立文件, include 合并)
    file="$CONF_DIR/$PROTO-$next.json"
    tag_name="${PROTO}${next}"

    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "$LISTEN_ADDR",
      "port": $VLESS_PORT,
      "tag": "$tag_name",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "$SERVER_DEC"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$CERT_FILE",
              "keyFile": "$KEY_FILE"
            }
          ],
          "minVersion": "1.3",
          "echServerKeys": "$ECH_SERVER_KEYS"
        },
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "mode": "$XHTTP_MODE"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ]
}
EOF
    else
cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "$LISTEN_ADDR",
      "port": $VLESS_PORT,
      "tag": "$tag_name",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "$SERVER_DEC"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$CERT_FILE",
              "keyFile": "$KEY_FILE"
            }
          ],
          "minVersion": "1.3",
          "echServerKeys": "$ECH_SERVER_KEYS"
        },
        "wsSettings": {
          "path": "$WS_PATH"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ]
}
EOF
    fi

    # 清除空 echServerKeys (CDN-ECH 模式) + 持久化客户端 ML-KEM encryption (重建用)
    python3 - "$file" "$CLIENT_ENC" <<'PY'
import json, sys
p, enc = sys.argv[1], sys.argv[2]
d = json.load(open(p))
ts = d["inbounds"][0]["streamSettings"]["tlsSettings"]
# 仅清除空值 (CDN-ECH 模式); direct-ECH 模式的 echServerKeys 必须保留
if not ts.get("echServerKeys"):
    ts.pop("echServerKeys", None)
if enc:
    d["_clientEncryption"] = enc
elif "_clientEncryption" in d:
    del d["_clientEncryption"]
json.dump(d, open(p, "w"), indent=2)
PY

    # 10. 确保 include 存在
    ensure_include

    # 11. 渲染客户端 + nginx
    render_client
    render_nginx_conf

    print_ok "VLESS 配置生成成功"
    echo -e "编号: $next\n传输: $VLESS_TRANSPORT\n接入: $ACCESS_MODE\nECH: $ECH_MODE\n监听: $LISTEN_ADDR:$VLESS_PORT\nUUID: $UUID\nTag: $tag_name" >&2
    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
        echo "XHTTP 路径: $XHTTP_PATH (mode: $XHTTP_MODE)" >&2
    else
        echo "WS 路径: $WS_PATH" >&2
    fi
    echo >&2

    # 12. 提示重启
    print_warn "请重启 xrayls 使配置生效: systemctl restart xrayls"
}

# ================================
# 确保 config.json 含 include 指向 conf 目录
# ================================
ensure_include() {
    python3 - "$MAIN_CONF" "$CONF_DIR" <<'PY'
import json, sys, os
p, cdir = sys.argv[1], sys.argv[2]
d = json.load(open(p))
pattern = os.path.join(cdir, "vless-xhttp-*.json")
inc = d.get("include", [])
if isinstance(inc, str):
    inc = [inc]
if pattern not in inc:
    inc.append(pattern)
    d["include"] = inc
json.dump(d, open(p, "w"), indent=2)
print(f"[OK] include 已确保: {pattern}")
PY
}

# ================================
# 渲染客户端 YAML + 分享链接
# ================================
render_client() {
    local num2="${index:-$num2}"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.yaml"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    # 客户端连接目标:
    #   CDN-ECH 模式 (ECH_MODE=cdn):   连 CDN:443 (域名), TLS 终止于 Cloudflare, 自动发现 CF 的 ECH
    #   direct-ECH 模式 (ECH_MODE=direct): 连 xray 服务器自身端口 (直连, TLS 终止于 xray, echServerKeys 生效)
    CLIENT_SNI="$CERT_DOMAIN"
    if [[ "$ECH_MODE" = "direct" ]]; then
        # direct ECH = 必须直连 xray 端口 (TLS 终止于 xray), 否则 pin 的 ECHConfig 会被 CF 拒绝
        # 优先 IPv4, 无则 IPv6 (IPv6 加方括号)
        if [[ -n "$PUBLIC_IP_V4" ]]; then
            LINK_HOST="$PUBLIC_IP_V4"
        elif [[ -n "$PUBLIC_IP_V6" ]]; then
            LINK_HOST="[$PUBLIC_IP_V6]"
        else
            LINK_HOST="$CERT_DOMAIN"
        fi
        LINK_PORT="$VLESS_PORT"
    else
        # CDN-ECH = 连 CDN:443, 自动发现
        LINK_HOST="$CERT_DOMAIN"
        LINK_PORT="443"
    fi

    local ech_block=""
    local ech_comment=""
    if [[ "$ECH_MODE" = "direct" ]]; then
        # 目标客户端为 mihomo: ech-opts.config 填入标准 ECHConfigList (跨核心通用)
        # 若使用 Xray/v2ray 客户端, 请改用同值的 echConfigList 字段
        ech_comment="# ECH: 直连 Xray ECH (pin 标准 ECHConfigList). 直连服务器端口, TLS 终止于 Xray"
        ech_block="    ech-opts:
      enable: true
      config: $ECH_CONFIG_LIST"
    else
        ech_comment="# ECH: Cloudflare 边缘处理 (CDN-ECH), 客户端自动 HTTPS 发现"
        ech_block="    ech-opts:
      enable: true"
    fi

    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
        network_block="    network: xhttp
    xhttp-opts:
      mode: $XHTTP_MODE
      path: $XHTTP_PATH"
        linktype="type=xhttp&mode=$XHTTP_MODE&path=$XHTTP_PATH"
    else
        network_block="    network: ws
    ws-opts:
      path: $WS_PATH
      headers:
        Host: $CERT_DOMAIN"
        linktype="type=ws&path=$WS_PATH&host=$CERT_DOMAIN"
    fi

    cat > "$OUT_FILE" <<EOF
# $PROTO_NAME #$num2 ($VLESS_TRANSPORT, $ECH_MODE)
$ech_comment
proxies:
  - name: $PROTO-$num2
    type: vless
    server: $LINK_HOST
    port: $LINK_PORT
    uuid: $UUID
    encryption: ${CLIENT_ENC:-none}
    udp: true
    tls: true
    sni: $CLIENT_SNI
    skip-cert-verify: true
$network_block
EOF

    if [[ -n "$ech_block" ]]; then
        printf "%b\n" "$ech_block" >> "$OUT_FILE"
    fi

    # 分享链接 ech= 参数: cdn 用 DNS 查询形式, direct 用 pin 的 ECHConfigList
    local ech_param=""
    if [[ "$ECH_MODE" = "direct" && -n "$ECH_CONFIG_LIST" ]]; then
        ech_param="&ech=$(urlencode "$ECH_CONFIG_LIST")"
    elif [[ "$ECH_MODE" = "cdn" ]]; then
        ech_param="&ech=$(urlencode "cloudflare-ech.com+https://dns.alidns.com/dns-query")"
    fi
    echo "vless://${UUID}@${LINK_HOST}:${LINK_PORT}?encryption=${CLIENT_ENC:-none}&security=tls&sni=${CLIENT_SNI}&type=$([ "$VLESS_TRANSPORT" = "xhttp" ] && echo xhttp || echo ws)&path=$([ "$VLESS_TRANSPORT" = "xhttp" ] && echo "$XHTTP_PATH" || echo "$WS_PATH")${ech_param}#${PROTO}-${num2}" > "$SHARE_FILE"

    print_ok "客户端 YAML: $OUT_FILE"
    print_ok "分享链接: $SHARE_FILE"
}

# ================================
# 重建所有客户端文件 (适配 conflicts)
# ================================
rebuild_client() {
    print_title "重建客户端文件"

    local f num2
    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        num2=$(basename "$f" .json | sed "s/^$PROTO-//")
        rebuild_one "$num2"
    done
}

rebuild_one() {
    local num2="$1"
    local file="$CONF_DIR/$PROTO-$num2.json"

    [[ -f "$file" ]] || return 0

    VLESS_PORT=$(jq -r '.inbounds[0].port' "$file")
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$file")
    VLESS_TRANSPORT=$(jq -r '.inbounds[0].streamSettings.network' "$file")
    CERT_FILE=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$file")
    KEY_FILE=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].keyFile' "$file")
    CERT_DOMAIN=$(basename "$CERT_FILE" .crt | sed 's/cert-//')
    CLIENT_ENC=$(grep -oP '"decryption"\s*:\s*"\K[^"]+' "$file" | head -1)
    CLIENT_ENC=""
    ECH_SERVER_KEYS=$(jq -r '.inbounds[0].streamSettings.tlsSettings.echServerKeys // ""' "$file")

    if [[ "$VLESS_TRANSPORT" = "xhttp" ]]; then
        XHTTP_PATH=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$file")
        XHTTP_MODE=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.mode // "auto"' "$file")
    else
        WS_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$file")
    fi

    ECH_MODE="cdn"
    [[ -n "$ECH_SERVER_KEYS" ]] && ECH_MODE="direct"

    ECH_CONFIG_LIST=""
    if [[ "$ECH_MODE" = "direct" ]]; then
        # 从 server keys 还原 ECHConfigList
        ECH_CONFIG_LIST=$("$XRAYLS_BIN" tls ech -i "$ECH_SERVER_KEYS" 2>/dev/null | grep -A1 "ECH config list:" | tail -1 | tr -d ' ')
    fi

    # ML-KEM: 客户端 encryption 从 json 的 _clientEncryption 字段读 (生成时保存)
    CLIENT_ENC=$(jq -r '._clientEncryption // ""' "$file")
    [[ -n "$CLIENT_ENC" ]] && print_info "ML-KEM 客户端串已恢复" || print_info "无 ML-KEM (decryption none)"

    index="$num2"
    render_client
    render_nginx_conf
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
        rm -f "$OUT_DIR/${PROTO}_client-$num_fmt.yaml" "$OUT_DIR/${PROTO}_share-$num_fmt.txt" "$OUT_DIR/${PROTO}_nginx-$num_fmt.conf" 2>/dev/null
        print_ok "已删除编号 $num_fmt 的 ${PROTO_NAME} 配置"
        print_warn "请重启 xrayls: systemctl restart xrayls"
    else
        print_error "编号 $num_fmt 不存在"
    fi
}

# ================================
# 查看 Nginx 转发配置
# ================================
view_nginx_conf() {
    print_title "Nginx 转发配置"

    local found=false
    local f
    for f in "$OUT_DIR"/${PROTO}_nginx-*.conf; do
        [[ -f "$f" ]] || continue
        found=true
        echo -e "\n${CYAN}===== $(basename "$f") =====${RESET}" >&2
        cat "$f" >&2
    done

    if ! $found; then
        print_warn "暂无生成的 Nginx 配置片段 (请先新增配置)"
    fi
    echo -e "\n${YELLOW}提示: 将片段放入 nginx conf.d 里站点配置的 server{} 块中即可${RESET}" >&2
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
        echo "4) 重建客户端文件" >&2
        echo "5) 查看 Nginx 转发配置" >&2
        echo "6) 校验配置并重启 xrayls" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case $c in
            1)
                list_configs
            ;;
            2)
                add_config
            ;;
            3)
                delete_config
            ;;
            4)
                rebuild_client
            ;;
            5)
                view_nginx_conf
            ;;
            6)
                if "$XRAYLS_BIN" run -test -config "$MAIN_CONF" >/dev/null 2>&1; then
                    print_ok "配置校验通过"
                    systemctl restart xrayls
                    sleep 1
                    print_ok "xrayls 已重启"
                else
                    print_error "配置校验失败:"
                    "$XRAYLS_BIN" run -test -config "$MAIN_CONF" 2>&1 | tail -5 >&2
                fi
            ;;
            0)
                return
            ;;
            *)
                print_error "无效选项"
            ;;
        esac

        printf "按回车继续..." >&2
        read
    done
}
config_menu

