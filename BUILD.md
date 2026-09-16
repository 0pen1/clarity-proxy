# BUILD.md — 从零到运行:完整构建手册

> 面向"换一台 Mac 从头复现"的场景。前提: macOS 12+,付费 Apple Developer 账号,
> 能正常访问 App Store。

## 0. 环境准备

```bash
# 1. 完整版 Xcode(App Store 安装,CommandLineTools 不够)
xcode-select -s /Applications/Xcode.app
xcodebuild -version   # 实测 15.4 可用

# 2. xcodegen 2.42.0(注意: brew 最新版 2.46 输出 objectVersion 77,Xcode 15 读不了)
curl -sL -o /tmp/xcodegen.zip \
  "https://github.com/yonaskolb/XcodeGen/releases/download/2.42.0/xcodegen.zip"
cd /tmp && unzip -oq xcodegen.zip
export PATH=/tmp/xcodegen/bin:$PATH
xcodegen --version   # 2.42.0

# 3. Xcode → Settings → Accounts 登录付费开发者账号(登录你的付费开发者账号)
```

## 1. 工程结构

```
NetProxy/
├── Sysex/                    # 系统扩展(数据面)
│   ├── main.swift            # 入口: startSystemExtensionMode + dispatchMain
│   ├── UDPFlow.swift         # BaseProvider(UDP override;不能 import Network!)
│   ├── Provider.swift        # 进程过滤 + TCPBridge(direct/SOCKS5)
│   └── Info.plist            # SYSX 元数据(版本号在这里改)
├── Host/
│   └── HostApp.swift         # CLI(控制面)
├── XcodeProj/
│   ├── project.yml           # xcodegen 定义 ← 团队 ID / bundle ID 改这里
│   └── netproxy/             # plist 与 entitlements 模板
└── README.md / GUIDE.md / DEBUGGING.md
```

## 2. 定制你自己的标识

`XcodeProj/project.yml` 中替换三处:

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: <你的TeamID>
targets:
  NetProxy:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: local.netproxy.<teamid 小写>
  NetProxyExtension:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: local.netproxy.<teamid>.extension
```

同步修改:
- `Host/HostApp.swift` 里 `ProxyCtl.extensionBundleID`
- `XcodeProj/netproxy/ext-Info.plist` 里 `NEProviderClasses` 的类名
  (`<module 名>.Provider`,module = bundle id 把 `.` 换成 `_`)
- 开发期 entitlements 用**裸值** `app-proxy-provider`(与自动生成的
  Development profile 一致);分发改 `app-proxy-provider-systemextension`
  + Developer ID profile + 公证。公证用 notarytool(端点
  `appstoreconnect.apple.com/notary/v2/` 直连可达,需 App Store Connect
  API key——完整流程见 GUIDE §3.4)。

## 3. 构建

```bash
cd XcodeProj
xcodegen generate
# 每次重新 generate 后必须补 embed 路径补丁(xcodegen 2.42 不支持 sysex 嵌入):
python3 - <<'EOF'
p='netproxy.xcodeproj/project.pbxproj'
s=open(p).read()
s=s.replace('''			dstPath = "";
			dstSubfolderSpec = 13;''','''			dstPath = "$(SYSTEM_EXTENSIONS_FOLDER_PATH)";
			dstSubfolderSpec = 16;''')
open(p,'w').write(s)
print('embed patched')
EOF

# 首次构建(自动注册设备/生成证书/profile;设备注册若报错,用 Xcode GUI 打开
# 工程点一次 Signing & Capabilities)
xcodebuild -project netproxy.xcodeproj -scheme NetProxy \
  -configuration Debug -derivedDataPath build build -allowProvisioningUpdates

# 验证签名链
codesign -dv build/Build/Products/Debug/NetProxy.app | grep TeamIdentifier
codesign --verify --deep --strict build/Build/Products/Debug/NetProxy.app && echo OK
```

## 4. 部署与激活

```bash
APP=build/Build/Products/Debug/NetProxy.app
sudo cp -R $APP /Applications/ 2>/dev/null || cp -R $APP /Applications/
xattr -rc /Applications/NetProxy.app        # 清 quarantine(本机构建其实没有,保险)

# 激活: 第一次会弹系统设置批准
/Applications/NetProxy.app/Contents/MacOS/NetProxy activate
systemextensionsctl list   # 目标状态: [activated enabled]
```

> 激活失败排查: 见 DEBUGGING.md B 节。最常见是 profile 与 entitlements
> 值不一致(开发期必须是裸值 `app-proxy-provider`)。

## 4.5 GUI 模式（v3.3+）

无参数启动 = 菜单栏 GUI；带参数 = CLI。两者共用同一控制面（NE 配置 + 热更通道），可混用：

```bash
open /Applications/NetProxy.app   # 菜单栏图标（盾牌）→ 点开面板
```

- 状态灯：绿=connected / 红=未激活或未配置 / 橙=连接中
- 监控区「+ 添加监控…」：进程选择器（sysctl 枚举 + 搜索名称/pid，root 进程只显示名+pid）
- 出口：直连 / SOCKS5（host:port）/ 网关 三档
- ⚙ 菜单：激活扩展（首次弹系统设置批准）/ 停用 / 卸载配置（确认）/ 复制诊断命令
- 单实例守卫：已有 GUI 运行时再 open 只激活既有实例

> 注意：**版本升级（替换 /Applications 里的 app）后先退出菜单栏 GUI**（图标右键退出）再部署，
> 否则旧实例持着 bundle 路径，新二进制不生效。

## 5. 运行验证

```bash
NP=/Applications/NetProxy.app/Contents/MacOS/NetProxy

# 起一个测试: 只拦 curl,直连转发
$NP start --include curl --upstream direct
sleep 5 && $NP status          # status: 3 = connected

# 观察: 另开终端实时看拦截
/usr/bin/log stream --info --debug \
  --predicate 'subsystem == "local.netproxy" AND category == "extension"'
# 然后跑 curl,应看到 "intercept /usr/bin/curl -> x.x.x.x:443"

# socks5 上游(本机 Clash/V2Ray 等)
$NP start --include curl --upstream socks5://127.0.0.1:7897
curl -sI https://github.com | head -1   # 200 = 经代理出站

$NP stop
```

## 6. 版本升级流程

改代码后:

```bash
# 1. bump 版本(ext-Info.plist 的 CFBundleShortVersionString/CFBundleVersion)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.x" XcodeProj/netproxy/ext-Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion x" XcodeProj/netproxy/ext-Info.plist

# 2. 构建 + 部署
xcodebuild ... && cp -R ... /Applications/

# 3. 重启隧道(顺序很重要)
$NP stop; sleep 5
$NP activate        # 走 replace
sleep 5
$NP start --include curl --upstream ...
```

激活 Code=4 或卡 validating → **重启 Mac**(只一次,别反复重试制造脏记录,
见 GUIDE 坑 9)。

## 7. 无付费开发者账号的替代路径

| 路径 | 可行性 | 说明 |
|---|---|---|
| 免费 Apple ID + Xcode 个人团队 | ⚠️ 不确定 | NE entitlement 不在个人团队自动 profile 里,实测过不了签名匹配;可尝试 Xcode 里手动加 capability |
| 自签证书 | ❌ | restricted entitlement 必须 Apple profile 背书,host 二进制直接被内核杀 |
| 关 SIP + `systemextensionsctl developer on` | ⚠️ 仅开发机 | Recovery 里 `csrutil disable` → 重启 → `systemextensionsctl developer on` → 自签可激活;本项目早期用 scripts/build.sh 的自签流程就是为这条路准备的 |
| 借用商用 app 的证书 | ❌ | 证书私钥不可用 |

## 8. 一键脚本(可选)

把 §3 的 generate+patch+build 固化:

```bash
cat > build.sh <<'EOF'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/XcodeProj"
/tmp/xcodegen/bin/xcodegen generate
python3 - <<'PYEOF'
p='netproxy.xcodeproj/project.pbxproj'
s=open(p).read()
s=s.replace('''			dstPath = "";
			dstSubfolderSpec = 13;''','''			dstPath = "$(SYSTEM_EXTENSIONS_FOLDER_PATH)";
			dstSubfolderSpec = 16;''')
open(p,'w').write(s)
PYEOF
xcodebuild -project netproxy.xcodeproj -scheme NetProxy \
  -configuration Debug -derivedDataPath build build -allowProvisioningUpdates
echo "产物: $(pwd)/build/Build/Products/Debug/NetProxy.app"
EOF
chmod +x build.sh && ./build.sh
```
