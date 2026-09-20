#!/bin/bash
# =========================================================
# xary-core · unused/xray_install.sh
#
# 职责（仅此而已）：
#   1. 系统环境检查
#   2. 创建 Xray 基础目录
#   3. 安装 / 更新 Xray 内核 (xrayls)
#   4. 创建基础配置 00-base.json（零节点可运行）
#   5. 创建并维护 xrayls.service
#   6. 验证并启动
#
# Reality / XHTTP / WS / Nginx / Caddy / TLS 反代等
# 全部属于后续独立节点脚本职责，本脚本不做、不碰。
#
# 幂等性约定：
#   - 只管理自己的文件：00-base.json、xrayls.service、xrayls 内核
#   - 绝不删除 / 覆盖 conf/ 中的其他文件（10-*.json 等节点文件）
#   - 内核已安装且为最新版本时跳过下载，可直接当更新脚本执行
# =========================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

print_info()  { echo -e "${GREEN}[Info]${PLAIN} $1"; }
print_warn()  { echo -e "${YELLOW}[Warn]${PLAIN} $1"; }
print_error() { echo -e "${RED}[Error]${PLAIN} $1"; }

# ---------------------------------------------------------
# 固定路径（与项目全部脚本保持兼容，不得随意修改）
# ---------------------------------------------------------
INSTALL_DIR="${XRAY_INSTALL_DIR:-/root/catmi/xray}"
CONF_DIR="$INSTALL_DIR/conf"
LOG_DIR="$INSTALL_DIR/log"
OUT_DIR="$INSTALL_DIR/out"
BIN="$INSTALL_DIR/xrayls"
SERVICE_NAME="xrayls"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
XRAY_REPO_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_INSTALLER="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
BASE_CONF="$CONF_DIR/00-base.json"
STEP_TOTAL=6
TMP="/tmp/xray_install.$$"
mkdir -p "$TMP"
REL_TMP="$TMP/install-release.log"
UNZIP_OK=0
trap 'rm -rf "$TMP"' EXIT

die() {
    print_error "$1"
    print_error "失败命令：$2"
    print_error "建议排查：journalctl -u ${SERVICE_NAME} -b --no-pager"
    exit 1
}

# =========================================================
# [1/6] 系统环境检查
# =========================================================
S=0
section() {
    S=$((S + 1))
    echo -e "${GREEN}[$S/$STEP_TOTAL]${PLAIN} $1"
}

section "检查系统"

[[ $EUID -ne 0 ]] && { print_error "必须使用 root 用户运行此脚本。"; exit 1; }

if [[ "$(uname -s)" != "Linux" ]]; then
    print_error "仅支持 Linux 系统，当前为 $(uname -s)。"
    exit 1
fi

CPU_ARCH="$(uname -m)"
case "$CPU_ARCH" in
    x86_64|amd64|aarch64|arm64|s390x|ppc64le) ;;
    *) print_error "不支持的 CPU 架构：$CPU_ARCH（支持 x86_64 / aarch64 / s390x / ppc64le）"; exit 1 ;;
esac

if ! command -v systemctl >/dev/null 2>&1; then
    print_error "未检测到 systemctl，需要 systemd 环境。"
    exit 1
fi

if ! systemctl is-system-running >/dev/null 2>&1; then
    # degraded（常见于 VPS）可以继续；其他异常仅提示
    if ! systemctl is-system-running 2>&1 | grep -q "degraded"; then
        print_warn "systemd 未处于 running/degraded 状态，服务操作可能失败。"
    fi
fi

# 缺少必要命令时尝试用包管理器补齐
ensure_cmds() {
    local missing=()
    local c
    for c in cat curl awk sed grep sort tr mv chmod mkdir; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    ((${#missing[@]} == 0)) && return 0

    print_warn "缺少命令：${missing[*]}，尝试自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y curl coreutils gawk sed grep >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl coreutils gawk sed grep >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl coreutils gawk sed grep >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl coreutils gawk sed grep >/dev/null 2>&1
    fi
    for c in "${missing[@]}"; do
        command -v "$c" >/dev/null 2>&1 || die "缺少必要命令 '$c' 且自动安装失败" "请手动安装后重跑（如：apt install curl coreutils gawk）"
    done
}
ensure_cmds

print_info "系统检查通过（架构：${CPU_ARCH}）"

# =========================================================
# [2/6] 创建 Xray 基础目录
# =========================================================
section "创建目录"

mkdir -p "$CONF_DIR" "$LOG_DIR" "$OUT_DIR" \
    || die "无法创建基础目录" "mkdir -p $CONF_DIR $LOG_DIR $OUT_DIR"
print_info "目录就绪：$CONF_DIR / $LOG_DIR / $OUT_DIR"

# =========================================================
# [3/6] 安装 / 更新 Xray 内核
#       幂等：已安装且为最新版本时跳过；旧版本才更新
# =========================================================
section "安装 Xray 内核"

current_version() {
    [[ -x "$BIN" ]] && "$BIN" -version 2>/dev/null | awk 'NR==1{print $2; exit}'
}

latest_version() {
    local tag=""
    # 优先：GitHub API
    tag="$(curl -fsSL --max-time 15 "$XRAY_REPO_API" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4)"
    # 备用：跟随 releases/latest 重定向获取 tag
    [[ -z "$tag" ]] && tag="$(basename "$(curl -fsSL -o /dev/null -w '%{url_effective}' --max-time 15 https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null)")"
    echo "${tag#v}"
}

# arch -> Xray-core release 资产名映射
asset_arch() {
    case "$CPU_ARCH" in
        x86_64|amd64)  echo "Xray-linux-64.zip" ;;
        aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        s390x)         echo "Xray-linux-s390x.zip" ;;
        ppc64le)       echo "Xray-linux-ppc64le.zip" ;;
        *)             echo "" ;;
    esac
}

install_core() {
    command -v unzip >/dev/null 2>&1 && UNZIP_OK=1
    # 路径 A：官方 install-release.sh（首选）
    if bash -c "$(curl -fsSL "$XRAY_INSTALLER")" @ install >"$REL_TMP" 2>&1; then
        [[ -x /usr/local/bin/xray ]] || { print_error "官方安装脚本执行后 /usr/local/bin/xray 不存在"; return 1; }
        cp -f /usr/local/bin/xray "$BIN"
        chmod +x "$BIN"
        return 0
    fi
    tail -5 "$REL_TMP" 2>/dev/null

    # 路径 B（备用）：API 限流时直接下载 release zip 手工部署
    print_warn "官方安装脚本失败（可能为 GitHub API 限流），尝试直接下载 release 包 ..."
    local asset
    asset="$(asset_arch)"
    if [[ -z "$asset" ]]; then
        print_error "不支持的架构：$CPU_ARCH"; return 1
    fi
    if [[ "$UNZIP_OK" != "1" ]]; then
        print_error "缺少 unzip 且官方安装脚本失败，无法部署内核"; return 1
    fi
    local zip="$TMP/xray-core.zip"
    local ok=0 i
    for i in 1 2 3; do
        if curl -fL --max-time 300 -o "$zip" "https://github.com/XTLS/Xray-core/releases/download/v${LAT_VER}/${asset}" 2>>"$REL_TMP"; then
            ok=1; break
        fi
        sleep 2
    done
    if [[ $ok -ne 1 ]]; then
        print_error "release 包下载失败（版本 ${LAT_VER}，已重试 3 次），最近输出："
        tail -5 "$REL_TMP" 2>/dev/null
        return 1
    fi
    mkdir -p "$TMP/xray-pkg"
    unzip -o "$zip" xray geoip.dat geosite.dat -d "$TMP/xray-pkg" >>"$REL_TMP" 2>&1 \
        || { print_error "解压 release 包失败，详细输出：$REL_TMP"; return 1; }
    mv -f "$TMP/xray-pkg/xray" /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    cp -f /usr/local/bin/xray "$BIN"
    chmod +x "$BIN"
    return 0
}

CUR_VER="$(current_version)"
if [[ -x "$BIN" ]]; then
    print_info "已检测到内核：$BIN（版本 ${CUR_VER:-未知}）"
else
    print_info "未检测到内核，将执行全新安装"
fi

LAT_VER="$(latest_version)"
if [[ -z "$LAT_VER" ]]; then
    if [[ -x "$BIN" ]]; then
        print_warn "无法获取最新版本号（网络受限？），保留现有内核 ${CUR_VER}"
    else
        die "无法获取 Xray 最新版本号" "curl $XRAY_REPO_API"
    fi
else
    if [[ -n "$CUR_VER" && "$(printf '%s\n%s\n' "$LAT_VER" "$CUR_VER" | sort -V | tail -1)" == "$CUR_VER" ]]; then
        print_info "当前内核 ${CUR_VER} 已是最新版本（最新：${LAT_VER}），跳过下载"
    else
        print_info "开始安装/更新内核 ${CUR_VER:-无} -> ${LAT_VER}"
        if ! install_core; then
            die "Xray 内核安装/更新失败" "bash <(curl $XRAY_INSTALLER) @ install"
        fi
        print_info "内核已安装/更新至：$(current_version)"
    fi
fi

[[ -x "$BIN" ]] || die "内核二进制不存在：$BIN" "检查步骤 [3/6] 的输出"

# geo 数据由官方安装在 /usr/local/share/xray，供 geosite / geoip 路由使用
[[ -d /usr/local/share/xray ]] && export XRAY_LOCATION_ASSET=/usr/local/share/xray

# =========================================================
# [4/6] 创建基础配置（仅管理 00-base.json，绝不触碰节点文件）
# =========================================================
section "创建基础配置"

write_base_conf() {
    # 只含所有节点共同需要的基础内容：
    #   - 日志（access/error -> 项目日志目录，不硬编码其他位置）
    #   - 基础 outbound（tag "direct" / "block"，与现有节点脚本兼容）
    # 不含任何 inbound / UUID / Reality / WS / XHTTP / 端口 / 节点参数
    cat > "$BASE_CONF" <<EOF
{
  "log": {
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log",
    "loglevel": "warning"
  },
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF
}

if [[ -f "$BASE_CONF" ]]; then
    # 幂等：基础配置已存在则原样保留，仅校验 JSON 合法性
    if "$BIN" -test -config "$BASE_CONF" >/dev/null 2>&1; then
        print_info "基础配置已存在且合法，保持不变：$BASE_CONF"
    else
        print_warn "基础配置无法被当前内核解析，详细原因："
        "$BIN" -test -config "$BASE_CONF" 2>&1 | tail -5
        die "基础配置 $BASE_CONF 非法且拒绝自动覆盖（请手动修复或删除后重装）" "$BIN -test -config $BASE_CONF"
    fi
else
    write_base_conf
    print_info "已生成基础配置：$BASE_CONF（零节点即可运行）"
fi

# 未来节点脚本在自己的文件中声明 inbound / 路由：
#   e.g. 10-reality.json / 20-xhttp.json —— 本次绝不创建。

# =========================================================
# [5/6] 安装并维护 xrayls.service
#       幂等：内容一致不重写；否则写入并 daemon-reload + enable
# =========================================================
section "安装 systemd 服务"

gen_unit() {
    cat <<EOF
[Unit]
Description=${SERVICE_NAME} Service
After=network.target

[Service]
ExecStart=${BIN} -confdir ${CONF_DIR}
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

if [[ "$INSTALL_DIR" != "/root/catmi/xray" ]]; then
    # 测试模式：不允许污染真实服务
    print_warn "检测到 XRAY_INSTALL_DIR=$INSTALL_DIR（测试模式），跳过 systemd 安装与启动"
else
    TMP_UNIT=$(mktemp)
    gen_unit > "$TMP_UNIT"
    if [[ -f "$SERVICE_FILE" ]] && diff -q "$TMP_UNIT" "$SERVICE_FILE" >/dev/null 2>&1; then
        print_info "服务文件已是最新，无需修改"
    else
        gen_unit > "$SERVICE_FILE" || die "无法写入服务文件" "gen unit -> $SERVICE_FILE"
        systemctl daemon-reload || die "systemd daemon-reload 失败" "systemctl daemon-reload"
        print_info "服务文件已写入：$SERVICE_FILE"
    fi
    rm -f "$TMP_UNIT"

    if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
        print_warn "enable 失败（systemd 可能未完全可用），继续执行"
    fi
    print_info "服务已就绪并开机自启：${SERVICE_NAME}.service"
fi

# =========================================================
# [6/6] 配置验证并启动
# =========================================================
section "验证并启动"

# 1) 内核可执行
"$BIN" -version >/dev/null 2>&1 || die "内核无法执行：$BIN" "$BIN -version"

# 2) 基础配置存在且 JSON 合法
[[ -f "$BASE_CONF" ]] || die "缺少基础配置 $BASE_CONF" "检查步骤 [4/6]"
if ! "$BIN" -test -config "$BASE_CONF" >/dev/null 2>&1; then
    print_error "基础配置 $BASE_CONF 验证失败，原因："
    "$BIN" -test -config "$BASE_CONF" 2>&1 | tail -5
    die "基础配置验证失败" "$BIN -test -config $BASE_CONF"
fi

# 3) -confdir 整体测试（验证合并结果；旧节点文件语法错误会在此暴露）
if ! "$BIN" -confdir "$CONF_DIR" -test >/dev/null 2>&1; then
    print_error "confdir 整体配置测试失败（可能是某个具体配置文件语法问题）："
    "$BIN" -confdir "$CONF_DIR" -test 2>&1 | tail -8
    die "confdir 整体配置测试失败" "$BIN -confdir $CONF_DIR -test"
fi

# 4) 启动 / 重启 systemd 服务，并确认不会立即退出
if [[ "$INSTALL_DIR" == "/root/catmi/xray" ]]; then
    if ! systemctl restart "$SERVICE_NAME"; then
        systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | tail -15
        die "systemd 启动 ${SERVICE_NAME}.service 失败" "systemctl restart $SERVICE_NAME"
    fi
    sleep 3
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | tail -15
        print_error "服务启动后立即退出或未运行，请检查：journalctl -u ${SERVICE_NAME} -b --no-pager"
        die "服务未能保持运行" "systemctl status $SERVICE_NAME"
    fi
    print_info "服务运行中：systemctl status $SERVICE_NAME"
fi

echo -e "${GREEN}------------------------------${PLAIN}"
echo -e "${GREEN}Xray 内核安装完成${PLAIN}"
echo -e "配置目录：${CONF_DIR}"
echo -e "日志目录：${LOG_DIR}"
echo -e "服务：${SERVICE_NAME}.service"
echo -e "${GREEN}------------------------------${PLAIN}"
echo "提示：Reality / XHTTP / WS 等节点配置请使用对应独立节点脚本（写入 ${CONF_DIR}/ 下自己的文件，例如 10-*.json）。"
