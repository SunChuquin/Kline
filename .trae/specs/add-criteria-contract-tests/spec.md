# 口径契约测试（阶段 0）Spec

> change-id: `add-criteria-contract-tests`
> 上游依据：`.trae/documents/python-engine/Python引擎下沉可行性分析.md` §6.3 阶段 0、§1.4

## Why

可行性分析 §1.4 指出：PC 侧 Python 与 App 侧 Swift 对同一批口径（周期聚合、取数口径、模板解析）各有一份实现，目前靠源码注释「改这里前先读那边」维持一致，是已书面化的漂移面。§6.3 阶段 0 的结论是：把「靠注释对齐」升级为「靠测试锁死」——为三处口径各建一份契约测试（PC 侧 Python 产出 golden 值，Swift 侧断言同值），**不需要 Python 引擎、不改构建链路、现在就可做**，且是阶段 1（引擎引入）的进入条件。

用户约束：本改动只是实现方式与验证方式的变化，**运行时功能、性能、可靠性、稳定性必须与现状完全相同**。

## What Changes

- 新建单元测试 target `KlineTests`（手改 `project.pbxproj`，参照既有 `KlineUITests` 条目；现有同步文件夹加文件免改 pbxproj，但**新建 target 必须手改**）
- 新建 golden 生成脚本 `src/contract_golden.py`（纯标准库，与 src/ 既有模块零依赖风格一致），产出确定性 fixtures（JSON）到 `KlineTests/Fixtures/`
- Swift 侧**最小可见性放宽与纯函数抽取**（行为零变更）：
  - `WatchlistSyncManager.mergePeriodBar`（private static → internal）
  - `EastmoneyQuoteFetcher.decodeChunk` / `EMSnapshot`（private → internal）、`secid(forFile:)` 补静态纯函数形态
  - `GapBackfill` 腾讯 `newfqkline` 行解析从 `fetchSourceBars` 网络路径中抽取为纯函数；`calibrate`（private → internal）
  - `SystemIndicatorStore.parse(content:id:)`（private → internal）
- 新增三个契约测试文件：周期聚合 / 取数口径 / 模板解析
- **无 BREAKING**；不改任何运行时算法、不改网络/DB 路径、不改 CI

## Impact

- Affected specs: `analyze-python-engine-offload`（阶段 0 落地，阶段 1 进入条件之一达成）
- Affected code:
  - `Kline.xcodeproj/project.pbxproj`（新增 KlineTests target）
  - `Kline/Trading/WatchlistSyncManager.swift`（仅可见性）
  - `Kline/Infrastructure/EastmoneyQuoteFetcher.swift`（仅可见性 + secid 纯函数形态）
  - `Kline/Infrastructure/GapBackfill.swift`（行解析抽取为纯函数 + 可见性）
  - `Kline/Formula/SystemIndicatorStore.swift`（仅可见性）
  - `src/contract_golden.py`（新增）
  - `KlineTests/`（新增目录：3 个测试文件 + Fixtures/*.json）

## ADDED Requirements

### Requirement: 周期聚合契约

系统 SHALL 提供周期聚合契约测试：对同一组合成日线输入序列，PC 侧 Python（`src/tdx_parser.py` 的 `period_key` + 聚合、`src/live_db_builder.py` 的 `period_bounds`/`aggregate_full_periods`）与 Swift 侧（`WatchlistSyncManager.mergePeriodBar` 及既有周期键规则）产出的周/月/季/年 bar **逐字段一致**（date=周期内首个交易日、OHLC、vol、amo；容差 1e-6）。

#### Scenario: 边界用例全绿

- **WHEN** 合成日线覆盖跨年、闰年 2/29、季切换（Q1→Q2）、月末/年末最后交易日、停牌造成的周期内空档、单日周期（只有一根 bar 的周/月）
- **THEN** Swift 测试对每个周期桶的断言与 golden JSON 完全一致，测试通过

#### Scenario: 停牌标的口径

- **WHEN** 某周期内全部停牌（无 bar）
- **THEN** 两侧均不产出该周期 bar（golden 中无该桶，Swift 断言同样无）

### Requirement: 取数口径契约

系统 SHALL 提供取数口径契约测试，覆盖三组 golden：

1. 东财批量快照原始 JSON → OHLCV/amo（`EastmoneyQuoteFetcher.decodeChunk` ↔ `live_db_builder.py` `_snapshot_from_diff`，字段 f17开/f15高/f16低/f2收/f5量/f6额/f124 交易日）；
2. 腾讯 `newfqkline` 行数组 11 字段 → OHLCV/amo（GapBackfill 抽取后的纯解析函数 ↔ `live_db_builder.py` `_parse_kline_line` 语义，注意价格顺序为**开-收-高-低**）；
3. 量纲自校准（`GapBackfill.calibrate`）：同一基准行 + 源行输入下，量比吸附到 1/100、额折算结果一致。

#### Scenario: 同一原始输入两侧同值

- **WHEN** 用真实抓包样本（东财快照响应、腾讯 newfqkline 响应）作为 fixtures 输入
- **THEN** Swift 解析结果与 golden JSON 逐字段一致（价格 1e-6 容差，vol/amo 整数精确相等）

#### Scenario: secid 映射一致

- **WHEN** 对 `universe_secids.txt` 全量标的及特例段（62#/102# 定制段、hk 前缀）逐一调用 Swift `secid(forFile:)` 纯函数形态
- **THEN** 与 `live_db_builder.py` `secid_for_file` 的 golden 输出一一相同

### Requirement: 模板解析契约

系统 SHALL 提供模板解析契约测试：对 `Kline/Indicators/*.tdx` 全 corpus，`check_indicators.py`（`parse_tdx`）产出的 NAME/SCOPE/GROUP/FORMULA 与 `SystemIndicatorStore.parse` 输出一致。

#### Scenario: 全 corpus 一致

- **WHEN** 遍历全部捆绑 `.tdx` 文件（fixtures 记录每份的四个字段）
- **THEN** Swift 解析结果与 golden 逐字段相同

#### Scenario: KIND=TECH 差异显式编码

- **WHEN** golden 生成脚本遇到非 `KIND=TECH` 的模板（Swift 侧会拒绝、Python 侧不校验）
- **THEN** golden 中显式标记 `"swiftExpected": "rejected"`，Swift 测试断言其被拒——**差异被编码为契约的一部分，而非被掩盖**

### Requirement: golden 可再生且确定

golden 生成脚本 SHALL 是确定性的：固定输入、固定输出，重复运行 byte 级一致；脚本不依赖网络、不依赖仓库外的任何数据（真实抓包样本以原始字符串形式内置在脚本或 fixtures 输入文件中）。

#### Scenario: 再生无 diff

- **WHEN** 连续两次运行 `python3 src/contract_golden.py`
- **THEN** `KlineTests/Fixtures/` 下文件内容不变（git diff 为空）

### Requirement: 运行时行为零变更

Swift 侧改动 SHALL 仅限：可见性放宽（private → internal）、把既有内联纯计算抽取为独立纯函数（逐行搬运，不改算法）。 SHALL NOT 改变：任何网络请求行为、DB 写入路径、指标计算结果、UI 行为、构建产物（除新增测试 target 外）。

#### Scenario: 编译与部署不受影响

- **WHEN** 按既有流程构建并部署到设备
- **THEN** 编译通过，App 全功能与改动前一致（冒烟：图表、补缺口、条件单页面可打开）

### Requirement: 测试可在既有验证链路运行

契约测试 SHALL 能通过 `xcodebuild test`（KlineTests scheme）在 Mac 侧运行；`Fixtures/*.json` 作为 KlineTests target 资源随 bundle 打包，测试经 `Bundle(for:)` 加载。
