#!/usr/bin/env python3
# 把 numpy PR #28759（iOS 支持，2026-07-17 merge 进 main db6d7c2）的关键改动移植到
# numpy 2.5.3 sdist，使 meson 在 iOS cross 环境可完成配置与编译：
#   1. numpy/_core/meson.build：long double 探测 UNKNOWN 分支插 ios 直赋值
#      （cross 环境禁止 run() 测试程序——2026-10-06 实证 9 次构建失败根因）；
#      arm64 iOS long double == double（IEEE_DOUBLE_LE），x86_64 模拟器 = 80-bit x87
#      （INTEL_EXTENDED_16_BYTES_LE）
#   2. numpy/meson.build：blas/lapack order 的 darwin 判定扩到 ios
#   3. numpy/_core/src/common/npy_cblas.h：iOS SDK ILP64 下限检查（对齐 main）
#   4. pyproject.toml：[tool.cibuildwheel.ios] 段（allow-noblas + before-build 清空 +
#      xbuild-tools=ninja）
# 全部锚点已对照 numpy main HEAD db6d7c2 逐一核对，幂等可重跑。
#
# 用法: python3 scripts/patch_numpy_ios.py <numpy-sdist-解包目录>
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")

# 1. numpy/_core/meson.build：UNKNOWN 分支插 ios longdouble 格式（arm64=double, x86_64 sim=80-bit x87）
p = root / "numpy/_core/meson.build"
s = p.read_text()
if "host_machine.system() == 'ios'" in s:
    print("1. _core/meson.build longdouble ios 分支已应用，跳过")
else:
    head_old = """if longdouble_format == 'UNKNOWN'
  longdouble_format = meson.get_compiler('c').run("""
    head_new = """if longdouble_format == 'UNKNOWN'
  if host_machine.system() == 'ios'
    if host_machine.cpu_family() == 'x86_64'
      # x86_64 iOS simulator runs on x86_64 macOS hosts; long double is 80-bit x87 (16 bytes)
      longdouble_format = 'INTEL_EXTENDED_16_BYTES_LE'
    else
      # On arm64 iOS, long double is identical to double
      longdouble_format = 'IEEE_DOUBLE_LE'
    endif
  else
    longdouble_format = meson.get_compiler('c').run("""
    assert s.count(head_old) == 1, "meson.build longdouble 头部锚点未唯一命中"
    s = s.replace(head_old, head_new, 1)
    # run() 探测块结尾：`  ''').stdout()` 后原 `endif` 关闭外层 if；现在 run 赋值包进 else，
    # 需在其后补 `  endif` 关闭内层 if/else（锚点已验证全文唯一）
    tail_old = "  ''').stdout()\nendif\n"
    tail_new = "  ''').stdout()\n  endif\nendif\n"
    assert s.count(tail_old) == 1, "meson.build run() 块尾部锚点未唯一命中"
    s = s.replace(tail_old, tail_new, 1)
    p.write_text(s)
    print("1. _core/meson.build longdouble ios 分支 OK")

# 2. numpy/meson.build：blas/lapack order 的 darwin 扩到 ios（main 74/85 行同款）
p = root / "numpy/meson.build"
s = p.read_text()
if "in ['darwin', 'ios']" in s:
    print("2. meson.build blas/lapack ios 已应用，跳过")
else:
    n = s.count("host_machine.system() == 'darwin'")
    assert n == 2, f"darwin 计数异常: {n}"
    s = s.replace("host_machine.system() == 'darwin'", "host_machine.system() in ['darwin', 'ios']")
    p.write_text(s)
    print("2. meson.build blas/lapack ios OK")

# 3. npy_cblas.h：iOS SDK ILP64 检查（noblas 下不触发，补齐与 main 对齐）
p = root / "numpy/_core/src/common/npy_cblas.h"
s = p.read_text()
if "TARGET_OS_IOS" in s:
    print("3. npy_cblas.h iOS SDK 检查已应用，跳过")
else:
    a_old = """#ifdef ACCELERATE_NEW_LAPACK
    #if __MAC_OS_X_VERSION_MAX_ALLOWED < 130300"""
    a_new = """#ifdef ACCELERATE_NEW_LAPACK
    #include "TargetConditionals.h"
    #if TARGET_OS_OSX && __MAC_OS_X_VERSION_MAX_ALLOWED < 130300"""
    assert s.count(a_old) == 1, "npy_cblas.h 头部锚点未唯一命中"
    s = s.replace(a_old, a_new, 1)
    b_old = """            #error "Accelerate ILP64 support is only available with macOS 13.3 SDK or later"
        #endif
    #else"""
    b_new = """            #error "Accelerate ILP64 support is only available with macOS 13.3 SDK or later"
        #endif
    #elif TARGET_OS_IOS && __IPHONE_OS_VERSION_MAX_ALLOWED < 160400
        #ifdef HAVE_BLAS_ILP64
            #error "Accelerate ILP64 support is only available with iOS 16.4 SDK or later"
        #endif
    #else"""
    assert s.count(b_old) == 1, "npy_cblas.h elif 锚点未唯一命中"
    s = s.replace(b_old, b_new, 1)
    p.write_text(s)
    print("3. npy_cblas.h iOS SDK 检查 OK")

# 4. pyproject.toml：[tool.cibuildwheel.ios] 段（xbuild-tools=ninja + before-build 清空 + noblas）
p = root / "pyproject.toml"
s = p.read_text()
if "[tool.cibuildwheel.ios]" in s:
    print("4. pyproject [tool.cibuildwheel.ios] 已应用，跳过")
else:
    old = "\n[tool.cibuildwheel.linux]\n"
    new = """
[tool.cibuildwheel.ios]
config-settings = "setup-args=-Dallow-noblas=true build-dir=build"
before-build = []
xbuild-tools = ["ninja"]

[tool.cibuildwheel.linux]
"""
    assert s.count(old) == 1, "pyproject linux 锚点未唯一命中"
    p.write_text(s.replace(old, new, 1))
    print("4. pyproject [tool.cibuildwheel.ios] OK")

print("=== 全部补丁就绪 ===")
