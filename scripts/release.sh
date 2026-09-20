#!/bin/bash
# release.sh — 一键发版：bump → 构建 → 公证 → release → tap 更新
#
# 用法：
#   ./scripts/release.sh <版本号>          # 例：./scripts/release.sh 3.3
#   ./scripts/release.sh 3.3 --notes "..." # 自定义 release notes 头部
#
# 前置（一次性）：
#   - notarytool 凭证已存钥匙串（clarity-notary profile，见 notarize.sh 头注释）
#   - gh 已登录（gh auth status）
#   - 本地 ~/Desktop/homebrew-tap 或 $TAP_DIR 指向 tap 仓库 clone
#
# 流程：
#   1. bump ext-Info.plist 版本（CFBundleShortVersionString + CFBundleVersion 同步递增）
#   2. xcodegen 工程沿用现有 pbxproj（不重新 generate——避免占位符/Team ID 丢失）
#   3. notarize.sh：嵌套签名（dylib→sysex→host，devid profile）→ ditto → submit → staple
#   4. ditto 打 staple 后 zip → gh release create（tag v<版本>）
#   5. 更新 tap 仓库 Casks/netproxy.rb（version/url/sha256）→ commit + push
#   6. 打印用户侧安装命令
set -euo pipefail
cd "$(dirname "$0")/.."

VER="${1:?usage: release.sh <version> [build] [--notes text]}"
BUILD="${2:-}"
# build 号缺省 = 25 起递增？不可靠——用日期时分（如 25091620）保证单调递增
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  BUILD=$(date +%y%m%d%H%M)
fi
echo "════════════════════════════════════════════"
echo "  clarity-proxy release v$VER (build $BUILD)"
echo "════════════════════════════════════════════"

echo "── [1/6] bump 版本 → $VER/$BUILD"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" XcodeProj/netproxy/ext-Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" XcodeProj/netproxy/ext-Info.plist

echo "── [2/6] 构建（复用现有 pbxproj——不重新 generate）"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd XcodeProj
xcodebuild -project netproxy.xcodeproj -scheme NetProxy -configuration Debug \
  -derivedDataPath build build -allowProvisioningUpdates 2>&1 | grep -E "error:|BUILD (SUCC|FAIL)" | head -3
cd ..
# Xcode 自动签名可能覆盖 embedded profile 为 Development 版——公证步骤会用 devid 重签覆盖

echo "── [3/6] 公证（签名 → ditto → submit --wait → staple）"
./scripts/notarize.sh

echo "── [4/6] 打 staple 后 zip + 检查既存 release"
APP="XcodeProj/build/Build/Products/Debug/NetProxy.app"
ZIP="NetProxy-v$VER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "  $ZIP ($(du -h "$ZIP" | cut -f1)) sha256=$SHA"

echo "── [5/6] GitHub Release v$VER"
if gh release view "v$VER" >/dev/null 2>&1; then
  echo "  release v$VER 已存在——覆盖上传资产"
  gh release upload "v$VER" "$ZIP" --clobber
else
  BODY="**v$VER (build $BUILD)** — Notarized Developer ID + staple。

安装（Homebrew）：
\`\`\`bash
brew tap 0pen1/tap https://github.com/0pen1/homebrew-tap
brew trust 0pen1/tap && brew install --cask netproxy
/Applications/NetProxy.app/Contents/MacOS/NetProxy activate
\`\`\`

变更见 [CHANGELOG.md](https://github.com/0pen1/clarity-proxy/blob/main/CHANGELOG.md)。"
  gh release create "v$VER" "$ZIP" --title "v$VER" --notes "$BODY"
fi

echo "── [6/6] 更新 homebrew-tap"
TAP_DIR="${TAP_DIR:-$HOME/Desktop/homebrew-tap}"
if [ ! -d "$TAP_DIR/.git" ]; then
  echo "  ✗ tap 仓库未找到（$TAP_DIR）——克隆后设置 TAP_DIR 或放默认位置"
  echo "    git clone https://github.com/0pen1/homebrew-tap ~/Desktop/homebrew-tap"
  exit 1
fi
# 先与远端对齐再改 cask（真机 2026-09-20 事故：本地落后远端时 push 被拒，
# 且本地旧 cask 整文件正则重写会冲掉远端的结构性改进——depends_on/
# url 插值/caveats 全丢，手工 rebase 才救回）。
if ! ( cd "$TAP_DIR" && git fetch origin && git pull --rebase -q origin main ); then
  echo "  ✗ tap 仓库与远端冲突——手动处理 $TAP_DIR 后重跑"
  exit 1
fi
CASK="$TAP_DIR/Casks/netproxy.rb"
# 以当前（已对齐远端的）cask 做最小替换：只动 version/sha256 两行。
# URL 不动——cask 已用 #{version} 插值（v3.3 定案），version 变更自然跟随。
python3 - "$CASK" "$VER" "$SHA" <<'PYEOF'
import re, sys
path, ver, sha = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if 'version "#{version}"' not in s:
    # 旧形态：URL 写死版本号——升级为 #{version} 插值（否则永远发不出新版本）
    s = re.sub(r'url "[^"]+NetProxy-v[^"]+\.zip"',
               'url "https://github.com/0pen1/clarity-proxy/releases/download/v#{version}/NetProxy-v#{version}.zip"',
               s)
s = re.sub(r'version "[^"]+"', f'version "{ver}"', s, count=1)
s = re.sub(r'sha256 "[a-f0-9]+"', f'sha256 "{sha}"', s, count=1)
open(path, 'w').write(s)
print(f"  cask 已更新: version={ver} sha256={sha[:12]}...")
PYEOF
( cd "$TAP_DIR" && git add -A && git commit -q -m "netproxy $VER" && git push -q origin main )

# commit 本仓库的版本号 bump（rebase 对齐远端——与 tap 同款防覆盖）
git pull --rebase -q origin main 2>/dev/null || true
git add XcodeProj/netproxy/ext-Info.plist
git commit -q -m "release: v$VER (build $BUILD)" || true
git push -q 2>/dev/null || git push

echo ""
echo "════════════════ ✅ 发版完成 ════════════════"
echo "  Release: https://github.com/0pen1/clarity-proxy/releases/tag/v$VER"
echo "  用户安装:"
echo "    brew tap 0pen1/tap https://github.com/0pen1/homebrew-tap"
echo "    brew trust 0pen1/tap && brew install --cask netproxy"
echo "  （brew 已装用户升级: brew update && brew upgrade --cask netproxy）"
