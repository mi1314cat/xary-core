#!/usr/bin/env python3
"""Xray Client Web Manager — 面板后端。

设计要点（对应需求第四、十四、十五条）：
    * 节点是共享资产：节点卡片提供「普通连接」与「Browser Dialer」两种使用方式，
      点击只切换**连接模式**，不修改节点本身；
    * 状态栏明确显示当前真正使用的模式，而不是一个模糊的 Running；
    * Browser Dialer 是按需启动的：按钮只影响 dialer/chromium 两个单元，
      常驻 Xray 永远不动 —— 关闭 Browser Dialer 不会中断普通代理。

安全：只监听配置里的地址；可选访问令牌；动作走白名单，参数以 argv 传递。
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
DIST = os.path.join(PREFIX, "xbd-dist")
NODES = os.path.join(PREFIX, "nodes")
CONF = os.path.join(PREFIX, "config")
RUNTIME = os.path.join(PREFIX, "runtime")

U_XRAY = "xray-client.service"
U_DIALER = "xray-dialer.service"
U_CHROMIUM = "chromium-browser-dialer.service"
U_PANEL = "browser-dialer-panel.service"
U_TIMER = "browser-dialer-health.timer"

STATE_PY = os.path.join(DIST, "lib", "state.py")
COMPAT_PY = os.path.join(DIST, "lib", "compat.py")
NODE_PY = os.path.join(DIST, "lib", "node.py")
GENCONFIG_PY = os.path.join(DIST, "lib", "genconfig.py")

BIND_HOST = "127.0.0.1"
BIND_PORT = 18090


# --------------------------------------------------------------------- 工具 ----
def sh(args, timeout=60, stdin=None):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, input=stdin)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def sh_bg(args):
    """后台执行，用于会重启自身所在单元的动作（否则会把自己的响应掐掉）。"""
    try:
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
        return True
    except OSError:
        return False


def cfg_get(path, key, default=""):
    try:
        for line in open(path):
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return default


def cfg_set(path, key, value):
    lines, found = [], False
    try:
        lines = open(path).read().splitlines()
    except OSError:
        pass
    out = []
    for line in lines:
        if line.startswith(key + "="):
            out.append(f"{key}={value}")
            found = True
        else:
            out.append(line)
    if not found:
        out.append(f"{key}={value}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")


def unit_state(unit):
    rc, out, _ = sh(["systemctl", "is-active", unit], timeout=10)
    rc2, en, _ = sh(["systemctl", "is-enabled", unit], timeout=10)
    return {"state": out or "unknown", "active": out == "active", "enabled": en == "enabled"}


# ---------------------------------------------------------------------- 状态 ----
def build_state():
    rc, out, err = sh(["python3", STATE_PY, "--json"], timeout=60)
    if rc != 0 or not out:
        return {"error": err or "state.py 执行失败", "services": {}, "nodes": []}
    try:
        state = json.loads(out)
    except ValueError:
        return {"error": "状态解析失败", "services": {}, "nodes": []}

    state["services_extra"] = {"panel": unit_state(U_PANEL), "timer": unit_state(U_TIMER)}
    state["doh"] = cfg_get(os.path.join(CONF, "chromium.env"), "XBD_DOH", "")

    ports = os.path.join(CONF, "ports.env")
    state["ports_cfg"] = {
        "normal": cfg_get(ports, "PORT_NORMAL", "1080"),
        "dialer": cfg_get(ports, "PORT_DIALER", "1081"),
        "http": cfg_get(ports, "PORT_HTTP", "10808"),
        "lan_http": cfg_get(ports, "PORT_LAN_HTTP", "10809"),
        "listen": cfg_get(ports, "LISTEN_ADDR", "127.0.0.1"),
        "channel": (cfg_get(ports, "DIALER_ADDR", "127.0.0.1:18081").rpartition(":")[2]),
        "api": cfg_get(os.path.join(CONF, "api.env"), "API_PORT", "18085"),
    }

    # 本机接管：看 proxy.sh / docker 配置是否指向我们
    prof = "/etc/profile.d/proxy.sh"
    dk = "/etc/systemd/system/docker.service.d/http-proxy.conf"
    hp = state["ports_cfg"]["http"]
    state["takeover_local"] = ("127.0.0.1:" + hp) in (open(prof).read() if os.path.exists(prof) else "")
    state["takeover_lan"] = bool(sh(["nft", "list", "table", "ip", "xbd_takeover"], timeout=10)[0] == 0)
    state["xray_ver"] = ""
    rc, out, _ = sh([os.path.join(PREFIX, "bin", "xray"), "version"], timeout=15)
    if rc == 0 and len(out.split()) > 1:
        state["xray_ver"] = out.split()[1]
    return state


def node_path(ident):
    """把编号或文件名解析成绝对路径，并确保它落在 nodes/ 内。"""
    ident = str(ident)
    if ident.isdigit():
        import glob
        files = sorted(glob.glob(os.path.join(NODES, "node-*.json")))
        idx = int(ident) - 1
        if 0 <= idx < len(files):
            return files[idx]
        return None
    if "/" in ident or not ident.startswith("node-"):
        return None
    p = os.path.join(NODES, ident)
    return p if os.path.exists(p) else None


def compat_of(path):
    rc, out, _ = sh(["python3", COMPAT_PY, "json", path], timeout=30)
    if rc in (0, 1) and out:
        try:
            return json.loads(out)
        except ValueError:
            pass
    return {}


# ------------------------------------------------------------------- 动作 ----
def act_import(uri):
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "add", uri], timeout=120)
    return rc == 0, (out or err)


def act_node_use(ident):
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    # 先看能不能用普通模式；不能用就没必要切
    caps = compat_of(path)
    if not caps.get("can_use_xray"):
        return False, "该节点连普通 Xray 模式都不支持，拒绝切换"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "use", os.path.basename(path)], timeout=60)
    if rc != 0:
        return False, out or err
    sh_bg(["bash", "-c", "sleep 1; systemctl restart " + U_XRAY])
    time.sleep(4)
    return True, "已切换节点，常驻 Xray 正在重启"


def act_node_remove(ident):
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "remove", os.path.basename(path)], timeout=60)
    return rc == 0, (out or err)


def act_node_latency(ident):
    """真实请求测延时。走临时 Xray 实例，不占用常驻服务。"""
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "latency.py"),
                       path, "--json", "--timeout", "12"], timeout=120)
    if rc != 0 and not out:
        return False, f"测速失败: {err or '未知错误'}"
    try:
        data = json.loads(out)
    except ValueError:
        return False, "测速结果解析失败"
    res = next(iter(data.values()), {})
    if res.get("ok"):
        return True, f"延时 {res['latency_ms']} ms（出口 {res.get('exit_ip') or '未知'}）"
    labels = {"timeout": "超时", "tls": "TLS 握手失败", "dns": "域名解析失败",
              "refused": "连接被拒绝", "unreachable": "无法连接", "no_response": "服务端无响应",
              "proxy_error": "代理错误", "config_failed": "配置生成失败", "xray_not_up": "临时实例未启动"}
    return False, f"测速失败：{labels.get(res.get('error'), res.get('error') or '未知')}"


def act_xray_version():
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "xrayup.py"), "check", "--json"], timeout=60)
    try:
        d = json.loads(out)
    except ValueError:
        return False, f"版本检查失败: {err or out}"
    if d.get("error"):
        return False, f'{d["error"]}（已安装 {d.get("installed") or "无"}）'
    cur, latest = d.get("installed") or "无", (d.get("latest") or "").lstrip("v")
    if d.get("updatable"):
        return True, f"已安装 {cur}，可更新到 {latest}。点「更新内核」开始。"
    return True, f"已是最新版本 {cur}"


def act_xray_upgrade():
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "xrayup.py"), "update", "--json"], timeout=600)
    try:
        d = json.loads(out)
    except ValueError:
        return False, f"更新失败: {err or out}"
    if not d.get("ok"):
        return False, f'更新失败: {d.get("error", "未知错误")}'
    if not d.get("updated"):
        return True, f'已是最新版本 {d.get("version")}'
    note = "（SHA256 已校验）" if d.get("sha256_verified") else "（未取得官方 .dgst）"
    # 换二进制后必须重启，否则还在跑旧内核
    sh(["systemctl", "restart", U_XRAY], timeout=60)
    if unit_state(U_DIALER)["active"]:
        sh(["systemctl", "restart", U_CHROMIUM], timeout=60)
    return True, f'内核已更新 {d.get("from") or "无"} → {d.get("to")} {note}，服务已重启'


def act_takeover(mode):
    """三种接管模式（需求：不接管 / 接管本机 / 接管局域网）。"""
    xbd = os.path.join(PREFIX, "bin", "xbd")
    if mode == "none":
        out_msgs = []
        for args in (["proxy", "off"], ["takeover", "off"]):
            rc, o, e = sh([xbd] + args, timeout=180)
            out_msgs.append(o or e or "")
        return True, "已切换为「不接管」：只提供代理服务，不修改本机与局域网" + \
            ("\n" + "\n".join(x.strip() for x in out_msgs if x.strip()) if out_msgs else "")
    if mode == "local":
        rc, out, err = sh([xbd, "proxy", "on"], timeout=300)
        if rc != 0:
            return False, out or err
        return True, "已接管本机：docker / apt / curl 走我们的代理（局域网不受影响）"
    if mode == "lan":
        # 先确保本机代理配置可用，再开透明劫持
        sh([xbd, "proxy", "on"], timeout=300)
        rc, out, err = sh([xbd, "takeover", "on"], timeout=180)
        if rc != 0:
            return False, out or err
        return True, "已接管局域网：80/443 透明转发，SSH/LAN/DNS 已豁免"
    return False, "未知模式"


def act_node_check(ident):
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, _ = sh(["python3", COMPAT_PY, "json", path], timeout=30)
    try:
        caps = json.loads(out)
    except ValueError:
        return False, "能力检查失败"
    lines = []
    x = caps.get("xray", {}).get("overall", "?")
    b = caps.get("dialer", {}).get("overall", "?")
    labels = {"SUPPORTED": "✓ 支持", "SUPPORTED_WITH_WARNING": "⚠ 支持（有注意项）",
              "NOT_SUPPORTED": "✗ 不支持", "UNKNOWN": "? 未知"}
    lines.append(f"Xray：{labels.get(x, x)}")
    lines.append(f"Browser Dialer：{labels.get(b, b)}")
    if caps.get("tags"):
        lines.append("能力标签：" + "  ".join(f"[{t}]" for t in caps["tags"]))
    for note in (caps.get("dialer", {}).get("notes") or [])[:4]:
        lines.append(f"  · {note}")
    return True, "\n".join(lines)


def act_mode(mode):
    """切换连接模式。只动该动的单元 —— 这是解耦的核心。"""
    xbd = os.path.join(PREFIX, "bin", "xbd")
    if mode == "normal":
        rc, out, err = sh([xbd, "dialer", "off"], timeout=180)
        ok = rc == 0
        state = build_state()
        if ok and state.get("services", {}).get("xray", {}).get("active"):
            return True, "已切换到普通 Xray 模式（Browser Dialer 与 Chromium 已关闭，Xray 继续运行）"
        return ok, out or err or "切换完成"
    if mode == "browser_dialer":
        rc, out, err = sh([xbd, "dialer", "on"], timeout=240)
        return rc == 0, (out or err)
    return False, "未知模式"


def act_service(op):
    xbd = os.path.join(PREFIX, "bin", "xbd")
    if op == "start":
        # 面板会重启到自己所在的单元，放到后台执行，避免响应被掐断
        sh_bg([xbd, "start"])
        return True, "正在启动常驻 Xray…"
    if op in ("stop", "restart", "stop-all"):
        if op == "stop-all":
            sh_bg([xbd, "stop", "--all"])
            return True, "正在全部停止…"
        sh_bg([xbd, op])
        return True, f"正在{ {'stop': '停止', 'restart': '重启'}[op] }常驻 Xray…"
    return False, "未知操作"


def _validate_port(v):
    v = str(v).strip()
    if not re.fullmatch(r"\d{1,5}", v) or not (1 <= int(v) <= 65535):
        return None
    return v


def act_port_set(kind, value):
    """统一端口修改。kind: normal/dialer/http/lan-http/channel/panel/api"""
    value = _validate_port(value)
    if value is None:
        return False, "端口必须是 1-65535 的数字"
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "port", kind, value], timeout=120)
    if rc != 0:
        return False, out or err or "修改失败"
    # 面板端口改的是自己，响应可能被掐断，所以后台重启
    if kind in ("panel",):
        return True, out or f"面板端口已改为 {value}，请用新地址访问"
    # 其余端口需要重新生成配置并重启对应服务
    rc2, o2, e2 = sh([xbd, "apply"], timeout=120)
    if rc2 != 0:
        return False, f"端口已改，但配置生成失败: {o2 or e2}"
    if kind == "channel":
        # 内部通道两端都要重启，否则 Chromium 还在连旧端口
        sh([xbd, "dialer", "off"], timeout=180)
        rc3, o3, e3 = sh([xbd, "dialer", "on"], timeout=300)
        if unit_state(U_DIALER)["active"]:
            return rc3 == 0, (o3 or e3 or f"内部通道已改为 {value}")
        return True, f"内部通道已改为 {value}（下次启用 dialer 时生效）"
    sh_bg(["bash", "-c", "sleep 1; systemctl restart " + U_XRAY])
    time.sleep(3)
    return True, f"{kind} 端口已改为 {value}"


def act_conninfo():
    """生成可直接复制的连接配置。

    为什么要后端生成：端口随时会改，前端拼字符串一定会和真实配置脱节。
    """
    ports = os.path.join(CONF, "ports.env")
    listen = cfg_get(ports, "LISTEN_ADDR", "127.0.0.1")
    p_socks = cfg_get(ports, "PORT_NORMAL", "1080")
    p_lan_http = cfg_get(ports, "PORT_LAN_HTTP", "10809")
    p_http = cfg_get(ports, "PORT_HTTP", "10808")
    p_dialer = cfg_get(ports, "PORT_DIALER", "1081")

    node_name = "LAN"
    node_path = os.path.join(NODES, "current")
    try:
        node_name = json.load(open(os.path.realpath(node_path))).get("name") or "LAN"
    except (OSError, ValueError):
        pass

    safe = "".join(ch for ch in node_name if ch.isalnum() or ch in "-_") or "LAN"

    yaml_text = f"""# 由 Xray Client Manager 生成 —— 复制到需要代理的机器上使用
# 本机地址: {listen}

proxies:
  - name: "{safe}-SOCKS5"
    type: socks5
    server: {listen}
    port: {p_socks}
    udp: true
  - name: "{safe}-HTTP"
    type: http
    server: {listen}
    port: {p_lan_http}
"""

    yaml_dialer = f"""
# Browser Dialer 模式（同一台服务器，TLS 由服务器上的 Chromium 完成）
# 需要先在面板上启用 Browser Dialer
  - name: "{safe}-BrowserDialer"
    type: socks5
    server: {listen}
    port: {p_dialer}
    udp: true
"""

    links = [
        {"label": "SOCKS5（推荐，支持 UDP）", "env": "socks5", "url": f"socks5://{listen}:{p_socks}"},
        {"label": "HTTP 代理", "env": "http", "url": f"http://{listen}:{p_lan_http}"},
        {"label": "Browser Dialer（按需启用）", "env": "socks5", "url": f"socks5://{listen}:{p_dialer}"},
    ]

    return True, json.dumps({
        "listen": listen,
        "yaml": yaml_text,
        "yaml_dialer": yaml_dialer,
        "links": links,
        "env_example": (f'export http_proxy="http://{listen}:{p_lan_http}"\n'
                        f'export https_proxy="http://{listen}:{p_lan_http}"\n'
                        f'export all_proxy="socks5://{listen}:{p_socks}"'),
        "local_note": (f'本机进程（docker/apt/curl）请用 127.0.0.1:{p_http}，'
                       f'它只监听回环，不对外暴露。'),
    }, ensure_ascii=False)


def act_ports_check():
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "ports.py"), "check"], timeout=120)
    return rc == 0, (out or err)


def act_ports_fix():
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "ports", "fix"], timeout=300)
    return rc == 0, (out or err)


def act_port(kind, value):
    value = _validate_port(value)
    if value is None:
        return False, "端口必须是 1-65535 的数字"
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "port", kind, value], timeout=60)
    if rc != 0:
        return False, out or err
    rc2, out2, err2 = sh([xbd, "apply"], timeout=120)
    if rc2 != 0:
        return False, f"端口已改但配置生成失败: {out2 or err2}"
    if kind == "dialer":
        if unit_state(U_DIALER)["active"]:
            rc3, o3, e3 = sh([xbd, "dialer", "on"], timeout=240)
            return rc3 == 0, o3 or e3
        return True, f"Dialer 端口已改为 {value}（下次启用 dialer 时生效）"
    sh_bg(["bash", "-c", "sleep 1; systemctl restart " + U_XRAY])
    time.sleep(4)
    return True, f"普通模式端口已改为 {value}，Xray 已重启"


def act_config_update():
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "apply"], timeout=120)
    return rc == 0, (out or err)


def act_diagnose():
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "diagnose"], timeout=240)
    return rc == 0, (out or err)


def act_ech():
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "echcli.py"), "--quick"], timeout=120)
    return rc == 0, (out or err)


DISPATCH = {
    "import": lambda p: act_import(str(p.get("uri", "")).strip()),
    "node_use": lambda p: act_node_use(p.get("ident", "")),
    "node_remove": lambda p: act_node_remove(p.get("ident", "")),
    "node_check": lambda p: act_node_check(p.get("ident", "")),
    "node_latency": lambda p: act_node_latency(p.get("ident", "")),
    "xray_version": lambda p: act_xray_version(),
    "xray_upgrade": lambda p: act_xray_upgrade(),
    "takeover": lambda p: act_takeover(str(p.get("mode", ""))),
    "mode": lambda p: act_mode(str(p.get("mode", ""))),
    "service": lambda p: act_service(str(p.get("op", ""))),
    "port": lambda p: act_port(str(p.get("kind", "normal")), p.get("value", "")),
    "port_set": lambda p: act_port_set(str(p.get("kind", "")), p.get("value", "")),
    "conninfo": lambda p: act_conninfo(),
    "ports_check": lambda p: act_ports_check(),
    "ports_fix": lambda p: act_ports_fix(),
    "config_update": lambda p: act_config_update(),
    "diagnose": lambda p: act_diagnose(),
    "ech": lambda p: act_ech(),
}


# ---------------------------------------------------------------------- 页面 ----
PAGE = r"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Xray Client Manager</title>
<style>
:root{--bg:#0f1115;--card:#171a21;--line:#252a34;--fg:#e7ebf0;--dim:#8b95a5;
--ok:#3ddc84;--warn:#ffb44d;--bad:#ff5c5c;--acc:#4c9aff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.55 -apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:22px 18px 60px}
header{display:flex;align-items:baseline;gap:12px;margin-bottom:18px;flex-wrap:wrap}
h1{font-size:19px;margin:0;font-weight:600}
.sub{color:var(--dim);font-size:12px}
.grid{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(260px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px}
.card h2{margin:0 0 12px;font-size:12px;color:var(--dim);font-weight:600;
text-transform:uppercase;letter-spacing:.05em}
.row{display:flex;justify-content:space-between;align-items:center;padding:5px 0;
border-bottom:1px solid rgba(255,255,255,.04);gap:10px}
.row:last-child{border:0}
.k{color:var(--dim);white-space:nowrap}
.v{font-variant-numeric:tabular-nums;text-align:right}
/* 圆点：背景色只加在 .dot 上。
   之前 .ok/.bad 是独立类且带实心背景，凡是同时写 class="tag ok"
   的元素都会被涂成绿底绿字 —— 文字完全看不见。 */
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:7px;vertical-align:middle;background:#4a5262}
.dot.ok{background:var(--ok);box-shadow:0 0 8px rgba(61,220,132,.5)}
.dot.bad{background:var(--bad);box-shadow:0 0 8px rgba(255,92,92,.5)}
.dot.warn{background:var(--warn)}
.dim2{background:#4a5262}
button{background:#222834;color:var(--fg);border:1px solid var(--line);
border-radius:7px;padding:7px 13px;cursor:pointer;font-size:13px;transition:.12s}
button:hover:not(:disabled){border-color:var(--acc);color:#fff}
button.pri{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
button.danger{background:var(--bad);border-color:var(--bad);color:#fff;font-weight:600}
button.sm{padding:5px 10px;font-size:12px}
button:disabled{opacity:.4;cursor:not-allowed}
input,select{background:#11141a;color:var(--fg);border:1px solid var(--line);
border-radius:7px;padding:7px 10px;font-size:13px;width:100%}
input:focus,select:focus{outline:none;border-color:var(--acc)}
.bar{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap;align-items:center}
.bar>*{flex:0 0 auto}.bar input{flex:1 1 200px;min-width:120px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;color:var(--dim);font-weight:600;padding:7px 8px;
border-bottom:1px solid var(--line);font-size:11px;text-transform:uppercase}
td{padding:9px 8px;border-bottom:1px solid rgba(255,255,255,.04);vertical-align:middle}
tr.cur{background:rgba(76,154,255,.10)}
tr.cur td:first-child{box-shadow:inset 3px 0 0 var(--acc)}
.tag{display:inline-block;padding:2px 7px;border-radius:5px;font-size:11px;
border:1px solid var(--line);color:var(--dim);background:rgba(255,255,255,.03);
margin:1px 3px 1px 0;white-space:nowrap}
.tag.ok{color:#8ff0b8;border-color:rgba(61,220,132,.55);background:rgba(61,220,132,.13)}
.tag.warn{color:#ffd08a;border-color:rgba(255,180,77,.55);background:rgba(255,180,77,.13)}
.tag.bad{color:#ff9b9b;border-color:rgba(255,92,92,.55);background:rgba(255,92,92,.13)}
.tag.acc{color:#9cc8ff;border-color:rgba(76,154,255,.55);background:rgba(76,154,255,.13)}
pre{background:#0b0d11;border:1px solid var(--line);border-radius:8px;padding:12px;
overflow:auto;max-height:380px;font-size:12px;margin:0;white-space:pre-wrap}
#msg{margin:12px 0;padding:10px 13px;border-radius:8px;border:1px solid var(--line);
display:none;font-size:13px;white-space:pre-wrap}
#msg.on{display:block}
#msg.good{border-color:rgba(61,220,132,.5)}
#msg.err{border-color:rgba(255,92,92,.5)}
.hint{color:var(--dim);font-size:12px;margin-top:8px;line-height:1.5}
.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
.mode-pick{display:flex;gap:8px;margin-top:6px}
.mode-pick button{flex:1}
.mode-pick button.sel{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
.stopped{color:var(--dim)}
.mode3{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.mode3 button{display:flex;flex-direction:column;align-items:flex-start;gap:4px;
  text-align:left;padding:11px 12px;line-height:1.35}
.mode3 button b{font-size:13px}
.mode3 button span{font-size:11px;color:var(--dim);font-weight:400}
.mode3 button.sel{background:var(--acc);border-color:var(--acc)}
.mode3 button.sel span{color:rgba(255,255,255,.85)}
@media(max-width:620px){.mode3{grid-template-columns:1fr}}
</style></head><body><div class="wrap">

<header>
  <h1>Xray Client</h1>
  <span class="sub" id="stamp">加载中…</span>
  <span style="flex:1"></span>
  <button onclick="load()">刷新</button>
</header>

<div id="msg"></div>

  <div class="card"><h2>运行状态</h2>
    <div class="row"><span class="k">Xray（常驻）</span><span class="v" id="s-xray">—</span></div>
    <div class="row"><span class="k">连接模式</span><span class="v" id="s-mode">—</span></div>
    <div class="row"><span class="k">当前节点</span><span class="v" id="s-node">—</span></div>
    <div class="row"><span class="k">出口 IP</span><span class="v mono" id="s-ip">—</span></div>
    <div class="bar">
      <button class="pri" id="btn-toggle" onclick="toggleMain()">启动</button>
      <button onclick="svc('restart')">重启 Xray</button>
    </div>
    <div class="hint" id="hint-main">Xray 常驻运行；Browser Dialer 按需启用，两者互不影响。</div>
  </div>

<div class="card"><h2>添加节点</h2>
  <div class="bar">
    <input id="in-node" placeholder="vless:// / vmess:// / trojan:// / ss:// / hysteria2:// / 订阅URL">
    <button class="pri" onclick="addNode()">导入</button>
  </div>
  <div class="hint">导入后自动做能力检查：Xray 普通模式与 Browser Dialer 分别判定。也支持 Xray JSON 与 Mihomo YAML。</div>

<div class="card" style="margin-top:14px"><h2>节点列表（共享资产）</h2>
  <table><thead><tr>
    <th>节点</th><th>能力标签</th><th>Xray</th><th>Browser Dialer</th><th>延时</th><th style="text-align:right">操作</th>
  </tr></thead><tbody id="tb-nodes"></tbody></table>
  <div class="hint">「普通连接」与「Browser Dialer」只是同一节点的两种用法，切换不会修改节点本身。</div>

  <div class="card"><h2>Browser Dialer</h2>
    <div class="row"><span class="k">Browser Dialer</span><span class="v" id="s-dialer">—</span></div>
    <div class="row"><span class="k">Chromium</span><span class="v" id="s-chromium">—</span></div>
    <div class="row"><span class="k">浏览器连接数</span><span class="v" id="s-ws">—</span></div>
    <div class="row"><span class="k">Dialer 入口</span><span class="v mono" id="s-dport">—</span></div>
    <div class="mode-pick">
      <button id="m-normal" onclick="setMode('normal')">普通连接</button>
      <button id="m-dialer" onclick="setMode('browser_dialer')">Browser Dialer</button>
    </div>
    <div class="hint" id="hint-dialer"></div>
  </div>

  <div class="card"><h2>运行概况</h2>
    <div class="row"><span class="k">普通入口</span><span class="v mono" id="s-nport">—</span></div>
    <div class="row"><span class="k">代理连通</span><span class="v" id="s-proxy">—</span></div>
    <div class="row"><span class="k">出口 IP</span><span class="v mono" id="s-ip2">—</span></div>
    <div class="hint">端口统一在下面的「端口设置」里改，这里只做显示 ——
      之前两处都能改，容易改重。</div>
  </div>
</div>

<div class="card" style="margin-top:14px"><h2>接管模式</h2>
  <div class="hint" style="margin:0 0 10px">控制这台服务器"被接管到什么程度"。默认不接管，只提供代理服务。</div>
  <div class="mode3">
    <button id="tk-none" onclick="setTakeover('none')">
      <b>不接管</b><span>只提供代理服务<br>本机与局域网都不改</span>
    </button>
    <button id="tk-local" onclick="setTakeover('local')">
      <b>接管本机</b><span>docker / apt / curl 走代理<br>局域网不受影响</span>
    </button>
    <button id="tk-lan" onclick="setTakeover('lan')">
      <b>接管局域网</b><span>80/443 透明转发<br>SSH/LAN/DNS 已豁免</span>
    </button>
  </div>
  <div class="hint" id="hint-takeover"></div>
  <div class="row" style="margin-top:10px"><span class="k">代理入口</span>
    <span class="v mono" id="entries">—</span></div>
</div>

<div class="card" style="margin-top:14px"><h2>连接配置（可直接复制）</h2>
  <div class="hint" style="margin:0 0 10px">在需要代理的设备上使用。所有内容按当前端口实时生成，改端口后点「刷新配置」即可。</div>
  <div class="bar">
    <button onclick="loadConn(this)">刷新配置</button>
    <button onclick="copyText(document.getElementById('conn-yaml').textContent, this)">复制 YAML</button>
    <button onclick="copyText(document.getElementById('conn-env').textContent, this)">复制环境变量</button>
  </div>

  <div style="margin-top:12px"><div class="k" style="margin-bottom:5px">Mihomo / Clash 配置</div>
    <pre id="conn-yaml">点「刷新配置」生成…</pre></div>

  <div style="margin-top:12px"><div class="k" style="margin-bottom:5px">代理链接（点右侧按钮复制）</div>
    <table><tbody id="tb-links"></tbody></table></div>

  <div style="margin-top:12px"><div class="k" style="margin-bottom:5px">环境变量（Linux / macOS）</div>
    <pre id="conn-env">—</pre></div>

  <div class="hint" id="conn-note"></div>
</div>

<div class="card" style="margin-top:14px"><h2>端口设置</h2>
  <div class="hint" style="margin:0 0 10px">所有端口都可以改。改完会自动重新生成配置并重启对应服务。
    第一次安装时会自动挑没被占用的端口。</div>
  <table><tbody id="tb-ports"></tbody></table>
  <div class="bar" style="margin-top:10px">
    <input id="in-addr" placeholder="绑定地址（当前值见下表）" style="flex:1 1 160px">
    <button onclick="setAddr(this)">改绑定地址</button>
  </div>
  <div class="bar">
    <button onclick="portsCheck(this)">检查冲突</button>
    <button class="pri" onclick="portsFix(this)">自动重新分配</button>
  </div>
  <div class="hint">「自动重新分配」只改被别的服务占用的那些端口，不会动正常的。</div>
</div>

<div class="card" style="margin-top:14px"><h2>Xray 内核</h2>
  <div class="row"><span class="k">已安装版本</span><span class="v mono" id="xver">—</span></div>
  <div class="bar">
    <button onclick="xrayCheck(this)">检查更新</button>
    <button class="pri" onclick="xrayUpgrade(this)">更新内核</button>
  </div>
  <div class="hint">只更新本项目自己的副本（$PREFIX/bin/xray），不碰系统 Xray。下载后会校验官方 SHA256。</div>
</div>


</div>


</div>

<div class="card" id="out-card" style="margin-top:14px;display:none"><h2>输出</h2><pre id="out">—</pre></div>



<script>
const $ = id => document.getElementById(id);

// 复制到剪贴板。面板走的是 http（非安全上下文），
// navigator.clipboard 会被浏览器禁用，所以必须回退到 execCommand。
async function copyText(text, btn){
  if (!text || text.startsWith('点「刷新')) return say('还没有内容可复制', 'err');
  let ok = false;
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      ok = true;
    }
  } catch (e) { /* 继续走回退 */ }
  if (!ok) {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.left = '-9999px';
      ta.setAttribute('readonly', '');
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, ta.value.length);
      ok = document.execCommand('copy');
      document.body.removeChild(ta);
    } catch (e) { ok = false; }
  }
  if (ok) {
    const old = btn ? btn.textContent : '';
    if (btn) { btn.textContent = '已复制 ✓'; setTimeout(() => btn.textContent = old, 1400); }
    say('已复制到剪贴板');
  } else {
    say('自动复制被浏览器拦了，请手动选中下面的内容复制', 'err');
  }
}
const ESC = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
let ST = {};
// 延时结果缓存在前端：测速较慢，不放进 5 秒轮询里
const LAT = {};
function latText(file){
  const v = LAT[file];
  if (!v) return '<span class="hint">未测</span>';
  if (v.loading) return '<span class="hint">测试中…</span>';
  if (!v.ok) return `<span class="tag bad">${ESC(v.msg||'失败')}</span>`;
  const ms = v.ms;
  const cls = ms < 300 ? 'ok' : ms < 800 ? 'warn' : 'bad';
  return `<span class="tag ${cls}">${ms} ms</span>`;
}

function dot(on, text){ return `<span class="dot ${on?'ok':'bad'}"></span>${ESC(text)}`; }
const CN = {active:'正在运行',inactive:'已停止',failed:'启动失败',activating:'正在启动',deactivating:'正在停止',unknown:'未知'};
const cn = s => CN[s] || s;
function vtag(v, kind){
  const m = {SUPPORTED:'ok',SUPPORTED_WITH_WARNING:'warn',NOT_SUPPORTED:'bad'};
  const label = kind === 'dialer'
    ? {SUPPORTED:'✓ 支持',SUPPORTED_WITH_WARNING:'⚠ 支持',NOT_SUPPORTED:'✗ 不支持'}[v]
    : {SUPPORTED:'✓ 支持',SUPPORTED_WITH_WARNING:'⚠ 支持',NOT_SUPPORTED:'✗ 不支持'}[v];
  return `<span class="tag ${m[v]||''}">${ESC(label||v||'?')}</span>`;
}
function say(t, cls){ const m=$('msg'); m.textContent=t; m.className='on '+(cls||''); }
function clearMsg(){ $('msg').className=''; }
function out(t){ $('out-card').style.display='block'; $('out').textContent=t; }

async function load(){
  try{
    const ctl=new AbortController(); const tm=setTimeout(()=>ctl.abort(),20000);
    ST = await (await fetch('/api/state',{signal:ctl.signal})).json();
    clearTimeout(tm);
  }catch(e){ say('无法连接面板后端：'+e, 'err'); return; }
  if (ST.error){ say('状态异常：'+ST.error,'err'); return; }

  $('stamp').textContent = '更新于 ' + ST.time;

  const svc = ST.services||{}, ports = ST.ports||{}, extra = ST.services_extra||{};
  const xrayOn = svc.xray && svc.xray.active;
  const dialerOn = svc.dialer && svc.dialer.active;
  const chromOn = svc.chromium && svc.chromium.active;

  $('s-xray').innerHTML = dot(xrayOn, cn(svc.xray ? svc.xray.state : 'unknown'));
  $('s-mode').innerHTML = dialerOn ? '<span class="tag acc">Browser Dialer</span>'
                                   : (xrayOn ? '<span class="tag ok">普通 Xray</span>' : '<span class="tag">已停止</span>');
  $('s-node').textContent = ST.node ? ST.node.name : '（未选择）';
  $('s-ip').textContent = ST.exit_ip || '—';
  if ($('s-ip2')) $('s-ip2').textContent = ST.exit_ip || '—';
  $('s-proxy').innerHTML = ST.proxy_ok ? dot(true,'正常') : dot(false,'未连通');

  $('s-dialer').innerHTML = dot(dialerOn, dialerOn ? '正在运行' : '已停止');
  $('s-chromium').innerHTML = dot(chromOn, chromOn ? `正在运行 (${ST.chromium_procs||0} 进程)` : '已停止');
  $('s-ws').textContent = ST.ws_connections ?? 0;
  $('s-dport').textContent = `${ports.listen||''}:${ports.dialer||''}`;
  $('s-nport').innerHTML = `${ESC((ports.listen||'')+':'+(ports.normal||''))} ${ports.normal_up?'<span class="tag ok">监听中</span>':'<span class="tag bad">未监听</span>'}`;

  // 主按钮：跟着 Xray 状态切换
  const bt = $('btn-toggle');
  bt.textContent = xrayOn ? '停止 Xray' : '启动 Xray';
  bt.className = xrayOn ? 'danger' : 'pri';
  bt.disabled = false;

  // 模式按钮
  $('m-normal').className = (!dialerOn && xrayOn) ? 'sel' : '';
  $('m-dialer').className = dialerOn ? 'sel' : '';
  // 只根据能力决定可用性；不要因为一次请求把它永久锁死
  $('m-dialer').disabled = !ST.can_use_dialer || !xrayOn;
  $('m-normal').disabled = !xrayOn;
  $('hint-dialer').textContent = !ST.node
    ? '还没有节点。'
    : (!ST.can_use_dialer
        ? '当前节点不支持 Browser Dialer：' + (ST.dialer_reason || '')
        : (dialerOn ? 'Browser Dialer 正在运行，关闭后 Chromium 会退出，Xray 继续运行。'
                    : '点击启用：会启动 Browser Dialer 与 Chromium（按需启动，未使用时 Chromium 不常驻）。'));

  // 接管模式：三选一，如实反映当前状态
  const tkl = !!ST.takeover_local, tkn = !!ST.takeover_lan;
  const cur = tkn ? 'lan' : (tkl ? 'local' : 'none');
  for (const m of ['none','local','lan']) {
    const b = document.getElementById('tk-'+m);
    if (b) { b.className = (m === cur) ? 'sel' : ''; }
  }
  const pc = ST.ports_cfg || {};
  const L = pc.listen || '';
  $('entries').innerHTML =
    `本机 <span class="mono">127.0.0.1:${pc.http}</span><br>` +
    `LAN HTTP <span class="mono">${L}:${pc.lan_http}</span><br>` +
    `LAN SOCKS <span class="mono">${L}:${pc.normal}</span><br>` +
    `Browser Dialer <span class="mono">${L}:${pc.dialer}</span>`;
  $('hint-takeover').textContent = tkn
    ? '当前：局域网透明接管中。设备连上网络即可用，无需配置；关闭请点「不接管」。'
    : (tkl ? '当前：接管本机（docker / apt / curl 走代理）。'
           : '当前：不接管。设备需在 WiFi/系统设置里手动填上面任一入口。');

  $('xver').textContent = ST.xray_ver || '未知';

  // 端口设置表
  const PORT_ROWS = [
    ['normal',  'LAN SOCKS5（普通模式）',   pc.normal],
    ['dialer',  'LAN SOCKS5（Browser Dialer）', pc.dialer],
    ['http',    '本机 HTTP 代理（docker 等）', pc.http],
    ['lan-http','局域网 HTTP 代理（WiFi）',  pc.lan_http],
    ['channel', 'Xray↔Chromium 内部通道',   pc.channel],
    ['panel',   '面板',                     ST.panel_port || pc.panel],
    ['api',     'Xray 统计 API',            pc.api],
  ];
  // 绑定地址单独一行（只读展示 + 单独按钮改）
  if ($('in-addr')) $('in-addr').placeholder = '绑定地址（当前 ' + (pc.listen || '') + '）';
  $('tb-ports').innerHTML = PORT_ROWS.map(([k, label, val]) =>
    `<tr><td style="white-space:nowrap">${ESC(label)}</td>
      <td class="mono" style="width:90px">${ESC(val || '—')}</td>
      <td style="width:1%"><input id="pk-${k}" placeholder="新端口" inputmode="numeric" style="width:90px"></td>
      <td style="width:1%"><button class="sm" onclick="setPortOne('${k}', this)">改</button></td>
    </tr>`).join('');


  const rows = (ST.nodes||[]).map(n => {
    const c = n.compat || {};
    const x = (c.xray||{}).overall, b = (c.dialer||{}).overall;
    const tags = (c.tags||[]).map(t => {
      const cls = t.includes('不可用') ? 'bad' : (t==='Browser Dialer'||t==='Xray' ? 'acc' : '');
      return `<span class="tag ${cls}">${ESC(t)}</span>`;
    }).join('');
    return `<tr class="${n.current?'cur':''}">
      <td>${n.current?'<span class="tag ok">当前</span> ':''}${ESC(n.name)}<div class="hint mono">${ESC(n.address)}:${ESC(n.port)}</div></td>
      <td>${tags}</td>
      <td>${vtag(x,'xray')}</td>
      <td>${vtag(b,'dialer')}</td>
      <td class="mono" id="lat-${ESC(n.file)}" style="white-space:nowrap">${latText(n.file)}</td>
      <td style="text-align:right;white-space:nowrap">
        ${n.current ? '' : `<button class="sm pri" onclick="useNode('${ESC(n.file)}', this)">普通连接</button>`}
        <button class="sm" onclick="testLatency('${ESC(n.file)}', this)">测速</button>
        <button class="sm" onclick="checkNode('${ESC(n.file)}', this)">检查</button>
        ${n.current ? '' : `<button class="sm" onclick="rmNode('${ESC(n.file)}')">删除</button>`}
      </td></tr>`;
  });
  $('tb-nodes').innerHTML = rows.join('') || '<tr><td colspan="6" class="hint">还没有节点，先在上面导入</td></tr>';
  // 轮询会重建表格，这里把已测到的延时重新画上，避免结果被冲掉
  Object.keys(LAT).forEach(f => {
    const c = document.getElementById('lat-'+f);
    if (c) c.innerHTML = latText(f);
  });
}

// 只禁用"被点的那个按钮"并显示进度 —— 以前是全局禁用所有按钮，
// 一旦异常或状态残留，整个面板就再也点不动了（看起来像黑掉）。
async function post(action, payload, label, btn){
  if (label) say(label);
  let oldText = '';
  if (btn) { oldText = btn.textContent; btn.disabled = true; btn.dataset.busy = '1'; }
  try{
    const r = await fetch('/api/action', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify(Object.assign({action}, payload||{}))});
    const j = await r.json();
    say((j.ok?'✓ ':'✗ ') + (j.message||''), j.ok?'good':'err');
    return j;
  }catch(e){ say('请求失败：'+e,'err'); return {ok:false}; }
  finally{
    if (btn) { btn.disabled = false; btn.dataset.busy = ''; btn.textContent = oldText; }
    try { await load(); } catch(e) { /* 刷新失败不影响按钮恢复 */ }
  }
}

async function toggleMain(){
  const on = ST.services && ST.services.xray && ST.services.xray.active;
  await post('service', {op: on?'stop':'start'}, on?'正在停止 Xray…':'正在启动 Xray…');
}
const svc = op => post('service', {op}, '正在执行…');
const setMode = m => post('mode', {mode:m},
  m==='browser_dialer' ? '正在启用 Browser Dialer（启动 Chromium，约需 15 秒）…' : '正在关闭 Browser Dialer…');
const useNode = (f, btn) => post('node_use', {ident:f}, '正在切换节点…', btn);
const rmNode = f => { if(confirm('确认删除该节点？')) post('node_remove', {ident:f}); };
async function setTakeover(mode, btn){
  const labels = {none:'正在切换为「不接管」…', local:'正在接管本机（会重启 docker）…',
                  lan:'正在接管局域网（写入 nftables 规则）…'};
  const el = btn || document.getElementById('tk-'+mode);
  await post('takeover', {mode}, labels[mode], el);
}

async function xrayCheck(btn){ await post('xray_version', {}, '正在检查版本…', btn); }

async function xrayUpgrade(btn){
  if (!confirm('确认更新 Xray 内核？更新后本项目服务会重启（局域网代理会短暂中断几秒）。')) return;
  await post('xray_upgrade', {}, '正在下载并更新内核，可能需要 1-2 分钟…', btn);
}

async function setPortOne(kind, btn){
  const el = document.getElementById('pk-'+kind);
  const v = (el && el.value || '').trim();
  if (!v) return say('请先在「'+kind+'」这一行填入新端口', 'err');
  const warn = {channel:'内部通道改动会重启 Browser Dialer（若在运行）', panel:'面板端口改动后需用新地址访问'}[kind];
  if (warn && !confirm(warn + '，确认继续？')) return;
  const j = await post('port_set', {kind, value:v}, `正在修改 ${kind} 端口…`, btn);
  if (j.ok && el) el.value = '';
}

async function loadConn(btn){
  const j = await post('conninfo', {}, '正在生成连接配置…', btn);
  if (!j.ok) return;
  let d;
  try { d = JSON.parse(j.message); } catch (e) { return say('配置生成失败', 'err'); }
  $('conn-yaml').textContent = d.yaml + d.yaml_dialer;
  $('conn-env').textContent = d.env_example;
  $('conn-note').textContent = d.local_note || '';
  $('tb-links').innerHTML = (d.links || []).map(l =>
    `<tr><td style="white-space:nowrap">${ESC(l.label)}</td>
      <td class="mono">${ESC(l.url)}</td>
      <td style="width:1%"><button class="sm" onclick="copyText('${ESC(l.url)}', this)">复制</button></td>
    </tr>`).join('');
}

async function setAddr(btn){
  const el = $('in-addr');
  const v = (el && el.value || '').trim();
  if (!v) return say('请输入绑定地址（如 127.0.0.1 或 192.168.1.178）', 'err');
  if (v === '0.0.0.0') {
    if (!confirm('0.0.0.0 会让代理对你的整个网络（含公网，若端口转发）开放。确认？')) return;
  }
  const j = await post('port_set', {kind:'addr', value:v}, '正在修改绑定地址…', btn);
  if (j.ok && el) el.value = '';
}

async function portsCheck(btn){ await post('ports_check', {}, '正在检查端口冲突…', btn); }
async function portsFix(btn){
  if (!confirm('自动重新分配被占用的端口？只改冲突的那些，正常的端口不动。')) return;
  await post('ports_fix', {}, '正在重新分配…', btn);
}

const addNode = () => {
  const v = $('in-node').value.trim();
  if(!v) return say('请粘贴节点链接或订阅地址','err');
  post('import', {uri:v}, '正在导入并做能力检查…');
};
async function testLatency(file, btn){
  LAT[file] = {loading:true};
  const paint = () => {
    const c = document.getElementById('lat-'+file);
    if (c) c.innerHTML = latText(file);
  };
  paint();
  // 关键：把结果写回该行的延时单元格。
  // 以前 load() 会重建表格把结果冲掉，且 post() 的全局禁用在异常时永不恢复。
  const j = await post('node_latency', {ident:file}, '正在测速（真实请求，约 3-10 秒）…', btn);
  if (j.ok) {
    const m = /(\d+)\s*ms/.exec(j.message||'');
    LAT[file] = {ok:true, ms: m ? parseInt(m[1],10) : 0, echo:(j.message||'').trim()};
  } else {
    LAT[file] = {ok:false, msg:(j.message||'').replace(/^✗\s*/,'')};
  }
  paint();
}

async function checkNode(f, btn){
  const j = await post('node_check', {ident:f}, '正在检查能力…', btn);
  if (j.ok) out(j.message);
  else say((j.message||'检查失败'), 'err');
}

load();
loadConn();
setInterval(load, 5000);
</script></div></body></html>
"""


# ---------------------------------------------------------------------- HTTP ----
class Handler(BaseHTTPRequestHandler):
    server_version = "XBD-Panel"
    token = ""
    cookie_name = "xbd_token"

    def log_message(self, *a):
        pass

    def handle_one_request(self):
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        except Exception:
            import traceback
            traceback.print_exc()

    def _authed(self):
        if not self.token:
            return True
        if self.headers.get("X-Panel-Token") == self.token:
            return True
        raw = self.headers.get("Cookie", "")
        if raw:
            try:
                jar = SimpleCookie()
                jar.load(raw)
                if jar.get(self.cookie_name) and jar[self.cookie_name].value == self.token:
                    return True
            except Exception:
                pass
        given = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("token", [""])[0]
        if given == self.token:
            self._set_cookie = True
            return True
        return False

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if getattr(self, "_set_cookie", False):
            self.send_header("Set-Cookie", f"{self.cookie_name}={self.token}; Path=/; SameSite=Strict")
            self._set_cookie = False
        self.end_headers()
        self.wfile.write(data)

    def _deny(self):
        body = ("<!DOCTYPE html><meta charset=utf-8><title>需要令牌</title>"
                '<body style="font:15px -apple-system,Segoe UI,Roboto,sans-serif;'
                'background:#0f1115;color:#e7ebf0;padding:40px">'
                "<h2>需要访问令牌</h2>"
                "<p>请在地址后加上 <code>?token=你的令牌</code></p>"
                '<p style="color:#8b95a5">令牌保存在服务器的 '
                "<code>/opt/xray-browser-dialer/config/panel.env</code></p></body>")
        self._send(401, body, "text/html")

    def do_GET(self):
        if not self._authed():
            return self._deny()
        path = urllib.parse.urlparse(self.path).path or "/"
        if path in ("/", "/index.html"):
            return self._send(200, PAGE, "text/html")
        if path == "/api/state":
            state = build_state()
            state["panel_host"] = cfg_get(os.path.join(CONF, "panel.env"), "PANEL_HOST", "")
            state["panel_port"] = cfg_get(os.path.join(CONF, "panel.env"), "PANEL_PORT", "")
            return self._send(200, json.dumps(state, ensure_ascii=False))
        return self._send(404, "<!DOCTYPE html><meta charset=utf-8><h3>404</h3>", "text/html")

    def do_POST(self):
        if not self._authed():
            return self._deny()
        if urllib.parse.urlparse(self.path).path != "/api/action":
            return self._send(404, json.dumps({"ok": False, "message": "not found"}))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, TypeError):
            return self._send(400, json.dumps({"ok": False, "message": "bad request"}))
        action = str(payload.get("action", ""))
        fn = DISPATCH.get(action)
        if not fn:
            return self._send(200, json.dumps({"ok": False, "message": f"未知操作: {action}"}, ensure_ascii=False))
        try:
            ok, message = fn(payload)
        except Exception as exc:
            ok, message = False, f"执行异常: {exc}"
        return self._send(200, json.dumps({"ok": bool(ok), "message": message}, ensure_ascii=False))


def load_panel_env():
    env = os.path.join(CONF, "panel.env")
    return (cfg_get(env, "PANEL_HOST", BIND_HOST),
            int(cfg_get(env, "PANEL_PORT", str(BIND_PORT)) or BIND_PORT),
            cfg_get(env, "PANEL_TOKEN", ""))


def main():
    host, port, token = load_panel_env()
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--host" and i + 1 < len(args):
            host = args[i + 1]; i += 2; continue
        if a == "--port" and i + 1 < len(args):
            port = int(args[i + 1]); i += 2; continue
        if a == "--token" and i + 1 < len(args):
            token = args[i + 1]; i += 2; continue
        i += 1
    Handler.token = token
    srv = ThreadingHTTPServer((host, port), Handler)
    scope = "仅本机" if host in ("127.0.0.1", "localhost") else f"局域网可达 {host}"
    print(f"面板 http://{host}:{port} ({scope})" + ("，需要令牌" if token else ""), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
