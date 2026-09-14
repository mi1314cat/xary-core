#!/usr/bin/env bash
# ============================================================================
#  自检：「接管本机」必须是**改配置**，不是新增一份来打架的配置
# ============================================================================
#  为什么要测：本机可能已经有别的服务（mihomo 之类）接管了系统代理。
#  我们再写一个 /etc/profile.d/proxy.sh 进去就是两份配置互相覆盖，
#  profile.d 按字典序 source，谁赢完全看文件名 —— 这种问题极难排查。
#
#  这个自检在真实 /etc 上造出"别人已经接管"的局面，跑真实的 xbd proxy on/off，
#  断言：① 就地改写别人的那份文件；② 不新增我们的文件；③ off 逐字节还原；
#  ④ 没有别人的接管时，仍然按老行为新建，off 时删干净。
#  跑完把 /etc 恢复成运行前的样子（trap 保证异常也能恢复）。
#
#  用法:  sudo bash tools/selftest-proxy.sh
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export XBD_PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"

PROFILE=/etc/profile.d/proxy.sh                                  # 我们的默认落点
DOCKER=/etc/systemd/system/docker.service.d/http-proxy.conf      # 我们的默认落点
OWNER_SH=/etc/profile.d/zz-xbd-selftest-owner.sh                 # 假装是 mihomo 写的
OWNER_DOCKER=/etc/systemd/system/docker.service.d/zz-xbd-selftest.conf
OWNER_ENV=/etc/environment
STATE=/var/lib/xbd-proxy
SAVE="$(mktemp -d)"

PASS=0; FAIL=0
ck() { # $1=名称 $2=实际 $3=期望
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n      期望: %s\n      实际: %s\n' "$1" "$3" "$2"; fi
}

# --- 快照/还原：把机器恢复成运行前的样子 -------------------------------------
snap() {   # $1=file → 在 SAVE 下留一份，或记录"当时不存在"
  local key; key="$(printf '%s' "$1" | tr '/' '_')"
  if [ -e "$1" ]; then cp -a "$1" "$SAVE/$key"; : > "$SAVE/$key.present"
  else rm -f "$SAVE/$key" "$SAVE/$key.present"; fi
}
unsnap() { # $1=file
  local key; key="$(printf '%s' "$1" | tr '/' '_')"
  if [ -e "$SAVE/$key.present" ]; then cp -a "$SAVE/$key" "$1"
  else rm -f "$1"; fi
}
FILES=("$PROFILE" "$DOCKER" "$OWNER_SH" "$OWNER_DOCKER" "$OWNER_ENV")
cleanup() {
  for f in "${FILES[@]}"; do unsnap "$f"; done
  rm -rf "$STATE/manifest"
  rm -f "$STATE"/*.orig
  [ "$FAIL" -eq 0 ] && rm -rf "$SAVE"
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || { echo "需要 root（要读写 /etc）"; exit 1; }
for f in "${FILES[@]}"; do snap "$f"; done

xbd() { bash "$ROOT/bin/xbd" "$@"; }
mkdir -p "$(dirname "$OWNER_SH")" "$(dirname "$OWNER_DOCKER")"

# ============================================================================
echo "== 0. 清场：确保从「没有我们、也没有别人」的状态开始 =="
rm -rf "$STATE"
xbd proxy off >/dev/null 2>&1
rm -f "$OWNER_SH" "$OWNER_DOCKER"
ck "proxy.sh 不存在"   "$([ -e "$PROFILE" ] && echo 有 || echo 无)" "无"
ck "docker conf 不存在" "$([ -e "$DOCKER" ] && echo 有 || echo 无)" "无"

# ============================================================================
echo "== 1. 造出「mihomo 已经接管了本机代理」的局面 =="
cat > "$OWNER_SH" <<'EOF'
# 假装这是 mihomo / 发行版脚本写的接管配置
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export NO_PROXY=localhost,127.0.0.1
# 这行不是代理变量，必须原样保留
export MIHOMO_HOME=/etc/mihomo
EOF
cat > "$OWNER_DOCKER" <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
EOF
cp -a "$OWNER_SH" "$SAVE/owner_sh.orig"
cp -a "$OWNER_DOCKER" "$SAVE/owner_docker.orig"
bash "$ROOT/bin/xbd" proxy status > "$SAVE/status.log" 2>&1
ck "status 报出两个接管点" "$(grep -c 'zz-xbd-selftest' "$SAVE/status.log")" "2"

# ============================================================================
echo "== 2. xbd proxy on：应该就地改别人的配置 =="
xbd proxy on > "$SAVE/on.log" 2>&1
ck "on 成功退出" "$?" "0"
ck "改的是 mihomo 那份 shell 配置" "$(grep -c '127.0.0.1:10808' "$OWNER_SH")" "5"
ck "没有新增 proxy.sh"             "$([ -e "$PROFILE" ] && echo 有 || echo 无)" "无"
ck "docker 改的是 mihomo 那份"     "$(grep -c '10808' "$OWNER_DOCKER")" "5"
ck "没有新增 docker 落点"          "$([ -e "$DOCKER" ] && echo 有 || echo 无)" "无"
ck "非代理行原样保留"              "$(grep -c 'MIHOMO_HOME' "$OWNER_SH")" "1"
ck "注释原样保留"                  "$(grep -c '假装这是 mihomo' "$OWNER_SH")" "1"
ck "归属登记 2 条"                 "$(wc -l < "$STATE/manifest")" "2"
ck "原文件已备份"                  "$(cat "$STATE"/_etc_profile.d_zz-xbd-selftest-owner.sh.orig | grep -c 7890)" "2"
ck "备份 == 原文"                  "$(cmp -s "$SAVE/owner_sh.orig" "$STATE"/_etc_profile.d_zz-xbd-selftest-owner.sh.orig && echo 同 || echo 异)" "同"

# ============================================================================
echo "== 3. xbd proxy off：应该逐字节还原别人的配置 =="
xbd proxy off > "$SAVE/off.log" 2>&1
ck "off 成功退出"       "$?" "0"
ck "mihomo 配置被还原"  "$(cmp -s "$SAVE/owner_sh.orig" "$OWNER_SH" && echo 同 || echo 异)" "同"
ck "docker 配置被还原"  "$(cmp -s "$SAVE/owner_docker.orig" "$OWNER_DOCKER" && echo 同 || echo 异)" "同"
ck "没有留下 proxy.sh"  "$([ -e "$PROFILE" ] && echo 有 || echo 无)" "无"
ck "manifest 已清理"    "$([ -e "$STATE/manifest" ] && echo 有 || echo 无)" "无"

# ============================================================================
echo "== 4. 本机没有别人接管时：仍然新建我们自己的文件 =="
rm -f "$OWNER_SH" "$OWNER_DOCKER"
xbd proxy on > "$SAVE/on2.log" 2>&1
ck "新建了 proxy.sh"    "$(grep -c '127.0.0.1:10808' "$PROFILE" 2>/dev/null)" "5"
ck "新建了 docker 落点" "$(grep -c '10808' "$DOCKER" 2>/dev/null)" "5"
ck "登记为 created"     "$(awk -F'\t' '$1=="created"' "$STATE/manifest" | wc -l)" "2"
xbd proxy off > "$SAVE/off2.log" 2>&1
ck "off 删掉了 proxy.sh" "$([ -e "$PROFILE" ] && echo 有 || echo 无)" "无"
ck "off 删掉了 docker"   "$([ -e "$DOCKER" ] && echo 有 || echo 无)" "无"

# ============================================================================
echo "== 5. /etc/environment 被人接管时：也改它，不新增 =="
cp -a "$OWNER_ENV" "$SAVE/env.orig" 2>/dev/null || : > "$SAVE/env.absent"
printf 'PATH="/usr/local/sbin:/usr/bin:/bin"\nhttp_proxy="http://127.0.0.1:7890"\n' > "$OWNER_ENV"
xbd proxy on > "$SAVE/on3.log" 2>&1
ck "/etc/environment 被就地改写" "$(grep -c '127.0.0.1:10808' "$OWNER_ENV")" "5"
ck "PATH 行保留"                 "$(grep -c '^PATH=' "$OWNER_ENV")" "1"
ck "shell 侧没人接管 → 新建 proxy.sh" "$([ -e "$PROFILE" ] && echo 有 || echo 无)" "有"
xbd proxy off > "$SAVE/off3.log" 2>&1
ck "/etc/environment 还原"       "$(grep -c '127.0.0.1:7890' "$OWNER_ENV")" "1"

# ============================================================================
if [ "$FAIL" -eq 0 ]; then
  printf '\n\033[32m全部通过\033[0m：%d 项断言\n' "$PASS"
  exit 0
fi
printf '\n\033[31m失败 %d 项\033[0m，通过 %d 项\n' "$FAIL" "$PASS"
echo "日志: $SAVE"
exit 1
