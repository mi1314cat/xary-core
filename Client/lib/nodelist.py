#!/usr/bin/env python3
"""节点列表渲染：显示两种使用方式的能力，而不是只给一个模糊状态。"""
from __future__ import annotations

import json
import os
import sys

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")

LABEL = {
    "SUPPORTED": "支持",
    "SUPPORTED_WITH_WARNING": "支持!",
    "NOT_SUPPORTED": "不支持",
    "UNKNOWN": "未知",
}


def load_compat_module():
    path = os.path.join(PREFIX, "xbd-dist", "lib", "compat.py")
    import importlib.util
    spec = importlib.util.spec_from_file_location("_xbd_compat", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    state_py = os.path.join(PREFIX, "xbd-dist", "lib", "state.py")
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("_xbd_state", state_py)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        nodes = mod.nodes_dir()[0]
    except Exception as exc:
        print(f"  读取节点失败: {exc}", file=sys.stderr)
        return 1

    if not nodes:
        print('  还没有节点。用: xbd node add "<uri>"')
        return 1

    # 判定一律**实时计算**，不用文件里可能过期的 _compat 缓存。
    # 为什么：缓存是导入那一刻写下的，之后 Xray 升级或判定逻辑改了它不会更新 ——
    # 于是两个内容完全相同的节点会一个显示"支持"、一个显示"不支持"（实测踩过），
    # 而被信以为真的恰恰是那个错的旧值。
    compat_mod = None
    for n in nodes:
        try:
            if compat_mod is None:
                compat_mod = load_compat_module()
            path = os.path.join(PREFIX, "nodes", n["file"])
            n["compat"] = compat_mod.check_all(json.load(open(path)))
        except Exception:
            n["compat"] = {}

    head = f'{"#":<4}{"":<3}{"名称":<30}{"协议":<13}{"传输":<11}{"Xray":<11}Browser Dialer'
    print("  " + head)
    print("  " + "-" * (len(head) - 6))
    for i, n in enumerate(nodes, 1):
        caps = n.get("compat") or {}
        x = (caps.get("xray") or {}).get("overall", "UNKNOWN")
        b = (caps.get("dialer") or {}).get("overall", "UNKNOWN")
        mark = "*" if n.get("current") else " "
        name = (n.get("name") or "?")[:28]
        print(f'  {i:<4}{mark:<3}{name:<30}{n.get("protocol",""):<13}'
              f'{n.get("transport",""):<11}{LABEL.get(x,x):<11}{LABEL.get(b,b)}')
    print("  (* = 当前节点)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
