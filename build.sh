#!/bin/bash
# 一键构建 clarity-proxy（generate + embed 补丁 + xcodebuild）
#
# 用法：
#   DEVELOPMENT_TEAM=你的TeamID ./build.sh
# （或已在 project.yml 写死 Team ID 则直接 ./build.sh）
#
# 注意 xcodegen 须 2.42.0（2.46+ 输出 objectVersion 77，Xcode 15 读不了——GUIDE 坑 4）。
set -euo pipefail
cd "$(dirname "$0")/XcodeProj"

XG=${XCODEGEN:-/tmp/xcodegen/bin/xcodegen}
if [ ! -x "$XG" ]; then
  echo "下载 xcodegen 2.42.0(2.46+ 输出的工程格式 Xcode 15 读不了)..."
  curl -sL -o /tmp/xcodegen.zip \
    "https://github.com/yonaskolb/XcodeGen/releases/download/2.42.0/xcodegen.zip"
  (cd /tmp && unzip -oq xcodegen.zip)
  XG=/tmp/xcodegen/bin/xcodegen
fi

# Team ID / bundle ID 参数化：DEVELOPMENT_TEAM 环境变量必填（首次），注入 project.yml 占位符。
# bundle ID 形态 local.clarity.<team小写>[.extension]——fork 用户得到自己的独立标识。
# 注：sed 表达式用单引号包住 ${占位符} 字面量（防 shell 展开 unbound 变量），替换值用双引号拼接。
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  TEAM_LC=$(echo "$DEVELOPMENT_TEAM" | tr 'A-Z' 'a-z')
  /usr/bin/sed -i.bak \
    -e 's/${DEVELOPMENT_TEAM}/'"${DEVELOPMENT_TEAM}"'/' \
    -e 's/${DEVELOPMENT_TEAM_LC}/'"${TEAM_LC}"'/g' project.yml && rm -f project.yml.bak
  /usr/bin/sed -i.bak 's/${MODULE_NAME}/local_clarity_'"${TEAM_LC}"'_extension/' netproxy/ext-Info.plist && rm -f netproxy/ext-Info.plist.bak
  echo "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM} (bundle: local.clarity.${TEAM_LC}) written"
fi

"$XG" generate

# xcodegen 2.42 不支持 sysex 嵌入路径,手工补丁(每次 generate 后都要)
python3 - <<'PYEOF'
p='netproxy.xcodeproj/project.pbxproj'
s=open(p).read()
s=s.replace('''			dstPath = "";
			dstSubfolderSpec = 13;''','''			dstPath = "$(SYSTEM_EXTENSIONS_FOLDER_PATH)";
			dstSubfolderSpec = 16;''')
open(p,'w').write(s)
print('embed patched')
PYEOF

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcodebuild -project netproxy.xcodeproj -scheme NetProxy \
  -configuration Debug -derivedDataPath build build -allowProvisioningUpdates \
  2>&1 | grep -E "error|BUILD" | head -5

echo "产物: $(pwd)/build/Build/Products/Debug/NetProxy.app"
echo "部署: cp -R $(pwd)/build/Build/Products/Debug/NetProxy.app /Applications/ && xattr -rc /Applications/NetProxy.app"
