# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"
INSTALL_DIR="/root/catmi/xray"
xrayconf="$INSTALL_DIR/install_info.env"
load_env() {
    local env_file="${1:-$CATMIENV_FILE}"

    # 1. 检查文件是否存在
    if [ ! -f "$env_file" ]; then
        echo "错误：env 文件不存在 -> $env_file"
        return 1
    fi

    # 2. 逐行读取
    while IFS= read -r line || [ -n "$line" ]; do
        # 去除 Windows 换行符 (CRLF)
        line="${line%$'\r'}"

        # 3. 跳过空行、空白行、注释行
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue

        # 4. 必须包含 =
        if [[ "$line" != *=* ]]; then
            echo "警告：跳过无效行（缺少 '='）：$line"
            continue
        fi

        # 5. 拆分 key=value（只分第一个 =）
        key="${line%%=*}"
        value="${line#*=}"

        # 6. trim 空格
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        # 7. 校验 key
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "错误：非法的变量名 -> $key"
            return 1
        fi

        # 8. 必须是 "value" 格式
        if [[ ! "$value" =~ ^\".*\"$ ]]; then
            echo "错误：变量 $key 的值必须包含在双引号内 -> $value"
            return 1
        fi

        # 去掉外层引号
        value="${value:1:-1}"

        # 9. 反转义（顺序非常重要）
        value="${value//\\\\/\\}"   # \\ -> \
        value="${value//\\\"/\"}"   # \" -> "
        value="${value//\\\$/\$}"   # \$ -> $

        # 10. 设置变量
        printf -v "$key" '%s' "$value"
        export "$key"

    done < "$env_file"

    echo "成功：已安全加载环境配置文件 $env_file"
}
update_env() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    # 参数检查
    [[ -n "$env_file" ]] || { echo "错误：未指定 env 文件"; return 1; }
    [[ -n "$key" ]]      || { echo "错误：未指定 key"; return 1; }

    # 校验 key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "Invalid key: $key"
        return 1
    }

    # 确保目录 & 文件
    mkdir -p "$(dirname "$env_file")"
    [ -f "$env_file" ] || touch "$env_file"

    # 获取权限 & 属主（兼容 Linux / BSD）
    local mode owner group
    if mode=$(stat -c "%a" "$env_file" 2>/dev/null); then
        owner=$(stat -c "%u" "$env_file")
        group=$(stat -c "%g" "$env_file")
    else
        mode=$(stat -f "%Lp" "$env_file")
        owner=$(stat -f "%u" "$env_file")
        group=$(stat -f "%g" "$env_file")
    fi

    # 转义 value
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    # 加锁 + 自动释放
    (
        flock 200

        local tmp_file
        tmp_file=$(mktemp "$(dirname "$env_file")/.env.tmp.XXXXXX")

        # 设置权限
        chmod "$mode" "$tmp_file"
        chown "$owner":"$group" "$tmp_file" 2>/dev/null || true

        # 精确删除旧 key
        awk -v k="$key" 'index($0, k"=") != 1' "$env_file" > "$tmp_file"

        # 写入新值
        printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"

        # 原子替换
        mv "$tmp_file" "$env_file"

    ) 200>"$env_file.lock"
}


webxn() {
    set -e

    print_info "请选择 Web 服务安装方式："
    print_info "1. 安装 Nginx"
    print_info "2. 安装 Caddy"

    read -rp "请输入选项 (1/2): " Conversion_CHOICE

    case "$Conversion_CHOICE" in
    1)
        print_info "=== 停止并卸载 Caddy ==="
        systemctl stop caddy 2>/dev/null || true
        systemctl disable caddy 2>/dev/null || true

        apt purge -y caddy || true
        apt autoremove -y || true

        print_info "=== 删除 Caddy 配置 ==="
        rm -rf /etc/caddy /var/lib/caddy

        print_info "=== 删除 Caddy 源 ==="
        rm -f /etc/apt/sources.list.d/caddy-stable.list
        rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg

        apt update -y

        print_info "Caddy 已卸载完成"

    read -p "请输入监听端口 (默认 443): " NPORT
    NPORT=${NPORT:-443}
    update_env $xrayconf NPORT "$NPORT"
        bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh)
        load_env "$CATMIENV_FILE"
        bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/nconf.sh)
        bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/nginx.sh)
        ;;

    2)
        print_info "=== 停止并卸载 Nginx ==="
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true

        apt purge -y nginx nginx-common nginx-full || true
        apt autoremove -y || true

        print_info "Nginx 已卸载完成"

        read -rp "请输入未 CDN 域名: " RDOMAIN_LOWE

        update_env "$xrayconf" "RDOMAIN_LOWE" "$RDOMAIN_LOWE"

        
        bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/conf/cconf.sh)
        bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/caddy.sh)
        ;;

    *)
        print_error "❌ 无效输入"
        return 1
        ;;
    esac
}

if [[ -d "$DINSTALL_CATMI" && -f "$DINSTALL_CATMI/catmi.env" ]]; then
print_info "检测到已安装环境"

webxn
    
else
    print_error "目录或文件不存在"
    bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xray-panel.sh)
fi
