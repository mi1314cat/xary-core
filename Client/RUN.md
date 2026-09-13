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

## 两个代理入口，二选一

| 端口 | 模式 | 什么时候用 |
|---|---|---|
| `1080` | 普通 Xray | 平时用这个 |
| `1081` | Browser Dialer | 需要真实浏览器 TLS 指纹时（先 `xbd dialer on`） |

局域网设备在 WiFi/系统设置里填 **`<服务器IP>` + 对应端口** 即可。

---

## 常见问题

**Q: 端口被占用怎么办？**
安装时会自动挑没被占用的端口。装完想换：`xbd port`（查看）→ `xbd port normal 2080`（修改）。
冲突检查：`xbd ports check`，自动重分配：`xbd ports fix`。

**Q: 关闭 Browser Dialer 会不会把 Xray 也停了？**
不会。两者生命周期完全独立 —— 关闭 Browser Dialer 只停它自己和 Chromium，Xray 继续跑。
未启用 Browser Dialer 时 Chromium 完全不运行（0 进程）。

**Q: 某个节点显示「Browser Dialer 不可用」？**
正常。Browser Dialer 只支持 `VLESS + WebSocket/XHTTP + TLS`。该节点仍可用普通模式。
如果切到这类节点时 Browser Dialer 正开着，会自动关闭它。

**Q: hysteria2 节点连不上，报 legacy Common Name？**
节点用的是自签证书。执行 `xbd cert <编号>` 取指纹固定即可（一条命令）。
注意：服务端换证书后要重新执行一次。

**Q: 会不会动我系统里已有的 Xray / mihomo？**
不会。只写自己的目录（默认 `/opt/xray-browser-dialer`）和自己创建的 systemd 单元。
不碰 `/usr/local/etc/xray`、`xray.service`、mihomo、防火墙、路由。

---

## 卸载

```bash
xbd uninstall        # 会先列出将删除的清单，确认后才执行
```
