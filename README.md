# xray-core一键脚本
## 面板 3x-ui
```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```
## reality一键脚本

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/reality_xray.sh)
```

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/reality_xray_ip.sh)
```

## xary  vmess+ws or socks 脚本
### socks
```bash
bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xray.sh) socks
```
### vmess+ws
```bash
bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xray.sh) vmess
```
# xray服务管理
## 启用
```
sudo systemctl enable xray
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
