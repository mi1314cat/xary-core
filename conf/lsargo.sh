#!/bin/bash

BASE_DIR="/root/catmi/xray"
CONF_DIR="$BASE_DIR/conf"
OUT_DIR="$BASE_DIR/out"
file="$CONF_DIR/lsargo.json"

generate_ws_path() {
    echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

WS_PATH8080=$(generate_ws_path)
UUID8080=$(generate_uuid)

mkdir -p "$CONF_DIR" "$OUT_DIR"

cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 8080,
      "tag": "VLESS-WS",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID8080}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH8080}"
        }
      }
    }
  ]
}
EOF

# 加载环境变量
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

load_env "$CATMIENV_FILE"

# 正确的分享链接
share_link="vless://${UUID8080}@${SD_domain}:443?encryption=none&security=tls&sni=${SD_domain}&allowInsecure=1&type=ws&host=${SD_domain}&path=${WS_PATH8080}#vless-ws-lsargo"

echo "${share_link}" > "$OUT_DIR/lsargo.txt"
