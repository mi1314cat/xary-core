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
mkdir -p "$INSTALL_DIR" /usr/local/etc/xray /root/catmi $INSTALL_DIR/conf $INSTALL_DIR/log
echo "mox：xray" >> /root/catmi/install_info.txt

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
ExecStart=$INSTALL_DIR/xrayls -c $INSTALL_DIR/conf
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF



# 生成 xray config.json（含多个 inbound）
cat <<EOF > "$INSTALL_DIR/conf/log.json"
{
  "log": {
    "access": "$INSTALL_DIR/log/access.log",
    "error": "$INSTALL_DIR/log/error.log",
    "disabled": false,
    "loglevel": "info",
    "timestamp": true
  }
   }
EOF

cat <<EOF > "$INSTALL_DIR/conf/dns.json"
{

  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "localhost"

    ]
  }
  }
EOF
cat <<EOF > "$INSTALL_DIR/conf/routing.json"
{
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
  }
  }
EOF 
cat <<EOF > "$INSTALL_DIR/conf/outbounds.json"
{
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
cat <<EOF > "$INSTALL_DIR/conf/x_inbounds.json"
{
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
            "alterId": 0
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
    }
  ]
}
EOF


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
    echo "UUID：${UUID}"
    echo "vless WS 路径：${WS_PATH1}"
    echo "vmess WS 路径：${WS_PATH}"
    echo "xhttp 路径：${WS_PATH2}"
    
} > "$INSTALL_DIR/install_info.txt"

echo "请选择 Web 服务安装方式："
echo "1. 安装 Nginx"
echo "2. 安装 Caddy"
echo "3. 跳过网页配置"
read -p "请输入选项 (1/2/3): " WEB_CHOICE

# ===== 统一获取端口 =====
read -p "请输入监听端口 (默认 443): " NPORT
NPORT=${NPORT:-443}
echo "端口：${NPORT}" >> "$INSTALL_DIR/install_info.txt"

# ===== 安装逻辑 =====
case "$WEB_CHOICE" in
    1)
        print_info "选择安装 Nginx..."

        if curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/nginx.sh >/dev/null 2>&1; then
            bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/nginx.sh) \
            || print_info "nginx.sh 执行结束（非致命）"
        else
            print_info "无法下载 nginx.sh，跳过"
        fi
        ;;

    2)
        print_info "选择安装 Caddy..."

        if curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/caddy.sh >/dev/null 2>&1; then
            bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/caddy.sh) \
            || print_info "caddy.sh 执行结束（非致命）"
        else
            print_info "无法下载 caddy.sh，跳过"
        fi
        ;;

    3)
        print_info "跳过 Web 服务安装"
        ;;

    *)
        print_info "输入错误，退出"
        exit 1
        ;;
esac

# ===== 统一 DOMAIN_LOWER 获取（无论选哪个都要）=====
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

# 手动输入兜底
if [[ -z "$DOMAIN_LOWER" ]]; then
    print_info "自动获取失败，请手动输入域名"
    read -p "请输入 DOMAIN_LOWER: " DOMAIN_LOWER

    if [[ -z "$DOMAIN_LOWER" ]]; then
        print_info "域名不能为空，退出"
        exit 1
    fi
fi

print_info "最终使用 DOMAIN_LOWER=${DOMAIN_LOWER}"

# ===== 如果跳过 Web → 生成 nginx 反代配置模板 =====
if [[ "$WEB_CHOICE" == "3" ]]; then

cat << EOF > "$INSTALL_DIR/nginx.conf"

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

    print_info "已生成 nginx 反代配置模板: $INSTALL_DIR/nginx.conf"
fi
# 生成 Clash Meta 配置片段
cat << EOF > "$INSTALL_DIR/clash-meta.yaml"
  
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

vless://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&allowInsecure=1&type=ws&host=${DOMAIN_LOWER}&path=${WS_PATH1}#vless-ws-tls
vmess://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&allowInsecure=1&type=ws&host=${DOMAIN_LOWER}&path=${WS_PATH}#vmess-ws-tls
vless://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&type=xhttp&host=${DOMAIN_LOWER}&path=${WS_PATH2}&mode=auto#vless-xhttp-tls
"
echo "${share_link}" > "$INSTALL_DIR/v2ray.txt"

# 展示服务状态与分享链接路径
systemctl status xrayls --no-pager || true

echo -e "\n${GREEN}安装完成，关键输出文件：${PLAIN}"
echo " - $INSTALL_DIR/install_info.txt"
echo " - $INSTALL_DIR/config.json"
echo " - $INSTALL_DIR/v2ray.txt"
echo " - /usr/local/etc/xray/privatekey (权限600)"
echo " - /usr/local/etc/xray/publickey (权限600)"
echo " - $INSTALL_DIR/clash-meta.yaml"
echo " - $INSTALL_DIR/xhttp.json"

echo -e "\n分享链接（保存在 $INSTALL_DIR/v2ray.txt）："
cat "$INSTALL_DIR/v2ray.txt"
