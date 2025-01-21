#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Alpine")
PACKAGE_UPDATE=("apt -y update" "apt -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove")

[[ $EUID -ne 0 ]] && yellow "请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && red "不支持当前VPS的操作系统，请使用主流的操作系统" && exit 1
if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl
fi
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
                   catmi.argo
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
checkStatus() {
    [[ -z $(cloudflared -help 2>/dev/null) ]] && cloudflaredStatus="未安装"
    [[ -n $(cloudflared -help 2>/dev/null) ]] && cloudflaredStatus="已安装"
    [[ -f /root/.cloudflared/cert.pem ]] && loginStatus="已登录"
    [[ ! -f /root/.cloudflared/cert.pem ]] && loginStatus="未登录"
}

archAffix() {
    case "$(uname -m)" in
        i686 | i386) echo '386' ;;
        x86_64 | amd64) echo 'amd64' ;;
        armv5tel | arm6l | armv7 | armv7l) echo 'arm' ;;
        armv8 | arm64 | aarch64) echo 'aarch64' ;;
        *) red "不支持的CPU架构！" && exit 1 ;;
    esac
}
installCloudFlared() {
    # 检查是否已安装 cloudflared
    [[ $cloudflaredStatus == "已安装" ]] && red "检测到已安装并登录CloudFlare Argo Tunnel，无需重复安装！！" && exit 1
    
    # 获取最新版本
    last_version=$(curl -Ls "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z $last_version ]]; then
    	red "检测 cloudflared 版本失败，可能是超出 Github API 限制，请稍后再试"
	exit 1
    fi
    
    # 判断 CPU 架构，适配 arm64
    arch=$(archAffix)
    if [[ "$arch" == "aarch64" ]]; then
        arch="arm64"  # 统一使用 arm64
    fi

    # 下载 Cloudflared 二进制文件
    wget -N --no-check-certificate https://github.com/cloudflare/cloudflared/releases/download/$last_version/cloudflared-linux-$arch -O /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
    checkStatus
    
    # 检查安装状态
    if [[ $cloudflaredStatus == "已安装" ]]; then
    	green "CloudFlare Argo Tunnel 已安装成功！"
    	back2menu
    else
        red "CloudFlare Argo Tunnel 安装失败！"
        back2menu
    fi
}


loginCloudFlared(){
    [[ $loginStatus == "已登录" ]] && red "检测到已登录CloudFlare Argo Tunnel，无需重复登录！！" && exit 1
    cloudflared tunnel login
    checkStatus
    if [[ $cloudflaredStatus == "未登录" ]]; then
        red "登录CloudFlare Argo Tunnel账户失败！！"
        back2menu
    else
        green "登录CloudFlare Argo Tunnel账户成功！！"
        back2menu
    fi
}
makeTunnel() {
    read -rp "请设置隧道名称：" tunnelName
    cloudflared tunnel create $tunnelName
    read -rp "请设置隧道域名：" tunnelDomain
    cloudflared tunnel route dns $tunnelName $tunnelDomain
    DOMAIN_LOWER=$tunnelDomain
    cloudflared tunnel list
    # 感谢yuuki410在其分支中提取隧道UUID的代码
    # Source: https://github.com/yuuki410/argo-tunnel-script
    tunnelUUID=$( $(cloudflared tunnel list | grep $tunnelName) = /[0-9a-f\-]+/)
    read -p "请输入隧道UUID（复制ID里面的内容）：" tunnelUUID
    read -p "输入传输协议（默认http）：" tunnelProtocol
    [[ -z $tunnelProtocol ]] && tunnelProtocol="http"
    read -p "输入反代端口：" tunnelPort
    [[ -z $tunnelPort ]] && tunnelPort=${PORT}
    tunnelFileName=CloudFlare
	cat <<EOF > /root/catmi/$tunnelFileName.yml
tunnel: $tunnelName
credentials-file: /root/.cloudflared/$tunnelUUID.json
originRequest:
  connectTimeout: 30s
  noTLSVerify: true
ingress:
  - hostname: $tunnelDomain
    service: $tunnelProtocol://localhost:$tunnelPort
  - service: http_status:404
EOF
    green "配置文件已保存至 /root/catmi/$tunnelFileName.yml"
    back2menu
}

runTunnel() {
    [[ $cloudflaredStatus == "未安装" ]] && red "检测到未安装CloudFlare Argo Tunnel客户端，无法执行操作！！！" && exit 1
    [[ $loginStatus == "未登录" ]] && red "请登录CloudFlare Argo Tunnel客户端后再执行操作！！！" && exit 1
    [[ -z $(type -P screen) ]] && ${PACKAGE_UPDATE[int]} && ${PACKAGE_INSTALL[int]} screen
    
   
    screen -USdm CloudFlare cloudflared tunnel --config /root/catmi/$tunnelFileName.yml run
    green "隧道已运行成功，请等待1-3分钟启动并解析完毕"
    back2menu
}
argoCert() {
    [[ $cloudflaredStatus == "未安装" ]] && red "检测到未安装CloudFlare Argo Tunnel客户端，无法执行操作！！！" && exit 1
    [[ $loginStatus == "未登录" ]] && red "请登录CloudFlare Argo Tunnel客户端后再执行操作！！！" && exit 1
    sed -n "1, 5p" /root/.cloudflared/cert.pem >>/root/private.key
    sed -n "6, 24p" /root/.cloudflared/cert.pem >>/root/cert.crt
    green "CloudFlare Argo Tunnel证书提取成功！"
    yellow "证书crt路径如下：/root/catmi/cert.crt"
    yellow "私钥key路径如下：/root/catmi/private.key"
    green "使用证书提示："
    yellow "1. 当前证书仅限于CF Argo Tunnel隧道授权过的域名使用"
    yellow "2. 在需要使用证书的服务使用Argo Tunnel的域名，必须使用其证书"
    back2menu
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
        location ${WS_PATH2} {
        proxy_request_buffering      off;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:9997;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
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
WS_PATH2=$(generate_ws_path)



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
cat << EOF > /root/catmi/xrayls/xhttp.json
{
    "downloadSettings": {
      "address": "$PUBLIC_IP", 
      "port": $port, 
      "network": "xhttp", 
      "xhttpSettings": {
        "path": "${WS_PATH2}", 
        "mode": "auto"
      },
      "security": "reality", 
      "realitySettings":  {
        "serverName": "$dest_server",
        "fingerprint": "chrome",
        "show": false,
        "publicKey": "$(cat /usr/local/etc/xray/publickey)",
        "shortId": "$short_id",
        "spiderX": ""
      }
    }
  }
EOF
{
    echo "xray 安装完成！"
    echo "服务器地址：${PUBLIC_IP}"
    echo "端口：${PORT}"
    echo "UUID：${UUID}"
    echo "vless WS 路径：${WS_PATH}"
    echo "vmess WS 路径：${WS_PATH1}"
    echo "xhttp 路径：${WS_PATH2}"
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
vless://$UUID@$DOMAIN_LOWER:443?encryption=none&security=tls&sni=$DOMAIN_LOWER&allowInsecure=1&type=ws&host=$DOMAIN_LOWER&path=${WS_PATH1}#vmess-ws-argo
vless://$UUID@$DOMAIN_LOWER:443?encryption=none&security=tls&sni=$DOMAIN_LOWER&type=xhttp&host=$DOMAIN_LOWER&path=${WS_PATH2}&mode=auto#vless-xhttp-argo
"
echo "${share_link}" > /root/catmi/xray.txt

sudo systemctl status xrayls
}
menu() {
   mkdir -p /root/catmi
    echo "执行 input_variables"
    input_variables
    checkStatus
    archAffix
    echo "执行 installCloudFlared"
    installCloudFlared
    echo "执行 loginCloudFlared"
    loginCloudFlared
    echo "执行 makeTunnel"
    makeTunnel
    echo "执行 runTunnel"
    runTunnel
    echo "执行 argoCert"
    argoCert
    echo "执行 xray"
    xray
    echo "执行 getkey"
    getkey
    echo "执行 xray_config"
    xray_config
    echo "执行 nginx"
    nginx
    echo "执行 OUTPUTyaml"
    OUTPUTyaml
}
