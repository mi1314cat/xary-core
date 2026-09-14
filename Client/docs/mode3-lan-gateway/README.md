# 模式 3（局域网透明网关）—— 已完成的设计、实测依据与弃用说明

> **状态：已从工具中移除，本文档是它的完整存档。**
> 移除日期与原因见文末「为什么去掉」。这里保留全部**实测结论**，因为那些数据
> 是重新评估同类方案时最贵的东西 —— 重做一遍要花几个小时，而且踩的坑一模一样。

---

## 1. 它想解决什么

工具原本有两个模式：

| 模式 | 做什么 | 设备要配什么 |
|---|---|---|
| 1 不接管 | 只提供代理端口（LAN SOCKS5 :1080 / LAN HTTP :10809） | 每台设备在 WiFi/系统里手填代理 |
| 2 接管本机 | 本机进程（docker/apt/curl）走代理，**改已有配置而非新增** | 无 |

模式 3 想让**局域网里的手机、平板"什么都不用配"**就自动走代理：手机把网关指到这台
Linux 机器，机器在 nftables 层把流量劫持进 Xray。

目标（当时的要求）：
1. TCP 80/443 透明转发
2. **DNS 必须经过代理节点**（不能明文直连，否则 DNS 泄露）
3. IPv4 + IPv6 都要
4. UDP 只需处理 DNS（其余 UDP 不管）
5. 必须能一键关闭，关掉后机器上不留监听

---

## 2. 最终设计

```
手机（网关指向 192.168.1.178，DNS 也填它）
   │
   ├─ TCP 80/443 ──► nft prerouting: dnat 到 192.168.1.178:10810 (IPv4)
   │                             dnat 到 [fe80::…]:10810        (IPv6)
   │                     └─► Xray dokodemo-door + followRedirect
   │                          用 SO_ORIGINAL_DST 取回原始目标 → proxy 出站 → 节点
   ├─ TCP/UDP 53 ──► nft prerouting: dnat 到 :15353
   │                     └─► Xray dokodemo-door → dns-out 出站 → DoH 上游（**经节点**）
   ├─ UDP 443    ──► nft forward: reject（逼 QUIC 回落 TCP，否则一半流量绕过代理）
   └─ 其余       ──► nft forward 打 mark → postrouting masquerade → 正常转发
```

**关键约束：两个入站只在模式 3 开启时才存在。** 它们绑 `::`（双栈），常驻就等于把
透明入口和 DNS 暴露在公网 IPv6 上；而且直连透明口会自环。所以状态文件
`config/takeover.env` 里的 `TAKEOVER_LAN=on/off` 是**唯一**来源，`genconfig.py` 和
`actions.sh` 都读它（两处各判各的，就是本项目反复踩过的"判定打架"）。

正确顺序：
* **开**：先让透明入站在听 → 再装 nft（反过来会有一瞬间把设备送到没人听的端口）
* **关**：先删 nft（停止劫持）→ 再让入站消失

---

## 3. 实测依据（每条都花钱买过）

### 3.1 nft 的 `redirect` 不带地址 = **入接口的主地址**，不是回环

假手机（netns，网关指向本机）实测：包被 redirect 到 `10.99.0.1:10808`（veth 的地址）。
逐个地址验证：

| 假设落点 | 结果 |
|---|---|
| `10.99.0.1:10808`（入接口地址） | ★ 收到连接（我在那儿临时监听） |
| `192.168.1.178:10808` | 收不到 |
| `127.0.0.1:10808` | 收不到 |

**这直接判了旧实现的死刑**：旧规则是 `redirect to :10808`，而 Xray 的 HTTP 入站只监听
`127.0.0.1:10808` —— 对应到真实网络落点是 `192.168.1.178:10808`，那里没人听，
内核直接回 RST。实测假手机 `curl` 拿到 `rc=7`，耗时 **1 毫秒**。也就是说：面板上写着
"80/443 透明转发"，局域网设备其实**一台都走不通**，把网关指过来会**所有网页打不开**。

### 3.2 nft 1.0.9 的 `redirect` 不接受地址

```
redirect to 192.168.1.178:10810   → Error: syntax error, unexpected colon
redirect to [fe80::…]:10810       → Error: syntax error, unexpected colon
redirect to :10810                → ✓（只能给端口）
dnat to 192.168.1.178:10810       → ✓
dnat to [fe80::…]:10810           → ✓   ← IPv6 必须用方括号
```
所以透明转发一律用 `dnat to <地址>:<端口>`（确定性也更好，不随接口地址变化）。

### 3.3 Xray 不能监听 link-local

```
listen: "fe80::cb5e:434:5e7d:3c0f%eth0"
→ Failed to start: infra/conf: unable to listen on domain address: fe80::…%eth0
```
（`infra/conf/xray.go:168` 的校验；地址带 zone 过不了它的解析。）
不带 zone 也起不来（link-local 必须有 zone 才能 bind）。**结论：IPv6 侧只能绑 `::`。**

### 3.4 Xray 绑 `::` 是双栈

`ss` 显示 `*:10810` / `*:15353`，并且从 `127.0.0.1` 也能连上。于是：
* IPv4 与 IPv6 共用一个入站，不需要第二个入站；
* 代价是**暴露在公网 IPv6 上**（这台机器有 5 个全局 IPv6），必须靠 nft 挡：
  `tcp dport 10810 ct status ! dnat drop`（只放行被我们 DNAT 的），
  DNS 端口再加 `ip6 saddr != <本网段> drop`。

### 3.5 53 端口不能绑通配

```
listen: "::", port: 53
→ failed to listen TCP on [::]:53 > bind 0.0.0.0:53: address already in use
```
systemd-resolved 占着 `127.0.0.53:53` 和 `127.0.0.54:53`；绑通配会撞上。
**所以 DNS 入站用高位端口（15353），由 nft 把 :53 DNAT 过去。**
（另一个办法是关掉 resolved 的 stub listener，那会动到系统 DNS，不能为了一个可选模式去改。）

### 3.6 DNS 路径：两条路都能通，且上游真的走节点

用独立临时 Xray 实例（不碰生产）实测：

| 方案 | dig 结果 | 是否经节点 |
|---|---|---|
| `dns-in → proxy`（UDP 53 直送 8.8.8.8） | ✅ 172.66.147.243 | ✅ 日志 `[dns-in -> proxy]` |
| `dns-in → block` | ❌ 超时 | 证明路由规则对该入站生效 |
| `dns-in → direct`（对照） | ✅ | — |
| `dns-in → dns 出站`（DoH 上游） | ✅ | ✅ `from DNS accepted https://1.1.1.1/dns-query [-> proxy]` |
| 同上 + 路由里 block 掉上游 IP | ❌ 超时 | 证明 **DoH 上游受路由控制**，能强制走节点 |

选 **dns 出站 + DoH 上游**：全程加密，上游连接也走节点。

### 3.7 用户现有那套上游可以直接翻译过来（实测可用）

用户 mihomo 配置 → Xray 的对应关系：

| mihomo | Xray |
|---|---|
| `default-nameserver: 223.5.5.5/8.8.8.8` | `dns.hosts` 静态映射（给 DoH 主机名做引导） |
| `nameserver: 阿里 DoH / 腾讯 DoH` | `servers[].domains: ["geosite:cn"]` |
| `fallback: 1.0.0.1 DoH / dns.google DoT` | `servers[].domains: ["geosite:geolocation-!cn"]` |
| `fallback-filter: geoip CN` | `unexpectedIPs: ["geoip:cn"]`（国外解析器返回国内 IP 就判为不该用） |

实测（含 `hosts` 与不含各跑一遍）：

```
www.baidu.com  → 103.235.46.102   （命中 geosite:cn → dns.alidns.com）
www.qq.com     → 43.159.109.55    （同上）
www.google.com → 142.251.154.119  （命中 !cn → 1.0.0.1）
DNS 上游连接 2 条，全部 -> proxy；直连泄露 0 条
```
`hosts` 有没有都一样能跑（节点侧会解析 DoH 主机名），保留是为了确定性。

### 3.8 这台机器的网络环境事实

* **IPv4 直连外网是通的**（`http://1.1.1.1` → 301）；**IPv6 直连不通**（`-6 https://ipv6.google.com` → rc=28 超时），
  尽管有 5 个全局 IPv6 地址。
* **节点地址是 IPv6 字面量**（`2001:470:c:c22:…`），但两个备用节点是**域名**。
* **IPv6 转发的陷阱（最危险的一条）**：
  ```
  net.ipv6.conf.all.forwarding = 1     ← /etc/sysctl.conf 里持久化的
  net.ipv6.conf.eth0.accept_ra = 0
  ```
  这两个同时存在时，**一旦去改 `forwarding`，内核会删掉 RA 学来的默认路由**。
  而这台机器的节点走 IPv6 —— 那就是整体断网。
  **结论：接管逻辑里绝不碰 IPv6 转发 sysctl**，只检查；要动必须先 `accept_ra=2`。
  （IPv4 的 `ip_forward` 可以开，并记下原值供回滚。）

### 3.9 两个必须防的坑

* **自环**：客户端直连透明端口时没有 DNAT，`followRedirect` 会拿到"自己"当目标 →
  Xray 拨号到自己 → 递归。防护：`input` 链 `tcp dport <透明口> ct status ! dnat drop`。
  （实测直连 `127.0.0.1:10810` 得到 `rc=56`，连接被处理后又断开。）
* **MASQUERADE 只能作用于被转发的流量**：如果在 postrouting 里按"源地址属于局域网"
  就 masquerade，会连**本机自己**发起的连接一起改源地址 —— 包括到节点的那条（IPv6 源
  地址会变成轮换的临时地址）。防护：在 `forward` 链里给转发流量打 mark，
  postrouting 只对 `meta mark <mark>` 做 masquerade（本机自己的包不经 forward 链）。

---

## 4. 完整规则模板（可直接复活）

```nft
table ip xbd_takeover {
  set local4 { type ipv4_addr; elements = { 192.168.1.178, 127.0.0.1 } }
  set private4 { type ipv4_addr; flags interval;
    elements = { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 } }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iif "lo" return
    ct status dnat return
    tcp dport 22 return                       # SSH 保命，硬性
    udp dport 53 dnat to 192.168.1.178:15353  # DNS 全劫持（含指向路由器的，否则泄露）
    tcp dport 53 dnat to 192.168.1.178:15353
    ip daddr @local4 return                   # 本机自己的服务不动
    ip daddr @private4 return                 # 局域网互访直连
    tcp dport { 80, 443 } dnat to 192.168.1.178:10810
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    ip daddr @private4 return
    udp dport 443 reject with icmp type port-unreachable   # 逼 QUIC 回落 TCP
    ip saddr 192.168.1.0/24 meta mark set 0x2334
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    meta mark 0x2334 masquerade               # 只 NAT 被转发的流量
  }
  chain input {
    type filter hook input priority filter; policy accept;
    tcp dport 10810 ct status ! dnat drop     # 防自环（也挡住公网 v6 直连）
  }
}

table ip6 xbd_takeover {                      # 结构完全一致，字面量换成 v6
  set local6 { type ipv6_addr; elements = { ::1, fe80::<本机> } }
  set private6 { type ipv6_addr; flags interval;
    elements = { ::1/128, fe80::/10, fc00::/7, 2409:<前缀>::/64 } }
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iif "lo" return
    ct status dnat return
    tcp dport 22 return
    udp dport 53 dnat to [fe80::<本机>]:15353
    tcp dport 53 dnat to [fe80::<本机>]:15353
    ip6 daddr @local6 return
    ip6 daddr @private6 return
    tcp dport { 80, 443 } dnat to [fe80::<本机>]:10810
  }
  chain forward { … udp dport 443 reject with icmpv6 type port-unreachable … }
  chain postrouting { … meta mark 0x2334 masquerade … }
  chain input {
    type filter hook input priority filter; policy accept;
    tcp dport 10810 ct status ! dnat drop
    ip6 saddr != 2409:<前缀>::/64 udp dport 15353 drop   # 入站绑 ::，公网 v6 上必须只认本网段
    ip6 saddr != 2409:<前缀>::/64 tcp dport 15353 drop
  }
}
```

Xray 侧（`genconfig.py`，仅当 `TAKEOVER_LAN=on` 且 `mode == normal`）：

```python
inbounds.append({                       # 透明 TCP
    "tag": "transparent-in", "listen": "::", "port": 10810,
    "protocol": "dokodemo-door",
    "settings": {"network": "tcp", "followRedirect": True},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
})
inbounds.append({                       # DNS（端口不是 53，见 3.5）
    "tag": "dns-in", "listen": "::", "port": 15353,
    "protocol": "dokodemo-door",
    "settings": {"address": "1.1.1.1", "port": 53, "network": "tcp,udp"},
})
outbounds.append({"tag": "dns-out", "protocol": "dns"})
# 路由第一条必须是它：否则下面的私网直连规则会把"查询路由器 192.168.1.1:53"判成
# direct —— 那就是明文泄露，正是要避免的东西
routing_rules.insert(0, {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out"})
cfg["dns"] = DNS_UPSTREAMS   # 见 3.7 的翻译表
```

配套（已一并移除）：
* `core.sh`：`XBD_PORT_TRANSPARENT=10810`、`XBD_PORT_DNS=15353`（可由 `config/ports.env` 覆盖）
* `genconfig.py`：`--takeover-file` / `--transparent-port` / `--dns-port`
* 状态文件 `config/takeover.env`：`TAKEOVER_LAN=on|off`（+ `IFACE` / `LAN_V4` / `LAN_V6` /
  `LL_V6` / `IP_FORWARD_WAS` 供回滚）
* `actions.sh`：`xbd takeover on|off|status`；开=先起因再装规则，关=先删规则再停因；
  失败路径自动回滚状态（`xbd_takeover_rollback_state`）

---

## 5. 手机怎么配（当时给用户的说明）

**Android**：设置 → WLAN → 长按当前网络 → 修改网络 → 高级 → IP 设置 = 静态
* IP：`192.168.1.240`（高位，避开 DHCP 池）
* 网关/路由器：`192.168.1.178`
* 前缀长度：`24`
* DNS：`192.168.1.178`

**iPhone**：设置 → 无线局域网 → ⓘ → 配置 IP = 手动：IP/掩码 `255.255.255.0`/路由器 `192.168.1.178`；DNS 手动填 `192.168.1.178`。

两个提醒：这台机器一停/一重启，手机会**直接断网**；手机走 IPv6 时**仍然绕过**代理。

---

## 6. 实现度评估（诚实版）

| 部分 | 状态 |
|---|---|
| 透明 TCP 机制（dnat + dokodemo-door + followRedirect） | 机制验证过；**未做端到端实测**（被叫停） |
| DNS（dns-out + DoH 上游经节点） | ✅ 实测通过，零直连泄露 |
| IPv6 规则（ip6 表 + link-local DNAT） | 规则语法验证过；**未实测** |
| QUIC 拒绝 / MASQUERADE / 防自环 | 语法验证过；**未实测** |
| 手机端 IPv6 接管 | ❌ **做不到**：Android 静态配置只能设 IPv4 网关，IPv6 由路由器 RA 决定 → 手机的 v6 流量根本不经过这台机器（除非改路由器 RA，超出范围） |
| 手机端"零配置"承诺 | ❌ 做不到：必须手动把网关改成这台机器，路由器不用改但手机必须改 |
| 爆炸半径 | ⚠️ 整机变全屋网关：一条 nft 规则写错，全屋断网；而"接管本机"最坏只是本机进程没代理 |
| 与现有能力的关系 | 模式 3 只覆盖 TCP 80/443 + DNS；QUIC/其它端口要么拒要么直连，**不如显式代理完整** |

---

## 7. 为什么去掉（2026-09 决定）

1. **收益不成立**：模式 3 的唯一卖点是"设备不用配"，但手机照样要手改网关，
   而且 IPv6 永远接不住 —— 卖点本身是假的。
2. **完整性不如已有方案**：显式代理（模式 1，设备填一次 IP:端口）+ 接管本机（模式 2）
   覆盖了实际要用的场景，而且 UDP/QUIC/任意端口都能走（SOCKS5 支持 UDP）。
3. **风险与收益不对称**：为了"少填一个网关"，让一台家用机器承担全屋出口，
   并且要在 nftables 上动 DNAT/MASQUERADE/reject —— 出错代价是全屋断网。
4. **环境脆弱**：节点走 IPv6，而这台机器的 IPv6 转发处于"forwarding=1 且 accept_ra=0"
   的脆弱状态，任何触碰都可能把 IPv6 默认路由弄丢。
5. **维护成本**：三处判定（状态文件/genconfig/nft）必须永远一致，一旦漂移就是
   "面板说开着、实际没生效"这种最难查的问题。

**替代用法**：设备需要走代理时，用模式 1 在设备的 WiFi/系统设置里填
`192.168.1.178:1080`（SOCKS5，支持 UDP）或 `192.168.1.178:10809`（HTTP）；
本机自己的进程（docker/apt/curl）用模式 2，一键开关且是"改已有配置而非新增"。

---

## 8. 如果以后要复活

按第 4 节的规则与代码恢复即可，但**先做这三件事**：

1. 补上端到端实测（netns 假手机，IPv4+IPv6 各跑一遍 http/https/dns/quic/masquerade），
   至少要覆盖：`ct status ! dnat drop` 是否真的挡住了直连自环、QUIC reject 是否让
   客户端回落 TCP、MASQUERADE 有没有误伤本机到节点的连接。
2. 决定 IPv6 怎么办：要么接受"手机 v6 绕过"并写清楚，要么先解决 `accept_ra=2`
   （否则改 forwarding 会断网）。
3. 给 nft 规则加一条"应用后自检"：装完立刻从 netns 验证一遍 TCP/DNS 通不通，
   不通就自动回滚（模式 3 开关不该有"装上但没生效"的中间态）。
