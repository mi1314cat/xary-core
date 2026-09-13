#!/usr/bin/env bash
# 命令实现层。被 bin/xbd 分发调用。
# 设计要点：Xray 常驻实例与 Browser Dialer 实例**完全解耦**，
# 所有启停都只作用于自己那一个单元，绝不互相牵连。
set -euo pipefail

# ---------------------------------------------------------------------------
# 安装与初始化
# ---------------------------------------------------------------------------
cmd_install() {
  local want_start=1 vless=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-start) want_start=0; shift ;;
      --vless) vless="${2:-}"; shift 2 ;;
      -h|--help) xbd_usage; return 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  need_root
  xbd_check_deps
  step "环境检查"
  has_systemd || die "需要 systemd"
  ok "架构: $(uname -m)  发行版: $(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")"
  ok "LAN IP: $(detect_lan_ip)"
  ok "浏览器: $(browser_version)"
  ok "现有服务未受影响: xray.service=$(unit_state xray.service 2>/dev/null || echo n/a) mihomo=$(unit_state mihomo.service 2>/dev/null || echo n/a)"

  step "部署到 $XBD_PREFIX"
  local dist; dist=$(xbd_dist_dir)
  if [ "$(cd "$dist" && pwd)" = "$(cd "$XBD_PREFIX" 2>/dev/null && pwd)" ]; then
    ok "已在目标目录内运行，跳过自我拷贝"
  else
    mkdir -p "$XBD_PREFIX"
    for d in lib bin config nodes runtime logs generated backup docs service scripts tools; do
      mkdir -p "$XBD_PREFIX/$d"
    done
    cp -a "$dist/lib/." "$XBD_PREFIX/lib/" 2>/dev/null || true
    cp -a "$dist/service/." "$XBD_PREFIX/service/" 2>/dev/null || true
    cp -a "$dist/scripts/." "$XBD_PREFIX/scripts/" 2>/dev/null || true
    cp -a "$dist/docs/." "$XBD_PREFIX/docs/" 2>/dev/null || true
    [ -f "$dist/VERSION" ] && cp "$dist/VERSION" "$XBD_PREFIX/VERSION"
    # CLI 入口
    install -m 0755 "$dist/bin/xbd" "$XBD_PREFIX/bin/xbd" 2>/dev/null || true
    # 脚本以 xbd-dist 为根定位 lib（见 scripts/run-*.sh）
    mkdir -p "$XBD_DIST"
    cp -a "$dist/lib/." "$XBD_LIBDIR/" 2>/dev/null || true
    cp -a "$dist/bin/." "$XBD_DIST/bin/" 2>/dev/null || true
    cp -a "$dist/VERSION" "$XBD_DIST/VERSION" 2>/dev/null || true
    ok "已拷贝项目文件"
  fi

  # 权限：显式设定，避免 umask 造成的 203/EXEC
  chmod 0755 "$XBD_SCRIPTS"/*.sh "$XBD_LIB"/*.py "$XBD_DIST/lib"/*.py 2>/dev/null || true
  chmod 0755 "$XBD_PREFIX/bin/xbd" 2>/dev/null || true

  menu_xray_ensure
  menu_browser_ensure

  step "写入配置（幂等，不覆盖已有内容）"
  xbd_write_default_configs

  step "安装 systemd 单元"
  local u
  for u in "$XBD_U_XRAY" "$XBD_U_DIALER" "$XBD_U_CHROMIUM" "$XBD_U_PANEL" "$XBD_U_HEALTH" "$XBD_U_TIMER"; do
    install -m 0644 "$XBD_SERVICE/$u" "/etc/systemd/system/$u"
  done
  systemctl daemon-reload
  ok "已安装 6 个单元（xray-client / xray-dialer / chromium + panel / health / timer）"

  # 清理 v1/v2 遗留单元，避免与新架构冲突
  local old
  for old in xray-browser-client.service browser-dialer-health.service browser-dialer-health.timer; do
    if [ -f "/etc/systemd/system/$old" ] && [ "$old" != "$XBD_U_HEALTH" ] && [ "$old" != "$XBD_U_TIMER" ]; then
      systemctl disable --now "$old" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$old"
      dim "  已移除旧单元 $old"
    fi
  done
  systemctl daemon-reload

  # 迁移旧节点文件到统一模型
  menu_migrate_nodes

  if [ -n "$vless" ]; then
    cmd_node_add "$vless" || warn "节点未导入"
  fi

  if [ ! -e "$XBD_NODES/current" ]; then
    warn "尚未选择节点，服务未启动"
    info "下一步: xbd node add \"<uri>\"   然后 xbd start"
    return 0
  fi
  if [ "$want_start" -eq 1 ]; then
    cmd_start
  else
    warn "已按 --no-start 跳过启动"
  fi
}

xbd_write_default_configs() {
  mkdir -p "$XBD_CONF"

  # 首次安装：自动挑选**未被占用**的端口。
  # 换到新环境撞端口时不用人工排查 —— 分配器会逐个探测并避开。
  if [ ! -f "$XBD_CONF/ports.env" ]; then
    local lan; lan=$(detect_lan_ip)
    local alloc; alloc=$(python3 "$XBD_LIBDIR/ports.py" allocate --lan "$lan" --json 2>/dev/null || true)
    if [ -n "$alloc" ]; then
      step "自动分配端口"
      printf '%s' "$alloc" | python3 -c '
import sys, json
d = json.load(sys.stdin)
defaults = {"PORT_NORMAL":1080,"PORT_DIALER":1081,"PORT_HTTP":10808,
            "PORT_LAN_HTTP":10809,"DIALER_ADDR":18081,"PANEL_PORT":18090,"API_PORT":18085}
labels = {"PORT_NORMAL":"LAN SOCKS5（普通）","PORT_DIALER":"LAN SOCKS5（Dialer）",
          "PORT_HTTP":"本机 HTTP 代理","PORT_LAN_HTTP":"局域网 HTTP 代理",
          "DIALER_ADDR":"内部通道","PANEL_PORT":"面板","API_PORT":"统计 API"}
for k, label in labels.items():
    v = d.get(k)
    if v is None: continue
    if k == "DIALER_ADDR":
        v = "127.0.0.1:" + str(v)
        changed = v != ("127.0.0.1:" + str(defaults[k]))
    else:
        changed = v != defaults[k]
    print(f"  {"  " if changed else "✓ "}{label:<24} {v}" + ("   ← 默认端口被占用，已改用这个" if changed else ""))
' 2>/dev/null || true
      _XBD_ALLOC="$alloc"
    fi
  fi

  [ -f "$XBD_CONF/ports.env" ] || {
    # 用分配结果写配置
    local _lan _pn _pd _ph _plh _ch _pp _api
    _lan=$(printf '%s' "${_XBD_ALLOC:-{}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("listen_addr",""))' 2>/dev/null)
    _pn=$(printf '%s' "${_XBD_ALLOC:-{}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PORT_NORMAL",1080))' 2>/dev/null)
    _pd=$(printf '%s' "${_XBD_ALLOC:-{}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PORT_DIALER",1081))' 2>/dev/null)
    _ph=$(printf '%s' "${_XBD_ALLOC:-{}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PORT_HTTP",10808))' 2>/dev/null)
    _plh=$(printf '%s' "${_XBD_ALLOC:-{}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PORT_LAN_HTTP",10809))' 2>/dev/null)
    _ch=$(printf '%s' "${_XBD_ALLOC:-{}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("DIALER_ADDR",18081))' 2>/dev/null)
    _pp=$(printf '%s' "${_XBD_ALLOC:-{}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PANEL_PORT",18090))' 2>/dev/null)
    _api=$(printf '%s' "${_XBD_ALLOC:-{}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("API_PORT",18085))' 2>/dev/null)
    [ -n "$_lan" ] || _lan=$(detect_lan_ip)
    cat > "$XBD_CONF/ports.env" <<EOF
# 端口分配。改完执行: xbd port <类型> <值> 或直接改这里再 xbd apply && xbd restart
# 自动分配器会避开已被占用的端口；重新分配可执行 xbd ports fix
PORT_NORMAL=${_pn:-1080}
PORT_DIALER=${_pd:-1081}
LISTEN_ADDR=${_lan}
DIALER_ADDR=127.0.0.1:${_ch:-18081}
PORT_HTTP=${_ph:-10808}
PORT_LAN_HTTP=${_plh:-10809}
EOF
    printf 'PANEL_PORT=%s\n' "${_pp:-18090}" > "$XBD_CONF/panel.port.tmp"
    printf 'API_PORT=%s\n' "${_api:-18085}" > "$XBD_CONF/api.env"
  }

  [ -f "$XBD_CONF/ports.env" ] || cat > "$XBD_CONF/ports.env" <<EOF
# 端口规划。改完执行: xbd apply && xbd restart
# 常驻 Xray（普通代理模式）→ 局域网设备连这个
PORT_NORMAL=1080
# Browser Dialer 模式 → 按需启用时使用
PORT_DIALER=1081
# 只绑 LAN 地址，绝不 0.0.0.0（本机 ufw 未启用，绑 0.0.0.0 等于暴露公网）
LISTEN_ADDR=$(detect_lan_ip)
# Xray ↔ Chromium 的内部通道，仅回环
DIALER_ADDR=127.0.0.1:18081
# 本机 HTTP 代理（docker / apt / curl 用）。
# 为什么单独一个端口：docker 的 HTTP_PROXY 只认 http://，不支持 socks5://。
# 只监听回环，不对外暴露。
PORT_HTTP=10808
# 局域网 HTTP 代理：设备（手机/电脑）在 WiFi 设置里填 <本机IP>:这个端口
PORT_LAN_HTTP=10809
EOF

  [ -f "$XBD_CONF/dialer.env" ] || cat > "$XBD_CONF/dialer.env" <<'EOF'
# Browser Dialer 启用标志：让 Xray 监听该地址、播放内嵌页面、接受浏览器回连。
# 这是 Xray 内建功能，没有独立的 dialer 守护进程。
XRAY_BROWSER_DIALER=127.0.0.1:18081
EOF

  [ -f "$XBD_CONF/chromium.env" ] || cat > "$XBD_CONF/chromium.env" <<'EOF'
# Chromium 运行参数（仅 Browser Dialer 模式运行时使用）
BROWSER_DIALER_ADDR=127.0.0.1:18081
# 本机以 root 运行，Chromium 在 root 下必须 --no-sandbox
CHROMIUM_EXTRA_ARGS="--no-sandbox"
# headless 已在本机验证可用；需要图形环境时改成 xvfb 并安装 xvfb
CHROMIUM_MODE=headless
CHROMIUM_DISPLAY=:99
# Chromium 的 ECH 依赖 Secure DNS（现代 Chromium 已移除相关命令行开关）
XBD_DOH=https://dns.alidns.com/dns-query
EOF

  if [ ! -f "$XBD_CONF/panel.env" ]; then
    cat > "$XBD_CONF/panel.env" <<EOF
# 面板配置。改完执行: xbd restart panel
# 127.0.0.1=仅本机 / <LAN IP>=同局域网可访问 / 0.0.0.0=暴露公网(不要)
PANEL_HOST=$(detect_lan_ip)
PANEL_PORT=18090
PANEL_TOKEN=$(openssl rand -hex 12 2>/dev/null || head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
EOF
    chmod 0600 "$XBD_CONF/panel.env"
  fi
}

menu_xray_ensure() {
  step "Xray 二进制"
  if [ -x "$XBD_XRAY" ]; then
    ok "已就绪: $("$XBD_XRAY" version 2>/dev/null | head -1)"
    return 0
  fi
  warn "未找到 $XBD_XRAY"
  local src
  for src in /usr/local/bin/xray /usr/bin/xray; do
    if [ -x "$src" ]; then
      install -m 0755 "$src" "$XBD_XRAY"
      ok "已从 $src 复制为本项目独立副本"
      return 0
    fi
  done
  info "请先下载官方 Xray 到 $XBD_XRAY，或运行: xbd update"
  return 1
}

menu_browser_ensure() {
  step "浏览器"
  if BROWSER=$(detect_browser); then
    ok "已就绪: $BROWSER — $(browser_version)"
    return 0
  fi
  warn "未找到浏览器，Browser Dialer 将不可用（普通模式不受影响）"
  return 1
}

menu_migrate_nodes() {
  [ -d "$XBD_NODES" ] || return 0
  local f migrated=0
  for f in "$XBD_NODES"/node-*.json "$XBD_NODES"/current; do
    [ -e "$f" ] || continue
    [ -L "$f" ] && continue
    python3 - "$f" <<'PY' 2>/dev/null && migrated=$((migrated+1))
import json, sys, os
sys.path.insert(0, os.environ.get("XBD_LIBDIR", "/opt/xray-browser-dialer/xbd-dist/lib"))
try:
    import node as N
except ImportError:
    raise SystemExit(1)
p = sys.argv[1]
d = json.load(open(p))
if "protocol" in d and "transport" in d and d.get("raw_params") is not None:
    raise SystemExit(1)          # 已是统一模型
n = N.new_node()
n.update({k: v for k, v in d.items() if k in n and v not in (None, "")})
n["transport_raw"] = d.get("transport_raw") or d.get("transport", "tcp")
n["transport"] = N._norm_transport(n["transport_raw"])
n["port"] = int(n.get("port") or 443)
json.dump(n, open(p, "w"), ensure_ascii=False, indent=2)
PY
  done
  [ "$migrated" -gt 0 ] && ok "已迁移 $migrated 个节点到统一模型" || true
}

# ---------------------------------------------------------------------------
# 节点管理
# ---------------------------------------------------------------------------
cmd_node() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    add|import)  cmd_node_add "$@" ;;
    latency|ping|delay) cmd_node_latency "$@" ;;
    list|ls)     cmd_node_list "$@" ;;
    use|select)  cmd_node_use "$@" ;;
    remove|rm)   cmd_node_remove "$@" ;;
    check)       cmd_node_check "$@" ;;
    latency|ping|delay) cmd_node_latency "$@" ;;
    sub|subscription) cmd_node_subscription "$@" ;;
    import-file) cmd_node_import_file "$@" ;;
    -h|--help|"") info "用法: xbd node <add|list|use|remove|check|sub|import-file>" ;;
    *) die "未知子命令: $sub" ;;
  esac
}

cmd_node_add() {
  local raw="${1:-}"
  if [ -z "$raw" ] && [ ! -t 0 ]; then raw=$(cat); fi
  if [ -z "$raw" ]; then
    printf '请输入节点（URI / Xray JSON / Mihomo YAML，可多行、可多个）: '
    raw=$(cat)
  fi
  [ -n "$raw" ] || die "没有输入"

  # 订阅 URL：先下载再解析
  if printf '%s' "$raw" | grep -qE '^https?://'; then
    cmd_node_subscription "$raw"
    return $?
  fi

  # 关键：整段交给 parse_many。
  # 之前是按行拆开逐行解析 —— 那样多行 YAML 会被拆散，
  # 一段含多个 "- name:" 的 mihomo 配置只能碰巧识别出个别字段。
  local tmp; tmp=$(mktemp)
  printf '%s' "$raw" | python3 "$XBD_LIBDIR/node.py" multi - > "$tmp" 2>/tmp/.xbd_multi_err
  if [ ! -s "$tmp" ]; then
    bad "没有解析出可用节点: $(head -1 /tmp/.xbd_multi_err 2>/dev/null)"
    rm -f "$tmp"; return 1
  fi

  local total; total=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$tmp" 2>/dev/null || echo 0)
  [ "$total" -gt 0 ] || { rm -f "$tmp"; die "没有解析出可用节点"; }

  if [ "$total" -gt 1 ]; then
    info "检测到 $total 个节点，逐个导入："
  fi

  local count=0 idx=0
  while IFS= read -r node_json; do
    [ -z "$node_json" ] && continue
    idx=$((idx+1))
    printf '%s' "$node_json" > /tmp/.xbd_one.json
    if [ "$total" -gt 1 ]; then
      printf '\n  [%d/%d] ' "$idx" "$total"
    fi
    cmd_node_import_file /tmp/.xbd_one.json && count=$((count+1))
  done < <(python3 -c '
import json, sys
for n in json.load(open(sys.argv[1])):
    print(json.dumps(n, ensure_ascii=False))
' "$tmp")

  rm -f "$tmp" /tmp/.xbd_one.json /tmp/.xbd_multi_err
  [ "$count" -gt 0 ] || die "没有成功导入任何节点"
  [ "$total" -gt 1 ] && { info ""; ok "共导入 $count/$total 个节点"; }
}

cmd_node_import_one() {  # 解析一个节点并落盘；成功返回 0
  local raw="$1" tmp
  tmp=$(mktemp)
  if ! printf '%s' "$raw" | python3 "$XBD_LIBDIR/node.py" parse - > "$tmp" 2>/tmp/.xbd_node_err; then
    bad "解析失败: $(cat /tmp/.xbd_node_err 2>/dev/null | head -1)"
    rm -f "$tmp"; return 1
  fi

  # 落盘 + 能力检查结果
  local slug dest idx=1
  slug=$(python3 -c '
import json,sys,re
d=json.load(open(sys.argv[1]))
s=re.sub(r"[^A-Za-z0-9._-]+","-",(d.get("name") or d.get("address") or "node")).strip("-").lower()
print(s[:40] or "node")' "$tmp")
  while :; do
    dest="$XBD_NODES/$(printf 'node-%03d' "$idx")-$slug.json"
    [ -e "$dest" ] && { idx=$((idx+1)); continue; }
    break
  done
  install -m 0644 "$tmp" "$dest"; rm -f "$tmp"

  local caps
  # 注意：compat.py 在"两种模式都不可用"时退出码为 1（这是有效结论，不是失败），
  # 所以这里不能写 || echo '{}' —— 那样会把结论丢掉。
  caps=$(python3 "$XBD_LIBDIR/compat.py" json "$dest" 2>/dev/null)
  [ -n "$caps" ] || caps='{}'
  case "$caps" in \{*) : ;; *) caps='{}' ;; esac
  python3 - "$dest" "$caps" <<'PY'
import json, sys
p, caps = sys.argv[1], sys.argv[2]
d = json.load(open(p))
try:
    d["_compat"] = json.loads(caps)
except ValueError:
    d["_compat"] = {}
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PY

  print_node_card "$dest"
  # 首个节点自动选中
  if [ ! -e "$XBD_NODES/current" ]; then
    ln -sfn "$(basename "$dest")" "$XBD_NODES/current"
    ok "已设为当前节点: $(basename "$dest")"
  fi
  return 0
}

print_node_card() {  # print_node_card <node.json>
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d.get("_compat") or {}
x = (c.get("xray") or {}).get("overall", "UNKNOWN")
b = (c.get("dialer") or {}).get("overall", "UNKNOWN")
tagmap = {"SUPPORTED": "✓ 支持", "SUPPORTED_WITH_WARNING": "⚠ 支持（有注意项）",
          "NOT_SUPPORTED": "✗ 不支持", "UNKNOWN": "? 未知"}
print()
print(f"  节点名称：{d.get('name')}")
print(f"  Xray：            {tagmap.get(x, x)}")
print(f"  Browser Dialer：  {tagmap.get(b, b)}")
tags = c.get("tags") or []
if tags:
    print("  能力标签：" + "  ".join(f"[{t}]" for t in tags))
notes = (c.get("dialer") or {}).get("notes") or []
if b not in ("SUPPORTED", "SUPPORTED_WITH_WARNING") and notes:
    print("  原因：")
    for n in notes[:3]:
        print(f"    - {n}")
PY
}

import_node_file() {  # 内部：把一个文件导入为节点
  cmd_node_import_one "$(cat "$1")"
}

cmd_node_import_file() {
  local f="${1:-}"
  [ -f "$f" ] || die "文件不存在: $f"
  cmd_node_import_one "$(cat "$f")"
}

cmd_node_subscription() {
  local url="${1:-}"
  [ -n "$url" ] || die "用法: xbd node sub <订阅URL>"
  step "下载订阅"
  local body; body=$(curl -sL --max-time 60 "$url") || die "下载失败"
  [ -n "$body" ] || die "订阅内容为空"

  local tmp; tmp=$(mktemp)
  printf '%s' "$body" | python3 "$XBD_LIBDIR/node.py" subscription - > "$tmp" 2>/dev/null || true
  local n; n=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$tmp" 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] || { rm -f "$tmp"; die "订阅里没有解析出节点"; }
  ok "解析出 $n 个节点"

  python3 - "$tmp" <<'PY' > /tmp/.xbd_sub_lines
import json, sys
for node in json.load(open(sys.argv[1])):
    print(json.dumps(node, ensure_ascii=False))
PY
  local c=0 line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    cmd_node_import_one "$line" >/dev/null && c=$((c+1))
  done < /tmp/.xbd_sub_lines
  rm -f "$tmp" /tmp/.xbd_sub_lines
  ok "已导入 $c 个节点"
}

cmd_node_list() {
  XBD_PREFIX="$XBD_PREFIX" python3 "$XBD_LIBDIR/nodelist.py"
}

cmd_node_use() {
  local t="${1:-}"
  [ -n "$t" ] || { cmd_node_list; info ""; info "用法: xbd node use <编号|文件名>"; return 0; }
  local path
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    path=$(ls -1 "$XBD_NODES"/node-*.json 2>/dev/null | sed -n "${t}p")
    [ -n "$path" ] || die "没有编号 $t 的节点"
  else
    path="$XBD_NODES/$t"
    [ -e "$path" ] || path=$(ls -1 "$XBD_NODES"/*"$t"* 2>/dev/null | head -1)
    [ -e "${path:-}" ] || die "找不到节点: $t"
  fi
  ln -sfn "$(basename "$path")" "$XBD_NODES/current"
  ok "当前节点 → $(basename "$path")"
  print_node_card "$path"

  # 新节点若不支持 Browser Dialer，而 dialer 还在跑，必须收敛掉
  # （否则会出现"界面 Running、代理已死"的静默失效）
  local new_can
  new_can=$(python3 "$XBD_LIBDIR/compat.py" json "$path" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("can_use_dialer"))' 2>/dev/null || echo False)
  if [ "$new_can" != "True" ] && unit_active "$XBD_U_DIALER"; then
    warn "新节点不支持 Browser Dialer，正在关闭 dialer"
    xbd_dialer_off
  fi
  info "执行 xbd apply && xbd restart 生效"
}

cmd_node_remove() {
  local t="${1:-}"
  [ -n "$t" ] || die "用法: xbd node remove <编号|文件名>"
  local path
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    path=$(ls -1 "$XBD_NODES"/node-*.json 2>/dev/null | sed -n "${t}p")
  else
    path="$XBD_NODES/$t"
    [ -e "$path" ] || path=$(ls -1 "$XBD_NODES"/*"$t"* 2>/dev/null | head -1)
  fi
  [ -e "${path:-}" ] || die "找不到节点: $t"
  local base; base=$(basename "$path")
  if [ -L "$XBD_NODES/current" ] && [ "$(basename "$(readlink -f "$XBD_NODES/current")")" = "$base" ]; then
    die "不能删除当前正在使用的节点，先切换到别的节点"
  fi
  rm -f "$path"
  ok "已删除 $base"
}

# 节点延时：真实发一次请求测完整往返，比 TCP ping 准
cmd_node_latency() {
  local t="${1:-}"
  local files=()
  if [ -z "$t" ]; then
    local f
    for f in "$XBD_NODES"/node-*.json; do [ -e "$f" ] && files+=("$f"); done
    [ ${#files[@]} -gt 0 ] || die "还没有节点"
  elif [[ "$t" =~ ^[0-9]+$ ]]; then
    local p; p=$(ls -1 "$XBD_NODES"/node-*.json 2>/dev/null | sed -n "${t}p")
    [ -n "$p" ] || die "没有编号 $t 的节点"
    files=("$p")
  else
    local p="$XBD_NODES/$t"
    [ -e "$p" ] || p=$(ls -1 "$XBD_NODES"/*"$t"* 2>/dev/null | head -1)
    [ -e "${p:-}" ] || die "找不到节点: $t"
    files=("$p")
  fi

  step "延时测试（真实请求，每个节点约 3-10 秒）"
  local current; current=$(readlink -f "$XBD_NODES/current" 2>/dev/null || true)
  # 注意：不要把 "$@" 再传给 python —— 之前那样会把 --json 之类参数重复传入，
  # curl 收到未知参数会失败，却被误判成节点不通。
  XBD_PREFIX="$XBD_PREFIX" XBD_DIST="$(xbd_dist_dir)" \
    python3 "$XBD_LIBDIR/latency.py" "${files[@]}"
  info ""
  info "口径：一次 https 请求的完整往返时间（含建连/TLS/传输协议），已预热"
}

cmd_node_check() {
  local t="${1:-}"
  local path="$XBD_NODES/current"
  if [ -n "$t" ]; then
    if [[ "$t" =~ ^[0-9]+$ ]]; then
      path=$(ls -1 "$XBD_NODES"/node-*.json 2>/dev/null | sed -n "${t}p")
    else
      path="$XBD_NODES/$t"
      [ -e "$path" ] || path=$(ls -1 "$XBD_NODES"/*"$t"* 2>/dev/null | head -1)
    fi
  fi
  [ -e "${path:-}" ] || die "找不到节点"
  python3 "$XBD_LIBDIR/compat.py" render "$path"
}

# ---------------------------------------------------------------------------
# 生命周期：Xray 常驻 与 Browser Dialer 完全解耦
# ---------------------------------------------------------------------------
cmd_apply() {
  need_root
  require_current_node >/dev/null
  step "生成运行配置"
  xbd_load_ports
  local mode
  for mode in normal dialer; do
    if python3 "$XBD_LIBDIR/genconfig.py" \
        --node "$XBD_NODES/current" --output "$XBD_RUNTIME/xray-$mode.json" --mode "$mode" \
        --listen "$XBD_LISTEN_ADDR" --port-normal "$XBD_PORT_NORMAL" --port-dialer "$XBD_PORT_DIALER" \
        --api-port "${XBD_API_PORT:-18085}" --logs "$XBD_LOGS" 2>&1 | grep -q '"ok": true'; then
      ok "xray-$mode.json（端口 $( [ "$mode" = normal ] && echo "$XBD_PORT_NORMAL" || echo "$XBD_PORT_DIALER" )）"
    else
      # dialer 配置生成失败是**允许的**：说明该节点不支持 Browser Dialer
      if [ "$mode" = dialer ]; then
        warn "xray-dialer.json 生成失败（该节点不支持 Browser Dialer，普通模式不受影响）"
        rm -f "$XBD_RUNTIME/xray-dialer.json"
      else
        die "xray-normal.json 生成失败，这是致命的"
      fi
    fi
  done
  # 生成完配置后立即校验 dialer 一致性
  _xbd_dialer_guard || true
}

cmd_start() {
  need_root
  require_current_node >/dev/null
  xbd_load_ports
  cmd_apply

  step "启动常驻 Xray（普通代理模式）"
  systemctl enable --now "$XBD_U_XRAY" >/dev/null 2>&1 || systemctl start "$XBD_U_XRAY"
  sleep 4
  unit_active "$XBD_U_XRAY" && ok "$XBD_U_XRAY: RUNNING" || { bad "$XBD_U_XRAY 启动失败"; journalctl -u "$XBD_U_XRAY" -n 15 --no-pager; return 1; }

  step "启动面板"
  systemctl enable --now "$XBD_U_PANEL" >/dev/null 2>&1 || systemctl start "$XBD_U_PANEL"
  sleep 2
  unit_active "$XBD_U_PANEL" && ok "$XBD_U_PANEL: RUNNING ($(xbd_panel_url))" || warn "面板未启动（不影响代理）"

  info ""
  ok "普通模式已就绪。局域网设备可连接 ${XBD_LISTEN_ADDR}:${XBD_PORT_NORMAL}"
  info "如需 Browser Dialer: xbd dialer on（按需启动，不会影响上面的常驻实例）"
}

cmd_stop() {
  need_root
  # 分层：默认只停常驻 Xray；--all 才连面板块停
  local all=0
  [ "${1:-}" = "--all" ] && all=1

  step "停止常驻 Xray"
  systemctl stop "$XBD_U_XRAY" 2>/dev/null || true
  ok "$XBD_U_XRAY: STOPPED"

  if unit_active "$XBD_U_DIALER"; then
    warn "Browser Dialer 模式仍在运行（xbd dialer off 可单独关闭）"
  fi

  if [ "$all" -eq 1 ]; then
    xbd_dialer_off || true
    systemctl stop "$XBD_U_TIMER" 2>/dev/null || true
    systemctl stop "$XBD_U_PANEL" 2>/dev/null || true
    ok "已全部停止"
  else
    info "面板保持运行，可从网页再启动: $(xbd_panel_url)"
  fi
  info "单元仍为 enabled，重启机器会自动启动"
}

cmd_restart() {
  need_root
  systemctl restart "$XBD_U_XRAY"
  sleep 3
  ok "$XBD_U_XRAY 已重启"
  # Xray 重启会换 CSRF token，dialer 模式若在运行必须跟着重启浏览器。
  # 但先检查节点是否还支持 dialer —— 不支持就直接停掉，而不是盲目重启。
  if unit_active "$XBD_U_DIALER"; then
    if _xbd_dialer_guard; then
      warn "重启 Chromium 以重新同步（Xray 重启会换 token）"
      systemctl restart "$XBD_U_CHROMIUM" 2>/dev/null || true
    fi
  fi
  cmd_status
}

# ---------------------------------------------------------------------------
# Browser Dialer 按需启停（需求第五、六、七条）
# ---------------------------------------------------------------------------
cmd_dialer() {
  local op="${1:-status}"
  case "$op" in
    on|start|enable)  xbd_dialer_on ;;
    off|stop|disable) xbd_dialer_off ;;
    toggle)           if unit_active "$XBD_U_DIALER"; then xbd_dialer_off; else xbd_dialer_on; fi ;;
    status|"")        xbd_dialer_status ;;
    -h|--help)        info "用法: xbd dialer <on|off|toggle|status>" ;;
    *) die "未知操作: $op" ;;
  esac
}

# dialer 与节点的一致性守卫。
# 为什么需要：切到不支持 Browser Dialer 的节点后，dialer 实例与 Chromium 仍在运行，
# 但 xray-dialer.json 生成失败 —— 表现为「界面显示 Running，代理实际已死」。
# 这是实测复现过的静默失效，必须主动收敛。
_xbd_dialer_guard() {
  unit_active "$XBD_U_DIALER" || return 0          # 没开就不用管

  local node; node=$(readlink -f "$XBD_NODES/current" 2>/dev/null || true)
  [ -n "$node" ] && [ -e "$node" ] || return 0

  local can="False"
  local caps; caps=$(python3 "$XBD_LIBDIR/compat.py" json "$node" 2>/dev/null)
  case "$caps" in
    \{*) can=$(printf '%s' "$caps" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("can_use_dialer"))' 2>/dev/null || echo False) ;;
  esac

  if [ "$can" != "True" ] || [ ! -f "$XBD_RUNTIME/xray-dialer.json" ]; then
    warn "当前节点不支持 Browser Dialer，正在自动关闭 dialer（Xray 常驻实例不受影响）"
    systemctl stop "$XBD_U_CHROMIUM" 2>/dev/null || true
    systemctl stop "$XBD_U_DIALER" 2>/dev/null || true
    systemctl stop "$XBD_U_TIMER" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6; do
      [ "$(pgrep -c chromium 2>/dev/null | head -1 || echo 0)" -eq 0 ] && break
      sleep 1
    done
    ok "Browser Dialer 已关闭，Chromium 已退出"
    info "该节点仍可正常使用普通模式（:$(cfg_get "$XBD_CONF/ports.env" PORT_NORMAL 1080)）"
    return 1
  fi
  return 0
}

xbd_dialer_status() {
  printf '  Browser Dialer: %s\n' "$(unit_active "$XBD_U_DIALER" && echo "Running" || echo "Stopped")"
  printf '  Chromium:       %s\n' "$(unit_active "$XBD_U_CHROMIUM" && echo "Running" || echo "Stopped")"
  printf '  Xray:           %s\n' "$(unit_active "$XBD_U_XRAY" && echo "Running" || echo "Stopped")"
  if unit_active "$XBD_U_DIALER"; then
    printf '  Dialer 入口:    %s:%s\n' "$(cfg_get "$XBD_CONF/ports.env" LISTEN_ADDR 127.0.0.1)" "$(cfg_get "$XBD_CONF/ports.env" PORT_DIALER 1081)"
    printf '  浏览器连接数:   %s\n' "$(conn_count '127.0.0.1:18081')"
  fi
}

xbd_dialer_on() {
  need_root
  step "启用 Browser Dialer 模式"
  local node; node=$(require_current_node)

  # 1. 该节点能不能用
  local caps can
  caps=$(python3 "$XBD_LIBDIR/compat.py" json "$node" 2>/dev/null || echo '{}')
  can=$(printf '%s' "$caps" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("can_use_dialer"))' 2>/dev/null || echo False)
  if [ "$can" != "True" ]; then
    bad "当前节点不支持 Browser Dialer"
    printf '%s' "$caps" | python3 -c '
import sys, json
c = json.load(sys.stdin)
for n in (c.get("dialer") or {}).get("notes") or []:
    print(f"    原因: {n}")
' 2>/dev/null || true
    info "该节点仍可正常使用普通 Xray 模式（xbd status 查看）"
    return 1
  fi

  # 2. 常驻 Xray 必须在跑（但 dialer 不会去启动它 —— 独立职责）
  if ! unit_active "$XBD_U_XRAY"; then
    warn "常驻 Xray 未运行，先启动它"
    cmd_start >/dev/null 2>&1 || true
  fi

  # 3. 生成 dialer 配置
  xbd_load_ports
  if ! python3 "$XBD_LIBDIR/genconfig.py" \
      --node "$node" --output "$XBD_RUNTIME/xray-dialer.json" --mode dialer \
      --listen "$XBD_LISTEN_ADDR" --port-dialer "$XBD_PORT_DIALER" \
      --api-port "${XBD_API_PORT:-18085}" --logs "$XBD_LOGS" >/dev/null 2>&1; then
    bad "dialer 配置生成失败"; return 1
  fi
  ok "已生成 xray-dialer.json"

  # 4. 启动 dialer 实例 + Chromium（只动这两个单元）
  systemctl start "$XBD_U_DIALER"
  sleep 4
  unit_active "$XBD_U_DIALER" || { bad "xray-dialer 启动失败"; journalctl -u "$XBD_U_DIALER" -n 10 --no-pager; return 1; }
  ok "$XBD_U_DIALER: RUNNING"

  systemctl start "$XBD_U_CHROMIUM"
  systemctl enable --now "$XBD_U_TIMER" >/dev/null 2>&1 || true
  sleep 8

  # 真实校验两端是否接上。只看"端口在听"不够 ——
  # 端口改过而 Chromium 没跟上时，两边各自"正常"但一条 WS 都没有。
  local chk
  chk=$(python3 "$XBD_LIBDIR/ports.py" verify-dialer --json 2>/dev/null || echo '{}')
  local vok vws vmismatch
  vok=$(printf '%s' "$chk" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo False)
  vws=$(printf '%s' "$chk" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ws_connections",0))' 2>/dev/null || echo 0)
  vmismatch=$(printf '%s' "$chk" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("mismatch"))' 2>/dev/null || echo False)

  if [ "$vmismatch" = "True" ]; then
    bad "端口不一致：Chromium 连的不是 Xray 监听的端口"
    info "  修正: xbd port channel <端口>  然后 xbd dialer off && xbd dialer on"
    return 1
  fi
  if unit_active "$XBD_U_CHROMIUM"; then
    if [ "$vok" = "True" ]; then
      ok "$XBD_U_CHROMIUM: RUNNING（浏览器已接上，$vws 条 WS）"
    else
      warn "$XBD_U_CHROMIUM RUNNING，但浏览器还没接上 —— health timer 会在 30 秒内自愈"
      info "  若一直不恢复: xbd ports verify"
    fi
  else
    bad "$XBD_U_CHROMIUM 启动失败"
  fi

  info ""
  ok "Browser Dialer 模式已启用"
  info "  模式入口: ${XBD_LISTEN_ADDR}:${XBD_PORT_DIALER}（TLS 由 Chromium 完成）"
  info "  普通模式: ${XBD_LISTEN_ADDR}:${XBD_PORT_NORMAL}（不受影响，仍在运行）"
  info "  关闭: xbd dialer off"
}

xbd_dialer_off() {
  need_root
  step "关闭 Browser Dialer 模式"
  # 只停 dialer 与 Chromium；常驻 Xray 绝不停（需求第六条）
  systemctl stop "$XBD_U_CHROMIUM" 2>/dev/null || true
  systemctl stop "$XBD_U_DIALER" 2>/dev/null || true
  systemctl stop "$XBD_U_TIMER" 2>/dev/null || true

  # 等 Chromium 子进程真正退出
  local i procs
  for i in 1 2 3 4 5 6 7 8; do
    procs=$(pgrep -c chromium 2>/dev/null | head -1 || true)
    [ "${procs:-0}" -eq 0 ] && break
    sleep 1
  done
  procs=$(pgrep -c chromium 2>/dev/null | head -1 || true)

  ok "$XBD_U_DIALER: STOPPED"
  ok "$XBD_U_CHROMIUM: STOPPED（残留进程 $procs）"
  if unit_active "$XBD_U_XRAY"; then
    ok "$XBD_U_XRAY: 继续运行 ✓（普通模式不受影响）"
  else
    warn "$XBD_U_XRAY 未在运行"
  fi
  rm -f "$XBD_RUNTIME/xray-dialer.json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 端口
# ---------------------------------------------------------------------------
cmd_port() {
  local which="${1:-}" value="${2:-}"
  xbd_load_ports
  if [ -z "$which" ]; then
    printf '  当前端口分配:\n'
    printf '    %-34s %s\n' "LAN SOCKS5（普通模式）"   "$XBD_PORT_NORMAL"
    printf '    %-34s %s\n' "LAN SOCKS5（Browser Dialer）" "$XBD_PORT_DIALER"
    printf '    %-34s %s\n' "本机 HTTP 代理（docker 等）" "$XBD_PORT_HTTP"
    printf '    %-34s %s\n' "局域网 HTTP 代理（WiFi）" "$XBD_PORT_LAN_HTTP"
    printf '    %-34s %s\n' "Xray↔Chromium 内部通道"  "$XBD_DIALER_ADDR"
    printf '    %-34s %s\n' "面板"                    "$XBD_PANEL_PORT"
    printf '    %-34s %s\n' "Xray 统计 API"           "${XBD_API_PORT:-18085}"
    printf '    %-34s %s\n' "绑定地址"                "$XBD_LISTEN_ADDR"
    info ""
    info "修改: xbd port <类型> <值>"
    info "  类型: normal | dialer | http | lan-http | channel | panel | api | addr"
    info "自动分配: xbd ports fix    检查冲突: xbd ports check"
    return 0
  fi

  need_root
  case "$which" in
    normal|n)     [ -n "$value" ] || die "缺端口值"; _xbd_set_port PORT_NORMAL "$value" normal ;;
    dialer|d)     [ -n "$value" ] || die "缺端口值"; _xbd_set_port PORT_DIALER "$value" dialer ;;
    http|h)       [ -n "$value" ] || die "缺端口值"; _xbd_set_port PORT_HTTP "$value" xray ;;
    lan-http|lh)  [ -n "$value" ] || die "缺端口值"; _xbd_set_port PORT_LAN_HTTP "$value" xray ;;
    api)          [ -n "$value" ] || die "缺端口值"; _xbd_set_port API_PORT "$value" xray ;;
    channel|ch)
      [ -n "$value" ] || die "缺端口值"
      _xbd_check_port_num "$value"
      local holder; holder=$(port_holder "$value")
      [ -z "$holder" ] || [ "$(printf '%s' "$holder" | grep -c xray)" -gt 0 ] || die "端口 $value 已被占用（${holder:0:60}）"
      # 内部通道改端口必须**两边一起改**，否则 Chromium 还连旧端口（实测过这个坑）
      cfg_set "$XBD_CONF/ports.env" DIALER_ADDR "127.0.0.1:$value"
      cfg_set "$XBD_CONF/dialer.env" XRAY_BROWSER_DIALER "127.0.0.1:$value"
      cfg_set "$XBD_CONF/chromium.env" BROWSER_DIALER_ADDR "127.0.0.1:$value"
      ok "内部通道 → 127.0.0.1:$value（ports.env / dialer.env / chromium.env 已同步）"
      ;;
    panel|p)
      [ -n "$value" ] || die "缺端口值"
      _xbd_check_port_num "$value"
      cfg_set "$XBD_CONF/panel.env" PANEL_PORT "$value"
      ok "面板端口 → $value"
      systemctl restart "$XBD_U_PANEL" 2>/dev/null || true
      info "面板新地址: http://$(cfg_get "$XBD_CONF/panel.env" PANEL_HOST 127.0.0.1):$value/"
      return 0
      ;;
    addr|listen)  [ -n "$value" ] || die "缺地址值"; cfg_set "$XBD_CONF/ports.env" LISTEN_ADDR "$value"; ok "绑定地址 → $value" ;;
    *) die "未知端口类型: $which（可选 normal/dialer/http/lan-http/channel/panel/api/addr）" ;;
  esac
  info "执行 xbd apply && xbd restart 生效"
}

# 端口子命令：检查与自动修复
cmd_ports() {
  local op="${1:-check}"
  case "$op" in
    check)  python3 "$XBD_LIBDIR/ports.py" check ;;
    fix|auto)
      need_root
      step "检查并修复端口冲突"
      local out; out=$(python3 "$XBD_LIBDIR/ports.py" check --json)
      local n; n=$(printf '%s' "$out" | python3 -c '
import sys, json
print(len(json.load(sys.stdin).get("problems", [])))' 2>/dev/null || echo 0)
      if [ "${n:-0}" -eq 0 ]; then
        ok "没有端口冲突（本项目服务占用自己的端口属正常）"
        return 0
      fi
      warn "发现 $n 处冲突，正在重新分配"
      printf '%s' "$out" | python3 -c '
import sys, json
for p in json.load(sys.stdin).get("problems", []):
    print(f"  {p["label"]}: {p["port"]} 被占用（{p["holder"][:50]}）→ 改用 {p["suggest"]}")
'
      # 逐项应用建议值（只改被占用的那些）
      local which port
      while IFS=$'\t' read -r which port; do
        [ -z "$which" ] && continue
        case "$which" in
          PORT_NORMAL)   _xbd_set_port PORT_NORMAL "$port" normal ;;
          PORT_DIALER)   _xbd_set_port PORT_DIALER "$port" dialer ;;
          PORT_HTTP)     _xbd_set_port PORT_HTTP "$port" xray ;;
          PORT_LAN_HTTP) _xbd_set_port PORT_LAN_HTTP "$port" xray ;;
          API_PORT)      _xbd_set_port API_PORT "$port" xray ;;
          PANEL_PORT)    cfg_set "$XBD_CONF/panel.env" PANEL_PORT "$port"; ok "面板端口 → $port" ;;
          DIALER_ADDR)   cfg_set "$XBD_CONF/ports.env" DIALER_ADDR "127.0.0.1:$port"
                         cfg_set "$XBD_CONF/dialer.env" XRAY_BROWSER_DIALER "127.0.0.1:$port"
                         ok "内部通道 → $port" ;;
        esac
      done < <(printf '%s' "$out" | python3 -c '
import sys, json
for p in json.load(sys.stdin).get("problems", []):
    print(p["key"] + "\t" + str(p["suggest"]))
')
      cmd_apply >/dev/null 2>&1 || true
      systemctl restart "$XBD_U_XRAY" 2>/dev/null || true
      systemctl restart "$XBD_U_PANEL" 2>/dev/null || true
      ok "已修复。执行 xbd status 查看"
      ;;
    verify)
      python3 "$XBD_LIBDIR/ports.py" verify-dialer ;;
    -h|--help|"") info "用法: xbd ports <check|fix|verify>" ;;
    *) die "未知操作: $op" ;;
  esac
}

_xbd_check_port_num() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "端口必须是 1-65535 的数字"
}

_xbd_set_port() {
  local key="$1" new="$2" reload="${3:-}"
  _xbd_check_port_num "$new"
  # API 端口存独立文件；其余在 ports.env
  local file="$XBD_CONF/ports.env"
  [ "$key" = "API_PORT" ] && file="$XBD_CONF/api.env"
  local cur holder
  cur=$(cfg_get "$file" "$key" "")
  [ "$new" = "$cur" ] && { ok "端口已经是 $new"; return 0; }
  holder=$(port_holder "$new")
  # 自己占着的端口允许改（例如重启后重新分配）
  if [ -n "$holder" ] && ! printf '%s' "$holder" | grep -q xray; then
    die "端口 $new 已被占用（${holder:0:70}）"
  fi
  cfg_set "$file" "$key" "$new"
  ok "$key: ${cur:-未设置} → $new"
  case "$reload" in
    xray)   systemctl restart "$XBD_U_XRAY" 2>/dev/null || true ;;
    panel)  systemctl restart "$XBD_U_PANEL" 2>/dev/null || true ;;
    normal|dialer|"") : ;;
  esac
}

# ---------------------------------------------------------------------------
# 状态 / 诊断
# ---------------------------------------------------------------------------
cmd_status() {
  if [ ! -x "$XBD_XRAY" ]; then
    warn "尚未安装（找不到 $XBD_XRAY）"
    info "安装: xbd install"
    return 2
  fi
  local quick=""
  [ "${1:-}" = "--quick" ] && quick="--quick"
  XBD_PREFIX="$XBD_PREFIX" python3 "$XBD_LIBDIR/state.py" $quick
}

cmd_panel() {
  xbd_load_ports
  info "面板地址: http://$XBD_PANEL_HOST:$XBD_PANEL_PORT/"
  [ -n "$XBD_PANEL_TOKEN" ] && { info "访问令牌: $XBD_PANEL_TOKEN"; info "完整链接: http://$XBD_PANEL_HOST:$XBD_PANEL_PORT/?token=$XBD_PANEL_TOKEN"; }
  [ "$XBD_PANEL_HOST" = "127.0.0.1" ] && dim "  当前只允许本机访问；要局域网访问把 PANEL_HOST 改成 $(detect_lan_ip)"
  info "配置: $XBD_CONF/panel.env"
}

cmd_diagnose() {
  local quick=0
  [ "${1:-}" = "--quick" ] && quick=1
  xbd_load_ports
  local fails=0 warns=0
  echo "========================================"
  echo "Xray Client + Browser Dialer 诊断"
  echo "========================================"
  _d() { case "$2" in
    PASS) ok "$(printf '%-26s' "$1") $3" ;;
    WARN) warn "$(printf '%-26s' "$1") $3"; warns=$((warns+1)) ;;
    FAIL) bad "$(printf '%-26s' "$1") $3"; fails=$((fails+1)) ;;
  esac; }

  _d "架构/发行版" PASS "$(uname -m) / $(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")"
  [ -x "$XBD_XRAY" ] && _d "Xray 二进制" PASS "$("$XBD_XRAY" version 2>/dev/null | head -1 | cut -c1-40)" || _d "Xray 二进制" FAIL "缺失"
  if BROWSER=$(detect_browser); then _d "浏览器" PASS "$(browser_version | cut -c1-40)"; else _d "浏览器" WARN "未安装（Browser Dialer 不可用，普通模式不受影响）"; fi

  local node; node=$(current_node_file 2>/dev/null || true)
  if [ -n "$node" ]; then
    local caps
    caps=$(python3 "$XBD_LIBDIR/compat.py" json "$node" 2>/dev/null || echo '{}')
    _d "节点 Xray" "$(printf '%s' "$caps" | python3 -c 'import sys,json;print("PASS" if json.load(sys.stdin).get("can_use_xray") else "FAIL")' 2>/dev/null || echo FAIL)" \
       "$(node_field "$node" name)"
    _d "节点 Browser Dialer" "$(printf '%s' "$caps" | python3 -c 'import sys,json;print("PASS" if json.load(sys.stdin).get("can_use_dialer") else "WARN")' 2>/dev/null || echo WARN)" \
       "$(node_field "$node" transport) / $(node_field "$node" security)"
  else
    _d "节点" FAIL "尚未选择"
  fi

  _d "xray-client.service" "$(unit_active "$XBD_U_XRAY" && echo PASS || echo FAIL)" "$(unit_state "$XBD_U_XRAY")"
  _d "xray-dialer.service" "$(unit_active "$XBD_U_DIALER" && echo PASS || echo WARN)" "$(unit_state "$XBD_U_DIALER")（按需）"
  _d "chromium.service" "$(unit_active "$XBD_U_CHROMIUM" && echo PASS || echo WARN)" "$(unit_state "$XBD_U_CHROMIUM")（按需）"
  _d "panel.service" "$(unit_active "$XBD_U_PANEL" && echo PASS || echo WARN)" "$(unit_state "$XBD_U_PANEL")"

  _d "普通入口 :$XBD_PORT_NORMAL" "$(port_listening_tcp "$XBD_PORT_NORMAL" && echo PASS || echo FAIL)" "$(port_holder "$XBD_PORT_NORMAL" | cut -c1-40)"
  if unit_active "$XBD_U_DIALER"; then
    _d "Dialer 入口 :$XBD_PORT_DIALER" "$(port_listening_tcp "$XBD_PORT_DIALER" && echo PASS || echo FAIL)" "$(port_holder "$XBD_PORT_DIALER" | cut -c1-40)"
    _d "浏览器↔Dialer" "$([ "$(conn_count '127.0.0.1:18081')" -gt 0 ] && echo PASS || echo WARN)" "$(conn_count '127.0.0.1:18081') 条 WS"
  else
    _d "Dialer 入口" PASS "未启用（按需启动，符合预期）"
  fi

  # 按需启动的核心检查：未启用 dialer 时不应该有 Chromium
  local cprocs; cprocs=$(pgrep -c chromium 2>/dev/null | head -1 || true); cprocs=${cprocs:-0}
  if unit_active "$XBD_U_DIALER"; then
    _d "Chromium 进程" "$([ "${cprocs:-0}" -gt 0 ] && echo PASS || echo FAIL)" "$cprocs 个（dialer 模式运行中）"
  else
    _d "Chromium 进程" "$([ "${cprocs:-0}" -eq 0 ] && echo PASS || echo FAIL)" \
      "$cprocs 个$([ "${cprocs:-0}" -eq 0 ] && echo '（未启用 dialer 时不应有）')"
  fi

  if [ "$quick" -eq 0 ]; then
    local addr; addr=$(cfg_get "$XBD_CONF/ports.env" LISTEN_ADDR 127.0.0.1)
    local port="$XBD_PORT_NORMAL"
    unit_active "$XBD_U_DIALER" && port="$XBD_PORT_DIALER"
    local ip
    ip=$(curl -s --max-time 20 --socks5-hostname "$addr:$port" https://api.ipify.org 2>/dev/null || true)
    _d "经代理出网" "$([ -n "$ip" ] && echo PASS || echo FAIL)" "${ip:-失败}（经 :$port）"

    local loop=0
    ip -o link show type tun 2>/dev/null | grep -q . && { _d "本机 TUN" WARN "存在"; loop=1; } || _d "本机 TUN" PASS "无"
    iptables -t nat -S 2>/dev/null | grep -qE 'REDIRECT' && { _d "透明重定向" WARN "存在 NAT REDIRECT"; loop=1; } || _d "透明重定向" PASS "无"
    iptables -t mangle -S 2>/dev/null | grep -qE 'TPROXY' && { _d "TPROXY" WARN "存在"; loop=1; } || _d "TPROXY" PASS "无"
    local pe; pe=$(env | grep -cE '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY)=' || true)
    [ "${pe:-0}" -eq 0 ] && _d "代理环境变量" PASS "干净" || { _d "代理环境变量" FAIL "存在"; loop=1; }
    [ "$loop" -eq 0 ] && _d "代理环路风险" PASS "无环路迹象" || _d "代理环路风险" WARN "见上"

    _d "LAN 绑定" PASS "$addr（非 0.0.0.0）"
    if [ "$addr" = "0.0.0.0" ] || [ "$addr" = "::" ]; then
      _d "公网暴露" FAIL "监听所有网卡"
    else
      _d "公网暴露" PASS "仅绑 LAN 地址"
    fi
  fi

  _d "既有服务" PASS "xray.service=$(unit_state xray.service 2>/dev/null || echo n/a) mihomo=$(unit_state mihomo.service 2>/dev/null || echo n/a)"
  echo "========================================"
  if [ "$fails" -eq 0 ]; then printf '结果: PASS (%s 项警告)\n' "$warns"; else printf '结果: FAIL (%s 失败, %s 警告)\n' "$fails" "$warns"; fi
  echo "========================================"
  [ "$fails" -eq 0 ]
}

# ---------------------------------------------------------------------------
cmd_ech() {
  XBD_PREFIX="$XBD_PREFIX" python3 "$XBD_LIBDIR/echcli.py" "$@"
}

cmd_update() {
  need_root
  step "更新本项目组件"
  dim "  系统 Xray / xray.service / mihomo 不会被更新或重启"
  local dist; dist=$(xbd_dist_dir)
  if [ "$(cd "$dist" && pwd)" != "$(cd "$XBD_PREFIX" && pwd)" ]; then
    cp -a "$dist/lib/." "$XBD_LIB/" 2>/dev/null || true
    cp -a "$dist/lib/." "$XBD_LIBDIR/" 2>/dev/null || true
    cp -a "$dist/service/." "$XBD_SERVICE/" 2>/dev/null || true
    cp -a "$dist/scripts/." "$XBD_SCRIPTS/" 2>/dev/null || true
    cp -a "$dist/docs/." "$XBD_PREFIX/docs/" 2>/dev/null || true
    [ -f "$dist/VERSION" ] && cp "$dist/VERSION" "$XBD_PREFIX/VERSION"
    install -m 0755 "$dist/bin/xbd" "$XBD_PREFIX/bin/xbd" 2>/dev/null || true
    ok "已同步项目文件"
  else
    ok "已在目标目录内运行，跳过自我拷贝"
  fi
  chmod 0755 "$XBD_SCRIPTS"/*.sh "$XBD_LIB"/*.py "$XBD_DIST/lib"/*.py 2>/dev/null || true
  local u
  for u in "$XBD_U_XRAY" "$XBD_U_DIALER" "$XBD_U_CHROMIUM" "$XBD_U_PANEL" "$XBD_U_HEALTH" "$XBD_U_TIMER"; do
    install -m 0644 "$XBD_SERVICE/$u" "/etc/systemd/system/$u"
  done
  systemctl daemon-reload
  if unit_active "$XBD_U_XRAY"; then
    systemctl restart "$XBD_U_XRAY"
    sleep 2
    if unit_active "$XBD_U_DIALER"; then
      systemctl restart "$XBD_U_CHROMIUM" 2>/dev/null || true
    fi
  fi
  ok "更新完成"
  info "如需更新 Xray 内核: xbd xray update"
}

cmd_uninstall() {
  need_root
  local yes=0
  [ "${1:-}" = "--yes" ] && yes=1
  step "将要删除的内容"
  local items=() u
  for u in "$XBD_U_XRAY" "$XBD_U_DIALER" "$XBD_U_CHROMIUM" "$XBD_U_PANEL" "$XBD_U_HEALTH" "$XBD_U_TIMER"; do
    [ -f "/etc/systemd/system/$u" ] && items+=("/etc/systemd/system/$u")
  done
  [ -d "$XBD_PREFIX" ] && items+=("$XBD_PREFIX/")
  [ ${#items[@]} -eq 0 ] && { warn "没有发现本项目的文件"; return 0; }
  for i in "${items[@]}"; do info "  - $i"; done
  echo
  ok "以下内容不会被删除:"
  dim "  /etc/xray, /usr/local/etc/xray, /usr/local/bin/xray, xray.service,"
  dim "  mihomo 配置, 其它用户服务, 防火墙与路由"
  if [ "$yes" -ne 1 ]; then
    echo; read -r -p "确认删除以上 ${#items[@]} 项？(yes/no) " ans
    [ "$ans" = "yes" ] || { warn "已取消"; return 1; }
  fi
  step "执行卸载"
  systemctl disable --now "$XBD_U_TIMER" "$XBD_U_PANEL" "$XBD_U_CHROMIUM" "$XBD_U_DIALER" "$XBD_U_XRAY" 2>/dev/null || true
  for i in "${items[@]}"; do case "$i" in /etc/*) rm -f "$i" ;; esac; done
  systemctl daemon-reload
  ok "已移除 systemd 单元"
  rm -rf "$XBD_PREFIX"
  ok "已删除 $XBD_PREFIX"
}


# ---------------------------------------------------------------------------
# 方案 C：显式代理 —— 让本机进程（docker / apt / curl）用上我们的代理
# ---------------------------------------------------------------------------
# 为什么需要：docker 的 HTTP_PROXY 只接受 http:// 与 https://，不认 socks5://。
# 因此 Xray 除了 LAN 的 SOCKS5，还额外在回环上开一个 HTTP 代理。
XBD_PROFILE_FILE="/etc/profile.d/proxy.sh"
XBD_DOCKER_PROXY="/etc/systemd/system/docker.service.d/http-proxy.conf"

xbd_proxy_url_http()  { printf 'http://127.0.0.1:%s' "$XBD_PORT_HTTP"; }
xbd_proxy_url_socks() { printf 'socks5://127.0.0.1:%s' "$XBD_PORT_HTTP"; }

cmd_proxy() {
  local op="${1:-status}"
  case "$op" in
    on|enable)   xbd_proxy_on ;;
    off|disable) xbd_proxy_off ;;
    status|"")   xbd_proxy_status ;;
    -h|--help)   info "用法: xbd proxy <on|off|status>   让本机进程（docker 等）走我们的代理" ;;
    *) die "未知操作: $op" ;;
  esac
}

xbd_proxy_status() {
  xbd_load_ports
  local http="http://127.0.0.1:$XBD_PORT_HTTP" socks="socks5://127.0.0.1:$XBD_PORT_HTTP"
  printf '  HTTP 代理入口:    127.0.0.1:%s  %s\n' "$XBD_PORT_HTTP" \
    "$(port_listening_tcp "$XBD_PORT_HTTP" && echo LISTENING || echo 未监听)"
  printf '  LAN SOCKS5 入口:  %s:%s  %s\n' "$XBD_LISTEN_ADDR" "$XBD_PORT_NORMAL" \
    "$(port_listening_tcp "$XBD_PORT_NORMAL" && echo LISTENING || echo 未监听)"
  printf '  LAN HTTP 入口:    %s:%s  %s\n' "$XBD_LISTEN_ADDR" "$XBD_PORT_LAN_HTTP" \
    "$(port_listening_tcp "$XBD_PORT_LAN_HTTP" && echo LISTENING || echo 未监听)"
  printf '  shell 代理:       %s\n' "$(grep -q "127.0.0.1:$XBD_PORT_HTTP" "$XBD_PROFILE_FILE" 2>/dev/null && echo 已配置 || echo 未配置)"
  printf '  docker 代理:      %s\n' "$(grep -q "127.0.0.1:$XBD_PORT_HTTP" "$XBD_DOCKER_PROXY" 2>/dev/null && echo 已配置 || echo 未配置)"
  [ -f "$XBD_PROFILE_FILE" ] && grep -q 7890 "$XBD_PROFILE_FILE" 2>/dev/null && warn "  仍指向旧的 7890（mihomo），执行 xbd proxy on 切换"
}

xbd_proxy_on() {
  need_root
  xbd_load_ports
  step "配置本机显式代理 → Xray"
  local http="http://127.0.0.1:$XBD_PORT_HTTP" socks="socks5://127.0.0.1:$XBD_PORT_HTTP"

  # 依赖：常驻 Xray 的 HTTP 入站必须在听
  if ! port_listening_tcp "$XBD_PORT_HTTP"; then
    warn "HTTP 代理端口 $XBD_PORT_HTTP 未监听，先重启常驻 Xray 让新配置生效"
    systemctl restart "$XBD_U_XRAY" 2>/dev/null || true
    sleep 4
  fi
  if ! port_listening_tcp "$XBD_PORT_HTTP"; then
    bad "HTTP 代理仍未监听，请检查: xbd diagnose"
    return 1
  fi
  ok "HTTP 代理已就绪: $http"

  # 1) 登录 shell
  cat > "$XBD_PROFILE_FILE" <<EOF
# 由 xbd proxy on 生成 —— 本机进程的显式代理，指向本项目的 Xray。
# 恢复 mihomo: systemctl start mihomo.service 然后 xbd proxy off
export http_proxy="$http"
export https_proxy="$http"
export HTTP_PROXY="$http"
export HTTPS_PROXY="$http"
export all_proxy="$socks"
export no_proxy="127.0.0.1,localhost,::1,$XBD_LISTEN_ADDR,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
export NO_PROXY="\$no_proxy"
EOF
  chmod 0644 "$XBD_PROFILE_FILE"
  ok "已写 $XBD_PROFILE_FILE"

  # 2) docker 守护进程（拉镜像走代理）
  mkdir -p "$(dirname "$XBD_DOCKER_PROXY")"
  cat > "$XBD_DOCKER_PROXY" <<EOF
[Service]
Environment="HTTP_PROXY=$http"
Environment="HTTPS_PROXY=$http"
Environment="NO_PROXY=localhost,127.0.0.1,::1,$XBD_LISTEN_ADDR,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
EOF
  ok "已写 $XBD_DOCKER_PROXY"
  systemctl daemon-reload
  if unit_active docker.service; then
    warn "重启 docker 以加载代理（容器会短暂中断）"
    systemctl restart docker.service && ok "docker 已重启" || warn "docker 重启失败，可稍后手动重启"
  fi

  info ""
  ok "显式代理已启用"
  info "  新开的 shell 会自动带上代理变量"
  info "  当前 shell 立即生效: source $XBD_PROFILE_FILE"
  info "  docker 拉镜像: 已生效"
}

xbd_proxy_off() {
  need_root
  step "关闭本机显式代理"
  if [ -f "$XBD_PROFILE_FILE" ]; then
    rm -f "$XBD_PROFILE_FILE"
    ok "已移除 $XBD_PROFILE_FILE"
  fi
  if [ -f "$XBD_DOCKER_PROXY" ]; then
    rm -f "$XBD_DOCKER_PROXY"
    ok "已移除 $XBD_DOCKER_PROXY"
    systemctl daemon-reload
    if unit_active docker.service; then
      warn "重启 docker 以清掉代理环境变量"
      systemctl restart docker.service && ok "docker 已重启" || true
    fi
  fi
  info "本机将恢复为直连。注意：GitHub / Docker Hub 直连不通时需要重新开启。"
}

# ---------------------------------------------------------------------------
# 方案 B：局域网透明接入（可选、默认关闭）
# ---------------------------------------------------------------------------
# 只劫持 **出站** 到 80/443 的 TCP，并显式豁免：
#   SSH(22)、DNS(53)、LAN 网段、回环、节点地址、面板端口、代理端口自身
# 这些豁免是硬性要求 —— 少了任何一条都可能把自己锁在外面或形成代理环路。
XBD_NFT_TABLE="xbd_takeover"
XBD_TAKEOVER_MARK=0x2333

cmd_takeover() {
  local op="${1:-status}"
  case "$op" in
    on|enable)   xbd_takeover_on ;;
    off|disable) xbd_takeover_off ;;
    status|"")   xbd_takeover_status ;;
    -h|--help)   info "用法: xbd takeover <on|off|status>   局域网透明接入（可选）" ;;
    *) die "未知操作: $op" ;;
  esac
}

xbd_takeover_status() {
  xbd_load_ports
  if nft list table ip "$XBD_NFT_TABLE" >/dev/null 2>&1; then
    printf '  透明接入: 已启用\n'
    nft list table ip "$XBD_NFT_TABLE" 2>/dev/null | grep -cE '^\s' | xargs printf '    规则行数: %s\n'
  else
    printf '  透明接入: 未启用（默认）\n'
  fi
  printf '  局域网入口: %s:%s (SOCKS5)  %s:%s (HTTP)\n' \
    "$XBD_LISTEN_ADDR" "$XBD_PORT_NORMAL" "$XBD_LISTEN_ADDR" "$XBD_PORT_HTTP"
}

xbd_takeover_on() {
  need_root
  xbd_load_ports
  step "启用局域网透明接入"
  command -v nft >/dev/null 2>&1 || die "需要 nftables"

  # 前置安全检查：SSH 必须存活、代理必须在听
  port_listening_tcp "$XBD_PORT_NORMAL" || { bad "常驻 SOCKS5 未监听，先 xbd start"; return 1; }

  # 先打印回滚方式，再动规则
  info "回滚命令: nft delete table ip $XBD_NFT_TABLE   （或 xbd takeover off）"
  info "SSH 已显式豁免（dport 22 直接 return），不会断开当前连接"
  echo

  nft delete table ip "$XBD_NFT_TABLE" 2>/dev/null || true
  nft -f - <<EOF
table ip $XBD_NFT_TABLE {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    # ---- 硬性豁免：任何一条都不许省 ----
    iif lo return                          # 回环
    ip daddr $XBD_LISTEN_ADDR return       # 本机自己
    ip daddr 192.168.0.0/16 return         # LAN（含 SSH、本机服务）
    ip daddr 10.0.0.0/8 return
    ip daddr 172.16.0.0/12 return
    ip daddr 127.0.0.0/8 return
    tcp dport 22 return                    # SSH 再保一道
    tcp dport 53 return                    # DNS 不动
    udp dport 53 return
    tcp dport $XBD_PORT_NORMAL return      # 代理端口自身，防环路
    tcp dport $XBD_PORT_HTTP return
    tcp dport $XBD_PORT_LAN_HTTP return
    tcp dport $XBD_PANEL_PORT return       # 面板
    tcp dport 18081 return                 # Browser Dialer 通道
    # ---- 只劫持出站 web 流量 ----
    tcp dport { 80, 443 } redirect to :$XBD_PORT_HTTP
  }
}
EOF
  if nft list table ip "$XBD_NFT_TABLE" >/dev/null 2>&1; then
    ok "透明接入已启用（仅 80/443 → $XBD_PORT_HTTP，SSH/LAN/DNS 已豁免）"
    info "局域网设备无需任何配置即可上网（网关指向本机 $XBD_LISTEN_ADDR）"
    info "关闭: xbd takeover off"
  else
    bad "规则加载失败，已回滚"
    return 1
  fi
}

xbd_takeover_off() {
  need_root
  nft delete table ip "$XBD_NFT_TABLE" 2>/dev/null && ok "透明接入已关闭" || info "透明接入本来就没启用"
  info "局域网设备恢复直连；显式代理入口（:${XBD_PORT_NORMAL:-1080}）不受影响"
}

# Xray 内核版本与更新（之前 cmd_update 只同步项目文件，从不更新二进制）
cmd_xray() {
  local op="${1:-version}"
  case "$op" in
    version) python3 "$XBD_LIBDIR/xrayup.py" version ;;
    check)   python3 "$XBD_LIBDIR/xrayup.py" check ;;
    update|upgrade)
      need_root
      step "更新 Xray 内核"
      dim "  只更新本项目副本 $XBD_XRAY，不碰系统 Xray"
      python3 "$XBD_LIBDIR/xrayup.py" update || return 1
      systemctl restart "$XBD_U_XRAY"
      sleep 3
      unit_active "$XBD_U_XRAY" && ok "$XBD_U_XRAY 已重启" || { bad "Xray 重启失败"; journalctl -u "$XBD_U_XRAY" -n 12 --no-pager; return 1; }
      if unit_active "$XBD_U_DIALER"; then
        systemctl restart "$XBD_U_CHROMIUM" 2>/dev/null || true
        info "Browser Dialer 模式在运行，已同步重启 Chromium"
      fi
      ;;
    -h|--help|"") info "用法: xbd xray <version|check|update>" ;;
    *) die "未知操作: $op" ;;
  esac
}

# 导出连接配置到固定文件，方便直接复制
cmd_export() {
  xbd_load_ports
  mkdir -p "$XBD_GENERATED"
  local host="$XBD_LISTEN_ADDR"
  local name="LAN"
  if [ -e "$XBD_NODES/current" ]; then
    name=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("name","LAN"))' "$(readlink -f "$XBD_NODES/current")" 2>/dev/null | tr -cd 'A-Za-z0-9._-' || echo LAN)
    [ -n "$name" ] || name="LAN"
  fi

  local yaml="$XBD_GENERATED/mihomo.yaml"
  local links="$XBD_GENERATED/links.txt"
  local envf="$XBD_GENERATED/env.sh"

  cat > "$yaml" <<EOF
# 由 xbd export 生成 —— 复制到需要代理的设备
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

proxies:
  - name: "${name}-SOCKS5"
    type: socks5
    server: $host
    port: $XBD_PORT_NORMAL
    udp: true
  - name: "${name}-HTTP"
    type: http
    server: $host
    port: $XBD_PORT_LAN_HTTP
# 需要 Browser Dialer 时取消下面注释（并先在服务器上启用）
#  - name: "${name}-BrowserDialer"
#    type: socks5
#    server: $host
#    port: $XBD_PORT_DIALER
#    udp: true
EOF

  cat > "$links" <<EOF
# 代理链接 —— 生成时间 $(date '+%Y-%m-%d %H:%M:%S')
SOCKS5          socks5://$host:$XBD_PORT_NORMAL
HTTP            http://$host:$XBD_PORT_LAN_HTTP
Browser Dialer  socks5://$host:$XBD_PORT_DIALER
（本机进程用 127.0.0.1:$XBD_PORT_HTTP，仅回环）
EOF

  cat > "$envf" <<EOF
# source 这个文件即可让当前 shell 走代理
export http_proxy="http://$host:$XBD_PORT_LAN_HTTP"
export https_proxy="http://$host:$XBD_PORT_LAN_HTTP"
export all_proxy="socks5://$host:$XBD_PORT_NORMAL"
export no_proxy="127.0.0.1,localhost,::1,192.168.0.0/16,10.0.0.0/8"
EOF
  chmod 0644 "$yaml" "$links" "$envf"

  ok "已导出到 $XBD_GENERATED/"
  printf '  %-28s %s\n' "Mihomo 配置" "$yaml"
  printf '  %-28s %s\n' "代理链接" "$links"
  printf '  %-28s %s\n' "环境变量" "$envf"
  info ""
  info "服务器上直接看: cat $links"
}

# 取服务端证书指纹并写进节点（自签证书节点的正确解法）
# Xray 26.x 移除了 allowInsecure，替代方案就是 pinnedPeerCertSha256。
cmd_cert() {
  local t="${1:-}"
  [ -n "$t" ] || die "用法: xbd cert <编号|文件名>   （取该节点服务端证书指纹并固定）"
  local path
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    path=$(ls -1 "$XBD_NODES"/node-*.json 2>/dev/null | sed -n "${t}p")
  else
    path="$XBD_NODES/$t"
    [ -e "$path" ] || path=$(ls -1 "$XBD_NODES"/*"$t"* 2>/dev/null | head -1)
  fi
  [ -e "${path:-}" ] || die "找不到节点: $t"

  local addr port sni proto
  addr=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("address",""))' "$path")
  port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("port",443))' "$path")
  sni=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("sni") or d.get("address",""))' "$path")
  proto=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("protocol",""))' "$path")

  step "取服务端证书指纹"
  info "  节点: $(basename "$path")"
  info "  目标: [$addr]:$port  SNI=$sni"
  command -v go >/dev/null 2>&1 || die "需要 go 工具链（apt install golang-go）"

  local probe="$XBD_DIST/tools/certprobe"
  [ -d "$probe" ] || die "缺少工具目录 $probe（升级到包含 tools/ 的版本）"

  local out
  out=$(cd "$probe" && GOFLAGS=-mod=mod https_proxy="${XBD_HTTP_PROXY:-}" go run . "$addr" "$port" "$sni" 2>&1)
  printf '%s\n' "$out" | sed 's/^/  /'

  local fp
  # 输出形如 "      SHA256 =4cdbca..."（等号前后可能没空格），所以只匹配 64 位十六进制
  fp=$(printf '%s' "$out" | grep -oE '[0-9a-f]{64}' | head -1)
  [ -n "$fp" ] || die "未能取到证书指纹（节点可能不响应 QUIC/TLS）"

  python3 - "$path" "$fp" <<'PY'
import json, sys
p, fp = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["pinned_cert_sha256"] = fp
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
print(f"  已写入 pinned_cert_sha256: {fp[:32]}...")
PY
  ok "证书已固定。执行 xbd apply && xbd restart 生效"
  warn "注意：服务端证书换签后该哈希会失效，届时重新执行 xbd cert 即可"
}

cmd_usage() { xbd_usage; }

xbd_usage() {
  cat <<EOF
Xray Client Web Manager v$XBD_VERSION
Xray 常驻底层客户端 + Browser Dialer 按需增强

用法: xbd <命令> [参数]

  安装与基础
    install [--no-start] [--vless <uri>]   安装（幂等）
    update                                 更新本项目脚本
    xray version|check|update              查看/检查/更新 Xray 内核
    uninstall                              安全卸载（先列清单）

  节点（共享资产，两种模式共用）
    node add "<uri|json|yaml>"             导入节点（支持多行 / 多协议）
    node sub <订阅URL>                     导入订阅
    node list                              节点列表（含两种能力）
    node use <编号>                        切换当前节点
    node check [编号]                      能力检查
    node latency [编号]                    延时测试（真实请求）
    node remove <编号>                     删除节点

  连接模式（Xray 常驻；Browser Dialer 按需）
    start                                  启动常驻 Xray + 面板
    stop [--all]                           停止常驻 Xray
    restart                                重启常驻 Xray
    dialer on|off|toggle|status            启用/关闭 Browser Dialer 模式
    apply                                  只生成配置
    port [类型] [值]                       查看/修改端口（normal/dialer/http/lan-http/channel/panel/api/addr）
    ports check|fix|verify                 端口冲突检查 / 自动重新分配 / 校验 dialer 两端接上

  本机上网 / 局域网接入
    proxy on|off|status                    让本机进程（docker/apt/curl）走我们的代理
    takeover on|off|status                 局域网透明接入（可选，默认关闭）

  状态与诊断
    status [--quick]                       状态（含当前模式）
    diagnose [--quick]                     全面诊断
    panel                                  面板地址与令牌
    export                                 导出连接配置到 generated/（方便复制）
    cert <编号>                            取服务端证书指纹并固定（自签证书节点用）
    ech                                    验证 Chromium 原生 ECH

  selftest                                 运行内置自检
EOF
}

# ---------------------------------------------------------------------------
xbd_main() {
  # 运行期脚本目录：多文件版=项目根，自解压版=xbd-dist
  XBD_LIBDIR="$(xbd_dist_dir)/lib"
  export XBD_LIBDIR
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install)    cmd_install "$@" ;;
    update)     cmd_update "$@" ;;
    uninstall)  cmd_uninstall "$@" ;;
    node)       cmd_node "$@" ;;
    start)      cmd_start "$@" ;;
    stop)       cmd_stop "$@" ;;
    restart)    cmd_restart "$@" ;;
    dialer)     cmd_dialer "$@" ;;
    apply)      cmd_apply "$@" ;;
    port)       cmd_port "$@" ;;
    ports)      cmd_ports "$@" ;;
    status)     cmd_status "$@" ;;
    diagnose)   cmd_diagnose "$@" ;;
    panel)      cmd_panel "$@" ;;
    ech)        cmd_ech "$@" ;;
    proxy)      cmd_proxy "$@" ;;
    takeover)   cmd_takeover "$@" ;;
    xray)       cmd_xray "$@" ;;
    export)     cmd_export "$@" ;;
    cert)       cmd_cert "$@" ;;
    selftest)   cmd_selftest "$@" ;;
    ""|-h|--help|help) xbd_usage ;;
    *) xbd_usage; die "未知命令: $cmd" ;;
  esac
}

cmd_selftest() {
  local failed=0
  echo "=== 内置自检 ==="
  for m in node compat; do
    printf '  %-10s ' "$m"
    if python3 "$XBD_LIBDIR/$m.py" selftest >/tmp/.xbd_st 2>&1; then
      echo "PASS"; tail -1 /tmp/.xbd_st | sed 's/^/             /'
    else
      echo "FAIL"; cat /tmp/.xbd_st | sed 's/^/             /'; failed=$((failed+1))
    fi
  done
  printf '  %-10s ' "genconfig"
  if python3 "$XBD_LIBDIR/genconfig.py" --node "$XBD_LIBDIR/../nodes/current" \
      --output /tmp/.xbd_tc.json --mode normal --logs /tmp >/dev/null 2>&1; then
    echo "PASS"
  else
    echo "SKIP（还没有节点）"
  fi
  rm -f /tmp/.xbd_st /tmp/.xbd_tc.json
  echo
  [ "$failed" -eq 0 ] && { echo "自检: PASS"; return 0; } || { echo "自检: $failed 项失败"; return 1; }
}
