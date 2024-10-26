#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 检查是否为root用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用root用户运行此脚本！\n" && exit 1

# 系统信息
SYSTEM_NAME=$(grep -i pretty_name /etc/os-release | cut -d \" -f2)
CORE_ARCH=$(arch)

# 介绍信息
clear
cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.xray.sock5
                
       -----------------------------------------
EOF
echo -e "${GREEN}System: ${PLAIN}${SYSTEM_NAME}"
echo -e "${GREEN}Architecture: ${PLAIN}${CORE_ARCH}"
echo -e "${GREEN}Version: ${PLAIN}1.0.0"
echo -e "----------------------------------------"

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

print_warning() {
    echo -e "${YELLOW}[Warning]${PLAIN} $1"
}

# 生成端口的函数
generate_port() {
    local protocol="$1"
    while :; do
        port=$((RANDOM % 10001 + 10000))
        read -p "请为 ${protocol} 输入监听端口(默认为随机生成): " user_input
        port=${user_input:-$port}
        if ! ss -tuln | grep -q ":$port\b"; then
            echo "$port"
            return 0
        else
            echo "端口 $port 被占用，请输入其他端口"
        fi
    done
}

# 安装xray
echo "安装最新 Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

mv /usr/local/bin/xray /usr/local/bin/xrayM

chmod +x /usr/local/bin/xrayM

cat <<EOF >/etc/systemd/system/xrayM.service
[Unit]
Description=XrayM Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayM -c /etc/xrayM/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target

EOF

# SOCKS 配置
DEFAULT_SOCKS_USERNAME="userb"
DEFAULT_SOCKS_PASSWORD="passwordb"
read -p "SOCKS 账号 (默认 $DEFAULT_SOCKS_USERNAME): " SOCKS_USERNAME
SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}
read -p "SOCKS 密码 (默认 $DEFAULT_SOCKS_PASSWORD): " SOCKS_PASSWORD
SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}

# 提示输入监听端口号
PORT=$(generate_port "socks5")

# 获取公网 IP 地址
PUBLIC_IP_V4=$(curl -s https://api.ipify.org)
PUBLIC_IP_V6=$(curl -s https://api64.ipify.org)
echo "公网 IPv4 地址: $PUBLIC_IP_V4"
echo "公网 IPv6 地址: $PUBLIC_IP_V6"

# 选择使用哪个公网 IP 地址
echo "请选择要使用的公网 IP 地址:"
echo "1. $PUBLIC_IP_V4"
echo "2. $PUBLIC_IP_V6"
read -p "请输入对应的数字选择: " IP_CHOICE

if [ "$IP_CHOICE" -eq 1 ]; then
    PUBLIC_IP=$PUBLIC_IP_V4
elif [ "$IP_CHOICE" -eq 2 ]; then
    PUBLIC_IP=$PUBLIC_IP_V6
else
    echo "无效选择，退出脚本"
    exit 1
fi

# 配置文件生成
mkdir -p /etc/xrayM
cat <<EOF > /etc/xrayM/config.json
{
    "log": {
        "disabled": false,
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "listen": "::",
            "port": ${PORT},
            "protocol": "socks",
            "settings": {
                "accounts": [
                    {
                        "user": "${SOCKS_USERNAME}",
                        "pass": "${SOCKS_PASSWORD}"
                    }
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOF
sudo systemctl enable xrayM
print_info "xray 安装完成！"
print_info "服务器地址：${PUBLIC_IP}"
print_info "端口：${PORT}"
print_info "账号：${SOCKS_USERNAME}"
print_info "密码：${SOCKS_PASSWORD}"
print_info "配置文件已保存到：/etc/xrayM/config.json"
sudo systemctl status xrayM
