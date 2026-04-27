#!/usr/bin/env bash
set -e

# ============================
# 基础路径
# ============================
WORKDIR="/root/argo_temp"
BIN="$WORKDIR/cloudflared"
TEMP_LOG="$WORKDIR/temp.log"
TEMP_SAVE="$WORKDIR/temp_url.txt"

mkdir -p "$WORKDIR"

# ============================
# 颜色
# ============================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
NC="\033[0m"

line() {
    echo -e "${BLUE}----------------------------------------${NC}"
}

title() {
    echo -e "${GREEN}$1${NC}"
    line
}

# ============================
# cloudflared 自动检测
# ============================
check_cloudflared() {
    if [[ ! -f "$BIN" ]]; then
        echo -e "${YELLOW}cloudflared 不存在，正在下载...${NC}"
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi

    if ! "$BIN" --version >/dev/null 2>&1; then
        echo -e "${RED}cloudflared 文件损坏，重新下载...${NC}"
        rm -f "$BIN"
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi
}

# ============================
# 创建临时隧道
# ============================
create_temp_tunnel() {
    check_cloudflared
    title "创建临时隧道"

    rm -f "$TEMP_LOG"

    nohup $BIN tunnel --url http://localhost:8080 --no-autoupdate \
        > "$TEMP_LOG" 2>&1 &

    sleep 2

    if ! pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${RED}临时隧道启动失败！${NC}"
        tail -n 20 "$TEMP_LOG"
        return
    fi

    for i in {1..20}; do
        URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | head -n 1)
        [[ -n "$URL" ]] && break
        sleep 1
    done

    if [[ -z "$URL" ]]; then
        echo -e "${RED}未捕获到临时隧道 URL${NC}"
        tail -n 20 "$TEMP_LOG"
        return
    fi

    echo "$URL" > "$TEMP_SAVE"
    echo -e "临时隧道：${GREEN}$URL${NC}"
}

# ============================
# 状态
# ============================
status_temp() {
    if pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

# ============================
# 重启
# ============================
restart_temp() {
    stop_temp
    create_temp_tunnel
}

# ============================
# 停止
# ============================
stop_temp() {
    pkill -f "cloudflared tunnel --url" 2>/dev/null
    echo "临时隧道已关闭"
}

# ============================
# 删除
# ============================
delete_temp() {
    stop_temp
    rm -f "$TEMP_LOG" "$TEMP_SAVE"
    echo "临时隧道文件已删除"
}

# ============================
# 手动诊断 + 自动修复
# ============================
heal_temp_manual() {
    if [[ ! -f "$TEMP_SAVE" ]]; then
        echo -e "${RED}没有记录中的临时隧道${NC}"
        return
    fi

    URL=$(cat "$TEMP_SAVE")
    echo -e "检测临时隧道：${GREEN}$URL${NC}"

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "$URL" || echo "000")

    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}临时隧道健康（HTTP $HTTP_CODE）${NC}"
        return
    fi

    echo -e "${RED}临时隧道异常（HTTP $HTTP_CODE），自动修复中...${NC}"

    restart_temp
}

# ============================
# systemd 自动健康检查
# ============================
generate_health_script() {
cat > "$WORKDIR/health.sh" <<'EOF'
#!/usr/bin/env bash
TEMP_SAVE="/root/argo_temp/temp_url.txt"
TEMP_LOG="/root/argo_temp/temp.log"
BIN="/root/argo_temp/cloudflared"

if [[ ! -f "$TEMP_SAVE" ]]; then
    exit 0
fi

URL=$(cat "$TEMP_SAVE")
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "$URL" || echo "000")

if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
    exit 0
fi

pkill -f "cloudflared tunnel --url" 2>/dev/null
sleep 1

nohup $BIN tunnel --url http://localhost:8080 --no-autoupdate \
    > "$TEMP_LOG" 2>&1 &
EOF

chmod +x "$WORKDIR/health.sh"
}

install_health_timer() {
cat > /etc/systemd/system/argo-temp-health.service <<EOF
[Unit]
Description=临时隧道自动健康检查

[Service]
Type=oneshot
ExecStart=/bin/bash $WORKDIR/health.sh
EOF

cat > /etc/systemd/system/argo-temp-health.timer <<EOF
[Unit]
Description=每 5 分钟自动修复临时隧道

[Timer]
OnBootSec=30
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable argo-temp-health.timer
systemctl start argo-temp-health.timer
}

# ============================
# 删除所有临时隧道文件（彻底清理）
# ============================
delete_all_temp() {
    title "删除所有临时隧道文件（彻底清理）"

    echo -e "${YELLOW}此操作将删除：${NC}"
    echo "- /root/argo_temp/ 目录"
    echo "- cloudflared 二进制文件"
    echo "- 临时隧道日志、URL 文件"
    echo "- health.sh 健康检查脚本"
    echo "- systemd 定时器：argo-temp-health.timer"
    echo "- systemd 服务：argo-temp-health.service"
    echo
    read -p "确认删除？输入 YES 执行: " CONFIRM

    if [[ "$CONFIRM" != "YES" ]]; then
        echo -e "${RED}已取消${NC}"
        return
    fi

    echo -e "${YELLOW}停止 cloudflared 进程...${NC}"
    pkill -f "cloudflared tunnel --url" 2>/dev/null || true

    echo -e "${YELLOW}删除 systemd 定时器与服务...${NC}"
    systemctl stop argo-temp-health.timer 2>/dev/null || true
    systemctl disable argo-temp-health.timer 2>/dev/null || true
    rm -f /etc/systemd/system/argo-temp-health.timer

    systemctl stop argo-temp-health.service 2>/dev/null || true
    rm -f /etc/systemd/system/argo-temp-health.service

    systemctl daemon-reload

    echo -e "${YELLOW}删除临时隧道目录...${NC}"
    rm -rf /root/argo_temp

    echo -e "${GREEN}临时隧道所有文件已彻底删除${NC}"
}

# ============================
# 查看日志
# ============================
view_temp_log() {
    title "临时隧道日志"
    if [[ -f "$TEMP_LOG" ]]; then
        tail -n 50 "$TEMP_LOG"
    else
        echo -e "${RED}没有日志文件${NC}"
    fi
}

# ============================
# 菜单
# ============================
menu() {
    while true; do
        title "临时隧道管理（独立版）"

        echo -n "状态："; status_temp
        [[ -f "$TEMP_SAVE" ]] && echo "域名：$(cat $TEMP_SAVE)"
        echo

        echo "1) 创建临时隧道"
        echo "2) 重启临时隧道"
        echo "3) 关闭临时隧道"
        echo "4) 删除临时隧道"
        echo "5) 手动诊断并自动修复"
        echo "6) 查看临时隧道日志"
        echo "7) 删除所有临时隧道文件（彻底清理）"

        echo "0) 退出"

        read -p "选择: " CH

        case $CH in
            1) create_temp_tunnel ;;
            2) restart_temp ;;
            3) stop_temp ;;
            4) delete_temp ;;
            5) heal_temp_manual ;;
            6) view_temp_log ;;
            7) delete_all_temp ;;

            0) exit 0 ;;
        esac
    done
}

# ============================
# 启动入口
# ============================
generate_health_script
install_health_timer
menu
