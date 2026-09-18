# macOS 透明代理按进程分流 — 完整实践指南

> 基于 `NETransparentProxyProvider` 的真实落地记录。
> 环境: macOS 14.4 (arm64) / Xcode 15.4 / 付费 Apple Developer 账号(Individual)。
> 所有结论均经本机实测验证,非理论推导。
> 完成日期: 2026-09-14。可运行的完整实现见本目录 `NetProxy/`。

---

## 0. 一句话结论

macOS 上对**指定进程树**做透明代理,生产级正解是 **Network Extension 的
`NETransparentProxyProvider`(app-proxy-provider-systemextension)**:
每个 TCP flow 携带 `sourceAppAuditToken`,可精确还原到进程路径,按进程
include/exclude 后把 flow 双向泵到 direct/SOCKS5 上游。

---

## 1. 方案选型(为什么是 NE)

| 方案 | 进程识别 | 精度 | 代价 | 结论 |
|---|---|---|---|---|
| **NETransparentProxyProvider** | audit token → PID → proc_pidpath | 字节级精确(flow 级) | 需开发者账号+签名链 | ✅ 生产正解 |
| TUN(sing-box/mihomo) | 用户态 socket 表反查 | 有竞态;UDP 无归属 | root+utun | 个人工具可接受 |
| pf `user` 匹配 | socket uid | 只到用户不到进程 | 需专用用户+rdr 两跳 | pf 的 `user` **不能**用于 rdr 翻译规则,只能 filter 规则 |
| proxychains-ng | LD_PRELOAD | 差 | SIP 下对系统二进制无效 | ❌ |
| Proxifier 等成品 | 同 NE | 精确 | 商业闭源 | 无定制空间 |

选型结论的实测依据:
- pf.conf(5) BNF:`user|group` 只在 `filteropt-list` 里,`rdr-rule` 无此字段。
- NE flow 的 `NEFlowMetaData.sourceAppAuditToken`(macOS 10.15+)是唯一可靠的
  进程归属原语,`audit_token_to_pid`(libbsm)+ `proc_pidpath`(libproc)还原路径。

---

## 2. 架构

```
┌────────────────────────────────────────────────────┐
│ NetProxy.app (/Applications)                       │
│  └─ Contents/Library/SystemExtensions/             │
│      └─ local.netproxy.<team>.extension.systemextension │
└────────────────────────────────────────────────────┘
        │ activate/start (控制面)              │ 数据面
        ▼                                      ▼
┌──────────────────┐                 ┌──────────────────────────┐
│ Host CLI         │                 │ sysex 进程 (root, sandbox)│
│ NETransparent-   │  startVPNTunnel │ NETransparentProxyProvider│
│ ProxyManager     │ ──────────────▶ │  handleNewFlow(flow)      │
│ saveToPreferences│                 │   auditToken→pid→path     │
└──────────────────┘                 │   filter include/exclude  │
                                     │   TCPBridge: flow ⇄ NWConn│
                                     │   (direct / SOCKS5)       │
                                     └──────────────────────────┘
```

- **控制面**:`NETransparentProxyManager`(继承 NEVPNManager)写偏好配置,
  `providerConfiguration` 字典传参(会被 Apple 记入系统日志,**勿放凭据**)。
- **数据面**:内核把匹配 `NENetworkRule` 的连接转成 `NEAppProxyTCPFlow` 交给
  扩展进程;扩展内 `handleNewFlow` 决定拦不拦(返回 false = 系统放行),
  拦下则起 `NWConnection` 双向泵。

### 代码结构(全部在仓库内,可直接抄)

| 文件 | 职责 | 行数 |
|---|---|---|
| `Sysex/main.swift` | 顶层入口: `NEProvider.startSystemExtensionMode()` + dispatchMain | ~10 |
| `Sysex/UDPFlow.swift` | `BaseProvider`: UDP override(单独文件,见坑 #1) | ~12 |
| `Sysex/Provider.swift` | 进程缓存/过滤规则/TCPBridge(direct+SOCKS5)/Provider | ~370 |
| `Host/HostApp.swift` | CLI: activate/deactivate/discover/start/stop/status/uninstall | ~230 |
| `XcodeProj/project.yml` | xcodegen 工程定义(两 target+签名配置) | ~60 |
| `scripts/build.sh` | 旧的自签构建脚本(保留供无开发者账号路径参考) | — |

---

## 3. 签名链路(最难的部分,逐级说明)

### 3.1 三档签名路径实测对比

| 路径 | entitlements 值 | profile | 是否可激活 | 卡点 |
|---|---|---|---|---|
| 自签证书(无 Team ID) | 任意 | 无 | ❌ | host 二进制直接 SIGKILL(exit 137),扩展 Code=8 |
| Developer ID(未公证) | `app-proxy-provider-systemextension` | Developer ID profile | ❌ | AMFI 在线查公证票据,被墙网络 `-67050` |
| **Apple Development(推荐开发期)** | `app-proxy-provider`(裸值!) | Mac Team Development profile | ✅ | 无 |

关键认知:**entitlements 值必须与 profile 的 `networkextension` 数组逐字一致**。
- Development distribution 的 profile 给**裸值**(`app-proxy-provider`)。
- Developer ID/Ad Hoc distribution 的 profile 给**带后缀值**
  (`app-proxy-provider-systemextension`)。
  (证据: Xcode capabilities 缓存 JSON 里 `distributionTypes` 与 values 的绑定。)
- Proxifier 实机样本: 其 profile 与二进制 entitlements 均为带后缀值,
  因为它是 Developer ID + 已公证。

### 3.2 必需的 profile 获取步骤(付费账号,网页 2 分钟)

1. developer.apple.com → Identifiers:为 host(`local.netproxy.<team>`)和
   扩展(`....extension`)各建 App ID,**勾选 Network Extensions capability**。
   (Xcode 自动签名首次构建时也会自动建。)
2. Profiles → + → **Developer ID Application**(分发用)或直接用 Xcode 自动
   签名生成的 "Mac Team Provisioning Profile"(开发用,推荐)。
3. 下载的 `.provisionprofile` 放入
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 与
   `~/Library/MobileDevice/Provisioning Profiles/`(两处都放最稳)。
4. 手动签名时 Xcode 构建会自动把 profile 打进 `Contents/embedded.provisionprofile`
   (host 和 sysex 各一份)。

### 3.3 设备注册

`xcodebuild -allowProvisioningDeviceRegistration` 在"首次注册设备"场景经常
不生效(报 `Device isn't registered`)。实测有效的路径:
- **Xcode GUI 打开工程 → Signing & Capabilities → 选 Team → 自动注册**(一次即可);
- 注册后 CLI 的 `-allowProvisioningUpdates` 就能自动续 profile。

### 3.4公证问题(Developer ID 路径)

- 未公证的 Developer ID 扩展在 category 校验阶段被拒:
  `Error checking with notarization daemon: 3` → `-67050 代码未能满足指定的代码要求`。
- ~~本机公证 API(`api.notarization-service.apple.com`、`gc.apple.com`)被网络阻断,
  走本机代理(Clash 7897)也 TLS 被重置 → 无法自行公证。~~
  **注(2026-09-16 修正):这是误判**——`api.notarization-service.apple.com` 是 altool
  时代的旧 notary API(2023-11 已停用),`notarytool` 根本不连它。从 notarytool 二进制
  抽取的真实端点只有一个:`https://appstoreconnect.apple.com/notary/v2/`。
  实测该域名**直连即通**(无凭证返回 401,服务器正常响应)——公证无网络障碍。
  当时"走 Clash 也 TLS 被重置"的现象是旧域名/旧节点的组合,对本机公证流程无参考价值。
- `spctl --master-disable`(Gatekeeper 关闭)**不能**豁免 sysextd 的独立校验路径。
- `stapler validate` 对已公证 app(如 Proxifier)工作正常 → trustd 本身健康,
  只是"无票据 + 在线查询不通"必拒。
- **结论(修正)**:开发期用 Apple Development 路线;正式分发走 notarytool 公证
  (需 App Store Connect API key)。流程:
  1. 从内向外签:先 `codesign` sysex(`--options runtime --timestamp` +
     devid entitlements 带后缀值 `app-proxy-provider-systemextension`),再签 host app;
  2. `ditto -c -k --keepParent NetProxy.app NetProxy.zip`(不能直接传 .app;
     ditto 保留符号链接/权限,普通 zip 会坏);
  3. `xcrun notarytool submit NetProxy.zip -p <keychain-profile> --wait`
     (凭证先用 `notarytool store-credentials` 存钥匙串;失败看
     `notarytool log <submission-id>`);
  4. `xcrun stapler staple NetProxy.app` + `stapler validate` +
     `spctl --assess -t exec -vvv`。

---

## 4. 完整踩坑清单(按踩到顺序,每条都有日志证据)

### 坑 1: `Network.NWEndpoint` 与 `NetworkExtension.NWEndpoint` 同名歧义 ⭐️

`handleNewUDPFlow(_:initialRemoteEndpoint:)` 的参数在 Swift 里是
**NetworkExtension.NWEndpoint**(ObjC 类),与 `import Network` 的
NWEndpoint(枚举)**同名**。两个框架同时 import 时该 override 无法标注类型,
报 `ambiguous type lookup`。

**解法**: 拆文件——UDP override 放进不 `import Network` 的文件
(本仓库 `Sysex/UDPFlow.swift` 的 `BaseProvider`),其余代码在主文件
`import Network`。extension 不能承载 override,必须是类继承链。

### 坑 2: `@main` 与 `main.swift` 互斥

文件名 `main.swift` = 顶层入口,不能再用 `@main`。
**解法**: Host 改名 `HostApp.swift` + `swiftc -parse-as-library`。
(扩展的 main.swift 保持顶层代码风格,这是 SYSX 的正常形态。)

### 坑 3: `audit_token_to_pid` 链接失败

符号在 libbsm,SDK 无 tbd 到处可见但 `swiftc` 不自动链。
**解法**: `OTHER_LDFLAGS: -lbsm`(或 swiftc `-lbsm`)。

### 坑 4: xcodegen 2.46 输出 objectVersion 77,Xcode 15.4 读不了

Xcode 15.4 CLI 报 `future Xcode project file format (77)`;
**Xcode GUI 打开会直接崩溃**
(`+[PBXProject _formatForMissingPreferredProjectFormatAttribute] unrecognized selector`)。
**解法**: 用 xcodegen **2.42.0**(输出 54/56)。不要手改 pbxproj 的
objectVersion——77 格式的字段集 15.4 也读不懂。

### 坑 5: 系统扩展必须嵌入 `Contents/Library/SystemExtensions/`

xcodegen 的 embed 走 `dstSubfolderSpec = 13`(PlugIns),sysex 不被识别
(`Extension not found in App bundle` Code=4)。
**解法**: 手改 Copy Files phase 为
`dstPath = "$(SYSTEM_EXTENSIONS_FOLDER_PATH)"` + `dstSubfolderSpec = 16`。
(每次 `xcodegen generate` 后都要重新打此补丁。)

### 坑 6: restricted entitlement 的 AMFI 校验链

- host 二进制带 NE entitlement 但无 profile 背书 → **内核直接 SIGKILL**,
  amfid 日志: `Restricted entitlements not validated, bailing out ... No matching profile found`。
- 连带发现:`systemextensionsctl developer on` 需要关 SIP,macOS 14 仍如此。
- **解法**: 全链路 Apple 证书 + 对应 profile(见 §3)。

### 坑 7: profile 与 entitlements 值逐字比对

`Provisioning profile ... doesn't match the entitlements file's value for the
com.apple.developer.networking.networkextension entitlement` —— 把 entitlements
改成 profile 数组里的**字面值**(开发期=裸值)即可通过签名;但要想让系统激活,
**必须用对应 distribution 的正确组合**(见 §3.1 表格)。

### 坑 8: `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES` 注入 `get-task-allow`

Developer ID 手动签名时该默认值把 `get-task-allow=true` 注入二进制,
不在 profile 允许集合内 → 激活 Code=8。
**解法**: `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`。

### 坑 9: db 双记录死锁(激活 Code=4)⭐️⭐️

同一 identifier 存在两条记录(如一条 `validating_by_category` 悬空 + 一条
`activated_enabled`)时,sysextd 对该 identifier 的**一切**请求
(activate/deactivate)都报 `activateDecision found two entries` → Code=4。
- db 位于 `/Library/SystemExtensions/db.plist`,**SIP 保护,root 也写不了**;
- staging 目录 `/Library/SystemExtensions/<uuid>/` 同样受保护,`sudo rm` 报
  `Operation not permitted`;
- `sudo pkill sysextd` 后 restore 不清悬空 validating 记录;
- **唯一可靠解法: 重启**。重启时 restore 按 staging 目录存在性清理
  (目录缺失的记录被删)。因此:**避免反复 deactivate;升级版本后第一次激活
  失败先重启再试,不要连续重试制造更多脏记录**。

### 坑 10: 公证阻断(见 §3.4)

### 坑 11: 入口点错误 `_NSExtensionMain` ⭐️⭐️⭐️(最隐蔽,浪费最久)

xcodegen 的 `type: app-extension` target 默认 `LD_ENTRY_POINT = _NSExtensionMain`
(App Extension/PlugInKit 路径)。系统扩展必须普通 `_main`
(自己 main.swift 的顶层代码)。后果: provider **spawn 成功但启动即
SIGTRAP**,崩溃栈:
```
_xpc_copy_xpcservice_dictionary.cold.2  "Couldn't retrieve XPCService
_xpc_connection_create_service_listener   dictionary from service bundle"
-[NSXPCListener resume] → xpc_main
```
launchd 显示 `service has crashed 52 times in a row`。
**解法**: `LD_ENTRY_POINT: _main`。验证: `otool -l <bin> | grep -A1 LC_MAIN`。

### 坑 12: `NEProviderClasses` 类名必须带 Swift module 前缀

Info.plist 里写裸 `Provider` → NESM 实例化失败,plugin 永远 `[inactive]`,
`startProxy` 永不被调用。
**解法**: `<string><bundle_id_点换下划线>.Provider</string>`（如 `local_clarity_XXXXXXXX_extension.Provider`）
(Swift runtime 的 ObjC 类名 = `<module>.<ClassName>`)。

### 坑 13: `NWHostEndpoint` 的 port "0" 非法

构造 `NENetworkRule` 用 `NWHostEndpoint(hostname:port:)`,port 填 `"0"` 会让
`setTunnelNetworkSettings` 抛错 → provider 报 `Plugin initiated` 断开,
隧道永远 connected 不了。
**解法**: port 用任意合法占位(如 `"1"`)+ prefix 表达网段。

### 坑 14: TCPBridge 生命周期 —— 局部变量被释放

`handleNewFlow` 里创建 `TCPBridge` 后返回 `true`,函数栈结束 bridge/conn
被 ARC 释放 → NWConnection 静默 cancel,连接无日志消失。
**解法**: Provider 持有 `[TCPBridge]` 强引用数组 + `onDone` 回调在
`teardown` 时移除。

### 坑 15: 回环必须加 `excludedNetworkRules`

SOCKS5 上游在本机(127.0.0.1:7897)时,不排除回环 → provider 的
NWConnection 被自己的 include 规则(policy loop)挡住,
日志: `conn waiting: ECONNREFUSED` 永远连不上。
**解法**:
```swift
settings.excludedNetworkRules = [
    NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: "127.0.0.1", port: "1"),
                  remotePrefix: 32, localNetwork: nil, localPrefix: 0,
                  protocol: .any, direction: .outbound)
]
```

### 坑 16: CLI 参数解析两个经典错误

- Xcode Run 注入 `-NSDocumentRevisionsDebugMode YES` 进 argv;
- `--include`/`--upstream` 的**开关词**被"过滤以 `-` 开头参数"的过滤器误删。
**解法**: 过滤白名单化(`-NS` 前缀、YES/NO),并保证 apply 收到的参数
是"命令词之后"的切片。

### 坑 17: deactivate/activate 循环产生僵尸 provider

旧 provider 进程(root)在新配置 start 时被 NESM 复用,但其 session context
已失效 → `startProxy` 永不执行、`extension starting` 后无下文。
`kill` 普通权限杀不掉 root 进程。
**解法**: `sudo kill -9 <pid>`;或重启一劳永逸。长期修法是 host 在
deactivate 完成后确认 provider 进程退出再 activate。

### 坑 18: 换仓库/构建链变更后产物配置链断裂（2026-09-16 实录）⭐️

从原始仓库迁移到独立仓库后直接 `xcodebuild`,两处静默断裂(编译全绿、
activate 成功,但 NESM `Plugin failed` / `started with PID 0`):

1. **NEProviderClasses 类名占位符未注入**——build.sh 的 `${MODULE_NAME}`
   注入只在 `DEVELOPMENT_TEAM` 环境变量存在时执行,直接 xcodebuild 不传
   变量时占位符裸奔进产物(`.Provider`)→ NESM 找不到 Provider 类。
   排查: `plutil -p <sysex>/Contents/Info.plist | grep -A2 NEProviderClasses`
   验证类名 = `<module>.Provider`(module = 二进制里 `_TtC35<module>...`
   mangled 名)。**修复**: 模板直接写死正确类名。
2. **embedded.provisionprofile 与 entitlements 值错配**——Xcode 自动签名
   选了 Developer ID profile(要求 `app-proxy-provider-systemextension`
   后缀值)而 entitlements 还是开发期裸值 `app-proxy-provider` → AMFI
   校验失败 → NESM spawn 返回 PID 0。
   排查: `security cms -D -i <sysex>/Contents/embedded.provisionprofile |
   plutil -p -` 对照 entitlements 值。**修复**: 让 Xcode 选回 Mac Team
   Development profile(裸值匹配)。

**核心教训**: 迁移构建链后"能编译 + activate 报 active"≠ 产物可用;每次
部署变更后用 `start` 的 `✓ verified`(connected + startProxy 落盘验证)
确认,不信 `proxy started` 字样。

### 坑 19: async 版 handleAppMessage override 风险

Swift async 版 `override func handleAppMessage(_:) async -> Data` 在
macOS 14.4 上疑似与 NEProvider 的 ObjC 派发不兼容(曾表现为 Plugin failed,
当时与坑 18 叠加无法归因)。**安全形态**: completion 版
`handleAppMessage(_:completionHandler:)`(参数类型 `((Data?) -> Void)?`,
注意 optional)。

### 坑 20: 公证版 sendProviderMessage 热更通道被 NESM 整体拒绝(2026-09-18 定案)⭐️⭐️

`NETunnelProviderSession.sendProviderMessage` 在公证版 host 上**永远失败**:
NESM 对每条 sendMessage IPC 做 entitlement 检查,要求调用方持有**裸值**
`app-proxy-provider`;而 Developer ID profile 只允许**带后缀值**
`app-proxy-provider-systemextension`(见 §3.1 的分布类型绑定)。错误日志:

```
nesessionmanager: process <pid> is not entitled to establish IPC with
plugins of type <ext-bundle-id>
```

- 本机 3 天日志 20 条该拒绝**全部**来自 NetProxy;同机的 Proxifier
  (同样只有后缀值 entitlements)零条——因为它根本不走这个通道(见 §9)。
- Development 签名的 host(裸值 entitlements)不受影响——这也是开发期
  "sendMessage 偶尔能用"的错觉来源。
- **结论: 公证版规则热更必须绕开 NE IPC**(§9 的 XPC 直连方案),
  sendMessage 热更只对 Development 签名构建有效,留作开发期通道。

### 坑 21: 公证版 ↔ Development 版不能互相替换(真机 2026-09-18)⭐️

现役扩展是 Developer ID 公证版时,直接部署 Apple Development 签名的
Debug 构建(同 identifier)再 activate:
- 不报错也不拒绝——**永远卡 `[validating by category]`**(sysextd 反复
  `Error checking with notarization daemon: 3`,每 10s 重试);
- 此次失败留下一条悬空 validating 记录 → 坑 9 双记录 → 后续一切
  activate(包括换回公证版)Code=4,**重启 Mac 唯一解**。

**规则**: 替换已公证扩展的构建**必须同样走 notarize.sh 公证**(签名
身份一致,category 校验走票据,秒过);Development 签名构建只能替换
Development 签名的现役扩展。升级流程(§6)中"拷贝 → activate"一步
前,先确认新构建已公证。

### 坑 22: NEMachServiceName 缺 application-groups 背书 → NESM 崩溃循环(2026-09-18 反汇编定案)⭐️⭐️

给扩展 Info.plist 加 `NEMachServiceName`(XPC 热更通道的 launchd mach
注册,§9)后,activate 永久卡 `[validating by category]`,且
**nesessionmanager 每 10s 崩一次**(EXC_BAD_ACCESS / PAC_EXCEPTION 261,
当天 20+ 份 crash report)。反汇编 nesessionmanager(arm64e 切片,UUID
与 crash report 吻合)定案:

- 崩溃点在 NESM 校验失败的**错误构造路径**:跳转表按 SYSEXT_* 错误码
  分发,本例是 `SYSEXT_INVALID_MACH_SERVICE_NAME` 分支;
- 该分支用 `NEResourcesCopyLocalizedFormatString` 取格式串
  (`%@ %@ %@ %s`),再 `[[NSString alloc] initWithFormat:]` 拼错误描述,
  静态引用 `NEMachServiceName` 与 `com.apple.security.application-groups`
  两个 key 名——**校验内容就是拿 mach 服务名对照扩展声明的 app group**;
- Apple 自身 bug:错误分支把一个未 PAC 签名的坏指针当 `%@` ObjC 对象
  传入 → `objc_opt_respondsToSelector` PAC 261 → NESM 死。校验永远
  完不成,失败记录永久悬空(坑 9 链)。

**判定规则**: `NEMachServiceName` 必须是 `TeamID.扩展bundleID` 形态,
**且扩展 entitlements 必须声明 `com.apple.security.application-groups`
覆盖该前缀**(Proxifier 实证:ext 声明宿主 group
`NXELXU5YLW.com.initex.proxifier.v3.macos`,mach 名
`NXELXU5YLW.com.initex...Extension` 被其覆盖)。我们加
`3W73W8C23L.local.netproxy.3w73w8c23l`(TeamID.宿主bundleID)后部署,
NESM 崩溃立即停止(部署后零新 crash report)。

**注意**: 该 entitlement 加在 ext-devid.entitlements / ext.entitlements
两份里;Developer ID profile 未列 application-groups 也照常激活(真机
3.5/27 实证,profile 只背书受限 entitlement,app-group 沙盒声明不走
profile 覆盖检查)。

### 坑 23: stapler staple 嵌套 sysex 会写坏宿主 seal(2026-09-18)⭐️

`xcrun stapler staple $SYSEX` 往 sysex/Contents/ 写一个票据文件(Apple
System Integration CA 二进制),而**宿主的 seal 在 codesign 时已封死**
→ 宿主 `codesign --verify --deep --strict` 报
`file added: .../CodeResources` → Gatekeeper 判「已损坏」→ exec SIGKILL
(137)。notarize.sh 曾为修坑 21 的误判(mach 名问题,实为坑 22)加了
sysex staple,反而引入本坑。

**规则**: **sysex 永远不要 staple**——3.3 与 Proxifier 扩展均无 ticket、
激活正常(sysextd category 校验走在线公证查询);只 staple 宿主 app
(写的是宿主自己的 CodeResources,不影响已封的子路径)。

---

## 5. 调试方法论(这套问题排查流程可直接复用)

### 5.1 日志三板斧

```bash
# ① 系统扩展守护进程(激活链路全在这)
/usr/bin/log show --last 10m --info --debug \
  --predicate 'process == "sysextd"' --style compact

# ② NE 会话管理(隧道启停、plugin 状态)
/usr/bin/log show --last 10m --info --debug \
  --predicate 'process == "nesessionmanager" AND eventMessage CONTAINS "NetProxy"' --style compact

# ③ 自己的 provider 日志(必须 --info --debug,Logger.info 默认不落盘!)
/usr/bin/log show --last 10m --info --debug \
  --predicate 'subsystem == "local.netproxy"' --style compact
```

注意 `log` 是 zsh 内置,会报 `too many arguments` —— 用 `/usr/bin/log`。

### 5.2 关键状态与错误码速查

| 现象 | 含义 | 指向 |
|---|---|---|
| `systemextensionsctl list` 显示 `[validating by category]` 超时 | category 校验未返回 | 公证阻断(Developer ID)或 provider 崩溃循环 |
| `[activated waiting for user]` | 等用户在系统设置批准 | ✅ 正常,去批准 |
| Code=3 `must be in /Applications` | host app 不在 /Applications | 拷过去再激活 |
| Code=4 `Extension not found` | bundle 扫描不到 **或** db 双记录 | 先查目录,再查 `db.plist` 记录数 |
| Code=8 `SignatureInvalid` | entitlements/profile 不匹配或注入了 base entitlements | §3.1 + 坑 8 |
| `exit=137` (SIGKILL) | host 带 restricted entitlement 无 profile | 坑 6 |
| NESM `plugin [inactive]` 且 startProxy 不执行 | 类名不对或入口点错 | 坑 11/12 |
| `status: 3` | NEVPNStatus connected | ✅ |
| `status: 1` | disconnected | 查 NESM "last stop reason" |

### 5.3 崩溃报告位置

- 用户进程: `~/Library/Logs/DiagnosticReports/*.ips`(JSON,首行 metadata 分隔)
- **root 的系统扩展**: `/Library/Logs/DiagnosticReports/local.netproxy*.ips`
  (不在用户目录!)解析:
  ```python
  import json
  raw = open(path).read().split('\n',1)[1]   # 第一行是元数据
  d = json.loads(raw)
  # faultingThread / threads / usedImages 取栈
  ```

### 5.4 验证签名链完整性

```bash
codesign -d --entitlements - <binary>              # 看实际 entitlements
codesign -dvv <binary> | grep -E "Authority|TeamIdentifier"
codesign --verify --deep --strict <app>
spctl --assess --type execute -vvv <app>           # GK 视角(与 sysextd 不同)
xcrun stapler validate <app>                       # 公证票据
security cms -D -i <embedded.provisionprofile> | plutil -p -   # profile 内容
```

---

## 6. 运维手册(日常使用)

```bash
APP=/Applications/NetProxy.app

# 首次: 激活扩展(弹系统设置批准)
$APP/Contents/MacOS/NetProxy activate

# 启动: 只拦 curl,走本机 Clash socks5
$APP/Contents/MacOS/NetProxy start --include curl --upstream socks5://127.0.0.1:7897

# 多规则: --include/--exclude 可重复,按可执行路径子串匹配
$APP/Contents/MacOS/NetProxy start \
  --include /Applications/Foo.app \
  --exclude Foo.helper --upstream direct

# 全部拦截(不传 --include 时,系统路径白名单外全拦)
$APP/Contents/MacOS/NetProxy start --upstream socks5://127.0.0.1:7897

# 状态/停止
$APP/Contents/MacOS/NetProxy status
$APP/Contents/MacOS/NetProxy stop

# 彻底卸载配置(遇状态机异常时)
$APP/Contents/MacOS/NetProxy uninstall

# 调试辅助: 查系统识别到的扩展属性
$APP/Contents/MacOS/NetProxy discover

# 观察实时拦截
/usr/bin/log stream --info --debug \
  --predicate 'subsystem == "local.netproxy" AND category == "extension"'
```

升级扩展版本流程(重要,避免坑 9/21):
```bash
# 1. 改代码 → 改 ext-Info.plist 版本号 → xcodebuild
# 2. ./scripts/notarize.sh(现役是公证版时,替换构建必须同样公证——坑 21)
# 3. 部署到 /Applications
# 4. stop 隧道 → 等 5 秒 → activate → 等 5 秒 → start
# 5. 若激活 Code=4/卡 validating → 重启后重试(只做一次)
```

---

## 7. 已知边界与后续方向

**当前限制**
- UDP 不拦截(`handleNewUDPFlow` 返回 false 交还系统)。要支持需实现
  SOCKS5 UDP ASSOCIATE 或 direct datagram 桥接。
- SOCKS5 仅无认证 CONNECT;目标地址用 IP(系统已解析),未用域名模式。
- 每连接一对泵线程,大并发需换 async/await 或连接池。
- include/exclude 是路径子串匹配,无通配符/正则。
- `providerConfiguration` 明文进系统日志,凭据类参数要走 Keychain。

**可选增强(按性价比排序)**
1. DNS 处理: 目前 DNS 走系统直连,要全局接管需加 `NEDNSSettingsManager`
   或在扩展里处理 UDP 53。
2. 进程匹配升级: 用 `sourceAppSigningIdentifier` 做代码签名身份匹配,
   防同名路径伪造。
3. 流量观测: `NWPathMonitor` + per-flow 计数,接一个状态面板。
4. mitm 支持: 桥接层换成 TLS 拦截(参考 mitmproxy_rs 的 IPC 架构,
   数据面外移到用户态代理进程,扩展只做转发)。

---

## 8. 参考实现与资料

- **mitmproxy_rs/mitmproxy-macos**(官方 NETransparentProxyProvider 开源实现,
  本项目的重要参照): `github.com/mitmproxy/mitmproxy_rs` 下
  `mitmproxy-macos/redirector/`。它的数据面走 Unix socket IPC 外移,
  架构上更干净;本项目为零依赖改在扩展进程内桥接。
- Apple 头文件(SDK 内,读头文件比文档准):
  - `NetworkExtension/NETransparentProxyProvider.h`(继承 NEAppProxyProvider)
  - `NetworkExtension/NEFlowMetaData.h`(audit token)
  - `SystemExtensions/SystemExtensions.h`(OSSystemExtensionRequest 全生命周期)
  - `bsm/libbsm.h`(audit_token_to_pid)
- Apple 论坛关键帖:
  - "DNS Proxy network extension doesn't..."(#776759): NE 类 sysex 卡
    validating = NE 侧问题
  - NETransparentProxyProvider 系列(handleNewFlow 返回 false = 系统放行)
- 本机实测对照样本: Proxifier.app(sysex 结构/entitlements/profile 逐项比对)。

---

## 9. 热更新架构: Proxifier 解剖与 XPC 直连方案(2026-09-18 实录)⭐️

### 9.1 问题: 为什么公证版改规则要么不生效、要么要把隧道推倒重来

NE 官方给 host → provider 的运行时通道只有一条:
`NETunnelProviderSession.sendProviderMessage` → provider 的
`handleAppMessage`。这条通道在公证版上被 NESM 的 IPC entitlement 检查
整体拒绝(坑 20),于是每次改规则都只能走"停隧道 → startVPNTunnel"的
冷启路径——而 NESM 状态机(坑 17 僵尸 provider、stop/start 竞态)和
内核 flow-divert 控制 socket 耗尽(reboot 唯一解)都在这条路径上等着。

### 9.2 Proxifier 为什么从不重启: 证据链(全部本机实测)

同机安装的 Proxifier 3.15(Developer ID + 公证,entitlements 带后缀值,
与 NetProxy 同款限制)改规则秒生效、隧道 3 天零次重启、扩展进程
(root)开机起活到关机。解剖结论:**它根本不走 NE IPC,规则热更走
自建 XPC 直连**。证据:

1. **NESM 日志对照**(最硬): 3 天 `nesessionmanager` 日志里
   `not entitled to establish IPC` 拒绝 20 条全是 NetProxy,Proxifier
   零条——若它走 sendMessage 必被同样拒绝。且 `Proxifier Data`
   (透明代理会话)3 天内零次 start/stop 命令。
2. **双方二进制都有自建 XPC 栈**:
   - 扩展: `XPCServerInExtension.swift`、`Starting XPC listener for
     mach service %@` 格式串、`IPCExtension`/`IPCBaseProtcol` 协议;
     运行时每次开机打一行 `Starting XPC listener for mach service <private>`。
   - 宿主: `XPCClientForExtension.swift`,方法表即热更协议——
     `helloWithVersion:reply:`(握手)、
     **`updateSettingWithSettings:profile:reply:`**(推送整份 profile:
     dump 出的 CProfileEx 结构含 m_Proxies/m_Chains/**m_Rules**/m_Options)、
     `retriveTickDataWithReply:`(反向拉状态)。
3. **mach 通道基础设施**: 扩展 Info.plist 声明
   `NEMachServiceName = NXELXU5YLW.com.initex.proxifier.v3.macos.ProxifierExtension`,
   `launchctl print system` 里该 mach 服务真实注册在 system domain;
   宿主持有 `temporary-exception.mach-register.global-name`
   (沙箱宿主自建反向 XPC 服务端,供扩展连回——双向 XPC)。
4. **排除其他通道**: App Group 容器存在但全空(非文件共享);
   无 LaunchDaemon、无 PrivilegedHelperTools、无 /tmp socket。

**为什么它永远不用重启**: 不改 providerConfiguration 就不碰
saveToPreferences/startVPNTunnel(NESM skip no-op 不可达)、不 stop/start
隧道(NESM 状态机竞态不可达)、不 deactivate/activate(坑 17 不可达)、
扩展进程每开机只 spawn 一次(flow-divert 控制 socket 耗尽不可达)。
规则变更 = 一条 XPC 消息,root 扩展进程内就地生效。

### 9.3 落地: clarity-proxy 的 ConfigXPC 通道(3.5 实现)

NetProxy 宿主**无沙箱**(比 Proxifier 条件更好,不需要
temporary-exception entitlement),照抄架构:

```
宿主 apply() 热更快路径:
  ① ConfigXPC.push(conf) — NSXPCConnection(machServiceName: ext 的
     NEMachServiceName, options: .privileged) 直连 root 扩展进程,
     2s 超时竞速 → 命中即热更完成,结束。
  ② 失败 → sendProviderMessage(Development 签名构建的有效通道)。
  ③ 再失败 → 冷启(stopTunnelAndWait → startVPNTunnel,兜底)。
```

- 扩展侧: `Sysex/ConfigXPC.swift` 定义 `ConfigXPCProtocol`
  (@objc protocol,`pushConfig(_:reply:)`) + `ConfigXPCServer`
  (NSObject, NSXPCListenerDelegate;把 providerConfiguration 字典喂给
  Provider 注入的 applyConfig 闭包——与 handleAppMessage 共用同一套
  解析)。Provider.startProxy 里启动 listener,**mach 服务名 =
  TeamID + 扩展 bundle ID**(Info.plist 的 `NetworkExtension.NEMachServiceName`
  声明同名——launchd system domain 注册由此生效,Proxifier 实证;
  裸 bundle ID 形态会触发坑 22 的 NESM 崩溃,已真机踩过)。
- 宿主侧: `Host/HostApp.swift` 的 `ConfigXPCClient.push` 同名协议
  客户端。
- **安全(必做,否则是提权漏洞)**: 扩展是 root 进程,listener 必须
  校验连接方——`NSXPCConnection` 的 `auditToken`(private API 形态:
  `extension NSXPCConnection { var auditToken: audit_token_t }`),
  `audit_token_to_pid` + `proc_pidpath` 校验路径 = 本 app 的
  `/Applications/NetProxy.app/Contents/MacOS/NetProxy`。Proxifier 同样
  这么做(其扩展有 audit token 校验类符号)。注: 签名校验
  `SecCodeCopyGuestWithAttributes` 需要 audit token → SecCode,
  sandbox 扩展内可用;进程路径校验对"替换二进制"攻击面足够(替换
  /Applications 下二进制本身需要管理员权限)。
- 消息内容: 与 handleAppMessage 相同的全量 providerConfiguration 字典
  (JSON/plist 序列化),扩展侧 `applyConfig` 就地生效。**持久化仍由宿主
  saveToPreferences 负责**(冷启时 startProxy 从 providerConfiguration 读)
  ——XPC 热更只改内存,与 NE 通道的语义分工不变。

### 9.4 实测注意

- `NEMachServiceName` 在 SDK 头文件无文档(0 命中),但 Proxifier 实证
  该键驱动 launchd system domain 注册;`launchctl print system` 的
  `M` 标志行可见。**三处必须逐字一致**: Info.plist 键值、
  ConfigXPCServer.machServiceName、宿主 ConfigXPCClient 的
  NSXPCConnection machServiceName——任何一处裸 bundle ID 形态都会
  lookup `No such process`(坑 22 的 invalid 形态)或连不上。
- 扩展的 NSXPCListener 生命周期: 在 startProxy 里创建并 resume,
  stopProxy 里 invalidate——进程被 NESM 复用时 startProxy 重入,
  listener 幂等重建。
- 若 mach 连接连不上(扩展刚冷启、listener 未起),落 ②/③ 兜底即可,
  无需等待重试——下次 apply 自然命中。
- **真机验证(3.5/27, 2026-09-18)**: `start --include-pid <pid>` 输出
  `✓ hot-reloaded via XPC`,扩展日志(subsystem local.clarity,
  category extension)`hot-reloaded(xpc): mode=... match=...`,
  provider pid 全程不变——隧道零重启,规则即时生效。
