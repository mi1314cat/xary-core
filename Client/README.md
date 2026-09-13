# A/ — 最新可上传版本

这个目录里的东西就是**当前最新版本**，可以直接上传 GitHub。

```
A/
├── xbd-install.sh          ← 单文件自解压安装脚本（想只传一个文件就传它）
├── bin/xbd                 ← CLI 入口
├── lib/                    核心模块（Python + shell）
├── service/  scripts/      systemd 单元与运行脚本
├── docs/                   文档
├── VERSION                 版本号
└── nodes/ config/ ...      运行时目录（部署后使用，上传时可忽略）
```

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
