# 怎么用（看这一页就够了）

## 一键部署（推荐）

在**目标服务器**上执行**一条命令**：

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/l.sh)
```

它会自动完成全部工作：下载 → 校验 → 解压 → 安 Xray → 分配端口 → 建 systemd 服务 → 启动 →
然后**问你要节点链接**（粘贴后回车即可）。

装完输出会告诉你局域网设备该连哪个地址。

---

## 方式二：下载压缩包手动解压

```bash
# 下载
curl -LO https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/xbd-client.tar.gz

# 解压
tar xzf xbd-client.tar.gz
cd xbd-client

# 一个脚本完成安装
sudo bash RUN.sh
```

压缩包内容：

```
xbd-client/
├── RUN.sh          ← 一键安装（解压后运行这一个）
├── l.sh            ← 方式一用的在线部署脚本
├── bin/xbd         ← 命令行工具
├── lib/            核心模块
├── service/        systemd 单元
├── scripts/        运行脚本
├── docs/           详细文档
└── tools/          辅助工具（打包、取证书指纹）
```

---

## 带节点直接装（不交互）

```bash
bash <(curl -Ls .../Client/l.sh) --vless "vless://..." --yes
```

也支持一次给多个节点（vmess / trojan / ss / hysteria2 / 订阅链接 / Xray JSON / Mihomo YAML）。

---

## 装完之后

只用一个命令 `xbd`：

| 命令 | 作用 |
|---|---|
| `xbd status` | 看状态（含当前连接模式） |
| `xbd node add "<链接>"` | 加节点（支持一次多个） |
| `xbd node list` | 节点列表（显示两种使用方式各自是否可用） |
| `xbd node use <编号>` | 切换节点 |
| `xbd node latency` | 测节点延时（真实请求） |
| `xbd dialer on` / `off` | 启用 / 关闭 **Browser Dialer** 模式 |
| `xbd panel` | 面板地址与访问令牌 |
| `xbd diagnose` | 全面诊断 |
| `xbd export` | 导出连接配置（Mihomo YAML / 链接 / 环境变量） |
| `xbd cert <编号>` | 取服务端证书指纹（自签证书节点用） |
| `xbd xray check` / `update` | 检查 / 更新 Xray 内核 |
| `xbd uninstall` | 安全卸载（先列清单） |

---

## 两个代理入口（都是全部节点通用）

| 端口 | 协议 | 什么时候用 |
|---|---|---|
| `1080` | SOCKS5 | 推荐。支持 UDP，Mihomo / 浏览器插件用它 |
| `10809` | HTTP | 设备只支持 HTTP 代理时（WiFi 设置里那种） |
| `10808` | HTTP（仅回环） | 本机进程：docker / apt / curl |

**没有"Browser Dialer 专用端口"**。两个入口都由同一个 Xray 实例服务；某个节点要不要用
浏览器来完成 TLS，由服务器按节点自动决定，你在客户端这边什么都不用改。

局域网设备在 WiFi/系统设置里填 **`<服务器IP>` + 对应端口** 即可。

---

## 常见问题

**Q: 端口被占用怎么办？**
安装时会自动挑没被占用的端口。装完想换：`xbd port`（查看）→ `xbd port normal 2080`（修改）。
冲突检查：`xbd ports check`，自动重分配：`xbd ports fix`。

**Q: 停掉 Chromium 会不会把 Xray 也停了？**
不会。`xbd dialer off` 只停 Chromium，Xray 与两个入口继续运行。
唯一影响：**需要浏览器指纹的节点**（Browser Dialer 那栏显示"支持"的）会暂时拨号失败，
其他节点完全不受影响。`xbd dialer on` 立刻恢复。

**Q: 某个节点显示「Browser Dialer 不支持」？**
正常。只有 `VLESS/Vmess + WebSocket/XHTTP + TLS`（非 REALITY）能交给浏览器。
这类节点会走 Xray 自带 TLS，用同一个端口，不需要你做任何切换。

**Q: 怎么确认这套"一个实例、两个端口"没被改坏？**
```bash
sudo bash /opt/xray-browser-dialer/tools/selftest-arch.sh
```
它会断言三件事：两个入口必须由**同一个** Xray 进程监听、两个入口出口必须一致、
不需要浏览器的节点在 **Chromium 完全停掉**时仍能出网。

**Q: hysteria2 节点连不上，报 legacy Common Name？**
节点用的是自签证书。执行 `xbd cert <编号>` 取指纹固定即可（一条命令）。
注意：服务端换证书后要重新执行一次。

**Q: 会不会动我系统里已有的 Xray / mihomo？**
不会。只写自己的目录（默认 `/opt/xray-browser-dialer`）和自己创建的 systemd 单元。
不碰 `/usr/local/etc/xray`、`xray.service`、mihomo、防火墙、路由。

---

## 卸载

**方式一：独立删除脚本**（推荐，不依赖面板/命令）

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/uninstall-xray-client.sh)
```

先看会删什么（不动手）：

```bash
bash <(curl -Ls .../Client/uninstall-xray-client.sh) --dry-run
```

删之前会保留节点配置：

```bash
bash <(curl -Ls .../Client/uninstall-xray-client.sh) --keep-nodes
```
（节点会备份到 `/root/xbd-nodes-backup-<时间>.tar.gz`）

**方式二：用命令**

```bash
xbd uninstall
```

### 它会删除什么

| 项目 | 说明 |
|---|---|
| 6 个 systemd 单元 | 先停止 → 禁用 → 删除并 reload |
| 安装目录 | 默认 `/opt/xray-browser-dialer`（含 Xray 内核、节点、日志） |
| `/usr/local/bin/xbd` | 仅当它指向本项目时 |
| 本机代理配置 | **只删自己写的**。`xbd proxy on` 若发现本机已有别的服务在接管系统代理（例如 mihomo 写的 `/etc/profile.d/*.sh`、`/etc/environment`），会**就地改那一份**而不是再新增一份来互相覆盖；此时 `proxy off` / 卸载会**还原原文件**，不会删掉别人的配置 |
| `/var/lib/xbd-proxy` | 接管时留下的原文件备份与归属记录（还原用） |
| docker 代理配置 | 同上判断 |
| nftables 残留规则 | 仅当 `table ip xbd_takeover` 存在时（旧版"接管局域网"模式遗留） |

### 它绝不会碰什么

* `/etc/xray`、`/usr/local/etc/xray`、`/usr/local/share/xray`
* `/usr/local/bin/xray`（系统自己的 Xray 二进制）
* `xray.service`、`xrayls.service`（系统自带的服务）
* mihomo 及其配置、其它用户服务
* 防火墙默认策略、路由表

**每一项删除前都做归属校验** —— 内容不指向本项目就跳过并提示，宁可不删也不删错。
