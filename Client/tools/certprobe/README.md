# certprobe — 取 QUIC/HTTPS 服务端证书指纹

用途：某些节点用**自签证书**（证书里只有 CN、没有 SAN）。Xray 26.x 已移除
`allowInsecure`，替代方案是 `pinnedPeerCertSha256`（把服务端证书哈希写进配置）。
这个工具用来取那个哈希。

```bash
go run . <地址> <端口> <SNI>
```

输出示例：

```
证书链长度: 1
  [0] Subject=CN=addons.mozilla.org
      Issuer =CN=addons.mozilla.org      ← Issuer 与 Subject 相同 = 自签
      SAN    =[]                          ← 没有 SAN，所以 Xray 会拒绝
      SHA256 =4cdbcabc0ae7df752b56efe4fdc97933c8df7904e501eccd8863f5799695c7d7
```

把 `SHA256` 填进节点的 `pinnedPeerCertSha256` 即可。

**注意**：证书换了（续签/重签）这个哈希就失效，需要重新取一次。
