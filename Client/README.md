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
                      ├── 普通模式（:1080）   Xray 自己完成 TLS
                      └── Browser Dialer（:1081）  真实 Chromium 完成 TLS
```

* **Xray 常驻**：负责普通代理，永不为 Browser Dialer 让路
* **Browser Dialer 按需**：点点开关才启动，不用时不运行 Chromium（0 进程）
* **节点是共享资产**：同一个节点两种用法，不用导入两份
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
| [docs/README.md](docs/README.md) | 完整功能与架构 |
| `docs/ARCHITECTURE.md` | 数据流、端口、环路防护 |
| `docs/COMPATIBILITY.md` | 各协议的 Browser Dialer 兼容性（含源码依据） |
| `docs/TROUBLESHOOTING.md` | 排错 |

---

## 两种分发方式

### 方式一：整目录上传（推荐）

把 `A/` 里的 `bin lib service scripts docs VERSION` 传上去即可。在服务器上：

```bash
cd /path/to/project
./bin/xbd install
```

### 方式二：只传一个文件

```bash
./tools/build-bundle.sh      # 在项目根执行，重新生成 A/xbd-install.sh
```

然后只上传 `A/xbd-install.sh`，服务器上：

```bash
chmod +x xbd-install.sh
./xbd-install.sh install
./xbd-install.sh install --vless "vless://..."
```

`xbd-install.sh` 是**自解压脚本**：它会把自己内部的载荷释放到
`/opt/xray-browser-dialer/xbd-dist/`，然后调用 `xbd install`。
它和整目录版本内容完全一致 —— 每次构建都从 `A/` 源码生成，不做手工同步。

> **改完源码记得重新构建**：`./tools/build-bundle.sh`

## 日常操作

```bash
xbd status                  # 状态（含当前连接模式）
xbd node add "<uri>"        # 加节点（支持 vless/vmess/trojan/ss/hysteria2、订阅、JSON、YAML）
xbd node list               # 节点列表（含"两种用法"的能力）
xbd node use <编号>          # 切换节点
xbd dialer on               # 按需启用 Browser Dialer（会启动 Chromium）
xbd dialer off              # 关闭（Chromium 退出，Xray 继续运行）
xbd diagnose                # 全面诊断
xbd ech                     # 验证 Chromium 原生 ECH
xbd panel                   # 面板地址与令牌
```

## 架构要点

```
Xray Client（常驻）
├── 普通模式   :1080  ← 默认，Xray 自己完成 TLS
└── Browser Dialer :1081 ← 按需启用，TLS 交给 Chromium
```

* **Xray 是常驻底层客户端**，负责普通代理。
* **Browser Dialer 是按需增强**，关闭它不会停止 Xray。
* **Chromium 只是 Browser Dialer 的运行时依赖**，未启用时不运行（实测 0 进程）。
* **节点是共享资产**：同一个节点既可用普通模式，也可能支持 Browser Dialer，
  由能力检查分别判定，不用导入两份。

## 自检

```bash
./bin/xbd selftest
```

覆盖：多协议解析、双能力判定、配置生成、systemd 单元、脚本路径。
