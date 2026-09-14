#!/usr/bin/env bash
# ============================================================================
#  Xray Client 卸载脚本（独立运行，不依赖面板）
# ============================================================================
#  用法：
#      bash uninstall-xray-client.sh              # 交互确认
#      bash uninstall-xray-client.sh --dry-run    # 只看会删什么，不动手
#      bash uninstall-xray-client.sh --yes        # 跳过确认
#      bash uninstall-xray-client.sh --keep-nodes # 保留节点配置
#
#  设计原则：宁可不删，也不删错。
#    * 只删除**本项目自己创建**的东西
#    * 每一项都做归属校验（内容指向本项目才删）
#    * 系统里别人的 Xray / mihomo / 配置一律不碰
#    * 删之前完整列出清单，默认需要手工确认
# ============================================================================
set -uo pipefail

PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
DEFAULT_PREFIX="/opt/xray-browser-dialer"
GLOBAL_BIN="/usr/local/bin/xbd"
PROFILE_PROXY="/etc/profile.d/proxy.sh"
DOCKER_PROXY="/etc/systemd/system/docker.service.d/http-proxy.conf"

DRY_RUN=0
ASSUME_YES=0
KEEP_NODES=0

# ---------------------------------------------------------------- 输出 ----
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; O=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; D=""; O=""
fi
info() { printf '%s\n' "$*"; }
dim()  { printf '%s%s%s\n' "$D" "$*" "$O"; }
ok()   { printf '%s✓%s %s\n' "$G" "$O" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$O" "$*"; }
bad()  { printf '%s✗%s %s\n' "$R" "$O" "$*"; }
step() { printf '\n%s==>%s %s\n' "$B" "$O" "$*"; }
die()  { bad "$*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --keep-nodes) KEEP_NODES=1; shift ;;
    --prefix)     PREFIX="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Xray Client 卸载

  --dry-run, -n    只显示将删除什么，不实际删除
  --yes, -y        跳过确认（脚本化用）
  --keep-nodes     保留节点配置（$PREFIX/nodes 备份到 /root）
  --prefix <目录>  指定安装目录（默认 $PREFIX）

只删除本项目创建的内容。系统里别人的 Xray / mihomo / 配置一律不动。
EOF
      exit 0 ;;
    *) die "未知参数: $1（用 --help 查看）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root 权限"

# ============================================================================
#  第一步：审计 —— 只收集"确实属于本项目"的候选项
# ============================================================================
step "扫查本项目的安装痕迹"

REMOVE_FILES=()      # 要删除的文件
REMOVE_DIRS=()       # 要删除的目录
REMOVE_UNITS=()      # 要停用并删除的 systemd 单元
KEEP_LIST=()         # 明确保留的东西（会打印出来）
WARNINGS=()

# ---- 1. 安装目录 ----------------------------------------------------------
if [ -d "$PREFIX" ]; then
  # 归属校验：目录里必须有本项目自己的标志文件，避免删错别人的目录
  marker=0
  for m in bin/xbd lib/actions.sh lib/core.sh xbd-dist/bin/xbd VERSION; do
    [ -e "$PREFIX/$m" ] && marker=1 && break
  done
  if [ "$marker" -eq 1 ]; then
    REMOVE_DIRS+=("$PREFIX")
  else
    WARNINGS+=("$PREFIX 存在但不像本项目目录（缺少标志文件），将跳过不删")
  fi
else
  dim "  安装目录不存在: $PREFIX"
fi

# ---- 2. systemd 单元 ------------------------------------------------------
# 只删我们的单元名。xray.service / xrayls.service 等一律不在名单里。
for u in xray-client.service chromium-browser-dialer.service \
         browser-dialer-panel.service browser-dialer-health.service browser-dialer-health.timer; do
  if [ -f "/etc/systemd/system/$u" ]; then
    REMOVE_UNITS+=("$u")
  fi
done

# ---- 3. 全局命令（必须指向本项目才删）-------------------------------------
if [ -e "$GLOBAL_BIN" ]; then
  if grep -q "$PREFIX/bin/xbd" "$GLOBAL_BIN" 2>/dev/null; then
    REMOVE_FILES+=("$GLOBAL_BIN")
  else
    # 指向别的路径（比如已删除的旧安装）—— 也属于本项目产物，但要提示
    target=$(grep -oE '/[^ "]*/bin/xbd' "$GLOBAL_BIN" 2>/dev/null | head -1)
    if [ -n "$target" ]; then
      REMOVE_FILES+=("$GLOBAL_BIN")
      WARNINGS+=("$GLOBAL_BIN 指向 $target（不是当前安装），也会一并清理")
    else
      WARNINGS+=("$GLOBAL_BIN 不是本项目创建的，跳过")
    fi
  fi
fi

# ---- 4. 本机代理配置（必须指向本项目端口才删）-----------------------------
HTTP_PORT=""
[ -f "$PREFIX/config/ports.env" ] && \
  HTTP_PORT=$(awk -F= '/^PORT_HTTP=/{print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null)
[ -n "$HTTP_PORT" ] || HTTP_PORT=$(awk -F= '/^PORT_HTTP=/{print $2; exit}' "$DEFAULT_PREFIX/config/ports.env" 2>/dev/null)
PORTS_RE="${HTTP_PORT:-10808}"

for f in "$PROFILE_PROXY" "$DOCKER_PROXY"; do
  [ -f "$f" ] || continue
  if grep -q "127.0.0.1:$PORTS_RE" "$f" 2>/dev/null; then
    REMOVE_FILES+=("$f")
  elif grep -q '127.0.0.1:7890' "$f" 2>/dev/null; then
    KEEP_LIST+=("$f（指向 mihomo 7890，不是本项目，保留）")
  else
    KEEP_LIST+=("$f（内容与本项目无关，保留）")
  fi
done

# ---- 5. nftables 透明接管规则 ---------------------------------------------
# 旧版本（有"接管局域网"模式时）会在 nftables 里留下 DNAT 规则。模式已移除，
# 但残留规则仍会劫持局域网的 80/443，所以这里必须继续清掉。
NFT_TABLE=""
if command -v nft >/dev/null 2>&1 && nft list table ip xbd_takeover >/dev/null 2>&1; then
  NFT_TABLE="xbd_takeover"
fi

# ---- 6. 备份节点（可选保留）-----------------------------------------------
NODES_BACKUP=""
if [ "$KEEP_NODES" -eq 1 ] && [ -d "$PREFIX/nodes" ]; then
  NODES_BACKUP="/root/xbd-nodes-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
fi

# ============================================================================
#  第二步：展示清单
# ============================================================================
step "将要删除"
if [ ${#REMOVE_UNITS[@]} -eq 0 ] && [ ${#REMOVE_FILES[@]} -eq 0 ] && [ ${#REMOVE_DIRS[@]} -eq 0 ] && [ -z "$NFT_TABLE" ]; then
  warn "没有发现本项目的安装痕迹"
  [ ${#KEEP_LIST[@]} -gt 0 ] && { info ""; info "保留项:"; for k in "${KEEP_LIST[@]}"; do info "  · $k"; done; }
  exit 0
fi

if [ ${#REMOVE_UNITS[@]} -gt 0 ]; then
  info "  systemd 单元（会先停止再禁用）:"
  for u in "${REMOVE_UNITS[@]}"; do
    info "    · /etc/systemd/system/$u"
  done
fi
if [ -n "$NFT_TABLE" ]; then
  info "  nftables 规则:"
  info "    · table ip $NFT_TABLE（旧版遗留的透明接管规则）"
fi
if [ ${#REMOVE_FILES[@]} -gt 0 ]; then
  info "  文件:"
  for f in "${REMOVE_FILES[@]}"; do info "    · $f"; done
fi
if [ -s /var/lib/xbd-proxy/manifest ]; then
  info "  被接管的代理配置（不是删除，是**还原成原样**）:"
  while IFS=$'\t' read -r act path; do
    [ -n "${path:-}" ] || continue
    info "    · $path  $([ "$act" = edited ] && echo '(还原原文件)' || echo '(本项目新建的)')"
  done < /var/lib/xbd-proxy/manifest
fi
if [ ${#REMOVE_DIRS[@]} -gt 0 ]; then
  info "  安装目录（含 Xray 内核、节点、日志、配置）:"
  for d in "${REMOVE_DIRS[@]}"; do
    info "    · $d/"
    dim "        $(du -sh "$d" 2>/dev/null | cut -f1)  $(find "$d" -type f 2>/dev/null | wc -l) 个文件"
  done
fi

step "不会被删除（别人的东西）"
info "  /etc/xray、/usr/local/etc/xray、/usr/local/share/xray"
info "  /usr/local/bin/xray（系统 Xray 二进制）"
info "  xray.service、xrayls.service（系统自带的 Xray 服务）"
info "  mihomo 及其配置、其它用户服务"
info "  防火墙默认策略、路由表"
for k in "${KEEP_LIST[@]:-}"; do
  [ -n "$k" ] && info "  $k"
done

if [ ${#WARNINGS[@]} -gt 0 ]; then
  step "注意"
  for w in "${WARNINGS[@]}"; do warn "  $w"; done
fi

if [ -n "$NODES_BACKUP" ]; then
  step "节点配置备份"
  info "  将备份到: $NODES_BACKUP"
fi

# ============================================================================
#  第三步：确认
# ============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  echo
  ok "仅预览模式（--dry-run），未做任何修改"
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  echo
  warn "以上内容将被永久删除，无法恢复。"
  if [ ${#REMOVE_DIRS[@]} -gt 0 ]; then
    warn "想保留节点配置请改用: bash $0 --keep-nodes"
  fi
  printf '确认删除？输入 yes 继续: '
  read -r ans
  [ "$ans" = "yes" ] || { info "已取消，未做任何修改"; exit 1; }
fi

# ============================================================================
#  第四步：执行
# ============================================================================
step "停止服务"
for u in "${REMOVE_UNITS[@]}"; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then
    systemctl stop "$u" 2>/dev/null && ok "已停止 $u" || warn "停止 $u 失败"
  fi
done

# 确认进程真的退出（尤其 Chromium 会有很多子进程）
if [ ${#REMOVE_UNITS[@]} -gt 0 ]; then
  for i in 1 2 3 4 5 6 7 8; do
    n=$(pgrep -c -f "$PREFIX" 2>/dev/null | head -1 || true)
    [ "${n:-0}" -eq 0 ] && break
    sleep 1
  done
fi

if [ -n "$NFT_TABLE" ]; then
  step "移除 nftables 规则"
  nft delete table ip "$NFT_TABLE" 2>/dev/null && ok "已移除 table ip $NFT_TABLE" || warn "移除失败"
fi

if [ -n "$NODES_BACKUP" ]; then
  step "备份节点配置"
  tar czf "$NODES_BACKUP" -C "$PREFIX" nodes 2>/dev/null \
    && ok "已备份到 $NODES_BACKUP" || warn "备份失败，节点将被删除"
fi

step "删除 systemd 单元"
for u in "${REMOVE_UNITS[@]}"; do
  systemctl disable "$u" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$u" && ok "已删除 $u"
done
[ ${#REMOVE_UNITS[@]} -gt 0 ] && { systemctl daemon-reload && ok "已 reload systemd"; }

# 清掉可能残留的 wants 链接
for u in "${REMOVE_UNITS[@]}"; do
  for d in /etc/systemd/system/multi-user.target.wants /etc/systemd/system/timers.target.wants; do
    [ -L "$d/$u" ] && rm -f "$d/$u" && dim "  清理残留链接 $d/$u"
  done
done

if [ ${#REMOVE_FILES[@]} -gt 0 ]; then
  step "删除文件"
  for f in "${REMOVE_FILES[@]}"; do
    rm -f "$f" && ok "已删除 $f"
  done
fi

# 本机代理可能不是写在"我们自己的文件"里 —— xbd proxy on 发现本机已有别的服务
# 在接管系统代理时会**就近改那一份**。那种情况不能删（那是别人的配置），要按备份
# 还原。这件事用 xbd proxy off 做（它读 /var/lib/xbd-proxy/manifest），
# 必须在删安装目录**之前**调用，因为 off 要用安装目录里的脚本。
XBD_BIN="$DEFAULT_PREFIX/bin/xbd"
if [ -f "$XBD_BIN" ] && [ -s /var/lib/xbd-proxy/manifest ]; then
  step "还原被接管的代理配置"
  "$XBD_BIN" proxy off 2>&1 | while IFS= read -r l; do dim "  $l"; done
fi
if [ -d /var/lib/xbd-proxy ]; then
  rm -rf /var/lib/xbd-proxy && dim "  已清理 /var/lib/xbd-proxy（原文件备份）"
fi

if [ ${#REMOVE_DIRS[@]} -gt 0 ]; then
  step "删除安装目录"
  for d in "${REMOVE_DIRS[@]}"; do
    # 脚本自身可能就在这个目录里：先复制到 /tmp 再执行删除，避免自我删除
    if [ -n "${BASH_SOURCE[0]:-}" ] && \
       [ "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" = "$(cd "$d" 2>/dev/null && pwd)" ]; then
      dim "  脚本位于该目录内，切换到 /tmp 后删除"
      cp -f "${BASH_SOURCE[0]}" /tmp/.xbd-uninstall.sh 2>/dev/null || true
      cd /tmp || true
    fi
    rm -rf "$d" && ok "已删除 $d/" || bad "删除 $d/ 失败"
  done
fi

# ============================================================================
#  第五步：验证
# ============================================================================
step "验证"
leftover=0

for u in "${REMOVE_UNITS[@]}"; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^$u"; then
    bad "单元仍存在: $u"; leftover=1
  fi
done
[ "$leftover" -eq 0 ] && ok "systemd 单元已清理干净"

for d in "${REMOVE_DIRS[@]}"; do
  [ -e "$d" ] && { bad "目录仍存在: $d"; leftover=1; }
done
for f in "${REMOVE_FILES[@]}"; do
  [ -e "$f" ] && { bad "文件仍存在: $f"; leftover=1; }
done
[ "$leftover" -eq 0 ] && ok "文件已清理干净"

if [ -n "$NFT_TABLE" ] && nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
  bad "nftables 规则仍存在"; leftover=1
else
  [ -n "$NFT_TABLE" ] && ok "nftables 规则已移除"
fi

echo
info "确认系统里别人的东西没被动过:"
for p in /usr/local/etc/xray /usr/local/share/xray /etc/systemd/system/xray.service \
         /etc/systemd/system/xrayls.service; do
  [ -e "$p" ] && info "  ✓ $p 完好" || info "  · $p 本来就不存在"
done
printf '  %s\n' "mihomo.service: $(systemctl is-active mihomo.service 2>/dev/null || echo 未安装)"

echo
if [ "$leftover" -eq 0 ]; then
  ok "卸载完成，已彻底清理"
else
  warn "卸载完成，但有残留（见上方 ✗ 项）"
fi
[ -n "$NODES_BACKUP" ] && info "节点配置备份: $NODES_BACKUP"
info ""
dim "如需重新安装："
dim "  bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/l.sh)"
