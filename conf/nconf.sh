nx_inbounds() {
cat <<EOF > "$INSTALL_DIR/conf/01.json"
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
vless://${UUID}@${link_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_server}&fp=chrome&pbk=$(cat /usr/local/etc/xray/publickey)&sid=${short_id}&type=tcp&headerType=none#Reality
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
}
n_meta() {

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

}
INSTALL_DIR="/root/catmi/xray"
ENV_FILE="$INSTALL_DIR/install_info.env"
load_env() {
    if [ -f "$ENV_FILE" ]; then
        # 检查 env 文件格式是否正确
        if grep -qEv '^[A-Za-z_][A-Za-z0-9_]*=".*"$' "$ENV_FILE"; then
            echo "⚠ env 文件格式异常：$ENV_FILE"
            return 1
        fi

        # 安全加载
        set -a
        source "$ENV_FILE"
        set +a
        echo "已加载 env：$ENV_FILE"
    else
        echo "env 文件不存在：$ENV_FILE"
    fi
}
nx_inbounds
out_conf
n_meta
