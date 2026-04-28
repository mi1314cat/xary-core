#!/bin/bash

BASE_DIR="/root/catmi/xray"
CONF_DIR="$BASE_DIR/conf"
OUT_DIR="$BASE_DIR/out"
file="$CONF_DIR/lsargo.json"
xrayls_DTR="$BASE_DIR/xrayls"

generate_ws_path() {
    echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

WS_PATH8080=$(generate_ws_path)
UUID8080=$(generate_uuid)

mkdir -p "$CONF_DIR" "$OUT_DIR"

# -----------------------------
# 生成 ML-KEM PQ 加密串（稳定版）
# -----------------------------
if [ ! -x "$xrayls_DTR" ]; then
    echo "错误：未找到 xrayls 可执行文件：$xrayls_DTR"
    exit 1
fi

VLESSENC_OUTPUT=$("$xrayls_DTR" vlessenc 2>/dev/null || true)

if [ -z "$VLESSENC_OUTPUT" ]; then
    echo "错误：xrayls vlessenc 无输出，无法生成 ML-KEM PQ 加密串"
    exit 1
fi

# 换行 → 空格（避免串黏连）
CLEAN_OUTPUT=$(echo "$VLESSENC_OUTPUT" | tr '\n' ' ')

# 取最后一个 decryption（ML-KEM-768）
SERVER_DEC=$(echo "$CLEAN_OUTPUT" | grep -oP '"decryption"\s*:\s*"\K[^"]+' | tail -n 1)

# 取最后一个 encryption（ML-KEM-768）
CLIENT_ENC=$(echo "$CLEAN_OUTPUT" | grep -oP '"encryption"\s*:\s*"\K[^"]+' | tail -n 1)

if [[ -z "$SERVER_DEC" || -z "$CLIENT_ENC" ]]; then
    echo "错误：无法解析 ML-KEM-768 加密串"
    echo "$VLESSENC_OUTPUT"
    exit 1
fi

echo "[Info] ML-KEM 服务端 decryption: $SERVER_DEC"
echo "[Info] ML-KEM 客户端 encryption: $CLIENT_ENC"

# -----------------------------
# 写入 Xray 配置（加入 ML-KEM PQ）
# -----------------------------
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
        "decryption": "${SERVER_DEC}"
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

# -----------------------------
# 加载环境变量
# -----------------------------
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

load_env "$CATMIENV_FILE"

# -----------------------------
# 生成分享链接（加入 ML-KEM PQ）
# -----------------------------
share_link="vless://${UUID8080}@${SD_domain}:443?security=tls&sni=${SD_domain}&type=ws&host=${SD_domain}&path=${WS_PATH8080}&encryption=${CLIENT_ENC}#vless-ws-lsargo-mlkem"

echo "${share_link}" > "$OUT_DIR/lsargo.txt"

echo "[OK] ML-KEM PQ + VLESS-WS 节点生成完成"
echo "配置文件：$file"
echo "分享链接：$OUT_DIR/lsargo.txt"
