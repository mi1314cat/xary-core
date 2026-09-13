#!/usr/bin/env bash
# 由 xray-client.service / xray-dialer.service 调用。
#   run-xray.sh normal   常驻实例：普通代理
#   run-xray.sh dialer   按需实例：Browser Dialer（TLS 交给 Chromium）
# 生成配置 → 校验 → exec Xray。两种模式生成**不同**配置，互不影响。
set -euo pipefail

MODE="${1:-normal}"
case "$MODE" in normal|dialer) ;; *) echo "用法: run-xray.sh normal|dialer" >&2; exit 2 ;; esac

PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
DIST="$PREFIX/xbd-dist"
XRAY="$PREFIX/bin/xray"

[ -x "$XRAY" ] || { echo "缺少 Xray 二进制: $XRAY" >&2; exit 1; }
NODE="$PREFIX/nodes/current"
[ -e "$NODE" ] || { echo "尚未选择节点：先用 xbd node add \"<uri>\"" >&2; exit 1; }

PORT_NORMAL=$(awk -F= '/^PORT_NORMAL=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true)
PORT_HTTP=$(awk -F= '/^PORT_HTTP=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true)
PORT_LAN_HTTP=$(awk -F= '/^PORT_LAN_HTTP=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true)
PORT_DIALER=$(awk -F= '/^PORT_DIALER=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true)
LISTEN_ADDR=$(awk -F= '/^LISTEN_ADDR=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true)
PORT_NORMAL=${PORT_NORMAL:-1080}
PORT_DIALER=${PORT_DIALER:-1081}
PORT_HTTP=${PORT_HTTP:-10808}
PORT_LAN_HTTP=${PORT_LAN_HTTP:-10809}
LISTEN_ADDR=${LISTEN_ADDR:-127.0.0.1}

mkdir -p "$PREFIX/runtime" "$PREFIX/logs"
OUT="$PREFIX/runtime/xray-$MODE.json"

python3 "$DIST/lib/genconfig.py" \
  --node "$NODE" --output "$OUT" --mode "$MODE" \
  --listen "$LISTEN_ADDR" \
  --port-normal "$PORT_NORMAL" --port-dialer "$PORT_DIALER" \
  --http-port "$PORT_HTTP" --lan-http-port "$PORT_LAN_HTTP" \
  --api-port "${XBD_API_PORT:-18085}" \
  --logs "$PREFIX/logs" --loglevel "${XBD_LOGLEVEL:-warning}" >/dev/null

# 校验失败绝不启动：宁可起不来，也不带着坏配置上线
"$XRAY" run -test -config "$OUT" >/dev/null 2>&1 \
  || { echo "生成的配置未通过校验: $OUT" >&2; exit 1; }

exec "$XRAY" run -config "$OUT"
