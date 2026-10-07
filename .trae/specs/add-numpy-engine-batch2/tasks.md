# Tasks

- [x] Task 1: mobile-forge wheel 链路评估
  - [x] 1.1 确认 mobile-forge（beeware）numpy cp314 iOS arm64 wheel 的可用版本与下载 URL（numpy iOS 已 Tier 3，2026-07 定案；beeware mobile wheels leaderboard 为入口）
    - **结论（2026-10-06 证伪）**：mobile-forge 已半退役，不支持 Python 3.14+（引擎为 CPython 3.14.7）；PyPI 从未发布 numpy iOS wheel（Tier 3 仅构建支持不承诺发布）。唯一路径 = **cibuildwheel 4.3.0 自建**（numpy 2.5.3 sdist + PR#28759 补丁移植，scripts/patch_numpy_ios.py）
  - [x] 1.2 记录 wheel 体积（解压后增量预估）与 License（BSD-3），确定 sha256 校验值来源
    - **实测**：iphoneos wheel 5.4MB / iphonesimulator wheel 5.5MB；site-packages 解压后 22M（19 个 .so）；sdist sha256 `df2d5874…` 固定校验，wheel sha256 由 build-numpy-wheel.yml 发 sidecar、engine.yml shasum -c 校验
  - [x] 1.3 评估落点：解包到 `lib/python3.14/site-packages/` 后 `sys.path` 是否天然可见（beeware 布局 + PYTHONHOME 语义），必要时确定 .pth/环境变量兜底方案
    - **结论**：CPython site 语义天然可见（site.py 对存在的 site-packages 自动追加 sys.path），无需 .pth；本机实证 wheel 构建通过（12 轮踩坑：long double run() cross 探测 → PR#28759 补丁；ninja 需 host PATH；跨 arch build-dir 污染需清理）
- [x] Task 2: engine.yml 扩展（numpy 安装 + 冒烟）
  - [x] 2.1 新增 "Install numpy wheel" 步骤：curl 下载 wheel → sha256 校验 → unzip 到 `$SLICE/lib/python3.14/site-packages/`
    - 落点：双区合并后（Build Engine.app 步骤内）、ldid 全签前——装入的 .so 随 ldid 一次签名覆盖；安装逻辑收敛在 scripts/install_numpy_into_engine.sh（CI/本地共用）
  - [x] 2.2 ldid 重签覆盖确认（既有 find Mach-O 阶段顺序在 wheel 安装之后，或显式重签 numpy .so）
    - 确认：Engine.app 内 ldid 全签循环在 numpy 安装之后（engine.yml 顺序：合并 → manifest → 装 numpy → vtool 冒烟 → ldid 全签 → files.sha256）
  - [x] 2.3 打包冒烟扩展：CI 内以解包产物执行 `import numpy` + `numpy.array([1,2,3]).mean()` 断言（对齐 stdlib landmark 冒烟风格）
    - **调整说明**：beeware 包无可独立执行的 python（只有 dylib + 交叉工具链，iOS .so 无法被 macOS host 加载），CI 内无法真跑 import——改为**结构冒烟加强**（lipo 架构 + vtool 平台标记逐 .so 验证 iphoneos）；执行断言由 KlineTests 冒烟用例（模拟器）与真机 PyBridge 冒烟承担
  - [x] 2.4 manifest `build` 字段追加 numpy 版本标记；Release 说明补充 numpy 来源与体积
    - 标记逻辑收敛在 install_numpy_into_engine.sh（幂等：先剥旧标记再追加；`beeware-3.14-b11+numpy-2.5.3`），CI/本地单一来源；build-numpy-wheel.yml 与 engine.yml Release 说明均已补 numpy 来源
- [x] Task 3: 模拟器验证（iPad mini 5th gen）
  - [x] 3.1 本地引擎缓存（模拟器内嵌变体）按同一安装逻辑补 numpy
    - 已实测：EngineCache/sim 装入 19 个 .so（22M），manifest 自动标记 `beeware-3.14-b11+numpy-2.5.3`
  - [x] 3.2 新增 KlineTests numpy 冒烟用例：经 runPyBridge 执行 import + 数组运算断言；无 numpy 环境 XCTSkip（对齐 PyBridge 契约测试的 skip 语义）
    - KlineTests/PyBridgeNumpySmokeTests.swift：runScriptCapturingOutput inline 脚本（import + mean/dot/max/dtype 断言，版本钉 2.5.3）；ImportError 内联捕获回传 → numpy 未安装 XCTSkip。修正一轮：ensureEngineReady 须主动触发加载（对齐契约测试），否则用例顺序在前时误 skip
  - [x] 3.3 `xcodebuild test -only-testing:KlineTests` 全绿（含新用例），xcresult 取证
    - 2026-10-07 实测：iPad mini 5th gen（54291852，GUI 可见）**37/37 全绿（0 fail 0 skip）**，testNumpyImportAndCompute Passed 0.56s；xcresult: /tmp/kline_numpy_test.xcresult
- [ ] Task 4: 真机发布与验证（用户执行）
  - [x] 4.1 手动触发 engine.yml 出新 .tipa（engine-3.14.7 tag --clobber + sha256 sidecar）
    - 2026-10-07 实证：build-numpy-wheel.yml run 37507451005 发 `numpy-wheel-2.5.3` Release（双 wheel + sidecar）；engine.yml run 37508185511 全绿，`KlineEngine-3.14.7.tipa` 28,386,228 字节 sha256 `bf0b490e…`；下载后解包验证 19 个 numpy .so + __init__.py 就位（路径 ios-arm64/lib/python3.14/site-packages/）
  - [x] 4.2 用户经 TrollStore 更新 Engine.app → App 内 PyBridge 冒烟确认 numpy 可用（沙盒日志取证）
    - 2026-10-07 真机实证（iPad mini 4，klinehttp 拉日志）：App #501「更新引擎」行自动检查 `发现新引擎 #9（当前 #7）` → 下载 24s → sidecar sha256 + Release digest 双校验通过（tipa 28,386,228 字节与 Release 一致）→ opener 拉起 TrollStore（完整 28MB 流式送装）；装后引擎加载正常（dlopen 24.2ms / Py_Initialize 112.2ms）。numpy 标记终验：更新引擎行应显示绿勾 `最新#9 当前 #9`（Python Engine Lab 显示 v3.14.7（beeware-3.14-b11+numpy-2.5.3，api=1））
- [x] Task 5: 文档回填 + 提交
  - [x] 5.1 可行性分析 §8.1 第 8 条标记完成 + 体积实测记录（.tipa 前后对比）
    - 已回填：mobile-forge/PyPI 证伪 + cibuildwheel 自建定案 + 12 轮实证坑 + 体积实测 22.0MB→28.4MB（+6.4MB，远小于预估数十 MB——allow-noblas 纯 C 回退无 OpenBLAS）+ 真机更新通道实证
  - [x] 5.2 checklist 逐项核验勾选；git commit + push

# Task Dependencies

- Task 2 依赖 Task 1（wheel URL/校验值/落点方案确定后才可写工作流）
- Task 3 依赖 Task 2（同一安装逻辑本地复刻）
- Task 4 依赖 Task 3（模拟器全绿才发布真机）
- Task 5 依赖 Task 4（真机确认后收尾）
