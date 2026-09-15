#!/usr/bin/env python3
"""统一节点模型与多协议解析器（仅标准库）。

设计原则（对应需求第十二条）：
    解析阶段**尽可能完整保留**所有参数，即使 Browser Dialer 用不到。
    "能不能用"是后续能力的判断，不在解析阶段丢信息。

统一模型字段命名尽量贴近 Xray 的 streamSettings，便于直接生成配置。

支持输入：
    vless://  vmess://  trojan://  ss://  hysteria2://  hy2://
    Xray JSON 配置          Mihomo YAML 节点
    订阅 URL（多个节点换行分隔，或 base64 编码的列表）
"""
from __future__ import annotations

import base64
import binascii
import os
import json
import re
import sys
import urllib.parse

# ---------------------------------------------------------------------------
# 内部模型
# ---------------------------------------------------------------------------
DEFAULT_NODE = {
    "name": "",
    "protocol": "",            # vless / vmess / trojan / shadowsocks / hysteria2
    "address": "",
    "port": 0,
    "uuid": "",
    "password": "",
    "method": "",              # shadowsocks 加密方式
    "encryption": "none",      # vless 的 encryption
    "flow": "",
    "transport": "",           # xhttp / websocket / tcp / grpc / h2 / httpupgrade
    "transport_raw": "",
    "security": "none",        # tls / reality / none
    "sni": "",
    "alpn": "",
    "fingerprint": "",
    "allow_insecure": False,
    "path": "",
    "host": "",
    "mode": "",                # xhttp mode
    # WebSocket early data 长度。0 = 不启用。
    # 官方 browser_dialer 文档推荐 ?ed=2048；实测定量结论：
    #   浏览器路径下若没有 ed，内嵌页面会读 task.extra.protocol 抛 TypeError（extra 是空的），
    #   于是 ws 节点在浏览器路径下**必然失败**；加上 ed 后立刻可用。
    #   原生路径下有没有 ed 都能用，所以加上不会造成回归。
    "ws_ed": 0,
    "extra": "",               # xhttp extra
    "service_name": "",        # grpc
    "header_type": "",         # tcp 伪装
    "reality_public_key": "",
    "reality_short_id": "",
    "reality_spider_x": "",
    "ech": False,              # 节点是否声明支持 ECH
    "pinned_cert_sha256": "",  # 自签证书节点的证书哈希（Xray 26.x 的 allowInsecure 替代）
    "mux": False,
    "udp": True,
    "source": "",              # 来源格式，便于排查
    "raw_params": {},          # 原始 query，一个都不丢
    "raw": "",                 # 原始字符串/片段
    # 这个节点是否用浏览器完成 TLS。这是**每个节点各自的属性**，不是全局模式：
    #     None  = 默认（协议支持就用浏览器，不支持就用 Xray 自带 TLS）
    #     True  = 强制用浏览器
    #     False = 强制不用（即使协议支持）
    # 为什么不做成全局开关：全局关掉会让**所有**依赖浏览器的节点一起失效（实测踩过）。
    "use_browser": None,
}

_TRANSPORT_ALIASES = {
    "xhttp": "xhttp", "splithttp": "xhttp",
    "ws": "websocket", "websocket": "websocket",
    "tcp": "tcp", "raw": "tcp",
    "grpc": "grpc", "gun": "grpc",
    "h2": "h2", "http": "h2",
    "httpupgrade": "httpupgrade",
    "mkcp": "mkcp", "kcp": "mkcp",
    "quic": "quic",
}


def new_node() -> dict:
    return dict(DEFAULT_NODE)


def _b64decode(s: str) -> str:
    """宽松的 base64 解码：兼容 urlsafe、缺失 padding、换行。"""
    s = s.strip().replace("\n", "").replace("\r", "")
    s = s.replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    try:
        return base64.b64decode(s).decode("utf-8", "replace")
    except (binascii.Error, ValueError):
        return ""


def _norm_transport(raw: str) -> str:
    return _TRANSPORT_ALIASES.get((raw or "").lower(), (raw or "").lower())


def _q(params: dict) -> dict:
    """把 parse_qs 的 {k: [v]} 压平为 {k: v}。"""
    return {k: (v[0] if isinstance(v, list) and v else "") for k, v in (params or {}).items()}


# ---------------------------------------------------------------------------
# 各协议解析
# ---------------------------------------------------------------------------
def parse_vless(uri: str) -> dict:
    u = urllib.parse.urlparse(uri)
    if not u.hostname:
        raise ValueError("VLESS 链接缺少地址")
    q = _q(urllib.parse.parse_qs(u.query, keep_blank_values=True))
    n = new_node()
    n.update({
        "name": urllib.parse.unquote(u.fragment) or u.hostname,
        "protocol": "vless",
        "uuid": urllib.parse.unquote(u.username or ""),
        "address": u.hostname,
        "port": u.port or 443,
        "encryption": q.get("encryption", "none"),
        "security": (q.get("security") or "none").lower(),
        "sni": q.get("sni") or q.get("serverName") or "",
        "host": q.get("host") or "",
        "path": q.get("path") or "",
        "mode": q.get("mode") or "",
        "extra": q.get("extra") or "",
        "flow": q.get("flow") or "",
        "fingerprint": q.get("fp") or "",
        "alpn": q.get("alpn") or "",
        "service_name": q.get("serviceName") or "",
        "header_type": q.get("headerType") or "",
        "reality_public_key": q.get("pbk") or "",
        "reality_short_id": q.get("sid") or "",
        "reality_spider_x": q.get("spx") or "",
        "allow_insecure": str(q.get("allowInsecure", "")).lower() in ("1", "true"),
        "ech": bool(q.get("ech")),
        "source": "vless-uri",
        "raw_params": q,
        "raw": uri,
    })
    n["transport_raw"] = (q.get("type") or "tcp").lower()
    n["transport"] = _norm_transport(n["transport_raw"])
    return n


def parse_vmess(uri: str) -> dict:
    """vmess://<base64 json>"""
    body = uri.split("://", 1)[1]
    txt = _b64decode(body)
    if not txt.strip().startswith("{"):
        raise ValueError("vmess 链接不是有效的 base64 JSON")
    d = json.loads(txt)
    n = new_node()
    n.update({
        "name": d.get("ps") or d.get("add", "vmess"),
        "protocol": "vmess",
        "uuid": d.get("id", ""),
        "address": d.get("add", ""),
        "port": int(d.get("port") or 443),
        "encryption": d.get("scy") or "auto",
        "security": "tls" if str(d.get("tls", "")).lower() in ("tls", "true", "1") else "none",
        "sni": d.get("sni") or d.get("host") or "",
        "host": d.get("host") or "",
        "path": d.get("path") or "",
        "service_name": d.get("path") or "",
        "fingerprint": d.get("fp") or "",
        "alpn": d.get("alpn") or "",
        "header_type": d.get("type") or "",
        "source": "vmess-uri",
        "raw_params": d,
        "raw": uri,
    })
    n["transport_raw"] = (d.get("net") or "tcp").lower()
    n["transport"] = _norm_transport(n["transport_raw"])
    return n


def parse_trojan(uri: str) -> dict:
    u = urllib.parse.urlparse(uri)
    if not u.hostname:
        raise ValueError("Trojan 链接缺少地址")
    q = _q(urllib.parse.parse_qs(u.query, keep_blank_values=True))
    n = new_node()
    n.update({
        "name": urllib.parse.unquote(u.fragment) or u.hostname,
        "protocol": "trojan",
        "password": urllib.parse.unquote(u.username or ""),
        "address": u.hostname,
        "port": u.port or 443,
        # Trojan 默认就是 TLS
        "security": (q.get("security") or "tls").lower(),
        "sni": q.get("sni") or q.get("peer") or "",
        "host": q.get("host") or "",
        "path": q.get("path") or "",
        "service_name": q.get("serviceName") or "",
        "fingerprint": q.get("fp") or "",
        "alpn": q.get("alpn") or "",
        "allow_insecure": str(q.get("allowInsecure", "")).lower() in ("1", "true"),
        "source": "trojan-uri",
        "raw_params": q,
        "raw": uri,
    })
    n["transport_raw"] = (q.get("type") or "tcp").lower()
    n["transport"] = _norm_transport(n["transport_raw"])
    return n


def parse_shadowsocks(uri: str) -> dict:
    """支持 SIP002 (ss://base64(method:pass)@host:port) 与旧式 ss://base64(全部)。"""
    body = uri.split("://", 1)[1]
    q, _, frag = body.partition("#")
    name = urllib.parse.unquote(frag)
    q, _, query = q.partition("?")
    params = _q(urllib.parse.parse_qs(query, keep_blank_values=True))

    if "@" in q:
        userinfo, hostpart = q.rsplit("@", 1)
        cred = _b64decode(userinfo) if ":" not in userinfo else urllib.parse.unquote(userinfo)
    else:
        decoded = _b64decode(q)
        if "@" not in decoded:
            raise ValueError("ss 链接格式无法识别")
        cred, hostpart = decoded.rsplit("@", 1)

    method, _, password = cred.partition(":")
    hostpart = hostpart.split("/")[0]
    if hostpart.startswith("["):          # IPv6
        host, _, port = hostpart.rpartition("]:")
        host = host.lstrip("[")
    else:
        host, _, port = hostpart.rpartition(":")

    n = new_node()
    n.update({
        "name": name or host,
        "protocol": "shadowsocks",
        "method": method,
        "password": password,
        "address": host,
        "port": int(port or 8388),
        "security": "none",
        "source": "ss-uri",
        "raw_params": params,
        "raw": uri,
    })
    n["transport_raw"] = "tcp"
    n["transport"] = "tcp"
    return n


def parse_hysteria2(uri: str) -> dict:
    u = urllib.parse.urlparse(uri)
    if not u.hostname:
        raise ValueError("Hysteria2 链接缺少地址")
    q = _q(urllib.parse.parse_qs(u.query, keep_blank_values=True))
    n = new_node()
    n.update({
        "name": urllib.parse.unquote(u.fragment) or u.hostname,
        "protocol": "hysteria2",
        "password": urllib.parse.unquote(u.username or "") or q.get("password", ""),
        "address": u.hostname,
        "port": u.port or 443,
        "security": "tls",
        "sni": q.get("sni") or q.get("peer") or "",
        "alpn": q.get("alpn") or "",
        "allow_insecure": str(q.get("insecure", "")).lower() in ("1", "true"),
        "source": "hysteria2-uri",
        "raw_params": q,
        "raw": uri,
    })
    n["transport_raw"] = "quic"
    n["transport"] = "quic"
    return n


# ---------------------------------------------------------------------------
# 配置文件解析
# ---------------------------------------------------------------------------
def parse_xray_json(text: str) -> dict:
    cfg = json.loads(text)
    outbounds = cfg.get("outbounds") or []
    ob = None
    for cand in outbounds:
        if cand.get("protocol") in ("vless", "vmess", "trojan", "shadowsocks", "hysteria2"):
            ob = cand
            break
    if ob is None:
        raise ValueError("Xray 配置里没有可识别的出站")

    proto = ob["protocol"]
    ss = ob.get("streamSettings") or {}
    settings = ob.get("settings") or {}
    n = new_node()
    n["protocol"] = proto
    n["name"] = ob.get("tag") or proto
    n["source"] = "xray-json"
    n["raw"] = text[:4000]
    n["transport_raw"] = (ss.get("network") or "tcp").lower()
    n["transport"] = _norm_transport(n["transport_raw"])
    n["security"] = (ss.get("security") or "none").lower()

    if proto in ("vless", "vmess"):
        vnext = (settings.get("vnext") or [{}])[0]
        users = (vnext.get("users") or [{}])[0]
        n["address"] = vnext.get("address", "")
        n["port"] = int(vnext.get("port") or 443)
        n["uuid"] = users.get("id", "")
        n["flow"] = users.get("flow") or ""
        n["encryption"] = users.get("encryption") or ("auto" if proto == "vmess" else "none")
    else:
        servers = (settings.get("servers") or [{}])[0]
        n["address"] = servers.get("address", "")
        n["port"] = int(servers.get("port") or 443)
        n["password"] = servers.get("password", "")
        n["method"] = servers.get("method", "")

    tls = ss.get("tlsSettings") or {}
    reality = ss.get("realitySettings") or {}
    ws = ss.get("wsSettings") or {}
    xh = ss.get("xhttpSettings") or ss.get("splithttpSettings") or {}
    grpc = ss.get("grpcSettings") or {}

    n["sni"] = tls.get("serverName") or reality.get("serverName") or ""
    n["alpn"] = ",".join(tls.get("alpn") or [])
    n["fingerprint"] = tls.get("fingerprint") or reality.get("fingerprint") or ""
    n["allow_insecure"] = bool(tls.get("allowInsecure"))
    n["host"] = ws.get("host") or xh.get("host") or ""
    n["path"] = ws.get("path") or xh.get("path") or ""
    n["mode"] = xh.get("mode") or ""
    n["extra"] = json.dumps(xh.get("extra") or {})
    n["service_name"] = grpc.get("serviceName") or ""
    n["reality_public_key"] = reality.get("publicKey") or ""
    n["reality_short_id"] = reality.get("shortId") or ""
    n["mux"] = bool(ob.get("mux", {}).get("enabled"))
    n["ech"] = bool(tls.get("echSettings"))
    return n


_MIHOMO_KEYS = {
    "servername": "sni", "sni": "sni", "flow": "flow", "uuid": "uuid",
    "password": "password", "cipher": "method", "alterId": "alter_id",
    "client-fingerprint": "fingerprint", "skip-cert-verify": "allow_insecure",
}


def parse_mihomo_yaml(text: str) -> dict:
    """mihomo 节点解析。优先用 PyYAML，缺失时退化为键值扫描。"""
    entry = None
    try:
        import yaml
        data = yaml.safe_load(text) or {}
        candidates = (data.get("proxies") or []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
        for p in candidates:
            if isinstance(p, dict) and str(p.get("type", "")).lower() in (
                    "vless", "vmess", "trojan", "ss", "shadowsocks", "hysteria2"):
                entry = p
                break
    except ImportError:
        entry = None
    except Exception as exc:
        raise ValueError(f"mihomo YAML 解析失败: {exc}") from exc

    if entry is None:
        # 退化路径：至少能读出 server/port/type
        if not re.search(r"^\s*(server|type)\s*:", text, re.M):
            raise ValueError("mihomo 配置里没有可识别的节点")
        entry = {}
        for k in ("name", "type", "server", "port", "uuid", "password", "cipher",
                  "network", "tls", "servername", "sni", "path", "host"):
            m = re.search(rf"^\s*{k}\s*:\s*(.+?)\s*$", text, re.M)
            if m:
                entry[k] = m.group(1).strip().strip('"\'')
        if "path" not in entry:
            m = re.search(r"^\s*path\s*:\s*(.+?)\s*$", text, re.M)
            if m:
                entry["path"] = m.group(1).strip().strip('"\'')

    return _yaml_entry_to_node(entry)


def _split_ws_path(path: str):
    """把 '/path?ed=2048' 拆成 ('/path', 2048)。

    为什么必须拆开：Xray 的浏览器转发会把整串当 URL 路径用，带着 ?ed= 会让
    服务端路径匹配失败（实测：path 含 ?ed=2048 时连接建立不起来）。
    early data 应该单独表达，而不是塞进路径。
    """
    p = str(path or "")
    if "?" not in p:
        return p, 0
    base, _, q = p.partition("?")
    ed = 0
    for kv in q.split("&"):
        k, _, v = kv.partition("=")
        if k.strip().lower() == "ed":
            try:
                ed = int(v.strip() or 0)
            except ValueError:
                ed = 0
    return (base or "/"), ed


def _extract_ws_ed(ws: dict, path: str) -> int:
    """early data 长度：优先显式字段，其次 path 里的 ?ed=。"""
    for k in ("ed", "earlyData", "early_data", "edMax"):
        v = ws.get(k)
        if v in (None, "", 0, "0"):
            continue
        try:
            n = int(v)
        except (TypeError, ValueError):
            continue
        if n > 0:
            return n
    return _split_ws_path(path)[1]


def _yaml_entry_to_node(entry: dict) -> dict:
    t = str(entry.get("type", "")).lower()
    proto = {"ss": "shadowsocks"}.get(t, t)
    n = new_node()
    n["protocol"] = proto
    n["name"] = entry.get("name") or entry.get("server", "node")
    n["address"] = str(entry.get("server", ""))
    n["port"] = int(entry.get("port") or 443)
    n["uuid"] = str(entry.get("uuid", ""))
    n["password"] = str(entry.get("password", ""))
    n["method"] = str(entry.get("cipher", ""))
    # vless 的 encryption 必须原样保留！
    # Xray 25.x 起 vless 支持后量子加密（mlkem768x25519plus.*），服务端开了之后
    # 客户端写 "none" 会直接连不上。曾经这里漏读该字段，于是所有 mlkem 节点
    # 都被静默降级成 none —— 表现为"原生 TLS 连不上"，被误判成服务端问题。
    if "encryption" in entry and entry.get("encryption") not in (None, ""):
        n["encryption"] = str(entry["encryption"])
    n["sni"] = str(entry.get("servername") or entry.get("sni") or "")
    n["flow"] = str(entry.get("flow", ""))
    n["fingerprint"] = str(entry.get("client-fingerprint", ""))
    n["allow_insecure"] = bool(entry.get("skip-cert-verify"))
    n["mux"] = bool(entry.get("smux") or entry.get("mux"))
    n["udp"] = bool(entry.get("udp", True))
    n["source"] = "mihomo-yaml"
    # 原始片段：单条解析时能拿到全文，从列表抽取时只能拿到该条目
    n["raw"] = json.dumps(entry, ensure_ascii=False)[:4000]

    if entry.get("reality-opts"):
        n["security"] = "reality"
        ro = entry["reality-opts"] if isinstance(entry["reality-opts"], dict) else {}
        n["reality_public_key"] = str(ro.get("public-key", ""))
        n["reality_short_id"] = str(ro.get("short-id", ""))
    elif str(entry.get("tls", "")).lower() in ("true", "1"):
        n["security"] = "tls"
    else:
        n["security"] = "none"

    # hysteria2 走 QUIC，配置里通常不写 network —— 不能默认成 tcp
    default_net = "quic" if proto == "hysteria2" else "tcp"
    net = str(entry.get("network") or default_net).lower()
    n["transport_raw"] = net
    n["transport"] = _norm_transport(net)

    ws = entry.get("ws-opts") if isinstance(entry.get("ws-opts"), dict) else {}
    xh = entry.get("xhttp-opts") or entry.get("splithttp-opts")
    xh = xh if isinstance(xh, dict) else {}
    if ws:
        n["path"] = str(ws.get("path") or "")
        headers = ws.get("headers") or {}
        n["host"] = str(headers.get("Host") or headers.get("host") or "")
        # early data：只记录，**不把 ?ed= 从 path 里拆掉**。
        # 实测（26.3.27）：ed 只能通过 URL 查询串生效，写 wsSettings.ed 等字段一律无效；
        # 而浏览器转发要靠它才会在任务里带上 extra.protocol，缺了页面就抛 TypeError。
        # 拆出去看着更"干净"，实际上会让 ws 节点在浏览器路径下必然失败。
        n["ws_ed"] = _extract_ws_ed(ws, n["path"])
    if xh:
        n["path"] = str(xh.get("path") or n["path"])
        n["mode"] = str(xh.get("mode") or "")
        headers = xh.get("headers") or {}
        n["host"] = str(headers.get("Host") or headers.get("host") or n["host"])
    if entry.get("ech-opts"):
        n["ech"] = True
    if "alpn" in entry:
        alpn = entry["alpn"]
        n["alpn"] = ",".join(alpn) if isinstance(alpn, list) else str(alpn)
    return n


# ---------------------------------------------------------------------------
# 格式识别与统一入口
# ---------------------------------------------------------------------------
_URI_SCHEMES = {
    "vless": parse_vless, "vmess": parse_vmess, "trojan": parse_trojan,
    "ss": parse_shadowsocks, "shadowsocks": parse_shadowsocks,
    "hysteria2": parse_hysteria2, "hy2": parse_hysteria2,
}


def is_uri(text: str) -> bool:
    return bool(re.match(r"^[a-z0-9]+://", text.strip(), re.I))


def detect_format(text: str) -> str:
    t = text.lstrip()
    if is_uri(t):
        scheme = t.split("://", 1)[0].lower()
        if scheme in _URI_SCHEMES:
            return f"uri:{scheme}"
        if scheme in ("http", "https"):
            return "subscription"
    if t.startswith("{"):
        try:
            d = json.loads(t)
        except ValueError:
            return "unknown"
        if isinstance(d, dict):
            if "outbounds" in d:
                return "xray-json"
            if "source" in d and "address" in d:
                return "node-record"
            if "transport" in d and ("address" in d or "server" in d):
                return "node-record"
            if "address" in d or "server" in d:
                return "node-record"
        return "unknown"
    if "proxies:" in t or t.startswith("- ") or re.search(r"^\s*type\s*:", t, re.M):
        return "mihomo-yaml"
    return "unknown"


def parse_node(text: str) -> dict:
    """把任意支持的输入解析成统一模型。"""
    fmt = detect_format(text)
    if fmt.startswith("uri:"):
        scheme = fmt.split(":", 1)[1]
        return _URI_SCHEMES[scheme](text.strip())
    if fmt == "xray-json":
        return parse_xray_json(text)
    if fmt == "node-record":
        d = json.loads(text)
        if not isinstance(d, dict) or "address" not in d:
            raise ValueError("不是节点记录")
        merged = new_node()
        merged.update({k: v for k, v in d.items() if v not in (None, "")})
        merged.setdefault("transport_raw", merged.get("transport", ""))
        return merged
    if fmt == "mihomo-yaml":
        return parse_mihomo_yaml(text)
    raise ValueError("无法识别的输入格式（支持 vless/vmess/trojan/ss/hysteria2 链接、"
                     "Xray JSON、Mihomo YAML）")


def parse_many(text: str) -> list[dict]:
    """解析可能包含多个节点的输入。

    支持三种形态：
      1) 一段 mihomo YAML（含多个 - name: 条目）—— 必须整段解析，
         按行拆开会把多行结构拆散（这是之前的 bug）
      2) 多行 URI（每行一个 vless:// 等）
      3) 订阅内容（可能 base64 编码）
    """
    body = text.strip()
    if not body:
        return []

    # 形态 1：YAML 文档 / 列表
    looks_yaml = (
        body.startswith("- ") or body.startswith("proxies:")
        or ("\n" in body and re.search(r"^\s*-\s*name\s*:", body, re.M))
        or re.search(r"^\s*type\s*:\s*(vless|vmess|trojan|ss|shadowsocks|hysteria2)\s*$",
                     body, re.M)
    )
    if looks_yaml and not is_uri(body):
        return _parse_yaml_all(body)

    # 形态 2/3：多行 URI（含 base64 订阅）
    decoded = _b64decode(body) if ("\n" not in body and not is_uri(body)) else ""
    if decoded and is_uri(decoded):
        body = decoded

    nodes = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            nodes.append(parse_node(line))
        except Exception:
            continue
    return nodes


def _parse_yaml_all(text: str) -> list[dict]:
    """从 mihomo YAML 里取出全部节点。"""
    entries = None
    try:
        import yaml
        data = yaml.safe_load(text) or {}
        if isinstance(data, dict):
            entries = data.get("proxies") or []
        elif isinstance(data, list):
            entries = data
    except Exception:
        entries = None

    if entries:
        out = []
        for e in entries:
            if not isinstance(e, dict):
                continue
            try:
                out.append(_yaml_entry_to_node(e))
            except Exception:
                continue
        if out:
            return out

    # 退化路径：PyYAML 不可用或结构异常时，按 "  - name:" 切块后逐块解析
    import yaml as _y  # noqa: F401  (仅确认可用性)
    blocks = re.split(r"^\s*-\s*(?=name\s*:)", text, flags=re.M)
    out = []
    for blk in blocks:
        blk = blk.strip()
        if not blk:
            continue
        candidate = "- " + blk if not blk.startswith("- ") else blk
        try:
            out.append(parse_mihomo_yaml(candidate))
            continue
        except Exception:
            pass
        # v2.1: 粘贴常带多余前导缩进（首行 "- name:" 顶格、其余字段多 2 格以上），
        # PyYAML 报 "mapping values are not allowed here"。
        # 方法：首行作为键行，后续行按 (自身缩进 - 第二字段行缩进 + 2) 左移，
        # 重建为合法列表项后再解析一次。
        lines = [l.rstrip() for l in blk.splitlines() if l.strip()]
        if len(lines) >= 2:
            first_c = len(lines[0]) - len(lines[0].lstrip())   # "name:" 行的当前缩进
            shift = len(lines[1]) - len(lines[1].lstrip()) - 2  # 第二字段行相对键位的多余空格
            if shift > 0:
                fixed_lines = ["- " + lines[0].lstrip()]
                for l in lines[1:]:
                    c = len(l) - len(l.lstrip())
                    fixed_lines.append(" " * max(0, c - shift - first_c) + l.lstrip())
                try:
                    out.append(parse_mihomo_yaml("\n".join(fixed_lines)))
                    continue
                except Exception:
                    pass
        continue
    return out


def parse_subscription(text: str) -> list[dict]:
    """订阅内容 → 节点列表。自动识别 base64 编码与多行文本。"""
    body = text.strip()
    decoded = _b64decode(body) if not is_uri(body) and "\n" not in body else ""
    if decoded and is_uri(decoded):
        body = decoded
    nodes = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            nodes.append(parse_node(line))
        except Exception:
            continue
    return nodes


def dump(node: dict) -> str:
    return json.dumps(node, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def selftest() -> int:
    """多协议解析自检：每种协议至少一条真实形态的输入。"""
    failed = 0
    cases = [
        ("vless://u@a.example:443?encryption=none&security=tls&type=xhttp&path=%2Fx&sni=a.example&mode=auto",
         "vless", "xhttp", "tls"),
        ("vless://u@b.example:443?encryption=none&security=reality&type=ws&path=%2Fw&sni=b.example&pbk=k&sid=01&fp=chrome",
         "vless", "websocket", "reality"),
        ("vmess://" + base64.b64encode(json.dumps({
            "v":"2","ps":"vm","add":"c.example","port":"443","id":"11111111-2222-3333-4444-555555555555",
            "net":"ws","tls":"tls","host":"c.example","path":"/ws","scy":"auto"}).encode()).decode(),
         "vmess", "websocket", "tls"),
        ("trojan://pw@d.example:443?sni=d.example&type=tcp#trojan-node",
         "trojan", "tcp", "tls"),
        ("ss://" + base64.b64encode(b"aes-256-gcm:pass123").decode() + "@e.example:8388#ss-node",
         "shadowsocks", "tcp", "none"),
        ("hysteria2://pw@f.example:443?sni=f.example#hy2-node",
         "hysteria2", "quic", "tls"),
    ]
    print("=== 节点解析自检 ===")
    for raw, proto, transport, security in cases:
        try:
            n = parse_node(raw)
            good = (n["protocol"] == proto and n["transport"] == transport
                    and n["security"] == security and n["address"] and n["port"])
            detail = f'{n["protocol"]:<12} {n["transport"]:<10} {n["security"]:<8} {n["address"]}:{n["port"]}'
        except Exception as exc:
            good, detail = False, f"异常: {exc}"
        failed += 0 if good else 1
        print(f"  [{'PASS' if good else 'FAIL'}] {detail}")

    # 统一模型的完整性：解析阶段不许丢字段
    n = parse_node(cases[1][0])
    keep = ["reality_public_key", "reality_short_id", "fingerprint", "path", "sni"]
    missing = [k for k in keep if not n.get(k)]
    good = not missing
    failed += 0 if good else 1
    print(f"  [{'PASS' if good else 'FAIL'}] 字段完整性（缺失: {missing or '无'}）")

    # 订阅解析
    sub = "\n".join([c[0] for c in cases[:3]])
    nodes = parse_subscription(sub)
    good = len(nodes) == 3
    failed += 0 if good else 1
    print(f"  [{'PASS' if good else 'FAIL'}] 订阅解析（{len(nodes)}/3 个节点）")

    # base64 订阅
    b64sub = base64.b64encode(sub.encode()).decode()
    nodes = parse_subscription(b64sub)
    good = len(nodes) == 3
    failed += 0 if good else 1
    print(f"  [{'PASS' if good else 'FAIL'}] base64 订阅（{len(nodes)}/3）")

    print(f"\n自检: {'PASS' if failed == 0 else str(failed) + ' 项失败'}")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]

    if cmd == "selftest":
        return selftest()

    raw = sys.stdin.read() if (len(argv) > 2 and argv[2] == "-") else ""
    if not raw and len(argv) > 2:
        arg = argv[2]
        if os.path.isfile(arg):      # v2 fix: 支持 node.py multi <file> 直接读文件
            raw = open(arg, encoding="utf-8", errors="replace").read()
        else:
            raw = arg
    if not raw:
        print("缺少输入", file=sys.stderr)
        return 2

    try:
        if cmd == "parse":
            print(dump(parse_node(raw)))
        elif cmd == "multi":
            print(json.dumps(parse_many(raw), ensure_ascii=False))
        elif cmd == "subscription":
            nodes = parse_subscription(raw)
            print(json.dumps(nodes, ensure_ascii=False, indent=2))
        elif cmd == "field":
            node = parse_node(raw)
            print(node.get(argv[3], "") if len(argv) > 3 else "")
        elif cmd == "detect":
            print(detect_format(raw))
        else:
            print(f"未知子命令: {cmd}", file=sys.stderr)
            return 2
    except Exception as exc:
        print(f"解析失败: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv))
