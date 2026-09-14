#!/usr/bin/env python3
"""运行状态收集：把"到底在用什么模式、哪些在跑"讲清楚。

架构：**唯一一个 Xray 实例**，同时提供 SOCKS 与 HTTP 两个 LAN 入站，并始终带
XRAY_BROWSER_DIALER —— 因此 "Browser Dialer" 不是模式，而是节点的一个属性：
当前节点是 xhttp/websocket 且非 REALITY 时，Xray 把 TLS 交给 Chromium，否则自己完成。

所以这里判定的是"这个实例健不健康"：
    1. Xray 在跑 + Chromium 在跑 -> mode = ready（两个端口全部可用，含 BD 节点）
    2. Xray 在跑 + Chromium 停了 -> mode = degraded（BD 节点会拨号失败，其他节点照常）
    3. Xray 没跑                 -> mode = stopped
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")

U_XRAY = "xray-client.service"
U_CHROMIUM = "chromium-browser-dialer.service"
U_PANEL = "browser-dialer-panel.service"
U_TIMER = "browser-dialer-health.timer"

MODE_READY = "ready"
MODE_DEGRADED = "degraded"
MODE_STOPPED = "stopped"

MODE_LABEL = {
    MODE_READY: "就绪",
    MODE_DEGRADED: "降级（Chromium 未运行，而当前节点需要它）",
    MODE_STOPPED: "已停止",
}


def sh(args, timeout=20):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def cfg_get(path, key, default=""):
    try:
        for line in open(path):
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return default


def unit_info(unit):
    rc, out, _ = sh(["systemctl", "is-active", unit])
    active = out == "active"
    rc2, enabled, _ = sh(["systemctl", "is-enabled", unit])
    rc3, since, _ = sh(["systemctl", "show", unit, "-p", "ActiveEnterTimestamp", "--value"])
    return {"unit": unit, "active": active, "state": out or "unknown",
            "enabled": enabled == "enabled", "since": since}


def port_listening(port):
    rc, out, _ = sh(["ss", "-H", "-tln"])
    if rc != 0:
        return False
    return any(line.split()[3].endswith(f":{port}") for line in out.splitlines() if len(line.split()) >= 4)


def ws_count(addr):
    rc, out, _ = sh(["ss", "-H", "-tn"])
    if rc != 0:
        return 0
    return sum(1 for line in out.splitlines() if addr in line)


def count_procs(name, exact=False):
    """pgrep -c 在部分实现下会输出多行，只取第一行。"""
    args = ["pgrep", "-c"] + (["-x"] if exact else []) + [name]
    rc, out, _ = sh(args)
    # pgrep -c 输出的是**计数本身**（单个整数），取第一行即正确。
    # 不要改成"数行数"：那会得到 1（实测验证过）。
    # 真正的坑在别处：不带 -x 时 pgrep 会把调用者自己也算进去。
    first = (out or "").strip().splitlines()
    try:
        return int(first[0]) if first else 0
    except (ValueError, IndexError):
        return 0


def chromium_procs():
    # exact=True 是必须的：不加 -x 时 pgrep 会连调用者所在的命令行一起匹配。
    return count_procs("chromium", exact=True)


def xray_procs():
    # 精确匹配：否则会匹配到 xbd 脚本自身的命令行（里面含 xray 字样）
    return count_procs("xray", exact=True)


def load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def nodes_dir():
    """节点列表。判定一律实时算，不读文件里的 _compat 缓存 ——
    缓存写于导入那一刻，Xray 升级或判定逻辑改动后它不会更新，于是两个内容完全
    相同的节点会一个显示"支持"一个显示"不支持"（实测踩过），而错的那个反而被当真。"""
    d = os.path.join(PREFIX, "nodes")
    files = []
    if not os.path.isdir(d):
        return files, ""
    compat_mod = None
    compat_py = os.path.join(PREFIX, "xbd-dist", "lib", "compat.py")
    if not os.path.exists(compat_py):
        compat_py = os.path.join(PREFIX, "lib", "compat.py")
    if os.path.exists(compat_py):
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location("_xbd_compat_list", compat_py)
            compat_mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(compat_mod)
        except Exception:
            compat_mod = None
    current = ""
    link = os.path.join(d, "current")
    if os.path.islink(link):
        current = os.path.basename(os.path.realpath(link))
    for name in sorted(os.listdir(d)):
        if name.startswith("node-") and name.endswith(".json"):
            data = load_json(os.path.join(d, name)) or {}
            caps = {}
            if compat_mod is not None:
                try:
                    caps = compat_mod.check_all(data)
                except Exception:
                    caps = {}
            files.append({
                "file": name,
                "name": data.get("name") or data.get("address") or name,
                "protocol": data.get("protocol", ""),
                "transport": data.get("transport", ""),
                "security": data.get("security", "none"),
                "address": data.get("address", ""),
                "port": data.get("port", 0),
                "ech": bool(data.get("ech")),
                "current": name == current,
                "compat": caps,
                # 这个节点是否用浏览器完成 TLS（None=默认，True/False=用户显式选择）
                "use_browser": data.get("use_browser", None),
                # 实测结果（tools/browserprobe.py 写的）。面板用它显示"实测可用/失败"，
                # 而不是只凭配置推断 —— 配置合法不等于能通（实测过同一套配置不同服务器结果相反）。
                "probe_ok": (data.get("browser_probe") or {}).get("ok"),
            })
    return files, current


def build_state(deep: bool = True) -> dict:
    ports = os.path.join(PREFIX, "config", "ports.env")
    p_normal = int(cfg_get(ports, "PORT_NORMAL", "1080"))
    p_http = int(cfg_get(ports, "PORT_HTTP", "10808"))
    p_lan_http = int(cfg_get(ports, "PORT_LAN_HTTP", "10809"))
    listen = cfg_get(ports, "LISTEN_ADDR", "127.0.0.1")
    dialer_addr = cfg_get(ports, "DIALER_ADDR", "127.0.0.1:18081")
    panel_env = os.path.join(PREFIX, "config", "panel.env")
    panel_host = cfg_get(panel_env, "PANEL_HOST", "127.0.0.1")
    panel_port = cfg_get(panel_env, "PANEL_PORT", "18090")

    ux = unit_info(U_XRAY)
    uc = unit_info(U_CHROMIUM)
    up = unit_info(U_PANEL)
    ut = unit_info(U_TIMER)

    # Chromium 没跑**不等于**降级 —— 要看当前节点是否真的需要它。
    # 曾经只要 Chromium 不在跑就报 degraded，于是用户主动把节点设成原生 TLS 后，
    # 界面一直显示"降级（Browser Dialer 节点不可用）"，而他其实一切正常。
    # 判据与 run-xray.sh / health-check.sh 共用同一套语义。
    _need = False
    try:
        _curn = load_json(os.path.join(PREFIX, "nodes", current)) or {}
        _proto = (_curn.get("protocol") or "").lower()
        _tr = (_curn.get("transport") or "").lower()
        _tr = {"ws": "websocket", "splithttp": "xhttp"}.get(_tr, _tr)
        _sec = (_curn.get("security") or "none").lower()
        _may = _proto == "vless" and _tr in ("websocket", "xhttp") and _sec != "reality"
        _need = _may and _curn.get("use_browser", None) is not False
    except Exception:
        _need = False

    if not ux["active"]:
        mode = MODE_STOPPED
    elif not uc["active"] and _need:
        mode = MODE_DEGRADED          # 真需要浏览器却没跑，才叫降级
    else:
        mode = MODE_READY

    nodes, current = nodes_dir()
    cur_node = next((n for n in nodes if n["current"]), None)

    ws = ws_count(dialer_addr)

    result = {
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "mode": mode,
        "mode_label": MODE_LABEL[mode],
        # 一句话说清当前到底在跑什么、当前节点走哪条路 —— 不写死"Xray + Chromium"，
        # 那会在 Chromium 本来就不需要跑（节点走原生 TLS）时误导。
        "mode_detail": (
            "Xray 未运行" if mode == MODE_STOPPED
            else ("Xray 在跑；当前节点需要浏览器，但 Chromium 未运行" if mode == MODE_DEGRADED
                  else ("Xray + Chromium 都在跑（当前节点走浏览器 TLS）" if uc["active"]
                        else "Xray 在跑；当前节点走 Xray 自带 TLS，Chromium 无需运行"))
        ),
        "services": {"xray": ux, "chromium": uc, "panel": up, "health_timer": ut},
        "ports": {
            "normal": p_normal, "http": p_http, "lan_http": p_lan_http, "listen": listen,
            "dialer_addr": dialer_addr,
            "normal_up": port_listening(p_normal),
            "http_up": port_listening(p_http),
            "lan_http_up": port_listening(p_lan_http),
        },
        "chromium_procs": chromium_procs(),
        "xray_procs": xray_procs(),
        "ws_connections": ws,
        "node": cur_node,
        "nodes": nodes,
        "project_installed": os.path.exists(os.path.join(PREFIX, "bin", "xray")),
    }

    # Browser Dialer 可用性：当前节点能不能用浏览器拨号
    if cur_node and deep:
        node_path = os.path.join(PREFIX, "nodes", cur_node["file"])
        node = load_json(node_path)
        if node:
            # 直接 import compat，省掉一次子进程与临时文件
            compat_py = os.path.join(PREFIX, "xbd-dist", "lib", "compat.py")
            if os.path.exists(compat_py):
                try:
                    import importlib.util
                    spec = importlib.util.spec_from_file_location("_xbd_compat", compat_py)
                    mod = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(mod)
                    result["compat"] = mod.check_all(node)
                except Exception:
                    pass

    # 当前节点的浏览器开关提到顶层 —— 面板的按钮要用它判断"当前该不该走浏览器"。
    # 只从列表里取会漏掉"节点文件有、但面板读的是旧缓存"这类情况，所以明确提上来。
    if cur_node:
        try:
            _cur = load_json(os.path.join(PREFIX, "nodes", cur_node["file"])) or {}
            result["use_browser"] = _cur.get("use_browser", None)
            result["probe_ok"] = (_cur.get("browser_probe") or {}).get("ok")
        except Exception:
            result["use_browser"] = None
            result["probe_ok"] = None

    can_dialer = bool(result.get("compat", {}).get("can_use_dialer"))
    result["can_use_dialer"] = can_dialer
    result["dialer_reason"] = ""
    if cur_node and not can_dialer:
        notes = result.get("compat", {}).get("dialer", {}).get("notes") or []
        result["dialer_reason"] = notes[0] if notes else "该节点不满足 Browser Dialer 条件"

    # 出口 IP 只在需要时探测，避免每次轮询都走一遍网络。
    # 只探测 SOCKS：HTTP 入站由同一个实例服务，出口必然一致。
    if deep and result["ports"]["normal_up"]:
        rc, out, _ = sh(["curl", "-s", "--max-time", "15", "--socks5-hostname",
                         f"{listen}:{p_normal}", "https://api.ipify.org"], timeout=25)
        result["exit_ip"] = out if rc == 0 else ""
        result["proxy_ok"] = rc == 0 and bool(out)
    else:
        result["exit_ip"] = ""
        result["proxy_ok"] = False

    return result


def cmd_status_text(state: dict) -> str:
    svc = state["services"]
    def dot(on):
        return "●" if on else "○"
    lines = []
    lines.append("=" * 44)
    lines.append(f'Xray Client:        {dot(svc["xray"]["active"])} {svc["xray"]["state"]}')
    lines.append(f'Connection Mode:    {state["mode_label"]}')
    if state.get("mode_detail"):
        lines.append(f'                    {state["mode_detail"]}')
    node = state.get("node")
    lines.append(f'Current Node:       {node["name"] if node else "（未选择）"}')
    lines.append(f'Chromium:           {dot(svc["chromium"]["active"])} {"Running" if svc["chromium"]["active"] else "Stopped"}'
                 + (f' ({state["chromium_procs"]} 进程)' if state["chromium_procs"] else ''))
    ports = state["ports"]
    lines.append(f'SOCKS5 入口:        {ports["listen"]}:{ports["normal"]}'
                 + ("  LISTENING" if ports["normal_up"] else "  未监听"))
    lines.append(f'HTTP  入口(LAN):    {ports["listen"]}:{ports["lan_http"]}'
                 + ("  LISTENING" if ports["lan_http_up"] else "  未监听"))
    lines.append(f'HTTP  入口(本机):   127.0.0.1:{ports["http"]}'
                 + ("  LISTENING" if ports["http_up"] else "  未监听"))
    lines.append(f'浏览器↔Dialer:      {state["ws_connections"]} 条连接')
    lines.append(f'出口 IP:            {state["exit_ip"] or "（未探测）"}')
    lines.append(f'Panel:              {dot(svc["panel"]["active"])} http://{cfg_get(os.path.join(PREFIX, "config", "panel.env"), "PANEL_HOST", "127.0.0.1")}:'
                 f'{cfg_get(os.path.join(PREFIX, "config", "panel.env"), "PANEL_PORT", "18090")}/')
    if node and not state.get("can_use_dialer"):
        lines.append(f'Browser Dialer 可用: 否（该节点走 Xray 自带 TLS）— {state.get("dialer_reason", "")}')
    elif node:
        lines.append(f'Browser Dialer 可用: 是（本节点走浏览器 TLS）')
    lines.append("=" * 44)
    return "\n".join(lines)


def main(argv) -> int:
    as_json = "--json" in argv
    quick = "--quick" in argv
    state = build_state(deep=not quick)
    if as_json:
        print(json.dumps(state, ensure_ascii=False, indent=2))
    else:
        print(cmd_status_text(state))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
