#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"
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
mkdir -p "$INSTALL_DIR"/{conf,log,out}
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
scuid() {
  bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/XRevise.sh)
  bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh)
}

webcn() {
if [ "$WEB_CHOICE" = "2" ]; then
    
    read -p "请输入nginx监听端口 (默认 443): " NPORT
    NPORT=${NPORT:-443}
    update_env $xrayconf NPORT "$NPORT"
    
    NRPORT=$(generate_port "Reality (外部 TCP)")
    update_env $xrayconf NRPORT "$NRPORT"
    read -p "请输入申请证书的域名: " DOMAIN_LOWER   
    update_env $xrayconf NDOMAIN_LOWER "$NDOMAIN_LOWER"
    update_env $CATMIENV_FILE DOMAIN_LOWER "$DOMAIN_LOWER"
    bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/nconf.sh)
    bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/nginx.sh)
elif [ "$WEB_CHOICE" = "1" ] || [ "$WEB_CHOICE" = "3" ]; then

    read -p "请输入监听端口 (默认 443): " CRPORT
    CRPORT=${CRPORT:-443}
    update_env $xrayconf CRPORT "$CRPORT"
    read -p "请输入未cdn域名 " RDOMAIN_LOWE
    read -p "请输入申请证书的域名: " CDOMAIN_LOWER    
    update_env $xrayconf CDOMAIN_LOWER "$CDOMAIN_LOWER"
    update_env $CATMIENV_FILE DOMAIN_LOWER "$CDOMAIN_LOWER"
    update_env $xrayconf RDOMAIN_LOWE "$RDOMAIN_LOWE"

    bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/cconf.sh)
    bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/caddy.sh)
fi
}
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
cat_out_files() {
    local dir="$1"

    [[ -d "$dir" ]] || {
        echo "[Info] 目录不存在: $dir"
        return 0
    }

    local files
    files=$(find "$dir" -type f \( -name "*.txt" -o -name "*.yaml" \))

    [[ -z "$files" ]] && {
        echo "[Info] 没有找到 txt/yaml 文件"
        return 0
    }

    echo "[Info] 输出文件内容："
    echo "----------------------"

    cat $files
}
main(){
    
    scuid
    load_env $xrayconf
    webcn
    
    start_xray
    cat_out_files "$INSTALL_DIR/out"
    print_info "完成"
}

main
