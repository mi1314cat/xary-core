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
                   catmi.xrayM.sock5
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
generate_ports() {
    local protocol="$1"
    local ports=()
    while :; do
        read -p "请输入 SOCKS 端口 (输入空行结束，默认随机生成): " user_input
        if [[ -z "$user_input" ]]; then
            break
        fi
        ports+=("$user_input")
    done

    # 如果没有输入，则生成一个随机端口
    if [ ${#ports[@]} -eq 0 ]; then
        while :; do
            port=$((RANDOM % 10001 + 10000))
            if ! ss -tuln | grep -q ":$port\b"; then
                ports+=("$port")
                break
            fi
        done
    fi

    # 检查端口是否被占用
    for port in "${ports[@]}"; do
        while ss -tuln | grep -q ":$port\b"; do
            echo "端口 $port 被占用，请输入其他端口"
            read -p "请输入新的端口: " new_port
            port=$new_port
        done
    done

    echo "${ports[@]}"
}

# 安装xray
echo "安装最新 Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || { echo "Xray 安装失败"; exit 1; }

mv /usr/local/bin/xray /usr/local/bin/xrayM || { echo "移动文件失败"; exit 1; }
chmod +x /usr/local/bin/xrayM || { echo "修改权限失败"; exit 1; }

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

# 提示输入多个监听端口号
echo "请为 SOCKS 服务器输入端口，按 Enter 键结束输入："
PORTS=($(generate_ports "socks5"))

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
EOF

for port in "${PORTS[@]}"; do
    cat <<EOF >> /etc/xrayM/config.json
        {
            "listen": "::",
            "port": $port,
            "protocol": "socks",
            "settings": {
                "auth": "password",
                "accounts": [
                    {
                        "user": "${SOCKS_USERNAME}",
                        "pass": "${SOCKS_PASSWORD}"
                    }
                ]
            }
        },
EOF
done

# 移除最后一个多余的逗号
sed -i '$ s/,$//' /etc/xrayM/config.json

cat <<EOF >> /etc/xrayM/config.json
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

sudo systemctl daemon-reload
sudo systemctl enable xrayM
sudo systemctl restart xrayM || { echo "重启 xrayM 服务失败"; exit 1; }

# 保存信息到文件
OUTPUT_DIR="/root/xrayM"
mkdir -p "$OUTPUT_DIR"
{
    echo "xray 安装完成！"
    echo "服务器地址：${PUBLIC_IP}"
    echo "端口：${PORTS[*]}"
    echo "账号：${SOCKS_USERNAME}"
    echo "密码：${SOCKS_PASSWORD}"
    echo "配置文件已保存到：/etc/xrayM/config.json"
} > "$OUTPUT_DIR/install_info.txt"

print_info "xray 安装完成！"
print_info "服务器地址：${PUBLIC_IP}"
print_info "端口：${PORTS[*]}"
print_info "账号：${SOCKS_USERNAME}"
print_info "密码：${SOCKS_PASSWORD}"
print_info "配置文件已保存到：/etc/xrayM/config.json"

sudo systemctl status xrayM
