

ssl_dns() {
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
    sudo apt update 
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
        CERT_PATH="$TARGET_DIR/${DOMAIN_LOWER}.crt"
        KEY_PATH="$TARGET_DIR/${DOMAIN_LOWER}.key"

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
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN_LOWER/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN_LOWER/privkey.pem"

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
}
ssl_sd(){
CERT_DIR="/root/catmi"
CERT_PATH="${CERT_DIR}/server.crt"
KEY_PATH="${CERT_DIR}/server.key"
ufw disable
# 创建目录
mkdir -p "$CERT_DIR"

# 输入域名（可以扩展做记录或校验）
read -p "请输入申请证书的域名: " DOMAIN_LOWER

# 输入证书内容
echo "📄 请粘贴你的证书内容（以 -----BEGIN CERTIFICATE----- 开头），输入完后按 Ctrl+D："
CERT_CONTENT=$(</dev/stdin)

# 检查输入为空
if [[ -z "$CERT_CONTENT" ]]; then
  echo "❌ 证书内容不能为空！"
  exit 1
fi

# 保存证书
echo "$CERT_CONTENT" > "$CERT_PATH"
echo "✅ 证书已保存到 $CERT_PATH"

# 输入私钥内容
echo "🔑 请粘贴你的私钥内容（以 -----BEGIN PRIVATE KEY----- 或 RSA 开头），输入完后按 Ctrl+D："
KEY_CONTENT=$(</dev/stdin)

# 检查输入为空
if [[ -z "$KEY_CONTENT" ]]; then
  echo "❌ 私钥内容不能为空！"
  exit 1
fi

# 保存私钥
echo "$KEY_CONTENT" > "$KEY_PATH"
echo "✅ 私钥已保存到 $KEY_PATH"
apt install acl
setfacl -m u:www-data:x /root
setfacl -m u:www-data:x $CERT_DIR
setfacl -m u:www-data:r $KEY_PATH
setfacl -m u:www-data:r $CERT_PATH
# 设置权限
chmod 644 "$CERT_PATH" "$KEY_PATH"
echo "🔐 权限已设置为 644"

echo "🎉 所有操作完成！"
}
caddy_install() {
apt update
apt install -y debian-keyring debian-archive-keyring curl

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

apt update
apt install -y caddy
wget -O index.html https://github.com/mi1314cat/One-click-script/releases/download/HTML/1.HTML
mkdir -p /var/www/html
mv index.html /var/www/html/
chown -R caddy:caddy /var/www/html
chmod -R 755 /var/www/html
chown -R caddy:caddy /run/xray
chmod 755 /run/xray
read -p "请输入未cdn域名 " RDOMAIN_LOWE

cat << EOF > /etc/caddy/Caddyfile
${DOMAIN_LOWER} ${RDOMAIN_LOWE} {
       reverse_proxy unix//run/xray/tls_gate.sock

        tls ${CERT_PATH} ${KEY_PATH}

        log {
                output file /var/log/caddy/access.log
        }

        handle /${WS_PATH2} {
                reverse_proxy unix//run/xray/xhttp_in.sock {
                        transport http {
                                versions 2
                        }
                }
        }

        handle /${WS_PATH1} {
                reverse_proxy unix//run/xray/vless_in.sock {
                        transport http {
                                versions 2
                        }
                }
        }

        handle /${WS_PATH} {
                reverse_proxy unix//run/xray/vmess_in.sock {
                        transport http {
                                versions 2
                        }
                }
        }

        handle {
                root * /var/www/html
                file_server
        }
}
EOF
systemctl restart caddy
systemctl status caddy
}
ssl() {
echo "请选择要申请证书的方式:"
echo "1. 自动 DNS验证 "
echo "2. 手动输入 "
read -p "请输入对应的数字选择 [默认1]: " Certificate

# 如果没有输入（即回车），则默认选择1
Certificate=${Certificate:-1}

# 选择请证书的方式
if [ "$Certificate" -eq 1 ]; then
    ssl_dns
elif [ "$Certificate" -eq 2 ]; then
    ssl_sd
else
    echo "无效选择，退出脚本"
    exit 1
fi
}

WS_PATH=$(grep '^vmess WS 路径' /root/catmi/install_info.txt | sed 's/.*[:：]//')
WS_PATH1=$(grep '^vless WS 路径' /root/catmi/install_info.txt | sed 's/.*[:：]//')
WS_PATH2=$(grep '^xhttp 路径' /root/catmi/install_info.txt | sed 's/.*[:：]//')
ssl
caddy_install
