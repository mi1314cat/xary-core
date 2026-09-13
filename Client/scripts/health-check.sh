#!/usr/bin/env bash
# 心跳自愈。只在 dialer 模式运行时才有意义：
#   Xray 每次启动都会换 CSRF token，页面只重试 socket、不重载自己，
#   所以 Xray(dialer) 重启后浏览器必须跟着重启。
#   若 dialer 模式本来就没开，这里什么都不做 —— 不会把 Chromium 拉起来。
set -uo pipefail
U_DIALER="xray-dialer.service"
U_CHROMIUM="chromium-browser-dialer.service"
DIALER_ADDR="127.0.0.1:18081"

# 未启用 Browser Dialer 模式 -> 直接退出（按需启动的核心保证）
systemctl is-active --quiet "$U_DIALER" || exit 0
systemctl is-active --quiet "$U_CHROMIUM" || exit 0
ss -tlnH 2>/dev/null | grep -q ":${DIALER_ADDR##*:}" || exit 0
ss -tnH 2>/dev/null | grep -q "$DIALER_ADDR" && exit 0

logger -t xbd-health "dialer 模式未同步（无 WS 连接），重启 $U_CHROMIUM"
systemctl restart "$U_CHROMIUM" 2>/dev/null || true
