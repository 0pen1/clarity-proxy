# Changelog

## 3.5 (2026-09-18)

- **XPC 热更通道（公证版根治）**：解剖同机 Proxifier 3.15 实证其规则热更不走 NE IPC（3 天 NESM 日志零拒绝、Data 隧道零重启），而是宿主 ↔ root 扩展进程自建 NSXPC 直连（扩展 Info.plist `NEMachServiceName` + 双端自建 XPC 栈 `XPCClientForExtension`/`XPCServerInExtension`，方法表 `updateSettingWithSettings:profile:reply:`）。NetProxy 照抄架构：扩展侧 `ConfigXPC.swift`（listener = TeamID.扩展bundleID，proc_pidpath 校验连接方防 root 提权），宿主侧 `ConfigXPCClient.push`（2s 超时竞速）。apply() 热更链重排：① XPC 直连（公证版主通道）→ ② sendMessage（Development 有效）→ ③ 冷启兜底。详见 GUIDE §9 / 坑 20。
- **坑 21（GUIDE）**：公证版现役扩展不能被 Development 签名构建替换——卡 validating（notarization daemon: 3）+ 双记录 Code=4，重启唯一解。替换已公证扩展必须同样公证。
- **坑 22（GUIDE，反汇编定案）**：`NEMachServiceName` 必须 TeamID 前缀且扩展 entitlements 声明 `application-groups` 覆盖其前缀，否则 NESM 校验落 `SYSEXT_INVALID_MACH_SERVICE_NAME` 错误分支——该分支 `initWithFormat:` 传坏 `%@`（Apple bug）→ PAC 261 崩溃循环（20+ crash report），记录永久卡 validating。加 `3W73W8C23L.local.netproxy.3w73w8c23l` 后部署，NESM 崩溃即刻归零。
- **坑 23（GUIDE）**：`stapler staple` 嵌套 sysex 会往 sysex/Contents/ 写票据文件破坏宿主 seal →「已损坏」弹窗 + exec SIGKILL。sysex 永不 staple（3.3/Proxifier 均无票激活正常），只 staple 宿主。notarize.sh 已改。
- 真机验证：3.5/27 公证版 activated enabled；`start --include-pid` 输出 `✓ hot-reloaded via XPC`，扩展日志 `hot-reloaded(xpc): mode=... match=...`，provider pid 全程不变——隧道零重启规则即时生效。

## 3.4 (2026-09-18)

- **热更 fallback 假成功根治**：公证版 host 的 sendMessage IPC entitlement 被 NESM 拒（devid entitlements 只有 `-systemextension` 后缀值，NESM 检查要裸 `app-proxy-provider`），fallback 落回冷启时若会话仍 connected，`startVPNTunnel` 被 NESM skip（no-op）→ 新配置永远到不了 provider，GUI 卡「连接中…」。现在 fallback 先 `stopVPNTunnel` 并等 disconnected（10s 超时上报 stopTimeout）再 start。真机事故：GUI 加 pid → 热更被拒 → fallback skip → forever「连接中…」。

## 2.9 (2026-09-15)

- **gk 断连自愈**：网关重启/IPC 消失不再导致 bridge 永久失效——flow 提前 open（客户端字节缓冲于 NE），上游连接指数退避重连（250ms→10s），恢复后自动重发 IPC 头续传。真机验证 8s 断窗 9.1s 恢复，provider 状态机不再僵死。
- race 修复：waiting 分支先置 reconnecting 再 cancel（否则 cancelled 回调先到会 teardown flow）。

## 2.8 (2026-09-15)

- gk 模式 flow 提前 open（自愈第一步，见 2.9）。

## 2.7 (2026-09-15)

- TCPBridge 重连循环骨架（waiting/failed 排程重连）。

## 2.6 (2026-09-14)

- `--include-pid`：按祖先链 pid 精确匹配子树，零误伤（pid 死后警告）。

## 2.5 (2026-09-14)

- `--include-tree`：进程树匹配（祖先链任一路径命中）；gatekeeper 数据面进程无条件放行（回环防护）。

## 2.4 / 2.3 (2026-09-14)

- Provider.bridges 并发修复（NSLock）；SOCKS 会话内 TLS MITM 支持。

## 2.2 (2026-09-14)

- Phase 2 全链路 e2e：TCP IPC fallback（unix socket 被扩展沙箱拒）。
