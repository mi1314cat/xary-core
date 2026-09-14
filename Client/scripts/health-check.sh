#!/usr/bin/env bash
# 心跳自愈。是否带 XRAY_BROWSER_DIALER 由当前节点的开关决定，所以"该在线时 Chromium 必须在线"。
#
# 两条职责：
#   1. 当前节点需要浏览器拨号、但 Chromium 没在跑 -> **启动**它。
#      只做 restart 是不够的：单元停了之后 restart 治不了，表现为
#      「面板一切正常，但那个节点永远拨号失败」—— 实测踩过。
#   2. Chromium 在线、Xray 在监听、却一条 WS 都没有 -> 重启它。
#      原因：Xray 每次启动都会换 CSRF token，而官方内嵌页面只重试 socket、
#      不重载自己，所以 Xray 重启后浏览器必须整个重启。
#
# 节点不需要浏览器时不折腾它：停着是正常状态，不该被拉起。
set -uo pipefail
U_XRAY="xray-client.service"
U_CHROMIUM="chromium-browser-dialer.service"
PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"

ADDR=$(awk -F= '/^DIALER_ADDR=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null)
ADDR=${ADDR:-127.0.0.1:18081}

systemctl is-active --quiet "$U_XRAY" || exit 0
ss -tlnH 2>/dev/null | grep -q ":${ADDR##*:}" || exit 0   # Xray 没在监听 -> 不是浏览器的问题

# 要不要浏览器：唯一判定入口在 compat.py（与 run-xray.sh 同一套语义）
need_bd() {
  [ "$(python3 "$PREFIX/xbd-dist/lib/compat.py" want-bd "$PREFIX/nodes/current" 2>/dev/null)" = "yes" ]
}

if ! systemctl is-active --quiet "$U_CHROMIUM"; then
  need_bd || exit 0
  logger -t xbd-health "当前节点依赖浏览器拨号但 $U_CHROMIUM 未运行，正在启动"
  systemctl start "$U_CHROMIUM" 2>/dev/null || true
  exit 0
fi

ss -tnH 2>/dev/null | grep -q "$ADDR" && exit 0           # 已有 WS 连接 -> 健康
need_bd || exit 0
logger -t xbd-health "BD 通道无 WS 连接，重启 $U_CHROMIUM"
systemctl restart "$U_CHROMIUM" 2>/dev/null || true
