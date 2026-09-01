#!/bin/bash

# ================================
# split.sh — Xray 分流规则管理脚本
# outbound.sh（出站脚本）的姊妹版本，专管"分流规则"：
#   - 同样的彩色输出 / print_* / print_title / safe_read 风格
#   - 数据载体 conf/out-routing.json（与 outbound.sh 的绑定表同文件，
#     由 _meta.splitRules 存分流规则、_meta.bindings 存绑定表）
#   - 每条规则 = {type:field, [inboundTag], domain:[...], outboundTag}
#       · 不带 inboundTag → 全局分流（所有入站命中域名都走该出站）
#       · 带 inboundTag   → 按入站分流（只对该入站生效）
#   - 生成 routing.rules 顺序：分流规则(splitRules)在最前 → 绑定规则 → ads→block
#     （本 xrayls fork 对 routing 是"后读文件覆盖前读"，故全部集中在同一文件，
#       分流在前先匹配，优先于绑定）
# 用法： bash split.sh   （测试时可 SPLIT_BASE_DIR=... 覆盖基础目录）
# ================================

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
RESET="\e[0m"

# ================================
# 打印函数（全部输出到 stderr，与兄弟脚本一致）
# ================================
print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ================================
# 基础变量
# ================================
BASE_DIR="${SPLIT_BASE_DIR:-/root/catmi/xray}"
CONF_DIR="$BASE_DIR/conf"
ROUTING_FILE="$CONF_DIR/out-routing.json"

# Xray 二进制（配置校验用）
XRAY_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_BIN" ]]; then
    for c in /root/catmi/xray/xrayls /usr/local/bin/xray xrayls; do
        command -v "$c" >/dev/null 2>&1 && { XRAY_BIN=$(command -v "$c"); break; }
    done
fi

mkdir -p "$CONF_DIR"

# ================================
# 输入清理
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

# ================================
# 安全输入（不会污染 JSON）
# ================================
safe_read() {
    local prompt="$1"
    local default="$2"
    local input

    if [[ -n "$default" ]]; then
        printf "%s (默认: %s): " "$prompt" "$default" >&2
    else
        printf "%s: " "$prompt" >&2
    fi
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

# ================================
# 出站 tag 列表（direct/block + conf/out-NN.json 的 tag）
# ================================
outbound_tags() {
    echo "direct"
    echo "block"
    local f t
    shopt -s nullglob
    for f in "$CONF_DIR"/out-*.json; do
        [[ "$(basename "$f")" == out-routing.json ]] && continue
        t=$(jq -r '.outbounds[0].tag // empty' "$f" 2>/dev/null)
        [[ -n "$t" ]] && echo "$t"
    done
}

# ================================
# 入站 tag 列表（conf 目录里非 out-* 片段中的 inbounds tag）
# ================================
inbound_tags() {
    local f t
    shopt -s nullglob
    for f in "$CONF_DIR"/*.json; do
        [[ "$(basename "$f")" == out-*.json ]] && continue
        while IFS= read -r t; do
            [[ -n "$t" ]] && echo "$t"
        done < <(jq -r '.inbounds[]?.tag // empty' "$f" 2>/dev/null)
    done | sort -u
}

# ================================
# 读/写分流规则集合（_meta.splitRules）
# ================================
read_rules() {
    jq -c '._meta.splitRules // []' "$ROUTING_FILE" 2>/dev/null
}

ensure_split_file() {
    if [[ ! -f "$ROUTING_FILE" ]]; then
        echo '{"_meta":{"bindings":{},"splitRules":[]},"routing":{"rules":[]}}' > "$ROUTING_FILE"
        print_ok "已创建 $ROUTING_FILE"
    fi
}

# 统一重组 routing.rules：分流(splitRules) + 绑定(bindings) + ads→block
# 与 outbound.sh 的 rebuild 逻辑一致（两边各自实现，保证结果相同）
rebuild_and_write() {
    if [[ ! -f "$ROUTING_FILE" ]]; then
        ensure_split_file
    fi
    local splits binds
    splits=$(jq -c '._meta.splitRules // []' "$ROUTING_FILE" 2>/dev/null)
    # 绑定表 → 绑定规则数组
    binds=$(jq -c '[._meta.bindings // {} | to_entries[] | {inboundTag:[.key], outboundTag:.value}]' "$ROUTING_FILE" 2>/dev/null)
    [[ -z "$binds" || "$binds" == "null" ]] && binds='[]'
    # 只更新 routing 字段，保留 _meta
    jq --argjson splits "$splits" --argjson binds "$binds" \
        '.routing.rules = ($splits + $binds + [{domain:["geosite:category-ads-all"], outboundTag:"block"}])' \
        "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    print_ok "已更新 $ROUTING_FILE（分流在前，绑定在后）"
}

# ================================
# 查看分流规则
# ================================
list_splits() {
    print_title "分流规则列表"
    ensure_split_file
    local n=0 d ib ob
    while IFS= read -r d; do
        n=$((n+1))
        ib=$(jq -r '.inboundTag? // empty' <<< "$d")
        ob=$(jq -r '.outboundTag // "?"' <<< "$d")
        local cnt doms
        cnt=$(jq -r '.domain? // [] | length' <<< "$d")
        doms=$(jq -r '.domain? // [] | join(" ")' <<< "$d" | cut -c1-60)
        if [[ -n "$ib" ]]; then
            printf "  %d) [按入站] %s → %s  (域名 %d 个: %s)\n" "$n" "$ib" "$ob" "$cnt" "$doms" >&2
        else
            printf "  %d) [全局] → %s  (域名 %d 个: %s)\n" "$n" "$ob" "$cnt" "$doms" >&2
        fi
    done < <(read_rules | jq -c '.[]')
    if (( n == 0 )); then
        print_info "当前无分流规则（所有入站都走绑定/默认出口）"
    fi
}

# ================================
# 新增分流规则
# ================================
add_split() {
    print_title "新增分流规则"
    ensure_split_file
    # 选择出口
    echo "选择出口（分流命中后的去向）:" >&2
    local -a tags=()
    local i=1 t
    while IFS= read -r t; do
        tags+=("$t")
        echo "  $i) $t" >&2
        i=$((i+1))
    done < <(outbound_tags | sort -u)
    if ((${#tags[@]} == 0)); then
        print_error "没有任何可用出站，请先运行 outbound.sh 创建"
        return 1
    fi
    printf "选择序号: " >&2
    read sel; sel=$(clean_input "$sel")
    [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#tags[@]} ]] || { print_error "无效选择"; return 1; }
    local ob="${tags[$((sel-1))]}"

    # 全局 or 按入站
    echo "分流范围:" >&2
    echo "  1) 全局（所有入站生效）" >&2
    echo "  2) 指定入站（只对某入站生效）" >&2
    printf "选择: " >&2
    read scope; scope=$(clean_input "$scope")
    local inbound=""
    if [[ "$scope" == "2" ]]; then
        echo "可用入站:" >&2
        local -a ins=()
        i=1
        while IFS= read -r it; do
            ins+=("$it")
            echo "  $i) $it" >&2
            i=$((i+1))
        done < <(inbound_tags)
        if ((${#ins[@]} == 0)); then
            print_error "未发现任何入站（conf 里没有 inbounds 片段）"
            return 1
        fi
        printf "选择序号: " >&2
        read isel; isel=$(clean_input "$isel")
        [[ "$isel" =~ ^[0-9]+$ && "$isel" -ge 1 && "$isel" -le ${#ins[@]} ]] || { print_error "无效选择"; return 1; }
        inbound="${ins[$((isel-1))]}"
    fi

    # 域名名单（支持逗号/空格分隔，或 geosite: 前缀）
    local doms
    doms=$(safe_read "域名名单（多个用空格或逗号分隔，如 browserleaks.com matrix.tencent.com）" "")
    [[ -n "$doms" ]] || { print_error "至少需要一个域名"; return 1; }
    local -a darr=()
    local d
    for d in $doms; do
        d=${d%,}
        [[ -z "$d" ]] && continue
        [[ "$d" == geosite:* || "$d" == domain:* ]] || d="domain:$d"
        darr+=("$d")
    done
    ((${#darr[@]} == 0)) && { print_error "域名解析失败"; return 1; }

    # 构造规则并写入 _meta.splitRules
    local rule
    if [[ -n "$inbound" ]]; then
        rule=$(jq -n --arg ib "$inbound" --arg ob "$ob" --argjson ds "$(printf '%s\n' "${darr[@]}" | jq -R . | jq -s .)" \
            '{type:"field", inboundTag:[$ib], domain:$ds, outboundTag:$ob}')
    else
        rule=$(jq -n --arg ob "$ob" --argjson ds "$(printf '%s\n' "${darr[@]}" | jq -R . | jq -s .)" \
            '{type:"field", domain:$ds, outboundTag:$ob}')
    fi
    jq --argjson r "$rule" '._meta.splitRules = ((._meta.splitRules // []) + [$r])' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    rebuild_and_write
    local scope_txt="全局"
    [[ -n "$inbound" ]] && scope_txt="入站 $inbound"
    print_ok "已新增分流规则：[$scope_txt] → $ob  (域名 ${#darr[@]} 个)"
}

# ================================
# 删除分流规则
# ================================
del_split() {
    print_title "删除分流规则"
    ensure_split_file
    local total
    total=$(read_rules | jq 'length')
    if [[ "$total" == "0" ]]; then
        print_info "当前无分流规则"
        return 0
    fi
    list_splits
    printf "输入要删除的规则序号 (0=取消): " >&2
    read dn; dn=$(clean_input "$dn")
    [[ "$dn" =~ ^[0-9]+$ ]] || { print_error "无效序号"; return 1; }
    (( dn >= 1 && dn <= total )) || { print_error "序号超出范围"; return 1; }
    jq "._meta.splitRules |= del(.[$((dn-1))])" "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    rebuild_and_write
    print_ok "已删除规则 $dn"
}

# ================================
# 给规则增删域名
# ================================
edit_domains() {
    print_title "维护分流规则域名"
    ensure_split_file
    local total
    total=$(read_rules | jq 'length')
    if [[ "$total" == "0" ]]; then
        print_info "当前无分流规则，请先新增"
        return 0
    fi
    list_splits
    printf "选择规则序号 (0=取消): " >&2
    read sn; sn=$(clean_input "$sn")
    [[ "$sn" =~ ^[0-9]+$ ]] || { print_error "无效序号"; return 1; }
    (( sn >= 1 && sn <= total )) || { print_error "序号超出范围"; return 1; }
    local idx=$((sn-1))
    echo "操作:" >&2
    echo "  1) 添加域名" >&2
    echo "  2) 移除域名" >&2
    printf "选择: " >&2
    read op; op=$(clean_input "$op")
    local ds added
    case "$op" in
        1)
            ds=$(safe_read "要添加的域名（多个可空格分隔）" "")
            [[ -n "$ds" ]] || { print_error "不能为空"; return 1; }
            local -a addarr=()
            local d
            for d in $ds; do
                d=${d%,}
                [[ -z "$d" ]] && continue
                [[ "$d" == geosite:* || "$d" == domain:* ]] || d="domain:$d"
                addarr+=("$d")
            done
            ((${#addarr[@]} == 0)) && { print_error "没有有效域名"; return 1; }
            local addjson
            addjson=$(printf '%s\n' "${addarr[@]}" | jq -R . | jq -s .)
            jq --argjson idx "$idx" --argjson add "$addjson" \
                '._meta.splitRules[$idx].domain = ((._meta.splitRules[$idx].domain // []) + $add) | ._meta.splitRules[$idx].domain |= unique' \
                "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
            rebuild_and_write
            print_ok "已添加域名到规则 $sn"
            ;;
        2)
            added=$(read_rules | jq -r ".[$idx].domain // [] | join(\" \")")
            echo "当前域名: $added" >&2
            ds=$(safe_read "要移除的域名（输完整，可空格分隔多个）" "")
            [[ -n "$ds" ]] || { print_error "不能为空"; return 1; }
            local -a rmarray=()
            for d in $ds; do
                d=${d%,}
                [[ -z "$d" ]] && continue
                [[ "$d" == geosite:* || "$d" == domain:* ]] || d="domain:$d"
                rmarray+=("$d")
            done
            local rmjson
            rmjson=$(printf '%s\n' "${rmarray[@]}" | jq -R . | jq -s .)
            jq --argjson idx "$idx" --argjson rm "$rmjson" \
                '._meta.splitRules[$idx].domain = ((._meta.splitRules[$idx].domain // []) - $rm)' \
                "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
            rebuild_and_write
            print_ok "已从规则 $sn 移除域名"
            ;;
        *) print_error "无效操作" ;;
    esac
}

# ================================
# 校验配置 / 重启
# ================================
validate_config() {
    if [[ -z "$XRAY_BIN" ]]; then
        print_error "未找到 xray 二进制，无法校验"
        return 1
    fi
    print_title "校验 Xray 配置"
    local out
    out=$("$XRAY_BIN" run -test -confdir "$CONF_DIR" 2>&1)
    if [[ "$out" == *"Configuration OK."* ]]; then
        print_ok "Configuration OK."
    else
        print_error "配置校验失败："
        echo "$out" | tail -8 >&2
    fi
}

restart_xrayls() {
    if systemctl list-unit-files 2>/dev/null | grep -qw "xrayls.service"; then
        systemctl restart xrayls
        sleep 1
        systemctl is-active --quiet xrayls && print_ok "xrayls 已重启" || print_error "xrayls 重启失败"
    elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -qw "xray.service"; then
        systemctl restart xray
        print_ok "xray 已重启"
    else
        print_error "未找到 xray 服务，请手动重启"
    fi
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Xray 分流规则管理"

        echo "1) 查看分流规则" >&2
        echo "2) 新增分流规则" >&2
        echo "3) 删除分流规则" >&2
        echo "4) 维护规则域名（增删）" >&2
        echo "5) 校验配置 / 重启服务" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case $c in
            1) list_splits ;;
            2) add_split ;;
            3) del_split ;;
            4) edit_domains ;;
            5)
                print_title "校验 / 重启"
                validate_config
                printf "重启 xrayls 服务? [y/N]: " >&2
                read rr
                rr=$(clean_input "$rr")
                [[ "$rr" == "y" || "$rr" == "Y" ]] && restart_xrayls
                ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        printf "按回车继续..." >&2
        read
    done
}

# 支持被 source 后直接调用内部函数做自动化测试
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_menu
fi