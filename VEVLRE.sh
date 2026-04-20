#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 检查是否为root用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用root用户运行此脚本！\n" && exit 1

# 简单依赖检查
for cmd in curl ss awk xxd systemctl grep sed tr dd; do
    command -v $cmd >/dev/null 2>&1 || { echo -e "${RED}错误：${PLAIN} 需要命令 '$cmd'，请先安装它。"; exit 1; }
done

# 系统信息
SYSTEM_NAME=$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d '"' -f2 || echo "Unknown")
CORE_ARCH=$(arch 2>/dev/null || echo "unknown")

# 介绍信息
clear
cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.xrayls
       -----------------------------------------
EOF
echo -e "${GREEN}System: ${PLAIN}${SYSTEM_NAME}"
echo -e "${GREEN}Architecture: ${PLAIN}${CORE_ARCH}"
echo -e "${GREEN}Version: ${PLAIN}1.0.1-fixed"
echo -e "----------------------------------------"

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

# 随机生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# 生成端口的函数（返回端口通过 echo）
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

# 随机生成 WS 路径
generate_ws_path() {
    echo "/$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)"
}

INSTALL_DIR="/root/catmi/xray"
mkdir -p "$INSTALL_DIR"/{conf,log}
echo "mox：xray" >> /root/catmi/install_info.txt
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


# ================= 安装 Xray =================
xray_install() {
# 安装 xray（保留你原来的安装方式）
print_info "安装最新 Xray..."
if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    print_error "Xray 安装失败，请检查网络与安装脚本来源"
    exit 1
fi

# 确认 xray 二进制存在
if [ ! -x /usr/local/bin/xray ]; then
    print_error "/usr/local/bin/xray 不存在或不可执行，安装可能失败"
    exit 1
fi

# 移动并重命名为 xrayls（保留可执行权限）
mv -f /usr/local/bin/xray "$INSTALL_DIR/xrayls" 2>/dev/null || cp -f /usr/local/bin/xray "$INSTALL_DIR/xrayls"
chmod +x "$INSTALL_DIR/xrayls"

# systemd service
cat <<EOF >/etc/systemd/system/xrayls.service
[Unit]
Description=xrayls Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/xrayls -c $INSTALL_DIR/conf/01.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

# ================= Reality 密钥 =================
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
# ================= 参数生成 =================
usid() {
# 生成短 id
short_id=$(dd if=/dev/urandom bs=4 count=2 2>/dev/null | xxd -p -c 8)



# 生成端口与路径

WS_PATH1=$(generate_ws_path)
WS_PATH=$(generate_ws_path)
WS_PATH2=$(generate_ws_path)
UUID=$(generate_uuid)
UUID2=$(generate_uuid)
print_info "使用端口: $PORT"
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
    VALUE="[::]:"
    link_ip="[$PUBLIC_IP]"
else
    # 默认使用 IPv4（如果不存在则回落到 IPv6）
    if [ -n "$PUBLIC_IP_V4" ]; then
        PUBLIC_IP="$PUBLIC_IP_V4"
        VALUE=""
        link_ip="$PUBLIC_IP"
    else
        PUBLIC_IP="$PUBLIC_IP_V6"
        VALUE="[::]:"
        link_ip="[$PUBLIC_IP]"
    fi
fi

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
# ================= Web 选择 =================
webcn() {
echo "请选择 Web 服务安装方式："
echo "1. 安装 Nginx"
echo "2. 安装 Caddy"
echo "3. 跳过网页配置"
read -p "请输入选项 (1/2/3): " WEB_CHOICE
if [ "$WEB_CHOICE" = "1" ] || [ "$WEB_CHOICE" = "3" ]; then
    
    read -p "请输入监听端口 (默认 443): " NPORT
    NPORT=${NPORT:-443}
    update_env NPORT "NPORT"
    
    dest_server
    PORT=$(generate_port "Reality (外部 TCP)")
    update_env PORT "PORT"
    read -p "请输入申请证书的域名: " DOMAIN_LOWER   
    update_env DOMAIN_LOWER "DOMAIN_LOWER"
    bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/nconf.sh)
elif [ "$WEB_CHOICE" = "2" ]; then
    
    read -p "请输入未cdn域名 " RDOMAIN_LOWE
    read -p "请输入申请证书的域名: " DOMAIN_LOWER    
    update_env DOMAIN_LOWER "DOMAIN_LOWER"
    update_env RDOMAIN_LOWE "RDOMAIN_LOWE"

    bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/cconf.sh)
fi
}
dest_server() {
if [ -x /bin/bash ]; then
    # 靠你原脚本位置调用 domains.sh（容错）
    if curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh >/dev/null 2>&1; then
        bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh) || print_info "domains.sh 执行结束（非致命）"
    else
        print_info "无法下载 domains.sh（可能离线），跳过该步骤"
    fi
fi

# 读取 dest_server，容错处理
dest_server=""
if [ -f /root/catmi/dest_server.txt ]; then
    dest_server=$(grep -Eo '[:：]\s*[^[:space:]]+' /root/catmi/dest_server.txt | sed 's/[:：]\s*//g' | head -n1)
    # 也尝试直接读取整行 key=value
    if [ -z "$dest_server" ]; then
        dest_server=$(grep -E '^dest_server' /root/catmi/dest_server.txt 2>/dev/null | sed 's/.*[:=：]\s*//g' | head -n1)
    fi
fi

if [ -z "$dest_server" ]; then
    print_error "未检测到有效的 dest_server（/root/catmi/dest_server.txt），请先确保文件存在并包含 dest_server: your.domain"
    exit 1
fi
print_info "目标域名 dest_server=$dest_server"
}
webxz() {
    if [[ "$WEB_CHOICE" == "1" ]]; then
        print_info "选择安装 Nginx..."

        if curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/nginx.sh >/dev/null 2>&1; then
            bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/nginx.sh) \
            || print_info "nginx.sh 执行结束（非致命）"
        else
            print_info "无法下载 nginx.sh，跳过"
        fi
    fi

    if [[ "$WEB_CHOICE" == "2" ]]; then
        print_info "选择安装 Caddy..."
        if curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/caddy.sh >/dev/null 2>&1; then
            bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/caddy.sh) \
            || print_info "caddy.sh 执行结束（非致命）"
        else
            print_info "无法下载 caddy.sh，跳过"
        fi
    fi

    if [[ "$WEB_CHOICE" == "3" ]]; then
read -p "请输入你的域名 (DOMAIN_LOWER): " DOMAIN_LOWER

cat << EOF > "$INSTALL_DIR/nginx.json"
    
    location ${WS_PATH} {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:9999;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
        location ${WS_PATH1} {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:9998;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
        location ${WS_PATH2} {
        proxy_request_buffering      off;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:9997;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOF
    if [[ -z "$DOMAIN_LOWER" ]]; then
        print_info "域名不能为空，请重新运行脚本"
        exit 1
    fi

    print_info "已设置 DOMAIN_LOWER=${DOMAIN_LOWER}"
fi
}






# ================= 启动 =================
start_xray() {
# 重新加载 systemd 并启动服务
systemctl daemon-reload
systemctl enable xrayls
if ! systemctl restart xrayls; then
    print_error "重启 xrayls 服务失败，请运行 'journalctl -u xrayls -b --no-pager' 获取详情"
    systemctl status xrayls --no-pager || true
    exit 1
fi
print_info "xrayls 服务已启动并正在运行"
}


# ================= 主流程 =================
main(){
    xray_install
    getkey
    usid
    webcn
    webxz
    start_xray
    print_info "完成"
}

main
