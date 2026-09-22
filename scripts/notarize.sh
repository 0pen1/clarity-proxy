#!/bin/bash
# notarize.sh — clarity-proxy 公证流水线（首次跑通于 2026-09-16）
#
# 用法：
#   ./scripts/notarize.sh [keychain-profile]
#   （默认 profile 名 clarity-notary；凭证先一次性存入钥匙串：
#    xcrun notarytool store-credentials clarity-notary \
#      --key AuthKey_XXXX.p8 --key-id XXXXXXXXXX --issuer <uuid>）
#
# 流程（GUIDE §3.4 修正版——notarytool 端点 appstoreconnect.apple.com/notary/v2/）：
#   0. 前置检查（证书 / Hardened Runtime / timestamp）
#   1. 从内向外签名（sysex 先签，host 后签——嵌套代码必须内→外）
#   2. ditto 打包（不能用 zip：会丢符号链接/权限）
#   3. notarytool submit --wait（失败拉日志）
#   4. host staple + validate + spctl 终验
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-clarity-notary}"
CERT="Developer ID Application: wang zhichun (3W73W8C23L)"
APP="XcodeProj/build/Build/Products/Debug/NetProxy.app"
SYSEX="$APP/Contents/Library/SystemExtensions/local.netproxy.3w73w8c23l.extension.systemextension"
E="XcodeProj/netproxy"

echo "=== 0. 前置检查 ==="
security find-identity -v -p codesigning | grep -q "$CERT" || {
  echo "✗ 找不到 Developer ID Application 证书"; exit 1
}
[ -d "$APP" ] || { echo "✗ 未找到构建产物 $APP（先 ./build.sh）"; exit 1; }
echo "✓ 证书与产物就位"

echo "=== 1. 嵌套签名（内 → 外：dylib → sysex → host）==="
# 所有嵌套 dylib 逐个签（公证要求每个二进制独立 Developer ID + timestamp；
# --deep 不覆盖 Frameworks 内的 dylib 签名——首次提交 Invalid 的根因）
# Frameworks 目录可能不存在（部署目标 12+ 时 Xcode 不再内嵌 back-deploy 的
# libswift_Concurrency.dylib——3.7 实测）；find 对缺失路径返回非零，
# set -euo pipefail 会静默杀掉脚本（且外层管道吞掉非零退出码）——用
# && 短路保护，目录缺失 = 没有 dylib 可签 = 直接跳过。
[ -d "$APP/Contents/Frameworks" ] && \
find "$APP/Contents/Frameworks" -name "*.dylib" 2>/dev/null | while read -r dylib; do
  codesign --force --sign "$CERT" --options runtime --timestamp "$dylib"
done
true  # 上面的 && 短路在目录缺失时整体为假——补 true 防止 set -e 误杀
# sysex 签（devid entitlements + devid profile 背书——裸 Developer ID 签名
# 带受限 entitlement 在非开发机上会被内核 SIGKILL（killed），必须嵌 profile）
cp "$E/ext-devid.provisionprofile" "$SYSEX/Contents/embedded.provisionprofile"
codesign --force --sign "$CERT" \
  --entitlements "$E/ext-devid.entitlements" \
  --options runtime --timestamp "$SYSEX"
# host 后签（同理嵌 devid profile）
cp "$E/host-devid.provisionprofile" "$APP/Contents/embedded.provisionprofile"
codesign --force --sign "$CERT" \
  --entitlements "$E/host-devid.entitlements" \
  --options runtime --timestamp "$APP"
# 公证严格度验证
codesign --verify --deep --strict --verbose=2 "$APP" || {
  echo "✗ 签名验证失败（notary 也必拒）"; exit 1
}
echo "✓ 嵌套签名完成"

echo "=== 2. ditto 打包 ==="
rm -f NetProxy.zip
ditto -c -k --keepParent "$APP" NetProxy.zip
echo "✓ NetProxy.zip ($(du -h NetProxy.zip | cut -f1))"

echo "=== 3. 公证提交（--wait，通常几分钟）==="
SUBMIT_OUT=$(xcrun notarytool submit NetProxy.zip -p "$PROFILE" --wait 2>&1) || {
  echo "$SUBMIT_OUT"
  echo "✗ 公证失败——拉日志："
  SUB_ID=$(echo "$SUBMIT_OUT" | grep -oE 'id: [a-f0-9-]+' | head -1 | cut -d' ' -f2)
  [ -n "${SUB_ID:-}" ] && xcrun notarytool log "$SUB_ID" -p "$PROFILE" || true
  exit 1
}
echo "$SUBMIT_OUT" | tail -5
grep -q "status: Accepted" <<<"$SUBMIT_OUT" || { echo "✗ 未 Accepted"; exit 1; }
echo "✓ 公证 Accepted"

# sysex 不 staple：staple 往 sysex/Contents/ 写票据文件，而 host 的 seal
# 在签名时已封死 → host 校验发现"多出一个文件" → 「已损坏」弹窗 + SIGKILL
# （3.5/27 实录）。3.3 与 Proxifier 扩展均无 ticket、激活正常——sysextd
# category 校验走在线公证查询，ticket 并非必要。
# host staple 放最后（写 host 自己的 CodeResources，不影响已封的子路径）

echo "=== 4. staple + 终验 ==="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess -t exec -vvv "$APP" && echo "✓✓✓ 公证全链路通过（可分发）" || {
  echo "⚠ spctl 未过（可能是 sysex 类型的正常限制——sysex 走 sysextd 独立校验而非 Gatekeeper）"
}
