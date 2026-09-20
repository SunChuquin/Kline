#!/usr/bin/env bash
# Kline macOS 本地交付闭环：按 Xcode 当前选中的运行目的地构建 → 安装 → 启动 → 提交推送
# 与 Windows 的 build_and_deploy.py 对应：公司走 CI + TrollStore，家里走本机直连设备。
#
# 用法（前台阻塞执行）：
#   bash scripts/kline_deploy_mac.sh "<提交描述>"
#
# 目标选择（自动模拟 Xcode 工具栏当前选中的运行设备）：
#   1. KLINE_DEVICE_ID=<id>  强制指定（模拟器 UDID 或真机 ECID）
#   2. 已 Booted 的模拟器    Xcode 选中模拟器时它一定处于启动状态
#   3. 已连接的真机          取 -showdestinations 中的物理设备
#   4. 都没有                报错退出（请在 Xcode 选好设备，或插线/启动模拟器）
#
# 退出码：0 全部成功；非 0 = 构建/安装/启动失败，此时不会提交代码。
set -euo pipefail

PROJECT="Kline.xcodeproj"
SCHEME="Kline"
BUNDLE_ID="com.sunck.Kline"

cd "$(dirname "$0")/.."

MSG="${1:-}"
if [ -z "$MSG" ]; then
  echo "用法: bash scripts/kline_deploy_mac.sh \"<提交描述>\""
  exit 2
fi

# ---- 1. 选定目标设备 -------------------------------------------------------

# 已启动的模拟器 UDID；多台同时 Booted 时取最近启动的一台（最贴近刚在 Xcode 选中的目标）
booted_simulator() {
  xcrun simctl list devices booted --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
boots = [(x.get("lastBootedAt", ""), x["udid"])
         for devs in d.get("devices", {}).values()
         for x in devs if x.get("state") == "Booted"]
print(max(boots)[1] if boots else "")'
}

# 已连接真机 ECID（00008020-XXXXXXXX 形态；排除占位符与 4 连字符的模拟器 UUID）
connected_device() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
  | python3 -c '
import re, sys
for line in sys.stdin:
    if "platform:iOS" not in line:
        continue
    m = re.search(r"id:([0-9A-Fa-f]{8,16}-[0-9A-Fa-f]{8,})", line)
    if m:
        print(m.group(1)); break'
}

# 指定的 id 是模拟器 UDID（8-4-4-4-12，共 4 个连字符）还是真机 ECID（1 个连字符）
classify_id() {
  case "$1" in
    *-*-*-*-*) echo "sim" ;;
    *-*)       echo "device" ;;
    *)         echo "" ;;
  esac
}

if [ -n "${KLINE_DEVICE_ID:-}" ]; then
  TARGET_KIND="$(classify_id "$KLINE_DEVICE_ID")"
  TARGET_ID="$KLINE_DEVICE_ID"
  if [ "$TARGET_KIND" = "sim" ]; then
    if ! xcrun simctl list devices --json 2>/dev/null | grep -q "\"$TARGET_ID\""; then
      echo "指定的模拟器 ${TARGET_ID} 不存在（用 xcrun simctl list devices 查可用 UDID）"
      exit 10
    fi
  elif [ "$TARGET_KIND" = "device" ]; then
    if [ "$(connected_device)" != "$TARGET_ID" ]; then
      echo "指定的真机 ${TARGET_ID} 当前未连接（插线并解锁后重试）"
      exit 10
    fi
  else
    echo "无法识别 KLINE_DEVICE_ID=${TARGET_ID}（需要模拟器 UDID 或真机 ECID）"
    exit 10
  fi
else
  TARGET_ID="$(booted_simulator)"
  if [ -n "$TARGET_ID" ]; then
    TARGET_KIND="sim"
  else
    TARGET_ID="$(connected_device)"
    if [ -n "$TARGET_ID" ]; then
      TARGET_KIND="device"
    fi
  fi
fi

if [ -z "${TARGET_ID:-}" ]; then
  echo "没有可用的运行目标：请在 Xcode 选中一个模拟器（模拟器会自动启动），或插好真机后重试；"
  echo "也可用 KLINE_DEVICE_ID=<UDID或ECID> 显式指定。"
  exit 10
fi

# ---- 2. 构建前准备 ---------------------------------------------------------

XCODEBUILD_ARGS=(-project "$PROJECT" -scheme "$SCHEME" -destination "id=$TARGET_ID")

if [ "$TARGET_KIND" = "sim" ]; then
  # 模拟器若处于关机状态：先按约定打开带 GUI 的 Simulator（禁止无头后台运行），再启动它
  SIM_STATE="$(xcrun simctl list devices --json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
for devs in json.load(sys.stdin).get("devices", {}).values():
    for x in devs:
        if x.get("udid") == want:
            print(x.get("state", "")); sys.exit(0)
print("")' "$TARGET_ID")"
  if [ "$SIM_STATE" != "Booted" ]; then
    echo "==> 启动模拟器 ${TARGET_ID}（Simulator.app）"
    open -a Simulator
    xcrun simctl boot "$TARGET_ID" 2>/dev/null || true
  fi
  echo "==> 运行目标：模拟器 ${TARGET_ID}"
else
  # 真机需要自动签名
  XCODEBUILD_ARGS+=(-allowProvisioningUpdates)
  echo "==> 运行目标：真机 ${TARGET_ID}"
fi

# ---- 3. 构建 ---------------------------------------------------------------

echo "==> [1/4] xcodebuild 构建"
xcodebuild "${XCODEBUILD_ARGS[@]}" build

# ---- 4. 定位构建产物 Kline.app（同一 destination 的 buildSettings 会给出正确的 Products 目录）

echo "==> [2/4] 定位构建产物 Kline.app"
APP_PATH=$(xcodebuild "${XCODEBUILD_ARGS[@]}" -showBuildSettings -json 2>/dev/null \
  | python3 -c '
import json, os, sys
for target in json.load(sys.stdin):
    s = target.get("buildSettings", {})
    if s.get("PRODUCT_NAME") == "Kline":
        p = os.path.join(s.get("BUILT_PRODUCTS_DIR", ""), s.get("FULL_PRODUCT_NAME", ""))
        if os.path.isdir(p):
            print(p)
            break')
if [ -z "${APP_PATH:-}" ]; then
  echo "未找到 Kline.app（检查构建配置与 DerivedData）"
  exit 3
fi
echo "    ${APP_PATH}"

# ---- 5. 安装并启动 ---------------------------------------------------------

if [ "$TARGET_KIND" = "sim" ]; then
  TARGET_LABEL="模拟器"
else
  TARGET_LABEL="真机"
fi
echo "==> [3/4] 安装并启动到${TARGET_LABEL}"
if [ "$TARGET_KIND" = "sim" ]; then
  xcrun simctl install "$TARGET_ID" "$APP_PATH"
  xcrun simctl launch "$TARGET_ID" "$BUNDLE_ID"
else
  xcrun devicectl device install app --device "$TARGET_ID" "$APP_PATH"
  xcrun devicectl device process launch --device "$TARGET_ID" "$BUNDLE_ID"
fi

# ---- 6. 提交并推送 ---------------------------------------------------------

echo "==> [4/4] 提交并推送"
if git diff --quiet --cached; then
  git add -A
fi
if git diff --cached --quiet; then
  echo "    工作区无改动，跳过提交"
else
  git commit -m "$MSG"
  git push
fi

echo "==> 完成：构建已安装并在目标上启动"
