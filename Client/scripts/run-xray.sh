#!/usr/bin/env bash
# 由 xray-client.service 调用。唯一实例，同时提供两个 LAN 入站：
#   SOCKS :1080   +   HTTP :10809（+ loopback HTTP :10808）
#
# Browser Dialer 是"出站的一种拨号方式"，与入站无关。是否带 XRAY_BROWSER_DIALER
# **由当前节点的开关决定**，而不是无条件带上：
#
#   * 该节点要用浏览器（use_browser=on，或默认且协议支持）-> 带上，TLS 交给 Chromium；
#   * 该节点不用浏览器（use_browser=off）-> **不带**，Xray 自己完成 TLS。
#
# 为什么必须这样：只要进程带着这个环境变量，xhttp/websocket 出站就会被交给浏览器，
# 而 browser_dialer.dialTask() 是 `conn = <-conns` —— **没有超时**。Chromium 一停，
# 那些节点不会报错、不会回退，而是永久挂住。
# 所以"关掉浏览器"必须同时让进程不再声明这个能力，否则用户根本关不掉（实测踩过）。
#
# 其他节点（tcp / reality / hysteria2 …）本来就会忽略该变量，带不带都一样。
set -euo pipefail

PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
DIST="$PREFIX/xbd-dist"
XRAY="$PREFIX/bin/xray"

[ -x "$XRAY" ] || { echo "缺少 Xray 二进制: $XRAY" >&2; exit 1; }
NODE="$PREFIX/nodes/current"
[ -e "$NODE" ] || { echo "尚未选择节点：先用 xbd node add \"<uri>\"" >&2; exit 1; }

cfg() { awk -F= -v k="^$1=" '$0 ~ k {print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true; }
PORT_NORMAL=$(cfg PORT_NORMAL);     PORT_NORMAL=${PORT_NORMAL:-1080}
PORT_HTTP=$(cfg PORT_HTTP);         PORT_HTTP=${PORT_HTTP:-10808}
PORT_LAN_HTTP=$(cfg PORT_LAN_HTTP); PORT_LAN_HTTP=${PORT_LAN_HTTP:-10809}
LISTEN_ADDR=$(cfg LISTEN_ADDR);     LISTEN_ADDR=${LISTEN_ADDR:-127.0.0.1}
DIALER_ADDR=$(cfg DIALER_ADDR);     DIALER_ADDR=${DIALER_ADDR:-127.0.0.1:18081}

# 这个节点是否要用浏览器 —— 判定只有 compat.py 一个来源，三处（本脚本、
# health-check.sh、actions.sh）共用，避免各判各的导致"该不该跑 Chromium"打架。
WANT_BD=$(python3 "$DIST/lib/compat.py" want-bd "$NODE" 2>/dev/null || echo no)
[ "$WANT_BD" = "yes" ] || WANT_BD=no

mkdir -p "$PREFIX/runtime" "$PREFIX/logs"
OUT="$PREFIX/runtime/xray-client.json"

python3 "$DIST/lib/genconfig.py" \
  --node "$NODE" --output "$OUT" --mode normal \
  --listen "$LISTEN_ADDR" \
  --port-normal "$PORT_NORMAL" \
  --http-port "$PORT_HTTP" --lan-http-port "$PORT_LAN_HTTP" \
  --api-port "${XBD_API_PORT:-18085}" \
  --logs "$PREFIX/logs" --loglevel "${XBD_LOGLEVEL:-warning}" >/dev/null

# 校验失败绝不启动：宁可起不来，也不带着坏配置上线
"$XRAY" run -test -config "$OUT" >/dev/null 2>&1 \
  || { echo "生成的配置未通过校验: $OUT" >&2; exit 1; }

if [ "$WANT_BD" = "yes" ]; then
  export XRAY_BROWSER_DIALER="$DIALER_ADDR"
  echo "browser-dialer: 启用（该节点使用浏览器完成 TLS）" >&2
else
  echo "browser-dialer: 关闭（该节点由 Xray 自己完成 TLS）" >&2
fi
exec "$XRAY" run -config "$OUT"
