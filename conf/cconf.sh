# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

cx_inbounds() {

cat <<EOF > "$INSTALL_DIR/conf/01.json"
 
 {

  "log": {
    "access": "$INSTALL_DIR/log/access.log",
    "error": "$INSTALL_DIR/log/error.log",
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
         "listen": "0.0.0.0",
         "port": ${PORT},
         "protocol": "vless",
         "settings": {
            "clients": [
               {
                  "email": "vision-user",
                  "flow": "xtls-rprx-vision",
                  "id": "${UUID}",
                  "level": 0
               },
               {
                  "email": "xhttp-user",
                  "id": "${UUID2}",
                  "level": 0
               }
            ],
            "decryption": "none",
            "fallbacks": [
               {
                  "dest": "/run/xray/xhttp_in.sock",
                  "xver": 0
               }
            ]
         },
         "streamSettings": {
            "network": "raw",
            "realitySettings": {
               "privateKey": "$(cat /usr/local/etc/xray/privatekey)",
               "serverNames": [
                  "${DOMAIN_LOWER}",
                  "${RDOMAIN_LOWE}"
               ],
               "shortIds": [
                  "${short_id}"
               ],
               "show": false,
               "target": "/run/xray/tls_gate.sock",
               "xver": 0
            },
            "security": "reality",
            "sockopt": {
               "tcpcongestion": "bbr",
               "tcpFastOpen": true,
               "tcpMptcp": true,
               "tcpNoDelay": true
            }
         },
         "tag": "REALITY_INBOUND"
      },
      {
         "listen": "/run/xray/xhttp_in.sock,0666",
         "protocol": "vless",
         "settings": {
            "clients": [
               {
                  "email": "xhttp-user",
                  "id": "${UUID2}",
                  "level": 0
               }
            ],
            "decryption": "none"
         },
         "streamSettings": {
            "network": "xhttp",
            "xhttpSettings": {
               "extra": {
                  "noSSEHeader": true,
                  "scMaxEachPostBytes": 1000000,
                  "xPaddingBytes": "100-1000"
               },
               "host": "",
               "mode": "auto",
               "path": "${WS_PATH2}"
            }
         },
         "tag": "XHTTP_INBOUND"
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
 
}

# ================= 输出 =================
out_conf() {
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
vless://${UUID}@${link_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN_LOWER}&fp=chrome&pbk=$(cat /usr/local/etc/xray/publickey)&sid=${short_id}&type=tcp&headerType=none#Reality
vless://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&allowInsecure=1&type=ws&host=${DOMAIN_LOWER}&path=${WS_PATH1}#vless-ws-tls
vmess://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&allowInsecure=1&type=ws&host=${DOMAIN_LOWER}&path=${WS_PATH}#vmess-ws-tls
vless://${UUID}@${DOMAIN_LOWER}:443?encryption=none&security=tls&sni=${DOMAIN_LOWER}&type=xhttp&host=${DOMAIN_LOWER}&path=${WS_PATH2}&mode=auto#vless-xhttp-tls
"
echo "${share_link}" > "$INSTALL_DIR/v2ray.txt"




}
c_meta() {
cat << EOF > "$INSTALL_DIR/clash-meta.yaml"

proxies:
  - name: 出站1-XTLS+Reality
    type: vless
    server: "${PUBLIC_IP}"
    port: 443
    uuid: ${UUID}
    encryption: none
    flow: xtls-rprx-vision
    network: tcp
    tls: true
    alpn:
      - h2
    servername: "${RDOMAIN_LOWE}"
    client-fingerprint: chrome
    reality-opts:
      public-key: $(cat /usr/local/etc/xray/publickey)
      short-id: ${short_id}
  - name: 出站2-xhttp+Reality
    type: vless
    server: "${PUBLIC_IP}"
    port: 443
    uuid: ${UUID2}
    encryption: none
    flow: ""
    network: xhttp
    tls: true
    alpn:
      - h2
    servername: "${RDOMAIN_LOWE}"
    client-fingerprint: chrome
    reality-opts:
      public-key:  $(cat /usr/local/etc/xray/publickey)
      short-id: ${short_id}
    xhttp-opts:
      path: ${WS_PATH2}
      mode: auto
      reuse-settings:
        max-concurrency: 16-32
        c-max-reuse-times: "0"
        h-max-reusable-secs: 1800-3000
  - name: 出站3-cdn上行+xhttp下行
    type: vless
    server: ${DOMAIN_LOWER}
    port: 443
    uuid: ${UUID2}
    encryption: none
    flow: ""
    network: xhttp
    tls: true
    alpn:
      - h2
    servername: ${DOMAIN_LOWER}
    client-fingerprint: chrome
    skip-cert-verify: true
    xhttp-opts:
      host: ${DOMAIN_LOWER}
      path: ${WS_PATH2}
      mode: auto
      reuse-settings:
        max-concurrency: 16-32
        c-max-reuse-times: "0"
        h-max-reusable-secs: 1800-3000
      download-settings:
        server: ${PUBLIC_IP}
        port: 443
        servername: "${RDOMAIN_LOWE}"
        reality-opts:
          public-key:  $(cat /usr/local/etc/xray/publickey)
          short-id: ${short_id}
        reuse-settings:
          max-concurrency: 16-32
          c-max-reuse-times: "0"
          h-max-reusable-secs: 1800-3000
  - name: 出站4-cdn上下行
    type: vless
    server: ${DOMAIN_LOWER}
    port: 443
    uuid: ${UUID2}
    encryption: none
    flow: ""
    network: xhttp
    tls: true
    alpn:
      - h2
    servername: ${DOMAIN_LOWER}
    client-fingerprint: chrome
    skip-cert-verify: true
    xhttp-opts:
      host: ${DOMAIN_LOWER}
      path: ${WS_PATH2}
      mode: auto
      reuse-settings:
        max-concurrency: 16-32
        c-max-reuse-times: "0"
        h-max-reusable-secs: 1800-3000
  - name: 出站5-上xhttp+Reality下xhttp+TLS+CDN
    type: vless
    server: "${PUBLIC_IP}"
    port: 443
    uuid: ${UUID2}
    encryption: none
    flow: ""
    network: xhttp
    tls: true
    alpn:
      - h2
    servername: "${RDOMAIN_LOWE}"
    client-fingerprint: chrome
    skip-cert-verify: true
    reality-opts:
      public-key:  $(cat /usr/local/etc/xray/publickey)
      short-id: ${short_id}
    xhttp-opts:
      host: ${DOMAIN_LOWER}
      path: ${WS_PATH2}
      mode: auto
      reuse-settings:
        max-concurrency: 16-32
        c-max-reuse-times: "0"
        h-max-reusable-secs: 1800-3000
      download-settings:
        path: ${WS_PATH2}
        host: ""
        server: ${DOMAIN_LOWER}
        port: 443
        tls: true
        alpn:
          - h2
        servername: ${DOMAIN_LOWER}
        client-fingerprint: chrome
        skip-cert-verify: true
        reality-opts:
          public-key: ""
        reuse-settings:
          max-concurrency: 16-32
          c-max-reuse-times: "0"
          h-max-reusable-secs: 1800-3000

EOF

}
INSTALL_DIR="/root/catmi/xray"
ENV_FILE="$INSTALL_DIR/install_info.env"
load_env() {
    local env_file="${1:-$ENV_FILE}"

    # 1. 检查文件是否存在
    if [ ! -f "$env_file" ]; then
        echo "错误：env 文件不存在 -> $env_file"
        return 1
    fi

    # 2. 逐行读取
    while IFS= read -r line || [ -n "$line" ]; do
        # 去除 Windows 换行符 (CRLF)
        line="${line%$'\r'}"

        # 3. 跳过空行、空白行、注释行
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue

        # 4. 必须包含 =
        if [[ "$line" != *=* ]]; then
            echo "警告：跳过无效行（缺少 '='）：$line"
            continue
        fi

        # 5. 拆分 key=value（只分第一个 =）
        key="${line%%=*}"
        value="${line#*=}"

        # 6. trim 空格
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        # 7. 校验 key
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "错误：非法的变量名 -> $key"
            return 1
        fi

        # 8. 必须是 "value" 格式
        if [[ ! "$value" =~ ^\".*\"$ ]]; then
            echo "错误：变量 $key 的值必须包含在双引号内 -> $value"
            return 1
        fi

        # 去掉外层引号
        value="${value:1:-1}"

        # 9. 反转义（顺序非常重要）
        value="${value//\\\\/\\}"   # \\ -> \
        value="${value//\\\"/\"}"   # \" -> "
        value="${value//\\\$/\$}"   # \$ -> $

        # 10. 设置变量
        printf -v "$key" '%s' "$value"
        export "$key"

    done < "$env_file"

    echo "成功：已安全加载环境配置文件 $env_file"
}

load_env
cx_inbounds
out_conf
c_meta
