#!/usr/bin/env bash
# Kline 内嵌 Python 引擎缓存准备脚本
# 作用：下载一次 beeware/Python-Apple-support 原始包（含真机/模拟器双 slice），
#       本地合并出真机/模拟器两份引擎树（EngineCache/device 与 EngineCache/sim），
#       供 Xcode 构建期 Run Script 从 EngineCache/ 拷入 Kline.app（模拟器与真机都内嵌引擎）。
# 合并逻辑镜像 .github/workflows/engine.yml 的 "Extract device slice + shared stdlib"
# 与 "Build Engine.app" 两步：beeware 布局是双区的（平台 slice + 跨 slice 共享 stdlib），
# 合并成 CPython prefix 语义（stdlib 恒在 <home>/lib/python3.14）。
# 注意：CI（engine.yml）不使用本脚本——Windows 路径 IPA 结构性不含引擎。
#
# 用法：bash scripts/prepare_engine_cache.sh [--force]
#   无参数：幂等——变体目录已存在（以 manifest.json 为准）则跳过；原始包已缓存则跳过下载
#   --force：重下载原始包 + 重建两变体
set -euo pipefail

# 引擎版本：与 Kline/Debug/PythonEngineHost.swift 的 tipaFileName 及
# .github/workflows/engine.yml 的 workflow_dispatch 默认值保持一致，升级引擎三处同步改
BEEWARE_TAG="3.14-b11"
PYTHON_VERSION="3.14.7"

# xcframework 内 slice 目录名（须与原始包实际布局一致，beeware 改名需同步）
DEVICE_SLICE="ios-arm64"
SIM_SLICE="ios-arm64_x86_64-simulator"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_ROOT="$REPO_ROOT/EngineCache"
RAW_DIR="$CACHE_ROOT/beeware"   # 原始包下载缓存（约 35MB，避免重复下载）

BNUM="${BEEWARE_TAG#*-}"        # 3.14-b11 -> b11
PY_MM="${PYTHON_VERSION%.*}"    # 3.14.7  -> 3.14
# 文件名规则与 engine.yml 一致：Python-<major.minor>-iOS-support.<bN>.tar.gz
RAW_URL="https://github.com/beeware/Python-Apple-support/releases/download/${BEEWARE_TAG}/Python-${PY_MM}-iOS-support.${BNUM}.tar.gz"
RAW_TGZ="$RAW_DIR/Python-${PY_MM}-iOS-support.${BNUM}.tar.gz"

# ---- 参数解析 ---------------------------------------------------------------

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "未知参数: $arg"; echo "用法: bash scripts/prepare_engine_cache.sh [--force]"; exit 2 ;;
  esac
done

# ---- 下载原始包（已缓存且未 --force 时跳过） ---------------------------------

if [ "$FORCE" = "1" ] || [ ! -f "$RAW_TGZ" ]; then
  if [ "$FORCE" = "1" ]; then
    echo "==> --force：重下载 beeware 原始包"
  else
    echo "==> 下载 beeware 原始包"
  fi
  mkdir -p "$RAW_DIR"
  # --http1.1：本机代理对 HTTP/2 framing 偶发 curl(16)，GitHub releases 双协议均支持，固定 1.1 更稳
  curl --http1.1 -L --fail --retry 3 -o "$RAW_TGZ" "$RAW_URL"
  tar -tzf "$RAW_TGZ" > /dev/null   # 完整性冒烟
else
  echo "==> 原始包已缓存，跳过下载：$RAW_TGZ"
fi

# ---- 变体构建 ----------------------------------------------------------------

# 临时工作区（脚本退出时统一清理，不污染仓库）
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kline-engine-cache.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# 构建单变体引擎树：$1 = xcframework 内 slice 目录名，$2 = 输出目录
# 只拷需要的部分（slice 目录 + 临时共享 lib），避免整包 xcframework 拷贝导致双 slice 体积翻倍
build_variant() {
  local SLICE_NAME="$1"
  local OUT_DIR="$2"

  echo "==> 构建引擎树：${OUT_DIR}（slice: ${SLICE_NAME}）"
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR/Frameworks/Python.xcframework"

  # 1. 解包原始包（每次重建前清掉旧解包，保证幂等）
  rm -rf "$WORK_DIR/extract"
  mkdir -p "$WORK_DIR/extract"
  tar -xzf "$RAW_TGZ" -C "$WORK_DIR/extract"
  local XF="$WORK_DIR/extract/Python.xcframework"
  if [ ! -d "$XF/$SLICE_NAME" ]; then
    echo "❌ 原始包内未找到 slice 目录 ${SLICE_NAME}，实际内容：" >&2
    ls -la "$XF" >&2
    exit 1
  fi

  # 2. 平台 slice 拷入产物；跨 slice 共享 stdlib 先放临时目录（合并完即删）
  local SLICE_DIR="$OUT_DIR/Frameworks/Python.xcframework/$SLICE_NAME"
  cp -R "$XF/$SLICE_NAME" "$SLICE_DIR"
  cp -R "$XF/lib" "$WORK_DIR/shared_lib"

  # 3. 清理 slice 内残留 _CodeSignature 目录（镜像 engine.yml；模拟器无签名、真机由 Xcode 构建期重签）
  find "$OUT_DIR" -type d -name _CodeSignature -exec rm -rf {} +

  # 4. 平台专属目录防御式定位（实际核验：真机 slice 只有 lib-arm64；
  #    模拟器 slice 是 arm64+x86_64 双架构区——lib-arm64 与 lib-x86_64 并存，
  #    两者 lib-dynload 的 .so 同名但各为单架构、无法双区共存。Apple Silicon 上
  #    模拟器执行 arm64 代码，固定选 lib-arm64；Intel Mac 模拟器不在支持范围）
  local LIB_MATCHES PLATFORM_LIB
  LIB_MATCHES="$(find "$SLICE_DIR" -maxdepth 1 -type d -name 'lib-*')"
  if [ -z "$LIB_MATCHES" ]; then
    echo "❌ slice 内未找到平台专属 lib-* 目录，slice 实际内容：" >&2
    ls -la "$SLICE_DIR" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$LIB_MATCHES" | wc -l | tr -d ' ')" -gt 1 ]; then
    PLATFORM_LIB="$SLICE_DIR/lib-arm64"
    if [ ! -d "$PLATFORM_LIB" ]; then
      echo "❌ slice 内有多个 lib-* 目录且无 lib-arm64，无法确定平台专属目录：" >&2
      printf '    %s\n' "$LIB_MATCHES" >&2
      exit 1
    fi
  else
    PLATFORM_LIB="$LIB_MATCHES"
  fi

  # 5. 合并双区为 CPython prefix 语义（PYTHONHOME=$SLICE_DIR，stdlib 恒在 <home>/lib/python3.14）：
  #    lib/python3.14 ← 共享纯 Python stdlib（xcframework/lib/python3.14）
  #                   + 平台专属（lib-dynload/_sysconfigdata 等，来自 slice 内 lib-*/python3.14）
  mkdir -p "$SLICE_DIR/lib"
  cp -R "$WORK_DIR/shared_lib/python3.14" "$SLICE_DIR/lib/python3.14"
  mv "$PLATFORM_LIB/python3.14/lib-dynload" "$SLICE_DIR/lib/python3.14/lib-dynload"
  cp -R "$PLATFORM_LIB/python3.14/." "$SLICE_DIR/lib/python3.14/"
  rm -rf "$PLATFORM_LIB" "$WORK_DIR/shared_lib"
  # 清掉未被选用的残余平台目录（如模拟器 fat slice 的 lib-x86_64），瘦身产物
  find "$SLICE_DIR" -maxdepth 1 -type d -name 'lib-*' -exec rm -rf {} +

  # 6. stdlib landmark 冒烟（缺失即坏树：删除输出目录并失败，绝不产出残缺引擎）
  for f in "lib/python3.14/encodings/__init__.py" "lib/python3.14/os.py" "lib/python3.14/lib-dynload"; do
    if [ ! -e "$SLICE_DIR/$f" ]; then
      echo "❌ stdlib landmark 缺失: $f" >&2
      rm -rf "$OUT_DIR"
      exit 1
    fi
  done

  # 7. manifest.json（schema v1；layout 相对 KlineEngine/ 根、无前缀，resolve() 直拼命中）
  cat > "$OUT_DIR/manifest.json" <<EOF
{
  "schema": 1,
  "engineId": "cpython",
  "engineVersion": "${PYTHON_VERSION}",
  "build": "beeware-${BEEWARE_TAG}",
  "apiVersion": 1,
  "layout": {
    "dylib": "Frameworks/Python.xcframework/${SLICE_NAME}/Python.framework/Python",
    "home": "Frameworks/Python.xcframework/${SLICE_NAME}"
  }
}
EOF
  python3 -c "import json; json.load(open('$OUT_DIR/manifest.json'))"   # JSON 合法性冒烟
  echo "    ✅ 构建完成：$OUT_DIR"
}

# 幂等：变体目录已存在（manifest.json 存在）且未 --force 时跳过
build_variant_if_needed() {
  local VARIANT="$1" SLICE_NAME="$2"
  if [ "$FORCE" != "1" ] && [ -f "$CACHE_ROOT/$VARIANT/manifest.json" ]; then
    echo "==> $VARIANT 引擎树已存在，跳过（--force 可重建）"
  else
    build_variant "$SLICE_NAME" "$CACHE_ROOT/$VARIANT"
  fi
}

build_variant_if_needed device "$DEVICE_SLICE"
build_variant_if_needed sim "$SIM_SLICE"

# ---- 完成 --------------------------------------------------------------------

echo "==> 引擎缓存就绪："
echo "    device: $CACHE_ROOT/device"
echo "    sim:    $CACHE_ROOT/sim"
du -sh "$CACHE_ROOT/device" "$CACHE_ROOT/sim"
