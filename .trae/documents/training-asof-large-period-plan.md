# 训练态多图/单图：大周期「形成中K线」时点切片

## Context（问题）

用户要求：**训练模式下（多图 + 单图），不论有无开启联动，大周期（周/月/季/年）视图都应像非训练态多图联动复盘那样，准确显示「截至训练日」的大周期K线形态。**

现状根因（已用仓库 `tdx.db` 实证）：

- KlineChartView 的训练态只把**右缘**钳到 `trainingEndIndex`（[KlineChartView.swift:351-370](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineChartView.swift#L351-L370)），数据本身仍取库里那张周期表；
- 库里的大周期 K 线是**整周期聚合**的（例：周线 `20260810` 一根已含 0810~0814 全周开高低收）；
- 于是训练日停在周中/月中时，右缘那根显示的是「整周/整月」的完整形状——**含训练日之后的数据**，且训练日推进时它也不变形（库里那根是固定的）；
- 非训练态多图联动复盘之所以"准"，是因为走 [LinkedReplaySupport.synthesizeBar](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedReplaySupport.swift#L299-L322)：用来源周期数据从大周期起点聚合到光标日，实时合成「形成中K线」。

## 需求对齐结论（用户确认）

1. 口径：**用本标的日线**，从该大周期起点聚合到训练日（开=区间首根日线开、收=训练日收、高低=包络、量额累加）；date 沿用原周期 bar 的 date（= 周期首个交易日）。
2. 范围：训练态**多图 + 单图**都套用；多图里各格可能显示**其它标的**，必须用**该格自己的标的**日线聚合（不能串标的）。
3. 指标：K 线与指标**一起 as-of**（整条序列按「≤训练日 + 右缘那根合成」喂给图表，蜡烛/量柱/曲线/数值栏自然一致）。

## 现有代码（关键入口）

| 位置 | 作用 |
| --- | --- |
| [LinkedReplaySupport.swift:299-322](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedReplaySupport.swift#L299-L322) | 联动复盘的单根合成口径（本次复用同口径） |
| [KlineData.swift:135-170](file:///Volumes/home/repositories/Kline2/Kline/Data/KlineData.swift#L135-L170) | `KlinePeriod.periodDateRange`：周期覆盖区间 |
| [LinkedKlineTile.swift:187-275](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedKlineTile.swift#L187-L275) | 单格视图数据加载（`fetchBars` → `ChartSeries`）+ 共享槽 |
| [LinkedViewStore.swift:57-71,128-170](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedViewStore.swift#L57-L71) | tile 共享数据槽：命中判定只看 (metaID, period) |
| [KlineDetailView.swift:1350-1381](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineDetailView.swift#L1350-L1381) | 单图数据加载（一次取 5 个周期，日线已在手） |
| [KlineDetailView.swift:1432-1447](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineDetailView.swift#L1432-L1447) | 钻取单图数据加载 |
| [IndicatorPipeline.swift:68-85](file:///Volumes/home/repositories/Kline2/Kline/Chart/IndicatorPipeline.swift#L68-L85) | `metaId != nil` 才会从 (标的,周期) 缓存恢复曲线 |

## 分步实现

### 1. 新增纯函数 `TrainingAsOfSeries.formingBar`
放在 [LinkedReplaySupport.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedReplaySupport.swift)（与 `synthesizeBar` 同口径、便于对照）：

```swift
static func formingBar(targetDate: Int, period: KlinePeriod, trainingDate: Int, daily: [KlineItem]) -> KlineItem?
```
- `daily` 为**该标的自己的**日线，**date 升序**（与 `LinkSourceBarCache` 同约定），二分定位 `[周期起点, 训练日]` 段；
- 产出一根合成 K 线（date 沿用 `targetDate`）；日线不可用 / 区间内无日线 → nil（回退真实 K 线）。

### 2. 图表内「单点合成」派生（不重载任何数据）
[LinkedReplaySupport.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedReplaySupport.swift) 的 `extension KlineChartView` 新增：
- `trainingFormingIndex`（= 右缘上界，`trainingEndIndex`）、`trainingFormingBar`（训练日落在该 K 线覆盖区间内才合成；日线取自 `linkedMetaID ?? metaId`，**各格各标的互不借用**）；
- `ensureTrainingSourceBars()`（请求本标的日线，命中/在途零开销；到达后由 `linkSourceCache.revision` 驱动重绘）；
- `asOfCanvasIndex`（画布合成点：复盘光标优先 → 训练态形成中K线）、`asOfLegendIndex`（图例/读数行读数点）、`trainingAsOfTrigger`、`effectiveAsOfTrigger`（`asOfTrigger ?? trainingAsOfTrigger`）。

### 3. 各绘制点接入合成点
- [ChartLayoutKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/ChartLayoutKit.swift)：`mainCanvas` 的 `syntheticBar`、`subChart` 的 `synthStick`、主/副图曲线 `mainCurveValues` / `subCurveValues` 的 as-of 单点替换（复盘优先 → 训练态）；
- [KlineChartView.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineChartView.swift)：`priceRange` 用 `displayRangeSlice`（右缘那根换成合成形态，避免把训练日之后的极值算进 y 轴）、`mirroredLatest` 取合成K线收盘；onAppear 增 `ensureTrainingSourceBars()`；`scheduleAsOf(effectiveAsOfTrigger)`、`.onChange(of: effectiveAsOfTrigger)`；`trainingMaxDate` 的 onChange 只做「右缘跟进 + 确保日线已请求」；
- [ChartLegendKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/ChartLegendKit.swift)：`subVolAmoOverride` 增训练态分支（形成中K线正好是图例在读那根时，VOL/AMO 柱读合成量/额）；
- [ChartCursorKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/ChartCursorKit.swift)：`drawnMainCandleExtent` 的合成K线判定增训练态分支；`cursorDisplayItem(at:)` 同步（行情数据行读数）。

### 4. `trainingStartDate` / `trainingSignalMarks` 不变
起始日竖轴与 B/S/T 标记仍按周期聚合绘制，与本次改动无关。

## 变更记录（2026-10-19 同日修订）

**初版（已废弃）**：按训练日把序列「裁到训练日 + 合成右缘那根」再喂给图表。方向正确但**引入整屏闪烁**：
每推进一个训练日都要 ① 重查库、② 把 tile 置为加载占位（`chartSeries = nil; isLoading = true` → 白屏转圈）、
③ `chartIdentity` 含训练日 → 图表实例被销毁重建（指标缓存清零、曲线等引擎回包）。

**现版**：训练日推进退化为「窗口右移一根」——与非训练态手拖主图**完全同一条廉价路径**；
右缘那根的"形成中"形态由 `SyntheticBar` 单点替换 + as-of 单点重算跟随，全程不重载数据、不重建视图。
（该机制本就在联动复盘里跑通，复用即可。）

**已知边界（与联动复盘同口径，非本次引入）**：
- 合成K线为单点替换，y 轴范围已按合成形态修正（`displayRangeSlice`），但副图 VOL/AMO 的量轴仍按库内曲线取值（影响极小：泄漏值≈一根完整周期量，与其他周期同量级）；
- VOL/AMO 的均量线（MA）在该点不走来 as-of 通道（与复盘一致），主图/其他副图指标均按训练日 as-of 重算。

**二次修订（2026-10-19）**：训练态多图 + 联动下，点击小周期主图触发光标时，被联动的大周期会"先闪一根库内完整大周期K线（含训练日之后数据），过一会才变成训练日聚合"。
根因：`trainingFormingBar` 的日线源走 `LinkSourceBarCache` 异步查询，首帧未就绪 → 单点合成返回 nil → 该帧只能画库内那根完整 K 线。
修复：新增 [TrainingSessionController.dailyBars(for:)](file:///Volumes/home/repositories/Kline2/Kline/Training/TrainingSessionController.swift#L103-L114)
（会话启动时已把该标的全量日线常驻内存，**同步可读**），`trainingFormingBar` **优先取它**，非训练标的才回退异步缓存 →
首帧即可合成，空窗消失。（`LinkSourceBarCache` 仍保留并预请求，兼顾多图里显示其它标的的情形。）

## 边界

- 标的日线为空 / 该周期区间内无日线 → 该根回退显示库内真实 K 线（不合成错数据）。
- 训练日不是交易日：训练日本身由控制器锚定到实际交易日（`TrainingSessionController`），不会出现。
- 训练日之前无该周期 K 线 → 序列为空，走既有空态。
- 与联动复盘叠加（训练 + 开联动 + 放光标）：光标那根仍由 `synthesizeBar` 合成，光标日期 ≤ 训练日，不会引入训练日之后的数据；合成结果与切片结果一致时无害。
- 非训练态：`trainingMaxDate == nil` → 以上全部走零开销分支，行为与改动前完全一致。

## 验收清单

1. 训练态单图切到周/月/季/年线：右缘那根 =「截至训练日」的合成形状；推进训练日，它随之变形（周内推进不再冻结）。
2. 训练态多图（2/3/4 格，含周/月线）：每格大周期同样正确；**关闭联动**时同样正确；某格显示另一标的时，用该标的自己的日线聚合，不与主标的串数据。
3. 训练态开联动 + 放光标：复盘合成照常，两套口径不冲突。
4. 非训练态单图/多图（含联动复盘）行为与改动前完全一致（回归点）。
5. 切周期、切标的、重置视图、钻取单图、数据热刷新（dataVersion）均正常。

## Critical Files

- `.trae/`：本计划
- [LinkedReplaySupport.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedReplaySupport.swift)（新增 `TrainingAsOfSeries`）
- [LinkedViewStore.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedViewStore.swift)（槽位训练日身份）
- [LinkedKlineTile.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedKlineTile.swift)（切片加载 + 训练日重载 + 图表身份）
- [KlineDetailView.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineDetailView.swift)（单图/钻取切片 + 重载 + 禁止缓存复用）
