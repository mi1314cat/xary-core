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
# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

xray_install() {
INSTALL_DIR="/root/catmi/xray"
mkdir -p "$INSTALL_DIR"/{conf,log,out}
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
ExecStart=$INSTALL_DIR/xrayls -confdir $INSTALL_DIR/conf
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}
xray_install
