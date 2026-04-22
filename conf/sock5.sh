#!/bin/bash

# 协议类型
PROTO="socks"

# 配置文件目录
CONF_DIR="/root/catmi/xray/conf"
mkdir -p "$CONF_DIR"

# ================================
# 随机生成函数
# ================================
random_port() {
    shuf -i 10000-60000 -n 1
}

random_user() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 8
}

random_pass() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 12
}

# 输入函数（支持默认值）
ask_with_default() {
    local prompt="$1"
    local default="$2"
    local var

    read -p "$prompt (回车使用默认: $default): " var
    echo "${var:-$default}"
}

# ================================
# 显示所有 SOCKS 配置
# ================================
list_configs() {
    echo "====== 当前 $PROTO 配置列表 ======"
    echo "编号 | 用户名 | 密码 | 本地端口"
    echo "-------------------------------------"

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)

        lport=$(jq -r '.inbounds[0].port' "$f")
        user=$(jq -r '.inbounds[0].settings.accounts[0].user' "$f")
        pass=$(jq -r '.inbounds[0].settings.accounts[0].pass' "$f")

        echo "$num) 用户: $user | 密码: $pass | 本地端口: $lport"
    done

    echo "-------------------------------------"
}


# ================================
# 新增 SOCKS 配置
# ================================
add_config() {
    # 生成随机默认值
    default_port=$(random_port)
    default_user=$(random_user)
    default_pass=$(random_pass)

    # 让用户选择或使用默认值
    lport=$(ask_with_default "请输入本地监听端口" "$default_port")
    SOCKS_USERNAME=$(ask_with_default "请输入 SOCKS 用户名" "$default_user")
    SOCKS_PASSWORD=$(ask_with_default "请输入 SOCKS 密码" "$default_pass")

    # 自动找下一个编号
    next=$(ls "$CONF_DIR"/$PROTO-*.json 2>/dev/null | wc -l)
    next=$((next + 1))
    tag_name="${PROTO}${next}"

    file="$CONF_DIR/$PROTO-$(printf "%02d" $next).json"

    cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "::",
      "port": $lport,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$SOCKS_USERNAME",
            "pass": "$SOCKS_PASSWORD"
          }
        ]
      },
      "tag": "$tag_name"
    }
  ]
}
EOF

    echo "新增 $PROTO 配置成功:"
    echo "编号: $next"
    echo "本地端口: $lport"
    echo "用户名: $SOCKS_USERNAME"
    echo "密码: $SOCKS_PASSWORD"
    echo "Tag: $tag_name"
}


# ================================
# 删除 SOCKS 配置
# ================================
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

# ================================
# 主菜单
# ================================
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
