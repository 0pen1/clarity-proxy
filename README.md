# clarity-proxy

> Per-process transparent proxy for macOS — intercept, attribute, and audit every TCP flow your agent makes.

**macOS 按进程透明代理：截获、归因、审计 agent 的每一条 TCP 流量。**

AI agent 跑在你的 Mac 上，它调用的每个子进程都在联网。clarity-proxy 用 Network Extension 系统扩展在 flow 级截获出站 TCP，用 `sourceAppAuditToken` 精确还原到进程，按**进程树**（祖先链）或**精确 pid** 决定谁被拦，流量转发到 direct / SOCKS5 / 策略网关——对应用完全透明，对你完全可见。

## Why clarity

| 方案 | 进程识别 | 精度 | 代价 |
|---|---|---|---|
| **NE 系统扩展（本项目）** | audit token → PID → proc_pidpath | flow 级字节精确 | 需开发者账号+签名链 |
| TUN（sing-box/mihomo） | 用户态 socket 表反查 | 有竞态，UDP 无归属 | root + utun |
| pf | socket uid | 只到用户不到进程 | 无法按进程 |
| DYLD 注入（proxychains） | LD_PRELOAD | 差 | SIP 下无效 |

无 TUN 设备、无 pf 规则、无注入——**对目标进程完全透明**。

## Install (Homebrew)

```bash
brew tap 0pen1/tap https://github.com/0pen1/homebrew-tap
brew trust 0pen1/tap
brew install --cask netproxy
# One-time activation (manual, requires admin approval):
/Applications/NetProxy.app/Contents/MacOS/NetProxy activate
```

Releases are notarized (Developer ID + staple) — no Xcode or developer-account registration needed on the target machine.

## Quick start (from source)

```bash
# 1. 构建（需要付费 Apple Developer 账号，详见 BUILD.md）
./build.sh
cp -R XcodeProj/build/Build/Products/Debug/NetProxy.app /Applications/ && xattr -rc /Applications/NetProxy.app

# 2. 激活（首次在系统设置批准）
/Applications/NetProxy.app/Contents/MacOS/NetProxy activate

# 3. 启动——只拦 claude 进程树的流量，走本机 Clash
/Applications/NetProxy.app/Contents/MacOS/NetProxy start \
  --include-tree claude --upstream socks5://127.0.0.1:7897

# 4. 观察（claude 调 bash 跑 curl 也全被截获）
/usr/bin/log stream --info --debug \
  --predicate 'subsystem == "local.netproxy" AND category == "extension"'
```

## 菜单栏 GUI（v3.3+）

双击 `/Applications/NetProxy.app`（或 `open`）即启动菜单栏应用——无参数启动进 GUI，带参数启动仍是 CLI，两者共用同一控制面：

- **状态灯**：绿=已连接，红=未激活/未配置，橙=连接中
- **监控区**：点「+ 添加监控…」从运行中的进程列表选 pid（搜索支持名称/pid，root 进程只显示进程名）。点行即添加，删除按钮即时生效（热更通道，不重启代理）
- **出口**：直连 / SOCKS5 / 网关三档切换，SOCKS5 填 host:port 后点「应用」
- **⚙ 菜单**：激活/停用系统扩展（首次激活弹系统设置批准）、卸载配置（确认对话框）、复制诊断命令

> 已知边界：root 进程 `proc_pidpath` 拿不到路径，进程选择器只显示进程名 + pid（可搜索 pid 添加）。

## 上游模式

```bash
--upstream direct                     # 直连
--upstream socks5://host:port         # 经 SOCKS5（凭据见下）
--upstream gk --ipc-tcp 127.0.0.1:P   # 经策略网关（如 gatekeeper）逐 flow 转发
```

- **进程树匹配** `--include-tree claude`：连接发起时实时回溯祖先链，动态子进程天然覆盖，孤儿进程放行
- **精确 pid** `--include-pid 1234`：只拦该实例及其枝干，零误伤；可叠加（merge 语义），`--remove-pid` 增删
- **网关模式（gk）**：每条 flow 带 IPC 头（pid/proc/祖先链/真实目标）转发给网关进程判定+审计；网关断线自动退避重连，客户端连接停滞不中断
- **SOCKS5 上游**：无认证与 user/pass（RFC 1929）

## 文档

| 文档 | 内容 |
|---|---|
| [BUILD.md](BUILD.md) | 从零构建：环境、签名三档对比、profile 获取、部署激活、升级流程 |
| [GUIDE.md](GUIDE.md) | 完整实践指南：方案选型依据、架构、**17 个踩坑全记录**（带日志证据）|
| [DEBUGGING.md](DEBUGGING.md) | 故障速查：症状 → 根因 → 修复 |

## 环境

- macOS 12+，Apple Silicon/Intel
- 完整版 Xcode 15.4 + xcodegen 2.42.0
- 付费 Apple Developer 账号（Network Extensions capability）

## Status

实测状态（v2.9，macOS 14.4 arm64）：系统扩展激活/替换升级、TCP 按进程路径/树/pid 拦截、direct/socks5/网关三种上游、网关断线自愈、merge 语义多 pid 监控。已知边界：UDP 不拦（设计如此，见 GUIDE §7）。

## License

Private — all rights reserved（签名分发凭据见 BUILD.md）。
