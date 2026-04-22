# 打印带颜色的消息
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

cx_inbounds() {

cat <<EOF > "$INSTALL_DIR/conf/caddy.json"
 
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
         "port": ${CRPORT},
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
                  "${CDOMAIN_LOWER}",
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
cat <<EOF > "$ngconfout_DIR/Cxhttp.txt"
{
  "downloadSettings": {
    "address": "${PUBLIC_IP}",
    "port": ${CRPORT},
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
    "address": "${CDOMAIN_LOWER}", 
    "port": 443, 
    "network": "xhttp", 
    "security": "tls", 
    "tlsSettings": {
      "serverName": "${CDOMAIN_LOWER}", 
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
vless://${UUID}@${link_ip}:${CRPORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${CDOMAIN_LOWER}&fp=chrome&pbk=$(cat /usr/local/etc/xray/publickey)&sid=${short_id}&type=tcp&headerType=none#Reality
vless://${UUID}@${CDOMAIN_LOWER}:443?encryption=none&security=tls&sni=${CDOMAIN_LOWER}&allowInsecure=1&type=ws&host=${CDOMAIN_LOWER}&path=${WS_PATH1}#vless-ws-tls
vmess://${UUID}@${CDOMAIN_LOWER}:443?encryption=none&security=tls&sni=${CDOMAIN_LOWER}&allowInsecure=1&type=ws&host=${CDOMAIN_LOWER}&path=${WS_PATH}#vmess-ws-tls
vless://${UUID}@${CDOMAIN_LOWER}:443?encryption=none&security=tls&sni=${CDOMAIN_LOWER}&type=xhttp&host=${CDOMAIN_LOWER}&path=${WS_PATH2}&mode=auto#vless-xhttp-tls
"
echo "${share_link}" > "$ngconfout_DIR/Cv2ray.txt"




}
c_meta() {
cat << EOF > "$ngconfout_DIR/Cclash-meta.yaml"

proxies:
  - name: 出站1-XTLS+Reality
    type: vless
    server: "${PUBLIC_IP}"
    port: ${CRPORT}
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
    port: ${CRPORT}
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
    server: ${CDOMAIN_LOWER}
    port: 443
    uuid: ${UUID2}
    encryption: none
    flow: ""
    network: xhttp
    tls: true
    alpn:
      - h2
    servername: ${CDOMAIN_LOWER}
    client-fingerprint: chrome
    skip-cert-verify: true
    xhttp-opts:
      host: ${CDOMAIN_LOWER}
      path: ${WS_PATH2}
      mode: auto
      reuse-settings:
        max-concurrency: 16-32
        c-max-reuse-times: "0"
        h-max-reusable-secs: 1800-3000
      download-settings:
        server: ${PUBLIC_IP}
        port: ${CRPORT}
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
    server: ${CDOMAIN_LOWER}
    port: 443
    uuid: ${UUID2}
    encryption: none
    flow: ""
    network: xhttp
    tls: true
    alpn:
      - h2
    servername: ${CDOMAIN_LOWER}
    client-fingerprint: chrome
    skip-cert-verify: true
    xhttp-opts:
      host: ${CDOMAIN_LOWER}
      path: ${WS_PATH2}
      mode: auto
      reuse-settings:
        max-concurrency: 16-32
        c-max-reuse-times: "0"
        h-max-reusable-secs: 1800-3000
  - name: 出站5-上xhttp+Reality下xhttp+TLS+CDN
    type: vless
    server: "${PUBLIC_IP}"
    port: ${CRPORT}
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
      host: ${CDOMAIN_LOWER}
      path: ${WS_PATH2}
      mode: auto
      reuse-settings:
        max-concurrency: 16-32
        c-max-reuse-times: "0"
        h-max-reusable-secs: 1800-3000
      download-settings:
        path: ${WS_PATH2}
        host: ""
        server: ${CDOMAIN_LOWER}
        port: 443
        tls: true
        alpn:
          - h2
        servername: ${CDOMAIN_LOWER}
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
ngconfout_DIR="$INSTALL_DIR/out"
ENV_FILE="$INSTALL_DIR/install_info.env"
load_env() {
}

load_env
cx_inbounds
out_conf
c_meta
