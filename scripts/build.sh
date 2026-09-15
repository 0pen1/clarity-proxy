#!/bin/bash
# [已废弃] 此脚本是早期"自签证书+swiftc 手工构建"流程,对应 GUIDE.md §7 的
# 无开发者账号路径。当前正路是 XcodeProj/ 的 xcodegen+xcodebuild 流程(见 BUILD.md)。
# 构建 NetProxy.app(含内嵌系统扩展)并用自签证书签名
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/NetProxy.app"
CERT="NetProxy Dev"

mkdir -p "$BUILD"

cat > "$BUILD/host.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.networking.networkextension</key>
	<array>
		<string>app-proxy-provider-systemextension</string>
	</array>
	<key>com.apple.developer.system-extension.install</key>
	<true/>
</dict>
</plist>
EOF

cat > "$BUILD/ext.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.networking.networkextension</key>
	<array>
		<string>app-proxy-provider-systemextension</string>
	</array>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
EOF

echo "== 编译 sysex =="
swiftc "$ROOT/Sysex/main.swift" "$ROOT/Sysex/UDPFlow.swift" "$ROOT/Sysex/Provider.swift" \
  -o "$BUILD/netproxy-extension" \
  -framework NetworkExtension -framework Network -framework CoreFoundation -lbsm

echo "== 编译 host =="
swiftc -parse-as-library "$ROOT/Host/HostApp.swift" -o "$BUILD/netproxy-host" \
  -framework NetworkExtension -framework SystemExtensions -framework CoreFoundation

echo "== 组装 bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Library/SystemExtensions/netproxy.extension.systemextension/Contents/MacOS"
cp "$BUILD/netproxy-host" "$APP/Contents/MacOS/NetProxy"
cp "$BUILD/netproxy-extension" \
   "$APP/Contents/Library/SystemExtensions/netproxy.extension.systemextension/Contents/MacOS/netproxy-extension"
cp "$ROOT/Sysex/Info.plist" \
   "$APP/Contents/Library/SystemExtensions/netproxy.extension.systemextension/Contents/Info.plist"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>NetProxy</string>
	<key>CFBundleIdentifier</key><string>local.netproxy</string>
	<key>CFBundleName</key><string>NetProxy</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleSupportedPlatforms</key>
	<array><string>MacOSX</string></array>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
EOF

echo "== 签名证书 =="
if ! security find-identity -v -p codesigning | grep -q "$CERT"; then
  echo "生成自签代码签名证书 $CERT ..."
  TMPDIR_CERT=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR_CERT/key.pem" \
    -out "$TMPDIR_CERT/cert.pem" -days 3650 -nodes \
    -subj "/CN=$CERT" -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning"
  openssl pkcs12 -export -legacy -out "$TMPDIR_CERT/ident.p12" \
    -inkey "$TMPDIR_CERT/key.pem" -in "$TMPDIR_CERT/cert.pem" \
    -passout pass:netproxy -name "$CERT"
  security import "$TMPDIR_CERT/ident.p12" -k ~/Library/Keychains/login.keychain-db \
    -P netproxy -T /usr/bin/codesign
  rm -rf "$TMPDIR_CERT"
  echo "证书已导入。如 codesign 报错用户交互,请在钥匙串访问中确认证书信任设置。"
fi

echo "== codesign =="
codesign --force --sign "$CERT" \
  --entitlements "$ROOT/build/ext.entitlements" \
  "$APP/Contents/Library/SystemExtensions/netproxy.extension.systemextension"
codesign --force --sign "$CERT" \
  --entitlements "$ROOT/build/host.entitlements" \
  -- requirements -anchor Apple generic 2>/dev/null || \
codesign --force --sign "$CERT" \
  --entitlements "$ROOT/build/host.entitlements" \
  "$APP"

echo "构建完成: $APP"
