#!/usr/bin/env bash
# 把 numpy iOS wheel 安装进引擎树的 site-packages
# 本地（prepare_engine_cache.sh 之后补装）与 CI（engine.yml Engine.app 组装期）共用同一逻辑。
#
# 用法: bash scripts/install_numpy_into_engine.sh <ENGINE_TREE_ROOT> <WHEEL_PATH>
#   ENGINE_TREE_ROOT: 引擎树根（Engine.app 或 EngineCache/device|sim），
#                     内部结构 Frameworks/Python.xcframework/<slice>/lib/python3.14
#   WHEEL_PATH:       numpy iOS wheel（arm64_iphoneos 真机版 / arm64_iphonesimulator 模拟器版）
#
# 幂等：先删旧 site-packages 再解包（引擎树重建 = 全新，重复调用无害）。
set -euo pipefail

TREE_ROOT="${1:?用法: install_numpy_into_engine.sh <ENGINE_TREE_ROOT> <WHEEL_PATH>}"
WHEEL="${2:?用法: install_numpy_into_engine.sh <ENGINE_TREE_ROOT> <WHEEL_PATH>}"

[ -f "$WHEEL" ] || { echo "❌ wheel 不存在: $WHEEL" >&2; exit 1; }

# 定位引擎树内 lib/python3.14（唯一平台 slice；模拟器 fat slice 已被 prepare 阶段清理）
PYDIR="$(find "$TREE_ROOT/Frameworks/Python.xcframework" -maxdepth 3 -type d -path '*/lib/python3.14' | head -1)"
[ -n "$PYDIR" ] || { echo "❌ 引擎树内未找到 lib/python3.14: $TREE_ROOT" >&2; exit 1; }

echo "==> 安装 numpy wheel → ${PYDIR}/site-packages"
echo "    wheel: $(basename "$WHEEL") ($(du -h "$WHEEL" | cut -f1))"
SITE="$PYDIR/site-packages"
rm -rf "$SITE"
mkdir -p "$SITE"
unzip -q "$WHEEL" -d "$SITE"

# 结构冒烟：numpy 包 + 核心 C 扩展必须存在
[ -f "$SITE/numpy/__init__.py" ] || { echo "❌ numpy/__init__.py 缺失（解包异常）" >&2; exit 1; }
SO_COUNT="$(find "$SITE/numpy" -name '*.so' | wc -l | tr -d ' ')"
[ "$SO_COUNT" -ge 1 ] || { echo "❌ numpy 内无任何 .so C 扩展（wheel 平台不符？）" >&2; exit 1; }

# manifest build 字段追加 numpy 版本标记（App 侧仅展示；schema/apiVersion/layout 不动）。
# 幂等：重复安装先剥旧标记再追加，避免叠加。单一来源——CI（engine.yml）与本地（EngineCache 补装）
# 都经本脚本，标记与实际内容恒一致。
DIST_INFO="$(find "$SITE" -maxdepth 1 -type d -name 'numpy-*.dist-info' | head -1)"
[ -n "$DIST_INFO" ] || { echo "❌ 未找到 numpy-*.dist-info（wheel 元数据异常）" >&2; exit 1; }
NUMPY_VER="$(basename "$DIST_INFO" | sed -e 's/^numpy-//' -e 's/\.dist-info$//')"
MANIFEST="$TREE_ROOT/manifest.json"
if [ -f "$MANIFEST" ]; then
  python3 - "$MANIFEST" "$NUMPY_VER" <<'PY'
import json, sys
path, ver = sys.argv[1], sys.argv[2]
m = json.load(open(path))
b = m.get("build", "")
if "+numpy-" in b:
    b = b.split("+numpy-")[0]
m["build"] = f"{b}+numpy-{ver}"
json.dump(m, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(f"    manifest build -> {m['build']}")
PY
fi

echo "    ✅ numpy 安装完成（.so 扩展 ${SO_COUNT} 个，site-packages $(du -sh "$SITE" | cut -f1)）"
