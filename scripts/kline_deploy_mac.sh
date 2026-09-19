#!/usr/bin/env bash
# Kline macOS 本地交付闭环：构建 → 安装 → 启动 → 提交推送
# 与 Windows 的 build_and_deploy.py 对应：公司走 CI + TrollStore，家里走本机直连真机。
#
# 用法（前台阻塞执行）：
#   bash scripts/kline_deploy_mac.sh "<提交描述>"
#
# 环境变量：
#   KLINE_DEVICE_ID  真机 id（默认 XIAO iPad；可用 xcrun devicectl list devices 查）
#
# 退出码：0 全部成功；非 0 = 构建/安装/启动失败，此时不会提交代码。
set -euo pipefail

DEFAULT_DEVICE_ID="00008020-000D48E11E78003A"   # XIAO iPad✨（USB/ECID 形态的 id）
PROJECT="Kline.xcodeproj"
SCHEME="Kline"
BUNDLE_ID="com.sunck.Kline"

cd "$(dirname "$0")/.."

MSG="${1:-}"
if [ -z "$MSG" ]; then
  echo "用法: bash scripts/kline_deploy_mac.sh \"<提交描述>\""
  exit 2
fi

# 选定目标真机：
#   1) KLINE_DEVICE_ID 显式指定 → 必须已连接，否则报错；
#   2) 默认 XIAO iPad 在线 → 用它；
#   3) 否则自动取第一台已连接的物理 iOS 设备；
#   4) 都没有 → 简短报错（请插线/解锁设备）。
pick_device() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
  | python3 -c '
import re, sys
want = sys.argv[1] or None
ids = []
for line in sys.stdin:
    if "platform:iOS" not in line:
        continue
    m = re.search(r"id:([0-9A-Fa-f-]{8,})", line)
    if not m:
        continue
    i = m.group(1)
    # -showdestinations 里：已连接真机 = ECID 形态（仅 1 个连字符，如 00008020-000D…）；
    # 模拟器 UUID 含 4 个连字符；Any iOS Device 占位符不含 8 位以上连续十六进制。
    if i.count("-") == 4:
        continue
    ids.append(i)
if want:
    if want in ids:
        print(want); sys.exit(0)
    sys.exit(11)
print(ids[0] if ids else "")
' "${KLINE_DEVICE_ID:-}"
}

if [ -n "${KLINE_DEVICE_ID:-}" ]; then
  DEVICE_ID="$KLINE_DEVICE_ID"
  if ! pick_device >/dev/null 2>&1; then
    echo "指定的设备 ${DEVICE_ID} 当前未连接（插线并解锁后重试）"
    exit 10
  fi
else
  CONNECTED=$(pick_device 2>/dev/null || true)
  if [ -z "$CONNECTED" ]; then
    echo "没有已连接的物理 iOS 设备（插线、解锁并信任后重试，或用 KLINE_DEVICE_ID=<id> 指定）"
    exit 10
  fi
  DEVICE_ID="$CONNECTED"
fi

echo "==> [1/4] xcodebuild 构建真机包（设备 ${DEVICE_ID}）"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$DEVICE_ID" -allowProvisioningUpdates build

echo "==> [2/4] 定位构建产物 Kline.app"
# 必须带 -destination：不带时 BUILT_PRODUCTS_DIR 是通用 Debug 目录而非 Debug-iphoneos
APP_PATH=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$DEVICE_ID" -showBuildSettings -json 2>/dev/null \
  | python3 -c '
import json, os, sys
for target in json.load(sys.stdin):
    s = target.get("buildSettings", {})
    if s.get("PRODUCT_NAME") == "Kline":
        p = os.path.join(s.get("BUILT_PRODUCTS_DIR", ""), s.get("FULL_PRODUCT_NAME", ""))
        if os.path.isdir(p):
            print(p)
            break
')
if [ -z "${APP_PATH:-}" ]; then
  echo "未找到 Kline.app（检查构建配置与 DerivedData）"
  exit 3
fi
echo "    $APP_PATH"

echo "==> [3/4] 安装并启动到真机"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"

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

echo "==> 完成：构建已安装并在真机启动"
