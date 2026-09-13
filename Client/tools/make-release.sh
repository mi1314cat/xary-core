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
for f in RUN.sh bin/xbd l.sh lib/actions.sh lib/node.py lib/genconfig.py \
         service/xray-client.service scripts/run-xray.sh; do
  [ -e "$HERE/$f" ] || { echo "缺少必需文件: $f" >&2; exit 1; }
done

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
    RUN.sh RUN.md l.sh bin lib service scripts docs tools VERSION README.md

sha256sum "$OUT" | awk '{print $1}' > "$OUT.sha256"

printf '已生成 %s\n' "$OUT"
printf '  大小   : %s\n' "$(du -h "$OUT" | cut -f1)"
printf '  SHA256 : %s\n' "$(cat "$OUT.sha256")"
printf '  内容   :\n'
tar tzf "$OUT" > "$OUT.list"
awk 'NR<=12 {print "    " $0}' "$OUT.list"
printf '    … 共 %s 项\n' "$(wc -l < "$OUT.list")"
rm -f "$OUT.list"
