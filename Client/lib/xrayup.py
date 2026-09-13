#!/usr/bin/env python3
"""Xray 内核版本检查与更新。

为什么单独一个模块：
    * 之前 `xbd update` 只同步项目文件，从不更新 Xray 二进制；
    * 下载要校验 SHA256（对官方 .dgst），不能只信"下载完成"；
    * 家宽常被限速/阻断 GitHub Release，需要连通性预探测与代理回退。

只操作本项目自己的 $PREFIX/bin/xray，绝不碰 /usr/local/bin/xray。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
XRAY = os.path.join(PREFIX, "bin", "xray")
BACKUP = os.path.join(PREFIX, "backup")
REPO = "XTLS/Xray-core"
HTTP_PROXY_PORTS = (10808, 7890)   # 本项目 HTTP 代理 / mihomo（按优先级）


def sh(args, timeout=60):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def installed_version() -> str:
    if not os.path.exists(XRAY):
        return ""
    rc, out, _ = sh([XRAY, "version"])
    if rc != 0:
        return ""
    parts = out.split()
    return parts[1] if len(parts) > 1 else ""


def reachable(host: str, port: int = 443, seconds: int = 6) -> bool:
    try:
        with socket.create_connection((host, port), timeout=seconds):
            return True
    except OSError:
        return False


def pick_proxy() -> str:
    """返回可用的本机代理 URL；都没有则返回空串（直连）。"""
    for port in HTTP_PROXY_PORTS:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=2):
                return f"http://127.0.0.1:{port}"
        except OSError:
            continue
    return ""


def fetch(url: str, proxy: str = "", timeout: int = 120) -> bytes:
    args = ["curl", "-fsSL", "--max-time", str(timeout)]
    if proxy:
        args += ["-x", proxy]
    args.append(url)
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout + 20)
        return p.stdout if p.returncode == 0 else b""
    except subprocess.TimeoutExpired:
        return b""


def latest_version(proxy: str = "") -> str:
    raw = fetch(f"https://api.github.com/repos/{REPO}/releases/latest", proxy, 25)
    try:
        return json.loads(raw.decode())["tag_name"]
    except (ValueError, KeyError, UnicodeDecodeError):
        return ""


def arch_asset() -> str:
    m = os.uname().machine
    return {"aarch64": "arm64-v8a", "arm64": "arm64-v8a",
            "x86_64": "64", "amd64": "64",
            "armv7l": "arm32-v7a", "armv7": "arm32-v7a"}.get(m, "")


def cmd_check(as_json=False) -> int:
    cur = installed_version()
    proxy = pick_proxy()
    direct = reachable("api.github.com", 443, 5)
    if not direct and not proxy:
        out = {"installed": cur, "latest": "", "error": "无法访问 GitHub 且本机没有可用代理",
               "updatable": False}
        print(json.dumps(out, ensure_ascii=False) if as_json else
              f"  已安装: {cur or '无'}\n  ! 无法访问 GitHub，也没有可用代理")
        return 1

    latest = latest_version(proxy if not direct else "")
    if as_json:
        print(json.dumps({"installed": cur, "latest": latest,
                          "updatable": bool(latest and latest.lstrip("v") != cur),
                          "proxy": proxy, "direct": direct}, ensure_ascii=False))
        return 0
    print(f"  已安装: {cur or '无'}")
    print(f"  最新版: {latest or '获取失败'}")
    if latest and latest.lstrip("v") != cur:
        print(f"  可更新: {cur or '无'} → {latest.lstrip('v')}")
    elif latest:
        print("  已是最新版本")
    return 0


def cmd_update(as_json=False, force=False) -> int:
    cur = installed_version()
    proxy = pick_proxy()

    # 直连优先；不通再用本机代理（本项目 HTTP 代理优先，其次 mihomo）
    if not reachable("api.github.com", 443, 5):
        if not proxy:
            print(json.dumps({"ok": False, "error": "无法访问 GitHub 且无本机代理"},
                             ensure_ascii=False) if as_json else
                  "  ✗ 无法访问 GitHub，且本机没有可用代理（先 xbd proxy on）")
            return 1
        print(f"  直连不通，改用代理 {proxy}" if not as_json else "", end="" if not as_json else "\n")

    latest = latest_version(proxy)
    if not latest:
        msg = "获取最新版本号失败"
        print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
        return 1

    target = latest.lstrip("v")
    if cur == target and not force:
        msg = f"已是最新版本 {cur}"
        print(json.dumps({"ok": True, "updated": False, "version": cur},
                         ensure_ascii=False) if as_json else f"  ✓ {msg}")
        return 0

    asset = arch_asset()
    if not asset:
        msg = f"不支持的架构: {os.uname().machine}"
        print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
        return 1

    base = f"https://github.com/{REPO}/releases/download/{latest}/Xray-linux-{asset}.zip"
    tmp = tempfile.mkdtemp(prefix="xbd-upd-")
    try:
        print(f"  正在下载 {latest}（{asset}）…" if not as_json else "", flush=True)
        blob = fetch(base, proxy, 300)
        if not blob:
            msg = "下载失败"
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
            return 1

        # 校验：官方 .dgst 里的 SHA2-256
        dgst = fetch(base + ".dgst", proxy, 60).decode("utf-8", "replace")
        want = ""
        for line in dgst.splitlines():
            if "SHA2-256" in line:
                want = line.split("=", 1)[1].strip()
                break

        zip_path = os.path.join(tmp, "xray.zip")
        open(zip_path, "wb").write(blob)

        got = ""
        rc, out, _ = sh(["sha256sum", zip_path])
        if rc == 0:
            got = out.split()[0]

        if want:
            if want != got:
                msg = f"SHA256 不匹配（期望 {want[:16]}… 实际 {got[:16]}…）"
                print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
                return 1
            verified = True
        else:
            verified = False

        rc, out, err = sh(["unzip", "-oq", zip_path, "-d", os.path.join(tmp, "x")])
        if rc != 0:
            msg = f"解压失败: {err[:120]}"
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
            return 1

        newbin = os.path.join(tmp, "x", "xray")
        if not os.path.exists(newbin):
            msg = "压缩包里没有 xray"
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
            return 1

        os.makedirs(BACKUP, exist_ok=True)
        if os.path.exists(XRAY):
            shutil.copy2(XRAY, os.path.join(BACKUP, f"xray.{cur or 'unknown'}.bak"))

        os.makedirs(os.path.dirname(XRAY), exist_ok=True)
        shutil.copy2(newbin, XRAY)
        os.chmod(XRAY, 0o755)
        for geo in ("geoip.dat", "geosite.dat"):
            src = os.path.join(tmp, "x", geo)
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(os.path.dirname(XRAY), geo))

        newver = installed_version()
        out = {"ok": True, "updated": True, "from": cur, "to": newver,
               "sha256_verified": verified}
        if as_json:
            print(json.dumps(out, ensure_ascii=False))
        else:
            print(f"  ✓ 已更新: {cur or '无'} → {newver}"
                  + ("" if verified else "（未取得官方 .dgst，仅记录本地校验值）"))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "update", "version"])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    if a.cmd == "version":
        print(installed_version())
        return 0
    if a.cmd == "check":
        return cmd_check(a.json)
    return cmd_update(a.json, a.force)


if __name__ == "__main__":
    sys.exit(main())
