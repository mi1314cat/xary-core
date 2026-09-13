#!/usr/bin/env python3
"""运行状态收集：把"到底在用什么模式、哪些在跑"讲清楚。

需求第十五条要求状态栏明确显示真正使用的模式，而不是一个模糊的 Running。
这里的判定顺序是：
    1. dialer 实例在跑        -> mode = browser_dialer
    2. 只有常驻实例在跑       -> mode = normal
    3. 都没跑                 -> mode = stopped
如果两个都在跑（切换瞬间/人为启动），如实报告 mixed，不假装正常。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")

U_XRAY = "xray-client.service"
U_DIALER = "xray-dialer.service"
U_CHROMIUM = "chromium-browser-dialer.service"
U_PANEL = "browser-dialer-panel.service"
U_TIMER = "browser-dialer-health.timer"

MODE_NORMAL = "normal"
MODE_DIALER = "browser_dialer"
MODE_STOPPED = "stopped"
MODE_MIXED = "mixed"

MODE_LABEL = {
    MODE_NORMAL: "普通 Xray",
    MODE_DIALER: "Browser Dialer",
    MODE_STOPPED: "已停止",
    MODE_MIXED: "混合（两个实例都在运行）",
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
    first = (out or "").strip().splitlines()
    try:
        return int(first[0]) if first else 0
    except (ValueError, IndexError):
        return 0


def chromium_procs():
    return count_procs("chromium")


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
    d = os.path.join(PREFIX, "nodes")
    files = []
    if not os.path.isdir(d):
        return files, ""
    current = ""
    link = os.path.join(d, "current")
    if os.path.islink(link):
        current = os.path.basename(os.path.realpath(link))
    for name in sorted(os.listdir(d)):
        if name.startswith("node-") and name.endswith(".json"):
            data = load_json(os.path.join(d, name)) or {}
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
                "compat": data.get("_compat") or {},
            })
    return files, current


def build_state(deep: bool = True) -> dict:
    ports = os.path.join(PREFIX, "config", "ports.env")
    p_normal = int(cfg_get(ports, "PORT_NORMAL", "1080"))
    p_dialer = int(cfg_get(ports, "PORT_DIALER", "1081"))
    listen = cfg_get(ports, "LISTEN_ADDR", "127.0.0.1")
    dialer_addr = cfg_get(ports, "DIALER_ADDR", "127.0.0.1:18081")
    panel_env = os.path.join(PREFIX, "config", "panel.env")
    panel_host = cfg_get(panel_env, "PANEL_HOST", "127.0.0.1")
    panel_port = cfg_get(panel_env, "PANEL_PORT", "18090")

    ux = unit_info(U_XRAY)
    ud = unit_info(U_DIALER)
    uc = unit_info(U_CHROMIUM)
    up = unit_info(U_PANEL)
    ut = unit_info(U_TIMER)

    if ud["active"] and ux["active"]:
        mode = MODE_MIXED
    elif ud["active"]:
        mode = MODE_DIALER
    elif ux["active"]:
        mode = MODE_NORMAL
    else:
        mode = MODE_STOPPED

    nodes, current = nodes_dir()
    cur_node = next((n for n in nodes if n["current"]), None)

    normal_up = port_listening(p_normal)
    dialer_up = port_listening(p_dialer)
    ws = ws_count(dialer_addr)

    result = {
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "mode": mode,
        "mode_label": MODE_LABEL[mode],
        "services": {
            "xray": ux, "dialer": ud, "chromium": uc, "panel": up, "health_timer": ut,
        },
        "ports": {
            "normal": p_normal, "dialer": p_dialer, "listen": listen,
            "dialer_addr": dialer_addr,
            "normal_up": normal_up, "dialer_up": dialer_up,
        },
        "chromium_procs": chromium_procs(),
        "xray_procs": xray_procs(),
        "ws_connections": ws,
        "node": cur_node,
        "nodes": nodes,
        "project_installed": os.path.exists(os.path.join(PREFIX, "bin", "xray")),
    }

    # Browser Dialer 可用性：当前节点能不能用 dialer 模式
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

    can_dialer = bool(result.get("compat", {}).get("can_use_dialer"))
    result["can_use_dialer"] = can_dialer
    result["dialer_reason"] = ""
    if cur_node and not can_dialer:
        notes = result.get("compat", {}).get("dialer", {}).get("notes") or []
        result["dialer_reason"] = notes[0] if notes else "该节点不满足 Browser Dialer 条件"

    # 出口 IP 只在需要时探测，避免每次轮询都走一遍网络
    if deep and normal_up and mode in (MODE_NORMAL, MODE_MIXED, MODE_DIALER):
        which = p_dialer if mode == MODE_DIALER else p_normal
        rc, out, _ = sh(["curl", "-s", "--max-time", "15", "--socks5-hostname",
                         f"{listen}:{which}", "https://api.ipify.org"], timeout=25)
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
    node = state.get("node")
    lines.append(f'Current Node:       {node["name"] if node else "（未选择）"}')
    lines.append(f'Browser Dialer:     {dot(svc["dialer"]["active"])} {"Running" if svc["dialer"]["active"] else "Stopped"}')
    lines.append(f'Chromium:           {dot(svc["chromium"]["active"])} {"Running" if svc["chromium"]["active"] else "Stopped"}'
                 + (f' ({state["chromium_procs"]} 进程)' if state["chromium_procs"] else ''))
    lines.append(f'普通代理入口:       {state["ports"]["listen"]}:{state["ports"]["normal"]}'
                 + ("  LISTENING" if state["ports"]["normal_up"] else "  未监听"))
    lines.append(f'Dialer 入口:        {state["ports"]["listen"]}:{state["ports"]["dialer"]}'
                 + ("  LISTENING" if state["ports"]["dialer_up"] else "  未监听"))
    lines.append(f'浏览器↔Dialer:      {state["ws_connections"]} 条连接')
    lines.append(f'出口 IP:            {state["exit_ip"] or "（未探测）"}')
    lines.append(f'Panel:              {dot(svc["panel"]["active"])} http://{cfg_get(os.path.join(PREFIX, "config", "panel.env"), "PANEL_HOST", "127.0.0.1")}:'
                 f'{cfg_get(os.path.join(PREFIX, "config", "panel.env"), "PANEL_PORT", "18090")}/')
    if node and not state.get("can_use_dialer"):
        lines.append(f'Browser Dialer 可用: 否 — {state.get("dialer_reason", "")}')
    elif node:
        lines.append(f'Browser Dialer 可用: 是')
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
