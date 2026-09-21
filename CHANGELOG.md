# Changelog

## 3.7 (未发布)

- **测试基建（零测试 → 34 case 全绿）**：`Shared/ProxyCore.swift` 把 ProcInfo/FilterRule/ProxyConfig/ProxyPatch/ConfigMerge 抽为纯 Foundation 共享源——Host 与扩展的配置字典解析合并为 `ProxyConfig.parse` 单一来源（3.6.1 的「includePids 空数组=显式清空」等语义定案由测试锁死）。`Tests/ProxyCoreTests.swift` 34 case：FilterRule 匹配全语义（tree/pid/truncated 降级/回环防护/系统白名单）、配置 round-trip 与两态兼容、merge 语义（含清扫空集落字典）。test bundle 独立运行（不依赖宿主 app——CLI/GUI 双态 `main()` 当 test host 会把 xctest 参数当命令 exit(2)）。跑法：`xcodebuild -scheme ProxyCoreTests test`。
- **GUI 路径规则可见可删**：监控区从只显示 pid 扩展为 pid + include 路径规则 + exclude 排除规则三类（CLI 建立的 `--include`/`--exclude` 规则此前在 GUI 不可见）；删除走热更通道秒生效。
- **`--remove-exclude`**：CLI 此前 exclude 只能加不能删（只能 `--fresh` 重建）——补上移除语义，与 GUI 删除按钮共用。
- **一键安装 + GUI 首启激活引导**：README 换 brew URL 直装（免 tap/trust 两步，`brew install --cask "https://github.com/0pen1/homebrew-tap/raw/main/Casks/netproxy.rb"`）；GUI 检测扩展未激活时显示醒目引导卡（激活按钮直达，替代藏在 ⚙ 菜单的入口）；cask caveats 同步。NE 系统扩展的用户批准流程无法自动化（Apple 安全模型），这是可达的最简安装形态。

## 3.6.1 (2026-09-20)

- **宿主版本号同步发版节奏**：release.sh bump 步骤同时更新宿主与扩展两个 Info.plist（此前只 bump ext——宿主 GUI 头一直显示 v1.1）。仓库现状一次性对齐 3.6.1（Info.plist / project.yml / pbxproj）。
- **cask 去 sudo 化**：tap `Casks/netproxy.rb` 拿掉 `uninstall delete: db.plist`——升级不再需要 sudo（NESM 登记归系统管，brew 不该碰）。release.sh tap 环节先 `pull --rebase` 再最小替换（只动 version/sha 两行），防覆盖远端 cask 结构。

## 3.6 (2026-09-20)

- **冷启自动重试（开机竞态自愈）**：apply() 冷启路径改两轮制——首轮 startVPNTunnel→waitConnected(15s) 失败后自动 stop→start 重试一轮（会话 connected 时 NESM 对 startVPNTunnel 是 skip no-op，先停才有效；stop 卡死则直接放弃）。开机竞态下 NESM 自动拉起失败后状态机滞后，首轮 15s 超时是常态（真机 2026-09-19 开机实录），不重试会误报「僵尸 provider」。两轮都失败才上报 waitTimeout/startProxyMissing/stopTimeout，文案从「僵尸 provider」改口「NESM 状态机卡死」（GUI 建议重启 Mac）。新增 ApplyEvent.coldStartRetry，CLI/GUI 双端同步。
- **log show 时区坑定案（真机 2026-09-20）**：`log show --start` 只认本地时区格式 `YYYY-MM-DD HH:MM:SS`，ISO8601 带 Z 被静默忽略并返回空——verifyStartProxyLogged 永远查不到 starting: 行，此前一切「僵尸 provider」误报的真正根源。改用 DateFormatter 本地时区生成。
- ConfigXPC 可信客户端路径增加 `XcodeProj/build/` 放行（本地 xcodebuild 产物真机调试，与 DerivedData 同一构建链语义）。

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
