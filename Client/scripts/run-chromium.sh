#!/usr/bin/env bash
# Browser Dialer 的运行时依赖：只负责把官方内嵌页面加载起来并常驻，
# 真实的 TLS/HTTP 由它完成。不需要 Xvfb：headless Chromium 已端到端验证。
# 唯一实例始终带 XRAY_BROWSER_DIALER，所以本服务是常驻依赖（约 255MB）。
set -euo pipefail
PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
ENVF="$PREFIX/config/chromium.env"

CHROMIUM_MODE="headless"
CHROMIUM_DISPLAY=":99"
CHROMIUM_EXTRA_ARGS="--no-sandbox"
[ -f "$ENVF" ] && . "$ENVF"

# 地址来源：ports.env 的 DIALER_ADDR —— 与 run-xray.sh 读的是同一个值。
# 之前这里写死了 127.0.0.1:18081，导致改了 ports.env 之后
# Chromium 还连旧端口 —— 一条 WS 都连不上，代理静默失效。
DIALER_ADDR=$(awk -F= '/^DIALER_ADDR=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true)
DIALER_ADDR="${DIALER_ADDR:-${BROWSER_DIALER_ADDR:-127.0.0.1:18081}}"

echo "chromium 将连接 dialer 通道: http://$DIALER_ADDR/"

BROWSER=""
for c in chromium chromium-browser google-chrome google-chrome-stable; do
  command -v "$c" >/dev/null 2>&1 && { BROWSER=$(command -v "$c"); break; }
done
[ -n "$BROWSER" ] || { echo "找不到 Chromium/Chrome" >&2; exit 1; }

PROFILE="$PREFIX/runtime/chromium-profile"
mkdir -p "$PROFILE" "$PREFIX/logs"

# 预置 Secure DNS：Chromium 的 ECH 依赖它，而现代 Chromium 已移除相关命令行开关。
#
# ⚠ 血泪教训（2026-09-14，本机真实事故）：不要在这里加"DoH 预检"或
#   `--host-resolver-rules` 钉 IP 那类自作聪明的加固。我加过一次，结果是：
#   预检通过 → mode=secure + 把 dns.alidns.com 钉到几个 IP → 之后 DoH 一旦不可用，
#   Chromium **拒绝解析任何域名**（secure 模式不允许回退到系统 DNS）→
#   连节点域名都解析不出来 → 整个拨号链路死掉，三个入口全部 SSL_ERROR_SYSCALL。
#   而且它"看起来"是好的：端口在听、服务 active、WS 也连着，只是全部拨号失败。
#   恢复办法是把 profile 改回 automatic 并重启 Chromium。
#
# 保留 `secure`（ECH 需要它），但**不加任何额外加固**：secure 模式下 DoH 不可用时
# Chromium 自身会有超时与重试语义，比我们手工钉 IP 更可靠。
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
# ⚠ 防复发守卫：这一行**不是**死代码，别删。
# 曾经有过一版在这里写 .doh_hosts（把 DoH 域名用 --host-resolver-rules 钉到固定 IP），
# 那版会在"IPv6 优先 + secure DoH"时让 Chromium 拒绝解析任何域名，直接搞挂整个代理。
# 只要这个文件还在，任何旧版脚本/手工残留都会把 --host-resolver-rules 拼回命令行，
# 所以每次启动都主动清掉。要动这一行之前，先读上面那段事故记录。
rm -f "$PROFILE/.doh_hosts"

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
