# Tasks

> 实施依据：`spec.md`。原则：运行时行为零变更；Swift 侧只做可见性放宽与纯函数抽取（逐行搬运）；golden 由 PC 侧 Python 产出。
> 验证链路：`xcodebuild test`（KlineTests scheme）+ 设备构建部署冒烟（走 kline-device-validation-loop）。

- [x] Task 1: 新建 `KlineTests` 单元测试 target
  - [x] SubTask 1.1: 手改 `project.pbxproj`：参照既有 `KlineUITests` 条目（pbxproj:118-140）新增 unit test bundle target（productType `com.apple.product-type.bundle.unit-test`），Sources/Resources/Frameworks 三个 build phase 齐备，TEST_HOST 指向 Kline.app（保证 `@testable import Kline` 可用）
  - [x] SubTask 1.2: 放入占位测试文件（一个 trivially-passing XCTest）验证 target 编译、`@testable import Kline` 生效、Fixtures 资源可经 `Bundle(for:)` 读取 —— CI 模拟器运行通过（2 tests, 0 failures）
  - [x] SubTask 1.3: 构建/测试验证：xcodebuild build + test 通过；Kline 主 target 产物无变化 —— 云构建 run=37177824000 编译通过；测试 run=37181794110 全绿

- [x] Task 2: golden 生成脚本与 fixtures（PC 侧 Python，可与 Task 3 并行）
  - [x] SubTask 2.1: 新建 `src/contract_golden.py`（纯标准库；复用 `tdx_parser.py` / `live_db_builder.py` 既有函数 import 调用，不复制逻辑）：合成日线序列（覆盖跨年、闰年 2/29、季切换、月末/年末最后交易日、停牌空档、单日周期）、真实抓包样本（东财快照 JSON、腾讯 newfqkline 响应，以原始字符串内置）、`universe_secids.txt` 全量 secid 映射、`Kline/Indicators/*.tdx` 全 corpus 解析输出（含 `swiftExpected: rejected` 标记）
  - [x] SubTask 2.2: 产出 `KlineTests/Fixtures/*.json`（period_aggregation.json / quote_parsing.json / secid_mapping.json / indicator_templates.json），格式带版本字段与输入快照，保证单独可读
  - [x] SubTask 2.3: 确定性验证：连续运行两次，输出 MD5 字节级一致；脚本不含网络调用与随机源（真实抓包样本于 2026-10-04 一次性获取后内置）

- [x] Task 3: Swift 侧最小可见性放宽与纯函数抽取（不改行为；可与 Task 2 并行）
  - [x] SubTask 3.1: `WatchlistSyncManager.mergePeriodBar`（:306，private static → internal static，逐行不动）
  - [x] SubTask 3.2: `EastmoneyQuoteFetcher`：`decodeChunk`（:372）与 `EMSnapshot`（:408）private → internal；`secid(forFile:)`（:149）抽出等价静态纯函数（原实例方法改为委托调用，行为不变）
  - [x] SubTask 3.3: `GapBackfill`：腾讯行数组 11 字段解析抽成 `static func parseTencentRow(_ r: [Any]) -> SourceBar?`（逐字符搬移，仅 continue→return nil、append→return）；`calibrate`（:584）private → internal。**附带修复：`ProbeItem` 原定义在被删的 DirectQuoteProbe.swift，已逐字收编进 GapBackfill.swift（此前删除时漏检裸类型名，云构建证实修复后编译通过）**
  - [x] SubTask 3.4: `SystemIndicatorStore.parse(content:id:)`（:58）private → internal
  - [x] SubTask 3.5: 自查：`git diff` 逐行复核，除可见性关键字与函数搬移外零改动；编译通过（GitHub Actions 云构建 run=37177824000 证实）

- [x] Task 4: 三个契约测试文件（依赖 Task 1/2/3）
  - [x] SubTask 4.1: `PeriodAggregationContractTests.swift`：8 个用例（7 组用例 + 清单校验），periodDateRange 分桶 + mergePeriodBar 逐桶逐字段断言；停牌周期断言两侧均无 bar（amo 因 Python 端 6 位小数规整用 1e-6 绝对容差，vol 精确相等）
  - [x] SubTask 4.2: `QuoteParsingContractTests.swift`：14 个用例（东财快照 1、腾讯K线 2 含开-收-高-低陷阱、calibrate 9、secid 2 含 knownDivergence 分歧可见性断言）
  - [x] SubTask 4.3: `IndicatorTemplateContractTests.swift`：2 个方法（31 份 corpus 全 accepted 迭代 + rejected 分支；corpus 无非 TECH 模板，附加 2 条合成负控守住拒载分支，已标注非 fixture 数据）
  - [x] SubTask 4.4: 失败信息可诊断：断言失败时输出「字段名 + 两侧值 + 对应 fixture 键」

- [x] Task 5: 全链路验证（依赖 Task 4）
  - [x] SubTask 5.1: `xcodebuild test`（KlineTests scheme）全绿 —— **GitHub Actions 模拟器 run=37181794110：26 tests, 0 failures（24 契约 + 2 占位），无需本地 Mac**
  - [x] SubTask 5.2: 既有 KlineUITests 不受影响 —— 测试构建中该 target 编译通过（仅 -skip-testing 跳过执行）
  - [x] SubTask 5.3: 设备构建部署冒烟（kline-device-validation-loop）：云构建成功 + TrollStore 部署完成（Kline v1.0.2 build 448），用户真机冒烟三项确认无问题

# Task Dependencies

- Task 2 与 Task 3 相互独立，可并行
- Task 4 依赖 Task 1（target）、Task 2（fixtures）、Task 3（Swift 纯函数形态）
- Task 5 依赖 Task 4
- 全程不触发 PC 数据管线运行、不改 CI、不引入第三方依赖
