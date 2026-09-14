#!/usr/bin/env python3
"""Xray 配置生成器。

线上的唯一实例一律用 `--mode normal`，**同时**提供 SOCKS 与 HTTP 两个入站，
进程始终带 XRAY_BROWSER_DIALER —— 于是"用不用浏览器"完全由节点决定，不需要第二个
实例、第二个端口。详见 scripts/run-xray.sh。

`--mode dialer` 只剩一个用途：`xbd ech` 的 ECH 诊断需要一份"TLS 由浏览器完成、只
监听回环临时端口"的探针配置。它做两件 normal 不会做的事：
    * 丢弃 flow（vision/xtls）：JS 网络栈不支持；
    * 把 websocket/xhttp 的自定义 Host 换回地址 —— 浏览器发出的 Host 必须等于 SNI，
      否则 TLS 对不上（见 transport/internet/websocket/dialer.go 的同域规则）。
请不要把这个模式接回线上服务。

不写入的东西（有意为之）：
    * allowInsecure：已由 pinnedPeerCertSha256 取代
    * echSettings：dialer 模式下 TLS 由 Chromium 完成，Xray 的 ECH 配置不生效
"""
from __future__ import annotations

import argparse
import json
import os
import sys

NORMAL, DIALER = "normal", "dialer"

# WebSocket early data 默认长度。官方 browser_dialer 文档推荐 ?ed=2048，
# 而且实测它是浏览器转发下 ws 能用的前提（缺了会让内嵌页面抛 TypeError）。
WS_ED_DEFAULT = 2048

# TLS 交给浏览器的模式只支持这些传输（浏览器只能发 HTTP(S)）
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

    # 传输字段名随版本变化，**必须两个都写**：
    #   v26.3.27 及更早 -> 只认 streamSettings.network（method 被整体静默丢弃）
    #   main / 26.9.9+  -> 认 method；官方 transport.md 里 network 已完全不出现
    #
    # 实测依据（26.3.27 逐变体对照）：
    #   network:"xhttp"        -> 正常出网，日志 XHTTP is dialing to tcp
    #   method:"xhttp" 单独写   -> 退回裸 TCP（与"两个都不写"逐字节相同）
    #   network + method 双写   -> 与只写 network 逐字节相同（无副作用）
    # 注意 26.3.27 会**静默丢弃未知 streamSettings 字段**（连杜撰字段名都 Configuration OK），
    # 所以"method 被接受"是假阳性，不能据此认为它生效。
    #
    # 为什么非 hysteria 分支也必须双写：它以前只写 network。一旦升级到 network
    # 被移除的版本，**所有非 hysteria 节点会静默退回 raw TCP** —— 不报错、起得来，
    # 只是连不上，属于最难排查的一类退化。
    stream: dict = {"network": transport, "method": transport}

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
        # early data（?ed=N）。官方 browser_dialer 文档推荐 2048，且这里是**必须**的：
        # 浏览器转发下若 ed 缺失，Xray 发给内嵌页面的 WS 任务里就没有 extra 字段，
        # 而页面要读 task.extra.protocol -> TypeError -> ws 节点在浏览器路径下必然失败。
        # 实测：同一个节点 path 不带 ed 必失败、带 ?ed=2048 立刻出网；原生路径两者都正常。
        # ed 只能通过 URL 查询串生效（实测：wsSettings.ed / earlyData / edMax 等字段全部无效），
        # 所以这里拼到 path 上。原生路径下也验证可用，不会造成回归。
        ed = node.get("ws_ed") or 0
        if ed <= 0:
            ed = WS_ED_DEFAULT
        if ed > 0 and "ed=" not in str(ws["path"]):
            sep = "&" if "?" in ws["path"] else "?"
            ws["path"] = f"{ws['path']}{sep}ed={int(ed)}"
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

    # 直连豁免：节点自身域名 + 私网必须走 freedom，避免将来启用 TUN/透明代理后形成环路。
    #
    # 必须区分域名 / IPv4 / IPv6 三种，不能只看"是不是全数字"：
    # IPv6 字面量（如 2001:470:c:c22::1）含冒号，去掉点后当然不是全数字，
    # 于是被当成域名拼成 `domain:2001:470:c:c22::1` —— 那是个永不匹配的垃圾规则，
    # 结果 IPv6 节点反而**没有**直连豁免，将来开了 TUN 就会形成环路。
    #
    # 另外 Xray 的 domain 字段不认 IP，IP 必须放进 ip 字段，所以两个列表要分开。
    direct_domains, direct_ips = [], []
    for key in ("address", "host", "sni"):
        v = (node.get(key) or "").strip()
        if not v:
            continue
        if ":" in v:                        # IPv6 字面量
            direct_ips.append(v)
        elif v.replace(".", "").isdigit():  # IPv4 字面量
            direct_ips.append(v)
        else:                               # 域名
            direct_domains.append(v)
    if direct_ips:
        direct_ips.append("geoip:private")  # 私网同样豁免

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

    outbounds = [
        build_outbound(node, mode, args.mux),
        {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
        {"tag": "block", "protocol": "blackhole"},
    ]

    routing_rules = [
        {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
        # 绝不代理自己：节点域名/自身 IP 与私网直连（环路防护）。
        # domain 与 ip 必须分成两条规则 —— Xray 的 domain 字段不认 IP 字面量。
        # 私网归在 ip 规则里；没有 IP 需要豁免时，单独出一条 geoip:private。
        *([{"type": "field", "outboundTag": "direct",
            "domain": sorted(set(direct_domains))}] if direct_domains else []),
        *([{"type": "field", "outboundTag": "direct",
            "ip": sorted(set(direct_ips))}] if direct_ips
          else [{"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]}]),
        {"type": "field", "outboundTag": "proxy", "network": "tcp,udp"},
    ]

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
        "outbounds": outbounds,
        "routing": {"domainStrategy": "AsIs", "rules": routing_rules},
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
    # 输出目录自己建：这里是所有调用路径的公共落点（RUN.sh 建的布局、xbd apply、
    # 服务启动脚本 run-xray.sh），目录缺失时不能指望调用方自觉。
    # 实测踩过：全新安装漏建 runtime/ 时这里直接 FileNotFoundError，
    # 上层只看到「配置生成失败，这是致命的」—— 装完就用不了。
    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
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
