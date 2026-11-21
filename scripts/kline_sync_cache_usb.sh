#!/bin/bash
# USB 快速通道：把模拟器的指标缓存整库经 USB 直接拷进真机沙盒
# （绕开 LAN 同步的 WiFi 传输——USB 3 实测 5GB 约 20~60 秒；
#  组合定义经 Documents/SyncCache/presets.json 随库拷入，App 启动时自动导入）
#
# 用法：bash scripts/kline_sync_cache_usb.sh [模拟器udid] [真机udid] [app包路径]
#   模拟器udid 缺省 = 第一台 booted 模拟器
#   真机udid   缺省 = iPad mini 5（XIAO iPad✨）
#   app包路径  缺省 = build/device 的最新真机构建（install 覆盖安装会先终止运行中的
#              App，保证拷贝时缓存库连接已释放；传 "skip" 跳过安装）
set -e
BUNDLE=com.sunck.Kline
SIM_UDID="${1:-$(xcrun simctl list devices booted | grep -m1 'Booted' | grep -oE '[0-9A-F-]{36}')}"
DEV_UDID="${2:-41275072-5F62-5DF9-BB29-8F426A86D4A9}"
APP_PATH="${3:-build/device/Build/Products/Debug-iphoneos/Kline.app}"

if [ "$APP_PATH" != "skip" ]; then
  echo "==> 覆盖安装最新构建（终止运行中的 App，释放缓存库连接）: $APP_PATH"
  xcrun devicectl device install app --device "$DEV_UDID" "$APP_PATH"
fi

echo "==> 源（模拟器）: $SIM_UDID"
SRC_CONTAINER=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE" data)
SRC_DB="$SRC_CONTAINER/Documents/indicator_cache.db"
SRC_PRESETS="$SRC_CONTAINER/Documents/SyncCache/presets.json"
if [ ! -f "$SRC_DB" ]; then
  echo "✗ 源缓存库不存在: $SRC_DB（先在模拟器上生成指标缓存）"
  exit 1
fi
du -sh "$SRC_DB"
if [ ! -f "$SRC_PRESETS" ]; then
  echo "⚠ 源组合定义不存在（可先在模拟器上打开一次联机同步页触发生成）"
fi

echo "==> 目标（真机）: $DEV_UDID"
echo "==> USB 拷贝缓存库（约 20~60 秒/GB）"
xcrun devicectl device copy to --device "$DEV_UDID" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source "$SRC_DB" --destination Documents/indicator_cache.db

if [ -f "$SRC_PRESETS" ]; then
  echo "==> USB 拷贝组合定义（App 启动时自动导入）"
  xcrun devicectl device copy to --device "$DEV_UDID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$SRC_PRESETS" --destination Documents/SyncCache/presets.json
fi

echo "==> 启动真机 App（启动时自动导入组合定义、打开新库）"
xcrun devicectl device process launch --device "$DEV_UDID" "$BUNDLE"
echo "==> 完成：真机切到对应组合打开标的，指标应直接命中缓存（打开即秒出）"
