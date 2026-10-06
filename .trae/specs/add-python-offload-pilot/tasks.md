# Tasks

- [x] Task 1: 生产桥接层 KlinePythonBridge（新文件 `Kline/Python/KlinePythonBridge.swift`）
  - [x] 1.1 `PythonEngineHost` 最小可见性放宽供程序化复用（不改既有行为：加载链路 / 状态机 / PyRun 执行通道）
  - [x] 1.2 `KlinePythonBridge` 单例：`ensureReady()`（后台队列一次初始化，状态非 `.installed` 不尝试；绝不同步触发）、`call(script:input:timeout:)`（临时文件 JSON in/out + 串行队列 + 等待超时失败）、`isReady`（不触发初始化）
  - [x] 1.3 失败路径统一：引擎未就绪 / 超时 / 脚本报错 → 可读原因返回 + DebugLogger 记录；临时文件清理
- [x] Task 2: 业务脚本 `Kline/PyScripts/`（新目录，随 App bundle；与 Task 1 并行）
  - [x] 2.1 `period_aggregate.py`：桶键规则（周=周一/月=月初/季=季初/年=年初）+ 基期⊕新日线合并（口径对齐 `src/tdx_parser.py` / `live_db_builder.aggregate_full_periods`；整周期停牌无桶不产 bar）；JSON 文件 in/out，异常写 error 字段
  - [x] 2.2 `template_parse.py`：`check_indicators.parse_tdx` 同规则（KIND/NAME/SCOPE/GROUP/COORD/FORMULA，KIND≠TECH 拒载，FORMULA= 单行内联兼容，无 FORMULA 或空模板拒载）；JSON 文件 in/out
  - [x] 2.3 bundle 同步验证（synchronized group 自动并入；模拟器构建产物含 `PyScripts/`）
- [x] Task 3: 候选 3 调用点切换（依赖 Task 1/2；与 Task 4 并行）
  - [x] 3.1 `WatchlistSyncManager.currentPeriodBars`：引擎就绪 → Python 聚合（数据先经既有 SQL 取出再整批传入）；未就绪/失败/超时 → 现有 `mergePeriodBar` 路径原样执行；降级事件 DebugLogger
- [x] Task 4: 候选 1 调用点（依赖 Task 1/2；与 Task 3 并行）
  - [x] 4.1 `SystemIndicatorStore` 后台校准：加载/重载完成后引擎已就绪时对同批 .tdx 内容 Python 重解析对拍；差异以 Python 为准更新 defs + 记录差异明细；init / loadAllPeriods 同步路径零改动
- [x] Task 5: 契约测试扩展（依赖 Task 3/4）
  - [x] 5.1 `PyBridgePeriodAggregationTests`：桥接 → Python vs golden `period_aggregation.json`（四周期全量对齐，容差同既有契约测试）；无引擎 XCTSkip
  - [x] 5.2 `PyBridgeTemplateParseTests`：桥接 → Python vs golden `indicator_templates.json`（含 rejected 与 KIND≠TECH 负控语义）；无引擎 XCTSkip
- [ ] Task 6: 全链路验证（依赖 Task 5）
  - [x] 6.1 模拟器验证（iPad mini 5th gen 模拟器）`xcodebuild test`：桥接契约 + 既有全部测试通过（36/36 全绿，xcresult 实证：PyBridge 契约 ×2 套件 + 冒烟测试 Passed；bundle 内 `PyScripts/` 经 Copy PyScripts 构建阶段物理验证就位）
  - [x] 6.2 降级验证：`KLINE_SKIP_ENGINE_EMBED=1` 构建跑测试（桥接契约 skip、其余全绿）；无引擎路径聚合/模板行为与现状一致（实测 36 tests / 4 skipped / 0 failures：桥接契约 3 用例 + 冒烟 1 用例 XCTSkip，其余 32 个纯 Swift 路径全绿；期间修复 Embed 阶段跳过分支的增量构建引擎残留——跳过时补 rm -rf）
  - [ ] 6.3 真机验证（TrollStore 路径，走既有设备闭环部署）：试点两候选表现用户确认
  - [x] 6.4 文档回填：`Python引擎下沉可行性分析.md` §6.3/§8 记录试点批完成、numpy 第二批与候选 4/2 后续批次规划（§6.3 试点批完成记录 + §8.1 第 7-9 条；含惰性激活 ensureOnce 设计点与沙盒日志三段实证）

# Task Dependencies

- Task 1 与 Task 2 相互独立，可并行
- Task 3、Task 4 依赖 Task 1/2 完成；两者相互独立，可并行
- Task 5 依赖 Task 3/4 完成
- Task 6 依赖 Task 5 完成
