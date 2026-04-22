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
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"
INSTALL_DIR="/root/catmi/xray"
mkdir -p "$INSTALL_DIR"/{conf,log}
xrayconf="$INSTALL_DIR/install_info.env"

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


update_env $CATMIENV_FILE mode xray
# ================= 安装 Xray =================
xray_install() {
https://github.com/mi1314cat/xary-core/raw/refs/heads/main/unused/xray_install.sh
}
scuid() {
  bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/XRevise.sh)
  bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh)
}

# ================= Web 选择 =================
webcn() {
echo "请选择 Web 服务安装方式："
echo "1. 安装 Nginx"
echo "2. 安装 Caddy"
echo "3. 跳过网页配置"
read -p "请输入选项 (1/2/3): " WEB_CHOICE
update_env $xrayconf WEB_CHOICE "$WEB_CHOICE"
if [ "$WEB_CHOICE" = "1" ] || [ "$WEB_CHOICE" = "3" ]; then
    
    read -p "请输入nginx监听端口 (默认 443): " NPORT
    NPORT=${NPORT:-443}
    update_env $xrayconf NPORT "$NPORT"
    
    RNPORT=$(generate_port "Reality (外部 TCP)")
    update_env $xrayconf RNPORT "$RNPORT"
    read -p "请输入申请证书的域名: " DOMAIN_LOWER   
    update_env $xrayconf NDOMAIN_LOWER "$NDOMAIN_LOWER"
    update_env $CATMIENV_FILE DOMAIN_LOWER "$DOMAIN_LOWER"
    bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/nconf.sh)
elif [ "$WEB_CHOICE" = "2" ]; then

    read -p "请输入监听端口 (默认 443): " CRPORT
    CRPORT=${CRPORT:-443}
    update_env $xrayconf RNPORT "$RNPORT"
    read -p "请输入未cdn域名 " RDOMAIN_LOWE
    read -p "请输入申请证书的域名: " CDOMAIN_LOWER    
    update_env $xrayconf CDOMAIN_LOWER "$CDOMAIN_LOWER"
    update_env $CATMIENV_FILE DOMAIN_LOWER "$CDOMAIN_LOWER"
    update_env $xrayconf RDOMAIN_LOWE "$RDOMAIN_LOWE"

    bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/cconf.sh)
fi
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
    load_env $xrayconf
    webcn
    webxz
    start_xray
    outconf
    print_info "完成"
}

main
