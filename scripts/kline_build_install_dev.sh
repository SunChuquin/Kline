#!/usr/bin/env bash
# 流水线 A：纯 CLI 构建 + 直装到 iPhone（全自动，无需人工，不经过 AltStore）
#
# 用法：
#   bash scripts/kline_build_install_dev.sh                 # 自动挑第一台已连接真机
#   UDID=00008030-001158362EA0402E bash scripts/kline_build_install_dev.sh
#   bash scripts/kline_build_install_dev.sh --variant dbg   # 独立身份 Kline-dbg，与 AltStore 托管的那份共存
#   CONFIG=Release SCHEME=Kline bash scripts/kline_build_install_dev.sh
#
# 环境变量：
#   UDID          目标设备 UDID（缺省自动探测第一台已连接真机）
#   SCHEME        scheme 名（默认 Kline）
#   CONFIG        Debug / Release（默认 Debug）
#   DERIVED_DATA  构建目录（默认 build/cli，已在 .gitignore 的 build/ 下）
#   LAUNCH        1=装完立刻启动（默认 1），0=只装
#   BUNDLE_ID / DISPLAY_NAME  手动覆盖（--variant dbg 等价于
#                 BUNDLE_ID=com.sunck.Kline.dbg DISPLAY_NAME=Kline-dbg）
#
# ⚠️ 副作用：这样装出来的是「开发签名」App——不归 AltStore 管，不会出现在 My Apps，
#    也不会被 Refresh All 续签。免费账号 7 天后失效，重跑本脚本即可（数据保留）。
#
# 退出码：0 成功；2 参数/环境错误；3 构建失败；4 安装失败；5 启动失败
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-Kline}"
CONFIG="${CONFIG:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-}"
UDID="${UDID:-}"
LAUNCH="${LAUNCH:-1}"
BUNDLE_ID="${BUNDLE_ID:-}"
DISPLAY_NAME="${DISPLAY_NAME:-}"
VARIANT="${VARIANT:-}"
WITH_IPA=0

# 解析参数：--variant=dbg / --variant dbg / --with-ipa
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    --variant=*) VARIANT="${args[$i]#*=}" ;;
    --variant)   VARIANT="${args[$((i+1))]:-}" ;;
    --with-ipa)  WITH_IPA=1 ;;
  esac
done

# 变体：dbg = 独立身份，和 AltStore 托管的那份共存（桌面显示 Kline-dbg）
if [ -n "$VARIANT" ]; then
  case "$VARIANT" in
    dbg) : "${BUNDLE_ID:=com.sunck.Kline.dbg}"; : "${DISPLAY_NAME:=Kline-dbg}" ;;
    *)   printf '\n[错误] 未知变体：%s（目前只支持 dbg）\n' "$VARIANT" >&2; exit 2 ;;
  esac
fi
DERIVED_DATA="${DERIVED_DATA:-build/cli${VARIANT:+-$VARIANT}}"

die() { printf '\n[错误] %s\n' "$2" >&2; exit "$1"; }

command -v xcodebuild >/dev/null || die 2 "找不到 xcodebuild，请先安装 Xcode 并执行 sudo xcode-select -s /Applications/Xcode.app"
command -v xcrun >/dev/null || die 2 "找不到 xcrun"

# ---- 1. 选设备 -------------------------------------------------------------
if [ -z "$UDID" ]; then
  # 只取「physical + connected」那一行里的 UUID（排除模拟器；UI 显示的 UDID 与 coredevice ID 都可用）
  UDID=$(xcrun devicectl list devices 2>/dev/null \
        | awk '/ connected / && / physical /{
            for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$/) {print $i; exit}}')
fi
[ -n "$UDID" ] || die 2 "没有检测到已连接的真机。请插 USB、解锁手机，或显式传 UDID=<设备ID>"

if ! xcrun devicectl list devices 2>/dev/null | grep -q "$UDID"; then
  die 2 "设备 $UDID 不在 devicectl 列表里：检查 USB 连接、是否点了「信任此电脑」"
fi

LOCKED=$(xcrun devicectl device info lockState --device "$UDID" 2>/dev/null | awk -F': ' '/passcodeRequired/{print $2}' | head -1)
echo "==> 设备 ${UDID}（锁屏密码要求: ${LOCKED:-unknown}）"
[ "${LOCKED:-}" = "true" ] && die 4 "设备处于锁定状态，安装需要先解锁手机再重跑"

# ---- 2. 构建 ---------------------------------------------------------------
BUILD_FLAGS=(-quiet)
BUILD_SETTINGS=()
if [ -n "$BUNDLE_ID" ]; then
  # 新 Bundle ID 需要新建 App ID / 描述文件，必须允许 xcodebuild 联网更新描述文件
  BUILD_FLAGS+=(-allowProvisioningUpdates)
  BUILD_SETTINGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
  [ -n "$DISPLAY_NAME" ] && BUILD_SETTINGS+=("INFOPLIST_KEY_CFBundleDisplayName=$DISPLAY_NAME")
  echo "==> 变体身份：${BUNDLE_ID}  显示名：${DISPLAY_NAME:-未改}"
fi

echo "==> 构建 $SCHEME ($CONFIG) → $DERIVED_DATA"
BUILD_CMD=(xcodebuild -project Kline.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG"
           -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA")
BUILD_CMD+=("${BUILD_FLAGS[@]}")
[ ${#BUILD_SETTINGS[@]} -gt 0 ] && BUILD_CMD+=("${BUILD_SETTINGS[@]}")
BUILD_CMD+=(build)
if ! "${BUILD_CMD[@]}"; then
  die 3 "构建失败。常见原因：签名 Team 未登录 Xcode（Settings → Accounts）、
        新 Bundle ID 建描述文件需要 -allowProvisioningUpdates（脚本已带）、
        或 #Preview 宏插件被沙箱拦截（请以非沙箱方式运行本脚本）"
fi

APP="$DERIVED_DATA/Build/Products/$CONFIG-iphoneos/$SCHEME.app"
[ -d "$APP" ] || die 3 "构建产物不存在：$APP"

# ---- 3. 安装 ---------------------------------------------------------------
echo "==> 安装到设备"
INSTALL_LOG=$(mktemp /tmp/kline_install_XXXX.log)
xcrun devicectl device install app --device "$UDID" "$APP" >"$INSTALL_LOG" 2>&1 || true
if ! grep -q "App installed" "$INSTALL_LOG"; then
  echo "---- devicectl 输出 ----" >&2
  cat "$INSTALL_LOG" >&2
  rm -f "$INSTALL_LOG"
  die 4 "安装失败。常见原因：App 数超过免费账号 3 个上限、描述文件过期、
        或设备未解锁（安装阶段同样需要解锁）"
fi
rm -f "$INSTALL_LOG"

# ---- 4. 启动（可选）--------------------------------------------------------
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist" 2>/dev/null || echo "com.sunck.Kline")
if [ "$LAUNCH" = "1" ]; then
  echo "==> 启动 $BUNDLE_ID"
  xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null \
    || die 5 "安装成功但启动失败（该 App 可能未受信任：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任）"
fi

echo
echo "✅ 完成：$BUNDLE_ID 已装到 $UDID"
echo "   提醒：此包为开发签名，不归 AltStore 管理、不会被自动续签；"
echo "   免费账号 7 天后失效，重跑本脚本即可（App 数据保留）。"

# ---- 5. 可选：同时把给 AltStore 用的 ipa 发布到固定位置 ---------------------
#   bash scripts/kline_build_install_dev.sh --with-ipa
#   EXPORT_IPA=1 bash scripts/kline_build_install_dev.sh
if [ "${EXPORT_IPA:-0}" = "1" ] || [ "$WITH_IPA" = "1" ]; then
  if [ -n "$BUNDLE_ID" ]; then
    echo
    echo "⚠️  变体模式下不发布 ipa：给 AltStore 的包必须是原 Bundle ID（com.sunck.Kline）"
  else
    echo
    echo "==> 导出并发布 AltStore 用 ipa"
    bash scripts/kline_serve_ipa.sh publish
  fi
fi
