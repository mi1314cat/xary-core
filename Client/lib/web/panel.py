#!/usr/bin/env python3
"""Xray Client Web Manager — 面板后端。

设计要点：
    * **唯一一个 Xray 实例**，同时提供 SOCKS 与 HTTP 两个 LAN 入站，并始终带
      XRAY_BROWSER_DIALER —— 所以不存在"普通模式 / Browser Dialer 模式"的切换，
      也没有第二条 SOCKS 端口。节点是共享资产，换节点不改任何服务。
    * Browser Dialer 是**节点的属性**：当前节点是 xhttp/websocket 且非 REALITY 时
      Xray 把 TLS 交给 Chromium，否则自己完成 TLS。状态栏如实显示"这个节点走哪条路"。
    * Chromium 是 Browser Dialer 的运行时依赖，面板只控制它开/关：
      它是唯一实例的常驻依赖，停掉后依赖浏览器拨号的节点会失败，其余节点不受影响。

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
        "http": cfg_get(ports, "PORT_HTTP", "10808"),
        "lan_http": cfg_get(ports, "PORT_LAN_HTTP", "10809"),
        "listen": cfg_get(ports, "LISTEN_ADDR", "127.0.0.1"),
        "channel": (cfg_get(ports, "DIALER_ADDR", "127.0.0.1:18081").rpartition(":")[2]),
        "api": cfg_get(os.path.join(CONF, "api.env"), "API_PORT", "18085"),
    }

    # 本机接管：不能只看 proxy.sh —— 接管点可能落在**别人**原有的配置里
    # （xbd proxy on 是"改配置而非新增"）。真相只有一个来源：xbd proxy json。
    rc, out, _ = sh([os.path.join(PREFIX, "bin", "xbd"), "proxy", "json"], timeout=30)
    try:
        local = json.loads((out or "").strip().splitlines()[-1])
    except (ValueError, IndexError):
        local = {}
    state["takeover_local"] = bool(local.get("enabled"))
    state["takeover_local_files"] = [f for f in (local.get("shell"), local.get("docker"),
                                                 local.get("environment")) if f]
    state["takeover_local_owners"] = int(local.get("owners") or 0)
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
    msg = "已切换节点，Xray 正在重启"
    if caps.get("can_use_dialer") and not unit_state(U_CHROMIUM)["active"]:
        started, note = ensure_chromium()
        msg += f"；{note}" if started else f"；⚠ {note}（该节点需要浏览器拨号，请手动执行 xbd dialer on）"
    return True, msg


def act_node_browser(ident, value):
    """单个节点的"是否用浏览器完成 TLS"开关。

    协议不支持时后端会拒绝打开；**支持的节点后端会拒绝关闭** ——
    因为 xhttp/websocket 出站只要浏览器在线就被无条件接管（见 Xray 源码
    splithttp/dialer.go:50、websocket/dialer.go:114），关掉只会让该节点不可用。
    """
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "browser",
                       os.path.basename(path), str(value)], timeout=300)
    return rc == 0, ((out or err or "").strip() or "已保存")


def act_node_use_as(ident, mode):
    """切到某个节点，并明确指定用普通连接还是 BD 连接。

    这是把"用哪个节点"和"用哪种 TLS"合成一个动作 —— 用户点「BD 连接」时，
    期望的是"切过去并且用浏览器"，而不是切过去之后还得再找开关。
    """
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    caps = compat_of(path) or {}
    if mode == "bd" and not caps.get("protocol_may_dialer"):
        return False, "该节点不走浏览器转发（只对 vless 的 ws/xhttp 生效）"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "use-as",
                       os.path.basename(path), mode], timeout=300)
    if rc != 0:
        return False, (out or err or "切换失败")
    # 节点切换与 TLS 方式变化都会让旧进程的环境变量失效，统一重启一次
    sh(["systemctl", "restart", U_XRAY], timeout=90)
    time.sleep(5)
    if not unit_state(U_XRAY)["active"]:
        return False, "Xray 重启失败，请查看 xbd status"
    # 用浏览器时确保 Chromium 在线；不用时确保停掉（省内存）
    if mode == "bd":
        okc, notec = ensure_chromium()
        if not okc:
            return True, "已切到 %s，但 %s" % (os.path.basename(path), notec)
        return True, "已切到 BD 连接（浏览器 TLS），%s" % notec
    if unit_state(U_CHROMIUM)["active"]:
        sh([os.path.join(PREFIX, "bin", "xbd"), "dialer", "off"], timeout=180)
    return True, "已切到普通连接（Xray 自带 TLS），Chromium 已关闭以释放内存"


def act_node_probe(ident):
    """真实探测一个节点的浏览器路径（临时起 Xray + Chromium，不动生产服务）。"""
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, err = sh(["python3", os.path.join(PREFIX, "tools", "browserprobe.py"),
                       path, "--save", "--json"], timeout=180)
    try:
        d = json.loads(out or "{}")
    except ValueError:
        d = {}
    if d.get("not_applicable"):
        return True, "该节点不走浏览器转发：" + str(d.get("reason", ""))
    if d.get("ok"):
        return True, "实测可用（出口 %s）" % (d.get("exit_ip") or "已通")
    return True, "实测不可用：" + str(d.get("reason") or err or "未知原因")


def ensure_chromium():
    """确保 Browser Dialer 的运行时在线。节点依赖它却没跑时，代理会静默失败。"""
    if unit_state(U_CHROMIUM)["active"]:
        return True, "Chromium 已在线"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "dialer", "on"], timeout=300)
    return rc == 0, ("已自动启动 Chromium" if rc == 0 else (out or err or "Chromium 启动失败"))


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
    if unit_state(U_CHROMIUM)["active"]:
        sh(["systemctl", "restart", U_CHROMIUM], timeout=60)
    return True, f'内核已更新 {d.get("from") or "无"} → {d.get("to")} {note}，服务已重启'


def _px_note(out):
    """把 xbd proxy on 的关键决策行带回界面：改了谁家的配置，或新建了什么。"""
    keep = [l.strip() for l in (out or "").splitlines()
            if ("接管" in l or "已写" in l or "已移除" in l or l.lstrip().startswith("["))
            and "本机没有别的" not in l]
    return ("\n" + "\n".join(keep)) if keep else ""


def act_takeover(mode):
    """两种接管模式：不接管 / 接管本机。

    曾经的第三种「接管局域网」（透明网关）已移除 —— 设计与实测存档在
    docs/mode3-lan-gateway/。局域网设备改为自己在代理设置里填 IP:端口。
    """
    xbd = os.path.join(PREFIX, "bin", "xbd")
    if mode == "none":
        out_msgs = []
        for args in (["proxy", "off"],):
            rc, o, e = sh([xbd] + args, timeout=180)
            out_msgs.append(o or e or "")
        return True, "已切换为「不接管」：只提供代理服务，不修改本机与局域网" + \
            ("\n" + "\n".join(x.strip() for x in out_msgs if x.strip()) if out_msgs else "")
    if mode == "local":
        rc, out, err = sh([xbd, "proxy", "on"], timeout=300)
        if rc != 0:
            return False, out or err
        return True, "已接管本机：docker / apt / curl 走我们的代理（局域网不受影响）" + _px_note(out)
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
    """Browser Dialer 运行时的开关。

    注意：这里**没有**"切换到普通模式"这回事 —— 唯一 Xray 实例始终同时服务
    SOCKS 与 HTTP，并始终带 XRAY_BROWSER_DIALER。停掉 Chromium 不会中断任何
    不需要浏览器拨号的节点，只是让依赖它的那些节点暂时不可用。
    """
    xbd = os.path.join(PREFIX, "bin", "xbd")
    if mode in ("browser_dialer", "on"):
        rc, out, err = sh([xbd, "dialer", "on"], timeout=300)
        if rc != 0:
            return False, (out or err or "启动失败")
        # 只回报结果，不回放整段脚本输出（页面上那样很难读）
        ws = (build_state() or {}).get("ws_connections", 0)
        return True, (f"Chromium 已启动，浏览器已接上（{ws} 条 WS）" if ws
                      else "Chromium 已启动，浏览器还在连接（health timer 会在 30 秒内自愈）")
    if mode in ("normal", "off"):
        rc, out, err = sh([xbd, "dialer", "off"], timeout=180)
        if rc != 0:
            return False, (out or err or "关闭失败")
        needs = False
        try:
            rc2, o2, _ = sh(["python3", COMPAT_PY, "json",
                             os.path.realpath(os.path.join(NODES, "current"))], timeout=30)
            needs = rc2 == 0 and json.loads(o2 or "{}").get("can_use_dialer") is True
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        warn = "⚠ 当前节点依赖浏览器拨号，它现在会拨号失败" if needs else "当前节点不需要浏览器拨号，不受影响"
        return True, f"Chromium 已停止，Xray 继续运行；{warn}"
    return False, "未知操作"


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
        sh(["systemctl", "restart", U_XRAY, U_CHROMIUM], timeout=120)
        if unit_state(U_CHROMIUM)["active"]:
            return True, f"内部通道已改为 {value}，Xray 与 Chromium 已重启"
        return True, f"内部通道已改为 {value}（Chromium 未运行，下次启动时生效）"
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

    node_name = "LAN"
    node_path = os.path.join(NODES, "current")
    try:
        node_name = json.load(open(os.path.realpath(node_path))).get("name") or "LAN"
    except (OSError, ValueError):
        pass

    safe = "".join(ch for ch in node_name if ch.isalnum() or ch in "-_") or "LAN"

    yaml_text = f"""# 由 Xray Client Manager 生成 —— 复制到需要代理的机器上使用
# 本机地址: {listen}
# 两个入口都由同一个 Xray 实例服务，所有节点通用；节点是否需要浏览器拨号由服务器决定。
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

    links = [
        {"label": "SOCKS5（推荐，支持 UDP）", "env": "socks5", "url": f"socks5://{listen}:{p_socks}"},
        {"label": "HTTP 代理", "env": "http", "url": f"http://{listen}:{p_lan_http}"},
    ]

    return True, json.dumps({
        "listen": listen,
        "yaml": yaml_text,
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
    if kind == "channel":
        sh(["systemctl", "restart", U_XRAY, U_CHROMIUM], timeout=120)
        return True, f"内部通道已改为 {value}，两端已重启"
    sh_bg(["bash", "-c", "sleep 1; systemctl restart " + U_XRAY])
    time.sleep(4)
    return True, f"端口已改为 {value}，Xray 已重启"


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
    "node_browser": lambda p: act_node_browser(p.get("ident", ""), p.get("value", "auto")),
    "node_probe": lambda p: act_node_probe(p.get("ident", "")),
    "node_use_as": lambda p: act_node_use_as(p.get("ident", ""), p.get("mode", "normal")),
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
.modes{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}
.modes button{display:flex;flex-direction:column;align-items:flex-start;gap:4px;
  text-align:left;padding:11px 12px;line-height:1.35}
.modes button b{font-size:13px}
.modes button span{font-size:11px;color:var(--dim);font-weight:400}
.modes button.sel{background:var(--acc);border-color:var(--acc)}
.modes button.sel span{color:rgba(255,255,255,.85)}
@media(max-width:620px){.modes{grid-template-columns:1fr}}
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
    <textarea id="in-node" rows="6" style="width:100%;font-family:monospace" placeholder="粘贴节点（可多个）：vless:// vmess:// trojan:// ss:// hysteria2:// / Xray JSON / Mihomo YAML（支持整段多行粘贴）/ 订阅URL"></textarea>
    <button class="pri" onclick="addNode()">导入</button>
  </div>
  <div class="hint">导入后自动做能力检查：Xray 普通模式与 Browser Dialer 分别判定。也支持 Xray JSON 与 Mihomo YAML。</div>

<div class="card" style="margin-top:14px"><h2>节点列表（共享资产）</h2>
  <table><thead><tr>
    <th>节点</th><th>能力标签</th><th>Xray</th><th>Browser Dialer</th><th>延时</th><th style="text-align:right">操作</th>
  </tr></thead><tbody id="tb-nodes"></tbody></table>
  <div class="hint">「普通连接」与「Browser Dialer」只是同一节点的两种用法，切换不会修改节点本身。</div>

  <div class="card"><h2>Browser Dialer（按节点自动生效）</h2>
    <div class="row"><span class="k">当前节点走哪条路</span><span class="v" id="s-dialer">—</span></div>
    <div class="row"><span class="k">Chromium 运行时</span><span class="v" id="s-chromium">—</span></div>
    <div class="row"><span class="k">浏览器连接数</span><span class="v" id="s-ws">—</span></div>
    <div class="row"><span class="k">Chromium 进程</span><span class="v" id="s-chromium-procs">—</span></div>
    <div class="mode-pick">
      <button id="m-dialer" onclick="setMode('browser_dialer')">启动 Chromium</button>
      <button id="m-normal" onclick="setMode('normal')"
              title="会把当前节点切到普通连接（Xray 自带 TLS）并停掉 Chromium，释放约 890MB">停掉 Chromium</button>
    </div>
    <div class="hint" id="hint-dialer"></div>
  </div>

  <div class="card"><h2>运行概况</h2>
    <div class="row"><span class="k">SOCKS5 入口</span><span class="v mono" id="s-nport">—</span></div>
    <div class="row"><span class="k">HTTP 入口</span><span class="v mono" id="s-hport">—</span></div>
    <div class="row"><span class="k">代理连通</span><span class="v" id="s-proxy">—</span></div>
    <div class="row"><span class="k">出口 IP</span><span class="v mono" id="s-ip2">—</span></div>
    <div class="hint">端口统一在下面的「端口设置」里改，这里只做显示 ——
      之前两处都能改，容易改重。</div>
  </div>
</div>

<div class="card" style="margin-top:14px"><h2>接管模式</h2>
  <div class="hint" style="margin:0 0 10px">控制这台服务器"被接管到什么程度"。默认不接管，只提供代理服务。</div>
  <div class="modes">
    <button id="tk-none" onclick="setTakeover('none')">
      <b>不接管</b><span>只提供代理服务<br>本机与局域网都不改</span>
    </button>
    <button id="tk-local" onclick="setTakeover('local')">
      <b>接管本机</b><span>docker / apt / curl 走代理<br>局域网不受影响</span>
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
// 每节点的"浏览器"开关。
//   协议不支持 -> 置灰不可点（它本来就走 Xray 自带 TLS，开了也没用）
//   协议支持   -> 显示为"始终使用"并锁住：xhttp/websocket 出站只要浏览器在线就被
//                Xray 无条件接管，关掉不是退回 Xray TLS，而是让该节点直接不可用。
// 每节点的"浏览器"开关。
//   协议不支持（非 vless 的 ws/xhttp、或 REALITY）-> 置灰，写了也没用
//   协议支持 -> 可切换：默认（用浏览器）/ 强制用 / 强制不用（走 Xray 自带 TLS）
// 切换会重启 Xray：是否带 XRAY_BROWSER_DIALER 是进程启动时决定的，不重启不生效。
function browserToggle(n){
  const c = n.compat || {};
  const dialer = c.dialer || {};
  const overall = dialer.overall || '';
  const can = overall === 'SUPPORTED' || overall === 'SUPPORTED_WITH_WARNING';
  const mayProto = !!c.protocol_may_dialer;      // 协议层面是否可能走浏览器
  const probe = n.probe_ok;                       // true / false / undefined

  // 协议层面就不可能 -> 真置灰。写了也没用：hysteria2 会走它自己的原生 QUIC，
  // 浏览器根本不在路径上（实测过：代理能通，但那是原生 QUIC 通的）。
  if (!mayProto) {
    const why = (dialer.notes||[])[0] || '该协议不走浏览器转发（只对 vless 的 ws/xhttp 生效，且不支持 REALITY）';
    return `<span class="tag" title="${ESC(why)}">— 不需要</span>`;
  }

  // 协议可能但实测失败 -> 给个可点的「重测」。
  // 不能做成死灰：服务器那边的配置问题修好之后，用户得有办法恢复。
  if (probe === false) {
    const why = (dialer.notes||[]).join(' ') || '实测未通过';
    return `<span class="tag warn" style="cursor:pointer" title="${ESC('实测未通过：' + why + ' — 点此重新探测（服务器修好后可恢复）')}"`
         + ` onclick="reprobe('${ESC(n.file)}', this)">重测</span>`;
  }
  // 协议可能、还没测过
  if ((probe === undefined || probe === null) && !can) {
    const why = (dialer.notes||[]).join(' ') || '判定未通过';
    return `<span class="tag warn" style="cursor:pointer" title="${ESC(why + ' — 点此实测一次')}"`
         + ` onclick="reprobe('${ESC(n.file)}', this)">未实测</span>`;
  }

  // 可用：在 默认 / 浏览器 / 原生 之间切换
  const ub = n.use_browser;
  let label, cls, title;
  if (ub === false)     { label = '原生 TLS';     cls = '';    title = '已强制不用浏览器，Xray 自己完成 TLS（点一下改为默认）'; }
  else if (ub === true) { label = '浏览器';       cls = 'acc'; title = '已强制使用浏览器（点一下改为原生）'; }
  else                  { label = '浏览器(默认)'; cls = 'acc'; title = '默认：协议支持就用浏览器（点一下改为原生 TLS）'; }
  return `<span class="tag ${cls}" style="cursor:pointer" title="${ESC(title)}"`
       + ` onclick="toggleBrowser('${ESC(n.file)}', this)">${ESC(label)}</span>`;
}
// 「普通连接」与「BD 连接」两个独立按钮 —— 这是同一个节点的两种用法：
//   普通连接 = 用 Xray 自带 TLS（同时会把浏览器关掉，省下 Chromium 的显存/内存）
//   BD 连接  = 用浏览器完成 TLS（真实浏览器指纹）
// 当前节点上也各留一个**可点**的按钮，用来在两种用法之间切换 ——
// 以前当前节点什么都不显示，用户就没有入口去切换，看起来像"关不掉"。
function useButtons(n){
  const c = n.compat || {};
  const mayProto = !!c.protocol_may_dialer;      // 协议层面能否走浏览器
  const probe = n.probe_ok;                       // true / false / undefined
  const canBD = mayProto && probe !== false;      // 能用浏览器的前提：协议可能 + 实测没失败
  const ub = n.use_browser;
  const bdOn = canBD && ub !== false;             // 当前是否在用浏览器
  const cur = !!n.current;

  // 「普通连接」**永远**要有 —— 任何节点都能用 Xray 自带 TLS。
  // 之前只在"能用浏览器"的分支里给这个按钮，导致不支持 BD 的节点完全没有入口切过去
  // （用户反馈：其他节点连"普通连接"按钮都没有）。这是个实打实的疏漏。
  let h = `<button class="sm ${(!bdOn && cur) ? 'pri' : ''}" `
        + `onclick="useNodeAs('${ESC(n.file)}','normal', this)" `
        + `title="用 Xray 自带 TLS（会关闭浏览器，释放内存）">普通连接</button>`;

  if (!mayProto) {
    // 协议层面就不可能走浏览器：标明原因即可，不再给 BD 按钮
    const why = ((c.dialer||{}).notes||[])[0] || '该协议不走浏览器转发（只对 vless 的 ws/xhttp 生效）';
    h += `<span class="tag" title="${ESC(why)}">仅原生</span>`;
  } else if (probe === false) {
    // 协议可能、实测失败：给「重测」，服务器修好后能恢复
    h += `<span class="tag warn" style="cursor:pointer" `
       + `title="${ESC('实测未通过，点此重新探测（服务器修好后可恢复）')}" `
       + `onclick="reprobe('${ESC(n.file)}', this)">重测</span>`;
  } else {
    h += `<button class="sm ${(bdOn && cur) ? 'pri' : ''}" `
       + `onclick="useNodeAs('${ESC(n.file)}','bd', this)" `
       + `title="用浏览器完成 TLS（真实浏览器指纹）">BD 连接</button>`;
  }
  return h;
}
async function useNodeAs(file, mode, btn){
  const label = (mode === 'bd')
    ? '正在切到 BD 连接（启用浏览器）…'
    : '正在切到普通连接（关闭浏览器）…';
  await post('node_use_as', {ident:file, mode:mode}, label, btn);
}
async function reprobe(file, btn){
  await post('node_probe', {ident:file}, '正在实测浏览器路径（约 30-60 秒）…', btn);
}
async function toggleBrowser(file, btn){
  // 在 默认 -> 原生 -> 浏览器 -> 默认 之间循环
  const row = (ST.nodes||[]).find(x => x.file === file) || {};
  const cur = row.use_browser;
  const next = (cur === null || cur === undefined) ? 'off' : (cur === false ? 'on' : 'auto');
  const label = {off:'正在改为原生 TLS（重启 Xray）…', on:'正在改为浏览器 TLS（重启 Xray）…',
                 auto:'正在改为默认…'}[next];
  await post('node_browser', {ident:file, value:next}, label, btn);
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
  const chromOn = svc.chromium && svc.chromium.active;
  const canBD = !!ST.can_use_dialer;

  $('s-xray').innerHTML = dot(xrayOn, cn(svc.xray ? svc.xray.state : 'unknown'));
  // 状态栏要说清"这个节点实际走哪条路"，而不是笼统的 Running
  // 连接模式也要说"当前实际走哪条路"。以前只看 can_use_dialer（协议能力），
  // 于是用户主动选了「普通连接」之后，界面还在报红"需要浏览器 TLS，但 Chromium 已停" ——
  // 明明能正常用，纯属误报，看着让人以为坏了。
  // 现在优先用后端给的 mode_detail（把"在跑什么"和"走哪条路"合成一句话），
  // 拿不到时退回本地判断。
  const bdInUse = canBD && ST.use_browser !== false;
  const detail = ST.mode_detail || '';
  $('s-mode').innerHTML = !xrayOn
    ? '<span class="tag">已停止</span>'
    : (bdInUse && !chromOn
        ? '<span class="tag bad">需要浏览器 TLS，但 Chromium 已停</span>'
        : `<span class="tag ${bdInUse ? 'acc' : 'ok'}">${ESC(detail || (bdInUse ? '浏览器 TLS' : 'Xray 自带 TLS'))}</span>`);
  $('s-node').textContent = ST.node ? ST.node.name : '（未选择）';
  $('s-ip').textContent = ST.exit_ip || '—';
  if ($('s-ip2')) $('s-ip2').textContent = ST.exit_ip || '—';
  $('s-proxy').innerHTML = ST.proxy_ok ? dot(true,'正常') : dot(false,'未连通');

  const nodePath = !ST.node ? '（未选择节点）'
    : (canBD ? (chromOn ? '经浏览器（Chromium 完成 TLS）' : '需要浏览器，但 Chromium 未运行')
             : '经 Xray（自带 TLS，不需要浏览器）');
  $('s-dialer').innerHTML = !ST.node ? ESC(nodePath)
    : (canBD ? `<span class="tag ${chromOn?'acc':'bad'}">${ESC(nodePath)}</span>`
             : `<span class="tag ok">${ESC(nodePath)}</span>`);
  $('s-chromium').innerHTML = dot(chromOn, chromOn ? `正在运行 (${ST.chromium_procs||0} 进程)` : '已停止');
  $('s-ws').textContent = ST.ws_connections ?? 0;
  $('s-nport').innerHTML = `${ESC((ports.listen||'')+':'+(ports.normal||''))} ${ports.normal_up?'<span class="tag ok">监听中</span>':'<span class="tag bad">未监听</span>'}`;
  if ($('s-hport')) $('s-hport').innerHTML = `${ESC((ports.listen||'')+':'+(ports.lan_http||''))} ${ports.lan_http_up?'<span class="tag ok">监听中</span>':'<span class="tag bad">未监听</span>'}`;

  // 主按钮：跟着 Xray 状态切换
  const bt = $('btn-toggle');
  bt.textContent = xrayOn ? '停止 Xray' : '启动 Xray';
  bt.className = xrayOn ? 'danger' : 'pri';
  bt.disabled = false;

  // 运行时按钮：控制 Chromium 在不在线。
  //
  // 这里刻意**不**用"节点是否支持 BD"来禁用「停掉 Chromium」——
  // 以前那样写，当前节点一旦支持 BD 这个按钮就永远点不动，用户以为坏了（实测反馈）。
  // 现在的语义是：
  //   启动 Chromium  -> 当前节点走浏览器（等价于点「BD 连接」）
  //   停掉 Chromium  -> 先把当前节点切到普通连接（Xray 自带 TLS），再停浏览器
  // 也就是说这两个按钮和操作列的两个按钮是**同一套动作**，不会再互相矛盾。
  const nodeUsesBrowser = !!ST.can_use_dialer && ST.use_browser !== false;
  $('m-normal').className = chromOn ? '' : 'sel';
  $('m-dialer').className = chromOn ? 'sel' : '';
  $('m-dialer').disabled = !xrayOn || chromOn;
  $('m-normal').disabled = !xrayOn || !chromOn;
  if ($('s-chromium-procs')) {
    $('s-chromium-procs').textContent = chromOn
      ? `${ST.chromium_procs || 0} 个进程（约 890MB）` : '未运行';
  }
  $('hint-dialer').textContent = !ST.node
    ? '还没有节点。'
    : (nodeUsesBrowser
        ? (chromOn
            ? '当前节点由 Chromium 完成 TLS。点「停掉 Chromium」会先把它切到普通连接（Xray 自带 TLS）再关闭浏览器 —— 节点不会断，只是不再走浏览器。'
            : '⚠ 当前节点设置为走浏览器，但 Chromium 没在运行 —— 点「启动 Chromium」恢复。')
        : '当前节点走 Xray 自带 TLS，Chromium 关着即可（省约 890MB）。想改用浏览器指纹：在下面节点表点「BD 连接」。');
  // 接管模式：三选一，如实反映当前状态
  const tkl = !!ST.takeover_local;
  const cur = tkl ? 'local' : 'none';
  for (const m of ['none','local']) {
    const b = document.getElementById('tk-'+m);
    if (b) { b.className = (m === cur) ? 'sel' : ''; }
  }
  const pc = ST.ports_cfg || {};
  const L = pc.listen || '';
  $('entries').innerHTML =
    `本机 <span class="mono">127.0.0.1:${pc.http}</span><br>` +
    `LAN HTTP <span class="mono">${L}:${pc.lan_http}</span><br>` +
    `LAN SOCKS <span class="mono">${L}:${pc.normal}</span><br>` +
    `<span class="hint">两个入口都是全部节点通用，服务器按节点自动决定要不要用浏览器。</span>`;
  $('hint-takeover').textContent = tkl
    ? '当前：接管本机（docker / apt / curl 走代理）。'
      + ((ST.takeover_local_files || []).length ? ' 配置在 ' + ST.takeover_local_files.join(' / ') : '')
    : '当前：不接管。局域网设备在 WiFi/系统设置里手动填上面任一入口即可（本机不做任何改动）。';

  $('xver').textContent = ST.xray_ver || '未知';

  // 端口设置表
  const PORT_ROWS = [
    ['normal',  'LAN SOCKS5（全部节点）',   pc.normal],
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
        ${useButtons(n)}
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
async function setMode(m){
  // 「停掉 Chromium」不能只是停进程：若当前节点设置为走浏览器，停掉会让它永久挂住
  // （dialTask 没有超时）。所以先把当前节点切成普通连接，再停浏览器 —— 一步到位。
  if (m === 'normal' && ST.node) {
    return post('node_use_as', {ident: ST.node.file, mode: 'normal'},
                '正在切到普通连接并关闭浏览器…');
  }
  if (m === 'browser_dialer' && ST.node && ST.can_use_dialer) {
    return post('node_use_as', {ident: ST.node.file, mode: 'bd'},
                '正在切到 BD 连接并启动浏览器…');
  }
  return post('mode', {mode:m},
    m==='browser_dialer' ? '正在启动 Chromium（约需 15 秒）…' : '正在停掉 Chromium…');
}
const useNode = (f, btn) => post('node_use', {ident:f}, '正在切换节点…', btn);
const rmNode = f => { if(confirm('确认删除该节点？')) post('node_remove', {ident:f}); };
async function setTakeover(mode, btn){
  const labels = {none:'正在切换为「不接管」…', local:'正在接管本机（会重启 docker）…'};
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
  const warn = {channel:'内部通道改动会重启 Xray 与 Chromium', panel:'面板端口改动后需用新地址访问'}[kind];
  if (warn && !confirm(warn + '，确认继续？')) return;
  const j = await post('port_set', {kind, value:v}, `正在修改 ${kind} 端口…`, btn);
  if (j.ok && el) el.value = '';
}

async function loadConn(btn){
  const j = await post('conninfo', {}, '正在生成连接配置…', btn);
  if (!j.ok) return;
  let d;
  try { d = JSON.parse(j.message); } catch (e) { return say('配置生成失败', 'err'); }
  $('conn-yaml').textContent = d.yaml;
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
  if(!v) return say('请粘贴节点链接、Xray JSON 或 Mihomo YAML','err');
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
