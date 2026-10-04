# Tasks

> 实施依据：`spec.md`。原则：运行时行为零变更；Swift 侧只做可见性放宽与纯函数抽取（逐行搬运）；golden 由 PC 侧 Python 产出。
> 验证链路：`xcodebuild test`（KlineTests scheme）+ 设备构建部署冒烟（走 kline-device-validation-loop）。

- [ ] Task 1: 新建 `KlineTests` 单元测试 target
  - [ ] SubTask 1.1: 手改 `project.pbxproj`：参照既有 `KlineUITests` 条目（pbxproj:118-140）新增 unit test bundle target（productType `com.apple.product-type.bundle.unit-test`），Sources/Resources/Frameworks 三个 build phase 齐备，TEST_HOST 指向 Kline.app（保证 `@testable import Kline` 可用）
  - [ ] SubTask 1.2: 放入占位测试文件（一个 trivially-passing XCTest）验证 target 编译、`@testable import Kline` 生效、Fixtures 资源可经 `Bundle(for:)` 读取
  - [ ] SubTask 1.3: 构建/测试验证：xcodebuild build + test 通过；Kline 主 target 产物无变化

- [ ] Task 2: golden 生成脚本与 fixtures（PC 侧 Python，可与 Task 3 并行）
  - [ ] SubTask 2.1: 新建 `src/contract_golden.py`（纯标准库；复用 `tdx_parser.py` / `live_db_builder.py` 既有函数 import 调用，不复制逻辑）：合成日线序列（覆盖跨年、闰年 2/29、季切换、月末/年末最后交易日、停牌空档、单日周期）、真实抓包样本（东财快照 JSON、腾讯 newfqkline 响应，以原始字符串内置）、`universe_secids.txt` 全量 secid 映射、`Kline/Indicators/*.tdx` 全 corpus 解析输出（含 `swiftExpected: rejected` 标记）
  - [ ] SubTask 2.2: 产出 `KlineTests/Fixtures/*.json`（period_aggregation.json / quote_parsing.json / secid_mapping.json / indicator_templates.json），格式带版本字段与输入快照，保证单独可读
  - [ ] SubTask 2.3: 确定性验证：连续运行两次，git diff 为空；脚本不含网络调用与随机源

- [ ] Task 3: Swift 侧最小可见性放宽与纯函数抽取（不改行为；可与 Task 2 并行）
  - [ ] SubTask 3.1: `WatchlistSyncManager.mergePeriodBar`（:306，private static → internal static，逐行不动）
  - [ ] SubTask 3.2: `EastmoneyQuoteFetcher`：`decodeChunk`（:372）与 `EMSnapshot`（:408）private → internal；`secid(forFile:)`（:149）抽出等价静态纯函数（读 `universe_secids.txt` 的映射逻辑搬为无状态形态，原实例方法改为委托调用，行为不变）
  - [ ] SubTask 3.3: `GapBackfill`：把 `fetchSourceBars`（:670-711）中腾讯行数组 11 字段解析抽成纯函数（入参 `[Any]`/行数组 → SourceBar，逐行搬运）；`calibrate`（:584）private → internal
  - [ ] SubTask 3.4: `SystemIndicatorStore.parse(content:id:)`（:58）private → internal
  - [ ] SubTask 3.5: 自查：`git diff` 逐行复核，除可见性关键字与函数搬移外零改动；编译通过

- [ ] Task 4: 三个契约测试文件（依赖 Task 1/2/3）
  - [ ] SubTask 4.1: `PeriodAggregationContractTests.swift`：读 period_aggregation.json，对每组合成序列调 Swift 侧聚合（mergePeriodBar + 既有周期键规则），逐周期桶逐字段断言；停牌周期断言两侧均无 bar
  - [ ] SubTask 4.2: `QuoteParsingContractTests.swift`：读 quote_parsing.json + secid_mapping.json；decodeChunk ↔ golden（东财快照）；腾讯行解析纯函数 ↔ golden（开-收-高-低顺序陷阱用例置顶）；calibrate ↔ golden（量比 1/100 吸附、额折算、不符丢弃用例）；secid 全量对拍
  - [ ] SubTask 4.3: `IndicatorTemplateContractTests.swift`：读 indicator_templates.json，遍历 corpus 断言四字段一致；`swiftExpected: rejected` 条目断言 parse 返回 nil（KIND=TECH 差异编码）
  - [ ] SubTask 4.4: 失败信息可诊断：断言失败时输出「字段名 + 两侧值 + 对应 fixture 键」，不做模糊 assert

- [ ] Task 5: 全链路验证（依赖 Task 4）
  - [ ] SubTask 5.1: `xcodebuild test`（KlineTests scheme）全绿；记录用例数
  - [ ] SubTask 5.2: 既有 KlineUITests 不受影响（编译通过，不强制全量跑 UI 测试）
  - [ ] SubTask 5.3: 设备构建部署冒烟（kline-device-validation-loop）：图表/指标、补缺口页面、条件单页面可正常打开，行为与改动前一致，暂停等用户在设备上确认

# Task Dependencies

- Task 2 与 Task 3 相互独立，可并行
- Task 4 依赖 Task 1（target）、Task 2（fixtures）、Task 3（Swift 纯函数形态）
- Task 5 依赖 Task 4
- 全程不触发 PC 数据管线运行、不改 CI、不引入第三方依赖
