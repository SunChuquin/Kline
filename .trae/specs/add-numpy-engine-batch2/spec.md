# numpy 第二批（候选 13 · 引擎基建）Spec

## Why

阶段 1 试点批（`add-python-offload-pilot`）已验收：模拟器 36/36 全绿、降级 4 skip 0 fail、真机部署路径已由用户修复（Windows GitHub 更新链路）。经用户决策（可行性分析 §8.1 第 8 条），numpy 引入拆为第二批，进入条件已满足。NumPy 已于 2026-07 接受 iOS 为 Tier 3 支持平台（beeware 主导、cibuildwheel 产 iOS arm64 wheel），mobile-forge wheel 链路具备落地条件。本批**只做基建**：让引擎包带上 numpy，业务脚本 `import numpy` 即可用；候选 13 的首个业务脚本（stats.py 等）等有真实指标需求时再立项。

## What Changes

- `engine.yml`（引擎包构建）新增 wheel 安装步骤：下载 mobile-forge 的 numpy iOS arm64 wheel（cp314）→ 解包到引擎 `lib/python3.14/site-packages/` → 与既有 Mach-O 一同 ldid 重签 → 打包冒烟新增 `import numpy` + 简单运算断言 → `files.sha256` 自动覆盖（既有 find 全量生成，天然覆盖）
- manifest `build` 字段追加 numpy 版本标记（如 `beeware-3.14-b11+numpy-2.x.x`）；**schema/apiVersion/layout 零改动**——App 端生产代码本批零改动
- 模拟器内嵌引擎变体同步安装 numpy（本地与 CI 同一套安装逻辑），新增桥接冒烟测试：经 `runPyBridge` 执行 `import numpy` + 数组运算断言；无 numpy 环境（旧引擎）XCTSkip
- 发布新 `KlineEngine-3.14.7.tipa`（engine-3.14.7 tag --clobber），用户经 TrollStore 更新 Engine.app 后真机验证
- 体积增量实测记录（.tipa 前后对比），回填可行性分析 §8.1

**不改**：桥接契约（kline_input/kline_result）、脚本分发、降级矩阵——脚本 `import numpy` 失败天然走既有 `scriptError` 路径 → Swift 降级，无需新兜底代码。

## Impact

- Affected specs: `add-python-offload-pilot`（后续批次承接）、`embed-python-engine-macos`（引擎链路扩展）
- Affected code:
  - `.github/workflows/engine.yml`（唯一生产链路改动）
  - `KlineTests/`（新增 numpy 冒烟测试，无 App 生产代码改动）
  - `.trae/documents/python-engine/Python引擎下沉可行性分析.md`（回填）
- 体积代价（用户已接受）：numpy iOS arm64 wheel 解压约 30-60 MB，.tipa 与 Engine.app 同步增大；**IPA 不受影响**（引擎只在 Engine.app）

## ADDED Requirements

### Requirement: 引擎包携带 numpy
引擎包（Engine.app / .tipa）SHALL 在 `lib/python3.14/site-packages/` 携带 numpy iOS arm64 版本，且所有 Mach-O（.so）经 ldid ad-hoc 重签，与既有引擎 Mach-O 同等授信。

#### Scenario: 打包冒烟
- **WHEN** engine.yml 构建完成
- **THEN** 在 CI 内用解包产物执行 `import numpy; numpy.array([1,2,3]).mean()` 冒烟（模拟引擎运行时语义），任一失败则 CI 失败

### Requirement: wheel 来源可复现
wheel 下载 SHALL 使用固定 URL + sha256 校验（与 .tipa sidecar 同等完整性纪律），版本变更需显式改工作流。

#### Scenario: 校验失败
- **WHEN** wheel sha256 与预期不符
- **THEN** CI 立即失败，不产出引擎包

### Requirement: App 端零改动 + 降级语义不变
App 生产代码 SHALL 零改动。脚本使用 numpy 时：引擎含 numpy → 正常执行；引擎不含 numpy（用户未更新 Engine.app）→ `import` 抛错走既有 `scriptError` → 调用方 Swift 降级，DebugLogger 可检索。

#### Scenario: 旧引擎跑 numpy 脚本
- **WHEN** 用户 Engine.app 为旧版（无 numpy），业务脚本 import numpy
- **THEN** 桥接返回失败（错误信息含 ImportError 线索），调用方走 Swift 降级，无崩溃

### Requirement: 模拟器验证与跳过语义
KlineTests SHALL 新增 numpy 冒烟用例：有 numpy 引擎时经桥接执行运算断言；无 numpy（含 CI/未更新引擎缓存）时 XCTSkip 不 fail。

#### Scenario: 双环境测试
- **WHEN** 模拟器跑 KlineTests
- **THEN** 含 numpy 引擎：新用例通过；无 numpy 环境：新用例 skipped，其余全绿
