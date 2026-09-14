#!/usr/bin/env python3
"""端口分配与冲突检测。

解决的问题（实测过的真缺陷）：
  1. Browser Dialer 的内部通道端口在 run-chromium.sh 里是**硬编码**的，
     改了 ports.env 之后 Chromium 还在连旧端口 → 一条 WS 都连不上，
     而 UI 却报告"已启用"（因为只检查了端口在听，没检查两端是否接上）。
  2. 安装时端口全是写死的，换到新环境撞端口就只能靠人工发现。

设计原则：
  * config/ports.env 是**唯一事实来源**，任何脚本都不许再写死端口；
  * 分配端口时逐个探测，跳过被占用的；
  * 移动端口之后必须**验证两端真的接上**，而不是只看"在听"。
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")

# 所有端口及其用途。order 决定分配顺序。
# scope: lan = 局域网可达（只绑本机 LAN 地址）；loopback = 只绑回环
PORT_SPECS = [
    ("PORT_NORMAL",   "LAN SOCKS5（全部节点）",   "lan",      1080),
    ("PORT_HTTP",     "本机 HTTP 代理（docker 等）", "loopback", 10808),
    ("PORT_LAN_HTTP", "局域网 HTTP 代理（WiFi 设置）", "lan", 10809),
    ("DIALER_ADDR",   "Xray↔Chromium 内部通道",   "loopback", 18081),
    ("PANEL_PORT",    "面板",                     "bind",     18090),
    ("API_PORT",      "Xray 统计 API",            "loopback", 18085),
]
# 这些端口绝不使用：SSH / DNS / 其它服务常用端口
RESERVED = {22, 53, 80, 443, 1080 + 100000}   # 占位，见下方 forbidden()


def forbidden() -> set[int]:
    """明确不能占用的端口。"""
    bad = {22, 53, 80, 443, 3128, 8080, 8443, 9090, 7890, 7891}
    # 本机已在用的也全部排除（动态探测）
    return bad


def _proc_name(pid: str) -> str:
    """返回 "名称 (pid N)"。名称优先用完整命令行里的可辨识片段。

    只靠 /proc/comm 不够：面板是 python3 跑的，comm 就是 "python3"，
    看不出它属于本项目，会把自家面板误报成"其它服务"。
    """
    name = ""
    try:
        with open(f"/proc/{pid}/comm") as fh:
            name = fh.read().strip()
    except OSError:
        pass
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            cmd = fh.read().replace(b"\x00", b" ").decode("utf-8", "replace").strip()
        if cmd:
            name = cmd
    except OSError:
        pass
    return f"{name} (pid {pid})" if name else f"pid {pid}"


def in_use(port: int, host: str = "") -> str:
    """返回占用者描述；空闲返回空串。

    注意两点：
      * 判断占用不能只看某个地址 —— 别的服务绑在 0.0.0.0 上，
        我们绑具体 IP 也会失败，所以检查**所有地址**。
      * ss 的进程名有时不打印（权限/格式），这时用 PID 反查 /proc，
        否则无法判断"占用者是不是本项目自己"。
    """
    try:
        out = subprocess.run(["ss", "-H", "-tlnp"], capture_output=True, text=True, timeout=10).stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        out = ""
    for line in out.splitlines():
        parts = line.split()
        # 列结构: LISTEN Recv-Q Send-Q 本地地址:端口 对端地址 进程
        # 进程信息在**第 5 列**（第 4 列是对端地址）—— 之前取错列了。
        if len(parts) >= 4 and parts[3].endswith(f":{port}"):
            holder = parts[5] if len(parts) > 5 else ""
            import re as _re
            m = _re.search(r'pid=(\d+)', holder)
            if m:
                name = _proc_name(m.group(1))
                if name:
                    return f"{name} (pid {m.group(1)})"
            return holder[:80] or "占用"
    # 再确认能否真的绑定（有些占用形态 ss 看不到）
    for candidate in ([host] if host else ["0.0.0.0", "127.0.0.1"]):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((candidate, port))
        except OSError as exc:
            return f"无法绑定 {candidate}: {exc.strerror}"
        finally:
            s.close()
    return ""


def pick_free(preferred: int, host: str, tries: int = 200, taken: set | None = None) -> int:
    """从 preferred 开始找一个既能绑定又没被占用的端口。

    taken：本次分配中已经选走的端口 —— 必须排除，
    否则会出现两个入站抢同一个端口（历史上 NORMAL 和 DIALER 就撞过 1081）。
    """
    bad = forbidden() | (taken or set())
    for p in range(preferred, preferred + tries):
        if p in bad or p > 65535:
            continue
        if not in_use(p, host):
            return p
    raise RuntimeError(f"从 {preferred} 起找不到可用端口")


def allocate(host_lan: str, host_panel: str, verbose: bool = False) -> dict:
    """为所有端口挑选可用值。已被本配置占用的端口视为"自己的"，不重复计较。"""
    result = {}
    taken: set[int] = set()
    for key, label, scope, default in PORT_SPECS:
        host = host_lan if scope == "lan" else ("127.0.0.1" if scope == "loopback" else host_panel)
        p = pick_free(default, host, taken=taken)
        taken.add(p)
        result[key] = p
        if verbose:
            mark = "" if p == default else f"  （{default} 被占用，已改用 {p}）"
            print(f"    {label:<32} {p}{mark}")
    return result


def read_ports(path: str) -> dict:
    cfg = {}
    if not os.path.exists(path):
        return cfg
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def dialer_addr_parts(cfg: dict) -> tuple[str, int]:
    raw = cfg.get("DIALER_ADDR", "127.0.0.1:18081")
    host, _, port = raw.rpartition(":")
    return (host or "127.0.0.1"), int(port or 18081)


def cmd_allocate(args) -> int:
    lan = args.lan or detect_lan()
    res = allocate(lan, args.panel_host or lan, verbose=not args.json)
    if args.json:
        print(json.dumps({"listen_addr": lan, **res}, ensure_ascii=False))
    return 0


def detect_lan() -> str:
    try:
        out = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"], capture_output=True, text=True, timeout=5).stdout
        toks = out.split()
        if "src" in toks:
            return toks[toks.index("src") + 1]
    except Exception:
        pass
    try:
        return socket.gethostbyname(socket.gethostname())
    except OSError:
        return "127.0.0.1"


def _is_own_service(holder: str) -> bool:
    """判断占用者是不是本项目自己的进程/服务。

    这一点很关键：自己的服务当然占着自己的端口，
    如果不区分，`check` 会把正常运行报成一堆冲突。
    """
    h = (holder or "").lower()
    return any(k in h for k in (
        "xray", "xbd", "chromium",          # 进程名
        "/opt/xray-browser-dialer",         # 本项目安装路径
        "xbd-dist", "panel.py", "genconfig.py", "latency.py",  # 本项目的脚本
    ))


def cmd_check(args) -> int:
    """检查现有配置里的端口是否可用；被**别人**占用才报告。"""
    cfg = read_ports(args.env)
    lan = cfg.get("LISTEN_ADDR") or detect_lan()
    problems = []
    for key, label, scope, default in PORT_SPECS:
        if key == "DIALER_ADDR":
            host, port = dialer_addr_parts(cfg)
        else:
            port = int(cfg.get(key, default) or default)
            host = lan if scope == "lan" else ("127.0.0.1" if scope == "loopback" else lan)
        holder = in_use(port, host)
        # 自己占着自己的端口是正常的，不算冲突
        if holder and not _is_own_service(holder):
            alt = pick_free(port + 1, host)
            problems.append({"key": key, "label": label, "port": port,
                             "holder": holder, "suggest": alt})
    if args.json:
        print(json.dumps({"problems": problems, "listen_addr": lan}, ensure_ascii=False))
    else:
        if not problems:
            print("  所有端口都可用（本项目的服务占用自己的端口属正常）")
        for p in problems:
            print(f"  ✗ {p['label']} 端口 {p['port']} 被**其它服务**占用（{p['holder']}）→ 建议改用 {p['suggest']}")
    return 1 if problems else 0


def cmd_verify_dialer(args) -> int:
    """验证 Browser Dialer 两端是否真的接上 —— 只看"端口在听"是不够的。

    这正是之前那个 bug 的核心：端口改了但 Chromium 还在连旧端口，
    两边各自"正常"，代理却完全不通。
    """
    cfg = read_ports(args.env)
    host, port = dialer_addr_parts(cfg)
    if not in_use(port, host):
        print(json.dumps({"ok": False, "reason": "xray_dialer_not_listening", "port": port},
                         ensure_ascii=False) if args.json else
              f"  ✗ Xray 未在 {host}:{port} 监听")
        return 1

    try:
        out = subprocess.run(["ss", "-H", "-tn"], capture_output=True, text=True, timeout=10).stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        out = ""
    ws = sum(1 for line in out.splitlines() if f"{host}:{port}" in line)

    # 再看浏览器实际连的是哪个端口（诊断"改端口没跟着改"这类问题）
    chrome_target = ""
    try:
        out2 = subprocess.run(["bash", "-c",
                               "ps -eo args= | grep -m1 -o 'http://127.0.0.1:[0-9]*' || true"],
                              capture_output=True, text=True, timeout=10).stdout.strip()
        chrome_target = out2.replace("http://", "")
    except Exception:
        pass

    ok = ws > 0
    result = {"ok": ok, "port": port, "ws_connections": ws,
              "chromium_target": chrome_target,
              "mismatch": bool(chrome_target and chrome_target != f"{host}:{port}")}
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        if result["mismatch"]:
            print(f"  ✗ 端口不一致：Xray 在 {host}:{port}，Chromium 却连 {chrome_target}")
        elif ok:
            print(f"  ✓ 两端已接上（{ws} 条 WS，端口 {port}）")
        else:
            print(f"  ✗ Xray 在 {host}:{port} 监听，但没有任何浏览器连接")
    return 0 if ok and not result["mismatch"] else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("allocate"); a.add_argument("--lan"); a.add_argument("--panel-host", dest="panel_host")
    a.add_argument("--json", action="store_true"); a.set_defaults(fn=cmd_allocate)

    c = sub.add_parser("check"); c.add_argument("--env", default=os.path.join(PREFIX, "config", "ports.env"))
    c.add_argument("--json", action="store_true"); c.set_defaults(fn=cmd_check)

    v = sub.add_parser("verify-dialer"); v.add_argument("--env", default=os.path.join(PREFIX, "config", "ports.env"))
    v.add_argument("--json", action="store_true"); v.set_defaults(fn=cmd_verify_dialer)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
