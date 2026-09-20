# 交易策略公式 · 执行侧实现计划（绑账户 / 生成条件单 / 历史回测）

## Context

上一阶段（`.trae/specs/split-formula-kinds/`）把三类公式分域，交易策略公式落地为「选股条件（PICK）+ 交易规则（RULES）」的定义、解析、校验与预览，**执行侧刻意留空**：[StrategyFormula.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/StrategyFormula.swift#L16-L17) 文件头明确不引用 `SimStore`、不生成条件单，`StrategyPreview.executionNotice`（`:440`）写着「触发后的下单指令（方向 / 数量 / 报价方式）本阶段未定义，留待接入执行阶段」。

本计划补齐执行侧，让策略从「一份可校验的定义」变成「能落到模拟账户上自动执行、并能用历史数据检验的完整策略」：

1. **绑账户**：一个策略可绑**多个**模拟账户，多账户并行执行
2. **生成真实条件单**：把策略的 RULES 变成绑定账户上的真实条件单组合（跑选股 → 命中清单勾选 → 批量生成）
3. **完整历史回测**：日线逐 bar 推进，复用现有费率 / T+1 / 涨跌停口径，输出净值曲线 + 总收益/年化/胜率/最大回撤 + 交易明细

## 现状与可复用能力（已逐行核实）

**策略公式侧（设计侧，已完成）**
- [FormulaKind.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/FormulaKind.swift)：`FormulaDoc`（`:41-48`，`id/kind/name/pickBody/pickRef/rules`）、`FormulaLibraryStore.shared`（`doc(kind:id:)` `:98`、`save` `:129`、`rename` `:153`、`delete` `:173`、`reload` `:188`、`formulaText(id:)` `:103`、`pickerName(id:)` `:109`）；`.tdx` 序列化 `:276-291`、解析 `:294-358`（头部只认 `KIND=`/`NAME=`/`PICKREF=`）
- [StrategyFormula.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/StrategyFormula.swift)：`StrategyRuleKind` 8 类（`:25-33`，与 `SimCondKind` 同名 case 一一对应）、`StrategyRuleCatalog.specs(for:)`（`:104-180`）、`StrategyRuleParser.parse/line`（`:212`/`:277`）、`StrategyValidator.validate`（`:306`）、`StrategyPreview.summary`（`:443`）
- [StrategyFormulaEditorView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/StrategyFormulaEditorView.swift)：`RuleRow`（`:16-20`）、`rulesText`（`:105-110`）、可复用子件（分段 `:250-271`、内嵌编辑器 `:282`、引用列表 `:324`、规则行 `:429`、预览卡 `:561`）
- [FormulaCenterView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/FormulaCenterView.swift)：策略段行仅「编辑/删除」（`:375-414`），子页面用 `.overlay` + `.zIndex(1000)`（`:418-495`）

**条件单与模拟交易侧（执行侧，全部现成）**
- `SimCondOrder`（[SimConditionModels.swift:260-285](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimConditionModels.swift#L260-L285)）、`SimCondDirective`（`:124-133`，`direction/priceType/offsetTicks/qty`）、`SimCondParams`（`:148-192`）
- 校验闸门 `SimCondRule.validateCreate(order:account:position:snapshot:)`（[SimCondRule.swift:223](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimCondRule.swift#L223)）、一句话预览 `previewSentence(_:)`（`:410`）、快照取数 `SimCondSnapshotCenter.snapshot(for:)`（`:438`，走既有 `SimQuoteCenter` / `MarketRowCache`）
- 写入：`SimStore.upsertCondOrder(_:)`（[SimStore.swift:985](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimStore.swift#L985)，单条一次全量落盘）、`cancelCondOrder` `:1000`、`deleteCondOrder` `:1016`、`condOrders(accountID:)` `:962`、`condCounts` `:977`；账户 `account(id:)` `:544`、持仓 `position(accountID:metaID:)` `:921`、`summary(accountID:)` `:1036`
- 下单唯一路径 `SimStore.submit(_ draft:)`（`:650`）+ `SimTradingRules.validate`（[SimTradingRules.swift:138](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimTradingRules.swift#L138)）；费用 `fee(amount:direction:)`（`:83`，佣金 `max(额×0.00025,5)` + 卖出印花税千一）、`limitRange(prevClose:)`（`:106`）、`affordableQty(cash:price:)`（`:114`）、常量 `:61-67`
- 触发引擎 `SimCondEngine.sweepConditions(trigger:)`（[SimCondEngine.swift:51](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimCondEngine.swift#L51)）——**只吃实时快照，不用于回测**
- 管理页五段式模板 [SimCondListView.swift:108-135](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimCondListView.swift#L108-L135)、进度条 `SimCondProgressBar`（[SimCondKit.swift:61-90](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimCondKit.swift#L61-L90)）

**行情与公式求值侧**
- `DatabaseManager.fetchBars(metaId:period:)`（[DatabaseManager.swift:172](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/DatabaseManager.swift#L172)，**date DESC**）、`fetchPeriodLimited(metaId:table:limit:)`（`:221`，`table` = `KlinePeriod.folderName` 如 `daily`）、`metaList`（`:23`）；**无截面 / 交易日历 API**
- `KlineItem`（[KlineData.swift:33-42](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/KlineData.swift#L33-L42)，`date` 为 Int YYYYMMDD，无复权/停牌标记）；`MetaItem`（`:9-31`，`code/name/type/firstDate/lastDate`）
- `TDXFormulaEngine.evaluate(formula:data:)`（[FormulaEngine.swift:1562](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/FormulaEngine.swift#L1562)）、`evaluateIncremental(...barCount...)`（`:1582`，`TDXSharedSeries` `:414`、`TDXIncrementalState` `:431`）、`TDXOutputLine.values`（`:379-394`）
- 既有 as-of 范式：`lowerBoundSorted`（[LinkedReplaySupport.swift:304-312](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Chart/LinkedReplaySupport.swift#L304-L312)）、`lastIndexNotAfter`（`:315-324`）、`evaluateAsOf`（`:176-209`）
- 全市场跑公式既有范式：`FavoritesStore.refreshFormulaGroup`（[FavoritesStore.swift:385-455](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift#L385-L455)，`computeQueue.asyncAfter` 错峰 + `DispatchGroup` + `NSLock`）；`MarketRowCache` 为 `@MainActor` + `computeQueue`（[MarketRowCache.swift:16-32](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketRowCache.swift#L16-L32)）

## 设计

### 1. 策略文件格式扩展（向后兼容）

```
KIND=STRATEGY
NAME=均线止损策略
TRADE:
DIRECTION=BUY                默认 BUY（BUY / SELL）
QTY=500                      与 AMOUNT 二选一，QTY 优先
AMOUNT=50000                 按生成时最新价换算并向下取整到 100 股
PRICETYPE=MARKET             默认 MARKET（MARKET / LIMIT）
OFFSETTICKS=2                仅 LIMIT 有效
VALIDITY=LONG                默认 LONG（DAY / LONG / DATE）
EXPIRES=2026-12-31           仅 DATE 需要
ACCOUNTS=<uuidA>,<uuidB>     英文逗号分隔，顺序即执行顺序；用 UUID 全串（改账户名不失效）
PICK:
...
RULES:
STOP_LOSS(BASE=COST, MODE=PCT, PROFIT=10, ORDDIR=SELL, ORDQTY=300)
```

**逐规则指令覆盖键必须用 `ORD` 前缀**：`ORDDIR` / `ORDQTY` / `ORDAMT` / `ORDPT` / `ORDOFF`。
> 原因（重要）：`DIR` 已被 `MA_CROSS` 占用（UP/DOWN）、`QTY` 已被 `GRID` 占用，直接复用会与规则参数撞名并污染 `knownKeys` 校验。`ORD*` 键不进 `StrategyRuleCatalog.specs`，解析器先摘出这些键再按 `knownKeys` 校验其余参数；序列化时追加在规则体末尾。
> 优先级：**规则行内 > TRADE 段 > 内置默认**。

**改动点**
- 新文件 `Kline/Formula/StrategyTrade.swift`：
```swift
struct StrategyTradeSpec: Equatable {
    var direction: SimOrderDirection?      // 只借用 SimModels 的枚举，不依赖 SimStore
    var qty: Int?; var amount: Double?
    var priceType: SimPriceType?; var offsetTicks: Int?
    var validity: SimCondValidity?; var expiresAt: Date?
    var accountIDs: [UUID] = []
}
struct StrategyDirectiveOverride { var dir: SimOrderDirection?; var qty: Int?; var amount: Double?
                                    var priceType: SimPriceType?; var offsetTicks: Int? }
enum StrategyTradeParser {
    static func parse(lines: [String]) -> (spec: StrategyTradeSpec, errors: [String])
    static func serialize(_ spec: StrategyTradeSpec) -> String
    static func override(in call: StrategyRuleCall) -> StrategyDirectiveOverride
    static func stripOverrides(_ line: String) -> String   // 供解析器摘键
}
```
- `FormulaDoc` 增 `var trade: StrategyTradeSpec = StrategyTradeSpec()`；`FormulaLibraryStore.serialize/parse` 增 `TRADE:` 段（`inTrade` 分支；头部仍只认 `KIND=`/`NAME=`/`PICKREF=`）
- `StrategyValidator.validate` 增 TRADE 校验：QTY/AMOUNT 互斥、整手、`LIMIT` 需 `OFFSETTICKS`、`DATE` 需 `EXPIRES`、`ACCOUNTS` 为空只告警不阻断
- `StrategyPreview` 增 `tradeSummary(doc:)`，并把私有 `triggerText(_:)` 提升为 internal 供详情页复用
- [StrategyFormulaEditorView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/StrategyFormulaEditorView.swift) 增「交易指令」区块（方向分段 / 数量或金额 / 报价方式 / 有效期）与「绑定账户」多选列表
- **向后兼容**：无 `TRADE:` 段的旧文件 → `trade` 全 nil、`accountIDs` 空，编辑/校验/预览行为与现状完全一致，仅「生成条件单」按钮禁用并提示「请先配置交易指令与绑定账户」

### 2. RULES → 条件单生成器（新文件 `Kline/Trading/StrategyCondGenerator.swift`，纯函数、不写盘）

```swift
struct StrategyCondDraft { var metaID: Int; var code: String; var name: String
    var kind: SimCondKind; var params: SimCondParams
    var directive: SimCondDirective; var validity: SimCondValidity; var expiresAt: Date? }
enum StrategyCondGenerator {
    static func directive(rule: StrategyRuleCall, trade: StrategyTradeSpec, lastPrice: Double) -> SimCondDirective
    static func drafts(doc: FormulaDoc, meta: MetaItem, lastPrice: Double,
                       costPrice: Double?) -> (drafts: [StrategyCondDraft], errors: [String])
}
```

| 规则 | 参数映射（键 → `SimCondParams` 字段） | 默认方向 | 兜底 / 拒绝 |
|---|---|---|---|
| `PRICE` | `OP`(`>=`→`compareUp=true`) → `triggerPrice` | 覆盖 / TRADE | 缺 `VALUE` 报错跳过 |
| `STOP_LOSS` | `MODE=PCT`→`baseMode=.percent` 且 `PROFIT/LOSS` 按 `basePrice` 换算 `takeProfitPrice/stopLossPrice`；`BASE=COST/LAST`→成本价/最新价 | 覆盖 / `sell` | 无持仓（`costPrice == nil`）→ 报「卖出规则需先有持仓」 |
| `TRAILING` | `PCT`→`trailPct`、`FLOOR`→`floorPrice`+`floorEnabled=true`、`breakoutPrice`=最新价 | 覆盖 / `sell` | — |
| `TIME` | `DATE`+`AT`（无 `AT` 取 09:30）→`fireDate` | 覆盖 | 日期解析失败报错跳过 |
| `CHANGE_PCT` | `PCT`（`OP='<='` 取负）→`changeThreshold` | 覆盖 | — |
| `MA_CROSS` | `PERIOD`→`maPeriod`、`DIR`(UP/DOWN)→`maAbove` | 覆盖 | — |
| `GRID` | `BASE/LOW/HIGH/STEP/QTY/MULT` → `gridBase/gridLower/gridUpper/gridStepPct/gridQtyPerLevel/gridMultiplier` | 双向自带 | — |
| `BATCH` | `TOTAL/COUNT/FIRST/GAP` → `batchTotalQty/batchCount/batchFirstPrice/batchStepPct` | 覆盖 | — |

`SimCondDirective` 装配：`qty` = `ORDQTY` ?: `ORDAMT` 折算 ?: TRADE.QTY ?: `AMOUNT/最新价` 取整手（网格走 `params.gridQtyPerLevel`）；`priceType` = `ORDPT` ?: TRADE.PRICETYPE ?: `.market`；`offsetTicks` = `ORDOFF` ?: TRADE.OFFSETTICKS ?: 0。

> 实现补充（与本节一致，落地后回填）：① 回测逐日循环顺序为「T+1 释放 → 执行待成交动作 → 持仓规则 → 入场信号 → 收盘估值」，释放必须早于成交执行，否则 D 日买入、D+1 开盘的卖出单会被 T+1 误拒并丢弃；② 回测运行器只保留**有命中**标的的 bars（未命中立即释放，控制内存），`scannedCount` 由运行器回填为实际扫描只数；③ 被取消时引擎中断逐日循环、保留已模拟部分的指标并在提示里说明。

**入场单**：命中清单本身就是「今天已命中」，再生成 `PRICE/TIME` 入场单只会延后成交 → **默认只生成离场/管理类规则的条件单**；`TRADE.DIRECTION=BUY` 时在确认页提供可选开关「同时生成入场单（PRICE ≥ 最新价按 TRADE 报价方式）」，默认关闭并附口径说明。

**校验 / 去重 / 上限**：逐条构造 `SimCondOrder` 后走 `SimCondRule.validateCreate`（`account` 取 `SimStore.account(id:)`、`position` 取 `SimStore.position(accountID:metaID:)`、`snapshot` 取 `SimCondSnapshotCenter.snapshot(for:)`）；被拒则收 `SimCondRejection.message` 进结果清单。去重：`condOrders(accountID:)` 中同 `metaID` + 同 `kind` 且 `status == .monitoring` → 计入「已存在」跳过。上限：单次运行最多生成 200 条、单账户监控总数 ≤ 1000，超限截断并提示。

**批量写盘**：`SimStore` 新增 `@discardableResult func upsertCondOrders(_ orders: [SimCondOrder]) -> Int` —— 合并入数组后 `assignConditionalOrders` 一次 + `saveToDisk()` 一次 + 汇总 1 条 `ActionLog`。**不要循环调 `upsertCondOrder`**（每条一次全量 JSON 落盘）。

### 3. 跑选股（新文件 `Kline/Formula/StrategyPickRunner.swift`）

复用 `MarketRowCache.computeQueue` + `matchFormula` 的命中语义（最后一条输出行末值 > 0）与 `refreshFormulaGroup` 的错峰范式，但不复用它本身（它绑 `cachedMatches` 持久化且只答布尔）。

```swift
@MainActor final class StrategyPickRunner: ObservableObject {
    enum Phase { case idle, running(done: Int, total: Int), finished, cancelled }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hits: [StrategyPickHit] = []
    func start(doc: FormulaDoc, pool: StrategyPickPool)
    func cancel()
}
struct StrategyPickHit: Identifiable { var id: Int { metaID }
    var metaID: Int; var code: String; var name: String; var lastPrice: Double?; var changePct: Double? }
enum StrategyPickPool: Hashable { case market, favorites }
```
候选池：`DatabaseManager.shared.metaList`（全市场）或 `FavoritesStore.resolveMetaItems(groupID:allMeta:)`（自选）。启动前先 `cache.rows(for:)` 批量注册 + prefetch，未就绪做一轮补试；取消用 `NSLock` 保护的标志位。

### 4. 完整回测（新目录 `Kline/Backtest/`）

新文件：`StrategyBacktestModels.swift`、`StrategyBacktestEngine.swift`、`BacktestParamView.swift`、`BacktestResultView.swift`、`NetValueChartView.swift`。

- **交易日历**：候选池各标的 `bars.date` 的**并集**升序（无截面 API，且基准标的会因停牌丢日期）。区间上限 500 交易日（可选 60/120/250/500）。
- **选股 as-of**：对每只标的**一次**推进全序列（`evaluate` 或 `evaluateIncremental(barCount:)`），第 i 根输出值即「截至第 i 根」的 as-of 值 —— 等价于逐 bar 截断重算，但省掉「逐日 × 全市场」的重算。内存不驻留：逐只推进、只保留命中日期集合，判完立即释放（1K 只 × 2400 根 × 6 序列 ≈ 115MB，不可全市场驻留）。
- **未来函数**：`REF(X,-n)` / `BACKSET` / `ZIG` 会让 `values[i]` 用到 i 之后的数据，结果偏乐观 → 在回测侧静态扫描（不动 `FormulaEngine`）+ 结果页固定警示，不阻断。
- **信号与成交时点**：第 i 根收盘判定信号 → **第 i+1 根开盘价成交**（默认，可切「当日收盘成交」对照）。
- **逐 bar 规则判定**：

| 规则 | bar 内触达 | 成交价 |
|---|---|---|
| `PRICE` | 买入 `high >= trigger`；卖出 `low <= trigger` | `clamp(trigger, [low, high])`，跳空时用 `open`（买单高开、卖单低开均偏保守，无乐观偏差） |
| `STOP_LOSS` | 同 `PRICE`；止损腿优先于止盈腿（与引擎同序） | 同上 |
| `STOP_LOSS(PCT)` | 基准 = 成本价，触达价 = `cost × (1 ± pct)` | 同上 |
| `TRAILING` | 先 `high` 推进极值，再 `low/close` 判回撤 ≥ `PCT`；`FLOOR` 下 `low <= floor` 直接触发 | 触达价 |
| `TIME` | `bar.date >= fireDate` | 该 bar 开盘价（关闭「次日开盘成交」时取收盘价） |
| `CHANGE_PCT` | `(close_i - close_{i-1}) / close_{i-1}` 满足阈值 | 次根开盘 |
| `MA_CROSS` | 自算 `PERIOD` 均线（用回测自身 close），bar 对 bar 判定 | 触达价 |
| `GRID` / `BATCH` | 每持仓维护 `gridLevel/gridLastPrice/batchDone`，逐 bar 推进；`GRID` 用 `low` 判下移一档买入、`high` 判上移一档卖出，bar 内可多档（上限 `SimCondRule.gridLevelCount`） | 该档目标价 |

- **不可成交 / 异常**：成交价触涨停（买入）/ 跌停（卖出）→ 不成交（复用 `SimTradingRules.limitRange`）；T+1 当日买入不加可卖、次 bar 起释放；当日无 bar → 不成交、估值沿用上一根 close；资金不足 → 按 `affordableQty` 缩量（默认）或整笔跳过。
- **账本**：`BacktestLedger { cash; positions: [Int: BacktestPosition]; realizedPnL; equityCurve: [(date: Int, equity: Double)] }`；费用复用 `SimTradingRules.default.fee(amount:direction:)`，不复制口径；明细 `BacktestTrade { date, metaID, code, name, ruleKind, direction, qty, price, amount, fee, realizedPnL?, holdDays? }`（卖出按加权成本价结算）。
- **指标**：总收益、年化（`pow(1+total, 252/n) - 1`）、胜率、盈亏比、最大回撤、交易次数、平均持仓天数。
- **净值曲线手绘**（iOS 15 无 Charts）：`GeometryReader` + 归一化 `x/y` + `Path.addLine`，叠加最大回撤区间半透明矩形与 min/max/首尾标注；入参用 `Equatable` 值类型避免重绘。
- **性能与进度**：三段式 —— ① 取数逐只 `fetchPeriodLimited(metaId:table:period.folderName,limit:区间+60)`（**禁用全量 `fetchBars`**）；② 选股 as-of 走 `computeQueue` 错峰；③ 逐 bar 回测只对命中池在后台推进；引擎标 `nonisolated`、输入输出全值类型；进度 `(phase, done, total)` 回调，取消按标的边界检查标志位。

### 5. 页面与入口

- [FormulaCenterView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/FormulaCenterView.swift) 策略段行（`:375-414`）加「详情」按钮（44pt），用既有 `.overlay` + `.zIndex(1000)` 呈现 `StrategyDetailView`
- `StrategyDetailView`（新）：页头（返回 / 名称 / 编辑）+ ① 选股条件摘要卡（`StrategyPreview.pickSummary`）② 交易指令卡（`tradeSummary` + 绑定账户前 3 个与「+N」，失效账户橙字提示）③ 规则清单卡（逐条 `triggerText`）④ 三个动作「跑选股」「生成条件单」「回测」+ 进度（`SimCondProgressBar`）
- 「跑选股」→ 页内 `StrategyPickListView`（池分段 全市场/自选、进度、逐行勾选默认全选）
- 「生成条件单」→ `StrategyGenConfirmView`（逐账户分组预览 `SimCondRule.previewSentence`、被拒/已存在/超限明细、确认后 toast 汇总）
- 「回测」→ `BacktestParamView`（区间 / 初始资金默认取绑定账户 `initialCapital` / 候选池 / 成交口径）→ `BacktestResultView`（指标卡 + 净值折线 + 明细，前 50 条 + 展开）
- 模拟页**不加新入口**（既有「策略公式」入口已直达策略段）

## 分阶段与 Critical Files

### 阶段一：TRADE 段 + 多账户绑定 + 策略详情页
- 新增：`Kline/Formula/StrategyTrade.swift`、`Kline/Formula/StrategyDetailView.swift`
- 修改：`FormulaKind.swift`、`StrategyFormula.swift`、`StrategyFormulaEditorView.swift`、`FormulaCenterView.swift`
- 验收：旧 `.tdx` 打开无副作用；保存重开字段一致；失效账户被跳过并提示；`QTY`/`AMOUNT` 冲突、`LIMIT` 缺 `OFFSETTICKS`、`DATE` 缺 `EXPIRES` 被拦；`ORD*` 覆盖键可解析且不污染规则参数校验

### 阶段二：跑选股 + 生成条件单
- 新增：`Kline/Formula/StrategyPickRunner.swift`、`Kline/Formula/StrategyPickListView.swift`、`Kline/Trading/StrategyCondGenerator.swift`、`Kline/Simulation/StrategyGenConfirmView.swift`
- 修改：`SimStore.swift`（`upsertCondOrders` 批量接口）、`StrategyDetailView.swift`
- 验收：全市场跑完 UI 不卡且有进度与取消；默认全选可取消；重复生成第二次全部计「已存在」；无持仓账户的卖出规则被拒并列出原因；**整轮只落盘一次**；生成后条件单页可见且摘要与策略预览一致

### 阶段三：完整回测
- 新增：`Kline/Backtest/StrategyBacktestModels.swift`、`StrategyBacktestEngine.swift`、`BacktestParamView.swift`、`BacktestResultView.swift`、`NetValueChartView.swift`
- 修改：`StrategyDetailView.swift`（回测入口）、必要时 `DatabaseManager.swift`（取数封装）
- 验收：同参数两次结果一致；净值末值 == 初始资金 + Σ已实现盈亏 + 浮盈；构造涨停买入被拒用例；250 日 × 50 只命中池耗时可接受；取消可中断；明细与净值曲线数据自洽

**Task Dependencies**：阶段一的 `StrategyTradeSpec` / `tradeSummary` 是阶段二生成器与阶段三回测参数的**硬依赖**；阶段一的详情页是阶段二/三的共同宿主，必须先落地；阶段三的候选池可复用阶段二的命中结果（软依赖，缺省退化为全市场）；阶段二与阶段三之间无依赖，可并行或调序。

## 边界与取舍（明确承认，不藏）

1. **前视偏差**：默认次日开盘成交已消除主要偏差；`TRAILING` 的「bar 内先 high 后 low」仍是乐观假设，写进结果页脚注，并提供「当日收盘成交」开关做对照
2. **未来函数**：`REF` 负偏移 / `BACKSET` / `ZIG` 污染 as-of 序列（偏乐观）→ 静态扫描 + 固定警示，不阻断
3. **数据缺失**：`KlineItem` 无复权与停牌标记，除权日会产生假暴跌并误触发卖点 → 默认限近期区间，明细中标注单日跳空 > 11% 为可疑
4. **性能**：全市场 × 数百天不可行 → 两段收缩（先缩池再回测）+ `fetchPeriodLimited` + 只推进命中池 + `computeQueue` 错峰 + 可取消 + 区间上限 500 日
5. **写盘次数**：逐条 `upsertCondOrder` 不可接受 → 新增批量接口一次落盘，单次上限 200 条
6. **条件单语义 ≠ 回测语义**：引擎只吃实时快照（两次评估之间的价格路径不可见），回测吃逐 bar high/low → 实盘触发必然晚于回测，在生成确认页与回测结果页各写口径说明
7. **涨跌停简化为 ±10%**：ST（5%）/ 科创创业板（20%）不准确 → 常量已集中在 `SimTradingRules.limitPct`，后续可按 `MetaItem.type` 分档

## 验证方式（真机闭环）

1. 每阶段结束执行 Windows 闭环：`python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<阶段描述>"`（退出码 0/6/7 均可交付），提交信息用 `feat(strategy): ...` / `fix(strategy): ...`
2. 真机路径：
   - 阶段一：个人中心 → 公式管理 → 交易策略段 → 详情 → 填交易指令 + 勾 1 个账户 → 保存 → 重开文件核对（含用文件 App 打开沙盒 `Documents/formula/strategy/STR_*.tdx` 看 `TRADE:` 段）
   - 阶段二：详情 → 跑选股（全市场）→ 勾选 3 只 → 生成条件单 → 去条件单页确认 3 只 × 规则数条；再生成一次应全部「已存在」
   - 阶段三：详情 → 回测（250 日 / 沪深主板）→ 核对指标卡与明细；再跑一次同参数结果须一致；切「当日收盘成交」对比差异
3. 回归点：K 线页指标面板不受影响；自选「刷新选股」不受影响；条件单引擎自动触发仍正常工作

## Critical Files

- [FormulaKind.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/FormulaKind.swift)（`FormulaDoc` 增 `trade`，序列化/解析加 `TRADE:` 段）
- [StrategyFormula.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/StrategyFormula.swift)（校验加 TRADE 项，`triggerText` 提为 internal，新增 tradeSummary）
- [StrategyFormulaEditorView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/StrategyFormulaEditorView.swift)（交易指令区块 + 账户多选）
- [FormulaCenterView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/FormulaCenterView.swift)（策略段「详情」入口）
- [SimStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimStore.swift)（批量 `upsertCondOrders`）
- [SimCondRule.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimCondRule.swift)（生成时复用 `validateCreate` / `previewSentence` / 快照）
- 新增：[StrategyTrade.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/StrategyTrade.swift)、[StrategyDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/StrategyDetailView.swift)、`StrategyPickRunner.swift`、`StrategyCondGenerator.swift`、`Kline/Backtest/*`