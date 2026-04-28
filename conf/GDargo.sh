#!/bin/bash
# ============================================================
#  xrayls - Argo + VLESS-WS + ML-KEM PQ 自动生成器（专业优化版）
# ============================================================

BASE_DIR="/root/catmi/xray"
CONF_DIR="$BASE_DIR/conf"
OUT_DIR="$BASE_DIR/out"
STATE_DIR="$BASE_DIR/state"
mkdir -p "$CONF_DIR" "$OUT_DIR" "$STATE_DIR"

xrayls_DTR="$BASE_DIR/xrayls"
XRAY_CONF="$CONF_DIR/argo.json"
STATE_FILE="$STATE_DIR/argo_state.env"

# -----------------------------
# 生成随机 WS path / UUID
# -----------------------------
gen_path() { echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"; }
gen_uuid() { cat /proc/sys/kernel/random/uuid; }

WS_PATH9970=$(gen_path)
UUID9970=$(gen_uuid)

# -----------------------------
# 生成 ML-KEM PQ 加密串（最终稳定版）
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
# 写入 Xray 配置（Vision + ML-KEM）
# -----------------------------
cat > "$XRAY_CONF" <<EOF
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 9970,
      "tag": "vless-GDargo",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID9970}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${SERVER_DEC}"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH9970}"
        }
      }
    }
  ]
}
EOF

# -----------------------------
# 加载环境模块
# -----------------------------
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")

update_env "$CATMIENV_FILE" mode xray

# -----------------------------
# Argo 域名（你目前注释掉）
# -----------------------------
 bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/url_argo.sh)
 load_env "$CATMIENV_FILE"
 if [[ -z "$uargo_domain" ]]; then
     echo "错误：未获取到 Argo 域名"
     exit 1
 fi

# -----------------------------
# 生成分享链接（带 ML-KEM PQ）
# -----------------------------
SHARE="vless://${UUID9970}@${uargo_domain}:443?flow=xtls-rprx-vision&security=tls&sni=${uargo_domain}&type=ws&host=${uargo_domain}&path=${WS_PATH9970}&encryption=${CLIENT_ENC}#vless-ws-argo-mlkem"

echo "$SHARE" > "$OUT_DIR/GDargo.txt"

# -----------------------------
# 写入状态文件（可追踪）
# -----------------------------
cat > "$STATE_FILE" <<EOF
UUID="${UUID}"
WS_PATH="${WS_PATH}"
ARGO_DOMAIN="${uargo_domain}"
SERVER_DEC="${SERVER_DEC}"
CLIENT_ENC="${CLIENT_ENC}"
XRAY_CONF="${XRAY_CONF}"
EOF

echo "Argo + Xray ML-KEM PQ 节点生成完成"
echo "配置文件：$XRAY_CONF"
echo "分享链接：$OUT_DIR/GDargo.txt"
echo "状态文件：$STATE_FILE"
