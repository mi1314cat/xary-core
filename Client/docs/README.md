# Xray Browser Dialer Client

**一个文件**，让一台 Linux 服务器成为 Browser Dialer 网关：
局域网设备（Windows Mihomo 等）→ 这台服务器的 SOCKS5 → **本机真实 Chromium 完成 TLS**
→ 你现有的节点。这正是 Xray 官方的 Browser Dialer 机制，不是 `fingerprint: chrome` 伪装。

## 用法

```bash
# 上传到服务器后，直接跑
chmod +x xray-browser-dialer.sh
./xray-browser-dialer.sh install

# 或者装的时候就把节点带上
./xray-browser-dialer.sh install --vless "vless://UUID@host:443?encryption=none&security=tls&type=xhttp&path=/xx&sni=host"
```

装完打开面板（地址和令牌会打印出来）：

```bash
./xray-browser-dialer.sh panel
```

之后所有操作都能在面板里完成：看状态、加节点、切节点、改端口、启停服务、跑诊断。

## 它可以做什么

```
./xray-browser-dialer.sh <命令>

  install [--no-start] [--vless "vless://..."]   安装（幂等，可顺带导入节点）
  add "vless://..."                              添加节点（也支持 Xray JSON / Mihomo YAML）
  list / use <编号>                               节点列表 / 切换当前节点
  check [节点]                                    静态兼容性检查
  port [端口]                                     查看/修改 LAN SOCKS5 端口
  start | stop [--all] | restart                  生命周期
  status                                          状态摘要
  diagnose [--quick]                              全面诊断
  panel                                           面板地址与访问令牌
  config | mihomo                                 生成运行配置 / Mihomo 片段
  update                                          只更新本项目组件
  uninstall                                       安全卸载（先列清单再删）
  selftest                                        内置自检
```

## Browser Dialer 兼容性（实测结论）

| transport | 结果 | 说明 |
|---|---|---|
| XHTTP | ✅ | 官方支持，HTTP 版本由 Chromium 决定 |
| WebSocket | ✅ | 官方支持，early data 走 `Sec-WebSocket-Protocol` |
| TCP / gRPC / H2 / mKCP / QUIC / HTTPUpgrade | ❌ | 浏览器只能发 HTTP(S)，无对应实现 |
| REALITY | ❌ | `splithttp/dialer.go` 仅在 `realityConfig == nil` 时启用 Browser Dialer |

另外要求 `SNI == Host == Address` 且 address 是域名；TLS 由 Chromium 校验，
所以 `allowInsecure` / `skip-cert-verify` / `fingerprint` 都无效。
本项目**只报告问题，绝不自动修改节点参数，也不碰服务端**。

## 架构

```
Windows Mihomo → (LAN) → 本机 SOCKS5 (192.168.x.x:1080)
                              ↓
                         Xray 客户端（不做 TLS）
                              ↓
              Browser Dialer（Xray 内建，XRAY_BROWSER_DIALER=127.0.0.1:18081）
                              ↓  WS 回连 + fetch 转发
                  headless Chromium ← 真正发起 TLS 的一方
                              ↓
                         现有节点 → Internet
```

三个 systemd 单元：`xray-browser-client` / `chromium-browser-dialer` / `browser-dialer-panel`，
外加一个 `browser-dialer-health.timer` 每 30 秒心跳自愈（Xray 每次启动都会换 CSRF token，
浏览器必须跟着重启，否则代理会静默失效）。

## 安全边界

- SOCKS5 **只绑 LAN 地址**（默认 `192.168.x.x:1080`），绝不 `0.0.0.0`。
- Browser Dialer HTTP 只监听 `127.0.0.1:18081`；面板可配令牌。
- 只写 `/opt/xray-browser-dialer` 与自己创建的 5 个 systemd 单元。
- **绝不修改** `/etc/xray`、`/usr/local/etc/xray`、系统 `xray.service`、mihomo、防火墙、路由。
- 卸载只删除本项目的东西，删前先列清单。

## 依赖

`bash` `curl` `python3`(≥3.8) `unzip` `systemd` `ss` `ip`，以及一个真实浏览器
（Chromium/Chrome，缺失时脚本会尝试按发行版安装；**无法用其它方式替代**）。
Xvfb 不需要 —— headless Chromium 已实测可用。

## ECH 验证（Chromium 原生 ECH）

Browser Dialer 下 **TLS 由 Chromium 完成**，所以 ECH 也必须由 Chromium 发起 ——
Xray 的 `tlsSettings.echSettings` 在这条链路上不生效。用内置命令验证：

```bash
./xray-browser-dialer.sh ech            # 完整验证（隔离端口，不动生产服务）
./xray-browser-dialer.sh ech --quick    # 只查 DNS 侧 ECHConfig
./xray-browser-dialer.sh ech --keep     # 保留 netlog 等证据
```

判据全部来自 Chromium 自己的 netlog，而不是"看到 TLS 1.3 就算"：

| 证据 | 含义 |
|---|---|
| `ech_config_list` 非空 | Chromium 成功获得 ECHConfig |
| `encrypted_client_hello: true` | 该次握手**实际发出**了 ECH |
| 该事件邻近的 host == 节点域名 | ECH 确实作用在到节点的连接上 |
| Xray 日志 `XHTTP is dialing` 次数为 0 | TLS 是 Chromium 做的，不是 Xray |

状态分级：`ECH_ACTIVE` / `ECH_INACTIVE` / `ECH_UNAVAILABLE` / `ECH_UNKNOWN`。

### 关键前提：DoH 必须真的生效

本机实测（Chromium 151）：

* ECH 需要 Chromium 的 **Secure DNS**，而现代 Chromium **移除了**
  `--dns-over-https-mode` / `--dns-over-https-templates` 命令行开关；
  DoH 只能通过 profile 的 `Local State`（`dns_over_https.mode=secure` + `templates`）配置。
* 系统解析器不返回 HTTPS/SVCB 记录时，Chromium 拿不到 ECHConfig。
* 实测 `dns.alidns.com` 的 DoH 在本机直连可达且返回 ECHConfig；
  `cloudflare-dns.com` / `dns.google` 在本机被墙（才需要走代理）。

### 实测结论

* Chromium 原生 ECH **可用**（`ECH_ACTIVE`）。
* ECH 只在**新建** TLS 握手上生效；连接复用（XHTTP 会话池 / Mux）时不会有新握手，
  因此探测时临时配置会关闭 mux。
* Chromium 在 A 记录与 HTTPS 记录之间是**竞速**的，第一个连接常赶在 ECHConfig 之前
  回退为普通握手 —— 这是正常行为，不是配置错误。实测多次运行成功率约 80%。

---

## 项目结构

```
xray-browser-dialer/
├── xray-browser-dialer.sh     ← 唯一需要部署的文件（上传 GitHub 只需要它）
├── README.md
├── .gitignore
├── research/                  研究资料，部署不需要（ECH 论证工具与结论）
│   ├── README.md
│   ├── echprobe.py            查询 HTTPS/SVCB 记录里的 ECHConfig
│   ├── dnsfwd.py              极简 DNS 转发器（曾用于验证解析器行为）
│   └── xray-echtest.json      ECH 验证用临时配置
├── legacy/v1-multifile/       v1 多文件版（40 个文件），仅作历史参考，不再维护
└── backup/                    安装前的备份（tarball + 当时的 systemd 单元）
```

## 两份副本的关系

脚本同时存在两个位置，**内容必须一致**：

| 位置 | 用途 |
|---|---|
| `xray-browser-dialer/xray-browser-dialer.sh` | 开发副本，GitHub 上传的就是它 |
| `/opt/xray-browser-dialer/xray-browser-dialer.sh` | 服务器上实际运行的副本 |

改完开发副本后同步：

```bash
cp xray-browser-dialer/xray-browser-dialer.sh /opt/xray-browser-dialer/
cd /opt/xray-browser-dialer && ./xray-browser-dialer.sh update
chmod 0755 /opt/xray-browser-dialer/xray-browser-dialer.sh
```

也可以反过来：直接在 `/opt/xray-browser-dialer/` 里改，再拷回开发副本。

部署目录 `/opt/xray-browser-dialer/` 的结构（由脚本自动生成，不需要手工维护）：

```
/opt/xray-browser-dialer/
├── xray-browser-dialer.sh    主脚本（可从这里直接执行所有命令）
├── bin/                      Xray 二进制 + geo 数据
├── config/                   listen.env / browser-dialer.env / chromium.env / panel.env
├── lib/                      compat.py / genconfig.py / panel.py / echprobe.py / echcheck.py（安装时从主脚本展开）
├── scripts/                  run-xray.sh / run-chromium.sh / run-panel.sh / health-check.sh
├── service/                  5 个 systemd 单元
├── nodes/                    节点文件，current 指向当前选中
├── runtime/                  运行配置 + Chromium profile
├── logs/ access.log error.log
├── generated/                mihomo 配置等生成物
└── backup/                   更新二进制前的备份
```
