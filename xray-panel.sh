#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"  # 修复缺失的闭合引号

# 主菜单
show_menu() {
    # 获取服务状态
    xrayls_server_status=$(systemctl is-active xrayls.service 2>/dev/null || echo "inactive")

    # 生成状态文本
    if [[ "$xrayls_server_status" == "active" ]]; then
        xrayls_server_status_text="${GREEN}启动${PLAIN}"
    else
        xrayls_server_status_text="${RED}未启动${PLAIN}"
    fi

    # 使用单引号和here-doc格式避免转义问题
    clear
    echo -e "
${GREEN}xrayls 管理脚本${PLAIN}
----------------------
${GREEN}1.${PLAIN} 安装 xray
${GREEN}2.${PLAIN} 卸载 xray
${GREEN}3.${PLAIN} 更新 xray
${GREEN}4.${PLAIN} 重启 xray
${GREEN}5.${PLAIN} 查看客户端配置
${GREEN}6.${PLAIN} 修改配置
${GREEN}7.${PLAIN} 查询服务状态
${GREEN}0.${PLAIN} 退出脚本
----------------------
xrayls 服务状态: ${xrayls_server_status_text}
----------------------"

    read -p "请输入选项 [0-7]: " choice

    case "${choice}" in
        0) clear; exit 0 ;;
        1) bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/VEVLRE.sh) ;;
        2) bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/uninstall_xray.sh) ;;
        3) bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/upxray.sh) ;;
        4) systemctl restart xrayls.service ;;
        5) [[ -f /root/catmi/xray.txt ]] && cat /root/catmi/xray.txt || echo "配置文件不存在" ;;
        6) clear ;;  # 示例配置修改
        7) systemctl status xrayls.service -l ;;
        *) echo -e "${RED}无效的选项 ${choice}${PLAIN}" ;;
    esac

    echo && read -p "按回车键返回主菜单..." && echo
}

# 主程序循环
while true; do
    show_menu
done
