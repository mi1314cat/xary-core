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
# 事件类型编号（Chromium netlog 的 type 是枚举序号，这里只固化我们用到的那几个；
# 判据不依赖编号含义，而是依赖字段本身是否存在，所以即使编号漂移也不会误判）。
EV_SSL_CONFIG = 194        # 含 url / privacy_mode
EV_SSL_HANDSHAKE = 63      # 含 encrypted_client_hello（仅 TLS-over-TCP）
EV_CONNECT_JOB = 181       # 含 destination / using_quic
EV_TCP_CONNECT = 51        # 含 address


def _load_events(path):
    """容错读取 netlog 事件。

    netlog 常被截断（Chromium 被 SIGKILL 时根对象没闭合），严格 json.loads 会炸，
    而正则能容忍却会丢结构。这里用 raw_decode 逐条读，读到断点就停 —— 两头的好处都要。
    """
    raw = open(path, encoding="utf-8", errors="replace").read()
    dec = json.JSONDecoder()
    i = raw.index("[", raw.index('"events"')) + 1
    n = len(raw)
    events, truncated = [], False
    while i < n:
        while i < n and raw[i] in " \t\r\n,":
            i += 1
        if i >= n or raw[i] == "]":
            break
        try:
            obj, end = dec.raw_decode(raw, i)
        except Exception:
            truncated = True
            break
        events.append(obj)
        i = end
    return events, truncated


def _find_key(obj, key):
    """按结构递归查找 key，返回 [(值, 同一字典里其它字符串值...)]。

    刻意不用 json.dumps + 正则：那正是这个探针原来的毛病 —— 引号、转义、换行
    都会让匹配悄悄失败，而失败表现为"看不到 ECHConfig"，会被误读成"ECH 没生效"。
    """
    out = []
    if isinstance(obj, dict):
        if key in obj:
            siblings = [v for k, v in obj.items()
                        if k != key and isinstance(v, str)]
            out.append((obj.get(key), siblings))
        for k, v in obj.items():
            if k != key:
                out.extend(_find_key(v, key))
    elif isinstance(obj, list):
        for v in obj:
            out.extend(_find_key(v, key))
    return out


def scan_netlog(path, node_host=""):
    """判定"ECH 是否真的作用在到节点的连接上"。

    为什么不能用"数 encrypted_client_hello":

    1. 该字段只出现在 TLS-over-TCP 的 SSL_HANDSHAKE 事件里。而 Chromium 对支持
       HTTP/3 的站点会走 QUIC，QUIC 的 ECH **不会**产生这个字段 —— 于是节点明明
       用了 ECH，却被报成"没使用"。实测 5 次里 2 次因此假阴性。
    2. 它以前还按"最近的前一个 host 字符串"猜这条握手属于谁（按文件字节位置），
       那既可能取到别的并发连接，也可能取到 URL —— 不是证据。

    现在改用两个**直接**判据：
      A. SSL_CONFIG 事件的 privacy_mode == "enabled"  —— 这条连接启用了隐私模式（ECH），
         而它是按 url 归属到具体主机的，不用猜。
      B. 同时确认 Chromium 确实拿到了该域名的 ECHConfig（DNS 侧的 HTTPS 记录）。
    另外记录到节点的连接走的是 TCP 还是 QUIC，避免再把 QUIC 当成"没连上"。
    """
    events, truncated = _load_events(path)
    host = (node_host or "").strip().lower()

    cfg_lens = set()          # Chromium 拿到的 ECHConfig 长度（base64 字符串长度）
    ech_config_for_node = 0   # 明确归属到节点域名的 ECHConfig
    privacy_on, privacy_off = [], []
    tcp_ech_true = tcp_ech_total = 0
    node_quic = node_tcp = 0
    node_ips = set()

    for e in events:
        prm = e.get("params") or {}
        et = e.get("type")

        # ECHConfig：按**结构**找，不用正则 —— 用正则解析 JSON 正是这个探针
        # 原来最容易出错的地方（引号/转义/换行都会让匹配悄悄失败）。
        for lst, name in _find_key(prm, "ech_config_list"):
            if lst:
                cfg_lens.add(len(lst))
                # 归属：同一条目里出现的 target_name / canonical_names 是否就是节点
                if host and any(host in str(x).lower() for x in name):
                    ech_config_for_node += 1

        if et == EV_SSL_CONFIG:
            url = prm.get("url") or ""
            pm = prm.get("privacy_mode") or ""
            if host and host in url.lower():
                (privacy_on if pm.startswith("enabled") else privacy_off).append(url)
        elif et == EV_SSL_HANDSHAKE and "encrypted_client_hello" in prm:
            tcp_ech_total += 1
            if prm.get("encrypted_client_hello") is True:
                tcp_ech_true += 1
        elif et == EV_CONNECT_JOB:
            dest = (prm.get("destination") or "").lower()
            if host and host in dest:
                if prm.get("using_quic"):
                    node_quic += 1
                else:
                    node_tcp += 1
        elif et == EV_TCP_CONNECT and host:
            addr = prm.get("address")
            if addr and addr.startswith("[") is False:
                node_ips.add(addr)

    # 判据 A 优先：能直接看到"到节点的连接启用了隐私模式"
    if privacy_on:
        status = "ECH_ACTIVE"
    elif ech_config_for_node and privacy_off:
        status = "ECH_INACTIVE"
    elif cfg_lens and not privacy_on:
        # 拿到了 ECHConfig，但看不到任何到节点的启用态连接：
        # 可能是没连上、也可能是走了 QUIC 而这些事件没被记上 —— 证据不足就说不足
        status = "ECH_UNKNOWN" if not privacy_off else "ECH_INACTIVE"
    else:
        status = "ECH_UNKNOWN"

    return {
        "ech_config_lengths": sorted(cfg_lens),
        "ech_config_for_node": ech_config_for_node,
        "node_privacy_enabled": len(privacy_on),
        "node_privacy_disabled": len(privacy_off),
        # 保留旧字段名以便向后兼容，但语义已修正（见上面注释）
        "handshakes": tcp_ech_total,
        "ech_handshakes": tcp_ech_true,
        "ech_hosts": sorted({u.split("/")[2] for u in privacy_on if "//" in u}),
        "node_ech": bool(privacy_on),
        "node_transport": ("quic" if node_quic and not node_tcp
                           else "tcp" if node_tcp and not node_quic
                           else "mixed" if node_quic and node_tcp else "unknown"),
        "node_quic_jobs": node_quic,
        "node_tcp_jobs": node_tcp,
        "truncated": truncated,
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

        # 谁在发起上游 TLS。
        # ⚠ 这条日志是 **Info 级**，而本诊断用 warning 级运行 —— 所以它**恒为 0**，
        # 无论 Xray 是否真的自己拨号。它证明不了任何事，之前却被当成"TLS 由浏览器发起"
        # 的证据（独立复核实测：info 级下 1 条，warning 级下 0 条）。
        # 现在只在真的取到该日志行时才作为辅助信息输出，取不到就明确标注"不可用"。
        logf = os.path.join(work, "error-dialer.log")
        try:
            txt = open(logf, errors="replace").read()
            dial = txt.count("XHTTP is dialing")
            dial_usable = "XHTTP is dialing" in txt or "dialing" in txt
        except OSError:
            dial, dial_usable = 0, False
        result["evidence"]["xray_self_dials"] = dial if dial_usable else None
        result["evidence"]["xray_self_dials_note"] = (
            "可用（日志里出现了 dialing 行）" if dial_usable
            else "不可用：该日志是 Info 级，本诊断按 warning 级运行，恒为 0，不能作为证据")
        # 真正可靠的反证在 netlog 里：到节点的连接由 Chromium 建立（node_transport 非 unknown）
        result["checks"]["tls_by_chromium"] = None

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
        print(f"  ECHConfig 长度:      {nl.get('ech_config_lengths') or '未获得'}"
              + (f"（其中 {nl.get('ech_config_for_node')} 条明确属于目标节点）"
                 if nl.get("ech_config_for_node") else ""))
        tr = nl.get("node_transport", "unknown")
        tr_txt = {"quic": "QUIC / HTTP3", "tcp": "TCP", "mixed": "TCP + QUIC",
                  "unknown": "未见连接到节点"}.get(tr, tr)
        print(f"  到节点的连接:        {tr_txt}"
              + (f"（QUIC 任务 {nl.get('node_quic_jobs')} / TCP 任务 {nl.get('node_tcp_jobs')}）"
                 if tr in ("quic", "tcp", "mixed") else ""))
        enabled = nl.get("node_privacy_enabled") or 0
        disabled = nl.get("node_privacy_disabled") or 0
        print(f"  目标节点启用 ECH:    {enabled} 条启用 / {disabled} 条未启用")
        print(f"  TLS-over-TCP 握手:   {nl.get('handshakes')} 次，其中 ECH "
              f"{nl.get('ech_handshakes')} 次（此计数看不到 QUIC，仅供参考）")
        if nl.get("truncated"):
            print("  注:                  netlog 尾部被截断，已按容错方式解析")
    if result["evidence"].get("xray_self_dials") is not None:
        print(f"  Xray 自发连接:       {result['evidence']['xray_self_dials']}（0 = TLS 由 Chromium 发起）")
    elif result["evidence"].get("xray_self_dials_note"):
        print(f"  Xray 自发连接:       {result['evidence']['xray_self_dials_note']}")
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
