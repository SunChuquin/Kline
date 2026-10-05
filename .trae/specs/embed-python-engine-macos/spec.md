# macOS 构建路径内嵌 Python 引擎 Spec

## Why

Python 引擎现已按 Windows 路径落地为独立 Engine.app(.tipa) + TrollStore 授信 + Engine.app 路径 dlopen（Phase-0 完美收尾）。macOS 构建部署路径（`scripts/kline_deploy_mac.sh` 本机 xcodebuild → simctl/devicectl 安装）当前拿不到引擎。用户要求：macOS 路径构建时引擎直接作为资源随 Kline.app 打包部署运行，**真机与模拟器目标都要嵌入**；Windows 路径（CI + TrollStore + 独立引擎包）保持原样。

## What Changes

- **新增构建期嵌入（真机 + 模拟器）**：Kline target 追加 "Embed Python Engine" Run Script 构建阶段（Resources 之后、签名之前），按当前构建平台选择变体拷入 `Kline.app/KlineEngine/`：
  - `PLATFORM_NAME == iphoneos` → `EngineCache/device/`（真机 slice）
  - `PLATFORM_NAME == iphonesimulator` → `EngineCache/sim/`（模拟器 slice，Apple Silicon 模拟器可用）
  - 门禁：对应变体缓存目录存在 且 `KLINE_SKIP_ENGINE_EMBED != 1`；不满足则输出跳过原因、exit 0（构建不失败）。**缓存存在即嵌入**——Xcode GUI 构建同样生效，无需环境变量；CI checkout 恒无 `EngineCache/` → **Windows 路径结构性不嵌入**，硬约束「引擎不进 CI IPA」不变
  - 拷贝幂等（先清后拷）；嵌套 Mach-O 由 Xcode 自动签名流程一并签名（模拟器无签名）
- **新增引擎缓存准备脚本** `scripts/prepare_engine_cache.sh`：下载一次 beeware/Python-Apple-support 原始包（双 slice，版本常量置顶）→ 为两个变体各自执行「slice + 共享 stdlib 合并」（镜像 engine.yml 合并逻辑，slice 内 `lib-*/python3.14` 防御式定位）→ 生成 schema v1 manifest（layout 无前缀、直接相对 `KlineEngine/`）→ stdlib landmark 冒烟；幂等、`--force` 重做、失败非零退出（坏包绝不进缓存）
- **kline_deploy_mac.sh 集成**：构建前（模拟器与真机目标都）跑准备脚本；失败 → 警告 + 继续无引擎部署（降级路径，绝不阻断）
- **Swift 宿主来源抽象**（PythonEngineHost）：新增 `PythonEngineSource { embedded, engineApp }` 与 `locateEngineDir()`——优先定位 bundle 内嵌引擎（`Bundle.main/KlineEngine/manifest.json`），回退现有 Engine.app 扫描；`status()/engineManifest()/loadEngine()/runScriptIsolated()` 全部走统一来源；状态文案按来源参数化（内嵌损坏 ≠ 「TrollStore 卸载重装」）
- **UI 展示来源**（PythonEngineLabView 状态区）：新增「引擎来源」行（内嵌（随包）/ Engine.app / —）
- **单测**：manifest 解码 + `resolve()` 路径解析 + 内嵌布局定位（临时目录注入）
- **.gitignore**：`EngineCache/`（引擎产物不入库）
- **Windows 引擎包链路零改动**：engine.yml / build.yml 不动；Engine.app 下载/TrollStore 安装/加载链路原样保留
- **模拟器能力边界（如实声明）**：进程内链路（加载 + PyRun + 实验①②③）在模拟器完全可用；pyrunner 隔离子进程路径依赖 opener/root（本地构建无、模拟器无 root 语义），维持既有「构建异常」报错，不属本次范围

## Impact

- Affected specs: 无既有 spec（`.trae/specs/` 为空）；关联文档 `Python引擎下沉可行性分析.md` §5（双路径）、`Phase-0引擎实验-plan.md`
- Affected code:
  - `Kline.xcodeproj/project.pbxproj`（新增 PBXShellScriptBuildPhase + buildPhases 追加）
  - `scripts/prepare_engine_cache.sh`（新）、`scripts/kline_deploy_mac.sh`、`.gitignore`
  - `Kline/Debug/PythonEngineHost.swift`、`Kline/Debug/PythonEngineLabView.swift`
  - `KlineTests/`（新增测试文件）

## ADDED Requirements

### Requirement: 构建期引擎嵌入（macOS 路径，真机 + 模拟器）
系统 SHALL 在 Kline target 提供 "Embed Python Engine" Run Script 构建阶段：按 `PLATFORM_NAME` 选择 `EngineCache/device/`（iphoneos）或 `EngineCache/sim/`（iphonesimulator）变体，在该变体目录存在且 `KLINE_SKIP_ENGINE_EMBED != 1` 时，把变体目录整树幂等拷贝为 `Kline.app/KlineEngine/`（拷贝前清空目标目录）。其余平台或条件不满足 SHALL 跳过并输出可读日志，构建不失败。

#### Scenario: macOS 真机构建命中嵌入
- **WHEN** 真机目标构建且 `EngineCache/device/` 已就位
- **THEN** 产物 `Kline.app/KlineEngine/` 内含 manifest.json、Python.framework（ios-arm64 slice）、lib/python3.14；Xcode 签名覆盖嵌套 Mach-O，安装启动正常，dlopen 走 bundle 内 dylib

#### Scenario: 模拟器构建嵌入模拟器 slice
- **WHEN** 模拟器目标构建（含 iPad mini 5 模拟器）且 `EngineCache/sim/` 已就位
- **THEN** 产物内含模拟器 slice 引擎；实验室页可完成加载（dlopen + Py_Initialize）并跑通实验①②③（进程内链路）

#### Scenario: Xcode GUI 构建同样嵌入
- **WHEN** 缓存已就位时直接在 Xcode 内 Cmd+R 构建运行
- **THEN** 产物含引擎（缓存存在即嵌入，无需脚本设置环境变量）

#### Scenario: CI 构建结构性不嵌入
- **WHEN** GitHub Actions build.yml 执行（checkout 恒无 EngineCache）
- **THEN** 产出的 IPA 不含任何 Python 引擎文件（Windows 路径硬约束保持）

#### Scenario: 缓存缺失或显式跳过时降级
- **WHEN** 变体缓存不存在、准备脚本失败、或设置 `KLINE_SKIP_ENGINE_EMBED=1`
- **THEN** 跳过嵌入并输出原因，部署继续（App 全功能可用，引擎状态为未安装）

### Requirement: 引擎缓存准备脚本（单源双变体）
`scripts/prepare_engine_cache.sh` SHALL 下载一次 beeware 原始包（URL 由置顶常量 BEEWARE_TAG / PYTHON_VERSION 拼出）并缓存于 `EngineCache/beeware/`，为真机与模拟器各产出一份合并后引擎树（`EngineCache/device/`、`EngineCache/sim/`，含 manifest.json + Frameworks/Python.xcframework/<slice>/{Python.framework, lib/python3.14}）；manifest 为 schema v1（apiVersion=1，layout 相对 `KlineEngine/` 无前缀）；每个变体 SHALL 通过 stdlib landmark 冒烟（encodings/__init__.py、os.py、lib-dynload）否则非零退出；变体目录已存在且未 `--force` 时 SHALL 跳过（幂等）。

#### Scenario: 一键双变体就位
- **WHEN** 本机无缓存时执行 `bash scripts/prepare_engine_cache.sh`
- **THEN** `EngineCache/device/` 与 `EngineCache/sim/` 均就位且 landmark 冒烟通过，重复执行直接跳过

#### Scenario: 坏数据不进缓存
- **WHEN** 下载中断或合并后 landmark 缺失
- **THEN** 非零退出，不产出（或清除）该变体目录

### Requirement: Swift 宿主引擎来源抽象
PythonEngineHost SHALL 支持两种引擎来源并按优先级定位：内嵌（`Bundle.main/KlineEngine/`，优先）→ Engine.app（TrollStore 安装路径，回退）。状态机四态语义（notInstalled / installed / versionMismatch / corrupted）与 `apiVersion` 配对校验对两种来源一致；错误文案 SHALL 按来源参数化。进程内加载链路（stdlib 预检 → setenv PYTHONHOME → dlopen → Py_Initialize → SaveThread）与 PyRun 链路对内嵌路径零特殊分支（路径与布局对齐 manifest 契约）。

#### Scenario: 内嵌引擎被优先识别
- **WHEN** App bundle 内存在 `KlineEngine/manifest.json` 且校验通过
- **THEN** `status()` 返回 `.installed`（来源 = embedded），`loadEngine()` 从 bundle 内 dylib 成功 dlopen 并初始化

#### Scenario: 模拟器内嵌引擎可加载
- **WHEN** 模拟器构建（含内嵌 sim 变体）打开实验室页并点「加载引擎」
- **THEN** stdlib 预检通过、dlopen 与 Py_Initialize 计时数字可读、sys.version 正确回读

#### Scenario: 无内嵌时回退 Engine.app
- **WHEN** bundle 内无 KlineEngine 且 TrollStore 已装 Engine.app
- **THEN** 行为与 Phase-0 完全一致（Windows 路径回归无变化）

#### Scenario: 内嵌引擎损坏给出正确文案
- **WHEN** 内嵌 manifest 不可读或 dylib 缺失
- **THEN** 报「引擎损坏」并提示重新构建部署（而非 TrollStore 卸载重装）

### Requirement: UI 展示引擎来源
Python 引擎实验室状态区 SHALL 新增「引擎来源」行，显示 内嵌（随包）/ Engine.app / —，与既有「当前状态 / 引擎版本 / 解释器」行并列。

#### Scenario: 内嵌部署展示
- **WHEN** 内嵌引擎构建（真机或模拟器）部署后打开实验室页
- **THEN** 来源行显示「内嵌（随包）」，引擎路径行指向 bundle 内 KlineEngine 目录

## MODIFIED Requirements

（无既有 spec 需求变更；行为增量均向后兼容，降级路径不变）

## REMOVED Requirements

（无）
