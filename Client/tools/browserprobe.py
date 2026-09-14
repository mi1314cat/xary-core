#!/usr/bin/env python3
"""浏览器路径实测探测：这个节点走 Browser Dialer 到底通不通。

为什么必须有它：能力判定只能验证"配置层面合法"（传输是 ws/xhttp、SNI==Host==Address、
版本够…），但**合法不等于能通**。实测到了两种判定无法覆盖的情况：

  * 同一套配置，8nm3ai 这台服务器浏览器路径可用，cswdcsdcw 却不行
    （浏览器侧 Dial WS 明明成功了，是服务端协议层不接受）—— 配置完全一样。
  * WebSocket 缺 early data 时，内嵌页面会因为 task.extra 为空直接抛 TypeError。

所以这里不看配置，**真的起一个临时 Xray + 临时 Chromium 跑一次请求**，用结果说话。
结果写进节点文件（browser_probe），能力判定读它 —— 判不出来就如实说"未验证"，
绝不假装支持。

用法:
    python3 browserprobe.py <node.json> [--timeout 45] [--json]
退出码: 0=通过 1=不通过 2=无法判定（缺少浏览器等）
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
LIB = os.path.join(PREFIX, "xbd-dist", "lib")
if not os.path.isdir(LIB):
    LIB = os.path.join(PREFIX, "lib")
XRAY = os.path.join(PREFIX, "bin", "xray")
GEN = os.path.join(LIB, "genconfig.py")

# 探测用端口：刻意用高位固定段，且互相错开，避免与生产/其它探测互撞
S_PORT = 11120          # 临时 SOCKS 入口（回环）
T_PORT = 18120          # 临时 Xray↔Chromium 通道（回环）
API_PORT = 18125


def sh(cmd, timeout=30, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def port_open(port, host="127.0.0.1"):
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def find_browser():
    for c in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable"):
        p = shutil.which(c)
        if p:
            return p
    return None


LOCK_PATH = "/tmp/.xbd-browserprobe.lock"


def _acquire_lock():
    """探测要占固定端口，必须串行 —— 并发跑会互相抢端口、互相干扰结果。"""
    import fcntl
    fh = open(LOCK_PATH, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        return None
    return fh


_LOCK_FH = None


def probe(node_path: str, timeout: int = 45, browser: str | None = None) -> dict:
    """薄壳：持有文件锁跑一次实测，保证锁一定释放、且不混进返回值。"""
    global _LOCK_FH
    _LOCK_FH = _acquire_lock()
    if _LOCK_FH is None:
        return {"ok": False, "stage": "env",
                "reason": "另一个探测正在进行（避免抢端口），请稍后重试"}
    try:
        res = _probe_impl(node_path, timeout=timeout, browser=browser)
    finally:
        try:
            _LOCK_FH.close()
        except Exception:
            pass
        _LOCK_FH = None
    return res


def _probe_impl(node_path: str, timeout: int = 45, browser: str | None = None) -> dict:
    """跑一次真实请求，返回 {'ok':bool, 'reason':str, ...}"""
    out = {"ok": False, "reason": "", "stage": ""}
    if not os.path.exists(XRAY):
        out.update(reason=f"缺少 Xray 二进制: {XRAY}", stage="env")
        return out
    browser = browser or find_browser()
    if not browser:
        out.update(reason="未安装 Chromium/Chrome", stage="env")
        return out

    # 端口被占（可能是并发探测）就直接放弃，不要撞生产
    for p in (S_PORT, T_PORT):
        if port_open(p):
            out.update(reason=f"探测端口 {p} 被占用，跳过以免干扰", stage="env")
            return out

    # 先做协议层面预判。**必须做**，否则会把"代理恰好能通"误判成"浏览器路径可用"：
    # hysteria2 有它自己的 dialer，根本不检查 HasBrowserDialer，所以在 BD 模式下
    # 它照样走原生 QUIC —— 代理能出网，但浏览器完全不在路径上（实测踩过这个假阳性）。
    try:
        _n = json.load(open(node_path, encoding="utf-8"))
    except Exception:
        _n = {}
    _proto = (_n.get("protocol") or "").lower()
    _tr = (_n.get("transport") or "").lower()
    _sec = (_n.get("security") or "none").lower()
    _alias = {"ws": "websocket", "splithttp": "xhttp"}
    _tr = _alias.get(_tr, _tr)
    if _proto != "vless" or _tr not in ("websocket", "xhttp") or _sec == "reality":
        out.update(reason=f"该节点不走浏览器转发（{_proto}/{_tr}/{_sec}）："
                          "浏览器转发只作用于 vless 的 ws/xhttp 出站，且不支持 REALITY",
                   stage="protocol", not_applicable=True)
        return out

    work = tempfile.mkdtemp(prefix="xbd-bprobe-")
    cfg = os.path.join(work, "c.json")
    try:
        rc, so, se = sh([sys.executable, GEN, "--node", node_path, "--output", cfg,
                         "--mode", "normal", "--listen", "127.0.0.1",
                         "--port-normal", str(S_PORT), "--api-port", str(API_PORT),
                         "--logs", work], timeout=60)
        if rc != 0 or not os.path.exists(cfg):
            out.update(reason=f"配置生成失败: {(so or se)[:200]}", stage="genconfig",
                       needs_browser="不支持" if "不支持" in (so + se) else "")
            # 配置生成失败通常意味着该节点不支持浏览器路径（例如传输不是 ws/xhttp）
            return out

        env = dict(os.environ, XRAY_BROWSER_DIALER=f"127.0.0.1:{T_PORT}")
        xp = subprocess.Popen([XRAY, "run", "-config", cfg], env=env,
                              stdout=subprocess.DEVNULL, stderr=open(os.path.join(work, "xray.log"), "w"))
        try:
            for _ in range(20):
                if port_open(T_PORT) and port_open(S_PORT):
                    break
                time.sleep(0.5)
            if not (port_open(T_PORT) and port_open(S_PORT)):
                out.update(reason="临时 Xray 未能就绪", stage="xray")
                return out

            prof = os.path.join(work, "prof")
            os.makedirs(prof, exist_ok=True)
            cp = subprocess.Popen(
                [browser, "--headless=new", "--no-sandbox", "--disable-gpu",
                 "--disable-dev-shm-usage", "--no-first-run", "--disable-dbus",
                 f"--user-data-dir={prof}", f"http://127.0.0.1:{T_PORT}/"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                # 等浏览器把 WS 接上
                ws = False
                for _ in range(30):
                    rc2, so2, _ = sh(["bash", "-c",
                                      f"ss -tnH 2>/dev/null | grep -c ':{T_PORT}' || true"])
                    try:
                        ws = int((so2 or "0").strip() or 0) > 0
                    except ValueError:
                        ws = False
                    if ws:
                        break
                    time.sleep(1)
                out["browser_ws"] = ws
                if not ws:
                    out.update(reason="浏览器没有接上 dialer（页面可能加载失败）", stage="browser")
                    return out

                # 真的发一次请求（多试几次，绕过首连时序）
                deadline = time.time() + timeout
                last = ""
                while time.time() < deadline:
                    rc3, ip, _ = sh(["curl", "-s", "--max-time", "15",
                                     "--socks5-hostname", f"127.0.0.1:{S_PORT}",
                                     "https://api.ipify.org"], timeout=25)
                    ip = (ip or "").strip()
                    if rc3 == 0 and ip and ip.count(".") == 3:
                        # 出网成功还不够：必须确认浏览器真的在路径上。
                        # 两条独立判据，缺一不可：
                        #   1) 浏览器与 dialer 的 WS 连接在请求期间仍然存在；
                        #   2) Xray 自己没有直连节点（即 TLS 不是 Xray 发的）。
                        ws_now = sh(["bash", "-c",
                                     f"ss -tnH 2>/dev/null | grep -c ':{T_PORT}' || true"])[1]
                        try:
                            ws_alive = int((ws_now or "0").strip() or 0) > 0
                        except ValueError:
                            ws_alive = False
                        xlog = os.path.join(work, "xray.log")
                        try:
                            ltxt = open(xlog, errors="replace").read()
                        except OSError:
                            ltxt = ""
                        # Xray 自己拨号会留下 "is dialing to ..."；浏览器拨号不会
                        self_dial = ("is dialing to" in ltxt)
                        out["ws_alive_during_request"] = ws_alive
                        out["xray_self_dial"] = self_dial
                        if not ws_alive:
                            out.update(reason="请求通了但浏览器已不在路径上（WS 断开），"
                                              "无法确认是浏览器拨号", stage="verify")
                            return out
                        if self_dial:
                            out.update(reason="Xray 自己直连了节点（日志出现 dialing），"
                                              "说明浏览器没有参与", stage="verify")
                            return out
                        out.update(ok=True, exit_ip=ip, stage="done",
                                   reason="浏览器路径实测可用（已确认浏览器在路径上）")
                        return out
                    last = f"curl rc={rc3} out={ip[:40]!r}"
                    time.sleep(2)
                out.update(reason=f"请求未成功（{last}）", stage="request")
                return out
            finally:
                cp.terminate()
                time.sleep(2)
                for p in sh(["bash", "-c", f"pgrep -f 'user-data-dir={prof}' || true"])[1].split():
                    sh(["kill", "-9", p])
        finally:
            xp.terminate()
            try:
                xp.wait(timeout=5)
            except subprocess.TimeoutExpired:
                xp.kill()
    finally:
        if os.environ.get("XBD_KEEP_PROBE"):
            out["work_dir"] = work
        else:
            shutil.rmtree(work, ignore_errors=True)
    return out


def save_result(node_path: str, res: dict) -> None:
    """把探测结果写进节点文件，供能力判定读取。

    "不适用"（协议层面就不走浏览器）**不写** —— 写了会让 hysteria2 这类节点
    显示成"实测失败"，而它其实只是不适用，会造成误导。
    """
    try:
        d = json.load(open(node_path, encoding="utf-8"))
    except (OSError, ValueError):
        return
    if res.get("not_applicable"):
        d.pop("browser_probe", None)
        try:
            json.dump(d, open(node_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        except OSError:
            pass
        return
    d["browser_probe"] = {
        "ok": bool(res.get("ok")),
        "reason": res.get("reason", "")[:200],
        "stage": res.get("stage", ""),
        "at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "xray": os.path.basename(XRAY),
    }
    if res.get("ok"):
        d["browser_probe"]["exit_ip"] = res.get("exit_ip", "")
    try:
        json.dump(d, open(node_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    except OSError:
        pass


def main(argv) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    as_json = "--json" in argv
    timeout = 45
    for a in argv[1:]:
        if a.startswith("--timeout="):
            timeout = int(a.split("=", 1)[1])
    if not args:
        print("用法: browserprobe.py <node.json> [--timeout=45] [--json]", file=sys.stderr)
        return 2
    node_path = args[0]
    res = probe(node_path, timeout=timeout)
    if "--save" in argv:
        save_result(node_path, res)
    if as_json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
    else:
        mark = "✓ 可用" if res.get("ok") else "✗ 不可用"
        print(f"浏览器路径: {mark}")
        if res.get("reason"):
            print(f"  原因: {res['reason']}")
        if res.get("exit_ip"):
            print(f"  出口: {res['exit_ip']}")
    if res.get("ok"):
        return 0
    # env/protocol：不是"不可用"，而是"不适用/判不了"
    return 2 if res.get("stage") in ("env", "protocol") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
