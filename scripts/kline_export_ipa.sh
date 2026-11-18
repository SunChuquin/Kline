#!/usr/bin/env bash
# 流水线 B：构建 → 导出 .ipa（给 AltStore 用，人工装一次后由 AltStore 自动续签）
#
# 用法：
#   bash scripts/kline_export_ipa.sh                 # Release + development 导出
#   CONFIG=Debug OUTPUT_DIR=~/Downloads bash scripts/kline_export_ipa.sh
#
# 环境变量：
#   SCHEME         scheme 名（默认 Kline）
#   CONFIG         Release / Debug（默认 Release）
#   TEAM_ID        签名 Team（默认取工程里的 DEVELOPMENT_TEAM）
#   OUTPUT_DIR     输出目录（默认 build/ipa，已在 .gitignore 的 build/ 下）
#   EXPORT_METHOD  development / ad-hoc / app-store（默认 development）
#
# 产出：$OUTPUT_DIR/Kline-<版本>-<build>.ipa
#
# ⚠️ 这条流水线能自动化到「产出 ipa」为止；最后一步必须人工在 iPhone 上
#    打开 AltStore → My Apps → + → 选 ipa。原因：AltStore 没有 CLI、
#    AltServer 没有 URL scheme、AltStore 也不「收养」外部安装的 App。
#    装完这一次之后，Refresh All / 定时自动化才会把它纳入续签范围。
#
# 退出码：0 成功；2 参数错误；3 archive 失败；4 导出失败
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-Kline}"
CONFIG="${CONFIG:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-build/ipa}"
EXPORT_METHOD="${EXPORT_METHOD:-debugging}"
TEAM_ID="${TEAM_ID:-$(grep -m1 'DEVELOPMENT_TEAM' Kline.xcodeproj/project.pbxproj 2>/dev/null | tr -d ' ";' | cut -d= -f2)}"

die() { printf '\n[错误] %s\n' "$2" >&2; exit "$1"; }

command -v xcodebuild >/dev/null || die 2 "找不到 xcodebuild"
[ -n "${TEAM_ID:-}" ] || die 2 "无法从工程读出 DEVELOPMENT_TEAM，请显式传 TEAM_ID=XXXXXXXXXX"

ARCHIVE="build/archive/Kline.xcarchive"
rm -rf "$ARCHIVE"
mkdir -p "$(dirname "$ARCHIVE")" "$OUTPUT_DIR"

# ---- 1. archive ------------------------------------------------------------
echo "==> archive $SCHEME ($CONFIG)，Team=$TEAM_ID"
if ! xcodebuild -project Kline.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
     -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -quiet archive; then
  die 3 "archive 失败。常见原因：签名 Team 未登录 Xcode（Settings → Accounts）、
        设备列表为空、或 #Preview 宏插件被沙箱拦截（请以非沙箱方式运行本脚本）"
fi
[ -d "$ARCHIVE" ] || die 3 "archive 产物不存在：$ARCHIVE"

# ---- 2. 导出 ipa -----------------------------------------------------------
PLIST=$(mktemp /tmp/kline_export_XXXX.plist)
trap 'rm -f "$PLIST"' EXIT
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${EXPORT_METHOD}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF

EXPORT_TMP=$(mktemp -d /tmp/kline_export_out_XXXX)
echo "==> 导出 ipa (method=${EXPORT_METHOD})"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_TMP" \
     -exportOptionsPlist "$PLIST" -quiet; then
  rm -rf "$EXPORT_TMP"
  die 4 "导出失败。若提示找不到 provisioning profile：先在 Xcode 里对该 target
        勾选 Automatically manage signing 并用同一台设备跑一次（Xcode 会自动生成描述文件）"
fi

IPA=$(find "$EXPORT_TMP" -maxdepth 1 -name "*.ipa" | head -1)
[ -n "$IPA" ] || { rm -rf "$EXPORT_TMP"; die 4 "导出目录里没有 .ipa：$EXPORT_TMP"; }

# ---- 3. 归档到固定位置（版本号从 archive 里读，export 目录只剩 ipa）----------
APPB="$ARCHIVE/Products/Applications/$SCHEME.app"
VER=""
BLD=""
if [ -d "$APPB" ]; then
  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APPB/Info.plist" 2>/dev/null || echo "")
  BLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APPB/Info.plist" 2>/dev/null || echo "")
fi
NAME="${SCHEME}${VER:+-$VER}${BLD:+-$BLD}.ipa"
cp "$IPA" "$OUTPUT_DIR/$NAME"
rm -rf "$EXPORT_TMP"

echo
echo "✅ 已导出：$OUTPUT_DIR/$NAME"
echo "   下一步（人工，只需一次）："
echo "   1) 把 ipa 隔空投送到 iPhone，存到「文件」App"
echo "   2) iPhone → AltStore → My Apps → + → 选该 ipa"
echo "   3) 装完在 My Apps 里看到它并显示天数 → 之后 Refresh All 会自动带上它"
