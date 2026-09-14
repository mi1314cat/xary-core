#!/usr/bin/env bash
# ============================================================================
#  把 A/ 的内容推送到 GitHub 仓库的 Client/ 目录
# ============================================================================
#  为什么不用 git：
#    仓库里还有别的脚本（reality_xray.sh、nginx.sh 等）。用 git 就得把整个仓库
#    clone 下来、处理分支与合并，一不小心就把别人的东西带上去或覆盖掉。
#    这里只走 GitHub Contents API，**每一次写入的路径都被强制以 Client/ 开头**，
#    并且推送前会先列出"将要改动的文件"，越界直接中止。
#
#  凭据：
#    优先读环境变量 GITHUB_TOKEN；没有就读 $XDG_CONFIG_HOME/xbd-push.token；
#    都没有就交互式读取（不回显）。脚本从不打印 token 本身。
#
#  用法：
#    bash tools/push-client.sh --dry-run     # 只显示会改哪些文件，不写
#    bash tools/push-client.sh               # 真正推送
# ============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${XBD_REPO:-mi1314cat/xary-core}"
BRANCH="${XBD_BRANCH:-main}"
export XBD_BRANCH="$BRANCH"      # 下面的 Python 片段要用它拼 commit body，必须导出
PREFIX_PATH="Client"                     # 唯一允许写入的路径前缀
API="https://api.github.com/repos/$REPO"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

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
    curl -sS --max-time 120 -X "$m" -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$body" "$API$p"
  else
    curl -sS --max-time 120 -X "$m" -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$API$p"
  fi
}

jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

echo "=== 推送 $SRC → $REPO/$PREFIX_PATH（分支 $BRANCH）==="

# --- 0. 目录前缀白名单（硬保证：只动 Client/）-----------------------------
case "$PREFIX_PATH" in
  Client*) : ;;
  *) echo "拒绝：路径前缀必须是 Client/，当前 '$PREFIX_PATH'" >&2; exit 1 ;;
esac

# --- 1. 生成清单：路径\tsha\tsize（相对 Client/）--------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
LIST="$TMP/files.tsv"
cd "$SRC"
find bin lib service scripts docs tools -type f \
     \( -name '*.pyc' -o -path '*__pycache__*' \) -prune -o -type f -print 2>/dev/null > "$TMP/all"
printf '%s\n' README.md RUN.md RUN.sh l.sh uninstall-xray-client.sh VERSION \
              xbd-client.tar.gz xbd-client.tar.gz.sha256 >> "$TMP/all"
sort -u "$TMP/all" | while read -r f; do
  [ -f "$f" ] || continue
  case "$f" in *__pycache__*|*.pyc) continue ;; esac
  printf '%s\t%s\t%s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c %s "$f")"
done > "$LIST"
echo "  待推送文件: $(wc -l < "$LIST") 个，总计 $(du -ch $(cut -f1 "$LIST" | tr '\n' ' ') 2>/dev/null | tail -1 | cut -f1)"

# --- 2. 取远端 Client/ 全部文件的 blob sha（含子目录）--------------------
echo "  读取远端 $PREFIX_PATH/ 现状…"
REMOTE="$TMP/remote.tsv"; : > "$REMOTE"
walk() {  # walk <相对路径> ；递归列出文件
  local path="$1" out
  out=$(api GET "/contents/$PREFIX_PATH${path:+/$path}?ref=$BRANCH")
  printf '%s' "$out" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
if isinstance(d, dict):
    print("ERR\t" + str(d.get("message",""))); sys.exit(0)
for e in d:
    if e["type"] == "file":  print("F\t%s\t%s\t%s" % (e["path"], e["sha"], e.get("size",0)))
    elif e["type"] == "dir": print("D\t%s" % e["path"])
' 2>/dev/null | while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      F) printf '%s\t%s\t%s\n' "${a#$PREFIX_PATH/}" "$b" "$c" >> "$REMOTE" ;;
      D) walk "${a#$PREFIX_PATH/}" ;;
      ERR) echo "  ⚠ 读取 $a 失败: $b" >&2 ;;
    esac
  done
}
walk ""
echo "  远端现有: $(wc -l < "$REMOTE") 个文件"

# --- 3. 差异：谁要改、谁是新增（远端有而本地没有的**不删**，避免误删）------
CHANGED="$TMP/changed.tsv"; : > "$CHANGED"; new=0; mod=0; same=0
while IFS=$'\t' read -r f sha size; do
  rsha=$(awk -F'\t' -v k="$f" '$1==k{print $2; exit}' "$REMOTE")
  if [ -z "$rsha" ]; then printf 'NEW\t%s\t\t%s\n' "$f" "$size" >> "$CHANGED"; new=$((new+1))
  elif [ "$rsha" != "$sha" ]; then printf 'MOD\t%s\t%s\t%s\n' "$f" "$rsha" "$size" >> "$CHANGED"; mod=$((mod+1))
  else same=$((same+1)); fi
done < "$LIST"
echo
echo "  新增 $new / 修改 $mod / 未变 $same"
if [ -s "$CHANGED" ]; then
  echo "  --- 将要写入（全部在 $PREFIX_PATH/ 下）---"
  awk -F'\t' '{printf "    %-6s %s\n", $1, $2}' "$CHANGED" | head -60
else
  echo "  没有变化，无需推送"; exit 0
fi

if [ "$DRY" -eq 1 ]; then
  echo
  echo "  --dry-run：没有写入任何东西。"
  exit 0
fi

# --- 4. 逐个写入 ---------------------------------------------------------
echo
echo "  写入中…"
i=0; total=$(wc -l < "$CHANGED"); failed=0
while IFS=$'\t' read -r kind f rsha size; do
  i=$((i+1))
  target="$PREFIX_PATH/$f"
  case "$target" in "$PREFIX_PATH"/*) : ;; *) echo "  ✗ 越界路径，中止: $target" >&2; exit 1 ;; esac
  # base64 内容（GitHub 要求），大文件走同一条路
  body=$(python3 - "$SRC/$f" "$target" "$rsha" <<'PY'
import base64, json, sys, os
path, target, rsha = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path, "rb").read()
d = {"message": "Client: sync %s" % target, "content": base64.b64encode(content).decode(), "branch": os.environ["XBD_BRANCH"]}
if rsha: d["sha"] = rsha
print(json.dumps(d))
PY
)
  resp=$(api PUT "/contents/$target" "$body")
  ok=$(printf '%s' "$resp" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print("badjson"); sys.exit()
print("ok" if d.get("content") or d.get("commit") else "ERR:"+str(d.get("message")))')
  if [ "$ok" = "ok" ]; then
    printf '    [%d/%d] %s\n' "$i" "$total" "$target"
  else
    printf '    [%d/%d] ✗ %s → %s\n' "$i" "$total" "$target" "$ok"; failed=$((failed+1))
  fi
done < "$CHANGED"

echo
if [ "$failed" -eq 0 ]; then echo "  ✓ 全部推送完成（$total 个文件）"
else echo "  ✗ $failed 个文件失败"; fi

# --- 5. 结果核对 ---------------------------------------------------------
echo
echo "=== 核对：$PREFIX_PATH/ 现状 ==="
api GET "/contents/$PREFIX_PATH?ref=$BRANCH" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if isinstance(d,dict): print('  ', d.get('message'))
else:
    for e in sorted(d, key=lambda x:x['name']): print(f\"  {e['type']:5s} {e['name']:32s} {e.get('size','')}\")
    print('  共', len(d), '项')
"
echo
echo "=== 核对：仓库根目录未被改动（应仍为 18 项）==="
api GET "/contents/?ref=$BRANCH" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  根目录项数:', len(d))
names=[e['name'] for e in d]
print('  含 Client:', 'Client' in names)
"
[ "$failed" -eq 0 ]
