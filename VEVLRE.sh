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
mkdir -p "$INSTALL_DIR" /usr/local/etc/xray /root/catmi

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
ExecStart=$INSTALL_DIR/xrayls -c $INSTALL_DIR/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 如果你依赖外部 domains 脚本来填充 /root/catmi/dest_server.txt，请执行
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

# 生成 Reality 私钥对等信息并保存（public/private/hash/password）
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
getkey

# 生成短 id
short_id=$(dd if=/dev/urandom bs=4 count=2 2>/dev/null | xxd -p -c 8)


read -p "请输入 Vless 监听端口 (默认为 443): " NPORT
NPORT=${PORT:-443}
# 生成端口与路径
PORT=$(generate_port "Reality (外部 TCP)")
WS_PATH1=$(generate_ws_path)
WS_PATH=$(generate_ws_path)
WS_PATH2=$(generate_ws_path)
UUID=$(generate_uuid)

print_info "使用端口: $PORT"
print_info "UUID: $UUID"
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

# 生成 xray config.json（含多个 inbound）
cat <<EOF > "$INSTALL_DIR/config.json"
{
  "log": {
    "access": "$INSTALL_DIR/access.log",
    "error": "$INSTALL_DIR/error.log",
    "disabled": false,
    "loglevel": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "localhost"

    ]
  },
  
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      
     
      
      {
        "domain": [
          "geosite:category-ads-all" 
        ],
        "outboundTag": "block" 
      }
    ]
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 9998,
      "tag": "VLESS-WS",
      "protocol": "VLESS",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 64
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH1}"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 9999,
      "tag": "VMESS-WS",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 64
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 9997,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${UUID}"
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${WS_PATH2}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "tag": "in1"
    },
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 9997
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": true,
          "dest": "${dest_server}:443",
          "xver": 0,
          "serverNames": [
            "${dest_server}"
          ],
          "privateKey": "$(cat /usr/local/etc/xray/privatekey)",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "${short_id}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]

}
EOF

# 重新加载 systemd 并启动服务
systemctl daemon-reload
systemctl enable xrayls
if ! systemctl restart xrayls; then
    print_error "重启 xrayls 服务失败，请运行 'journalctl -u xrayls -b --no-pager' 获取详情"
    systemctl status xrayls --no-pager || true
    exit 1
fi
print_info "xrayls 服务已启动并正在运行"

# 保存安装信息
{
    echo "xray 安装完成！"
    echo "服务器地址：${PUBLIC_IP}"
    echo "IP_CHOICE：${IP_CHOICE}"
    echo "端口：${NPORT}"
    echo "reality端口：${PORT}"
    echo "UUID：${UUID}"
    echo "vless WS 路径：${WS_PATH1}"
    echo "vmess WS 路径：${WS_PATH}"
    echo "xhttp 路径：${WS_PATH2}"
    echo "dest_server：${dest_server}"
    echo "short_id：${short_id}"
} > "/root/catmi/install_info.txt"

# 询问是否安装 nginx
read -p "是否安装 Nginx? (y/n): " INSTALL_NGINX

if [[ "$INSTALL_NGINX" == "y" || "$INSTALL_NGINX" == "Y" ]]; then
    print_info "开始安装并配置 Nginx..."

    # ===== 先执行 nginx =====
    if curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/nginx.sh >/dev/null 2>&1; then
        bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/nginx.sh) \
        || print_info "nginx.sh 执行结束（非致命）"
    else
        print_info "无法下载 nginx.sh，跳过 nginx 配置"
    fi

    # ===== 再读取 DOMAIN_LOWER（容错）=====
    print_info "尝试读取 DOMAIN_LOWER..."

    DOMAIN_LOWER=""
    if [ -f /root/catmi/DOMAIN_LOWER.txt ]; then
        DOMAIN_LOWER=$(grep -Eo '[:：]\s*[^[:space:]]+' /root/catmi/DOMAIN_LOWER.txt | sed 's/[:：]\s*//g' | head -n1)

        if [ -z "$DOMAIN_LOWER" ]; then
            DOMAIN_LOWER=$(grep -E '^DOMAIN_LOWER' /root/catmi/DOMAIN_LOWER.txt 2>/dev/null | sed 's/.*[:=：]\s*//g' | head -n1)
        fi
    fi

    # fallback
    DOMAIN_LOWER=${DOMAIN_LOWER:-$dest_server}

    # 如果还是空 → 手动输入（兜底）
    if [[ -z "$DOMAIN_LOWER" ]]; then
        print_info "自动获取失败，请手动输入域名"
        read -p "请输入 DOMAIN_LOWER: " DOMAIN_LOWER

        if [[ -z "$DOMAIN_LOWER" ]]; then
            print_info "域名不能为空，退出"
            exit 1
        fi
    fi

    print_info "最终使用 DOMAIN_LOWER=${DOMAIN_LOWER}"

else
    print_info "已选择不安装 Nginx"

    # ===== 不安装 → 直接手动输入 =====
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

# 生成 Clash Meta 配置片段
cat << EOF > "$INSTALL_DIR/clash-meta.yaml"
  - name: Reality
    port: ${PORT}
    server: ${PUBLIC_IP}
    type: vless
    network: tcp
    udp: true
    tls: true
    servername: ${dest_server}
    skip-cert-verify: true
    reality-opts:
      public-key: $(cat /usr/local/etc/xray/publickey)
      short-id: ${short_id}
    uuid: ${UUID}
    flow: xtls-rprx-vision
    client-fingerprint: chrome
  - name: vmess-ws-tls
    type: vmess
    server: ${DOMAIN_LOWER}
    port: 443
    cipher: auto
    uuid: ${UUID}
    alterId: 0
    tls: true
    network: ws
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${DOMAIN_LOWER}
    servername: ${DOMAIN_LOWER}
  - name: vless-ws-tls
    type: vless
    server: ${DOMAIN_LOWER}
    port: 443
    uuid: ${UUID}
    tls: true
    skip-cert-verify: true
    network: ws
    alterId: 0
    cipher: auto
    ws-opts:
      headers:
        Host: ${DOMAIN_LOWER}
      path: ${WS_PATH1}
    servername: ${DOMAIN_LOWER}

EOF

# 生成 xhttp.json（仅保留一个正确的 JSON）
cat <<EOF > "$INSTALL_DIR/xhttp.json"
{
  "downloadSettings": {
    "address": "${PUBLIC_IP}",
    "port": ${PORT},
    "network": "xhttp",
    "xhttpSettings": {
      "path": "${WS_PATH2}",
      "mode": "auto"
    },
    "security": "reality",
    "realitySettings": {
      "serverName": "${dest_server}",
      "fingerprint": "chrome",
      "show": false,
      "publicKey": "$(cat /usr/local/etc/xray/publickey)",
      "shortId": "${short_id}",
      "spiderX": ""
    }
  }
}


{
  "downloadSettings": {
    "address": "${DOMAIN_LOWER}", 
    "port": 443, 
    "network": "xhttp", 
    "security": "tls", 
    "tlsSettings": {
      "serverName": "${DOMAIN_LOWER}", 
      "allowInsecure": false
    }, 
    "xhttpSettings": {
      "path": "${WS_PATH2}", 
      "mode": "auto"
    }
  }
}
EOF

# 生成分享链接（将 pbk 指向 publickey）
share_link="
vless://${UUID}@${link_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_server}&fp=chrome&pbk=$(cat /usr/local/etc/xray/publickey)&sid=${short_id}&type=tcp&headerType=none#Reality
vless://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&allowInsecure=1&type=ws&host=${DOMAIN_LOWER}&path=${WS_PATH1}#vless-ws-tls
vmess://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&allowInsecure=1&type=ws&host=${DOMAIN_LOWER}&path=${WS_PATH}#vmess-ws-tls
vless://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&type=xhttp&host=${DOMAIN_LOWER}&path=${WS_PATH2}&mode=auto#vless-xhttp-tls
"
echo "${share_link}" > "$INSTALL_DIR/v2ray.txt"

# 展示服务状态与分享链接路径
systemctl status xrayls --no-pager || true

echo -e "\n${GREEN}安装完成，关键输出文件：${PLAIN}"
echo " - /root/catmi/install_info.txt"
echo " - $INSTALL_DIR/config.json"
echo " - $INSTALL_DIR/v2ray.txt"
echo " - /usr/local/etc/xray/privatekey (权限600)"
echo " - /usr/local/etc/xray/publickey (权限600)"
echo " - $INSTALL_DIR/clash-meta.yaml"
echo " - $INSTALL_DIR/xhttp.json"

echo -e "\n分享链接（保存在 $INSTALL_DIR/v2ray.txt）："
cat "$INSTALL_DIR/v2ray.txt"
