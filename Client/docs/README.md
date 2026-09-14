# 架构与兼容性

本文只讲两件在这套系统上**容易踩坑**的事：架构为什么长这样，以及每个协议走浏览器转发的真实边界。
结论来自官方文档、官方源码，以及本机实测（Xray 26.3.27）；凡实测得出的都注明验证方式。

---

## 一、架构：唯一实例 + 两个入口

```
xray-client.service（唯一 Xray 进程，按当前节点决定带不带 XRAY_BROWSER_DIALER）
├── SOCKS5  :1080    绑 LAN    ← 所有节点通用
├── HTTP    :10809   绑 LAN    ← 所有节点通用
├── HTTP    :10808   绑回环    ← 本机 docker / apt / curl
└── :18081   绑回环            ← Xray ↔ Chromium 通道（浏览器转发用）

chromium-browser-dialer.service   浏览器转发时才需要（约 890MB）
browser-dialer-health.timer       每 30 秒确保它在该在的时候在线
```

**没有"普通模式端口"和"Browser Dialer 端口"之分。** 两个入口一直只由同一个 Xray 实例服务，
"用不用浏览器"由当前节点的开关决定，与入口无关。历史上曾拆成两个实例 + 两个 SOCKS 端口，
结果 10809 被两个进程同时绑定、请求随机落到其中一个，非常难排查 —— 不要走回头路。

### 关键约束：`XRAY_BROWSER_DIALER` 是进程级的

```go
func HasBrowserDialer() bool { return conns != nil }   // transport/internet/browser_dialer/dialer.go
```

进程启动时读一次环境变量，之后无法按节点改变。所以：

- **关掉浏览器时必须让这个进程不再带该环境变量** —— 见 `scripts/run-xray.sh`，它按当前节点的
  `use_browser` 决定带不带。只改节点文件不重启进程是无效的。
- 三处判定必须共用同一个来源（`compat.py want-bd`）：`run-xray.sh`、`health-check.sh`、`actions.sh`。
  各判各的会出现"一个说要、一个说不要"，而后果不是标签错，是节点**永久挂住**。

### 为什么"停掉浏览器"会让节点挂住

```go
conn = <-conns        // transport/internet/browser_dialer/dialer.go：没有 ctx、没有超时
```

只要进程带着 `XRAY_BROWSER_DIALER`，`xhttp` / `websocket` 出站就走浏览器。此时若 Chromium 不在线，
`dialTask()` 会**无限阻塞**：不报错、不回退、连接一直挂着。表现为"关了浏览器之后这个节点就没网了"。

因此顺序永远是：**先让节点切到原生 TLS（重启 Xray 去掉环境变量），再停 Chromium。**

---

## 二、浏览器转发支持什么（官方硬限制）

官方 `docs/config/features/browser_dialer.md`：

- 浏览器只能发出 HTTP 连接，所以**仅支持 WebSocket 与 XHTTP** 传输方式
- **`SNI == host == address`**，自定义 HTTP 头与其它 `tlsSettings` 项会被忽略
- 浏览器必须能直连该节点域名（用 tun 时注意环路）
- 需要处理 CORS
- 浏览器会限制连接数，建议开 Mux.Cool
- 版本门槛：WebSocket 需 `v1.4.1+`，XHTTP 需 `v1.8.19+`

源码里只有两处判断，**条件不同**：

```go
// transport/internet/splithttp/dialer.go:50      XHTTP
if browser_dialer.HasBrowserDialer() && realityConfig == nil { ... }

// transport/internet/websocket/dialer.go:114     WebSocket（没有 reality 条件）
if browser_dialer.HasBrowserDialer() { ... }
```

两者都**不检查代理协议** —— 浏览器转发在传输层，vmess / trojan 走 ws 时同样由浏览器完成 TLS。

### 兼容性矩阵（实测）

| 传输 | 安全 | 浏览器转发 | 说明 |
|---|---|---|---|
| `xhttp` / `splithttp` | tls / none | ✅ | 官方支持 |
| `xhttp` | **reality** | ❌ | 源码要求 `realityConfig == nil` |
| `websocket` / `ws` | tls / none | ✅ | 官方支持 |
| `raw` / `tcp` | — | ❌ | 浏览器发不出这种私有分帧 |
| `grpc` / `mkcp` / `httpupgrade` / `hysteria` | — | ❌ | 同上 |
| 任意 | reality + 非 raw/xhttp/grpc | ❌ | 实测报错：`REALITY only supports RAW, XHTTP and gRPC for now.` |
| `h2` / `h3` / `http` / `quic` | — | ❌ | 26.x 已移除：`The feature ... has been removed` |
| `hysteria2` | — | ❌ | 有它自己的 dialer，**不检查** `HasBrowserDialer` |

**重要**：hysteria2 在带 BD 环境的进程里能出网，但那是**原生 QUIC 通的**，浏览器完全不在路径上。
所以"浏览器路径是否可用"不能只看能否出网，必须确认浏览器在路径上 ——
见 `tools/browserprobe.py`：查 `privacy_mode`、请求期间 WS 是否仍在、Xray 有无自己直连。

### 版本与字段名

- 出站协议名：Xray 里是 `hysteria`（`version: 2`），**不是** `hysteria2`
- 传输字段：官方文档只用 `method`；实测 26.3.27 **只认 `network`**（`method` 被静默丢弃），
  所以 `lib/genconfig.py` **两个都写**，兼顾现在与将来
- `network` 不接受 `h2` / `quic`（已被移除）；`method` 照单全收但无效

---

## 三、WebSocket 的 early data（`?ed=`）

Xray 发给内嵌页面的 WS 任务里有 `extra.protocol` 字段，页面用它作为 WebSocket 子协议：

```javascript
const wss = new WebSocket(task.url, task.extra.protocol);
```

Go 侧只在 early data 长度 > 0 时才填充它：

```go
if streamSettings.ProtocolSettings.(*Config).Ed > 0 {
    conn = &delayDialConn{ ... }          // ed 非 nil，extra.protocol 才有值
} else {
    conn, _ = dialWebSocket(..., nil)     // ed = nil → extra 为空 → 页面抛 TypeError
}
```

**实测结论**：

- `ed` 只能通过 **URL 查询串**生效；`wsSettings.ed` / `earlyData` / `early_data` / `edMax` 全部无效
- 因此 `lib/genconfig.py` 把它拼到 `path` 上；`lib/node.py` 解析时把用户写的值记进 `ws_ed`，
  生成时优先用用户的值，**完全没有时才补 `?ed=2048`**（官方推荐值）
- 只对 `websocket` 生效，不污染其它传输

> 实测对照：同一节点 `path` 不带 ed → 内嵌页面 `Uncaught TypeError: Cannot read properties of
> undefined (reading 'protocol')`，连接必然失败；带 `?ed=2048` → 任务里带上 750 字节 early data，正常。

---

## 四、ECH（Encrypted Client Hello）

浏览器转发下 TLS 由 Chromium 完成，所以 **ECH 也只能由 Chromium 提供**，靠 Secure DNS 拿 ECHConfig。

`xbd ech` 的判据全部取自 Chromium 自己的 netlog，不是"看到 TLS 1.3 就算"：

- `ech_config_list` 非空 —— Chromium 拿到了 ECHConfig（base64 字符串长 96，解码后 71 字节）
- 到节点的连接 `privacy_mode == "enabled"` —— 该连接启用了隐私模式
- 外层 SNI 应是 `public_name`（如 `cloudflare-ech.com`），**内层 SNI 才是节点域名**

**不要用 `encrypted_client_hello` 字段数数**：它只出现在 TLS-over-TCP 的握手事件里；节点走
QUIC/HTTP3 时不会产生该字段，会得出"ECH 没生效"的**假阴性**（实测 5 次里错 2 次）。

**脆性**：ECH 依赖 Secure DNS 在线，而节点 ECHConfig 往往只有 DoH 服务器才返回
（实测本机系统 DNS 不返回 HTTPS 记录）。所以它是"能用则用"的增强，不要为它牺牲可用性 ——
**不要**在 `run-chromium.sh` 里加"DoH 预检 + `--host-resolver-rules` 钉 IP"那种加固：

> 曾加过一次，结果是 IPv6 优先钉死 + `mode=secure` 时 Chromium 拒绝解析任何域名，
> 连节点域名都解析不出来，三个入口全部 `SSL_ERROR_SYSCALL`。而且它看起来是好的：
> 端口在听、服务 active、WS 也连着，只是全部拨号失败。

---

## 五、能力判定 vs 实测

配置层面"合法"不等于"能通"。实测到两种判定覆盖不到的情况：

1. 同一套 ws 配置，某台服务器可用、另一台不行（服务端差异）
2. hysteria2 在 BD 环境下能出网，但走的是原生 QUIC

所以判定分三层，不要混：

| 字段 | 含义 | 用途 |
|---|---|---|
| `can_use_xray` | 配置层面 Xray 能起来 | 能否使用该节点 |
| `protocol_may_dialer` | 协议/传输层面**是否可能**走浏览器 | **决定 Chromium 能否停**（停了会挂住） |
| `can_use_dialer` | 综合判定 + **实测结果** | 界面显示"能不能用浏览器" |

`tools/browserprobe.py` 做真实探测（临时起 Xray + Chromium 跑一次请求，不动生产服务），
结果写进节点文件；判定读它。**判不出来就说判不出来，绝不假装支持。**

导入时还会自动：**剔除 Xray 内核不支持的协议**（`tuic` 之类）并**去重**（同协议/地址/端口/凭据），
结束时汇总说明跳过了什么。想留档加 `--keep-unsupported`。
