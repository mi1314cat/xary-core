#!/usr/bin/env bash
# ============================================================================
#  Xray Client 一键部署
# ============================================================================
#  用法（推荐）：
#      bash <(curl -Ls https://raw.githubusercontent.com/mi1314cat/xary-core/main/Client/l.sh)
#
#  带节点（非交互）：
#      bash <(curl -Ls .../Client/l.sh) --vless "vless://..." --yes
#
#  它做四件事：
#      1. 下载 Client/xbd-client.tar.gz（单个压缩包，比逐文件下载快得多）
#      2. 校验 SHA256 后解压到临时目录
#      3. 调用包内 RUN.sh 完成安装
#      4. 输出状态与局域网连接地址
#
#  环境变量：
#      XBD_PREFIX      安装目录（默认 /opt/xray-browser-dialer）
#      XBD_REF         分支/标签（默认 main）
#      XBD_ARCHIVE     自定义压缩包地址
# ============================================================================
set -uo pipefail

REPO="mi1314cat/xary-core"
REF="${XBD_REF:-main}"
SUBDIR="Client"
# 归档双格式：优先 .tar.xz（小约 22%），本机没有 xz 命令就回退 .tar.gz。
# 刻意保留 gzip 回退：xz 在多数发行版都有，但 Alpine 精简镜像可能缺，
# 宁可多传一个包，也不要让"装不上"这种事发生。
if command -v xz >/dev/null 2>&1; then
  ARCHIVE_NAME="xbd-client.tar.xz"
  TAR_FLAG="-J"
else
  ARCHIVE_NAME="xbd-client.tar.gz"
  TAR_FLAG="-z"
fi
PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
LOG="/tmp/xbd-deploy-$(date +%H%M%S).log"

MIRROR_DIRS=(
  "https://raw.githubusercontent.com/$REPO/$REF/$SUBDIR"
  "https://cdn.jsdelivr.net/gh/$REPO@$REF/$SUBDIR"
  "https://github.com/$REPO/raw/refs/heads/$REF/$SUBDIR"
)
ARCHIVE_URL="${XBD_ARCHIVE:-${MIRROR_DIRS[0]}/$ARCHIVE_NAME}"
SHA_URL="$ARCHIVE_URL.sha256"

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; O=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; D=""; O=""
fi
info() { printf '%s\n' "$*" | tee -a "$LOG"; }
dim()  { printf '%s%s%s\n' "$D" "$*" "$O" | tee -a "$LOG"; }
ok()   { printf '%s✓%s %s\n' "$G" "$O" "$*" | tee -a "$LOG"; }
warn() { printf '%s!%s %s\n' "$Y" "$O" "$*" | tee -a "$LOG"; }
bad()  { printf '%s✗%s %s\n' "$R" "$O" "$*" | tee -a "$LOG"; }
step() { printf '\n%s==>%s %s\n' "$B" "$O" "$*" | tee -a "$LOG"; }
die()  { bad "$*"; info "日志: $LOG"; exit 1; }

WORKDIR=""
cleanup() { [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

PASS_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --vless)    PASS_ARGS+=(--vless "${2:-}"); shift 2 ;;
    --yes|-y)   PASS_ARGS+=(--yes); shift ;;
    --no-start) PASS_ARGS+=(--no-start); shift ;;
    --ref)
      REF="${2:-}"
      MIRROR_DIRS=(
        "https://raw.githubusercontent.com/$REPO/$REF/$SUBDIR"
        "https://cdn.jsdelivr.net/gh/$REPO@$REF/$SUBDIR"
        "https://github.com/$REPO/raw/refs/heads/$REF/$SUBDIR"
      )
      ARCHIVE_URL="${MIRROR_DIRS[0]}/$ARCHIVE_NAME"
      SHA_URL="$ARCHIVE_URL.sha256"
      shift 2 ;;
    --prefix)   PREFIX="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Xray Client 一键部署

  --vless "<链接>"   部署后直接导入节点
  --yes, -y          全自动不交互
  --no-start         只部署不启动
  --ref <分支>       拉取指定分支（默认 $REF）
  --prefix <目录>    安装目录（默认 $PREFIX）

  XBD_ARCHIVE=<url>  自定义压缩包地址
EOF
      exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

step "环境检查"
[ "$(id -u)" -eq 0 ] || die "需要 root 权限"
[ -d /run/systemd/system ] || die "本系统没有运行 systemd"

missing=()
for c in curl python3 tar ss ip systemctl awk sha256sum; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ ${#missing[@]} -gt 0 ]; then
  info "  安装缺少的命令: ${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >>"$LOG" 2>&1 || true
    apt-get install -y -qq curl python3 tar iproute2 coreutils systemd >>"$LOG" 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl python3 tar iproute coreutils systemd >>"$LOG" 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl python3 tar iproute2 coreutils >>"$LOG" 2>&1 || true
  fi
  missing=()
  for c in curl python3 tar ss ip systemctl awk sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [ ${#missing[@]} -eq 0 ] || die "仍缺少: ${missing[*]}"
fi
ok "基础命令齐全"
ok "架构: $(uname -m)  发行版: $(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"

[ -x "$PREFIX/bin/xbd" ] && warn "检测到已安装（$PREFIX），将执行更新"

CURL_MODE=()
detect_proxy() {
  local p
  for p in 10808 7890 10809 1080; do
    timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$p" 2>/dev/null && { printf 'http://127.0.0.1:%s' "$p"; return 0; }
  done
  return 1
}
probe_channel() {
  if timeout 8 curl -fsS --max-time 8 -o /dev/null "$ARCHIVE_URL" 2>/dev/null; then
    CURL_MODE=(); dim "  下载通道: 直连"; return 0
  fi
  local proxy; proxy=$(detect_proxy 2>/dev/null || true)
  if [ -n "$proxy" ] && timeout 12 curl -fsS --max-time 12 -x "$proxy" -o /dev/null "$ARCHIVE_URL" 2>/dev/null; then
    CURL_MODE=(-x "$proxy"); dim "  下载通道: 本机代理 $proxy"; return 0
  fi
  CURL_MODE=()
  warn "  下载通道探测未成功，仍尝试直连"
}
fetch() { curl -fsSL --connect-timeout 8 --max-time 180 --retry 1 --retry-delay 1 "${CURL_MODE[@]}" -o "$2" "$1" 2>>"$LOG"; }

# 逐个镜像试。为什么不是"主 + 一个备用"：
#   实测这台机器（CN 网络）直连 github.com **直接卡死** —— 既不报错也不返回，
#   一直挂到超时。而 raw.githubusercontent.com 1 秒就下完。
#   单一地址会让"装不上"看起来像脚本坏了；链式 + 快速失败才能给出有用信息。
fetch_any() {   # $1=包内文件名  $2=输出路径
  local name="$1" out="$2" u
  for u in "${MIRROR_DIRS[@]}"; do
    if fetch "$u/$name" "$out" && [ "$(wc -c < "$out" 2>/dev/null || echo 0)" -gt 0 ]; then
      dim "  来源: $u"
      return 0
    fi
    warn "  镜像不通: $u"
  done
  return 1
}

step "下载发布包"
WORKDIR=$(mktemp -d /tmp/xbd-deploy-XXXXXX)
[ -n "$WORKDIR" ] || die "无法创建临时目录"
TARBALL="$WORKDIR/$ARCHIVE_NAME"

probe_channel
if ! fetch_any "$ARCHIVE_NAME" "$TARBALL"; then
  die "所有镜像都下载失败（${MIRROR_DIRS[*]}）—— 检查网络，或用 XBD_ARCHIVE 指定其它地址"
fi

size=$(wc -c < "$TARBALL" 2>/dev/null || echo 0)
[ "$size" -gt 10000 ] || die "下载内容异常（$size 字节）"
ok "已下载 $(du -h "$TARBALL" | cut -f1)"

step "校验完整性"
got=$(sha256sum "$TARBALL" | awk '{print $1}')
if fetch_any "$ARCHIVE_NAME.sha256" "$WORKDIR/.sha" 2>/dev/null && [ -s "$WORKDIR/.sha" ]; then
  want=$(tr -d ' \n\r' < "$WORKDIR/.sha")
  if [ "$want" = "$got" ]; then
    ok "SHA256 校验通过"
  else
    die "SHA256 不匹配（期望 ${want:0:16}… 实际 ${got:0:16}…），已中止"
  fi
else
  warn "未取到 .sha256，跳过校验（本地值 ${got:0:16}…）"
fi

step "解压"
mkdir -p "$WORKDIR/src"
# shellcheck disable=SC2086
tar x${TAR_FLAG#-}f "$TARBALL" -C "$WORKDIR/src" \
  || die "解压失败（压缩包可能损坏，或缺少 ${ARCHIVE_NAME##*.} 解压工具）"
[ -f "$WORKDIR/src/RUN.sh" ] || die "压缩包结构异常：缺少 RUN.sh"
ok "已解压"

step "开始安装"
XBD_PREFIX="$PREFIX" bash "$WORKDIR/src/RUN.sh" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "安装未完成（退出码 $rc）"
  info "日志: $LOG"
  exit "$rc"
fi

echo
step "部署结果"
XBD_PREFIX="$PREFIX" "$PREFIX/bin/xbd" status 2>&1 | tee -a "$LOG" || true

P_HOST=$(awk -F= '/^LISTEN_ADDR=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || echo "")
P_SOCKS=$(awk -F= '/^PORT_NORMAL=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || echo 1080)
P_HTTP=$(awk -F= '/^PORT_LAN_HTTP=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || echo 10809)

echo
info "=========================================="
info " Xray Client 部署完成"
info "=========================================="
if [ -n "$P_HOST" ]; then
  info " 局域网设备可连接："
  info "   SOCKS5   $P_HOST:$P_SOCKS"
  info "   HTTP     $P_HOST:$P_HTTP"
  info ""
fi
info " 常用命令："
info "   xbd status           查看状态"
info "   xbd node add \"<链接>\"  添加节点"
info "   xbd dialer on|off    启用/关闭 Browser Dialer"
info "   xbd panel            面板地址与令牌"
info "   xbd diagnose         全面诊断"
info ""
info " 文档: $PREFIX/README.md"
info " 日志: $LOG"
info "=========================================="
