#!/bin/bash

PROTO="tunnel"   # ← 未来你只需要改这里就能复用整个脚本（vless/vmess/reality）
CONF_DIR="/root/catmi/xray/conf"
mkdir -p "$CONF_DIR"

# 显示所有配置
list_configs() {
    echo "====== 当前 $PROTO 配置列表 ======"
    echo "编号 | 目标地址 | 协议 | 本地端口"
    echo "-------------------------------------"

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)

        ip=$(jq -r '.inbounds[0].settings.address' "$f")
        port=$(jq -r '.inbounds[0].settings.port' "$f")
        net=$(jq -r '.inbounds[0].settings.network' "$f")
        lport=$(jq -r '.inbounds[0].port' "$f")

        echo "$num) $ip:$port ($net) → 本地端口 $lport"
    done

    echo "-------------------------------------"
}


# 新增配置
add_config() {
    read -p "请输入本地监听端口: " lport
    read -p "请输入目标 IP: " ip
    read -p "请输入目标端口: " tport

    echo "请选择协议类型:"
    echo "1) tcp"
    echo "2) udp"
    read -p "请输入选项: " choice

    case "$choice" in
        1) net="tcp" ;;
        2) net="udp" ;;
        *) 
            echo "无效选项，默认使用 tcp"
            net="tcp"
            ;;
    esac

    # 自动找下一个编号
    next=$(ls "$CONF_DIR"/$PROTO-*.json 2>/dev/null | wc -l)
    next=$((next + 1))

    file="$CONF_DIR/$PROTO-$(printf "%02d" $next).json"

    cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $lport,
      "protocol": "$PROTO",
      "settings": {
        "address": "$ip",
        "port": $tport,
        "network": "$net",
        "followRedirect": false,
        "userLevel": 0
      },
      "tag": "$PROTO$next"
    }
  ]
}
EOF

    echo "新增 $PROTO 配置成功:"
    echo "编号: $next"
    echo "本地端口: $lport"
    echo "转发到: $ip:$tport ($net)"
}


# 删除配置
delete_config() {
    list_configs

    read -p "请输入要删除的编号: " num
    file="$CONF_DIR/$PROTO-$(printf "%02d" $num).json"

    if [[ -f "$file" ]]; then
        rm -f "$file"
        echo "已删除编号 $num 的 $PROTO 配置"
    else
        echo "编号 $num 不存在"
    fi
}

# 主菜单
config_menu() {
    while true; do
        echo ""
        echo "====== $PROTO 配置管理 ======"
        echo "1) 查看所有配置"
        echo "2) 新增配置"
        echo "3) 删除配置"
        echo "0) 退出脚本"
        read -p "请选择: " c

        case $c in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac

        read -p "按回车继续..."
    done
}

config_menu
