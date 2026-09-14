#!/usr/bin/env bash
# ============================================================================
#  Client 发布打包脚本（在开发机上运行，产物提交到 /Client）
# ============================================================================
#  产出：
#      Client/xbd-client.tar.gz    可直接下载解压的发布包
#      Client/xbd-client.tar.gz.sha256
#  用法：
#      bash tools/make-release.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HERE/xbd-client.tar.gz"

# 校验必需文件，防止打出残缺包
for f in RUN.sh bin/xbd l.sh uninstall-xray-client.sh lib/actions.sh lib/node.py lib/genconfig.py \
         service/xray-client.service scripts/run-xray.sh tools/selftest-arch.sh; do
  [ -e "$HERE/$f" ] || { echo "缺少必需文件: $f" >&2; exit 1; }
done

# 已废弃的 dialer 实例单元绝不能被重新打进包 —— 它会把架构退回双实例
for f in service/xray-dialer.service lib/state.py; do
  case "$f" in
    service/xray-dialer.service) [ -e "$HERE/$f" ] && { echo "废弃文件不该存在: $f" >&2; exit 1; } ;;
  esac
done
grep -q 'xray-dialer' "$HERE/lib/actions.sh" && { echo "lib/actions.sh 仍引用 xray-dialer" >&2; exit 1; }
grep -q 'XRAY_BROWSER_DIALER' "$HERE/scripts/run-xray.sh" || { echo "run-xray.sh 没有 XRAY_BROWSER_DIALER" >&2; exit 1; }

bash -n "$HERE/tools/selftest-arch.sh" || { echo "selftest-arch.sh 语法错误" >&2; exit 1; }

cd "$HERE"
# 固定 mtime/gid/uid/owner：让同一份源码打出可复现的包
tar --sort=name \
    --mtime='2000-01-01 00:00:00' \
    --owner=0 --group=0 --numeric-owner \
    --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='xbd-client.tar.gz' --exclude='xbd-client.tar.gz.sha256' \
    --exclude='nodes' --exclude='runtime' --exclude='logs' \
    --exclude='generated' --exclude='backup' --exclude='config' \
    -czf "$OUT" \
    RUN.sh RUN.md l.sh uninstall-xray-client.sh bin lib service scripts docs tools VERSION README.md

sha256sum "$OUT" | awk '{print $1}' > "$OUT.sha256"

printf '已生成 %s\n' "$OUT"
printf '  大小   : %s\n' "$(du -h "$OUT" | cut -f1)"
printf '  SHA256 : %s\n' "$(cat "$OUT.sha256")"
printf '  内容   :\n'
tar tzf "$OUT" > "$OUT.list"
awk 'NR<=12 {print "    " $0}' "$OUT.list"
printf '    … 共 %s 项\n' "$(wc -l < "$OUT.list")"
rm -f "$OUT.list"
