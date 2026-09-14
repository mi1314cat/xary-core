#!/usr/bin/env python3
"""能力判定引擎的落地检查（纯本地断言，不发网络请求、不碰服务）。

为什么需要它：compat.py 的判定直接决定界面上"这个节点能不能用浏览器"。
判定一旦放宽或收紧错了，界面上完全看不出来 —— 要么把能用的节点标成不可用，
要么让用户点了必然失败的组合。这里把每条判定依据钉死。

判定依据全部来自 Xray 官方文档与源码（见 lib/compat.py 里的注释与实际链接）。

用法: python3 tools/selftest-compat.py
"""
from __future__ import annotations

import importlib.util
import os
import sys

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
for cand in (os.path.join(PREFIX, "xbd-dist", "lib"), os.path.join(PREFIX, "lib"),
             os.path.join(os.path.dirname(__file__), "..", "lib")):
    cand = os.path.abspath(cand)
    if os.path.exists(os.path.join(cand, "compat.py")):
        LIB = cand
        break
else:
    print("找不到 compat.py", file=sys.stderr)
    sys.exit(2)

spec = importlib.util.spec_from_file_location("_c", os.path.join(LIB, "compat.py"))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

passed = failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        print(f"  \033[32m✓\033[0m {label}")
        passed += 1
    else:
        print(f"  \033[31m✗\033[0m {label}\n      期望 {want!r}，实际 {got!r}")
        failed += 1


def node(**kw):
    base = {"protocol": "vless", "transport": "xhttp", "security": "tls",
            "address": "a.example", "port": 443, "sni": "a.example",
            "uuid": "u", "encryption": "none", "name": "t"}
    base.update(kw)
    return base


def bd(n):
    return c.check_all(n)["can_use_dialer"]


def xray(n):
    return c.check_all(n)["can_use_xray"]


print("=== 能力判定落地检查 ===")

# --- 1. 传输归一化：同一个传输的不同写法必须判成同一个结果 -------------------
print("\n[1] 传输别名归一化")
for alias in ("xhttp", "splithttp", "XHTTP"):
    check(f"transport={alias!r} 规范化为 xhttp", c.canon_transport(alias), "xhttp")
for alias, want in (("ws", "websocket"), ("websocket", "websocket"),
                    ("tcp", "raw"), ("raw", "raw"), ("kcp", "mkcp"), ("mkcp", "mkcp"),
                    ("splithttp", "xhttp")):
    check(f"transport={alias!r} → {want}", c.canon_transport(alias), want)

# 关键回归：曾经 ws/websocket 写法不同会被判成不同结果
check("ws 与 websocket 判定一致",
      bd(node(transport="ws")), bd(node(transport="websocket")))

# 别名表绝不能把内核已拒绝的值"洗"成合法值 —— 那会让界面把一个必然
# 起不来的节点显示成"支持"（h2/http/quic/gun 在 26.x 全被拒）。
for bogus in ("h2", "h3", "http", "quic", "gun", "boguszzz"):
    check(f"非法值 {bogus!r} 不被洗白", c.canon_transport(bogus) in c.XRAY_TRANSPORTS, False)

# --- 2. Browser Dialer 只支持两种传输 ---------------------------------------
# 官方 browser_dialer.md：浏览器只能发 HTTP(S)，所以仅支持 WebSocket 与 XHTTP
print("\n[2] 只支持 WebSocket 与 XHTTP（官方硬限制）")
check("xhttp 支持", bd(node(transport="xhttp")), True)
check("websocket 支持", bd(node(transport="websocket")), True)
check("xhttp 别名 splithttp 支持", bd(node(transport="splithttp")), True)
check("raw/tcp 不支持", bd(node(transport="tcp")), False)
check("grpc 不支持", bd(node(transport="grpc")), False)
check("h2 不支持", bd(node(transport="h2")), False)
check("httpupgrade 不支持", bd(node(transport="httpupgrade")), False)
check("mkcp 不支持", bd(node(transport="mkcp")), False)

# --- 3. REALITY 必须排除 ----------------------------------------------------
# splithttp/dialer.go:50 只在 realityConfig == nil 时启用 browser dialer
print("\n[3] REALITY 排除（源码 realityConfig == nil）")
check("xhttp+reality 不支持", bd(node(transport="xhttp", security="reality",
                                    reality_public_key="k")), False)

# --- 4. 官方硬要求 SNI == host == address ----------------------------------
# 官方原文：不能使用自定义 SNI 或者 Host，也就是说 SNI == host == address
print("\n[4] SNI == host == address（官方硬要求）")
check("三者一致 → 支持", bd(node(address="a.example", sni="a.example", host="a.example")), True)
check("sni 与 address 不一致 → 不支持", bd(node(address="a.example", sni="b.example")), False)
check("host 与 address 不一致 → 不支持", bd(node(address="a.example", host="b.example")), False)
check("host 与 sni 不一致 → 不支持", bd(node(address="a.example", sni="a.example", host="b.example")), False)
check("IP 字面量 → 不支持", bd(node(address="1.2.3.4", sni="", host="")), False)
check("未写 sni/host 时退回 address → 支持", bd(node(address="a.example", sni="", host="")), True)

# --- 5. vless encryption：mlkem 不该被误判 ---------------------------------
# 官方 vless.md 把 encryption 定义为 VLESS 加密（mlkem768x25519plus 等），
# 没有任何一处说它与浏览器转发不兼容 —— 所以不能判 NOT_SUPPORTED。
print("\n[5] vless encryption（官方无禁止性说明）")
MLKEM = "mlkem768x25519plus.native.0rtt.4CITIGkd1KI2w7oXdwkEzgY64MLHHfuS0CV"
check("encryption=none 支持", bd(node(encryption="none")), True)
check("mlkem768x25519plus 不因加密本身被否",
      c.check_all(node(encryption=MLKEM))["dialer"]["overall"] != c.NO, True)
check("mlkem 大小写不影响判定",
      bd(node(encryption=MLKEM.upper())), bd(node(encryption=MLKEM.lower())))
check("未知加密方案 → 不支持",
      bd(node(encryption="weird-scheme-x.abc")), False)

# --- 6. Xray 原生路径的判定 -------------------------------------------------
print("\n[6] Xray 原生路径")
check("vless+reality 原生可用", xray(node(security="reality", reality_public_key="k")), True)
check("hysteria2 原生可用", xray({"protocol": "hysteria2", "transport": "quic",
                                  "address": "h.example", "port": 443, "password": "p"}), True)
check("hysteria2 浏览器不可用", bd({"protocol": "hysteria2", "transport": "quic",
                                    "address": "h.example", "port": 443, "password": "p"}), False)
check("非 vless 协议浏览器不可用",
      bd(node(protocol="trojan", password="p")), False)

# --- 6b. 内核已删除的传输必须判死（否则整个实例起不来）---------------------
# 实测 26.3.27 报错：h2/http -> "HTTP transport ... has been removed"，
# quic -> "QUIC transport ... has been removed"，gun -> unknown transport。
# 这些值一旦被判"支持"，genconfig 就会写进配置，run-xray.sh 的 `xray run -test`
# 会 exit 1 —— 后果是**整个 Xray 实例起不来**，不是单节点失败。
print("\n[6b] 已删除的传输必须判死")
for bad in ("h2", "http", "quic", "h3", "gun"):
    check(f"transport={bad!r} 原生不可用", xray(node(transport=bad)), False)
check("transport='tcp' 原生可用（不能误报）", xray(node(transport="tcp")), True)
check("transport='ws' 原生可用", xray(node(transport="ws")), True)
check("transport='splithttp' 原生可用", xray(node(transport="splithttp")), True)

# --- 6c. REALITY 只能配 raw/xhttp/grpc -------------------------------------
# 实测报错原文：REALITY only supports RAW, XHTTP and gRPC for now.
print("\n[6c] REALITY × 传输组合（实测内核限制）")
check("reality + raw 可用", xray(node(transport="raw", security="reality", reality_public_key="k")), True)
check("reality + xhttp 可用", xray(node(transport="xhttp", security="reality", reality_public_key="k")), True)
check("reality + grpc 可用", xray(node(transport="grpc", security="reality", reality_public_key="k")), True)
check("reality + websocket 不可用", xray(node(transport="websocket", security="reality", reality_public_key="k")), False)
check("reality + mkcp 不可用", xray(node(transport="mkcp", security="reality", reality_public_key="k")), False)
check("reality + httpupgrade 不可用", xray(node(transport="httpupgrade", security="reality", reality_public_key="k")), False)

# --- 6d. security 只认 none/tls/reality ------------------------------------
# 实测报错：The feature Legacy XTLS has been removed.
print("\n[6d] 非法 security 必须判死（xtls 已移除）")
check("security='xtls' 不可用", xray(node(security="xtls")), False)
check("security='tls' 可用", xray(node(security="tls")), True)
check("security='none' 可用", xray(node(security="none")), True)

# --- 7. 版本门槛（官方 Badge：WS v1.4.1+ / XHTTP v1.8.19+）------------------
print("\n[7] 版本门槛（官方 Badge）")
check("WS 门槛 = 1.4.1", c.DIALER_MIN_VERSION.get("websocket"), (1, 4, 1))
check("XHTTP 门槛 = 1.8.19", c.DIALER_MIN_VERSION.get("xhttp"), (1, 8, 19))
check("版本解析 'Xray 26.3.27 (...)'", c.parse_version("Xray 26.3.27 (Xray, Penetrates Everything.)"), (26, 3, 27))
check("版本解析 1.8.19", c.parse_version("Xray 1.8.19"), (1, 8, 19))
check("本机版本 >= WS 门槛", c.xray_version() >= (1, 4, 1) if c.xray_version() else True, True)

# --- 8. 官方清单与源码一致 --------------------------------------------------
print("\n[8] 官方清单")
check("DIALER_TRANSPORTS 恰为 {xhttp, websocket}", set(c.DIALER_TRANSPORTS), {"xhttp", "websocket"})
check("安全取值含 none/tls/reality", {"none", "tls", "reality"} <= set(c.XRAY_SECURITIES), True)
for p in ("vless", "vmess", "trojan", "shadowsocks", "hysteria2"):
    check(f"代理协议含 {p}", p in c.XRAY_PROTOCOLS, True)

# --- 8b. WebSocket early data（?ed=）处理 -----------------------------------
# 规则（全部实测得出）：
#   * ed 只能通过 URL 查询串生效，写 wsSettings.ed / earlyData 等字段一律无效
#   * 缺 ed 时，Xray 发给内嵌页面的 WS 任务没有 extra 字段，页面读 task.extra.protocol
#     抛 TypeError，ws 节点在浏览器路径下必然失败
#   * 所以：用户写了就用用户的值；完全没写才补 2048（官方推荐值）
#   * 只对 websocket 生效，不能污染其它传输
print("\n[8b] WebSocket early data (?ed=)")
import subprocess as _sp, json as _json, tempfile as _tf
_GEN = os.path.join(LIB, "genconfig.py")
_NODE = os.path.join(LIB, "node.py")

def _gen_ws(yaml_text):
    """解析 YAML → 生成配置 → 返回 wsSettings（非 ws 传输返回 None）"""
    with _tf.TemporaryDirectory() as td:
        y = os.path.join(td, "n.yaml"); j = os.path.join(td, "n.json"); o = os.path.join(td, "c.json")
        open(y, "w").write(yaml_text)
        r = _sp.run([sys.executable, _NODE, "multi", "-"], stdin=open(y), capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            return None, None
        ns = _json.loads(r.stdout)
        _json.dump(ns[0], open(j, "w"), ensure_ascii=False)
        _sp.run([sys.executable, _GEN, "--node", j, "--output", o, "--mode", "normal",
                 "--listen", "127.0.0.1", "--port-normal", "19801", "--api-port", "19802",
                 "--logs", td], capture_output=True)
        if not os.path.exists(o):
            return None, ns[0]
        c = _json.load(open(o))
        return c["outbounds"][0]["streamSettings"].get("wsSettings"), ns[0]

_HDR = ("- name: t\n  type: vless\n  server: a.example\n  port: 443\n"
        "  uuid: 11111111-2222-3333-4444-555555555555\n  tls: true\n  network: ws\n  ws-opts:\n")

ws, model = _gen_ws(_HDR + "    path: /x\n    headers: {Host: a.example}\n")
check("没写 ed -> 自动补 2048", (ws or {}).get("path"), "/x?ed=2048")

ws, model = _gen_ws(_HDR + "    path: /x?ed=4096\n    headers: {Host: a.example}\n")
check("已写 ?ed=4096 -> 尊重用户的值", (ws or {}).get("path"), "/x?ed=4096")

ws, model = _gen_ws(_HDR + "    path: /x\n    ed: 1024\n    headers: {Host: a.example}\n")
check("写了 ed 字段 -> 用该值", (ws or {}).get("path"), "/x?ed=1024")

ws, model = _gen_ws(_HDR + "    path: /x\n    earlyData: 512\n    headers: {Host: a.example}\n")
check("写了 earlyData -> 用该值", (ws or {}).get("path"), "/x?ed=512")

# 同一份配置反复生成必须稳定，不能拼出 ?ed=2048?ed=2048
ws, _ = _gen_ws(_HDR + "    path: /x?ed=2048\n    headers: {Host: a.example}\n")
check("已有 ed 时不会重复拼接", (ws or {}).get("path").count("ed="), 1)

# 非 ws 传输绝不能被加 ed
ws, _ = _gen_ws("- name: t\n  type: vless\n  server: a.example\n  port: 443\n"
                "  uuid: 11111111-2222-3333-4444-555555555555\n  tls: true\n  network: xhttp\n"
                "  xhttp-opts: {path: /x}\n")
check("xhttp 不受影响（无 wsSettings）", ws, None)

# --- 9. ECH 探针的判据（不看真实 netlog，只钉住"不许退回旧写法"）-----------
# 旧写法有三个已证实的缺陷，这里防止它们被改回去：
#   1) 用正则按字节位置猜 host（不是证据）
#   2) 只看 encrypted_client_hello —— 该字段只出现在 TLS-over-TCP，
#      节点走 QUIC 时必然假阴性（实测 5 次里 2 次）
#   3) xray_self_dials 用 Info 级日志，而诊断跑在 warning 级 —— 恒为 0，是空指标
print("\n[9] ECH 探针判据")
import importlib.util as _iu
_ech = os.path.join(LIB, "echcli.py")
if os.path.exists(_ech):
    _spec = _iu.spec_from_file_location("_ech", _ech)
    _m = _iu.module_from_spec(_spec); _spec.loader.exec_module(_m)
    check("有容错事件读取（应对截断 netlog）", hasattr(_m, "_load_events"), True)
    check("判据用 privacy_mode", "privacy_mode" in open(_ech, encoding="utf-8").read(), True)
    src = open(_ech, encoding="utf-8").read()
    check("不再用'最近的前一个 host'猜归属", "def nearest(" not in src, True)
    check("已标注 xray_self_dials 是空指标", "恒为 0" in src, True)
    # 用一个合成 netlog 验证：只有 QUIC 连接（无 encrypted_client_hello）也必须判 ACTIVE
    import tempfile as _tf, json as _json
    fake = {"events": [
        {"type": 181, "source": {"id": 1}, "params": {
            "destination": "https://node.example", "using_quic": True}},
        {"type": 194, "source": {"id": 2}, "params": {
            "url": "https://node.example/x", "privacy_mode": "enabled"}},
        {"type": 8, "source": {"id": 3}, "params": {
            "results": {"endpoint_metadatas": [
                {"endpoint_metadata_value": {"ech_config_list": "A" * 96,
                                             "target_name": "node.example"}}]}}},
        {"type": 194, "source": {"id": 4}, "params": {
            "url": "http://127.0.0.1:18081/", "privacy_mode": "disabled"}},
    ]}
    with _tf.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        _json.dump(fake, fh); fn = fh.name
    try:
        r = _m.scan_netlog(fn, "node.example")
        check("纯 QUIC 连接（无 encrypted_client_hello）也判 ACTIVE",
              r["status"], "ECH_ACTIVE")
        check("到节点的连接识别为 QUIC", r["node_transport"], "quic")
        check("ECHConfig 归属到节点", r["ech_config_for_node"] >= 1, True)
    finally:
        os.unlink(fn)
else:
    print("  （找不到 echcli.py，跳过）")

print()
print("=" * 44)
if failed == 0:
    print(f"能力判定检查: PASS（{passed} 项）")
else:
    print(f"能力判定检查: FAIL（{failed} 失败 / {passed} 通过）")
print("=" * 44)
sys.exit(1 if failed else 0)
