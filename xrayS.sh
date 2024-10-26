#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
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
                   catmi.xrayS
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

# 随机生成 UUID 和 WS 路径
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

generate_ws_path() {
    echo "/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)"
}

# 安装xray
install_xray() {
    echo "安装最新 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || { echo "Xray 安装失败"; exit 1; }
    mv /usr/local/bin/xray /usr/local/bin/xrayS
    chmod +x /usr/local/bin/xrayS
}

# 生成服务文件
generate_service_file() {
    cat <<EOF > /etc/systemd/system/xrayS.service
[Unit]
Description=XrayS Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayS -c /etc/xrayS/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xrayS
}

# 生成配置文件
generate_config() {
    local type="$1"
    local port="$2"
    local uuid="$3"
    local ws_path="$4"
    local socks_port="$5"

    cat <<EOF > /etc/xrayS/config.json
{
    "log": {
        "disabled": false,
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "port": ${port},
            "protocol": "${type}",
            "settings": {
                "clients": [
                    {
                        "id": "${uuid}",
                        "alterId": 64
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "${ws_path}"
                }
            }
        },
        {
            "port": ${socks_port},
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "ip": "127.0.0.1",
                "users": [
                    {
                        "user": "user",
                        "pass": "pass"
                    }
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {}
        }
    ]
}
EOF
}

# 创建快捷方式
create_shortcut() {
    cat <<EOF > /usr/bin/xrayS-status
#!/bin/bash
sudo systemctl status xrayS
EOF
    chmod +x /usr/bin/xrayS-status
    print_info "已创建快捷方式 xrayS-status 用于查看服务状态。"
}

# 主菜单
while true; do
    echo "请选择要安装的功能:"
    echo "1. 安装 SOCKS5"
    echo "2. 安装 Vmess + WS"
    echo "3. 查看 Xray 状态"
    echo "4. 重启 Xray"
    echo "5. 查看配置"
    echo "6. 删除配置"
    echo "7. 退出"
    read -p "请输入选项 [1-7]: " option

    case $option in
        1)
            install_xray
            echo "请输入 SOCKS5 监听端口 (默认为 1080): "
            read -p "端口: " SOCKS_PORT
            SOCKS_PORT=${SOCKS_PORT:-1080}
            UUID=$(generate_uuid)
            generate_config "vmess" 443 "$UUID" "$(generate_ws_path)" "$SOCKS_PORT"
            generate_service_file
            create_shortcut
            print_info "SOCKS5 安装完成！"
            ;;
        2)
            install_xray
            UUID=$(generate_uuid)
            WS_PATH=$(generate_ws_path)
            echo "请输入 Vmess 监听端口 (默认为 443): "
            read -p "端口: " VMESS_PORT
            VMESS_PORT=${VMESS_PORT:-443}
            echo "请输入 SOCKS5 监听端口 (默认为 1080): "
            read -p "端口: " SOCKS_PORT
            SOCKS_PORT=${SOCKS_PORT:-1080}
            generate_config "vmess" "$VMESS_PORT" "$UUID" "$WS_PATH" "$SOCKS_PORT"
            generate_service_file
            create_shortcut
            print_info "Vmess + WS 安装完成！"
            ;;
        3)
            echo "Xray 状态信息:"
            sudo systemctl status xrayS
            ;;
        4)
            echo "重启 Xray 服务..."
            sudo systemctl restart xrayS
            print_info "Xray 服务已重启！"
            ;;
        5)
            echo "Xray 配置文件内容:"
            cat /etc/xrayS/config.json
            ;;
        6)
            echo "删除配置..."
            rm -f /etc/xrayS/config.json
            rm -f /etc/systemd/system/xrayS.service
            sudo systemctl stop xrayS
            sudo systemctl disable xrayS
            print_info "配置已删除，服务已停止并禁用。"
            ;;
        7)
            exit 0
            ;;
        *)
            print_error "无效选项，请重试。"
            ;;
    esac
done
