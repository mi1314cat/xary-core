# xray-core一键脚本
## xray-sock5
```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xrayM-sock5.sh)
```
## 面板
### 轻量
```bash
bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh)
```
### docker Marzban
```bash
sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
```
## reality一键脚本

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/reality_xray.sh)
```

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/reality_xray_ip.sh)
```
## 安装升级 Xray-core
```
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```
## xary  vmess+ws or socks 多端口脚本
### socks
```bash
bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xrayL.sh) socks
```
### vmess+ws
```bash
bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xrayL.sh) vmess
```
# xray服务管理
## 启用
```
sudo systemctl enable xray
```
## 设置开机自启， 并立即启动服务
```
systemctl enable --now xray.service
```
## 禁用
```
sudo systemctl disable xray
```
## 启动
```
sudo systemctl start xray
```
## 停止	
```
sudo systemctl stop xray
```
## 强行停止
```
sudo systemctl kill xray
```
## 重新启动	
```
sudo systemctl restart xray
```
## 查看状态
```
sudo systemctl status xray
```
## 查看日志	
```
sudo journalctl -u xray --output cat -e
```
## 实时日志	
```
sudo journalctl -u xray --output cat -f
```
