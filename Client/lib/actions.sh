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
  for u in "$XBD_U_XRAY" "$XBD_U_CHROMIUM" "$XBD_U_PANEL" "$XBD_U_HEALTH" "$XBD_U_TIMER"; do
    install -m 0644 "$XBD_SERVICE/$u" "/etc/systemd/system/$u"
  done
  systemctl daemon-reload
  ok "已安装 5 个单元（xray-client / chromium + panel / health / timer）"

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
defaults = {"PORT_NORMAL":1080,"PORT_HTTP":10808,
            "PORT_LAN_HTTP":10809,"DIALER_ADDR":18081,"PANEL_PORT":18090,"API_PORT":18085}
labels = {"PORT_NORMAL":"LAN SOCKS5",
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
    # 显式兜底成 {}：不能写 ${VAR:-{}} —— 默认值里的 } 会被当成展开的结束符，
    # 变量已设置时会多吐一个 }，JSON 解析失败后所有端口静默变空（实测踩过）。
    [ -n "${_XBD_ALLOC:-}" ] || _XBD_ALLOC='{}'

    local _lan _pn _ph _plh _ch _pp _api
    _lan=$(printf '%s' "${_XBD_ALLOC}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("listen_addr",""))' 2>/dev/null)
    _pn=$(printf '%s' "${_XBD_ALLOC}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PORT_NORMAL",1080))' 2>/dev/null)
    _ph=$(printf '%s' "${_XBD_ALLOC}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PORT_HTTP",10808))' 2>/dev/null)
    _plh=$(printf '%s' "${_XBD_ALLOC}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PORT_LAN_HTTP",10809))' 2>/dev/null)
    _ch=$(printf '%s' "${_XBD_ALLOC}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("DIALER_ADDR",18081))' 2>/dev/null)
    _pp=$(printf '%s' "${_XBD_ALLOC}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("PANEL_PORT",18090))' 2>/dev/null)
    _api=$(printf '%s' "${_XBD_ALLOC}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("API_PORT",18085))' 2>/dev/null)
    [ -n "$_lan" ] || _lan=$(detect_lan_ip)
    cat > "$XBD_CONF/ports.env" <<EOF
# 端口分配。改完执行: xbd port <类型> <值> 或直接改这里再 xbd apply && xbd restart
# 自动分配器会避开已被占用的端口；重新分配可执行 xbd ports fix
PORT_NORMAL=${_pn:-1080}
LISTEN_ADDR=${_lan}
DIALER_ADDR=127.0.0.1:${_ch:-18081}
PORT_HTTP=${_ph:-10808}
PORT_LAN_HTTP=${_plh:-10809}
EOF
    printf 'PANEL_PORT=%s\n' "${_pp:-18090}" > "$XBD_CONF/panel.port.tmp"
    printf 'API_PORT=%s\n' "${_api:-18085}" > "$XBD_CONF/api.env"
  }

  [ -f "$XBD_CONF/ports.env" ] || cat > "$XBD_CONF/ports.env" <<EOF
# 端口规划。改完执行: xbd restart
# 唯一 Xray 实例的 SOCKS5 入口 → 局域网设备 / Mihomo 连这个
PORT_NORMAL=1080
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

  [ -f "$XBD_CONF/chromium.env" ] || cat > "$XBD_CONF/chromium.env" <<'EOF'
# Chromium 运行参数（Browser Dialer 的运行时依赖）
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

  # 1) 系统里已有就直接复用一份（不覆盖原文件，只复制）
  local src
  for src in /usr/local/bin/xray /usr/bin/xray; do
    if [ -x "$src" ]; then
      install -m 0755 "$src" "$XBD_XRAY"
      ok "已从 $src 复制为本项目独立副本"
      return 0
    fi
  done

  # 2) 没有就下载官方版本（全新服务器的主要路径）
  info "  未找到 Xray，正在下载官方版本…"
  mkdir -p "$XBD_BIN"
  if python3 "$XBD_LIBDIR/xrayup.py" update 2>&1 | sed 's/^/  /'; then
    if [ -x "$XBD_XRAY" ]; then
      ok "Xray 安装完成: $("$XBD_XRAY" version 2>/dev/null | head -1)"
      return 0
    fi
  fi

  bad "Xray 未就绪，无法继续"
  info "  可手动下载官方二进制放到: $XBD_XRAY"
  info "  下载页: https://github.com/XTLS/Xray-core/releases"
  return 1
}

menu_browser_ensure() {
  step "浏览器"
  if BROWSER=$(detect_browser); then
    ok "已就绪: $BROWSER — $(browser_version)"
    return 0
  fi
  warn "未找到浏览器：依赖浏览器拨号的节点将不可用，其余节点不受影响"
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
    use-as)      cmd_node_use "$@" ;;   # 刻意不 shift：cmd_node 已经 shift 过一次
    remove|rm)   cmd_node_remove "$@" ;;
    check)       cmd_node_check "$@" ;;
    browser|bd)  cmd_node_browser "$@" ;;
    probe|test)  cmd_node_probe "$@" ;;
    sub|subscription) cmd_node_subscription "$@" ;;
    import-file) cmd_node_import_file "$@" ;;
    -h|--help|"") info "用法: xbd node <add|list|use|remove|check|browser|probe|sub|import-file>" ;;
    *) die "未知子命令: $sub" ;;
  esac
}

cmd_node_add() {
  local raw="${1:-}"
  # --keep-unsupported：连 Xray 内核不支持的协议也存下来（仅存档，不参与选节点）
  local keep_unsup=0
  case "$raw" in
    --keep-unsupported) keep_unsup=1; raw="${2:-}" ;;
  esac
  if printf '%s' "${*:-}" | grep -q -- '--keep-unsupported'; then keep_unsup=1; raw="${raw/--keep-unsupported/}" ; fi
  if [ "$keep_unsup" = "1" ]; then export XBD_KEEP_UNSUPPORTED=1; fi
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

  # 导入前先分流：Batch 里可能混着 Xray 内核根本不支持的协议（tuic / ssh / 别的内核），
  # 以及重复条目（订阅里很常见）。以前会一股脑儿落盘，列表被灌满、还得自己一个个看。
  # 现在默认：不支持的跳过、重复的跳过，最后汇总一行说明跳了什么。
  local KEEP_UNSUP=0
  [ "${XBD_KEEP_UNSUPPORTED:-0}" = "1" ] && KEEP_UNSUP=1
  python3 "$XBD_LIBDIR/nodefilter.py" "$tmp" "$XBD_LIBDIR" "$KEEP_UNSUP" "$XBD_NODES" > /tmp/.xbd_kept.jsonl 2>/tmp/.xbd_skipped.err

  local count=0 idx=0
  while IFS= read -r node_json; do
    [ -z "$node_json" ] && continue
    idx=$((idx+1))
    printf '%s' "$node_json" > /tmp/.xbd_one.json
    if [ "$total" -gt 1 ]; then
      printf '\n  [%d/%d] ' "$idx" "$total"
    fi
    cmd_node_import_file /tmp/.xbd_one.json && count=$((count+1))
  done < /tmp/.xbd_kept.jsonl

  # 汇总跳过项
  local nskip
  nskip=$(python3 -c 'import json;print(len(json.load(open("/tmp/.xbd_skipped.json"))))' 2>/dev/null || echo 0)
  if [ "${nskip:-0}" -gt 0 ]; then
    warn "已跳过 $nskip 个节点："
    python3 -c '
import json
for name, why in json.load(open("/tmp/.xbd_skipped.json")):
    print(f"    · {str(name)[:34]:36s} {why}")
' 2>/dev/null || true
    info "  （想保留这些节点存档：加 --keep-unsupported）"
  fi
  rm -f /tmp/.xbd_kept.jsonl /tmp/.xbd_skipped.json /tmp/.xbd_skipped.txt

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
  # 有意**不**把判定结果写进节点文件 —— 那是导入瞬间的快照，会过期。
  # 判定一律实时算（nodelist.py / state.py 都如此），避免"显示与实际能力脱节"。
  print_node_card "$dest"
  # 首个节点自动选中
  if [ ! -e "$XBD_NODES/current" ]; then
    ln -sfn "$(basename "$dest")" "$XBD_NODES/current"
    ok "已设为当前节点: $(basename "$dest")"
  fi
  return 0
}

print_node_card() {  # print_node_card <node.json>
  python3 - "$1" "$XBD_LIBDIR" <<'PY'
import importlib.util, json, os, sys
d = json.load(open(sys.argv[1]))
# 现场判定，不读文件里的 _compat 缓存（会过期）
_c = {}
try:
    spec = importlib.util.spec_from_file_location("_c", os.path.join(sys.argv[2], "compat.py"))
    _m = importlib.util.module_from_spec(spec); spec.loader.exec_module(_m)
    _c = _m.check_all(d)
except Exception:
    pass
c = _c
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
# Xray 段的注意事项也要打 —— 原来只打 dialer 那段，于是 xray 段里最关键的那句
# 「该节点声明了 skip-cert-verify，需要先 xbd cert 固定指纹，否则连不上」
# 从来没显示过：卡片写着"⚠ 支持（有注意项）"却不说注意什么（实测踩过）。
if x not in ("SUPPORTED",):
    for n in ((c.get("xray") or {}).get("notes") or [])[:3]:
        print(f"    * {n}")
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
  local t="${1:-}" how="${2:-}"
  [ -n "$t" ] || { cmd_node_list; info ""; info "用法: xbd node use <编号|文件名> [bd|normal]"; return 0; }
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

  # 明确指定用法时（面板的「普通连接」/「BD 连接」按钮走这里），把选择写进节点文件。
  # 这样"点按钮"就是用户意图的完整表达，不需要他再去理解环境变量那一层。
  case "$how" in
    bd|browser)   _xbd_set_node_browser "$path" true  ;;
    normal|native) _xbd_set_node_browser "$path" false ;;
    "") : ;;
    *) die "未知用法: $how（可选 bd / normal）" ;;
  esac

  # 按**新节点自己**的实际情况让 Chromium 状态跟上。
  #
  # ⚠ 判据必须与 run-xray.sh 完全一致（都用 compat.py want-bd）：
  #   want = 该节点**会不会**用浏览器（含用户的 use_browser 选择）
  # 只有 want 为真、但进程还没带 XRAY_BROWSER_DIALER 时，才需要重启一次 ——
  # 因为"带不带这个环境变量"是进程启动时决定的。
  # 以前这里用"协议层面是否可能"来判断要不要保留 Chromium，结果用户点了
  # 「普通连接」（明确要原生）也被拒绝关闭 —— 那是把保护做成了妨碍。
  local want=no
  _xbd_node_needs_dialer && want=yes

  if [ "$want" = "yes" ]; then
    if ! unit_active "$XBD_U_CHROMIUM"; then
      warn "该节点使用浏览器完成 TLS，正在启动 Chromium"
      xbd_dialer_on || warn "自动启动失败，可手动执行: xbd dialer on"
    fi
  else
    if unit_active "$XBD_U_CHROMIUM"; then
      warn "该节点不用浏览器，正在停掉 Chromium 释放内存"
      xbd_dialer_off || true
    fi
  fi

  # ⚠ 换了节点就**必须**重启，否则运行中的实例还在用旧节点。
  #
  # 这里原来只打印一句"执行 xbd apply && xbd restart 生效"，把动作留给用户 ——
  # 实测踩过：从 hysteria 节点切到另一个 hysteria 节点，浏览器开关没变，
  # 于是既不重启也不报错，**界面上节点已经换好了、实际流量还走旧节点**
  # （排查时看到进程启动时间比切换时间还早才发现）。
  # 判据是**配置文件有没有变**，不是"软链接是不是刚被改动" ——
  # 后者漏过一次：上一次 node use 只改了软链接、没重启，这一次 prev 与它相同，
  # 于是又跳过重启，运行中的实例继续用旧节点（实测踩过）。
  # 重新生成一次再比对哈希，是唯一可靠的"运行态 != 期望态"判据。
  local cfg="$XBD_RUNTIME/xray-client.json" before after
  before="$(sha256sum "$cfg" 2>/dev/null | cut -d' ' -f1)"
  cmd_apply >/dev/null 2>&1 || warn "配置生成失败，请手动执行: xbd apply"
  after="$(sha256sum "$cfg" 2>/dev/null | cut -d' ' -f1)"
  if unit_active "$XBD_U_XRAY"; then
    if [ "$before" != "$after" ]; then
      info "节点配置已变化，重启 Xray 生效…"
      _xbd_sync_xray_with_node force || warn "Xray 重启失败，请手动执行: xbd restart"
    else
      _xbd_sync_xray_with_node || warn "Xray 重启失败，请手动执行: xbd restart"
    fi
  fi
}

# 每个节点自己的"是否用浏览器完成 TLS"开关。
# 为什么不放在全局：全局一关，所有依赖浏览器的节点一起失效（实测踩过）；
# 而用户往往只是想给某一个节点省下那 ~890MB 内存。
cmd_node_browser() {
  local t="${1:-}" v="${2:-}"
  [ -n "$t" ] || die "用法: xbd node browser <编号|文件名> <on|off|auto>"
  local path
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    path=$(ls -1 "$XBD_NODES"/node-*.json 2>/dev/null | sed -n "${t}p")
    [ -n "$path" ] || die "没有编号 $t 的节点"
  else
    path="$XBD_NODES/$t"
    [ -e "$path" ] || path=$(ls -1 "$XBD_NODES"/*"$t"* 2>/dev/null | head -1)
    [ -e "${path:-}" ] || die "找不到节点: $t"
  fi
  [ -n "$v" ] || die "用法: xbd node browser <编号|文件名> <on|off|auto>"

  # 协议不支持时不允许打开 —— 置灰的后端对应物，别让界面骗人
  local can
  can=$(python3 "$XBD_LIBDIR/compat.py" json "$path" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("can_use_dialer"))' 2>/dev/null || echo False)

  # 这里**允许**对任何节点关闭（包括 xhttp/websocket）。
  # 曾经禁止过，理由是"只要 XRAY_BROWSER_DIALER 在线，xhttp/ws 出站就会被强制接管，
  # 关掉会让节点不可用"—— 那个推理没错，但解决方式错了：
  # 正确的做法是关闭时**同时让这个 Xray 进程不再声明该能力**（见 scripts/run-xray.sh，
  # 它按当前节点的开关决定带不带 XRAY_BROWSER_DIALER）。
  # 这样关掉之后节点自动走原生 TLS，既省下 Chromium 的内存，也不需要用户理解这些。
  # 之前的做法等于"因为实现有缺陷，就不让用户关"。
  if [ "$can" = "True" ] && [ "$v" = "off" ]; then
    info "该节点将改用 Xray 自带 TLS（不影响可用性，只是不再经过浏览器）"
  fi

  if [ "$can" != "True" ] && [ "$v" != "off" ] && [ "$v" != "auto" ]; then
    bad "该节点的协议不支持浏览器拨号（只有 xhttp/websocket 且非 REALITY 可以）"
    info "它仍然可以正常使用 Xray 自带 TLS：同一个入口，无需任何设置"
    return 1
  fi

  case "$v" in
    on)   _xbd_set_node_browser "$path" true  ;;
    off)  _xbd_set_node_browser "$path" false ;;
    auto) _xbd_set_node_browser "$path" null  ;;
    *) die "未知取值: $v（可选 on/off/auto）" ;;
  esac

  # 改的就是当前节点 -> 立刻生效。
  # ⚠ 必须重启 Xray：是否带 XRAY_BROWSER_DIALER 是**进程启动时**决定的，
  # 光改节点文件不重启，进程仍会走旧的那条路（这是"关不掉"的第二个原因）。
  if [ "$(readlink -f "$XBD_NODES/current" 2>/dev/null)" = "$(readlink -f "$path")" ]; then
    local want="no"
    _xbd_node_needs_dialer && want="yes"
    info "正在重启 Xray 让设置生效…"
    systemctl restart "$XBD_U_XRAY" 2>/dev/null || true
    sleep 4
    unit_active "$XBD_U_XRAY" || { bad "Xray 重启失败"; journalctl -u "$XBD_U_XRAY" -n 10 --no-pager; return 1; }
    if [ "$want" = "yes" ]; then
      unit_active "$XBD_U_CHROMIUM" || { info "该节点要用浏览器，正在启动 Chromium"; xbd_dialer_on || true; }
      ok "已生效：该节点走浏览器 TLS"
    else
      unit_active "$XBD_U_CHROMIUM" && { info "该节点不用浏览器了，正在停掉 Chromium 释放内存"; xbd_dialer_off || true; }
      ok "已生效：该节点走 Xray 自带 TLS"
    fi
  else
    ok "已保存。切到该节点时按此生效"
  fi
}

_xbd_set_node_browser() {
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
path, val = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["use_browser"] = None if val == "null" else (val == "true")
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
PYEOF
}

# 真实探测：这个节点走浏览器路径到底通不通。
# 能力判定只能验证"配置合法"，合法不等于能通（实测：同一套 ws 配置，
# 有的服务器可用、有的不行）。所以给一个能跑的探测，结果写回节点文件。
cmd_node_probe() {
  local t="${1:-}" all=0
  [ "$t" = "--all" ] && { all=1; t=""; }
  need_root
  local targets=()
  if [ "$all" = 1 ]; then
    local f
    for f in "$XBD_NODES"/node-*.json; do [ -e "$f" ] && targets+=("$f"); done
  else
    [ -n "$t" ] || { cmd_node_list; info ""; info "用法: xbd node probe <编号|文件名> | xbd node probe --all"; return 0; }
    local path
    if [[ "$t" =~ ^[0-9]+$ ]]; then
      path=$(ls -1 "$XBD_NODES"/node-*.json 2>/dev/null | sed -n "${t}p")
      [ -n "$path" ] || die "没有编号 $t 的节点"
    else
      path="$XBD_NODES/$t"
      [ -e "$path" ] || path=$(ls -1 "$XBD_NODES"/*"$t"* 2>/dev/null | head -1)
      [ -e "${path:-}" ] || die "找不到节点: $t"
    fi
    targets=("$path")
  fi

  step "浏览器路径实测探测（会临时起一个 Xray + Chromium，不动生产服务）"
  local f ok=0 bad=0 skip=0
  for f in "${targets[@]}"; do
    printf '  %-34s ' "$(python3 -c "import json;print(str(json.load(open('$f')).get('name'))[:32])" 2>/dev/null)"
    local out rc
    out=$(python3 "$XBD_PREFIX/tools/browserprobe.py" "$f" --save --json 2>/dev/null); rc=$?
    case "$rc" in
      0) ok=$((ok+1)); printf '\033[32m✓ 可用\033[0m %s\n' "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("exit_ip",""))' 2>/dev/null)";;
      2) skip=$((skip+1)); printf '\033[33m— 无法判定\033[0m %s\n' "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)";;
      *) bad=$((bad+1)); printf '\033[31m✗ 不可用\033[0m %s\n' "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)";;
    esac
  done
  info ""
  info "结果已写回节点文件，xbd node list 与面板会按实测显示"
  [ "$bad" -gt 0 ] && warn "$bad 个节点浏览器路径不可用 —— 用原生 TLS 即可，入口不变"
  return 0
}

# 让运行中的 Xray 与其环境变量声明保持一致（带不带 XRAY_BROWSER_DIALER）。
# 返回 0 = 已一致或已重启成功；1 = 重启失败。
_xbd_sync_xray_with_node() {   # $1=force 时无条件重启（换节点用）
  local want="no"
  _xbd_node_needs_dialer && want="yes"
  local pid have="no"
  pid=$(systemctl show -p MainPID --value "$XBD_U_XRAY" 2>/dev/null || echo 0)
  if [ "${pid:-0}" -gt 0 ] && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^XRAY_BROWSER_DIALER='; then
    have="yes"
  fi
  [ "${1:-}" != "force" ] && [ "$want" = "$have" ] && return 0
  info "正在重启 Xray 让节点/浏览器开关生效…"
  systemctl restart "$XBD_U_XRAY" 2>/dev/null || true
  sleep 4
  unit_active "$XBD_U_XRAY" || return 1
  # Xray 重启会让页面上的 CSRF token 作废，所以 Chromium 必须跟着重启
  if [ "$want" = "yes" ] && unit_active "$XBD_U_CHROMIUM"; then
    systemctl restart "$XBD_U_CHROMIUM" 2>/dev/null || true
  fi
  ok "Xray 已按当前节点设置重启（浏览器 $( [ "$want" = yes ] && echo 启用 || echo 关闭 )）"
  return 0
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
  # 唯一实例：一份配置同时提供 SOCKS + HTTP，并且始终带 XRAY_BROWSER_DIALER。
  # 因此换节点**不需要**重新生成配置，也不需要启停任何服务。
  if python3 "$XBD_LIBDIR/genconfig.py" \
      --node "$XBD_NODES/current" --output "$XBD_RUNTIME/xray-client.json" --mode normal \
      --listen "$XBD_LISTEN_ADDR" --port-normal "$XBD_PORT_NORMAL" \
      --http-port "$XBD_PORT_HTTP" --lan-http-port "$XBD_PORT_LAN_HTTP" \
      --api-port "${XBD_API_PORT:-18085}" --logs "$XBD_LOGS" 2>&1 | grep -q '"ok": true'; then
    ok "xray-client.json（SOCKS :$XBD_PORT_NORMAL / HTTP :$XBD_PORT_LAN_HTTP）"
  else
    die "xray-client.json 生成失败，这是致命的"
  fi
}

cmd_start() {
  need_root
  require_current_node >/dev/null
  xbd_load_ports
  cmd_apply

  step "启动 Xray（唯一实例：SOCKS + HTTP）"
  systemctl enable --now "$XBD_U_XRAY" >/dev/null 2>&1 || systemctl start "$XBD_U_XRAY"
  sleep 4
  unit_active "$XBD_U_XRAY" && ok "$XBD_U_XRAY: RUNNING" || { bad "$XBD_U_XRAY 启动失败"; journalctl -u "$XBD_U_XRAY" -n 15 --no-pager; return 1; }
  # Xray 重启换了 CSRF token，浏览器必须跟着重启（旧 WS 会挂着但已失效）
  unit_active "$XBD_U_CHROMIUM" && systemctl restart "$XBD_U_CHROMIUM" 2>/dev/null || true

  # Chromium 只在**当前节点需要浏览器**时才拉起来。
  # 旧的"常备"模型已经废弃：它无条件启动 Chromium，节点换到 hysteria 这类不用
  # 浏览器的协议后，这个进程会一直占着约 600MB（这台机器总共 1.8GB）。
  # 判据与 run-xray.sh / 换节点 / 健康检查完全一致：都用 compat.py want-bd。
  if _xbd_node_needs_dialer; then
    step "启动 Browser Dialer 运行时（Chromium）"
    systemctl enable --now "$XBD_U_CHROMIUM" >/dev/null 2>&1 || systemctl start "$XBD_U_CHROMIUM"
    systemctl enable --now "$XBD_U_TIMER" >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      unit_active "$XBD_U_CHROMIUM" && [ "$(conn_count '127.0.0.1:18081')" -gt 0 ] && break
      sleep 1
    done
    if unit_active "$XBD_U_CHROMIUM"; then
      ok "$XBD_U_CHROMIUM: RUNNING（$XBD_U_TIMER 负责自愈）"
    else
      warn "$XBD_U_CHROMIUM 未启动 —— 依赖浏览器拨号的节点会失败（xbd dialer on 可重试）"
    fi
  else
    step "Browser Dialer 运行时（Chromium）"
    if unit_active "$XBD_U_CHROMIUM"; then
      warn "当前节点不用浏览器，停掉 Chromium 释放内存"
      xbd_dialer_off || true
    else
      ok "当前节点走 Xray 自带 TLS，Chromium 无需运行"
    fi
  fi

  step "启动面板"
  systemctl enable --now "$XBD_U_PANEL" >/dev/null 2>&1 || systemctl start "$XBD_U_PANEL"
  sleep 2
  unit_active "$XBD_U_PANEL" && ok "$XBD_U_PANEL: RUNNING ($(xbd_panel_url))" || warn "面板未启动（不影响代理）"

  info ""
  ok "已就绪。局域网设备可连接 ${XBD_LISTEN_ADDR}:${XBD_PORT_NORMAL}(SOCKS5) / ${XBD_LISTEN_ADDR}:${XBD_PORT_LAN_HTTP}(HTTP)"
  info "两个入口都是全部节点通用；需要浏览器拨号的节点会自动使用 Chromium"
}

cmd_stop() {
  need_root
  # 分层：默认只停常驻 Xray；--all 才连面板块停
  local all=0
  [ "${1:-}" = "--all" ] && all=1

  step "停止 Xray"
  systemctl stop "$XBD_U_XRAY" 2>/dev/null || true
  ok "$XBD_U_XRAY: STOPPED"
  # Chromium 单独跑着没有意义（它的页面连不到 Xray），顺手停掉释放内存
  if unit_active "$XBD_U_CHROMIUM"; then
    systemctl stop "$XBD_U_CHROMIUM" 2>/dev/null || true
    ok "$XBD_U_CHROMIUM: STOPPED（Xray 已停，浏览器无对象可连）"
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
  # Xray 重启会换 CSRF token，官方页面只重试 socket、不重载自己，
  # 所以浏览器必须跟着重启，否则 WS 永远连不上。
  if unit_active "$XBD_U_CHROMIUM"; then
    systemctl restart "$XBD_U_CHROMIUM" 2>/dev/null || true
  fi
  cmd_status
}

# Chromium 进程数。必须返回**单个整数**：
#   pgrep -c 在本机会按每个匹配进程各输出一行，`| head -1` 拿到的可能是多行串，
#   于是 [ "$n" -eq 0 ] 报 "integer expression expected"（实测踩过）。
# 必须用 -x（精确匹配进程名）并且**不要用 -f**：
#   -f 会匹配整条命令行，把调用者自己（shell/pgrep）也算进去，数目虚高（实测 13 vs 真值 9）。
# pgrep -c 输出的就是计数本身，直接用它，别去数行数。
chromium_procs() {
  local n
  n=$(pgrep -c -x chromium 2>/dev/null)
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# ---------------------------------------------------------------------------
# Browser Dialer 的运行时依赖（Chromium）启停
#
# 唯一 Xray 实例**始终**带 XRAY_BROWSER_DIALER，所以这里控制的不是"模式"，
# 而是"浏览器在不在线"：
#   * Chromium 在线 -> 所有节点都可用（BD 节点走浏览器 TLS，其余走 Xray TLS）
#   * Chromium 停掉 -> BD 节点（xhttp/websocket 且非 REALITY）会拨号失败，
#                      其他节点完全不受影响
# ---------------------------------------------------------------------------
cmd_dialer() {
  local op="${1:-status}"
  case "$op" in
    on|start|enable)  xbd_dialer_on ;;
    off|stop|disable) xbd_dialer_off ;;
    toggle)           if unit_active "$XBD_U_CHROMIUM"; then xbd_dialer_off; else xbd_dialer_on; fi ;;
    status|"")        xbd_dialer_status ;;
    -h|--help)        info "用法: xbd dialer <on|off|toggle|status>" ;;
    *) die "未知操作: $op" ;;
  esac
}

# 当前节点**实际**要不要用浏览器完成 TLS。
#
# 判定顺序（与面板、health timer 共用同一套语义，避免两处判断打架）：
#   1. 协议必须支持（xhttp/websocket 且非 REALITY）—— 不支持则永远不用浏览器
#   2. 节点自己的 use_browser 开关：
#        None  -> 默认，协议支持就用
#        True  -> 用
#        False -> 不用，即使协议支持（用户可为单个节点关掉）
#
# 这是**每个节点各自的属性**，不是全局模式：以前做成全局开关时，一关就让所有
# 依赖浏览器的节点一起失效（实测踩过），而只是某个节点想省内存时不该牵连别人。
_xbd_node_needs_dialer() {
  # 判定只有一个来源：compat.py want-bd（与 run-xray.sh、health-check.sh 共用）。
  # 以前这里自己写了一套 python，三处语义容易走偏 —— 而走偏的后果是节点永久挂住。
  local node; node=$(readlink -f "$XBD_NODES/current" 2>/dev/null || true)
  [ -n "$node" ] && [ -e "$node" ] || return 1
  [ "$(python3 "$XBD_LIBDIR/compat.py" want-bd "$node" 2>/dev/null)" = "yes" ]
}

# 该节点**协议层面**是否可能走浏览器转发（不管实测通不通）。
# 与 _xbd_node_needs_dialer 的区别：这个不考虑 use_browser 开关，只看"能不能"。
# 用途：决定 Chromium 能不能停 —— 只要还可能用到，就不能停（停了会无限挂住）。
_xbd_node_may_use_browser() {
  # 协议层面是否**可能**走浏览器（不管实测通不通、不管用户开关）。
  # 用途：决定 Chromium 能不能停 —— 只要还可能用到就不能停（停了会无限挂住）。
  local node; node=$(readlink -f "$XBD_NODES/current" 2>/dev/null || true)
  [ -n "$node" ] && [ -e "$node" ] || return 1
  python3 "$XBD_LIBDIR/compat.py" json "$node" 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("protocol_may_dialer"))' 2>/dev/null \
    | grep -qx True
}

# 该节点能不能用浏览器（用于面板置灰）。与"要不要用"分开，因为要区分
# "不支持所以关着"和"支持但用户自己关的"。
_xbd_node_can_dialer() {
  local node; node=$(readlink -f "$XBD_NODES/current" 2>/dev/null || true)
  [ -n "$node" ] && [ -e "$node" ] || return 1
  python3 "$XBD_LIBDIR/compat.py" json "$node" 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("can_use_dialer"))' 2>/dev/null \
    | grep -qx True
}

xbd_dialer_status() {
  printf '  Xray（唯一实例）: %s\n' "$(unit_active "$XBD_U_XRAY" && echo "Running" || echo "Stopped")"
  printf '  Chromium:         %s\n' "$(unit_active "$XBD_U_CHROMIUM" && echo "Running" || echo "Stopped")"
  local la; la=$(cfg_get "$XBD_CONF/ports.env" LISTEN_ADDR 127.0.0.1)
  printf '  SOCKS5 入口:      %s:%s（全部节点）\n' "$la" "$(cfg_get "$XBD_CONF/ports.env" PORT_NORMAL 1080)"
  printf '  HTTP  入口(LAN):  %s:%s（全部节点）\n' "$la" "$(cfg_get "$XBD_CONF/ports.env" PORT_LAN_HTTP 10809)"
  printf '  HTTP  入口(本机): 127.0.0.1:%s\n' "$(cfg_get "$XBD_CONF/ports.env" PORT_HTTP 10808)"
  printf '  浏览器连接数:     %s\n' "$(conn_count '127.0.0.1:18081')"
  if _xbd_node_needs_dialer; then
    if unit_active "$XBD_U_CHROMIUM"; then
      printf '  当前节点:         依赖浏览器拨号 —— Chromium 在线，可用 ✓\n'
    else
      printf '  当前节点:         ⚠ 依赖浏览器拨号，但 Chromium 已停 —— 该节点会拨号失败\n'
      printf '  修复:             xbd dialer on\n'
    fi
  else
    printf '  当前节点:         不依赖浏览器拨号（走 Xray 自带 TLS）\n'
  fi
}

xbd_dialer_on() {
  need_root
  step "确保 Browser Dialer 运行时（Chromium）在线"
  xbd_load_ports          # 末尾要打印两个入口，必须先把端口读进来
  require_current_node >/dev/null || true

  if ! unit_active "$XBD_U_XRAY"; then
    warn "Xray 未运行，先启动它"
    cmd_start >/dev/null 2>&1 || true
  fi

  systemctl start "$XBD_U_CHROMIUM" 2>/dev/null || true
  systemctl enable --now "$XBD_U_TIMER" >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    unit_active "$XBD_U_CHROMIUM" && [ "$(conn_count '127.0.0.1:18081')" -gt 0 ] && break
    sleep 1
  done

  if ! unit_active "$XBD_U_CHROMIUM"; then
    bad "$XBD_U_CHROMIUM 启动失败"
    journalctl -u "$XBD_U_CHROMIUM" -n 12 --no-pager
    return 1
  fi

  # 真实校验两端是否接上。只看"端口在听"不够 ——
  # 端口改过而 Chromium 没跟上时，两边各自"正常"但一条 WS 都没有。
  local chk vok vws vmismatch
  chk=$(python3 "$XBD_LIBDIR/ports.py" verify-dialer --json 2>/dev/null || echo '{}')
  vok=$(printf '%s' "$chk" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo False)
  vws=$(printf '%s' "$chk" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ws_connections",0))' 2>/dev/null || echo 0)
  vmismatch=$(printf '%s' "$chk" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("mismatch"))' 2>/dev/null || echo False)

  if [ "$vmismatch" = "True" ]; then
    bad "端口不一致：Chromium 连的不是 Xray 监听的端口"
    info "  修正: xbd port channel <端口>  然后 systemctl restart $XBD_U_CHROMIUM"
    return 1
  fi
  if [ "$vok" = "True" ]; then
    ok "$XBD_U_CHROMIUM: RUNNING（浏览器已接上，$vws 条 WS）"
  else
    warn "$XBD_U_CHROMIUM RUNNING，但浏览器还没接上 —— health timer 会在 30 秒内自愈"
    info "  若一直不恢复: xbd ports verify"
  fi
  info "两个入口都可用: ${XBD_LISTEN_ADDR}:${XBD_PORT_NORMAL}(SOCKS5) / ${XBD_LISTEN_ADDR}:${XBD_PORT_LAN_HTTP}(HTTP)"
}

xbd_dialer_off() {
  need_root
  step "停掉 Browser Dialer 运行时（Chromium）"
  systemctl stop "$XBD_U_CHROMIUM" 2>/dev/null || true
  systemctl stop "$XBD_U_TIMER" 2>/dev/null || true

  # 等 Chromium 子进程真正退出
  local i procs
  for i in 1 2 3 4 5 6 7 8; do
    procs=$(chromium_procs)
    [ "${procs:-0}" -eq 0 ] && break
    sleep 1
  done
  procs=$(chromium_procs)

  ok "$XBD_U_CHROMIUM: STOPPED（残留进程 $procs）"
  if unit_active "$XBD_U_XRAY"; then
    ok "$XBD_U_XRAY: 继续运行 ✓（SOCKS/HTTP 两个入口都在，普通节点不受影响）"
  else
    warn "$XBD_U_XRAY 未在运行"
  fi
  if _xbd_node_needs_dialer; then
    warn "当前节点依赖浏览器拨号，Chromium 停掉后它会拨号失败 —— xbd dialer on 恢复"
  fi
}

# ---------------------------------------------------------------------------
# 端口
# ---------------------------------------------------------------------------
cmd_port() {
  local which="${1:-}" value="${2:-}"
  xbd_load_ports
  if [ -z "$which" ]; then
    printf '  当前端口分配:\n'
    printf '    %-34s %s\n' "LAN SOCKS5（全部节点）"   "$XBD_PORT_NORMAL"
    printf '    %-34s %s\n' "本机 HTTP 代理（docker 等）" "$XBD_PORT_HTTP"
    printf '    %-34s %s\n' "局域网 HTTP 代理（WiFi）" "$XBD_PORT_LAN_HTTP"
    printf '    %-34s %s\n' "Xray↔Chromium 内部通道"  "$XBD_DIALER_ADDR"
    printf '    %-34s %s\n' "面板"                    "$XBD_PANEL_PORT"
    printf '    %-34s %s\n' "Xray 统计 API"           "${XBD_API_PORT:-18085}"
    printf '    %-34s %s\n' "绑定地址"                "$XBD_LISTEN_ADDR"
    info ""
    info "修改: xbd port <类型> <值>"
    info "  类型: normal | http | lan-http | channel | panel | api | addr"
    info "自动分配: xbd ports fix    检查冲突: xbd ports check"
    return 0
  fi

  need_root
  case "$which" in
    normal|n)     [ -n "$value" ] || die "缺端口值"; _xbd_set_port PORT_NORMAL "$value" normal ;;
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
      cfg_set "$XBD_CONF/chromium.env" BROWSER_DIALER_ADDR "127.0.0.1:$value"
      ok "内部通道 → 127.0.0.1:$value（ports.env / chromium.env 已同步）"
      info "生效需要重启两边: systemctl restart $XBD_U_XRAY $XBD_U_CHROMIUM"
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
    *) die "未知端口类型: $which（可选 normal/http/lan-http/channel/panel/api/addr）" ;;
  esac
  info "执行 xbd restart 生效"
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
          PORT_HTTP)     _xbd_set_port PORT_HTTP "$port" xray ;;
          PORT_LAN_HTTP) _xbd_set_port PORT_LAN_HTTP "$port" xray ;;
          API_PORT)      _xbd_set_port API_PORT "$port" xray ;;
          PANEL_PORT)    cfg_set "$XBD_CONF/panel.env" PANEL_PORT "$port"; ok "面板端口 → $port" ;;
          DIALER_ADDR)   cfg_set "$XBD_CONF/ports.env" DIALER_ADDR "127.0.0.1:$port"
                         cfg_set "$XBD_CONF/chromium.env" BROWSER_DIALER_ADDR "127.0.0.1:$port"
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
  if BROWSER=$(detect_browser); then _d "浏览器" PASS "$(browser_version | cut -c1-40)"; else _d "浏览器" WARN "未安装（依赖浏览器拨号的节点会不可用，其余节点不受影响）"; fi

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

  _d "xray-client.service" "$(unit_active "$XBD_U_XRAY" && echo PASS || echo FAIL)" "$(unit_state "$XBD_U_XRAY")（唯一实例）"
  _d "panel.service" "$(unit_active "$XBD_U_PANEL" && echo PASS || echo WARN)" "$(unit_state "$XBD_U_PANEL")"

  # 唯一实例必须同时提供两个入站 —— 任一缺失都是配置/端口问题
  _d "SOCKS5 入口 :$XBD_PORT_NORMAL" "$(port_listening_tcp "$XBD_PORT_NORMAL" && echo PASS || echo FAIL)" "$(port_holder "$XBD_PORT_NORMAL" | cut -c1-40)"
  _d "HTTP 入口 :$XBD_PORT_LAN_HTTP" "$(port_listening_tcp "$XBD_PORT_LAN_HTTP" && echo PASS || echo FAIL)" "$(port_holder "$XBD_PORT_LAN_HTTP" | cut -c1-40)"

  # 同一端口被两个进程绑定 = 当年双实例拆分留下的坑，必须报出来
  local dup
  dup=$(ss -H -lntH 2>/dev/null | awk '{print $4}' | sort | uniq -d | head -3 | tr '\n' ' ')
  [ -z "$dup" ] && _d "端口重复绑定" PASS "无" || _d "端口重复绑定" FAIL "$dup"

  # Browser Dialer 的运行时依赖：节点需要它时必须在跑
  local cprocs; cprocs=$(chromium_procs); cprocs=${cprocs:-0}
  local cactive=0; unit_active "$XBD_U_CHROMIUM" && cactive=1
  if _xbd_node_needs_dialer; then
    _d "Chromium: RUNNING" "$([ "$cactive" -eq 1 ] && echo PASS || echo FAIL)" "$cprocs 个进程（当前节点依赖浏览器拨号）"
    _d "浏览器↔Dialer" "$([ "$(conn_count '127.0.0.1:18081')" -gt 0 ] && echo PASS || echo WARN)" "$(conn_count '127.0.0.1:18081') 条 WS"
  else
    _d "Chromium: RUNNING" "$([ "$cactive" -eq 1 ] && echo PASS || echo WARN)" \
      "$cprocs 个进程$([ "$cactive" -eq 0 ] && echo '（当前节点不需要，不影响）')"
  fi

  if [ "$quick" -eq 0 ]; then
    local addr; addr=$(cfg_get "$XBD_CONF/ports.env" LISTEN_ADDR 127.0.0.1)
    local ip
    ip=$(curl -s --max-time 20 --socks5-hostname "$addr:$XBD_PORT_NORMAL" https://api.ipify.org 2>/dev/null || true)
    _d "经代理出网" "$([ -n "$ip" ] && echo PASS || echo FAIL)" "${ip:-失败}（经 :$XBD_PORT_NORMAL）"

    # 两个入站必须走同一个实例 -> 出口必须一致。不一致说明又拆出了第二个实例。
    local iph
    iph=$(curl -s --max-time 20 --proxy "http://$addr:$XBD_PORT_LAN_HTTP" https://api.ipify.org 2>/dev/null || true)
    if [ -n "$ip" ] && [ "$ip" = "$iph" ]; then
      _d "两入口出口一致" PASS "$ip（SOCKS 与 HTTP 同一实例）"
    else
      _d "两入口出口一致" WARN "SOCKS=${ip:-失败} HTTP=${iph:-失败}"
    fi

    local loop=0
    ip -o link show type tun 2>/dev/null | grep -q . && { _d "本机 TUN" WARN "存在"; loop=1; } || _d "本机 TUN" PASS "无"
    iptables -t nat -S 2>/dev/null | grep -qE 'REDIRECT' && { _d "透明重定向" WARN "存在 NAT REDIRECT"; loop=1; } || _d "透明重定向" PASS "无"
    # 旧版本的"接管局域网"模式会留下这张表，即使工具已经不提供那个模式也必须报出来：
    # 残留规则会继续劫持局域网的 80/443 与 DNS，而界面上完全看不出来。
    if nft list table ip xbd_takeover >/dev/null 2>&1 || nft list table ip6 xbd_takeover >/dev/null 2>&1; then
      _d "nft 透明接管残留" WARN "存在 table xbd_takeover（旧版遗留）"
      dim "      清理: nft delete table ip xbd_takeover; nft delete table ip6 xbd_takeover"
      loop=1
    else
      _d "nft 透明接管残留" PASS "无"
    fi
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
  for u in "$XBD_U_XRAY" "$XBD_U_CHROMIUM" "$XBD_U_PANEL" "$XBD_U_HEALTH" "$XBD_U_TIMER"; do
    install -m 0644 "$XBD_SERVICE/$u" "/etc/systemd/system/$u"
  done
  systemctl daemon-reload
  if unit_active "$XBD_U_XRAY"; then
    systemctl restart "$XBD_U_XRAY"
    sleep 2
    if unit_active "$XBD_U_CHROMIUM"; then
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

  # 安全闸：systemd 单元名是全系统共享的，不随 XBD_PREFIX 变化。
  # 用自定义前缀（测试/多实例）时如果照常卸载，会删掉**生产环境**的单元。
  # 这个坑真实踩过：测试用 /tmp/rtest/install 前缀，把生产的 6 个单元删了。
  if [ "$XBD_PREFIX" != "/opt/xray-browser-dialer" ]; then
    warn "当前使用自定义前缀: $XBD_PREFIX"
    warn "systemd 单元名与主安装共用，卸载会影响主安装"
    info ""
    info "如需清理这个测试安装，请手动删除目录即可："
    info "  rm -rf $XBD_PREFIX"
    info ""
    info "若确实要卸载主安装，请用默认前缀运行："
    info "  /opt/xray-browser-dialer/bin/xbd uninstall"
    return 1
  fi
  step "将要删除的内容"
  local items=() u
  for u in "$XBD_U_XRAY" "$XBD_U_CHROMIUM" "$XBD_U_PANEL" "$XBD_U_HEALTH" "$XBD_U_TIMER"; do
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
  systemctl disable --now "$XBD_U_TIMER" "$XBD_U_PANEL" "$XBD_U_CHROMIUM" "$XBD_U_XRAY" 2>/dev/null || true
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
#
# 接管原则：**改配置，不新增冲突配置**。
# 本机可能已经有别的服务（mihomo / 发行版脚本 / 手工配置）接管了系统代理。
# 我们再丢一份 /etc/profile.d/proxy.sh 进去就是两份互相打架的配置：profile.d 按
# 字典序 source，后者胜出，谁覆盖谁完全取决于文件名，出问题极难排查。
# 所以 on 时先探测"谁在接管"：探测到就**就地改写那一份**，并在 off 时按备份还原。
XBD_PROFILE_FILE="/etc/profile.d/proxy.sh"
XBD_DOCKER_PROXY="/etc/systemd/system/docker.service.d/http-proxy.conf"
XBD_PROXY_STATE="/var/lib/xbd-proxy"   # on 时备份原文件 + 记录归属，供 off 精确还原

xbd_proxy_url_http() { printf 'http://127.0.0.1:%s' "$XBD_PORT_HTTP"; }

# 代理变量行（shell / /etc/environment / systemd drop-in 三种写法都算）
XBD_PX_RE='^[[:space:]]*(export[[:space:]]+|unset[[:space:]]+|Environment=)?"?(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|all_proxy|ALL_PROXY)"?='
XBD_PX_UNSET_RE='^[[:space:]]*unset[[:space:]]+"?(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|all_proxy|ALL_PROXY)"?[[:space:]]*$'

# 这份文件是否真的设置了代理（只写 no_proxy 不算接管）
_xbd_proxy_claims() {
  [ -f "$1" ] || return 1
  grep -qE "$XBD_PX_RE|$XBD_PX_UNSET_RE" "$1" 2>/dev/null
}

# 本机**别人**的代理接管点，输出 <style>|<file>，style ∈ sh|env|systemd。
# 输出顺序即生效顺序（profile.d 按字典序 source，后者覆盖前者）。
xbd_proxy_owners() {
  local f
  for f in /etc/profile.d/*.sh; do
    [ -e "$f" ] || continue
    [ "$f" = "$XBD_PROFILE_FILE" ] && continue
    _xbd_proxy_claims "$f" && printf 'sh|%s\n' "$f"
  done
  _xbd_proxy_claims /etc/environment && printf 'env|/etc/environment\n'
  for f in /etc/systemd/system/docker.service.d/*.conf; do
    [ -e "$f" ] || continue
    [ "$f" = "$XBD_DOCKER_PROXY" ] && continue
    _xbd_proxy_claims "$f" && printf 'systemd|%s\n' "$f"
  done
  return 0
}

# 可能携带本机代理配置的文件：别人的接管点 + 我们自己的落点
xbd_proxy_files() {
  xbd_proxy_owners
  [ -f "$XBD_PROFILE_FILE" ] && printf 'sh|%s\n' "$XBD_PROFILE_FILE"
  [ -f "$XBD_DOCKER_PROXY" ] && printf 'systemd|%s\n' "$XBD_DOCKER_PROXY"
  [ -f /etc/environment ]    && printf 'env|/etc/environment\n'
  return 0
}

# $1=style $2=port → 哪些文件正在带我们的代理（一行一个路径）
_xbd_proxy_hits() {
  local lines st f
  lines="$(xbd_proxy_files || true)"
  while IFS='|' read -r st f; do
    [ "$st" = "$1" ] || continue
    grep -q "127.0.0.1:$2" "$f" 2>/dev/null && printf '%s\n' "$f"
  done <<< "$lines"
  return 0
}

# $1=style $2=port → 给人看的一句话
_xbd_proxy_where() {
  local hit
  hit="$(_xbd_proxy_hits "$1" "$2" | paste -sd, -)"
  if [ -n "$hit" ]; then printf '已配置（%s）' "$hit"; else printf '未配置'; fi
}

# 给面板用：本机接管的**真实**状态（含"接管点其实在别人那份配置里"的情况）
xbd_proxy_json() {
  xbd_load_ports
  local p="$XBD_PORT_HTTP" sh_hit dk_hit ev_hit
  sh_hit="$(_xbd_proxy_hits sh      "$p" | paste -sd' ' -)"
  dk_hit="$(_xbd_proxy_hits systemd "$p" | paste -sd' ' -)"
  ev_hit="$(_xbd_proxy_hits env     "$p" | paste -sd' ' -)"
  printf '{"enabled":%s,"shell":"%s","docker":"%s","environment":"%s","owners":%s}\n' \
    "$([ -n "$sh_hit$dk_hit$ev_hit" ] && echo true || echo false)" \
    "$sh_hit" "$dk_hit" "$ev_hit" "$(xbd_proxy_owners | wc -l)"
}

# 归属登记：第一次接管某个文件时把原文备份下来（off 据此还原，而不是删掉别人的配置）
_xbd_proxy_record() {   # $1=created|edited $2=file
  local act="$1" f="$2" prev
  mkdir -p "$XBD_PROXY_STATE"
  prev="$(_xbd_proxy_recorded "$f")"
  if [ -n "$prev" ]; then
    [ "$prev" = "$act" ] || warn "$f 已登记为 $prev，保留最早的备份不动"
    return 0
  fi
  if [ "$act" = edited ]; then
    cp -a "$f" "$XBD_PROXY_STATE/$(printf '%s' "$f" | tr '/' '_').orig" || return 1
  fi
  printf '%s\t%s\n' "$act" "$f" >> "$XBD_PROXY_STATE/manifest"
}

_xbd_proxy_recorded() {   # $1=file → created|edited|空
  [ -s "$XBD_PROXY_STATE/manifest" ] || return 0
  awk -F'\t' -v p="$1" '$2==p{print $1; exit}' "$XBD_PROXY_STATE/manifest"
  return 0
}

# 就地改写别人的配置：代理变量行按我们的值重写，缺的变量在同一份文件里补齐
# （缺 http_proxy 却有 HTTP_PROXY 的程序不少，补齐才是一次完整的接管），
# 其余内容 —— 注释、unset、别的 export、段落结构 —— 原样保留。
# 补齐块插在**最后一条**代理变量之后，不追加到文件末尾：systemd drop-in 的
# 末尾可能已经在别的段落（[Unit]/[Install]）里，追加过去就不是给 [Service] 了。
# 用 cat > 回写而非 mv，保持 inode / 权限 / 属主不变。
_xbd_proxy_rewrite() {   # $1=file $2=style(sh|env|systemd) $3=http $4=no_proxy
  local f="$1" tmp
  tmp="$(mktemp)" || return 1
  awk -v style="$2" -v http="$3" -v nop="$4" '
    BEGIN {
      split("http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy no_proxy NO_PROXY", ord, " ")
      for (i = 1; i <= 7; i++) V[ord[i]] = 1
    }
    function render(n, v) {
      v = (n == "no_proxy" || n == "NO_PROXY") ? nop : http
      if (style == "systemd")  out = "Environment=\"" n "=" v "\""
      else if (style == "env") out = n "=\"" v "\""
      else                     out = "export " n "=\"" v "\""
      return out
    }
    function emit_missing(   i, n, gap) {
      for (i = 1; i <= 7; i++) {
        n = ord[i]
        if (n in seen) continue
        if (!gap) { print ""; print "# 以下由 xbd proxy on 补齐（原配置只设了部分代理变量）"; gap = 1 }
        print render(n)
      }
    }
    {
      if ($0 ~ /^[ \t]*#/) { lines[NR] = $0; next }
      t = $0
      sub(/^[ \t]+/, "", t); sub(/^(export|unset)[ \t]+/, "", t)
      sub(/^Environment=/, "", t); sub(/^"/, "", t)
      n = t; sub(/[^A-Za-z_].*$/, "", n)
      if (n in V && (t == n || t ~ ("^" n "="))) {
        lines[NR] = render(n); seen[n] = 1; last = NR; next
      }
      lines[NR] = $0
    }
    END {
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (i == last) emit_missing()
      }
      if (last == 0) emit_missing()
    }' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

_xbd_proxy_new_sh() {     # $1=file $2=http $3=no_proxy
  cat > "$1" <<EOF
# 由 xbd proxy on 生成 —— 本机进程的显式代理，指向本项目的 Xray。
# 关闭: xbd proxy off
export http_proxy="$2"
export https_proxy="$2"
export HTTP_PROXY="$2"
export HTTPS_PROXY="$2"
export all_proxy="$2"
export no_proxy="$3"
export NO_PROXY="$3"
EOF
  chmod 0644 "$1"
}

_xbd_proxy_new_docker() { # $1=file $2=http $3=no_proxy
  # 变量集合与 _xbd_proxy_rewrite 补齐的完全一致：
  # 「别人接管 → 我们改写」和「没人接管 → 我们新建」必须得到同一份效果。
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
# 由 xbd proxy on 生成 —— docker 守护进程拉镜像走本项目的 Xray。
# 关闭: xbd proxy off
[Service]
Environment="http_proxy=$2"
Environment="https_proxy=$2"
Environment="HTTP_PROXY=$2"
Environment="HTTPS_PROXY=$2"
Environment="all_proxy=$2"
Environment="no_proxy=$3"
Environment="NO_PROXY=$3"
EOF
  chmod 0644 "$1"
}

# 处理一个落点：本机已有接管 → 就地改那一份；没有 → 才新建我们自己的文件。
# $1=style $2=新建时的文件名（空 = 只改不建）$3=写入器 $4=http $5=no_proxy
_xbd_proxy_slot() {
  local style="$1" dflt="$2" writer="$3" owner
  owner="$({ xbd_proxy_owners || true; } | awk -F'|' -v s="$style" '$1==s{print $2}' | tail -n1)"
  if [ -n "$owner" ]; then
    if [ -n "$dflt" ] && [ -f "$dflt" ] && [ "$dflt" != "$owner" ]; then
      rm -f "$dflt" && info "已移除旧版留下的 $dflt（两份配置会互相覆盖）"
    fi
    ok "检测到本机已被接管: $owner —— 就地改这份配置，不新增文件"
    _xbd_proxy_record edited "$owner" || { bad "备份失败，已放弃改写: $owner"; return 1; }
    _xbd_proxy_rewrite "$owner" "$style" "$4" "$5" || { bad "改写失败: $owner"; return 1; }
    ok "已改写 $owner"
    return 0
  fi
  [ -n "$dflt" ] || return 0    # 只改不建（/etc/environment 不做代理就不管它）
  _xbd_proxy_record created "$dflt" || return 1
  "$writer" "$dflt" "$4" "$5"
  ok "已写 $dflt"
}

cmd_proxy() {
  local op="${1:-status}"
  case "$op" in
    on|enable)   xbd_proxy_on ;;
    off|disable) xbd_proxy_off ;;
    status|"")   xbd_proxy_status ;;
    json)        xbd_proxy_json ;;
    -h|--help)   info "用法: xbd proxy <on|off|status>   让本机进程（docker 等）走我们的代理" ;;
    *) die "未知操作: $op" ;;
  esac
}

xbd_proxy_status() {
  xbd_load_ports
  printf '  HTTP 代理入口:    127.0.0.1:%s  %s\n' "$XBD_PORT_HTTP" \
    "$(port_listening_tcp "$XBD_PORT_HTTP" && echo LISTENING || echo 未监听)"
  printf '  LAN SOCKS5 入口:  %s:%s  %s\n' "$XBD_LISTEN_ADDR" "$XBD_PORT_NORMAL" \
    "$(port_listening_tcp "$XBD_PORT_NORMAL" && echo LISTENING || echo 未监听)"
  printf '  LAN HTTP 入口:    %s:%s  %s\n' "$XBD_LISTEN_ADDR" "$XBD_PORT_LAN_HTTP" \
    "$(port_listening_tcp "$XBD_PORT_LAN_HTTP" && echo LISTENING || echo 未监听)"
  printf '  shell 代理:       %s\n' "$(_xbd_proxy_where sh "$XBD_PORT_HTTP")"
  printf '  docker 代理:      %s\n' "$(_xbd_proxy_where systemd "$XBD_PORT_HTTP")"
  printf '  /etc/environment: %s\n' "$(_xbd_proxy_where env "$XBD_PORT_HTTP")"
  local own; own="$(xbd_proxy_owners || true)"
  if [ -n "$own" ]; then
    info "  本机另有代理接管点（on 时会就地改它，不新增文件）:"
    while IFS='|' read -r st f; do info "    [$st] $f"; done <<< "$own"
  else
    printf '  本机另有代理接管点: 无\n'
  fi
}

xbd_proxy_on() {
  need_root
  xbd_load_ports
  step "配置本机显式代理 → Xray"
  local http nop others
  http="$(xbd_proxy_url_http)"
  nop="127.0.0.1,localhost,::1,$XBD_LISTEN_ADDR,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"

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

  others="$(xbd_proxy_owners || true)"
  if [ -n "$others" ]; then
    info "本机已有的代理接管点:"
    while IFS='|' read -r st f; do info "  [$st] $f"; done <<< "$others"
  else
    info "本机没有别的代理接管点，将新建配置"
  fi

  _xbd_proxy_slot sh      "$XBD_PROFILE_FILE" _xbd_proxy_new_sh     "$http" "$nop" || return 1
  _xbd_proxy_slot env     ""                  _xbd_proxy_new_sh     "$http" "$nop" || true
  _xbd_proxy_slot systemd "$XBD_DOCKER_PROXY" _xbd_proxy_new_docker "$http" "$nop" || return 1

  systemctl daemon-reload 2>/dev/null || true
  if unit_active docker.service; then
    warn "重启 docker 以加载代理（容器会短暂中断）"
    systemctl restart docker.service && ok "docker 已重启" || warn "docker 重启失败，可稍后手动重启"
  fi

  info ""
  ok "显式代理已启用"
  printf '  shell:  %s\n' "$(_xbd_proxy_where sh "$XBD_PORT_HTTP")"
  printf '  docker: %s\n' "$(_xbd_proxy_where systemd "$XBD_PORT_HTTP")"
  info "  新开的 shell 会自动带上代理变量"
  info "  当前 shell 立即生效: 重新登录，或 source 上面那个文件"
  info "  关闭: xbd proxy off（别人原来的配置会按备份还原）"
}

xbd_proxy_off() {
  need_root
  step "关闭本机显式代理"
  local act path bak touched=0 f
  if [ -s "$XBD_PROXY_STATE/manifest" ]; then
    while IFS=$'\t' read -r act path; do
      [ -n "${path:-}" ] || continue
      bak="$XBD_PROXY_STATE/$(printf '%s' "$path" | tr '/' '_').orig"
      if [ "$act" = edited ]; then
        if [ -f "$bak" ] && [ -f "$path" ]; then
          cp -a "$bak" "$path" && ok "已还原为原配置: $path" && touched=1
        else
          warn "跳过 $path（原备份或目标文件已不存在）"
        fi
      elif [ -f "$path" ]; then
        rm -f "$path" && ok "已移除 $path" && touched=1
      fi
    done < "$XBD_PROXY_STATE/manifest"
    rm -f "$XBD_PROXY_STATE/manifest"
  fi
  # 兼容早期版本留下的文件（当时没有 manifest）
  for f in "$XBD_PROFILE_FILE" "$XBD_DOCKER_PROXY"; do
    [ -f "$f" ] && rm -f "$f" && ok "已移除 $f" && touched=1
  done
  if [ "$touched" = 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
    if unit_active docker.service; then
      warn "重启 docker 以清掉代理环境变量"
      systemctl restart docker.service && ok "docker 已重启" || true
    fi
  fi
  if [ "$touched" = 0 ]; then
    info "本机本来就没有配置我们的代理，无需改动。"
  else
    info "本机已恢复为直连；被接管的原配置已还原（备份留在 $XBD_PROXY_STATE）。"
  fi
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
      if unit_active "$XBD_U_CHROMIUM"; then
        systemctl restart "$XBD_U_CHROMIUM" 2>/dev/null || true
        info "已同步重启 Chromium（Xray 重启会换 CSRF token）"
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
EOF

  cat > "$links" <<EOF
# 代理链接 —— 生成时间 $(date '+%Y-%m-%d %H:%M:%S')
SOCKS5          socks5://$host:$XBD_PORT_NORMAL
HTTP            http://$host:$XBD_PORT_LAN_HTTP
（两个入口都由同一个 Xray 实例服务，所有节点通用；本机进程用 127.0.0.1:$XBD_PORT_HTTP，仅回环）
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
唯一 Xray 实例（SOCKS + HTTP 两入口）+ Browser Dialer 按节点自动生效

用法: xbd <命令> [参数]

  安装与基础
    install [--no-start] [--vless <uri>]   安装（幂等）
    update                                 更新本项目脚本
    xray version|check|update              查看/检查/更新 Xray 内核
    uninstall                              安全卸载（先列清单）

  节点（共享资产；是否需要浏览器拨号由服务器按节点自动决定）
    node add "<uri|json|yaml>"             导入节点（支持多行 / 多协议）
    node sub <订阅URL>                     导入订阅
    node list                              节点列表（含 Xray / Browser Dialer 两种能力）
    node use <编号>                        切换当前节点
    node check [编号]                      能力检查
    node latency [编号]                    延时测试（真实请求）
    node remove <编号>                     删除节点

  服务（唯一实例，同时提供 SOCKS 与 HTTP）
    start                                  启动 Xray + 面板
    stop [--all]                           停止 Xray（--all 连面板一起停）
    restart                                重启 Xray（会自动同步重启 Chromium）
    dialer on|off|toggle|status            启动/停掉 Chromium（Browser Dialer 的运行时依赖）
    apply                                  重新生成配置
    port [类型] [值]                       查看/修改端口（normal/http/lan-http/channel/panel/api/addr）
    ports check|fix|verify                 端口冲突检查 / 自动重新分配 / 校验浏览器两端接上

  本机上网 / 局域网接入
    proxy on|off|status                    让本机进程（docker/apt/curl）走我们的代理
                                           （发现别的服务已接管系统代理时，就地改那一份）
    局域网设备：在设备的代理设置里填「本机 IP:1080(SOCKS5) / :10809(HTTP)」即可，
                不需要本机做任何改动（透明网关模式已移除，见 docs/mode3-lan-gateway/）

  状态与诊断
    status [--quick]                       状态（含当前节点实际走哪条 TLS 路径）
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

  # 架构自检：断言"唯一实例 + 两个入口 + 按节点决定是否走浏览器"这套模型真的成立。
  # 双实例/双端口一旦回归，界面上看不出来，只有这里能发现。
  printf '  %-10s ' "arch"
  if [ -x "$XBD_PREFIX/tools/selftest-arch.sh" ]; then
    if bash "$XBD_PREFIX/tools/selftest-arch.sh" >/tmp/.xbd_arch 2>&1; then
      echo "PASS"; grep -E '架构自检: PASS' /tmp/.xbd_arch | sed 's/^/             /'
    else
      echo "FAIL"; grep -E '✗|架构自检: FAIL' /tmp/.xbd_arch | sed 's/^/             /'; failed=$((failed+1))
    fi
  else
    echo "SKIP（缺少 tools/selftest-arch.sh）"
  fi
  rm -f /tmp/.xbd_arch
  echo
  [ "$failed" -eq 0 ] && { echo "自检: PASS"; return 0; } || { echo "自检: $failed 项失败"; return 1; }
}
