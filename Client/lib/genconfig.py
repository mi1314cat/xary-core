#!/usr/bin/env python3
"""模式感知的 Xray 配置生成器。

同一个节点、两种用法，生成**两份不同实例**的运行配置（需求第七、十条）：

    --mode normal   常驻实例：SOCKS :1080 → 节点（Xray 自己完成 TLS）
    --mode dialer   按需实例：SOCKS :1081 → 节点（TLS 交给 Chromium）

这样：
    * 关闭 Browser Dialer 只需停掉 dialer 实例，常驻实例完全不受影响；
    * 两种模式可以同时存在，互不干扰，也不会产生代理环路。

不写入的东西（有意为之）：
    * flow（vision/xtls）：JS 网络栈不支持，dialer 模式丢弃
    * allowInsecure：dialer 模式下由 Chromium 校验，写了也无效
    * echSettings：dialer 模式下 TLS 由 Chromium 完成，Xray 的 ECH 配置不生效
"""
from __future__ import annotations

import argparse
import json
import sys

NORMAL, DIALER = "normal", "dialer"

# dialer 模式支持的传输（浏览器只能发 HTTP(S)）
DIALER_TRANSPORTS = {"xhttp", "websocket"}


def fail(msg: str) -> None:
    print(f"genconfig: {msg}", file=sys.stderr)
    sys.exit(2)


def build_stream(node: dict, mode: str) -> dict:
    transport = (node.get("transport") or "tcp").lower()
    security = (node.get("security") or "none").lower()

    if mode == DIALER:
        if transport not in DIALER_TRANSPORTS:
            fail(f"Browser Dialer 模式不支持 transport={transport}（只支持 xhttp / websocket）")
        if security == "reality":
            fail("Browser Dialer 模式不支持 REALITY：splithttp/dialer.go 仅在 realityConfig == nil 时启用")

    # hysteria2 的传输在 Xray 里是 streamSettings.method="hysteria"，
    # 不是 network="quic" —— 官方文档明确列在 method 的取值里。
    if transport == "quic" or (node.get("protocol") or "").lower() == "hysteria2":
        # 字段名随版本不同（实测得出，不能照抄文档）：
        #   v26.3.27 及更早  -> streamSettings.network = "hysteria"
        #   main 分支/新版    -> streamSettings.method  = "hysteria"
        # 实测：正式版上用 method 会退回 TCP（dialing to tcp），
        #       用 network 才是正确的 QUIC（dialing to udp）。
        # 这里同时写两个字段：旧版认 network，新版认 method，互不冲突。
        stream: dict = {"network": "hysteria", "method": "hysteria"}
        hs: dict = {"version": 2}
        if node.get("password"):
            hs["auth"] = node["password"]
        stream["hysteriaSettings"] = hs
        if security in ("tls", "none"):
            # hysteria2 默认就是 TLS（QUIC 自带），按官方示例给 tlsSettings
            tls_h: dict = {"serverName": node.get("sni") or node.get("address", "")}
            if node.get("alpn"):
                tls_h["alpn"] = [a for a in str(node["alpn"]).split(",") if a]
            # hysteria2 的 TLS 配置走这个分支，pinning 也必须在这里加 ——
            # 之前只加在主 TLS 分支，hysteria2 节点永远读不到指纹。
            if node.get("pinned_cert_sha256"):
                tls_h["pinnedPeerCertSha256"] = node["pinned_cert_sha256"]
            stream["security"] = "tls" if security != "none" or node.get("sni") else "none"
            if stream["security"] == "tls":
                stream["tlsSettings"] = tls_h
        return stream

    stream: dict = {"network": transport}

    if security == "tls":
        tls: dict = {"serverName": node.get("sni") or node.get("address", "")}
        if node.get("alpn"):
            tls["alpn"] = [a for a in str(node["alpn"]).split(",") if a]
        if node.get("fingerprint") and mode == NORMAL:
            # dialer 模式下指纹无意义（Chromium 自带真实指纹）
            tls["fingerprint"] = node["fingerprint"]
        # 自签证书节点的正确解法：固定服务端证书哈希。
        # Xray 26.x 移除了 allowInsecure，官方替代就是 pinnedPeerCertSha256。
        if node.get("pinned_cert_sha256"):
            tls["pinnedPeerCertSha256"] = node["pinned_cert_sha256"]
        # 注意：Xray 26.x 已移除 allowInsecure（官方提示迁移到 pinnedPeerCertSha256），
        # 因此这里**不写**该字段 —— 写了会导致配置校验直接失败。
        # 若节点声明跳过证书校验，由 compat 检查提示"证书必须有效"。
        stream["security"] = "tls"
        stream["tlsSettings"] = tls
    elif security == "reality":
        reality = {
            "serverName": node.get("sni") or node.get("address", ""),
            "publicKey": node.get("reality_public_key", ""),
            "shortId": node.get("reality_short_id", ""),
            "fingerprint": node.get("fingerprint") or "chrome",
        }
        if node.get("reality_spider_x"):
            reality["spiderX"] = node["reality_spider_x"]
        stream["security"] = "reality"
        stream["realitySettings"] = reality
    else:
        stream["security"] = "none"

    if transport == "xhttp":
        xh: dict = {"path": node.get("path") or "/"}
        if node.get("host"):
            xh["host"] = node["host"]
        if node.get("mode"):
            xh["mode"] = node["mode"]
        if node.get("extra"):
            try:
                parsed = json.loads(node["extra"]) if isinstance(node["extra"], str) else node["extra"]
                if parsed:
                    xh["extra"] = parsed
            except (ValueError, TypeError):
                pass
        stream["xhttpSettings"] = xh
    elif transport == "websocket":
        ws: dict = {"path": node.get("path") or "/"}
        if node.get("host"):
            ws["host"] = node["host"]
        stream["wsSettings"] = ws
    elif transport == "grpc":
        stream["grpcSettings"] = {"serviceName": node.get("service_name") or ""}
    elif transport == "tcp" and node.get("header_type") == "http":
        stream["tcpSettings"] = {"header": {"type": "http"}}
    elif transport == "httpupgrade":
        stream["httpupgradeSettings"] = {"path": node.get("path") or "/"}
        if node.get("host"):
            stream["httpupgradeSettings"]["host"] = node["host"]

    return stream


def build_outbound(node: dict, mode: str, mux: bool) -> dict:
    proto = (node.get("protocol") or "").lower()
    settings: dict

    if proto in ("vless", "vmess"):
        users = {"id": node.get("uuid", "")}
        if proto == "vless":
            users["encryption"] = node.get("encryption") or "none"
            # dialer 模式下 flow 必须丢弃：JS 网络栈不支持 xtls/vision
            if node.get("flow") and mode == NORMAL:
                users["flow"] = node["flow"]
        else:
            users["security"] = node.get("encryption") or "auto"
        settings = {"vnext": [{
            "address": node.get("address", ""),
            "port": int(node.get("port") or 443),
            "users": [users],
        }]}
    elif proto == "hysteria2":
        # 官方格式：protocol="hysteria" + settings.version=2 + address/port
        # 认证密码放在 streamSettings.hysteriaSettings.auth（见官方文档）
        settings = {
            "version": 2,
            "address": node.get("address", ""),
            "port": int(node.get("port") or 443),
        }
    elif proto == "trojan":
        settings = {"servers": [{
            "address": node.get("address", ""),
            "port": int(node.get("port") or 443),
            "password": node.get("password", ""),
        }]}
    elif proto == "shadowsocks":
        settings = {"servers": [{
            "address": node.get("address", ""),
            "port": int(node.get("port") or 8388),
            "method": node.get("method", ""),
            "password": node.get("password", ""),
        }]}
    else:
        fail(f"不支持的协议: {proto}")

    # Xray 侧协议名是 hysteria（version 2 即 hysteria2）
    proto_out = "hysteria" if proto == "hysteria2" else proto
    ob: dict = {
        "tag": "proxy",
        "protocol": proto_out,
        "settings": settings,
        "streamSettings": build_stream(node, mode),
    }
    if node.get("flow") and mode == NORMAL and proto == "vless":
        pass  # flow 已在 users 里
    if mux:
        ob["mux"] = {"enabled": True, "concurrency": 8}
    return ob


def build(node: dict, args) -> dict:
    mode = args.mode
    port = args.port if args.port is not None else (args.port_dialer if mode == DIALER else args.port_normal)

    # 直连豁免：节点自身域名 + 私网必须走 freedom，避免将来启用 TUN/透明代理后形成环路
    direct_domains = []
    for key in ("address", "host", "sni"):
        v = node.get(key)
        if v and not v.replace(".", "").isdigit():
            direct_domains.append("domain:" + v)

    inbounds = [{
        "tag": f"socks-{mode}",
        "listen": args.listen,
        "port": port,
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": bool(node.get("udp", True)),
                     "address": args.listen},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
    }]

    # 本机进程用的 HTTP 代理入口。
    # 为什么必须有：docker 的 HTTP_PROXY 只接受 http:// 与 https://，
    # 不认 socks5:// —— 只有 SOCKS 入口时 docker pull 依然不通。
    # 只监听回环：本机自用，不对外暴露。
    # 只给常驻实例：dialer 实例与常驻实例会同时运行，绑同一端口必然冲突。
    # 本机进程（docker 等）要的是普通模式出口，不需要走 Browser Dialer。
    if args.http_port and mode == NORMAL:
        inbounds.append({
            "tag": f"http-{mode}",
            "listen": "127.0.0.1",
            "port": args.http_port,
            "protocol": "http",
            "settings": {"auth": "noauth", "allowTransparent": False},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
        })

    # 局域网 HTTP 代理入口：给"WiFi 设置里填代理"这种用法。
    # 与回环那个分开，便于单独关闭；同样只出 SOCKS/HTTP 代理，不做流量劫持。
    if args.lan_http_port:
        inbounds.append({
            "tag": f"http-lan-{mode}",
            "listen": args.listen,
            "port": args.lan_http_port,
            "protocol": "http",
            "settings": {"auth": "noauth", "allowTransparent": False},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
        })

    inbounds.append({
        "tag": "api-in",
        "listen": "127.0.0.1",
        "port": args.api_port,
        "protocol": "dokodemo-door",
        "settings": {"address": "127.0.0.1"},
    })

    cfg = {
        "log": {
            "loglevel": args.loglevel,
            "access": f"{args.logs}/access-{mode}.log",
            "error": f"{args.logs}/error-{mode}.log",
        },
        "stats": {},
        "api": {"tag": "api", "services": ["StatsService", "HandlerService"]},
        "policy": {
            "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
            "system": {"statsInboundUplink": True, "statsInboundDownlink": True,
                       "statsOutboundUplink": True, "statsOutboundDownlink": True},
        },
        "inbounds": inbounds,
        "outbounds": [
            build_outbound(node, mode, args.mux),
            {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
                # 绝不代理自己：节点域名与私网直连（环路防护）
                *([{"type": "field", "outboundTag": "direct",
                    "domain": sorted(set(direct_domains))}] if direct_domains else []),
                {"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]},
                {"type": "field", "outboundTag": "proxy", "network": "tcp,udp"},
            ],
        },
    }
    return cfg


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", required=True, help="统一模型的节点 JSON")
    ap.add_argument("--output", required=True)
    ap.add_argument("--mode", choices=[NORMAL, DIALER], required=True)
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None, help="覆盖端口")
    ap.add_argument("--port-normal", type=int, default=1080)
    ap.add_argument("--port-dialer", type=int, default=1081)
    ap.add_argument("--api-port", type=int, default=18085)
    ap.add_argument("--http-port", type=int, default=0,
                    help="本机回环 HTTP 代理端口（0=不启用）。docker 等只认 HTTP 代理")
    ap.add_argument("--lan-http-port", type=int, default=0,
                    help="局域网 HTTP 代理端口（0=不启用）。设备在 WiFi 设置里填 IP+端口用")
    ap.add_argument("--logs", default="/opt/xray-browser-dialer/logs")
    ap.add_argument("--loglevel", default="warning")
    ap.add_argument("--no-mux", dest="mux", action="store_false", default=True)
    args = ap.parse_args()

    node = json.load(open(args.node))
    for key in ("address", "port", "protocol"):
        if not node.get(key):
            fail(f"节点缺少字段 {key!r}")

    cfg = build(node, args)
    with open(args.output, "w") as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(json.dumps({"ok": True, "mode": args.mode, "output": args.output,
                      "port": cfg["inbounds"][0]["port"],
                      "http_port": args.http_port,
                      "lan_http_port": args.lan_http_port}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
