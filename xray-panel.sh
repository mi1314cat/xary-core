#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m

# 主菜单
show_menu() {
    # 获取服务状态
xrayls_server_status=$(systemctl is-active xrayls.service)

# 生成状态文本
xrayls_server_status_text=$(
    if [[ "$xrayls_server_status" == "active" ]]; then
        printf "${GREEN}启动${PLAIN}"
    else
        printf "${RED}未启动${PLAIN}"
    fi
)
    # 显示菜单
    echo -e "
  ${GREEN}Hysteria 2 管理脚本${PLAIN}
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
        0) clear;exit 0 ;;
        1) bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/VEVLRE.sh) || { echo "脚本安装失败"; return; } ;;
        2) bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/uninstall_xray.sh) || { echo "卸载失败"; return; } ;;
        3) bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/upxray.sh) || { echo "安装跟新xray-core失败"; return; } ;;
        4) systemctl restart xrayls.service ;;
        5) cat /root/catmi/xray.txt ;;
        6) clear ;;
        7) systemctl status xrayls.service ;;
        *) echo -e "${RED}无效的选项 ${choice}${PLAIN}" ;;
    esac

    echo && read -p "按回车键继续..." && echo
}

# 主程序
main() {
    
        show_menu
    
}

main 
