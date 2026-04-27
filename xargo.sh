#!/usr/bin/env bash
set -e

WORKDIR="/root/argo"
BIN="$WORKDIR/cloudflared"
TEMP_LOG="$WORKDIR/temp.log"
TEMP_SAVE="$WORKDIR/temp_url.txt"

mkdir -p "$WORKDIR"

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

download_cloudflared() {
    if [[ ! -f "$BIN" ]]; then
        title "正在下载 cloudflared..."
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi
}

# ============================
# 临时隧道（后台运行）
# ============================
create_temp_tunnel() {
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
        echo -e "${RED}未能捕获到临时隧道 URL${NC}"
        tail -n 20 "$TEMP_LOG"
        return
    fi

    echo "$URL" > "$TEMP_SAVE"
    echo -e "临时隧道：${GREEN}$URL${NC}"
}

status_temp() {
    if pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

restart_temp() {
    stop_temp
    create_temp_tunnel
}

stop_temp() {
    pkill -f "cloudflared tunnel --url" 2>/dev/null && echo "临时隧道已关闭"
}

delete_temp() {
    stop_temp
    rm -f "$TEMP_LOG" "$TEMP_SAVE"
    echo "临时隧道文件已删除"
}

# ============================
# 菜单
# ============================
menu_temp() {
    while true; do
        title "临时隧道管理"

        echo -n "状态："; status_temp
        [[ -f "$TEMP_SAVE" ]] && echo "域名：$(cat $TEMP_SAVE)"

        echo
        echo "1) 创建临时隧道"
        echo "2) 重启临时隧道"
        echo "3) 关闭临时隧道"
        echo "4) 删除临时隧道"
        echo "0) 退出"
        read -p "选择: " CH

        case $CH in
            1) download_cloudflared; create_temp_tunnel ;;
            2) restart_temp ;;
            3) stop_temp ;;
            4) delete_temp ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

menu_temp
