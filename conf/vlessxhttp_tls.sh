#!/bin/bash

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
# 打印函数
# ================================
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
# 依赖检查
# ================================
if ! command -v jq &>/dev/null; then
    print_error "需要安装 jq，请执行: apt install -y jq 或 yum install -y jq"
    exit 1
fi

# ================================
# 基础变量
# ================================
PROTO="vless-xhttp_tls"
PROTO_NAME="VLESS-xHTTP-MLKEM"
CONF_DIR="/root/catmi/xray/conf"
XRAYLS_BIN="/root/catmi/xray/xrayls"
CERT_BASE_DIR="/root/catmi"

# 全局 TLS / 域名变量
TLS_CERT=""
TLS_KEY=""
DOMAIN=""

mkdir -p "$CONF_DIR" "$CERT_BASE_DIR"

# ================================
# 工具函数
# ================================
random_port() { shuf -i 10000-60000 -n 1; }
random_path() { echo "/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)"; }
clean_input() { echo "$1" | tr -d '\000-\037'; }

# 优化 IPv6 端口检测：匹配行末的 :port
port_in_use() { ss -tuln | awk '{print $5}' | grep -q ":${1}$"; }

random_free_port() {
    while true; do
        port=$(random_port)
        if ! port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
}

safe_read() {
    local prompt="$1" default="$2" input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    echo "${input:-$default}"
}

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "监听端口 (1-65535, 默认: %s): " "$default" >&2
        read input
        port="${input:-$default}"
        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口 $port 已被占用"; continue; }
        echo "$port"
        return
    done
}

get_next_index() {
    local used=() i=1 f base
    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.json; do
        base=$(basename "$f")
        [[ "$base" =~ ^${PROTO}-([0-9]+)\.json$ ]] && used+=("${BASH_REMATCH[1]}")
    done
    [[ ${#used[@]} -eq 0 ]] && { printf "%02d\n" 1; return; }
    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done
    printf "%02d\n" "$i"
}

detect_listen_ip() {
    local has_ipv4=false has_ipv6=false
    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true
    if $has_ipv4 && ! $has_ipv6; then echo "ipv4"
    elif ! $has_ipv4 && $has_ipv6; then echo "ipv6"
    elif $has_ipv4 && $has_ipv6; then echo "dual"
    else echo "none"
    fi
}

choose_listen_ip() {
    local detect="$1" choice
    print_info "检测结果: $detect"
    echo "1) IPv4 (0.0.0.0)" >&2
    echo "2) IPv6 (::)" >&2
    echo "3) 本机回环 (127.0.0.1)" >&2
    printf "选择 (默认1): " >&2
    read choice
    case "$choice" in
        2) echo "::" ;;
        3) echo "127.0.0.1" ;;
        *) echo "0.0.0.0" ;;
    esac
}

get_public_ip() {
    local ipv4 ipv6 manual choice
    ipv4=$(curl -s4 --connect-timeout 3 https://api.ipify.org 2>/dev/null || true)
    ipv6=$(curl -s6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || true)

    if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
        print_error "公网 IP 检测失败，请手动输入"
        while true; do
            printf "输入服务器公网 IP: " >&2
            read manual
            [[ "$manual" =~ ^[0-9a-fA-F:.]+$ ]] || { print_error "格式无效"; continue; }
            echo "$manual"
            return
        done
    fi

    echo "选择对外 IP:" >&2
    [ -n "$ipv4" ] && echo "1) IPv4: $ipv4" >&2
    [ -n "$ipv6" ] && echo "2) IPv6: $ipv6" >&2
    echo "3) 手动输入" >&2
    while true; do
        printf "选项 (默认1): " >&2
        read choice
        case "${choice:-1}" in
            1) [ -n "$ipv4" ] && { echo "$ipv4"; return; }; print_error "IPv4 不可用";;
            2) [ -n "$ipv6" ] && { echo "$ipv6"; return; }; print_error "IPv6 不可用";;
            3) printf "输入 IP: " >&2; read manual
               [[ "$manual" =~ ^[0-9a-fA-F:.]+$ ]] && { echo "$manual"; return; }
               print_error "格式无效";;
            *) print_error "无效选项";;
        esac
    done
}

# ================================
# URL 编码函数 (用于分享链接)
# ================================
urlencode() {
    # 使用 jq 的 @uri 进行编码
    [ -z "$1" ] && return
    printf "%s" "$1" | jq -sRr @uri
}

# ================================
# ML-KEM 生成
# ================================
generate_mlkem() {
    print_info "正在生成 ML-KEM 参数..."
    if [ ! -x "$XRAYLS_BIN" ]; then
        print_error "未找到 xrayls: $XRAYLS_BIN"
        exit 1
    fi
    local output
    output=$("$XRAYLS_BIN" vlessenc 2>/dev/null || true)
    [[ -z "$output" ]] && { print_error "xrayls vlessenc 无输出"; exit 1; }
    SERVER_DEC=$(echo "$output" | grep -oP '"decryption"\s*:\s*"\K[^"]+' | tail -1)
    CLIENT_ENC=$(echo "$output" | grep -oP '"encryption"\s*:\s*"\K[^"]+' | tail -1)
    [[ -z "$SERVER_DEC" || -z "$CLIENT_ENC" ]] && { print_error "解析 ML-KEM 失败"; exit 1; }
    print_info "服务端 decryption: $SERVER_DEC"
    print_info "客户端 encryption: $CLIENT_ENC"
}

# ================================
# TLS 证书管理（无 ECH）
# ================================
ssl_dns() {
    set -e
    local choice

    echo "请选择证书申请方式："
    echo "1) 有 80/443 端口（standalone 自动申请）"
    echo "2) 无 80/443 端口（DNS 手动验证）"
    read -p "请输入选项 (1 或 2): " choice

    read -p "请输入域名: " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')

    read -p "请输入邮箱地址: " EMAIL

    TARGET_DIR="/root/catmi"
    mkdir -p "$TARGET_DIR"

    TLS_CERT=""
    TLS_KEY=""

    if [ "$choice" -eq 1 ]; then
        echo "执行自动申请（standalone）..."

        apt update
        apt install -y curl socat git cron openssl ufw
        ufw disable || true

        if ! command -v acme.sh >/dev/null 2>&1; then
            echo "安装 acme.sh..."
            curl https://get.acme.sh | sh
        fi

        export PATH="$HOME/.acme.sh:$PATH"

        acme.sh --register-account -m "$EMAIL"

        echo "申请证书（standalone 模式）..."
        if ! acme.sh --issue --standalone -d "$DOMAIN"; then
            echo "证书申请失败，清理残留..."
            acme.sh --remove -d "$DOMAIN" || true
            exit 1
        fi

        echo "安装证书..."
        acme.sh --install-cert -d "$DOMAIN" \
            --key-file       "$TARGET_DIR/${DOMAIN}.key" \
            --fullchain-file "$TARGET_DIR/${DOMAIN}.crt"

        TLS_CERT="$TARGET_DIR/${DOMAIN}.crt"
        TLS_KEY="$TARGET_DIR/${DOMAIN}.key"

        echo "创建自动续期脚本..."
        cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
acme.sh --renew -d "$DOMAIN" \
    --install-cert \
    --key-file "$TARGET_DIR/${DOMAIN}.key" \
    --fullchain-file "$TARGET_DIR/${DOMAIN}.crt"
systemctl restart xray 2>/dev/null || true
EOF
        chmod +x /root/renew_cert.sh

        (crontab -l 2>/dev/null; echo "0 0 * * * /root/renew_cert.sh >> /var/log/renew_cert.log 2>&1") | crontab -

        echo "证书已生成："
        echo "证书: $TLS_CERT"
        echo "私钥: $TLS_KEY"

    elif [ "$choice" -eq 2 ]; then
        echo "DNS 手动验证模式..."

        CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

        apt update
        apt install -y certbot openssl

        echo "请按提示在 DNS 添加 TXT 记录"
        certbot certonly --manual --preferred-challenges dns -d "$DOMAIN"

        TLS_CERT="$CERT_PATH"
        TLS_KEY="$KEY_PATH"

        (crontab -l 2>/dev/null; echo "0 0 * * * certbot renew --quiet") | crontab -

        echo "证书已生成："
        echo "证书: $TLS_CERT"
        echo "私钥: $TLS_KEY"

    else
        echo "无效选项"
        exit 1
    fi

    # 注意：变量 TLS_CERT, TLS_KEY, DOMAIN 会传递给调用者（全局作用域）
}

choose_tls_cert() {
    local CERT_FILE KEY_FILE tls_choice domain sni

    TLS_CERT=""
    TLS_KEY=""
    DOMAIN=""

    print_info "===== TLS 证书设置 ====="
    echo "1) 使用已有证书（输入路径）" >&2
    echo "2) 自动申请 / DNS 申请证书（acme.sh 或 certbot）" >&2
    echo "3) 手动粘贴证书内容" >&2
    printf "请选择 (默认1): " >&2
    read tls_choice
    tls_choice=${tls_choice:-1}

    case $tls_choice in
        1)
            printf "证书文件路径 (.crt 或 .pem): " >&2
            read CERT_FILE
            printf "密钥文件路径 (.key): " >&2
            read KEY_FILE
            if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
                print_error "证书/密钥文件不存在"
                exit 1
            fi
            printf "SNI 域名（可选）: " >&2
            read sni
            [ -n "$sni" ] && DOMAIN=$(echo "$sni" | tr '[:upper:]' '[:lower:]')
            TLS_CERT="$CERT_FILE"
            TLS_KEY="$KEY_FILE"
            ;;
        2)
            ssl_dns
            ;;
        3)
            printf "输入域名（用于文件名和 SNI）: " >&2
            read domain
            domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
            [[ -z "$domain" ]] && { print_error "域名不能为空"; exit 1; }
            DOMAIN="$domain"

            local crt_path="$CERT_BASE_DIR/${domain}.crt"
            local key_path="$CERT_BASE_DIR/${domain}.key"

            echo "📄 粘贴证书内容（Ctrl+D 结束）：" >&2
            cat > "$crt_path"
            echo "🔑 粘贴私钥内容（Ctrl+D 结束）：" >&2
            cat > "$key_path"

            chmod 600 "$crt_path" "$key_path"

            TLS_CERT="$crt_path"
            TLS_KEY="$key_path"
            ;;
        *)
            print_error "无效选择"
            exit 1
            ;;
    esac

    echo "证书路径: $TLS_CERT" >&2
    echo "密钥路径: $TLS_KEY" >&2
    [ -n "$DOMAIN" ] && echo "SNI 域名: $DOMAIN" >&2
}

# ================================
# 配置列表
# ================================
list_configs() {
    print_title "$PROTO_NAME 配置列表"
    printf "${CYAN}编号 | 监听 | 端口 | UUID | 路径 | TLS | Tag${RESET}\n" >&2
    echo "--------------------------------------------------------------------------" >&2
    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local num=$(basename "$f" .json | cut -d'-' -f2)
        if ! jq empty "$f" 2>/dev/null; then
            echo -e "${RED}[损坏] $num${RESET}" >&2
            continue
        fi
        local listen=$(jq -r '.inbounds[0].listen' "$f")
        local port=$(jq -r '.inbounds[0].port' "$f")
        local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$f")
        local path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "无"' "$f")
        local tls=$(jq -r '.inbounds[0].streamSettings.security // "无"' "$f")
        local tag=$(jq -r '.inbounds[0].tag' "$f")
        echo -e "${GREEN}$num${RESET}) ${YELLOW}$listen${RESET} | ${CYAN}$port${RESET} | ${MAGENTA}$uuid${RESET} | ${BLUE}$path${RESET} | TLS: ${WHITE}$tls${RESET} | Tag: ${WHITE}$tag${RESET}" >&2
    done
    echo "--------------------------------------------------------------------------" >&2
}

# ================================
# 新增配置（使用 jq 动态生成，安全可靠）
# ================================
add_config() {
    print_title "新增 $PROTO_NAME 配置"

    # 监听地址
    local detect=$(detect_listen_ip)
    local listen_ip=$(choose_listen_ip "$detect")

    # 端口
    local default_port=$(random_free_port)
    local lport=$(safe_read_port "$default_port")

    # 公网 IP
    local PUBLIC_IP=$(get_public_ip)
    local link_ip
    if [[ "$PUBLIC_IP" =~ : ]]; then link_ip="[$PUBLIC_IP]"; else link_ip="$PUBLIC_IP"; fi

    # UUID
    local UUID=$(cat /proc/sys/kernel/random/uuid)

    # xHTTP 路径
    local default_path=$(random_path)
    local WS_PATH=$(safe_read "请输入 xHTTP 路径" "$default_path")
    WS_PATH=$(clean_input "$WS_PATH")
    [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"

    # ML-KEM
    generate_mlkem

    # TLS 证书选择
    choose_tls_cert  # 设置 TLS_CERT, TLS_KEY, DOMAIN

    # 索引与文件名
    local next=$(get_next_index)
    local tag_name="${PROTO}${next}"
    local config_file="$CONF_DIR/$PROTO-$next.json"

    # 使用 jq 生成 JSON
    jq -n \
      --arg listen "$listen_ip" \
      --argjson port "$lport" \
      --arg tag "$tag_name" \
      --arg uuid "$UUID" \
      --arg dec "$SERVER_DEC" \
      --arg path "$WS_PATH" \
      --arg tls_cert "$TLS_CERT" \
      --arg tls_key "$TLS_KEY" \
      --arg sni "${DOMAIN:-$PUBLIC_IP}" \
      '{
        inbounds: [
          {
            listen: $listen,
            port: $port,
            tag: $tag,
            protocol: "vless",
            settings: {
              clients: [{id: $uuid}],
              decryption: $dec
            },
            streamSettings: {
              network: "xhttp",
              xhttpSettings: {
                path: $path
              }
            } +
            (if $tls_cert != "" then
              {
                security: "tls",
                tlsSettings: {
                  serverName: $sni,
                  certificates: [
                    {
                      certificateFile: $tls_cert,
                      keyFile: $tls_key
                    }
                  ]
                }
              }
            else {} end),
            sniffing: {
              enabled: true,
              destOverride: ["http", "tls", "quic"]
            }
          }
        ]
      }' > "$config_file"

    # JSON 验证
    if ! jq empty "$config_file" 2>/dev/null; then
        print_error "生成的配置 JSON 无效，请检查！"
        exit 1
    fi

    print_ok "配置已生成: $config_file"
    echo -e "编号: $next\n监听: $listen_ip:$lport\nUUID: $UUID\n路径: $WS_PATH\nTLS: ${TLS_CERT:+已启用}" >&2

    # ============================
    #   保存客户端文件（优化版）
    # ============================

    mkdir -p /root/catmi/xray/out

    # 客户端链接（URL 编码）
    local enc_path=$(urlencode "$WS_PATH")
    local enc_encryption=$(urlencode "$CLIENT_ENC")
    local params="type=xhttp&path=${enc_path}&encryption=${enc_encryption}"

    if [ -n "$TLS_CERT" ]; then
        local enc_sni=$(urlencode "${DOMAIN:-$PUBLIC_IP}")
        params+="&security=tls&sni=${enc_sni}"
    fi

    local link="vless://${UUID}@${link_ip}:${lport}?${params}#vless-xhttp-mlkem"

    # ① 保存链接（按协议分类）
    echo "[$next] $link" >> /root/catmi/xray/out/${PROTO}.txt

    # ② 保存 YAML（按协议分类）
cat >> /root/catmi/xray/out/${PROTO}.yaml <<EOF

# [$next] vless-xhttp-mlkem-$next
- name: vless-xhttp-mlkem-$next
  type: vless
  server: $PUBLIC_IP
  port: $lport
  uuid: $UUID
  encryption: $CLIENT_ENC
  network: xhttp
  xhttp-opts:
    path: $WS_PATH
  tls: ${TLS_CERT:+true}
  ${TLS_CERT:+sni: ${DOMAIN:-$PUBLIC_IP}}
EOF

    # ============================
    #   控制台输出
    # ============================

    echo >&2
    print_info "=== 客户端分享链接 ==="
    echo "$link" >&2

    echo >&2
    print_info "=== YAML 客户端示例 ==="
    cat >&2 <<EOF
- name: vless-xhttp-mlkem-$next
  type: vless
  server: $PUBLIC_IP
  port: $lport
  uuid: $UUID
  encryption: $CLIENT_ENC
  network: xhttp
  xhttp-opts:
    path: $WS_PATH
  tls: ${TLS_CERT:+true}
  ${TLS_CERT:+sni: ${DOMAIN:-$PUBLIC_IP}}
EOF
}


# ================================
# 删除配置
# ================================
delete_config() {
    list_configs
    printf "要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    local num_fmt=$(printf "%02d" "$num")
    local file="$CONF_DIR/$PROTO-$num_fmt.json"
    if [ -f "$file" ]; then
        rm -f "$file"
        print_ok "已删除编号 $num_fmt"
    else
        print_error "编号 $num_fmt 不存在"
    fi
}

# ================================
# 主菜单
# ================================
config_menu() {
    while true; do
        print_title "$PROTO_NAME 配置管理"
        echo "1) 查看所有配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "0) 退出" >&2
        printf "请选择: " >&2
        read c
        case $(clean_input "$c") in
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

# ================================
# 程序入口
# ================================
config_menu
