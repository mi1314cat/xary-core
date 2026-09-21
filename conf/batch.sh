#!/bin/bash
# ==============================================================
# batch.sh — X 内核 全协议一键生成 (Batch Generator)
# 设计思想对齐 sing-box-core 的 src/conf/batch.sh (Batch = Orchestrator):
#   * 不重新实现任何协议: 逐个调用现有 conf/<proto>.sh 的 add_config 流程
#   * 批量上下文: X_BATCH=1 (协议脚本问询走各自默认"最高配置") +
#                 X_BATCH_PORT_START/END (批量连续端口分配, 游标在 conf/.batch-ports)
#   * 幂等: conf/<proto>-NN.json 已存在 → 该协议跳过
#   * 失败隔离: 每个协议独立执行, 单协议失败不影响后续, 汇总时明确列出
#   * 统一验证+reload: 全部生成 → 复用 conf/verify.sh check → 通过后仅 reload 一次
#     (协议脚本本身从不 reload; reload 语义只属于 Batch 收尾)
#   * 复用输出: 节点信息 / 分享链接全部来自各协议脚本产出的 out/*-share-*.txt
# 批量协议列表(需新增协议时在此登记, 须与 conf/ 下脚本和其 PROTO 碎片名一一对应):
#   PROTO_LIST          -> conf/<name>.sh
#   PROTO_FRAGMENT_PFX  -> 该协议服务端碎片 conf/<pfx>-NN.json (幂等判断用)
# 注: 当前 OpenX 支持的全部交互式协议中, Argo 类(tunnel/固定/临时)依赖隧道交互流程,
#     SOCKS5/HTTP/VLESS 等裸协议按需由用户单发; Batch 默认只编排 4 个"最高配置"安全协议
# ==============================================================
set -u

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; MAGENTA="\e[35m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"
print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }
print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}
clean_input() { echo "$1" | tr -d '\000-\037'; }

GH_RAW="${X_BATCH_RAW:-https://github.com/mi1314cat/xary-core/raw/refs/heads/main}"

# 协议登记表: 批量协议脚本名 | 服务端碎片前缀(幂等判断) | 展示名
BATCH_PROTOS=(Reality Trojan Shadowsocks hysteria2)
BATCH_FRAG_PREFIX=(reality trojan ss2022 hysteria)

XRAY_BASE="${XRAY_BASE_DIR:-/root/catmi/xray}"
X_IS_SANDBOX=false
[[ "${XRAY_BASE_DIR:-/root/catmi/xray}" != "/root/catmi/xray" ]] && X_IS_SANDBOX=true
CONF_DIR="$XRAY_BASE/conf"
OUT_DIR="$XRAY_BASE/out"
LOG_DIR="${X_BATCH_LOG_DIR:-/tmp}"

########## 脚本目录解析 ##########
# 就近使用 batch.sh 同目录下的协议脚本 (仓库内/服务器临时部署);
# 否则(curl|bash 场景)从 GitHub 下载到临时目录再执行, 与面板其余选项一致
SCRIPT_DIR=""
resolve_scripts_dir() {
    local here
    here="$(dirname "${BASH_SOURCE[0]:-$0}")"
    if [[ -f "$here/Reality.sh" && -f "$here/Trojan.sh" ]]; then
        SCRIPT_DIR="$here"
        return 0
    fi
    local tmp="${X_BATCH_TMP_DIR:-/tmp/x-batch-scripts}"
    mkdir -p "$tmp"
    local f
    for f in "${BATCH_PROTOS[@]}"; do
        if [[ ! -s "$tmp/$f.sh" ]]; then
            curl -fsSL "$GH_RAW/conf/$f.sh" -o "$tmp/$f.sh" \
                || { print_error "下载 conf/$f.sh 失败"; return 1; }
            bash -n "$tmp/$f.sh" || { print_error "conf/$f.sh 语法错误(下载损坏)"; return 1; }
        fi
    done
    SCRIPT_DIR="$tmp"
    return 0
}

resolve_verify_sh() {
    if [[ -f "$XRAY_BASE/verify.sh" ]]; then echo "$XRAY_BASE/verify.sh"; return 0; fi
    local here
    here="$(dirname "${BASH_SOURCE[0]:-$0}")"
    if [[ -f "$here/verify.sh" ]]; then echo "$here/verify.sh"; return 0; fi
    local tmp="${X_BATCH_TMP_DIR:-/tmp/x-batch-scripts}/verify.sh"
    curl -fsSL "$GH_RAW/conf/verify.sh" -o "$tmp" 2>/dev/null || { print_error "下载 conf/verify.sh 失败"; return 1; }
    echo "$tmp"
}

fragment_prefix() {
    local i
    for i in "${!BATCH_PROTOS[@]}"; do
        [[ "${BATCH_PROTOS[$i]}" == "$1" ]] && { echo "${BATCH_FRAG_PREFIX[$i]}"; return; }
    done
    echo "$1"
}

latest_fragment() { ls "$CONF_DIR""/$(fragment_prefix "$1")"-*.json 2>/dev/null | sort | tail -1; }

########## 备份 ##########
backup_conf_out() {
    local ts tarball
    ts=$(date +%Y%m%d-%H%M%S)
    tarball="$XRAY_BASE/conf-backup-batch-$ts.tar.gz"
    tar czf "$tarball" -C "$XRAY_BASE" conf out 2>/dev/null || true
    [[ -f "$tarball" ]] && print_info "已备份 conf/out → $tarball"
}

########## 唯一交互: 端口范围 ##########
ask_port_range() {
    local r
    echo >&2
    printf "${CYAN}唯一交互: 监听端口分配范围。其余全部沿用各协议默认值（最高配置，自动生成密码/UUID/PSK/Reality 伪装域名）。${RESET}\n" >&2
    printf "${CYAN}批内多协议端口自动连续分配，收尾统一 check + 仅 reload 一次。${RESET}\n" >&2
    read -r -p "端口范围 (如 20000-25000, 回车=自动选择): " r >&2
    r=$(clean_input "$r")
    choose_port_range "$r"
}

choose_port_range() {
    local r="$1"
    if [[ -z "$r" ]]; then
        X_BATCH_PORT_START=$(( 20000 + RANDOM % 20000 ))
        X_BATCH_PORT_END=$(( X_BATCH_PORT_START + 2000 ))
        print_ok "批量自动端口区间: $X_BATCH_PORT_START-$X_BATCH_PORT_END"
    else
        X_BATCH_PORT_START="${r%%-*}"; X_BATCH_PORT_END="${r##*-}"
        [[ "$X_BATCH_PORT_START" =~ ^[0-9]+$ && "$X_BATCH_PORT_END" =~ ^[0-9]+$ ]] || { print_error "格式: 起始-结束"; return 1; }
        (( X_BATCH_PORT_START < X_BATCH_PORT_END && X_BATCH_PORT_START >= 1 && X_BATCH_PORT_END <= 65535 )) || { print_error "范围无效 (要求 起始 < 结束, 1-65535)"; return 1; }
    fi
    return 0
}

BATCH_OK=(); BATCH_SKIP=(); BATCH_FAIL=()

########## 主流程 ##########
batch_main() {
    mkdir -p "$CONF_DIR" "$OUT_DIR" "$LOG_DIR"
    resolve_scripts_dir || return 1

    print_title "X 内核 全协议一键生成"

    backup_conf_out
    rm -f "$CONF_DIR/.batch-ports"

    # 每协议: 已有节点 → 跳过(幂等); 否则 X_BATCH=1 调用现有协议脚本
    local proto frag file
    local -a ok_list=() skip_list=() fail_list=() new_files_before=()
    new_files_before=("$CONF_DIR"/*.json)

    echo >&2
    print_title "批量生成开始"
    for proto in "${BATCH_PROTOS[@]}"; do
        printf "${CYAN}• %-12s${RESET} " "$proto" >&2
        if [[ -n "$(latest_fragment "$proto")" ]]; then
            printf "${YELLOW}[已存在]${RESET} 跳过 (幂等)\n" >&2
            skip_list+=("$proto") && BATCH_SKIP+=("$proto")
            continue
        fi
        X_BATCH=1 X_NO_RELOAD=1 SB_BATCH=1 \
        X_BATCH_PORT_START="${X_BATCH_PORT_START:-}" X_BATCH_PORT_END="${X_BATCH_PORT_END:-}" \
            bash "$SCRIPT_DIR/$proto.sh" add </dev/null >"$LOG_DIR/x-batch-$proto.log" 2>&1
        if [[ $? -eq 0 ]]; then
            printf "${GREEN}[OK]${RESET} 生成\n" >&2
            ok_list+=("$proto") && BATCH_OK+=("$proto")
        else
            printf "${RED}[失败]${RESET} (详见 $LOG_DIR/x-batch-$proto.log)\n" >&2
            fail_list+=("$proto") && BATCH_FAIL+=("$proto")
        fi
    done

    # 本批新生成的服务端碎片(收尾失败清理用)
    local -a new_files=() f
    for f in "$CONF_DIR"/*.json; do
        local old
        for old in "${new_files_before[@]}"; do
            [[ "$old" == "$f" ]] && continue 2
        done
        new_files+=("$f")
    done

    # ---- 统一验证 (复用 conf/verify.sh 的 check, 不自行假设检查命令) ----
    echo >&2
    print_title "统一配置校验"
    local verify_sh
    verify_sh=$(resolve_verify_sh) || return 1

    local check_ok=false
    if VERIFY_INSTALL_DIR="$XRAY_BASE" bash "$verify_sh" check; then
        check_ok=true
    fi

    if [[ "$check_ok" != "true" ]]; then
        # 只回滚本批新增碎片, 不动既有节点; 协议脚本自身在生成时已做过单文件 -test
        print_error "统一校验失败，回滚本批新增节点碎片（原有节点不动）"
        local nf
        for nf in "${new_files[@]}"; do
            print_warn "回滚: $nf"
            rm -f "$nf"
        done
        rm -f "$CONF_DIR/.batch-ports"
        if VERIFY_INSTALL_DIR="$XRAY_BASE" bash "$verify_sh" check >/dev/null 2>&1; then
            print_ok "回滚后配置恢复可用"
        else
            print_error "回滚后统一校验仍失败，请用菜单「校验配置/重启服务」人工处理"
        fi
        batch_summary false
        return 1
    fi

    # ---- 仅一次统一 reload (非沙箱 XRAY_BASE_DIR 才操作 systemd) ----
    local reloaded=false
    if [[ "$X_IS_SANDBOX" != "true" && "${X_BATCH_TEST_SKIP_RESTART:-0}" != "1" ]]; then
        echo >&2
        print_title "统一重启 xrayls (仅此一次)"
        if bash "$verify_sh" restart; then
            reloaded=true
        fi
        systemctl is-active xrayls.service >/dev/null 2>&1 \
            && print_ok "xrayls 服务状态: active (运行中)" \
            || print_error "xrayls 服务状态异常, 请检查 journalctl -u xrayls"
    else
        print_info "沙箱/测试模式 (XRAY_BASE_DIR=$XRAY_BASE): 只校验不重启 systemd 服务"
        print_info "正式 reload: 请在正式环境重新执行 batch (或运行 verify.sh restart)"
    fi

    batch_summary "$reloaded"
    print_ok "全协议一键生成流程结束"
    return 0
}

########## 统一输出 (复用各协议已有产物, 不重造第二套格式) ##########
batch_summary() {
    local reloaded="${1:-false}"
    local -a ok_list=("${BATCH_OK[@]}") skip_list=("${BATCH_SKIP[@]}") fail_list=("${BATCH_FAIL[@]}")
    local proto frag num port tag share
    echo >&2
    print_title "全协议生成完成 · 汇总"
    for proto in "${BATCH_PROTOS[@]}"; do
        frag=$(latest_fragment "$proto")
        if [[ -z "$frag" ]]; then
            printf " ✗ %-14s (无节点; 失败详情见 $LOG_DIR/x-batch-%s.log)\n" "$proto" "$proto" >&2
            continue
        fi
        num=$(basename "$frag" | sed -E "s/^$(fragment_prefix "$proto")-([0-9]+)\.json$/\1/")
        port=$(jq -r '.inbounds[0].port' "$frag" 2>/dev/null)
        tag=$(jq -r '.inbounds[0].tag' "$frag" 2>/dev/null)
        printf " ✓ %-14s 编号=%-3s 端口=%-6s Tag=%s\n" "$proto" "$num" "$port" "$tag" >&2
        # 分享链接直接读取协议脚本生成的现有文件
        local pre share
        pre="$(fragment_prefix "$proto")"
        case "$proto" in
            hysteria2) share="$OUT_DIR/hy2_share-$num.txt" ;;
            *)         share="$OUT_DIR/$pre-share-$num.txt" ;;
        esac
        [[ -f "$share" ]] && sed 's/^/     /' "$share" >&2
    done
    echo >&2
    ((${#ok_list[@]}   > 0)) && printf "${GREEN}生成成功: %s${RESET}\n" "${ok_list[*]}" >&2
    ((${#skip_list[@]} > 0)) && printf "${YELLOW}已存在(跳过): %s${RESET}\n" "${skip_list[*]}" >&2
    ((${#fail_list[@]} > 0)) && {
        printf "${RED}失败(详情在日志末尾): %s${RESET}\n" "${fail_list[*]}" >&2
        local p
        for p in "${fail_list[@]}"; do
            echo "  --- $p ---" >&2
            tail -3 "$LOG_DIR/x-batch-$p.log" 2>/dev/null >&2
        done
    }
    [[ "$reloaded" == "true" ]] || print_info "服务未重启/沙箱模式: 配置已校验, reload 需在正式目录执行 batch 或手动 verify"
}

########## 入口 ##########
main() {
    if [[ "${1:-}" == "--auto" ]]; then
        : $(( X_BATCH_PORT_START = 20000 + RANDOM % 20000 ))
        : $(( X_BATCH_PORT_END = X_BATCH_PORT_START + 2000 ))
        batch_main
        return $?
    fi
    while true; do
        print_title "全协议一键生成 (Batch Generator)"
        echo -e "${CYAN}1)${RESET} 全协议生成：Reality / Trojan / SS2022 / Hysteria2（唯一交互: 端口范围）"
        echo -e "${CYAN}2)${RESET} 全协议生成（自动端口, 完全无交互）"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请输入选项 [0-2]: " c || { echo; exit 0; }
        c=$(clean_input "$c")
        case "$c" in
            1) ask_port_range && batch_main ;;
            2) choose_port_range "" && batch_main ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        [[ "$c" == "0" ]] || { read -r -p "按回车键返回..." _ || { echo; exit 0; }; }
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
