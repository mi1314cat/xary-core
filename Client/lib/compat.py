#!/usr/bin/env python3
"""节点能力检查：一个节点，两种使用方式。

对应需求第二/三条。核心观点：
    不要把节点分成"Browser Dialer 节点"和"普通节点"，
    而是同一个节点分别判断两种用法能不能用。

    Xray 普通模式   —— 几乎都支持（除本版本不认的协议）
    Browser Dialer  —— 只有 xhttp/websocket + TLS + 域名 才支持

判定规则来源（Xray-core 当前源码，不是教程）：
    transport/internet/splithttp/dialer.go:50   只有 realityConfig == nil 才启用 browser dialer
    transport/internet/websocket/dialer.go:114  同样的 host 规则
    docs/config/features/browser_dialer.md      只支持 XHTTP/WebSocket；不能自定义 SNI/Host
"""
from __future__ import annotations

import json
import sys

OK = "SUPPORTED"
WARN = "SUPPORTED_WITH_WARNING"
NO = "NOT_SUPPORTED"
UNKNOWN = "UNKNOWN"

# Xray 本版本支持的协议与传输（26.x）
# 官方 proxy/ 目录下的出站协议。hysteria2 在 Xray 里的协议名是 "hysteria"（version 2）。
XRAY_PROTOCOLS = {"vless", "vmess", "trojan", "shadowsocks", "hysteria2"}
# 官方文档里 method 的取值：raw | xhttp | mkcp | grpc | websocket | httpupgrade | hysteria
XRAY_TRANSPORTS = {"xhttp", "websocket", "tcp", "grpc", "h2", "httpupgrade", "mkcp", "quic"}

# Browser Dialer 只实现了这两种
DIALER_TRANSPORTS = {"xhttp", "websocket"}

VERDICT_RANK = {OK: 3, WARN: 2, UNKNOWN: 1, NO: 0}


def _is_ip(host: str) -> bool:
    if not host:
        return False
    if host.startswith("[") or ":" in host:
        return True
    parts = host.split(".")
    if len(parts) != 4:
        return False
    return all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)


# ---------------------------------------------------------------------------
# Xray 普通模式
# ---------------------------------------------------------------------------
def check_xray(node: dict) -> dict:
    checks, notes = [], []

    def add(item, verdict, detail):
        checks.append({"item": item, "verdict": verdict, "detail": detail})

    proto = (node.get("protocol") or "").lower()
    if not proto:
        add("协议", NO, "缺失")
        return _pack(checks, notes)

    if proto in XRAY_PROTOCOLS:
        label = {"shadowsocks": "Shadowsocks", "hysteria2": "Hysteria2"}.get(proto, proto.upper())
        add("协议", OK, label)
    else:
        add("协议", NO, f"{proto} 不在本 Xray 版本的出站协议里")
        notes.append("Browser Dialer 不能替代协议支持：它只是把 TLS/HTTP 交给浏览器，"
                     "协议本身仍由 Xray 处理。")
        return _pack(checks, notes)

    if not node.get("address"):
        add("地址", NO, "缺失")
    else:
        add("地址", OK, f'{node["address"]}:{node.get("port")}')

    if proto in ("vless", "vmess") and not node.get("uuid"):
        add("凭据", NO, "缺少 UUID")
    elif proto in ("trojan", "hysteria2") and not node.get("password"):
        add("凭据", NO, "缺少密码")
    elif proto == "shadowsocks" and not (node.get("method") and node.get("password")):
        add("凭据", NO, "缺少 method/password")
    else:
        add("凭据", OK, "完整")

    transport = node.get("transport") or ""
    if proto == "hysteria2":
        add("传输", OK, "hysteria（原生 QUIC 传输）")
    elif transport in XRAY_TRANSPORTS:
        add("传输", OK, transport)
    else:
        add("传输", WARN, f"{transport or '未知'} 未在本版本确认")

    security = (node.get("security") or "none").lower()
    add("安全", OK if security in ("tls", "reality", "none") else WARN, security)

    if security == "reality" and not node.get("reality_public_key"):
        add("Reality 公钥", NO, "security=reality 但缺少 pbk")
    if proto == "hysteria2":
        notes.append("Hysteria2 在 Xray 里的协议名是 hysteria（version 2）；"
                     "传输字段名随版本不同：v26.3.27 及更早用 streamSettings.network，"
                     "main 分支/新版用 method。本项目生成配置时会两个都写以兼容。")
        if node.get("allow_insecure") and not node.get("pinned_cert_sha256"):
            notes.append("该节点声明了 skip-cert-verify / allowInsecure，"
                         "但 Xray 26.x 已移除 allowInsecure —— 会报"
                         "「certificate relies on legacy Common Name field」而连不上。"
                         "解决：执行 xbd cert <编号> 取服务端证书指纹并固定"
                         "（pinnedPeerCertSha256 是官方替代方案）。")
    if node.get("allow_insecure"):
        add("证书校验", WARN, "节点声明跳过证书校验")
        notes.append("Xray 26.x 已移除 allowInsecure（迁移到 pinnedPeerCertSha256）；"
                     "本次生成的配置不会写入该项，因此证书必须有效。")
    if node.get("flow") and proto != "vless":
        add("flow", WARN, f"flow 仅对 VLESS 有意义（当前协议 {proto}）")

    return _pack(checks, notes)


# ---------------------------------------------------------------------------
# Browser Dialer 模式
# ---------------------------------------------------------------------------
def check_dialer(node: dict) -> dict:
    checks, notes = [], []

    def add(item, verdict, detail):
        checks.append({"item": item, "verdict": verdict, "detail": detail})

    proto = (node.get("protocol") or "").lower()
    transport = node.get("transport") or ""
    security = (node.get("security") or "none").lower()
    addr = (node.get("address") or "").strip()
    sni = (node.get("sni") or "").strip()
    host = (node.get("host") or "").strip()

    add("协议", OK if proto == "vless" else NO,
        "VLESS" if proto == "vless" else f"{proto} 不支持（Browser Dialer 目前只走 VLESS 出站）")
    if proto != "vless":
        notes.append("Browser Dialer 是 Xray 的传输层能力，只对 VLESS 出站启用；"
                     "该节点仍可用普通 Xray 模式。")
        return _pack(checks, notes)

    enc = (node.get("encryption") or "none").lower()
    add("encryption", OK if enc == "none" else NO, enc)

    if transport in DIALER_TRANSPORTS:
        add("传输", OK, transport)
    else:
        add("传输", NO, f"{transport or '未知'}：浏览器只能发 HTTP(S)，只实现了 XHTTP 与 WebSocket")
        notes.append(f"该节点仍可用普通 Xray 模式（transport={transport}）。")
        return _pack(checks, notes)

    if security == "reality":
        add("安全", NO, "REALITY 被 Browser Dialer 代码路径排除")
        notes.append("splithttp/dialer.go:50 只在 realityConfig == nil 时启用 browser dialer；"
                     "浏览器 JS 无法完成 REALITY 握手。该节点可用普通 Xray 模式。")
        return _pack(checks, notes)

    if security == "tls":
        port = int(node.get("port") or 0)
        add("TLS", OK if port == 443 else WARN, f"TLS :{port}")
        if port != 443:
            notes.append(f"非 443 端口会生成 https://<host>:{port}，服务端需接受该 authority。")
    else:
        add("安全", WARN, f"security={security}（明文 HTTP/WS）")
        notes.append("无 TLS 时浏览器走 ws:// 或 http://，可用但无保护。")

    if not addr:
        add("地址", NO, "缺失")
        return _pack(checks, notes)

    if _is_ip(addr):
        add("地址", NO, f"{addr} 是 IP 字面量")
        notes.append("浏览器直接拨 URL host，IP 会让 SNI 变成 IP，证书需含 IP SAN；"
                     "官方要求用域名（需要指 IP 就配 DNS 或 hosts）。")
    else:
        add("地址", OK, addr)

    effective = host or sni or addr
    add("浏览器使用的 Host", OK, effective)
    if host and sni and host != sni:
        add("Host vs SNI", WARN, f"host={host} sni={sni}")
        notes.append("Browser Dialer 忽略自定义 Host，实际使用 SNI。")
    elif host and host != addr:
        add("Host == Address", WARN, f"host={host} != address={addr}")
        notes.append("自定义 Host 不被尊重，浏览器会用它作为实际主机名。")
    elif sni and sni != addr:
        add("SNI == Address", WARN, f"sni={sni} != address={addr}")
        notes.append("Browser Dialer 实际要求 SNI == host == address。")
    else:
        add("SNI == Host == Address", OK, effective)

    if node.get("allow_insecure"):
        add("证书校验", WARN, "节点声明了 allowInsecure / skip-cert-verify")
        notes.append("Browser Dialer 下该配置无效：TLS 由 Chromium 校验，证书必须有效。")
    else:
        add("证书校验", OK, "由浏览器正常校验")

    if node.get("fingerprint"):
        notes.append(f"fingerprint={node['fingerprint']} 无意义：Chromium 自带真实指纹。")
    if node.get("flow"):
        add("flow", WARN, f"flow={node['flow']} 会被丢弃")
        notes.append("flow（vision/xtls）无法用于 JS 网络栈，生成配置时不写入。")

    if transport == "xhttp":
        add("XHTTP mode", OK if node.get("mode") else WARN, node.get("mode") or "未指定（用服务端默认）")
        notes.append("Xray issue #5739：Browser Dialer 忽略 xhttp sessionId/seqStr，服务端需接受。")
        notes.append("XHTTP 响应需带 CORS 头；第三方 CDN 可能剥掉。")
    if transport == "websocket":
        path = node.get("path") or ""
        add("WS path", OK if (not path or path.startswith("/")) else WARN, path or "(默认)")
        notes.append("early data 走 Sec-WebSocket-Protocol，服务端需 Xray >= 1.4.1。")

    notes.append("建议开 Mux.Cool：浏览器对同域并发有上限。")
    return _pack(checks, notes)


def _pack(checks, notes) -> dict:
    verdicts = [c["verdict"] for c in checks]
    if NO in verdicts:
        overall = NO
    elif UNKNOWN in verdicts:
        overall = UNKNOWN
    elif WARN in verdicts:
        overall = WARN
    else:
        overall = OK
    return {"overall": overall, "checks": checks, "notes": notes}


# ---------------------------------------------------------------------------
# 能力标签（需求第十三条）
# ---------------------------------------------------------------------------
def capability_tags(node: dict, xray: dict, dialer: dict) -> list[str]:
    tags = []
    if node.get("protocol"):
        tags.append(node["protocol"].upper() if node["protocol"] != "shadowsocks" else "Shadowsocks")
    if node.get("transport"):
        tags.append(node["transport"].upper() if node["transport"] != "websocket" else "WS")
    if (node.get("security") or "none") != "none":
        tags.append(node["security"].upper())
    if node.get("ech"):
        tags.append("ECH")
    if node.get("reality_public_key"):
        tags.append("Reality")
    if node.get("flow"):
        tags.append(node["flow"])
    if xray["overall"] in (OK, WARN):
        tags.append("Xray")
    else:
        tags.append("Xray 不可用")
    tags.append("Browser Dialer" if dialer["overall"] in (OK, WARN) else "Browser Dialer 不可用")
    return tags


def check_all(node: dict) -> dict:
    xray = check_xray(node)
    dialer = check_dialer(node)
    return {
        "node": node,
        "xray": xray,
        "dialer": dialer,
        "tags": capability_tags(node, xray, dialer),
        # 两种用法互相独立：这里给 UI 直接用
        "can_use_xray": xray["overall"] in (OK, WARN),
        "can_use_dialer": dialer["overall"] in (OK, WARN),
    }


def render(result: dict) -> str:
    n = result["node"]
    L = []
    L.append(f"节点名称：{n.get('name') or n.get('address')}")
    L.append("")
    L.append(f"Xray：")
    mark = {"SUPPORTED": "✓ 支持", "SUPPORTED_WITH_WARNING": "✓ 支持（有注意项）",
            "NOT_SUPPORTED": "✗ 不支持", "UNKNOWN": "? 未知"}[result["xray"]["overall"]]
    L.append(f"  {mark}")
    L.append("")
    L.append(f"Browser Dialer：")
    mark = {"SUPPORTED": "✓ 支持", "SUPPORTED_WITH_WARNING": "⚠ 支持（有注意项）",
            "NOT_SUPPORTED": "✗ 不支持", "UNKNOWN": "? 未知"}[result["dialer"]["overall"]]
    L.append(f"  {mark}")
    notes = (result["xray"].get("notes") or []) + (result["dialer"].get("notes") or [])
    if notes:
        L.append("")
        L.append("原因 / 说明：")
        for x in notes:
            L.append(f"  - {x}")
    L.append("")
    L.append("能力标签：" + "  ".join(f"[{t}]" for t in result["tags"]))
    return "\n".join(L)


# ---------------------------------------------------------------------------
SELFTEST_CASES = [
    # (节点, (Xray 普通模式可用, Browser Dialer 可用))
    ({"protocol": "vless", "transport": "xhttp", "security": "tls", "address": "a.example",
      "port": 443, "sni": "a.example", "uuid": "u", "mode": "auto", "encryption": "none"}, (True, True)),
    ({"protocol": "vless", "transport": "tcp", "security": "tls", "address": "b.example",
      "port": 443, "sni": "b.example", "uuid": "u", "encryption": "none"}, (True, False)),
    ({"protocol": "vless", "transport": "xhttp", "security": "reality", "address": "c.example",
      "port": 443, "sni": "c.example", "uuid": "u", "encryption": "none",
      "reality_public_key": "k"}, (True, False)),
    ({"protocol": "trojan", "transport": "tcp", "security": "tls", "address": "d.example",
      "port": 443, "password": "p"}, (True, False)),
    ({"protocol": "shadowsocks", "transport": "tcp", "security": "none", "address": "e.example",
      "port": 8388, "method": "aes-256-gcm", "password": "p"}, (True, False)),
    # hysteria2：Xray 支持（协议名 hysteria / version 2），Browser Dialer 不支持
    ({"protocol": "hysteria2", "transport": "quic", "security": "tls", "address": "f.example",
      "port": 443, "password": "p"}, (True, False)),
    ({"protocol": "vless", "transport": "websocket", "security": "tls", "address": "g.example",
      "port": 443, "sni": "g.example", "path": "/ws", "uuid": "u", "encryption": "none"}, (True, True)),
    ({"protocol": "vless", "transport": "xhttp", "security": "tls", "address": "1.2.3.4",
      "port": 443, "sni": "h.example", "uuid": "u", "encryption": "none"}, (True, False)),
    ({"protocol": "vless", "transport": "grpc", "security": "tls", "address": "i.example",
      "port": 443, "sni": "i.example", "uuid": "u", "encryption": "none"}, (True, False)),
]


def selftest() -> int:
    print("=== 能力检查自检 ===")
    failed = 0
    for node, (exp_xray, exp_dialer) in SELFTEST_CASES:
        r = check_all(node)
        good = (r["can_use_xray"] == exp_xray) and (r["can_use_dialer"] == exp_dialer)
        failed += 0 if good else 1
        print(f"  [{'PASS' if good else 'FAIL'}] {node['protocol']:<11} {node['transport']:<10} "
              f"{node['security']:<8} {node['address']:<12} "
              f"Xray={r['xray']['overall']:<22} BD={r['dialer']['overall']}")
    print(f"\n自检: {'PASS' if failed == 0 else str(failed) + ' 项失败'}")
    return 1 if failed else 0


def main(argv) -> int:
    if len(argv) > 1 and argv[1] == "selftest":
        return selftest()
    if len(argv) < 3:
        print("用法: compat.py <parse|check|json|render> <节点JSON文件|->  [--json]", file=sys.stderr)
        return 2
    cmd = argv[1]
    src = argv[2]
    text = sys.stdin.read() if src == "-" else open(src).read()
    if cmd in ("check", "render", "json"):
        node = json.loads(text)
        result = check_all(node)
        if cmd == "render":
            print(render(result))
            return 0 if result["can_use_dialer"] else 1
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if (result["can_use_xray"] or result["can_use_dialer"]) else 1
    print(f"未知命令: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
