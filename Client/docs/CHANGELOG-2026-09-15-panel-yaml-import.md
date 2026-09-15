# 变更记录 2026-09-15：面板 YAML 导入修复 + 导入即自动固定证书（v2.2）

## v2.1：面板 YAML 粘贴失效（根因与修复）

### 问题：粘贴多行 YAML 变成一行 → 「没有解析出可用节点」

- 输入框是单行 `<input>`，粘贴多行内容换行被浏览器吞掉 → YAML 结构被压扁 →
  解析必然失败；链接类（天然单行）不受影响，所以表现为「只能加链接」。
- 连带发现 `node.py` CLI 把 `argv[2]` 直接当内容（传文件路径时返回空数组）。

**修复**：
| 文件 | 修改 |
|------|------|
| `A/lib/web/panel.py` | 单行输入框 → 6 行 `<textarea>`，placeholder 明确提示支持 YAML 整段粘贴 |
| `A/lib/node.py` | ① CLI 支持传本地文件路径（`os.path.isfile`）；② 退化解析加『重缩进重建』容错（粘贴常见多余前导缩进自动还原） |

## v2.2：导入即自动固定证书（Hysteria2 自签证书场景）

### 现象

Hysteria2 节点（服务端自签证书、YAML 里 `skip-cert-verify: true`）导入成功、
状态页也显示 LISTENING，但实际 SOCKS/HTTP 出口完全不通。日志：
`proxy/hysteria: CRYPTO_ERROR 0x12a: x509: certificate relies on legacy
Common Name field`。

### 根因

Xray 26.x 已移除 `allowInsecure`（mihomo 语义的 skip-cert-verify）。
服务端证书是“只有 CN、没有 SAN”的老格式（浏览器/TLS 库强制要求 SAN），
Xray 26.x 下必须用 `pinnedPeerCertSha256` 固定服务端证书指纹作为替代。
以前这一步要**手动**执行 `xbd cert <编号>`，用户导入后节点直接不可用。

### 修复（新行为）

`A/lib/actions.sh` 新增 `_xbd_autopin_cert()`，并在 `cmd_node_import_one`
落盘后**自动调用**：

1. 节点声明了 `allow_insecure / skip_cert_verify` 且尚无 `pinned_cert_sha256`
   → 导入时自动用 `tools/certprobe` 连服务端拉证书、取 SHA-256、写进节点文件；
2. 节点不需要（如 vless/reality/证书合法）→ 一切无感跳过；
3. 探测失败（节点离线/非 TLS）→ 只 warn，不阻断导入，可手动 `xbd cert <编号>` 补跑；
4. 服务端换签后指纹失效，重新固定即可（节点上 `xbd cert <编号>` 或 删了重导）。

效果：**导入即用**，不再需要任何手动操作。

### 部署注意（教训）

- 修复必须同步**两处**：`/opt/xray-browser-dialer/lib/`（运行时实际加载）
  和 `/opt/xray-browser-dialer/xbd-dist/lib/`（发布模板）；
- `A/xbd-client.tar.gz` + `.sha256` 已用 `tools/make-release.sh` 重新生成。

### 回归验证

- `_xbd_autopin_cert` 单测：对自签证书节点成功取到 SAN 缺失证书的 SHA-256
  并写入 `pinned_cert_sha256`；
- 修复后实测：`xbd restart` → SOCKS5 `192.168.1.178:1080` 出口 `204` ✓
  HTTP `192.168.1.178:10809` 出口 `204` ✓（修复前 000/CRYPTO_ERROR）。
- 状态：`/opt/xray-browser-dialer/logs/error-normal.log` 若无新 error 且出口 204， 则终身有效。

## 范围限定

本次面板/CLI 两处入口语义 + 导入后证书自动固定。其他问题（生成脚本
域名错误修复、协议过滤 UA 口径）属独立仓库/项目，不在此处展开。

—— 修复者：AI 会话 2026-09-15
