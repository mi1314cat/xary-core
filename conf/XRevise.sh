INSTALL_DIR="/root/catmi/xray"
ENV_FILE="$INSTALL_DIR/install_info.env"

update_env() {
    local key="$1"
    local value="$2"

    # key 必须是合法的 env 变量名
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "Invalid key: $key"
        return 1
    }

    # 转义 value 中的双引号
    value="${value//\"/\\\"}"

    [ -f "$ENV_FILE" ] || touch "$ENV_FILE"

    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$ENV_FILE"
    else
        echo "${key}=\"${value}\"" >> "$ENV_FILE"
    fi
}
# 随机生成 WS 路径（更安全、更兼容）
generate_ws_path() {
    echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
}


# 随机生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

usid() {
# 生成短 id
short_id=$(openssl rand -hex 4)



# 生成端口与路径

WS_PATH1=$(generate_ws_path)
WS_PATH=$(generate_ws_path)
WS_PATH2=$(generate_ws_path)
UUID=$(generate_uuid)
UUID2=$(generate_uuid)

print_info "UUID: $UUID"
print_info "UUID2: $UUID2"
print_info "WS_PATH1: $WS_PATH1"
print_info "WS_PATH: $WS_PATH"
print_info "WS_PATH2: $WS_PATH2"
print_info "short_id: $short_id"

# 获取公网 IP 地址（容错）
PUBLIC_IP_V4=$(curl -s4 https://api.ipify.org || true)
PUBLIC_IP_V6=$(curl -s6 https://api64.ipify.org || true)

if [ -z "$PUBLIC_IP_V4" ] && [ -z "$PUBLIC_IP_V6" ]; then
    print_error "无法检测公网 IP（IPv4/IPv6），请检查网络或手动填写"
    exit 1
fi

echo "请选择要使用的公网 IP 地址:"
[ -n "$PUBLIC_IP_V4" ] && echo "1. IPv4: $PUBLIC_IP_V4"
[ -n "$PUBLIC_IP_V6" ] && echo "2. IPv6: $PUBLIC_IP_V6"
read -p "请输入对应的数字选择 [默认1，若不可用则选择可用项]: " IP_CHOICE
IP_CHOICE=${IP_CHOICE:-1}

# 选择公网 IP 地址
if [ "$IP_CHOICE" -eq 2 ] && [ -n "$PUBLIC_IP_V6" ]; then
    PUBLIC_IP="$PUBLIC_IP_V6"
else
    PUBLIC_IP="${PUBLIC_IP_V4:-$PUBLIC_IP_V6}"
fi

# IPv6 需要中括号，IPv4 不需要
if [[ "$PUBLIC_IP" =~ : ]]; then
    link_ip="[$PUBLIC_IP]"
else
    link_ip="$PUBLIC_IP"
fi

update_env link_ip "$link_ip"



print_info "选定公网 IP: $PUBLIC_IP"


update_env PUBLIC_IP "$PUBLIC_IP"
update_env IP_CHOICE "$IP_CHOICE"
update_env UUID "$UUID"
update_env UUID2 "$UUID2"
update_env WS_PATH1 "$WS_PATH1"
update_env WS_PATH "$WS_PATH"
update_env WS_PATH2 "$WS_PATH2"
update_env PRIVATE_KEY "$(tr -d '\n' < /usr/local/etc/xray/privatekey)"
update_env PUBLIC_KEY "$(tr -d '\n' < /usr/local/etc/xray/publickey)"
update_env PASSWORD "$(tr -d '\n' < /usr/local/etc/xray/password)"
update_env SHORT_ID "$short_id"
}
getkey() {
    echo "[Info] 正在生成 Reality 密钥对，请耐心等待..."

    mkdir -p /usr/local/etc/xray

    XRAY_BIN="$INSTALL_DIR/xrayls"
    if [ ! -x "$XRAY_BIN" ]; then
        echo "[Error] 未找到 xrayls 可执行文件：$XRAY_BIN"
        exit 1
    fi

    # 生成 PrivateKey、Password、Hash32
    key_output=$("$XRAY_BIN" x25519)
    private_key=$(echo "$key_output" | awk -F': ' '/PrivateKey/ {print $2}')
    password=$(echo "$key_output" | awk -F': ' '/Password/ {print $2}')
    hash32=$(echo "$key_output" | awk -F': ' '/Hash32/ {print $2}')

    if [ -z "$private_key" ] || [ -z "$password" ]; then
        echo "[Error] 未生成 privateKey 或 password，退出"
        exit 1
    fi

    # publicKey 就等于 password
    public_key="$password"

    # 保存到 /usr/local/etc/xray
    echo "$private_key" > /usr/local/etc/xray/privatekey
    echo "$public_key" > /usr/local/etc/xray/publickey
    echo "$password" > /usr/local/etc/xray/password
    echo "$hash32" > /usr/local/etc/xray/hash32
    chmod 600 /usr/local/etc/xray/*

    # 输出
    echo "[Info] Reality 密钥生成完成："
    echo "PrivateKey: $private_key"
    echo "PublicKey : $public_key"
    echo "Password  : $password"
    echo "Hash32    : $hash32"
}

generate_port() {
    local protocol="$1"
    while :; do
        candidate=$((RANDOM % 10001 + 10000))
        read -p "请为 ${protocol} 输入监听端口(回车使用随机端口 $candidate): " user_input
        port=${user_input:-$candidate}
        # 检查是否为数字且在 1-65535 范围内
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "端口 $port 无效，请输入 1-65535 的数字"
            continue
        fi
        # 检查端口是否被占用
        if ss -tuln | awk '{print $5}' | grep -E -q "(:|\\])${port}\$"; then
            echo "端口 $port 被占用，请输入其他端口"
            continue
        fi
        echo "$port"
        return 0
    done
}
# 检查 openssl 是否存在
if ! command -v openssl >/dev/null 2>&1; then
    echo "[Info] openssl 未安装，正在自动安装..."

    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y openssl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y openssl
    elif command -v apk >/dev/null 2>&1; then
        apk add openssl
    else
        echo "[Error] 无法自动安装 openssl，请手动安装"
        exit 1
    fi
fi

PORT=$(generate_port "Reality (外部 TCP)")
update_env PORT "$PORT"
getkey
usid
