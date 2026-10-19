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

### 1. 新增纯函数 `TrainingAsOfSeries.slice`
放在 [LinkedReplaySupport.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedReplaySupport.swift)（与 `synthesizeBar` 同口径、便于对照）：

```swift
static func slice(rows: [KlineItem], period: KlinePeriod, trainingDate: Int, daily: [KlineItem]) -> [KlineItem]
```
- `rows` / `daily` 均为 **date 降序**（DatabaseManager 查询约定）；
- 裁到 `date <= trainingDate`；
- 非日线周期：取裁剪后最新一根 `last`，`periodDateRange(period, last.date).0` 为该周期起点，用日线 `[起点, 训练日]` 段替换 `last`（date 保持 `last.date`）；
- 区间内无日线 / 无日线数据 → 只裁剪不替换（防御回退）。

### 2. 共享槽加入「训练日」身份
[LinkedTileDataSlot](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedViewStore.swift#L57-L71) 增 `loadedTrainingDate` / `inFlightTrainingDate`；`commitSlot` / `tryBeginFlight` 增 `trainingDate:` 入参并纳入命中判定。
否则：进入训练态时可能命中上一次（非训练）留下的同 (标的,周期) 旧序列，切片永不生效。

### 3. [LinkedKlineTile.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedKlineTile.swift)
- `currentSeries` / `currentLoading` / `tryLoadOnAppear` / `loadData` 的槽位命中判定一并比较训练日；
- `loadData`：训练态下 `period == .daily` 复用本行、否则取该格**自己 metaID** 的日线，调 `TrainingAsOfSeries.slice` 后再建 `ChartSeries`；
- 新增 `.onChange(of: trainingMaxDate)`：作废本格共享槽 → `loadData`（训练日推进/退出训练都要重载）；
- `chartIdentity` 追加训练日：训练日推进时本格序列整体重算，必须让图表实例与计算缓存一起重建，否则指标曲线会沿用旧序列。

### 4. [KlineDetailView.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineDetailView.swift)
- `loadData`：训练态下 5 个周期各自按训练日切片（日线行已在同一次查询里拿到，零额外查询）；
- `queryDrillInSeries`：训练态下补查钻取标的的日线再切片（钻取目标标的可能与主标的相同或不同，各用各的）；
- 新增 `.onChange(of: trainer.trainingDate)`：训练态下重载 series（含钻取序列）；
- `chartView(...)`：训练态 `metaId: nil`（切片序列与库中原序列不同，不能复用 (标的,周期) 指标缓存）；
- `prefetchOtherPeriods`：训练态直接跳过（不把切片后的曲线写进全局缓存，避免被非训练视图恢复）。

## 边界

- 标的日线为空 / 该周期区间内无日线 → 只裁剪（不退化为错数据）。
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
