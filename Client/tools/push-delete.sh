#!/usr/bin/env bash
# ============================================================================
#  仅删除 Client/ 目录内的废弃文件
# ============================================================================
#  为什么单做这个脚本：GitHub Contents API 的删除是"按路径直接删"，没有回收站。
#  仓库里还有别人的脚本（reality_xray.sh、nginx.sh 等），误删就是灾难。
#  所以这里：
#    * 每一次删除前都强制校验路径必须以 "Client/" 开头，否则直接中止；
#    * 支持 --dry-run 先列出要删什么、各自的 sha；
#    * 删完核对仓库根目录项数未变（证明没碰 Client/ 之外的东西）。
#
#  用法:
#    GITHUB_TOKEN=xxx bash tools/push-delete.sh --dry-run
#    GITHUB_TOKEN=xxx bash tools/push-delete.sh
# ============================================================================
set -uo pipefail

REPO="${XBD_REPO:-mi1314cat/xary-core}"
BRANCH="${XBD_BRANCH:-main}"
API="https://api.github.com/repos/$REPO"
ONLY_PREFIX="Client/"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# 要删除的路径（相对仓库根）。只允许 Client/ 下的。
TARGETS=(
  "Client/1"                 # 1 字节占位文件（内容就是换行），早期残留
  "Client/docs/RUN.md"       # 与根 RUN.md 字节完全相同的纯冗余副本
)

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  TF="${XDG_CONFIG_HOME:-$HOME/.config}/xbd-push.token"
  [ -f "$TF" ] && TOKEN=$(tr -d ' \t\r\n' < "$TF")
fi
if [ -z "$TOKEN" ]; then
  printf 'GitHub PAT（输入不回显）: ' >&2
  read -rs TOKEN </dev/tty; echo >&2
fi
[ -n "$TOKEN" ] || { echo "没有 token，退出" >&2; exit 1; }

api() {  # api <METHOD> <PATH> [JSON_BODY]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "$body" ]; then
    printf '%s' "$body" | curl -sS --max-time 120 -X "$m" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      --data-binary @- "$API$p"
  else
    curl -sS --max-time 120 -X "$m" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$API$p"
  fi
}

echo "=== 清理 $REPO 的 $ONLY_PREFIX 内废弃文件（分支 $BRANCH）==="

ROOT_BEFORE=$(api GET "/contents/?ref=$BRANCH" | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(-1)')
echo "  删除前仓库根目录项数: $ROOT_BEFORE"

fail=0
for t in "${TARGETS[@]}"; do
  # ---- 硬保护：绝不允许越出 Client/ ----
  case "$t" in
    "$ONLY_PREFIX"*) : ;;
    *) echo "  ✗ 拒绝：路径 '$t' 不在 $ONLY_PREFIX 下，跳过" >&2; fail=$((fail+1)); continue ;;
  esac
  case "$t" in
    *..*|/*) echo "  ✗ 拒绝：路径 '$t' 含可疑片段，跳过" >&2; fail=$((fail+1)); continue ;;
  esac

  meta=$(api GET "/contents/$t?ref=$BRANCH")
  sha=$(printf '%s' "$meta" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("sha") or "")
except Exception: print("")')
  if [ -z "$sha" ]; then
    printf '  — %-28s 不存在（无需删除）\n' "$t"
    continue
  fi
  size=$(printf '%s' "$meta" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("size"))
except Exception: print("?")')
  printf '  · %-28s %s 字节  sha=%.10s…\n' "$t" "$size" "$sha"

  if [ "$DRY" -eq 1 ]; then
    continue
  fi
  resp=$(api DELETE "/contents/$t" "{\"message\":\"Client: 删除废弃文件 $t\",\"sha\":\"$sha\",\"branch\":\"$BRANCH\"}")
  ok=$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print("ok" if d.get("commit") else "ERR:"+str(d.get("message")))
except Exception: print("badjson")')
  if [ "$ok" = "ok" ]; then
    printf '    ✓ 已删除\n'
  else
    printf '    ✗ 删除失败: %s\n' "$ok"; fail=$((fail+1))
  fi
done

if [ "$DRY" -eq 1 ]; then
  echo
  echo "  --dry-run：没有删除任何东西。"
  exit 0
fi

echo
ROOT_AFTER=$(api GET "/contents/?ref=$BRANCH" | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(-1)')
echo "  删除后仓库根目录项数: $ROOT_AFTER（应与删除前相同 = $ROOT_BEFORE）"
if [ "$ROOT_BEFORE" = "$ROOT_AFTER" ]; then
  echo "  ✓ 仓库根目录未被改动 —— 只动了 $ONLY_PREFIX 内的东西"
else
  echo "  ✗ 根目录项数变了！请立刻检查" >&2; fail=$((fail+1))
fi

echo
echo "=== $ONLY_PREFIX 现状 ==="
api GET "/contents/$ONLY_PREFIX?ref=$BRANCH" | python3 -c '
import sys,json
d=json.load(sys.stdin)
if isinstance(d,dict): print("  ",d.get("message"))
else:
    for e in sorted(d,key=lambda x:x["name"]): print(f"  {e[\"type\"]:5s} {e[\"name\"]:32s} {e.get(\"size\",\"\")}")
    print("  共",len(d),"项")'

[ "$fail" -eq 0 ]
