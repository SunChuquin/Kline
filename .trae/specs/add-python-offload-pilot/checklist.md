# Checklist

- [x] KlinePythonBridge 绝不从首帧/启动链同步触发引擎初始化（代码审查：isReady 只读、ensureReady 后台串行队列、call 未就绪即返回不触发加载；降级构建 32 测试全绿无 dlopen 副作用）
- [x] 引擎就绪时桥接调用返回正确结果；未就绪 / 超时 / 脚本报错均返回可读失败且调用方降级（契约测试通过 + DebugLogger 三类失败路径记录 + 调用点降级分支审查）
- [x] period_aggregate.py 输出与 golden `period_aggregation.json` 一致（周/月/季/年四周期、停牌无桶语义、价格容差 1e-6）（PyBridgePeriodAggregationTests passed，xcresult 实证）
- [x] template_parse.py 输出与 golden `indicator_templates.json` 一致（accepted/rejected 全量 + KIND≠TECH 负控拒载）（PyBridgeTemplateParseTests passed，xcresult 实证）
- [x] WatchlistSyncManager 引擎未就绪时聚合走现有 Swift 路径，产出与现状逐字段一致（无引擎设备数据照常）（降级轮 36 tests / 4 skipped / 0 failures）
- [x] SystemIndicatorStore init/loadAllPeriods 同步路径零改动；后台校准差异以 Python 为准并记录明细（代码审查 + 降级轮全绿）
- [x] 桥接契约测试在无引擎环境 XCTSkip 不 fail（36 tests / 4 skipped / 0 failures，test-without-building 探针实证）；有引擎环境（iPad mini 5 模拟器，内嵌 sim 变体）全绿（36/36）
- [x] 引擎包链路零改动：engine.yml / build.yml / prepare_engine_cache.sh / Engine.app 链路行为不变；CI IPA 不含 PyScripts 之外的 Python 变化（git status：以上文件零改动；Embed 阶段仅跳过分支补 rm -rf 防增量残留，嵌入行为不变）
- [x] 降级事件 DebugLogger 可检索（无引擎 / 超时 / 脚本报错三类均有记录）（代码审查确认三类失败路径均有 DebugLogger 调用）
- [x] `Kline/PyScripts/` 脚本随 App bundle 打包（模拟器构建产物实测含 PyScripts/，Copy PyScripts 构建阶段），引擎来源 embedded / engineApp 切换不影响脚本定位（call 以 Bundle.main 定位，与引擎来源无关）
- [x] numpy 决策已记录于文档（阶段 1 第二批，进入条件 = 试点批验收通过；mobile-forge wheel 链路评估）（可行性分析 §8.1 第 8 条）
- [x] `Python引擎下沉可行性分析.md` 回填试点批结论与后续批次规划（§6.3 试点批完成记录 + §8.1 第 7-9 条）
