# Phase-0 引擎实验计划（独立引擎包 + 调试 harness）

> 上游：`Python引擎下沉可行性分析.md` §5.6 / §5.6.1 / §7。用户已拍板：引擎不随 IPA 打包，独立引擎包 + 顺序保障；更新矩阵按 §5.6.1（引擎与 IPA 两个独立版本轴）。

## Context

- 目标设备：iPad mini 4 / iOS 15.5.x / TrollStore，entitlements 含 no-sandbox
- 引擎产物：BeeWare `Python-3.14-iOS-support.b11.tar.gz`（Python 3.14.7，min iOS 13.0-arm64 实证，`_ssl/_socket/zlib` 齐全，35.3MB 压缩）
- 待验证三件事（§7）：① dlopen + Py_Initialize 可行性 ② 冷启动/桥接/150 根计算耗时 ③ Python 侧并发取数吞吐（对照原生）
- 不做：引擎不进 IPA；不做 dlclose（不可靠）；不装 numpy（先测纯 Python 基线，numpy 走 mobile-forge wheel 另行评估）

## 引擎包格式（两端共用契约，v1）

CI 产出 `KlineEngine-<ver>.tar.gz`，内部只保留真机 slice：

```
engine/
├── manifest.json          # schema/engineVersion/build/apiVersion/layout
└── Python.xcframework/ios-arm64/…   # Python.framework + lib-arm64/python3.14(stdlib)
```

```json
{
  "schema": 1, "engineId": "cpython",
  "engineVersion": "3.14.7", "build": "beeware-3.14-b11", "apiVersion": 1,
  "layout": {
    "dylib": "engine/Python.xcframework/ios-arm64/Python.framework/Python",
    "home":  "engine/Python.xcframework/ios-arm64/lib-arm64/python3.14"
  }
}
```

sha256 不可放进包内（自引用），放**同名 `.sha256` sidecar**，与 tar.gz 一起发 Release。Release 通道独立：tag `engine-3.14.7-b11`，与 `latest`（IPA）互不干扰。

## 设备目录布局与更新矩阵

```
<App 沙盒>/Documents/KlineEngine/
├── active/     ← 在用引擎（staging 校验通过后 rename 切换；无则引擎未安装）
├── staging/    ← 下载/解压临时区
└── incoming.tar.gz / incoming.sha256
```

更新矩阵（§5.6.1）：IPA/引擎哪个有变更下哪个；引擎更新下次启动生效（旧 libpython 已映射，dlclose 不可靠）；IPA 更新后加载前校验 `apiVersion ∈ [minEngineAPI, maxEngineAPI]`（App 内常量，Phase-0 = 1..1），不兼容按降级矩阵禁用引擎功能。

## 分步实现

| 阶段 | 内容 | 验证 |
| --- | --- | --- |
| A | `.github/workflows/engine.yml`：下载 beeware b11 → 剥离模拟器 slice → ad-hoc codesign Python.framework → 打包 + sha256 sidecar → 发独立 Release（workflow_dispatch，可重复执行 --clobber） | CI 产资产，本地 curl 可下 |
| B | Swift 侧 `PythonEngineHost`（状态扫描/manifest 校验/下载→staging→激活/dlopen+Py_Initialize/PyRun 计时）+ `PythonEngineLabView` 调试页（挂个人中心调试区）：按钮=检查状态/下载引擎/加载引擎/实验①dlopen/实验②计时(冷启动+150根MA/EMA纯Python)/实验③吞吐(urllib 多线程小规模 N≈20)/卸载重置 | 设备 build & deploy（走既有闭环），模拟器 xcodebuild test 编译不回归 |
| C | 真机跑三实验，结果回填 §7 表，决定阶段 1 切法 | 用户真机确认 |

## 边界（硬约束）

- 引擎不进 IPA：build.yml 不下载/不嵌入任何 Python 产物
- harness 是纯调试页：不影响任何生产路径；引擎初始化只在用户点按钮时发生，不进启动链
- Python 侧只跑实验脚本；不写库、不动配置
- 吞吐实验请求量小（约 20 次），避免触发服务端限流

## 验收清单

- [ ] CI 能一键产出引擎包 Release（重复执行幂等）
- [ ] harness 显示引擎包状态机（未安装/已下载待激活/已激活/版本不兼容）
- [ ] 实验①：dlopen 非空 + Py_Initialize 成功 + sys.version 正确回读
- [ ] 实验②：冷启动耗时 + 150 根 MA/EMA 纯 Python 计时数字可读
- [ ] 实验③：urllib 并发吞吐 req/s 数字可读（与原生 GapBackfill 对照）
- [ ] 引擎更新走 staging→active，失败不破坏在用引擎
- [ ] 不安装引擎时 App 全功能无感（降级路径）

## Critical Files

- `.github/workflows/engine.yml`（新）
- `Kline/Debug/PythonEngineHost.swift`、`Kline/Debug/PythonEngineLabView.swift`（新）
- `Kline/Profile/`（个人中心调试入口挂载点，参考 LocalUpdateView.swift）
- `Python引擎下沉可行性分析.md` §7（实验结果回填）
