# Xray Client

**Xray 常驻客户端 + Browser Dialer 按需增强**，带 Web 面板。
一个脚本部署，一个命令管理。

---

## 一键部署

在目标服务器上执行**一条命令**：

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/l.sh)
```

装完会问你要节点链接，粘贴即可。局域网设备连接地址会在末尾输出。

**或者下载压缩包手动装：**

```bash
curl -LO https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/xbd-client.tar.gz
tar xzf xbd-client.tar.gz && cd xbd-client
sudo bash RUN.sh
```

👉 **详细使用说明看 [RUN.md](RUN.md)** —— 一页讲完，不用读别的。

---

## 一键卸载

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/uninstall-xray-client.sh)
```

先看会删什么、不动手：

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/uninstall-xray-client.sh) --dry-run
```

保留节点配置再删（备份到 `/root/xbd-nodes-backup-<时间>.tar.gz`）：

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/uninstall-xray-client.sh) --keep-nodes
```

独立脚本，不依赖面板与 `xbd` 命令 —— 即使安装已损坏也能跑。
**只删本项目创建的东西**：每一项删除前都做归属校验，内容不指向本项目就跳过。
`/usr/local/etc/xray`、系统 `xray.service`、mihomo、防火墙与路由一律不碰。
详见 [RUN.md](RUN.md#卸载)。

---

## 它解决什么问题

```
局域网设备 ──┐
             ├─→ 这台服务器 ──→ 你现有的节点 ──→ Internet
Windows PC ──┘        │
                      ├── SOCKS5 :1080  ┐
                      └── HTTP   :10809 ┘ 同一个 Xray 实例，全部节点通用
                                          └─ 若该节点需要浏览器指纹，Xray 自动把 TLS 交给 Chromium
```

* **只有一个 Xray 实例、两个入口**：不用记"哪个端口对应哪种模式"，两个端口对所有节点都通用
* **Browser Dialer 是节点的属性，不是模式**：节点协议支持时自动走浏览器 TLS，否则走 Xray 自带 TLS
* **节点是共享资产**：同一个节点两种用法，不用导入两份，切换也不会改写节点
* **不碰你的环境**：只写自己的目录和自己创建的服务

---

## 命令速查

```bash
xbd status                  # 状态（含当前连接模式）
xbd node add "<链接>"        # 加节点（多协议 / 订阅 / 一次多个）
xbd node list               # 节点列表（含两种能力判定）
xbd node use <编号>          # 切换节点
xbd node latency            # 测延时（真实请求）
xbd dialer on|off           # 启用/关闭 Browser Dialer
xbd panel                   # 面板地址与令牌
xbd diagnose                # 全面诊断
xbd export                  # 导出连接配置
xbd cert <编号>              # 取服务端证书指纹（自签节点）
xbd xray check|update       # Xray 内核版本 / 更新
xbd uninstall               # 安全卸载（也可用上面的独立删除脚本）
```

---

## 详细文档

| 文档 | 内容 |
|---|---|
| [RUN.md](RUN.md) | **使用说明（先看这个）** |
| [README.md](README.md) | 功能概览与命令速查（本文件） |
| [docs/README.md](docs/README.md) | 架构、协议兼容性矩阵、early data / ECH 的实测结论 |

---

## 两种分发方式

### 方式一：整目录上传（推荐）

把 `A/` 里的 `bin lib service scripts docs VERSION` 传上去即可。在服务器上：

```bash
cd /path/to/project
./bin/xbd install
```

### 方式二：一键脚本 / 发布包

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/Client/l.sh)
```

`l.sh` 下载 `Client/xbd-client.tar.gz` → 校验 SHA256 → 解压 → 调 `RUN.sh` 安装。
本地改完源码后重新打包发布件：

```bash
bash tools/make-release.sh    # 生成 xbd-client.tar.gz + .sha256
```

> 发布包必须重新生成，否则线上拉到的是旧代码。

## 日常操作

```bash
xbd status                  # 状态（含当前连接模式）
xbd node add "<uri>"        # 加节点（支持 vless/vmess/trojan/ss/hysteria2、订阅、JSON、YAML）
xbd node list               # 节点列表（含"两种用法"的能力）
xbd node use <编号>          # 切换节点
xbd dialer on               # 启动 Chromium（Browser Dialer 的运行时依赖）
xbd dialer off              # 停掉 Chromium（Xray 继续运行，需要浏览器的节点会暂时不可用）
xbd diagnose                # 全面诊断
xbd ech                     # 验证 Chromium 原生 ECH
xbd panel                   # 面板地址与令牌
```

## 架构要点

```
xray-client.service（唯一实例，始终带 XRAY_BROWSER_DIALER）
├── SOCKS5  :1080   绑 LAN   ← 所有节点
├── HTTP    :10809  绑 LAN   ← 所有节点
├── HTTP    :10808  绑回环   ← 本机 docker/apt/curl
└── :18081  绑回环   ← Xray ↔ Chromium 内部通道（Browser Dialer）

chromium-browser-dialer.service  加载官方内嵌页面，真实完成 TLS（约 255MB）
```

**为什么"用不用浏览器"由节点决定，而不是让你选模式**：
Browser Dialer 在 Xray 里就是「出站的一种拨号方式」（`XRAY_BROWSER_DIALER`），
它只在 `xhttp`/`websocket` 且非 REALITY 时生效，其余节点 Xray 直接忽略它。
所以同一个实例、同一对端口就能服务全部节点 —— 不需要第二个实例，也不需要第二个端口。

* **Xray 是常驻底层客户端**：换节点不改配置、不重启服务（脚本会自动重启）。
* **Chromium 是 Browser Dialer 的运行时依赖**：它是唯一实例的常驻依赖，约 255MB。
  停掉它只影响"需要浏览器指纹"的节点，其余节点照常。
* **节点是共享资产**：同一个节点既可能走 Xray 自带 TLS，也可能走浏览器 TLS，
  由能力检查分别判定，不用导入两份，切换也不改写节点。

## 自检

```bash
./bin/xbd selftest
```

覆盖：多协议解析、双能力判定、配置生成、systemd 单元、脚本路径，
以及 **架构自检 `tools/selftest-arch.sh`** —— 它断言"两个入口必须由同一个 Xray 进程监听、
两个入口出口必须一致、不需要浏览器的节点在 Chromium 停掉后仍能出网"。
这几条是防止悄悄退回"双实例/双端口"的唯一手段（界面上看不出来）。
