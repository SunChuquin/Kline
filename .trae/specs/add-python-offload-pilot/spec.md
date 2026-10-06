# Python 引擎阶段 1 试点批（候选 3 周期聚合 + 候选 1 模板解析下沉）Spec

## Why

阶段 1 进入条件已全部满足：阶段 0 契约测试完成（三份 golden 契约测试在库）；Phase-0 实验全部通过（§7.1，实验 1′/2/3）；体积代价已拍板接受（用户 2026-10-06 决策：阶段 1 内引入 numpy）。且引擎引入本身已超前完成（`embed-python-engine-macos`：双来源宿主 + macOS 构建路径真机/模拟器嵌入）。

本 spec 启动阶段 1 首批功能下沉（试点批）：候选 3（周期聚合）+ 候选 1（指标模板解析），一次打通「生产桥接层 + 业务脚本分发 + 契约测试复用 + 降级矩阵」全链路，为后续批次（候选 4 口径层 / 候选 2 解析层 / numpy）铺路。

**批次规划（决策记录）**：本 spec = 阶段 1 第一批（试点）。第二批 = numpy 引入（mobile-forge wheel 交叉编译与打包链路评估）+ 候选 13，进入条件 = 试点批验收通过；候选 4 / 候选 2 解析层 = 后续批次。

## What Changes

- **新增生产桥接层** `KlinePythonBridge`（`Kline/Python/`，新）：进程内 PyRun + 临时文件 JSON in/out + 串行队列 + 引擎就绪门禁 + 超时/错误→降级失败；复用 `PythonEngineHost` 既有加载与 PyRun 链路（宿主生产级拆分重构不在本批）
- **新增业务脚本分发目录** `Kline/PyScripts/`（新，随 App bundle）：`period_aggregate.py`、`template_parse.py`；业务脚本与引擎包是两个独立版本轴（脚本随 App 版本，引擎包链路零改动）
- **候选 3 下沉（试点）**：周期聚合计算提供 Python 权威实现，生产调用点 `WatchlistSyncManager.currentPeriodBars` 切「Python 优先 + Swift 降级」；`periodDateRange` 桶键规则在 Swift 渲染路径保留零改动
- **候选 1 下沉（试点）**：模板解析提供 Python 权威实现；`SystemIndicatorStore` init 同步路径零改动（Swift 先行，首帧不依赖引擎），加载/重载完成后后台对拍校准（差异以 Python 为准）
- **降级矩阵落地**（试点批两候选范围，§5.3 异常兜底语义）
- **契约测试扩展**：桥接 → Python 实现 vs 既有 golden fixtures；引擎未就绪 XCTSkip
- Python 侧只跑业务脚本；引擎初始化仍只在后台程序化触发，不进首帧、不进启动链

## Impact

- Affected specs: 无既有 spec 需求变更；关联文档 `Python引擎下沉可行性分析.md` §6.3（阶段 1）/ §5.3（降级）/ §4（反向闸）、`Phase-0引擎实验-plan.md`、`.trae/specs/embed-python-engine-macos`
- Affected code:
  - `Kline/Python/KlinePythonBridge.swift`（新）
  - `Kline/PyScripts/period_aggregate.py`、`Kline/PyScripts/template_parse.py`（新）
  - `Kline/Infrastructure/WatchlistSyncManager.swift`（聚合调用点）
  - `Kline/Formula/SystemIndicatorStore.swift`（后台校准）
  - `Kline/Debug/PythonEngineHost.swift`（最小可见性放宽供程序化复用，不改行为）
  - `KlineTests/`（新增桥接契约测试 ×2）

## ADDED Requirements

### Requirement: 生产桥接层
系统 SHALL 提供 `KlinePythonBridge` 单例：
- `ensureReady()`：引擎未加载时在后台队列程序化执行既有 loadEngine 链路（进程内只一次）；已加载立即返回；**绝不从首帧/启动链同步触发引擎初始化**；引擎状态非 `.installed`（未安装/versionMismatch/corrupted）SHALL 不尝试加载
- `call(script:input:timeout:)`：输入 JSON 写临时文件 → 串行队列上进程内 PyRun 执行 `Bundle.main/PyScripts/<script>.py`（脚本读输入文件、写输出 JSON 文件，异常写 error 字段）→ Swift 读回解码
- 引擎未就绪 / 等待超时 / 脚本报错 → 返回失败（含可读原因），调用方降级；降级事件经 DebugLogger 可检索
- `isReady` 查询（不触发初始化）供调用点与降级矩阵使用；GIL 语义沿用 Phase-0 修正（每次调用 PyGILState_Ensure/Release）

#### Scenario: 引擎就绪时调用成功
- **WHEN** 引擎已加载（embedded 或 engineApp 来源均可），`call` 传入 `period_aggregate` 与合法输入
- **THEN** 返回脚本输出 JSON 的解码结果，耗时数字可记录

#### Scenario: 引擎未就绪不阻塞不初始化
- **WHEN** 引擎未加载时 `call` 被调用
- **THEN** 立即返回失败（原因 = 引擎未就绪），不触发 dlopen / Py_Initialize，调用方走降级路径

#### Scenario: 超时降级且队列继续服务
- **WHEN** 串行队列上已有长任务，新 `call` 等待超过 timeout
- **THEN** 该次调用返回超时失败，调用方降级；队列继续处理后续任务，不丢弃不卡死

### Requirement: 业务脚本分发（随 App bundle）
业务 Python 脚本 SHALL 随 App 打包于 `Bundle.main/PyScripts/`，与引擎包（解释器 + stdlib）保持两个独立版本轴；脚本文件名即桥接调用契约。引擎包链路（`engine.yml` / `build.yml` / `prepare_engine_cache.sh` / Engine.app）SHALL 零改动。

#### Scenario: 两种引擎来源均可用脚本
- **WHEN** 引擎来源为 embedded 或 engineApp，桥接调用 `PyScripts` 下脚本
- **THEN** 脚本均从 `Bundle.main/PyScripts/` 定位执行（脚本与引擎来源解耦）

#### Scenario: 引擎包链路零改动
- **WHEN** 试点批合入后构建 CI IPA 与引擎包
- **THEN** `engine.yml` / `build.yml` 产物内容不变（引擎不含业务脚本，IPA 不含引擎）

### Requirement: 候选 3 周期聚合下沉（试点）
周期聚合 SHALL 提供 Python 权威实现 `period_aggregate.py`：桶键规则（周桶键=周一、月桶键=月初、季桶键=季初、年桶键=年初）与「基期 bar ⊕ 新日线」合并口径（open 取周期首行、high/low 极值、close 取末行、vol/amo 累加；整周期停牌 → 无桶不产 bar）对齐契约 golden 权威（`src/tdx_parser.py` / `live_db_builder.aggregate_full_periods`）。生产调用点 `WatchlistSyncManager.currentPeriodBars` SHALL 切为「引擎就绪 → Python 聚合；未就绪/失败/超时 → 现有 Swift `mergePeriodBar` 路径原样执行」。FFI 形状 = 批量数组一次搬运（过 §4 第一道闸）。`KlinePeriod.periodDateRange` 在 Swift 渲染路径（ChartLayoutKit 等）保留零改动。

#### Scenario: 引擎就绪时聚合走 Python 且与 Swift 同值
- **WHEN** 引擎就绪，WatchlistSyncManager 周期合并批次执行
- **THEN** 聚合经 Python 完成，结果与 Swift 降级实现对同一输入逐字段一致（容差同契约测试：价格 1e-6）

#### Scenario: 引擎未就绪时聚合无感降级
- **WHEN** 引擎未加载或 Python 调用失败/超时
- **THEN** 聚合走现有 Swift 路径，周期库数据照常产出，DebugLogger 记录降级事件

### Requirement: 候选 1 模板解析下沉（试点，权威校准模式）
模板解析 SHALL 提供 Python 权威实现 `template_parse.py`（`check_indicators.parse_tdx` 同规则：KIND/NAME/SCOPE/GROUP/COORD/FORMULA，KIND≠TECH 拒载，FORMULA= 单行内联兼容）。`SystemIndicatorStore` SHALL 保持 init / loadAllPeriods 同步路径零改动（Swift 解析先行，首帧不依赖引擎）；在后台加载/重载完成后，若引擎已就绪，SHALL 用 Python 对同批 .tdx 内容重解析对拍：有差异时以 Python 为准更新 defs 并记录差异明细；引擎未就绪 → 跳过校准，Swift 结果持续服务。

#### Scenario: 首帧路径零引擎依赖
- **WHEN** 引擎从未加载，App 启动后图表出现
- **THEN** SystemIndicatorStore 以 Swift 解析正常提供全部模板，无任何引擎初始化被触发

#### Scenario: 引擎就绪时后台校准生效
- **WHEN** 引擎已加载且模板重载发生
- **THEN** Python 重解析同批内容；无差异 → defs 不变；有差异 → 以 Python 为准更新并记录差异明细

### Requirement: 降级矩阵（试点批范围）
系统 SHALL 按下表对试点两候选执行降级（§5.3 异常兜底语义，下载顺序保障使降级仅异常场景出现）：

| 引擎状态 | 候选 3 周期聚合 | 候选 1 模板解析 |
| --- | --- | --- |
| 未安装 / 未加载 | Swift 聚合（现有路径） | Swift 解析（现有路径） |
| versionMismatch | Swift 聚合 | Swift 解析 |
| corrupted | Swift 聚合 | Swift 解析 |
| 已加载但调用失败/超时 | 单次降级 Swift + 记录 | 跳过校准 + 记录 |

降级 SHALL 不产生用户可见功能缺失（周期数据照常产出、模板照常加载），无新增报错弹窗，仅 DebugLogger 记录。

#### Scenario: 无引擎设备全功能无感
- **WHEN** 设备无引擎（CI IPA 且未装 Engine.app）正常使用
- **THEN** 周期库与模板加载行为与现状一致，无新增报错弹窗

### Requirement: 契约测试扩展（桥接链路）
KlineTests SHALL 新增桥接契约测试：经 `KlinePythonBridge` 调用 Python 实现，断言结果与既有 golden fixtures 一致（`period_aggregation.json` / `indicator_templates.json`，含 rejected 与 KIND≠TECH 负控语义）；引擎未就绪时 SHALL XCTSkip（同时验证降级路径），不因无引擎而 fail。

#### Scenario: 模拟器跑通桥接契约
- **WHEN** iPad mini 5 模拟器（内嵌 sim 引擎）执行桥接契约测试
- **THEN** 周期聚合与模板解析结果逐项对齐 golden

#### Scenario: 无引擎环境 skip 而非 fail
- **WHEN** 测试环境无引擎（EngineCache 缺失构建 / KLINE_SKIP_ENGINE_EMBED=1）
- **THEN** 桥接契约测试 XCTSkip，其余测试不受影响

## MODIFIED Requirements

（无既有 spec 需求变更；行为增量均向后兼容，降级路径即现状路径）

## REMOVED Requirements

（无）
