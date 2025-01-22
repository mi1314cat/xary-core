#!/bin/bash

# 设置颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 定义颜色打印函数
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    print_error "必须使用 root 用户运行此脚本！"
    exit 1
fi
apt install -y locales
locale-gen zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8

# 随机生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}
# 生成端口的函数
generate_port() {
    local protocol="$1"
    while :; do
        port=$((RANDOM % 10001 + 10000))
        read -p "请为 ${protocol} 输入监听端口(默认为随机生成): " user_input
        port=${user_input:-$port}
        ss -tuln | grep -q ":$port\b" || { echo "$port"; return $port; }
        echo "端口 $port 被占用，请输入其他端口"
    done
}
# 随机生成 WS 路径
generate_ws_path() {
    echo "/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)"
}

# 系统信息
SYSTEM_NAME=$(grep -i pretty_name /etc/os-release | cut -d \" -f2)
CORE_ARCH=$(uname -m)

# 介绍信息
clear
cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.xargo
       -----------------------------------------
EOF
echo -e "${GREEN}System: ${PLAIN}${SYSTEM_NAME}"
echo -e "${GREEN}Architecture: ${PLAIN}${CORE_ARCH}"
echo -e "${GREEN}Version: ${PLAIN}1.0.0"
echo -e "----------------------------------------"
# 打印系统信息
print_info "System: $SYSTEM_NAME"
print_info "Architecture: $CORE_ARCH"

# 定义安装函数
install_package() {
    local package_name="$1"
    if ! dpkg -s "$package_name" >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y "$package_name"
    fi
}

# 定义检查 Cloudflared 安装状态函数
check_cloudflared_status() {
    if cloudflared --version >/dev/null 2>&1; then
        return 0  # 已安装
    else
        return 1  # 未安装
    fi
}

# 定义安装 Cloudflared 函数
install_cloudflared() {
    local last_version
    last_version=$(curl -Ls "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$last_version" ]]; then
        print_error "检测 Cloudflared 版本失败，可能是超出 Github API 限制，请稍后再试"
        exit 1
    fi

    local arch="$CORE_ARCH"
    if [[ "$arch" == "aarch64" ]]; then
        arch="arm64"
    fi

    wget -N --no-check-certificate "https://github.com/cloudflare/cloudflared/releases/download/$last_version/cloudflared-linux-$arch" -O /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared

    print_info "Cloudflared 安装成功！"
}

# 定义登录 Cloudflared 函数
login_cloudflared() {
    cloudflared tunnel login
    if [[ $? -eq 0 ]]; then
        print_info "Cloudflared 登录成功！"
    else
        print_error "Cloudflared 登录失败！"
        exit 1
    fi
}

# 定义创建隧道函数
create_tunnel() {
    local tunnel_name="$1"
    local tunnel_domain="$2"
    local tunnel_uuid

    read -p "请设置隧道名称：" tunnel_name
    read -p "请设置隧道域名：" tunnel_domain

    cloudflared tunnel create "$tunnel_name"
    cloudflared tunnel route dns "$tunnel_name" "$tunnel_domain"
    DOMAIN_LOWER=$tunnel_domain
    tunnel_uuid=$(cloudflared tunnel list | grep "$tunnel_name" | awk -F ' ' '{print $1}')
    read -p "请输入隧道 UUID（复制 ID 里面的内容）：" tunnel_uuid

    local tunnel_file_name="CloudFlare"
    local config_file="/root/catmi/$tunnel_file_name.yml"
    tunnelPort=${PORT}
    mkdir -p /root/catmi

    cat <<EOF > "$config_file"
tunnel: $tunnel_name
credentials-file: /root/.cloudflared/$tunnel_uuid.json
originRequest:
  connectTimeout: 30s
  noTLSVerify: true
ingress:
  - hostname: $tunnel_domain
    service: https://localhost:$tunnelPort
  - service: http_status:404
EOF

    print_info "配置文件已保存至 $config_file"
}

# 定义运行隧道函数
run_tunnel() {
    install_package screen
    screen -dmS CloudFlare cloudflared tunnel --config /root/catmi/CloudFlare.yml run
    print_info "隧道已运行成功，请等待1-3分钟启动并解析完毕"
}

# 定义提取 Argo 证书函数
extract_argo_cert() {
    sed -n '1,5p' /root/.cloudflared/cert.pem > /root/catmi/private.key
    sed -n '6,24p' /root/.cloudflared/cert.pem > /root/catmi/cert.crt
    print_info "Argo 证书提取成功！"
    print_info "证书路径：/root/catmi/cert.crt"
    print_info "私钥路径：/root/catmi/private.key"
}

nginx() {
    apt install -y nginx
    cat << EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    gzip on;

    server {
        listen $VALUE${PORT} ssl;
        server_name ${DOMAIN_LOWER};

        ssl_certificate       "/root/catmi/cert.crt";
        ssl_certificate_key   "/root/catmi/private.key";
        
        ssl_session_timeout 1d;
        ssl_session_cache shared:MozSSL:10m;
        ssl_session_tickets off;
        ssl_protocols    TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;

        location / {
            proxy_pass https://pan.imcxx.com; #伪装网址
            proxy_redirect off;
            proxy_ssl_server_name on;
            sub_filter_once off;
            sub_filter "pan.imcxx.com" \$server_name;
            proxy_set_header Host "pan.imcxx.com";
            proxy_set_header Referer \$http_referer;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header User-Agent \$http_user_agent;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Accept-Language "zh-CN";
        }

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
        
    }
}
EOF


    systemctl reload nginx
}
# 安装xray
xray() {
echo "安装最新 Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || { echo "Xray 安装失败"; exit 1; }

mv /usr/local/bin/xray /usr/local/bin/xrayls || { echo "移动文件失败"; exit 1; }
chmod +x /usr/local/bin/xrayls || { echo "修改权限失败"; exit 1; }

cat <<EOF >/etc/systemd/system/xrayls.service
[Unit]
Description=xrayls Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayls -c /etc/xrayls/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}
# 定义函数，返回随机选择的域名
random_website() {
   domains=(
        "one-piece.com"
        "lovelive-anime.jp"
        "swift.com"
        "academy.nvidia.com"
        "cisco.com"
        "amd.com"
        "apple.com"
        "music.apple.com"
        "amazon.com"
        "fandom.com"
        "tidal.com"
        "zoro.to"
        "mora.jp"
        "j-wave.co.jp"
        "booth.pm"
        "ivi.tv"
        "leercapitulo.com"
        "sky.com"
        "itunes.apple.com"
        "download-installer.cdn.mozilla.net"
        "images-na.ssl-images-amazon.com"
	"www.google-analytics.com"
        "dl.google.com"
    )


    total_domains=${#domains[@]}
    random_index=$((RANDOM % total_domains))
    
    # 输出选择的域名
    echo "${domains[random_index]}"
}


getkey() {
    echo "正在生成私钥和公钥，请妥善保管好..."
    mkdir -p /usr/local/etc/xray

    # 生成密钥并保存到文件
    /usr/local/bin/xrayls x25519 > /usr/local/etc/xray/key || {
        print_error "生成密钥失败"
        return 1
    }

    # 提取私钥和公钥
    private_key=$(awk 'NR==1 {print $3}' /usr/local/etc/xray/key)
    public_key=$(awk 'NR==2 {print $3}' /usr/local/etc/xray/key)

    # 保存密钥到文件
    echo "$private_key" > /usr/local/etc/xray/privatekey
    echo "$public_key" > /usr/local/etc/xray/publickey

   
}
input_variables() {
# 生成密钥
read -rp "请输入reality回落域名回车随机域名: " dest_server
[ -z "$dest_server" ] && dest_server=$(random_website)
# 生成随机 ID
short_id=$(dd bs=4 count=2 if=/dev/urandom | xxd -p -c 8)
# 提示输入监听端口号
read -p "请输入 Vless 监听端口 (默认为 443): " PORT
PORT=${PORT:-443}
port=$(generate_port "reality")
# 生成 UUID 和 WS 路径
UUID=$(generate_uuid)
WS_PATH=$(generate_ws_path)
WS_PATH1=$(generate_ws_path)




# 获取公网 IP 地址
PUBLIC_IP_V4=$(curl -s https://api.ipify.org)
PUBLIC_IP_V6=$(curl -s https://api64.ipify.org)
echo "公网 IPv4 地址: $PUBLIC_IP_V4"
echo "公网 IPv6 地址: $PUBLIC_IP_V6"
# 选择使用哪个公网 IP 地址
echo "请选择要使用的公网 IP 地址:"
echo "1. $PUBLIC_IP_V4"
echo "2. $PUBLIC_IP_V6"
read -p "请输入对应的数字选择 [默认1]: " IP_CHOICE

# 如果没有输入（即回车），则默认选择1
IP_CHOICE=${IP_CHOICE:-1}

# 选择公网 IP 地址
if [ "$IP_CHOICE" -eq 1 ]; then
    PUBLIC_IP=$PUBLIC_IP_V4
    # 设置第二个变量为“空”
    VALUE=""
elif [ "$IP_CHOICE" -eq 2 ]; then
    PUBLIC_IP=$PUBLIC_IP_V6
    # 设置第二个变量为 "[::]:"
    VALUE="[::]:"
else
    echo "无效选择，退出脚本"
    exit 1
fi
}
xray_config() {
# 配置文件生成
mkdir -p /etc/xrayls
cat <<EOF > /etc/xrayls/config.json
{
    "log": {
        "disabled": false,
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": 9999,
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
                    "path": "${WS_PATH}"
                }
            }
        },
        {
           "listen": "127.0.0.1",
            "port": 9998,
            "tag": "VEESS-WS",
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
                    "path": "${WS_PATH1}"
                }
            }
        },
        
      
        {
          "listen": "0.0.0.0",
          "port": $port,
          "protocol": "vless",
          "settings": {
              "clients": [
                  {
                      "id": "$UUID",
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
                  "dest": "$dest_server:443",
                  "xver": 0,
                  "serverNames": [
                      "$dest_server"
                  ],
                  "privateKey": "$(cat /usr/local/etc/xray/privatekey)",
                  "minClientVer": "",
                  "maxClientVer": "",
                  "maxTimeDiff": 0,
                  "shortIds": [
                  "$short_id"
                  ]
              }
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

# 重载systemd服务配置
sudo systemctl daemon-reload
sudo systemctl enable xrayls
sudo systemctl restart xrayls || { echo "重启 xrayls 服务失败"; exit 1; }
}
OUTPUTyaml() {
# 保存信息到文件
OUTPUT_DIR="/root/catmi/xrayls"
mkdir -p "$OUTPUT_DIR"
cat << EOF > /root/catmi/xrayls/clash-meta.yaml
- name: Reality
  port:  $port
  server: "$PUBLIC_IP"
  type: vless
  network: tcp
  udp: true
  tls: true
  servername: "$dest_server"
  skip-cert-verify: true
  reality-opts:
    public-key: $(cat /usr/local/etc/xray/publickey)
    short-id: $short_id
  uuid: "$UUID"
  flow: xtls-rprx-vision
  client-fingerprint: chrome
EOF

{
    echo "xray 安装完成！"
    echo "服务器地址：${PUBLIC_IP}"
    echo "端口：${PORT}"
    echo "UUID：${UUID}"
    echo "vless WS 路径：${WS_PATH}"
    echo "vmess WS 路径：${WS_PATH1}"
    
    echo "配置文件已保存到：/etc/xrayls/config.json"
} > "$OUTPUT_DIR/install_info.txt"

print_info "xray 安装完成！"
print_info "服务器地址：${PUBLIC_IP}"
print_info "端口：${PORT}"
print_info "UUID：${UUID}"
print_info "配置文件已保存到：/etc/xrayls/config.json"
# 生成分享链接
share_link="
vless://$UUID@${PUBLIC_IP}:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=chrome&pbk=$(cat /usr/local/etc/xray/publickey)&sid=$short_id&type=tcp&headerType=none#Reality
vless://$UUID@$DOMAIN_LOWER:443?encryption=none&security=tls&sni=$DOMAIN_LOWER&allowInsecure=1&type=ws&host=$DOMAIN_LOWER&path=${WS_PATH}#vless-ws-argo
vmess://$UUID@$DOMAIN_LOWER:443?encryption=none&security=tls&sni=$DOMAIN_LOWER&allowInsecure=1&type=ws&host=$DOMAIN_LOWER&path=${WS_PATH1}#vmess-ws-argo

"
echo "${share_link}" > /root/catmi/xray.txt

sudo systemctl status xrayls
}

mkdir -p /root/catmi
xray
input_variables
install_package
check_cloudflared_status
install_cloudflared
login_cloudflared
create_tunnel
run_tunnel
extract_argo_cert
getkey
xray_config
nginx
OUTPUTyaml
cat /root/catmi/xray.txt
