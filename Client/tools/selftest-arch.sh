#!/usr/bin/env bash
# 架构自检：验证"唯一 Xray 实例 + 两个入站 + Browser Dialer 常备"这套模型真的成立。
#
# 为什么必须有这个脚本：这套模型的核心主张是"同一个 SOCKS/HTTP 端口对全部节点通用，
# 用不用浏览器由节点自己决定"。这几条一旦被改回"双实例 / 双端口"，界面上完全看不出来，
# 只有靠这里的三条断言能发现。断言全部基于可观测事实，不依赖日志措辞。
#
# 用法: sudo bash tools/selftest-arch.sh [--keep-bd-node]
#   默认会临时切到一个不需要浏览器的节点做第 3 条断言，结束时切回原节点。
set -uo pipefail
PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
LIB="$PREFIX/xbd-dist/lib"
[ -d "$LIB" ] || LIB="$PREFIX/lib"
XBD="$PREFIX/bin/xbd"
PORTS="$PREFIX/config/ports.env"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
warn_() { printf '  \033[33m!\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

getport() { awk -F= -v k="^$1=" '$0 ~ k {print $2; exit}' "$PORTS" 2>/dev/null; }
SOCKS_PORT=$(getport PORT_NORMAL);      SOCKS_PORT=${SOCKS_PORT:-1080}
HTTP_PORT=$(getport PORT_LAN_HTTP);     HTTP_PORT=${HTTP_PORT:-10809}
LOOP_PORT=$(getport PORT_HTTP);         LOOP_PORT=${LOOP_PORT:-10808}
CH_ADDR=$(getport DIALER_ADDR);         CH_ADDR=${CH_ADDR:-127.0.0.1:18081}
LAN=$(getport LISTEN_ADDR);             LAN=${LAN:-127.0.0.1}
PROBE="https://api.ipify.org"
# 注意：这台机器**没有直连外网**（裸 curl 是 rc=7），所以任何探测都必须显式带代理参数，
# 否则拿到的是"假失败"。
#
# 刻意把 curl 参数**逐个写死**，不做字符串拼接再靠 word-splitting 展开 ——
# 那种写法踩过坑：`${3:-}` 空展开会让 curl 把 --max-time 当成别的东西，报
# "option --max-time: expected a proper numerical parameter"(rc=2)，且静默为空。
# 超时给到 90s：BD 路径每次拨号都要经 Chromium 往返，冷启动更慢。
ask_socks() { curl -s --max-time 90 --socks5-hostname "$1" "$PROBE" 2>/dev/null; }
ask_http()  { curl -s --max-time 90 --proxy "http://$1"        "$PROBE" 2>/dev/null; }
# 刚重启过的 Xray / 刚切换的节点不一定马上能出网，单次探测会给出"假失败"（曾经误报过）。
ask_socks_retry() {
  local i r
  for i in $(seq 1 "${2:-3}"); do
    r=$(ask_socks "$1"); [ -n "$r" ] && { printf '%s' "$r"; return 0; }
    sleep 4
  done
  return 1
}
# 当前节点要不要浏览器：这是**节点属性**，不能像以前那样写死成"实例必须带 BD"。
WANT_BD=$(python3 "$LIB/compat.py" want-bd "$PREFIX/nodes/current" 2>/dev/null || echo unknown)

# Xray 每次重启都会换 CSRF token，而官方内嵌页面只重试 socket、不重载自己 ——
# 所以"端口在听"不等于"浏览器已接上"。等 WS 真接上再断言，否则测的是重启瞬间。
wait_ws() {
  local i port="${CH_ADDR##*:}"
  for i in $(seq 1 "${1:-30}"); do
    [ "$(ss -H -tn 2>/dev/null | grep -c ":$port\b")" -gt 0 ] && return 0
    sleep 1
  done
  return 1
}

echo "=== 架构自检（Xray Client）==="
echo "  prefix=$PREFIX  入口=$LAN:$SOCKS_PORT(SOCKS5) / $LAN:$HTTP_PORT(HTTP)"

# ---------------------------------------------------------------------------
head_ "1. 唯一实例：两个入站必须由同一个进程监听"
# 这一条直接否掉"双实例/双端口"的回归：以前 10809 被两个进程同时绑定过。
holders=$(ss -H -lntp 2>/dev/null | grep -E ":($SOCKS_PORT|$HTTP_PORT)\b" \
          | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
n=$(printf '%s\n' "$holders" | grep -c . || true)
if [ "${n:-0}" -eq 1 ]; then
  ok "两个入口同一个 PID ($holders)"
  prog=$(tr '\0' ' ' < "/proc/$holders/cmdline" 2>/dev/null | cut -c1-50)
  case "$prog" in
    *xray*) ok "该 PID 确实是 Xray" ;;
    *)      bad "该 PID 不是 Xray: $prog" ;;
  esac
  has_bd=no
  tr '\0' '\n' < "/proc/$holders/environ" 2>/dev/null | grep -q '^XRAY_BROWSER_DIALER=' && has_bd=yes
  case "$WANT_BD:$has_bd" in
    yes:yes) ok "当前节点要浏览器，实例也带着 XRAY_BROWSER_DIALER（节点属性，不是模式）" ;;
    no:no)   ok "当前节点不要浏览器，实例也**没有** XRAY_BROWSER_DIALER（进程级开关跟着节点走）" ;;
    yes:no)  bad "当前节点要浏览器，实例却没有 XRAY_BROWSER_DIALER —— 会退化成 Xray 自带 TLS" ;;
    no:yes)  warn_ "当前节点不要浏览器，实例仍带着 XRAY_BROWSER_DIALER（对当前节点无影响，但说明没跟着节点重启）" ;;
    *)       warn_ "节点判定失败（want-bd=$WANT_BD），跳过这条" ;;
  esac
else
  bad "两个入口被 $n 个进程分别监听（$holders）—— 架构回到了双实例"
fi

# 同一端口被两个进程绑定是历史踩过的坑，单独再查一次
dups=$(ss -H -lntH 2>/dev/null | awk '{print $4}' | sort | uniq -d | grep -c . || true)
[ "${dups:-0}" -eq 0 ] && ok "没有端口被重复绑定" || bad "$dups 个端口被重复绑定"

# ---------------------------------------------------------------------------
head_ "2. 两个入口出口必须一致（同一实例 ⇒ 同一节点 ⇒ 同一出口）"
if [ "$WANT_BD" = yes ]; then
  echo "  当前节点依赖浏览器，探测走 Browser Dialer 路径（较慢，请稍候）"
  wait_ws 30 || bad "等不到浏览器接上（0 条 WS）—— 先执行: xbd dialer on"
else
  echo "  （当前节点不走浏览器，跳过 WS 等待）"
fi
a=$(ask_socks "$LAN:$SOCKS_PORT")
b=$(ask_http  "$LAN:$HTTP_PORT")
c=$(ask_http  "127.0.0.1:$LOOP_PORT")
if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]; then
  ok "SOCKS5 / LAN HTTP / 本机 HTTP 出口一致: $a"
else
  bad "出口不一致: socks=${a:-失败} lan-http=${b:-失败} local-http=${c:-失败}"
fi

# ---------------------------------------------------------------------------
head_ "3. 节点决定路径：不需要浏览器的节点，停掉 Chromium 也必须照常工作"
# 这条是模型成立的另一半 —— Browser Dialer 常备不能殃及普通节点。
cur=$(readlink -f "$PREFIX/nodes/current" 2>/dev/null || true)
[ -e "$cur" ] || { bad "没有当前节点，跳过"; cur=""; }
# 当前节点是否需要浏览器 —— 第 3 条断言还原时要据此判断 Chromium 该不该被拉起来
BD_CUR=$(python3 "$LIB/compat.py" json "$PREFIX/nodes/current" 2>/dev/null \
         | python3 -c 'import sys,json;print(json.load(sys.stdin).get("can_use_dialer"))' 2>/dev/null || echo None)

if [ -n "$cur" ] && [ "${1:-}" != "--keep-bd-node" ]; then
  plain=$(python3 - "$LIB" "$PREFIX/nodes" <<'PY' 2>/dev/null
import importlib.util, os, sys
lib, ndir = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("c", os.path.join(lib, "compat.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import json
for f in sorted(os.listdir(ndir)):
    p = os.path.join(ndir, f)
    if not f.endswith(".json"): continue
    try: n = json.load(open(p))
    except Exception: continue
    try:
        a = m.check_all(n)
    except Exception:
        continue
    # 必须是"协议层面就不可能走浏览器"的节点（hysteria / raw / reality 这类）。
    # 不能用 can_use_dialer：实测失败的 ws 节点也是 False，但它属于"必须用原生"的另一类，
    # 拿它来测"普通节点不被浏览器拖累"会得到假失败（真踩过）。
    if a.get("can_use_xray") and not a.get("protocol_may_dialer"):
        print(p); break
PY
)
  if [ -z "$plain" ]; then
    echo "  （没有「不需要浏览器」的节点可供切换，跳过这条）"
  else
    chrom_was=$(systemctl is-active chromium-browser-dialer.service 2>/dev/null || true)
    timer_was=$(systemctl is-active browser-dialer-health.timer 2>/dev/null || true)
    systemctl stop browser-dialer-health.timer 2>/dev/null || true

    # 切换本身就该把 Chromium 停掉（它约占 600MB，这台机器上是大头）。
    # 注意：不手动 stop，让 xbd node use 自己去停 —— 断言的就是这个自动化行为。
    if [ "$chrom_was" = active ]; then
      "$XBD" node use "$(basename "$plain")" >/dev/null 2>&1
      sleep 6
      n=$(pgrep -c -x chromium 2>/dev/null || echo 0)
      if systemctl is-active --quiet chromium-browser-dialer.service || [ "${n:-0}" -gt 0 ]; then
        bad "切到不需要浏览器的节点后 Chromium 仍在跑（$n 个进程）—— 会白占内存"
      else
        ok "切到无浏览器节点后 Chromium 已自动停掉（释放约 600MB）"
      fi
    else
      "$XBD" node use "$(basename "$plain")" >/dev/null 2>&1
      echo "  （原节点本来就没开 Chromium，跳过自动停的断言）"
    fi

    systemctl restart xray-client.service 2>/dev/null || true; sleep 5
    systemctl stop chromium-browser-dialer.service 2>/dev/null || true; sleep 4
    ws=$(ss -H -tn 2>/dev/null | grep -c ":$(( ${CH_ADDR##*:} ))\b" || true)
    r=$(ask_socks_retry "$LAN:$SOCKS_PORT" 3)
    if [ -n "$r" ] && [ "${ws:-0}" -eq 0 ]; then
      ok "Chromium 完全停掉（0 条 WS）仍能出网: $r"
    else
      bad "Chromium 停掉后出网失败（rc/出口=${r:-空}，WS=$ws）—— 普通节点被 Browser Dialer 拖累"
      echo "    诊断: 服务状态 xray=$(systemctl is-active xray-client.service) chromium=$(systemctl is-active chromium-browser-dialer.service)"
      echo "    诊断: PID=$(systemctl show -p MainPID --value xray-client.service) 节点=$(readlink -f "$PREFIX/nodes/current" | xargs -r basename)"
      echo "    诊断: $(curl -sS --max-time 25 --socks5-hostname "$LAN:$SOCKS_PORT" "$PROBE" 2>&1 | head -2)"
      echo "    诊断: env=$(tr '\0' '\n' < "/proc/$(systemctl show -p MainPID --value xray-client.service)/environ" 2>/dev/null | grep -c '^XRAY_BROWSER_DIALER=' || echo 0)"
    fi

    # 还原：切回原节点。若原节点需要浏览器，xbd node use 应自动把它拉起来。
    "$XBD" node use "$(basename "$cur")" >/dev/null 2>&1 || true
    if [ "$BD_CUR" = "True" ]; then
      sleep 6
      if systemctl is-active --quiet chromium-browser-dialer.service; then
        ok "切回需要浏览器的节点后 Chromium 已自动启动"
      else
        bad "切回需要浏览器的节点但 Chromium 没起来 —— 该节点会拨号失败"
      fi
    fi
    # Xray 换了 CSRF token，浏览器必须跟着重启 —— 单元里的 PartOf= 负责这件事，
    # 这里直接 restart xray-client 就是在验证它（不用再手动重启 Chromium）。
    systemctl restart xray-client.service 2>/dev/null || true
    [ "$timer_was" = active ] && systemctl start browser-dialer-health.timer 2>/dev/null || true
    if [ "$BD_CUR" = "True" ]; then
      wait_ws 40 || true
      r2=$(ask_socks_retry "$LAN:$SOCKS_PORT" 3)
      if [ -n "$r2" ]; then
        ok "切回原节点后出网正常（Xray 重启已自动带着 Chromium 重启）: $r2"
      else
        bad "切回原节点后出网失败 —— Xray 重启没有同步重启浏览器？"
      fi
    else
      systemctl restart xray-client.service 2>/dev/null || true; sleep 6
      r2=$(ask_socks_retry "$LAN:$SOCKS_PORT" 3)
      [ -n "$r2" ] && ok "已切回原节点并恢复出网: $r2" || bad "切回原节点后出网失败"
    fi
  fi
fi

# ---------------------------------------------------------------------------
head_ "4. 需要浏览器的节点：0 条 WS 时必须挂起（证明确实走浏览器）"
# 源码依据 transport/internet/browser_dialer/dialer.go: dialTask() 阻塞在 <-conns，
# 一条 WS 都没有时 BD 拨号会挂住。所以"停掉浏览器 → 该节点失败"是正确行为，不是故障。
ws=$(ss -H -tn 2>/dev/null | grep -c ":$(( ${CH_ADDR##*:} ))\b" || true)
bd="$BD_CUR"
if [ "$bd" = "True" ]; then
  if [ "${ws:-0}" -gt 0 ]; then
    ok "当前节点依赖浏览器，且已有 $ws 条 WS（Chromium 在线）"
  else
    bad "当前节点依赖浏览器，但 0 条 WS —— 该节点现在会挂起（执行: xbd dialer on）"
  fi
else
  echo "  （当前节点不需要浏览器，跳过）"
fi

# ---------------------------------------------------------------------------
head_ "5. 换节点必须真的生效：运行配置里的出站 == nodes/current"
# 回归断言。曾经 `xbd node use` 只改了软链接、不重新生成配置也不重启，于是
# "界面上节点已切好、实际流量还走旧节点" —— 从 hysteria 换到 hysteria 时浏览器
# 开关没变，连"按需重启"都不会触发，完全静默。判据必须落在**运行配置**上。
_out() {   # $1=json 文件（运行配置或节点文件）→ address:port
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit
s = d["outbounds"][0].get("settings") or {} if "outbounds" in d else d
print("%s:%s" % (s.get("address", ""), s.get("port", "")))' "$1" 2>/dev/null
}
run_out=$(_out "$PREFIX/runtime/xray-client.json")
cur_out=$(_out "$PREFIX/nodes/current")
if [ -n "$run_out" ] && [ "$run_out" = "$cur_out" ]; then
  ok "运行配置与当前节点一致（$run_out）"
elif [ -z "$run_out" ] || [ -z "$cur_out" ]; then
  bad "读不到运行配置或当前节点（run=${run_out:-空} cur=${cur_out:-空}）"
else
  bad "运行配置与当前节点不一致：运行=${run_out} 当前=${cur_out} —— 执行 xbd apply && xbd restart"
fi

echo
echo "========================================"
if [ "$fail" -eq 0 ]; then printf '架构自检: PASS（%s 项）\n' "$pass"
else printf '架构自检: FAIL（%s 失败 / %s 通过）\n' "$fail" "$pass"; fi
echo "========================================"
[ "$fail" -eq 0 ]
