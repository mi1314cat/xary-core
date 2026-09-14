#!/usr/bin/env bash
# 基础层：常量、输出、环境探测、通用工具。
# 被 bin/xbd 与其它模块 source；不要直接执行。
set -euo pipefail

# ------------------------------------------------------------------ 常量 ----
: "${XBD_PREFIX:=/opt/xray-browser-dialer}"

XBD_BIN="$XBD_PREFIX/bin"
XBD_LIB="$XBD_PREFIX/lib"
XBD_CONF="$XBD_PREFIX/config"
XBD_NODES="$XBD_PREFIX/nodes"
XBD_RUNTIME="$XBD_PREFIX/runtime"
XBD_LOGS="$XBD_PREFIX/logs"
XBD_GENERATED="$XBD_PREFIX/generated"
XBD_BACKUP="$XBD_PREFIX/backup"
XBD_SCRIPTS="$XBD_PREFIX/scripts"
XBD_SERVICE="$XBD_PREFIX/service"

XBD_XRAY="$XBD_BIN/xray"
XBD_APK="$XBD_PREFIX/xbd.apk"          # 自解压载荷（单文件分发时用）
XBD_DIST="$XBD_PREFIX/xbd-dist"        # 解压后的脚本目录（自解压版）

# 端口规划（详见 README.md 的架构要点）
XBD_PORT_NORMAL="${XBD_PORT_NORMAL:-1080}"        # 唯一 Xray 实例 → LAN（SOCKS5）
XBD_PORT_HTTP="${XBD_PORT_HTTP:-10808}"           # 本机 HTTP 代理（docker/apt/curl，仅回环）
XBD_PORT_LAN_HTTP="${XBD_PORT_LAN_HTTP:-10809}"   # 局域网 HTTP 代理（WiFi 设置里填）
XBD_DIALER_ADDR="${XBD_DIALER_ADDR:-127.0.0.1:18081}"  # Xray↔Chromium 通道
XBD_PANEL_PORT="${XBD_PANEL_PORT:-18090}"
XBD_PANEL_HOST_DEFAULT="127.0.0.1"

# systemd 单元
XBD_U_XRAY="xray-client.service"                  # 唯一实例：SOCKS+HTTP，Browser Dialer 常备
XBD_U_CHROMIUM="chromium-browser-dialer.service" # Browser Dialer 的运行时依赖
XBD_U_PANEL="browser-dialer-panel.service"
XBD_U_HEALTH="browser-dialer-health.service"
XBD_U_TIMER="browser-dialer-health.timer"

XBD_XRAY_REPO="XTLS/Xray-core"
XBD_IMPL="Xray Browser Dialer（XRAY_BROWSER_DIALER + 真实 Chromium）"

# 脚本根目录：多文件版直接跑时就是项目根；自解压版则是 xbd-dist。
xbd_dist_dir() {
  if [ -d "$XBD_ROOT/lib" ] && [ -f "$XBD_ROOT/lib/actions.sh" ]; then
    printf '%s' "$XBD_ROOT"
  else
    printf '%s' "$XBD_DIST"
  fi
}

# ------------------------------------------------------------------ 输出 ----
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi
info()  { printf '%s\n' "$*"; }
dim()   { printf '%s%s%s\n' "$C_D" "$*" "$C_0"; }
ok()    { printf '%s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '%s!%s %s\n' "$C_Y" "$C_0" "$*"; }
bad()   { printf '%s✗%s %s\n' "$C_R" "$C_0" "$*"; }
step()  { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
die()   { printf '%s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
ask()   { local p="$1" d="${2:-}"; local a; read -r -p "$p" a; printf '%s' "${a:-$d}"; }

need_root() { [ "$(id -u)" -eq 0 ] || die "需要 root 权限（当前 uid=$(id -u)）"; }

# -------------------------------------------------------------- 环境探测 ----
detect_lan_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
  [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "$ip"
}

detect_browser() {
  local c
  for c in chromium chromium-browser google-chrome google-chrome-stable; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s' "$(command -v "$c")"; return 0; }
  done
  return 1
}
browser_version() {
  local b; b=$(detect_browser) || { printf '未安装'; return; }
  "$b" --version 2>/dev/null | head -1
}

has_systemd() { [ -d /run/systemd/system ]; }

port_holder() { ss -H -tlnp 2>/dev/null | awk -v p=":$1\$" '$4 ~ p {print $NF; exit}'; }
port_in_use() { [ -n "$(port_holder "$1")" ]; }
port_listening_tcp() { ss -H -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
conn_count() { ss -tnH 2>/dev/null | grep -c "$1" || true; }

unit_active()  { systemctl is-active  --quiet "$1" 2>/dev/null; }
unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }
unit_state()   { systemctl is-active "$1" 2>/dev/null || echo unknown; }

# ------------------------------------------------------------ 配置读取 ----
cfg_get() {  # cfg_get <file> <key> [default]
  local f="$1" k="$2" d="${3:-}"
  [ -f "$f" ] || { printf '%s' "$d"; return; }
  local v; v=$(awk -F= -v key="$k" '$1==key{sub(/^[^=]*=/,""); print; exit}' "$f" 2>/dev/null || true)
  printf '%s' "${v:-$d}"
}
cfg_set() {  # cfg_set <file> <key> <value>  幂等写入
  local f="$1" k="$2" v="$3"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || : > "$f"
  if grep -q "^$k=" "$f" 2>/dev/null; then
    sed -i "s|^$k=.*|$k=$v|" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

# 运行期端口/地址（允许用户在 config/ports.env 覆盖）
xbd_load_ports() {
  local f="$XBD_CONF/ports.env"
  XBD_PORT_NORMAL=$(cfg_get "$f" PORT_NORMAL "$XBD_PORT_NORMAL")
    XBD_DIALER_ADDR=$(cfg_get "$f" DIALER_ADDR "$XBD_DIALER_ADDR")
  XBD_PORT_HTTP=$(cfg_get "$f" PORT_HTTP "$XBD_PORT_HTTP")
  XBD_PORT_LAN_HTTP=$(cfg_get "$f" PORT_LAN_HTTP "$XBD_PORT_LAN_HTTP")
  XBD_LISTEN_ADDR=$(cfg_get "$f" LISTEN_ADDR "$(detect_lan_ip)")
  XBD_PANEL_HOST=$(cfg_get "$XBD_CONF/panel.env" PANEL_HOST "$XBD_PANEL_HOST_DEFAULT")
  XBD_PANEL_PORT=$(cfg_get "$XBD_CONF/panel.env" PANEL_PORT "$XBD_PANEL_PORT")
  XBD_PANEL_TOKEN=$(cfg_get "$XBD_CONF/panel.env" PANEL_TOKEN "")
  export XBD_PORT_NORMAL XBD_PORT_HTTP XBD_PORT_LAN_HTTP XBD_DIALER_ADDR XBD_LISTEN_ADDR \
         XBD_PANEL_HOST XBD_PANEL_PORT XBD_PANEL_TOKEN
}

xbd_panel_url() { printf 'http://%s:%s/' "${XBD_PANEL_HOST:-127.0.0.1}" "${XBD_PANEL_PORT:-18090}"; }

# -------------------------------------------------------------- 节点工具 ----
node_field() {  # node_field <node.json|current> <key> [default]
  python3 - "$1" "$2" "${3:-}" <<'PY' 2>/dev/null || printf '%s' "${3:-}"
import json, sys, os
p = sys.argv[1]
if not os.path.exists(p):
    print(sys.argv[3]); raise SystemExit
try:
    d = json.load(open(p))
except Exception:
    print(sys.argv[3]); raise SystemExit
v = d.get(sys.argv[2])
print("" if v is None else v)
PY
}

current_node_file() {
  [ -e "$XBD_NODES/current" ] || return 1
  readlink -f "$XBD_NODES/current"
}

require_current_node() {
  local f
  f=$(current_node_file) || die "尚未选择节点。用: xbd node add \"<uri>\""
  [ -s "$f" ] || die "节点文件为空: $f"
  printf '%s' "$f"
}

# ---------------------------------------------------------------- 依赖 ----
xbd_check_deps() {
  local missing=()
  local c
  for c in curl python3 ss ip systemctl awk; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [ ${#missing[@]} -eq 0 ] || die "缺少命令: ${missing[*]}"
}
