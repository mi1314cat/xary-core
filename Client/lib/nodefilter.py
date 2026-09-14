#!/usr/bin/env python3
"""导入分流：剔除 Xray 内核不支持的协议，并对重复节点去重。

为什么要有这一步 —— 用户一次可能贴一大段订阅，里面混着：
  * Xray 内核根本不支持的协议（tuic / hysteria v1 / 其它内核专属协议）；
  * 重复条目（订阅里很常见，同一份导入两次列表就翻倍，实测 9 个变 17 个）。

以前是一股脑儿落盘、只打标签，列表被灌满还得自己一个个看。现在默认：
不支持的跳过、重复的跳过（既与本批内比，也与已落盘的比），最后汇总说明跳了什么。

用法:
    nodefilter.py <解析出的节点数组.json> <lib目录> <是否保留不支持:0|1> <nodes目录>
输出:
    stdout  = 每行一个 JSON（要导入的节点）
    /tmp/.xbd_skipped.json = [[名字, 原因], ...] 供调用方汇总显示
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys

SKIPPED_PATH = "/tmp/.xbd_skipped.json"


def load_compat(libdir: str):
    spec = importlib.util.spec_from_file_location("c", os.path.join(libdir, "compat.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def ident(n: dict) -> str:
    """连接身份：协议 + 地址 + 端口 + 凭据 + 传输。

    用它判重，不看名字 —— 同一个节点在不同订阅里名字经常不一样，
    而连接参数才是"是不是同一个节点"的唯一依据。
    """
    cred = n.get("uuid") or n.get("password") or ""
    return "|".join(str(x) for x in (n.get("protocol"), n.get("address"),
                                     n.get("port"), cred, n.get("transport")))


def main(argv) -> int:
    if len(argv) < 5:
        print("用法: nodefilter.py <nodes.json> <libdir> <keep:0|1> <nodesdir>", file=sys.stderr)
        return 2
    src, libdir, keep, nodesdir = argv[1], argv[2], argv[3] == "1", argv[4]
    m = load_compat(libdir)

    seen: set = set()
    if os.path.isdir(nodesdir):
        for f in sorted(os.listdir(nodesdir)):
            if not (f.startswith("node-") and f.endswith(".json")):
                continue
            try:
                seen.add(ident(json.load(open(os.path.join(nodesdir, f), encoding="utf-8"))))
            except Exception:
                pass          # 坏文件不该阻断整批导入

    skipped = []
    try:
        incoming = json.load(open(src, encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"读取解析结果失败: {exc}", file=sys.stderr)
        return 2

    for n in incoming:
        caps = m.check_all(n)
        if not caps.get("can_use_xray") and not keep:
            skipped.append((n.get("name"), f"Xray 内核不支持该协议（{n.get('protocol')}）"))
            continue
        k = ident(n)
        if k in seen:
            skipped.append((n.get("name"), "与已有节点或本批前面的条目重复（同协议/地址/端口/凭据）"))
            continue
        seen.add(k)
        print(json.dumps(n, ensure_ascii=False))

    try:
        json.dump(skipped, open(SKIPPED_PATH, "w", encoding="utf-8"), ensure_ascii=False)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
