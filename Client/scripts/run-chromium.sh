#!/usr/bin/env bash
# Browser Dialer 的运行时依赖。只在 dialer 模式启用时运行。
# 不需要 Xvfb：headless Chromium 已在本机端到端验证。
set -euo pipefail
PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
ENVF="$PREFIX/config/chromium.env"

CHROMIUM_MODE="headless"
CHROMIUM_DISPLAY=":99"
CHROMIUM_EXTRA_ARGS="--no-sandbox"
[ -f "$ENVF" ] && . "$ENVF"

# 地址来源优先级（**不再写死端口**）：
#   1) dialer.env 的 XRAY_BROWSER_DIALER —— 与 Xray 侧同一个值，最可靠
#   2) ports.env 的 DIALER_ADDR
#   3) chromium.env 的 BROWSER_DIALER_ADDR
#   4) 都没有才退回默认值
# 之前这里写死了 127.0.0.1:18081，导致改了 ports.env 之后
# Chromium 还连旧端口 —— 一条 WS 都连不上，代理静默失效。
DIALER_ADDR=""
[ -f "$PREFIX/config/dialer.env" ] && {
  # shellcheck disable=SC1091
  . "$PREFIX/config/dialer.env"
  DIALER_ADDR="${XRAY_BROWSER_DIALER:-}"
}
[ -n "$DIALER_ADDR" ] || DIALER_ADDR=$(awk -F= '/^DIALER_ADDR=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true)
[ -n "$DIALER_ADDR" ] || DIALER_ADDR="${BROWSER_DIALER_ADDR:-}"
[ -n "$DIALER_ADDR" ] || DIALER_ADDR="127.0.0.1:18081"

echo "chromium 将连接 dialer 通道: http://$DIALER_ADDR/"

BROWSER=""
for c in chromium chromium-browser google-chrome google-chrome-stable; do
  command -v "$c" >/dev/null 2>&1 && { BROWSER=$(command -v "$c"); break; }
done
[ -n "$BROWSER" ] || { echo "找不到 Chromium/Chrome" >&2; exit 1; }

PROFILE="$PREFIX/runtime/chromium-profile"
mkdir -p "$PROFILE" "$PREFIX/logs"

# 预置 Secure DNS：Chromium 的 ECH 依赖它，而现代 Chromium 已移除相关命令行开关
python3 - "$PROFILE" <<'PYEOF'
import json, os, sys
prof = sys.argv[1]
doh = os.environ.get("XBD_DOH", "https://dns.alidns.com/dns-query")
os.makedirs(os.path.join(prof, "Default"), exist_ok=True)
cfg = {"dns_over_https": {"mode": "secure", "templates": doh}, "os_crypt": {"encrypted_key": ""}}
open(os.path.join(prof, "Local State"), "w").write(json.dumps(cfg))
open(os.path.join(prof, "Default", "Preferences"), "w").write(json.dumps({
    "profile": {"exit_type": "Normal", "exited_cleanly": True},
    "dns_over_https": {"mode": "secure", "templates": doh}}))
PYEOF

# 崩溃/重启后残留的会话文件会让 Chromium 卡在"恢复页面"
find "$PROFILE" -maxdepth 1 \( -name 'Singleton*' -o -name 'Current Session' -o -name 'Current Tabs' \
  -o -name 'Last Session' -o -name 'Last Tabs' \) -delete 2>/dev/null || true
rm -rf "$PROFILE/Sessions" 2>/dev/null || true

ARGS=(
  --user-data-dir="$PROFILE"
  --disable-dev-shm-usage
  --no-first-run
  --no-default-browser-check
  --disable-background-networking
  --disable-sync
  --disable-features=Translate,OptimizationHints,InfiniteSessionRestore
  --disable-dbus
  --disable-gpu
  --window-size=800,600
  --enable-logging=stderr
  --log-level=0
)

if [ "$CHROMIUM_MODE" = "xvfb" ]; then
  command -v Xvfb >/dev/null 2>&1 || { echo "CHROMIUM_MODE=xvfb 但未安装 Xvfb" >&2; exit 1; }
  DISPLAY="$CHROMIUM_DISPLAY" Xvfb "$CHROMIUM_DISPLAY" -screen 0 1280x1024x24 -nolisten tcp &
  trap 'kill $! 2>/dev/null || true' EXIT
  export DISPLAY
else
  ARGS+=(--headless=new)
fi

# shellcheck disable=SC2086
exec "$BROWSER" "${ARGS[@]}" $CHROMIUM_EXTRA_ARGS "http://${DIALER_ADDR}/"
