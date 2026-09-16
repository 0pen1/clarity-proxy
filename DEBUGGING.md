# DEBUGGING.md — 故障速查表

> 症状 → 根因 → 修复。每条都在 2026-09-14 的 macOS 14.4 上实际踩过/验证过。
> 详细原理见 GUIDE.md。

## A. 构建期

| 症状 | 根因 | 修复 |
|---|---|---|
| `ambiguous type lookup 'NWEndpoint'` | `import Network` + `import NetworkExtension` 同名类型 | UDP override 拆到不 import Network 的文件(类继承,不能用 extension) |
| `'main' attribute cannot be used in a module that contains top-level code` | 文件名 main.swift = 顶层入口 | 改名 + `-parse-as-library`,或去掉 @main 用顶层代码 |
| `Undefined symbols: _audit_token_to_pid` | 未链 libbsm | `-lbsm` |
| `Unable to read project ... format (77)` | xcodegen ≥2.43 输出新格式 | 用 xcodegen 2.42.0 |
| Xcode 打开工程闪退 `_formatForMissingPreferredProjectFormatAttribute` | 同上(GUI 也读不了 77) | 同上 |
| `Extension not found in App bundle` (Code=4, 首次) | sysex 被嵌到 PlugIns 而非 SystemExtensions | Copy Files phase: `dstPath=$(SYSTEM_EXTENSIONS_FOLDER_PATH)` `dstSubfolderSpec=16` |
| `Device isn't registered in your developer account` | CLI 自动注册设备不生效 | Xcode GUI 打开工程,Signing 页点一次注册 |

## B. 签名/激活期

| 症状 | 根因 | 修复 |
|---|---|---|
| host 二进制 exit=137 (SIGKILL) | 带 restricted entitlement 但无 profile 背书 | 全链 Apple 证书 + profile;开发期可裸签 host 先跑逻辑 |
| amfid: `No matching profile found` | 同上 | 同上 |
| 激活 Code=8 `Invalid code signature or missing entitlements` | ① entitlements 值与 profile 不一致 ② `get-task-allow` 注入 ③ 证书链无效 | ① 对齐字面值(开发期=裸值) ② `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` ③ `codesign --verify --deep --strict` |
| 激活 Code=3 `must be in /Applications folder` | host 不在 /Applications | `cp -R` 过去(xattr -rc 清属性) |
| 激活 Code=4 `Extension not found`(部署后) | ① Info.plist 与请求 identifier 不一致 ② **db 双记录死锁** | ① 核对 extensionBundleID ② `systemextensionsctl list` 看两条记录 → 重启 |
| 卡 `[validating by category]` | ① Developer ID 未公证 ② provider 反复崩溃使 NE 校验挂起 | ① notarytool 公证(端点 appstoreconnect.apple.com/notary/v2/ 直连可达,见 GUIDE §3.4) ② 先修 provider(见 D) |
| `-67050 代码未能满足指定的代码要求` | 公证校验失败(无公证票据,Gatekeeper 在线查票不通) | notarytool 公证 + stapler staple(见 GUIDE §3.4);开发期换 Apple Development 路线 |
| `spctl --master-disable` 后仍被拒 | sysextd 校验独立于 Gatekeeper 全局开关 | 无效操作,别浪费时间 |
| 激活后 `[terminated waiting to uninstall on reboot]` | 版本被替换,旧版待卸 | 正常,重启后消失 |

## C. 隧道启动期

| 症状 | 根因 | 修复 |
|---|---|---|
| `status: 1` 永不 connected;NESM: `plugin disconnected with reason Plugin initiated`(半秒内) | provider 端 startProxy 抛错或进程异常 | 看 provider 自身日志(下面 D);常见=excludedNetworkRules 构造非法 |
| NESM: `NEFlowDivertPlugin(...[inactive])` 且 startProxy 不执行 | ① NEProviderClasses 类名缺 module 前缀 ② 入口点 _NSExtensionMain | ① `<module>.<ClassName>` ② `LD_ENTRY_POINT: _main` |
| provider 启动即崩 52 次,sigtrap `Couldn't retrieve XPCService dictionary` | 入口点错误(App Extension 路径) | 同上② |
| startProxy 日志有但隧道仍 disconnected | setTunnelNetworkSettings 抛错(NWHostEndpoint port "0") | port 用 "1" 占位 |
| provider 连上游 `waiting: ECONNREFUSED`(本机 socks) | 回环被自己的 include 规则 policy-loop | excludedNetworkRules 加 127.0.0.1/32 |
| `内部错误，VPN会话失败` (host status) | 同 "Plugin initiated" | 同上第一行 |
| start 后 provider 进程在但完全无日志 | 僵尸 provider(deactivate 残留),NESM 复用旧进程 | `sudo kill -9 <pid>` 或重启 |

## D. 数据面

| 症状 | 根因 | 修复 |
|---|---|---|
| 拦截后连接静默消失,无任何 bridge 日志 | TCPBridge 是 handleNewFlow 局部变量,ARC 释放 | Provider 强引用 + onDone 回调清理 |
| curl 000 超时,bridge 停在 preparing | 上游不通(本机代理没开/端口错) | 先 `nc -z 127.0.0.1 <port>` 验证上游 |
| 个别域名 000 但其他 200 | DNS 污染(目标解析到假 IP),与代理无关 | 上游代理侧处理 DNS |
| UDP 流量不被拦 | 设计如此(handleNewUDPFlow 返回 false) | 需实现 UDP ASSOCIATE,见 GUIDE §7 |

## E. 状态机清理(卡死急救)

```bash
# 1. 观察当前状态
systemextensionsctl list
plutil -p /Library/SystemExtensions/db.plist | grep -E 'identifier|state'

# 2. 有多条同 identifier 记录(死锁) → 重启(唯一可靠清理)
# 3. 僵尸 provider
ps aux | grep local.netproxy | grep -v grep
sudo kill -9 <pid>

# 4. 配置残留 → host uninstall 命令删除重建
/Applications/NetProxy.app/Contents/MacOS/NetProxy uninstall
```

## F. 日志命令速查

```bash
# 激活链路
/usr/bin/log show --last 10m --info --debug --predicate 'process == "sysextd"' --style compact

# 隧道链路
/usr/bin/log show --last 10m --info --debug --predicate 'process == "nesessionmanager" AND eventMessage CONTAINS "NetProxy"' --style compact

# 自己的 provider(必须 --info --debug)
/usr/bin/log show --last 10m --info --debug --predicate 'subsystem == "local.netproxy"' --style compact

# 实时流(拦截观察)
/usr/bin/log stream --info --debug --predicate 'subsystem == "local.netproxy" AND category == "extension"'

# amfid(签名拒绝细节)
/usr/bin/log show --last 5m --predicate 'process == "amfid"' --style compact

# root 扩展崩溃报告在这里(不是 ~/Library/...)
ls -t /Library/Logs/DiagnosticReports/ | head
```

> 提醒: 交互 shell 里 `log` 是 zsh 内建会报 `too many arguments`,用 `/usr/bin/log`。
