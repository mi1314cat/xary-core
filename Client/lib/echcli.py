#!/usr/bin/env python3
"""ECH 验证：确认 Chromium 原生 ECH 是否真的作用在到节点的 TLS 上。

判定证据全部来自 Chromium 自己的 netlog，而不是"看到 TLS 1.3 就算"：
    ech_config_list 非空             -> Chromium 拿到了 ECHConfig
    encrypted_client_hello == true   -> 该次握手实际发出了 ECH
    该事件邻近的 host == 节点域名     -> ECH 确实用在到节点的连接上

关键前提（实测得出）：
    * 现代 Chromium 已移除 --dns-over-https-mode / --dns-over-https-templates，
      Secure DNS 只能通过 profile 的 Local State 配置；
    * 系统解析器不返回 HTTPS/SVCB 记录时，Chromium 拿不到 ECHConfig，ECH 不会发生。
"""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
DIST = os.path.join(PREFIX, "xbd-dist")
XRAY = os.path.join(PREFIX, "bin", "xray")
T_PORT = 18083
S_PORT = 11091
DEFAULT_DOH = "https://dns.alidns.com/dns-query"
DEFAULT_DOMAIN = "cloudflare-ech.com"


# ------------------------------------------------------------------ DNS ----
def build_query(name, qtype=65):
    hdr = b"\x12\x34" + b"\x01\x00" + b"\x00\x01" + b"\x00\x00" + b"\x00\x00" + b"\x00\x00"
    q = b"".join(bytes([len(x)]) + x.encode() for x in name.split(".")) + b"\x00"
    return hdr + q + struct.pack(">HH", qtype, 1)


def skip_name(buf, off):
    while True:
        ln = buf[off]
        if ln == 0:
            return off + 1
        if ln & 0xC0:
            return off + 2
        off += 1 + ln


def parse_https_ech(buf):
    """从 DNS 响应里取 HTTPS/SVCB 的 ech 参数（key 5）。"""
    if len(buf) < 12:
        return None
    _tid, flags, qd, an, *_ = struct.unpack(">HHHHHH", buf[:12])
    off = 12
    for _ in range(qd):
        off = skip_name(buf, off) + 4
    for _ in range(an):
        off = skip_name(buf, off)
        rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", buf[off:off + 10])
        off += 10
        rd = buf[off:off + rdlen]
        off += rdlen
        if rtype == 65 and len(rd) > 3:
            # HTTPS/SVCB rdata: [2 字节优先级][target 名][参数区]
            # target 通常是根 "."（1 字节 0x00），所以参数区从偏移 3 开始；
            # 之前写成 2 会整体错位一个字节，导致永远找不到 key 5。
            p = 3
            while p + 4 <= len(rd):
                key, ln = struct.unpack(">HH", rd[p:p + 4])
                if key == 5 and ln:
                    return rd[p + 4:p + 4 + ln]
                p += 4 + ln
    return None


def _tcp_query(server, name):
    """UDP 响应被截断（TC 位）时用 TCP 重取，保证 HTTPS 记录完整。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(8)
    try:
        s.connect((server, 53))
        q = build_query(name)
        s.sendall(len(q).to_bytes(2, "big") + q)
        head = s.recv(2)
        if len(head) < 2:
            return None
        ln = int.from_bytes(head, "big")
        buf = b""
        while len(buf) < ln:
            chunk = s.recv(ln - len(buf))
            if not chunk:
                break
            buf += chunk
        return parse_https_ech(buf)
    except OSError:
        return None
    finally:
        s.close()


def dns_plain(server, name):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(6)
    try:
        s.sendto(build_query(name), (server, 53))
        data, _ = s.recvfrom(65535)
        if len(data) > 12 and (data[2] & 0x02):     # TC 置位 -> 走 TCP
            return _tcp_query(server, name)
        return parse_https_ech(data)
    except OSError:
        return _tcp_query(server, name)
    finally:
        s.close()


def dns_doh(url, name):
    b64 = base64.urlsafe_b64encode(build_query(name)).rstrip(b"=").decode()
    sep = "&" if "?" in url else "?"
    try:
        out = subprocess.run(["curl", "-s", "--max-time", "12",
                              "-H", "accept: application/dns-message",
                              f"{url}{sep}dns={b64}"], capture_output=True, timeout=20)
        return parse_https_ech(out.stdout)
    except subprocess.TimeoutExpired:
        return None


def system_resolvers():
    out = []
    try:
        for line in open("/etc/resolv.conf"):
            if line.startswith("nameserver"):
                out.append(line.split()[1])
                break
    except OSError:
        pass
    out.append("223.5.5.5")
    return out


# --------------------------------------------------------------- netlog ----
def scan_netlog(path, node_host=""):
    raw = open(path, encoding="utf-8", errors="replace").read()
    cfg_lens = {len(m) for m in re.findall(r'"ech_config_list":\s*"([^"]*)"', raw) if m}
    hs = [(m.start(), m.group(1)) for m in re.finditer(r'"encrypted_client_hello":\s*(true|false)', raw)]
    hosts = [(m.start(), m.group(1)) for m in re.finditer(r'"host":\s*"([^"]+)"', raw)]

    def nearest(pos):
        prev = [h for p, h in hosts if p < pos]
        return prev[-1] if prev else "?"

    ech_hosts = [nearest(p) for p, v in hs if v == "true"]
    node_ech = [h for h in ech_hosts if node_host and node_host in h]

    if node_ech:
        status = "ECH_ACTIVE"
    elif cfg_lens and ech_hosts:
        status = "ECH_INACTIVE"
    elif cfg_lens or hs:
        status = "ECH_INACTIVE"
    else:
        status = "ECH_UNKNOWN"

    return {
        "ech_config_lengths": sorted(cfg_lens),
        "handshakes": len(hs),
        "ech_handshakes": len(ech_hosts),
        "ech_hosts": list(dict.fromkeys(ech_hosts)),
        "node_ech": bool(node_ech),
        "status": status,
    }


# ------------------------------------------------------------------ 主流程 ----
def sh(cmd, timeout=60, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def port_open(port, host="127.0.0.1"):
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex((host, port)) == 0


def main(argv):
    as_json = "--json" in argv
    quick = "--quick" in argv
    keep = "--keep" in argv
    doh = DEFAULT_DOH
    if "--doh" in argv:
        doh = argv[argv.index("--doh") + 1]
    domain = "" if quick else DEFAULT_DOMAIN

    result = {"doh": doh, "domain": domain, "checks": {}, "evidence": {}}

    node_path = os.path.join(PREFIX, "nodes", "current")
    node = {}
    try:
        node = json.load(open(os.path.realpath(node_path)))
    except (OSError, ValueError):
        pass
    node_host = node.get("address", "")
    result["node"] = node_host
    result["chromium"] = sh(["bash", "-c",
        "for c in chromium chromium-browser google-chrome google-chrome-stable; do command -v $c && break; done"])[1]

    # DNS 侧
    if domain:
        res = {}
        for srv in system_resolvers():
            res[f"系统 DNS {srv}"] = bool(dns_plain(srv, domain))
        res[f"DoH {doh}"] = bool(dns_doh(doh, domain))
        result["checks"]["echconfig_dns"] = any(res.values())
        result["evidence"]["dns_channels"] = res

    if quick or not node_host:
        return report(result, as_json)

    if not os.path.exists(XRAY):
        result["checks"]["xray"] = False
        return report(result, as_json)

    work = tempfile.mkdtemp(prefix="xbd-ech-")
    prof = os.path.join(work, "prof")
    os.makedirs(os.path.join(prof, "Default"), exist_ok=True)
    # Secure DNS 必须写进 Local State：命令行开关在本版本已不存在
    ls = {"dns_over_https": {"mode": "secure", "templates": doh}, "os_crypt": {"encrypted_key": ""}}
    open(os.path.join(prof, "Local State"), "w").write(json.dumps(ls))
    open(os.path.join(prof, "Default", "Preferences"), "w").write(json.dumps({
        "profile": {"exit_type": "Normal", "exited_cleanly": True},
        "dns_over_https": {"mode": "secure", "templates": doh}}))

    # 临时 dialer 配置（独立端口，只监听回环）
    cfg_path = os.path.join(work, "xray.json")
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "genconfig.py"),
                       "--node", os.path.realpath(node_path), "--output", cfg_path,
                       "--mode", "dialer", "--listen", "127.0.0.1",
                       "--port", str(S_PORT), "--port-dialer", str(S_PORT),
                       "--no-mux", "--api-port", "18095",
                       "--logs", work], timeout=30)
    if rc != 0:
        result["checks"]["genconfig"] = False
        result["evidence"]["genconfig_error"] = out or err
        return report(result, as_json)

    env = dict(os.environ, XRAY_BROWSER_DIALER=f"127.0.0.1:{T_PORT}")
    xray = subprocess.Popen([XRAY, "run", "-config", cfg_path], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(30):
            if port_open(T_PORT) and port_open(S_PORT):
                break
            time.sleep(1)
        result["checks"]["dialer_up"] = port_open(T_PORT) and port_open(S_PORT)
        if not result["checks"]["dialer_up"]:
            return report(result, as_json)

        netlog = os.path.join(work, "netlog.json")
        chrome = shutil.which("chromium") or shutil.which("chromium-browser") or shutil.which("google-chrome")
        cproc = subprocess.Popen(
            [chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
             "--no-first-run", "--disable-dbus", "--disable-background-networking",
             f"--user-data-dir={prof}", f"--log-net-log={netlog}",
             f"http://127.0.0.1:{T_PORT}/"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(12)
        result["checks"]["browser_ws"] = bool(sh(
            ["bash", "-c", f"ss -tnH 2>/dev/null | grep -c 127.0.0.1:{T_PORT}"])[1] not in ("0", ""))

        ok_req = 0
        for _ in range(2):
            for tgt in ("api.ipify.org", "www.cloudflare.com", "www.google.com", "example.com"):
                rc, _, _ = sh(["curl", "-s", "-o", "/dev/null", "--max-time", "20",
                               "--socks5-hostname", f"127.0.0.1:{S_PORT}", f"https://{tgt}"], timeout=30)
                ok_req += 1 if rc == 0 else 0
                time.sleep(2)
        result["checks"]["proxy"] = ok_req > 0
        result["evidence"]["requests_ok"] = ok_req
        time.sleep(2)

        cproc.terminate()
        time.sleep(4)
        for p in sh(["bash", "-c", f"pgrep -f 'user-data-dir={prof}' || true"])[1].split():
            sh(["kill", "-9", p])
        time.sleep(1)

        # 谁在发起上游 TLS
        logf = os.path.join(work, "error-dialer.log")
        try:
            dial = open(logf, errors="replace").read().count("XHTTP is dialing")
        except OSError:
            dial = 0
        result["checks"]["tls_by_chromium"] = dial == 0
        result["evidence"]["xray_self_dials"] = dial

        if os.path.exists(netlog):
            result["evidence"]["netlog"] = scan_netlog(netlog, node_host)
        if keep:
            result["evidence"]["work_dir"] = work
    finally:
        xray.terminate()
        time.sleep(1)
        try:
            xray.kill()
        except Exception:
            pass
        if not keep:
            shutil.rmtree(work, ignore_errors=True)

    return report(result, as_json)


def report(result, as_json):
    nl = result["evidence"].get("netlog") or {}
    verdict = nl.get("status", "ECH_UNKNOWN")
    result["status"] = verdict

    if as_json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if verdict == "ECH_ACTIVE" else 1

    print("=" * 44)
    print("Browser Dialer ECH 诊断")
    print("=" * 44)
    print(f"  Chromium:            {result.get('chromium') or '未找到'}")
    print(f"  目标节点:            {result.get('node') or '（未选择）'}")
    if result["evidence"].get("dns_channels"):
        print("  DNS 侧 ECHConfig:")
        for k, v in result["evidence"]["dns_channels"].items():
            print(f"    {k:<32} {'✅ 有' if v else '❌ 无'}")
    if nl:
        print(f"  ECHConfig 长度:      {nl.get('ech_config_lengths') or '未获得'}")
        print(f"  TLS 握手:            {nl.get('handshakes')} 次，其中 ECH {nl.get('ech_handshakes')} 次")
        if nl.get("ech_hosts"):
            print("  使用 ECH 的连接:")
            for h in nl["ech_hosts"][:5]:
                mark = "  ← 目标节点" if result.get("node") and result["node"] in h else ""
                print(f"    {h}{mark}")
    if result["evidence"].get("xray_self_dials") is not None:
        print(f"  Xray 自发连接:       {result['evidence']['xray_self_dials']}（0 = TLS 由 Chromium 发起）")
    print("=" * 44)
    labels = {
        "ECH_ACTIVE": ("✓ ECH 已在到节点的握手上实际使用", True),
        "ECH_INACTIVE": ("! Chromium 支持 ECH，但本次连接未使用", False),
        "ECH_UNAVAILABLE": ("✗ 当前环境无法使用 ECH", False),
        "ECH_UNKNOWN": ("? 证据不足，无法判定", False),
    }
    text, _ = labels.get(verdict, ("?", False))
    print(f"ECH 状态: {verdict}")
    print(text)
    print("=" * 44)
    return 0 if verdict == "ECH_ACTIVE" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
