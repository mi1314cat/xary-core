#!/bin/bash

# 确保脚本在遇到错误时退出
set -e

# 提供操作选项供用户选择
echo "请选择要执行的操作："
echo "1) 有80和443端口"
echo "2) 无80 443端口"
read -p "请输入选项 (1 或 2): " choice

# 提示用户输入域名和电子邮件地址
read -p "请输入域名: " DOMAIN

# 将用户输入的域名转换为小写
DOMAIN_LOWER=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')

read -p "请输入电子邮件地址: " EMAIL

# 创建目标目录
TARGET_DIR="/root/catmi"
mkdir -p "$TARGET_DIR"

if [ "$choice" -eq 1 ]; then
    # 选项 1: 安装更新、克隆仓库并执行脚本
    echo "执行安装acme证书..."

    # 更新系统并安装必要的依赖项
    echo "更新系统并安装依赖项..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install ufw -y
    sudo apt install -y curl socat git cron openssl
    ufw disable
    # 安装 acme.sh
    echo "安装 acme.sh..."
    curl https://get.acme.sh | sh

    # 设置路径
    export PATH="$HOME/.acme.sh:$PATH"

    # 注册账户
    echo "注册账户..."
    "$HOME/.acme.sh/acme.sh" --register-account -m "$EMAIL"

    # 申请 SSL 证书
    echo "申请 SSL 证书..."
    if ! "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN_LOWER"; then
        echo "证书申请失败，删除已生成的文件和文件夹。"
        rm -f "$HOME/${DOMAIN_LOWER}.key" "$HOME/${DOMAIN_LOWER}.crt"
        "$HOME/.acme.sh/acme.sh" --remove -d "$DOMAIN_LOWER"
        exit 1
    fi

    # 安装 SSL 证书并移动到目标目录
    echo "安装 SSL 证书..."
    "$HOME/.acme.sh/acme.sh" --installcert -d "$DOMAIN_LOWER" \
        --key-file       "$TARGET_DIR/${DOMAIN_LOWER}.key" \
        --fullchain-file "$TARGET_DIR/${DOMAIN_LOWER}.crt"

    # 提示用户证书已生成
    echo "SSL 证书和私钥已生成并移动到 $TARGET_DIR:"
    echo "证书: $TARGET_DIR/${DOMAIN_LOWER}.crt"
    echo "私钥: $TARGET_DIR/${DOMAIN_LOWER}.key"

    # 创建自动续期的脚本
    cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
\$HOME/.acme.sh/acme.sh --renew -d "$DOMAIN_LOWER" --key-file "$TARGET_DIR/${DOMAIN_LOWER}.key" --fullchain-file "$TARGET_DIR/${DOMAIN_LOWER}.crt"
EOF
    chmod +x /root/renew_cert.sh

    # 创建自动续期的 cron 任务，每天午夜执行一次
    (crontab -l 2>/dev/null; echo "0 0 * * * /root/renew_cert.sh >> /var/log/renew_cert.log 2>&1") | crontab -

    echo "完成！请确保在您的 Web 服务器配置中使用新的 SSL 证书。"

elif [ "$choice" -eq 2 ]; then
    # 选项 2: 手动获取 SSL 证书证书安装/etc/letsencrypt/live/$DOMAIN_LOWER 目录 文件夹
    echo "将进行手动获取 SSL 证书证书安装/etc/letsencrypt/live/$DOMAIN_LOWER 目录文件夹..."

    # 安装 Certbot
    echo "安装 Certbot..."
    sudo apt-get update
    sudo apt-get install -y certbot openssl

    # 手动获取证书
    echo "手动获取证书..."
    sudo certbot certonly --manual --preferred-challenges dns -d "$DOMAIN_LOWER"

    

    # 创建自动续期的 cron 任务
    (crontab -l 2>/dev/null; echo "0 0 * * * certbot renew") | crontab -


    echo "SSL 证书已安装/etc/letsencrypt/live/$DOMAIN_LOWER 目录中"
else
    echo "无效选项，请输入 1 或 2."
fi
