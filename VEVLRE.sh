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


INSTALL_DIR="/root/catmi/xray"
mkdir -p "$INSTALL_DIR"/{conf,log}
echo "mox：xray" >> /root/catmi/install_info.txt
ENV_FILE="$INSTALL_DIR/install_info.env"

update_env() {
    local key="$1"
    local value="$2"

    # 校验 key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "Invalid key: $key"
        return 1
    }

    # 确保目录 & 文件
    mkdir -p "$(dirname "$ENV_FILE")"
    [ -f "$ENV_FILE" ] || touch "$ENV_FILE"

    # 获取权限 & 属主（兼容 Linux / BSD）
    local mode owner group
    if mode=$(stat -c "%a" "$ENV_FILE" 2>/dev/null); then
        owner=$(stat -c "%u" "$ENV_FILE")
        group=$(stat -c "%g" "$ENV_FILE")
    else
        mode=$(stat -f "%Lp" "$ENV_FILE")
        owner=$(stat -f "%u" "$ENV_FILE")
        group=$(stat -f "%g" "$ENV_FILE")
    fi

    # 转义 value
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    # 加锁 + 自动释放
    (
        flock 200

        local tmp_file
        tmp_file=$(mktemp "$(dirname "$ENV_FILE")/.env.tmp.XXXXXX")

        # 先设置权限
        chmod "$mode" "$tmp_file"
        chown "$owner":"$group" "$tmp_file" 2>/dev/null || true

        # 精确删除旧 key（严格匹配 key=）
        awk -v k="$key" 'index($0, k"=") != 1' "$ENV_FILE" > "$tmp_file"

        # 写入新值
        printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"

        # 原子替换
        mv "$tmp_file" "$ENV_FILE"

    ) 200>"$ENV_FILE.lock"
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
scuid() {
  bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/XRevise.sh)
}
load_env() {
    if [ -f "$ENV_FILE" ]; then
        # 检查 env 文件格式是否正确
        if grep -qEv '^[A-Za-z_][A-Za-z0-9_]*=".*"$' "$ENV_FILE"; then
            echo "⚠ env 文件格式异常：$ENV_FILE"
            return 1
        fi

        # 安全加载
        set -a
        source "$ENV_FILE"
        set +a
        echo "已加载 env：$ENV_FILE"
    else
        echo "env 文件不存在：$ENV_FILE"
    fi
}
# ================= Web 选择 =================
webcn() {
echo "请选择 Web 服务安装方式："
echo "1. 安装 Nginx"
echo "2. 安装 Caddy"
echo "3. 跳过网页配置"
read -p "请输入选项 (1/2/3): " WEB_CHOICE
update_env WEB_CHOICE "$WEB_CHOICE"
if [ "$WEB_CHOICE" = "1" ] || [ "$WEB_CHOICE" = "3" ]; then
    
    read -p "请输入监听端口 (默认 443): " NPORT
    NPORT=${NPORT:-443}
    update_env NPORT "$NPORT"
    
    dest_server
    
    read -p "请输入申请证书的域名: " DOMAIN_LOWER   
    update_env DOMAIN_LOWER "$DOMAIN_LOWER"
    bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/nconf.sh)
elif [ "$WEB_CHOICE" = "2" ]; then
    
    read -p "请输入未cdn域名 " RDOMAIN_LOWE
    read -p "请输入申请证书的域名: " DOMAIN_LOWER    
    update_env DOMAIN_LOWER "$DOMAIN_LOWER"
    update_env RDOMAIN_LOWE "$RDOMAIN_LOWE"

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
    proxy_request_buffering off;
    proxy_redirect off;
    proxy_pass http://127.0.0.1:9997;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOF

    print_info "已生成 nginx.json 反代配置模板"
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

outconf(){
cat "$INSTALL_DIR/v2ray.txt"
cat "$INSTALL_DIR/clash-meta.yaml"

}
# ================= 主流程 =================
main(){
    xray_install
    scuid
    load_env
    webcn
    webxz
    start_xray
    outconf
    print_info "完成"
}

main
