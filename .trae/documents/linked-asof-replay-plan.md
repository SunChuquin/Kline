# 联动模式：大周期/同周期视图的「历史时点复盘」（合成 K 线 + 未来淡化 + 指标 as-of 重算）

> 状态：**设计已与用户确认，待实施**。用户手册（`Kline/Kline-联动多图光标联动说明.md` 第 6.1 节）已按本设计更新；实施完成前安装版本仅为"十字光标 + 收盘价横线"形态。
>
> 创建：2026-09-14。

## 1. Context（背景与目标）

联动多图 + 光标联动（`dualLink && cursorLinkEnabled`）下，被联动视图按目标周期与来源周期的大小关系分两种画面：

- **目标周期 < 来源周期**：已有「双竖轴范围框」（`linkRangeIndices` / `linkRangeAxisOverlay` / `centerLinkRange`），用户满意，**本次不动**；
- **目标周期 ≥ 来源周期**：目前只有一根十字光标（竖线定位最近日期 K 线 + 2026-09-14 已改为收盘价横线）。用户认为表达不足。

目标：后一类视图升级为「**历史时点复盘（As-of Replay）**」——十字光标声明一个历史截止时点 D（= 来源光标 K 线日期），被联动视图回答"假如时间停在 D，本周期图当时什么样"：

1. 光标所在的本周期 K 线（记索引 `i`）显示为**合成 K 线**：用**本视图自己标的**的来源周期数据，从该大周期自身起始边界到 D 之间聚合（开=首根开、收=末根收、高/低=包络、量/额=累加），随来源光标在大周期内移动实时变形；
2. `i+1 … 最后一根` 的全部图形元素**统一淡化到 1/3 透明度**（"未来区域"）；
3. 索引 `i` 的主图/副图指标值按合成 K 线 **as-of 重算**；历史段（< i）不动，未来段（> i）数值与线条保持数据库原样；
4. 光标以任何方式消失 → 合成/淡化/重算全部撤销，恢复数据库真实形态（纯渲染派生，零落地状态）。

## 2. 已确认的决策（2026-09-14，用户拍板，勿再变更）

| # | 决策点 | 结论 |
| --- | --- | --- |
| D1 | 淡化覆盖范围 | **全部元素统一 1/3**：主图蜡烛（四种样式）、VOL/AMO 柱、主图与全部副图指标曲线、最新价虚线等参考线；只改 alpha，不改数值 |
| D2 | 同周期目标（日→日等，含跨标的） | **也淡化**光标之后的 K 线；但不合成（光标那根本就是真实 K 线） |
| D3 | 跨标的 | **也淡化、也合成**，但各视图用**自己标的**的来源周期数据合成（B 的月线用 B 的周线，绝不借 A 的数据） |
| D4 | 拖动时指标重算策略 | **后台异步重算 + 缓存**：合成 K 线图形实时跟手；指标点允许极短暂显示上一次结果，算出后刷新 |

补充确认（用户原始描述已覆盖）：

- 合成聚合起点 = **目标大周期自身的起始边界**（`KlinePeriod.periodDateRange(targetPeriod, dateOfI).0` 在来源序列中的下界），不是光标当天；季中/年中触发时必须纳入此前已走完的来源 K 线；
- 横线价格 = 合成 K 线收盘价 = D 所指来源 K 线收盘价（同标的时与来源视图手指处一致；跨标的时是 B 自己数据的末根收盘价）；
- 光标在库最新一根时：无未来区域、合成值与库中未完结大 K 线一致，自然退化为现状，无需特判；
- 周线归属月按"起始交易日所在月"（跨月周整周计入一侧），这是以周线为最小信息单元的固有近似，用户知情接受。

## 3. 现状代码基础（复用，不重写）

- `KlineDetailView.swift`
  - `DualLinkSync`（约 111-122 行）：`cursorDate: Int?`（已广播）、`sourcePeriod: KlinePeriod`（已广播，普通 var）、`sourceRange`（范围框用）。**本设计无需新增字段**：合成所需的 (D, 来源周期) 已齐，标的各视图自取。
  - `lastCursorFromRightUser` 为遗留死字段（已标注），不使用。
- `KlineChartView.swift`
  - `renderCursorIndex`（约 981 行）：联动接收态由 `linkSync.cursorDate` 经 `nearestIndex(to:)` 派生 → 即本设计的 `i`。
  - `linkedCursorClose`（约 995 行，2026-09-14 新增）：联动态收盘价派生，合成接入后改读合成 K 线收盘。
  - `applyLinkCursor`（约 2060 行）：居中逻辑（每次到达滚到水平中央），继续复用；复盘态不改变 endOffset 语义。
  - 指标计算：`recomputeMainCurves`（约 1090 行）/`recomputeSub`（约 1231 行）经 `mainRows`（约 1188 行）调 `TDXFormulaEngine.evaluate(statements:data:)`；`calcData(from:to:)` 提供区间数据。**as-of 重算复用同一引擎，仅替换输入序列与调用入口**。
  - 主图绘制 `MainChartCanvas`（约 4000 行）：入参 `slice`/`curves`/`gaps`/`latest`，内部分样式 `drawCandles`/`drawOHLC`/`strokeLine` 与 `drawCurve`；镜像路径在构造入参处（约 2995 行 `mainMirrored ? mirroredSlice : slice`）。
  - 副图绘制 `SubChartCanvas`（约 4252 行）：`drawBars`（stick：VOL/AMO 柱）/`drawLine`；由 `subChart(model:)`（约 3025 行）构造。
  - 行情行 `axisQuoteRow`（约 3571 行）按光标索引读 KlineItem；数值栏经 `legendValue(_:)`（约 931 行）读 `arr[idx]`。
  - `priceRange`（约 1406 行）：含 5% padding；合成 K 线 OHLC 必在真实完整大 K 线范围内 → **价格域不变**。
  - 镜像辅助：`mir(_:)`（约 885 行）、`mirroredSlice`（约 902 行）、`mirroredRange`（约 924 行）。
- `KlineData.swift`：`KlinePeriod.granularityRank`（日0<周1<月2<季3<年4）、`periodDateRange(_:date:)` 给出大周期 [start,end]（周一固定 Monday）。
- `DatabaseManager.fetchBars(metaId:period:)`（DatabaseManager.swift 221 行）：同步本地查询，来源周期序列走它（与 tile 加载同一线程模型：后台队列查、主线程提交）。
- `LinkedKlineTile.swift`：tile 持有 `view.metaID` / `view.period`，向 KlineChartView 传参；共享 `DualLinkSync`。

## 4. 技术设计

### 4.1 派生状态总览（全部在 KlineChartView 内计算，光标消失自动为 nil）

```
linkReplay: (idx: Int, synthetic: KlineItem?, dimFrom: Int)?
```

- 生效条件（与范围框互斥）：`cursorLinkEnabled && !drag.cursorDragging && !linkUserDragging
  && linkSync.cursorDate != nil && linkRangeIndices == nil
  && self.period.granularityRank >= linkSync.sourcePeriod.granularityRank`；
- `idx = renderCursorIndex`（同一次派生内复用，避免两次最近查找不一致）；
- `dimFrom = idx + 1`（即使 synthetic 为 nil 也淡化，D3 停牌兜底）；
- `synthetic`：仅当 `self.period.rank > sourcePeriod.rank` 且聚合区间非空时存在（严格大于才合成；同周期 nil）；
- `renderCursorIndex` 现有"范围框时返回 nil"的总闸保持不动，复盘态正常返回 `idx`，现有竖线/行情行/数值栏通道继续工作。

### 4.2 来源周期数据缓存（新增轻量共享类，不改 LinkedViewStore 落盘）

- 新增 `final class LinkSourceBarCache`（建议放在 `KlineChartView.swift` 文件末尾，避免改 project.pbxproj）：
  - 进程内 `[(metaID, sourcePeriod): [KlineItem]]`（升序）+ 在途标记，仿 `LinkedTileDataSlot` 的 inFlight 防重；
  - `asyncBars(metaID:period:completion:)`：命中内存直接回调；否则后台 `DatabaseManager.fetchBars`、主线程回调；
  - 月线、季线 tile 同标的同来源（周线）时共享一份；内存估算：周线 ≈ 1500 根/标的，可接受；加简单 LRU 上限（如 12 组）防长期浏览膨胀；
- 数据新鲜度：缓存 key 附带轻量签名 `(targetCount, targetLastDate, sourceLastDate)`（数据更新后签名变化自动重查），不做复杂失效。

### 4.3 合成算法（同步、廉价，主线程执行）

输入：本视图 `sortedData`（目标周期）、来源序列 S、D=`linkSync.cursorDate!`、`idx`。

1. `(periodStart, _) = KlinePeriod.periodDateRange(self.period, date: sortedData[idx].date)`；
2. 在 S 中二分：`lo = lowerBound(periodStart)`，`hi = upperBound(D)`（首个 date > D 的下标 -1）；
   - 复用范围框同款严格二分骨架（现有 `lowerBound(_:)` 约 948 行 + 对称实现 upperBound）；
3. 区间为空 → `synthetic = nil`（D3 兜底：淡化仍生效）；
4. 区间非空 → 聚合 S[lo...hi]：
   - `open = first.open`、`close = S 中 date 最大者（≤ D 末根）.close`、`high = max`、`low = min`、
     `volume = sum`、`amount = sum`（KlineItem 实际字段名实施时对齐）；
   - `date = sortedData[idx].date`（沿用目标周期 K 线的起始日期，保证标签/坐标不变）；
   - 其余字段（涨跌幅等派生显示字段）按现有 KlineItem 显示惯例由 OHLC 推导；
5. 性能：聚合长度 = 一个大周期内的来源根数（日→月 ≤23、周→季 ≤14、日→年 ≤250），每次 cursorDate 变化一次遍历，可忽略；**不做增量**，简单优先。
6. 同周期（rank 相等）跳过 2-5，`synthetic = nil`。

### 4.4 渲染层改造（阶段 A 主体）

统一约定：两个 Canvas 各新增三个**可选**入参，默认 nil → 绘制路径与现状完全一致（单图/联动关闭零影响）：

```
syntheticAt: (index: Int, item: KlineItem)?   // 单点替换
dimFromIndex: Int?                            // 该索引起（含）应用 dimAlpha
dimAlpha: CGFloat = 1.0/3.0
```

**MainChartCanvas**：

- `drawCandles`（实心/空心）：逐根遍历时 ① index == syntheticAt.index 用合成 item；② index >= dimFromIndex 颜色统一乘 `dimAlpha`（影线、实体边框、实体填充一致）；gaps 在淡化区内同样降 alpha；
- `drawOHLC`：同规则分段着色；
- `strokeLine`（收盘线样式）：拆三段绘制——`[0, syntheticAt.index)` 原色、合成点用 synthetic.close 原色、`[dimFromIndex, end]` dimAlpha（无合成时两段：≤idx 原色、其后淡化）；
- `drawCurve`（主图指标曲线，阶段 A 先不改点值，仅分段 alpha）：以终点索引归属决定每段颜色，即线段 `[i-1, i]` 当 `i >= dimFromIndex` 时淡化；
- `latest` 最新价虚线：复盘态且最新索引 >= dimFromIndex 时降 alpha（D1）；
- 镜像：synthetic item **传真实 OHLC**，在 Canvas 现有镜像取负的同一位置统一处理（把单点替换放在 `mirroredSlice` 构造之后或让 canvas 内部 `mainMirrored` 感知——实施时取改动小者，原则：镜像行为与真实 K 线完全一致）。

**SubChartCanvas**（主图外三个副图）：

- `drawBars`（VOL/AMO 柱）：`index == synthIdx` 时柱高用合成 volume/amount（阶段 A 即接入，聚合值是现成的）、原色；`index >= dimFrom` 降 alpha；
- `drawLine`（指标线）：阶段 A 只做分段 alpha，点值阶段 B 替换；
- 副图坐标域 `subRange`：VOL/AMO 的最大值可能因合成柱变化？合成量 ≤ 真实完整月量，坐标域按完整数据算 → 不变；其它指标 as-of 点同理不重算 range（点可能略出界，阶段 B 验证；若个别指标点超出，允许该点被 clip，不扩 range，避免纵向跳动）。

**竖线/横线 overlay（SwiftUI 层，非 Canvas）**：

- 竖线 `mainCursorVLine`/`subCursorVLine` 无需改（idx 不变）；
- 横线已由 2026-09-14 的 `linkedCursorClose` + `fixedPrice` 机制处理；阶段 A 把其取值源从"真实 K 线 close"改为 `synthetic?.close ?? 真实close`；
- `axisQuoteRow` 与任何按 idx 读 item 的位置：新增统一派生 `displayCursorItem: KlineItem?`（= synthetic ?? sortedData[idx]），全部改读它（单点改动，避免漏改）。

### 4.5 指标 as-of 重算（阶段 B 主体）

**数据流**：

```
cursorDate 变化
  → linkReplay 立即派生（合成 item + 淡化，UI 立刻正确）
  → 同时发起 as-of 任务（ticket++，仅保留最新；同 key 命中缓存直接用）
  → 后台：构造 as-of 输入序列 → 逐指标引擎求值 → 只取 idx 的各输出行值
  → 主线程 ticket 校验 → 写入 @State asOfOverrides（key=行标识 → value）→ 单帧刷新
```

- **输入序列**：`sortedData[0...idx]`，末项替换为 synthetic（量/额也替换）；不传未来段（引擎输出只取末点，未来段无参与必要，且省一半计算）；
- **主图**：对当前启用的每个系统/自定义主图指标的每个输出行求值（直接复用 `TDXFormulaEngine.evaluate(statements:data:)` 或 `evaluate(formula:data:)`，与 `mainRows` 同路径），取输出数组末位；
- **副图**：`subTop/subBottom/subThird` 三个 `SubChartModel` 同法处理其各行；VOL/AMO 不需要公式（直接用合成量/额，阶段 A 已处理）；
- **覆盖应用（不改原 curves 数组，避免污染缓存与后台 prefetch）**：
  - Canvas 曲线：新增入参 `pointOverrides: [lineKey: (index: Int, value: Double)]`（或并行数组 `[Double?]`，实施时按 CanvasCurve 现状选），绘制到该点时用 override 值，线段连接自动反映折点；
  - 数值栏：`legendValue` 在 `renderCursorIndex == idx` 且 override 存在时返回 override；
  - 横线价格/行情行不走 override（走 synthetic item）；
- **缓存**：`[AsOfKey: [lineKey: Double]]`，
  `AsOfKey = (metaID, targetPeriod, sourcePeriod, D, configFingerprint, sourceLastDate, targetCount)`；
  拖回历史日期零计算；缓存挂在 4.2 的同一共享类或 tile 级 @State（优先共享类，月/季 tile 同 D 可共用）；
- **调度**：`DispatchQueue.global(qos: .userInitiated)` + 每次发布新 D 时取消/作废旧 ticket（不依赖任务可取消，用序号丢弃即可）；不修改 `ChartCacheStore`，不触发 prefetch；
- **菜单/指标面板打开**：沿用 `menuIsOpen` 抑制惯例（面板打开时没有图表拖动场景，保守跳过 as-of）；
- **跨周期引用的自定义公式**（若引擎支持在公式中引用其它周期数据）：as-of 输入只构造本周期，跨周期引用部分无法正确 as-of。实施时排查引擎是否存在该能力：**若存在，此类输出行的 override 置空（保留原值）**，并在代码注释与用户 FAQ 不改（属极边角）。

### 4.6 生命周期与清除（天然派生，少量兜底）

- 光标消失（cursorDate=nil / cursorClearToken 变化 / 开「边」/ 钻取 / 退联动）→ `linkReplay=nil`、`asOfOverrides` 清空、待回 as-of 结果因 ticket 失效丢弃；
- 切周期/切标的导致 tile `.id` 重建 → @State 自然重置；共享缓存保留无害；
- 不需要新增持久化、不改 LinkedViews/LinkedZooms。

## 5. 分阶段实施与验收

**阶段 A — 合成 K 线 + 未来淡化（视觉层）**

改动：4.1 派生、4.2 缓存、4.3 合成、4.4 渲染（含 VOL/AMO 合成柱、横线/行情行接 synthetic）；指标曲线只分段淡化、点值暂为库中值。

验收（真机/模拟器手测）：

1. 周线源→月线：月线光标 K 线随周线光标在月内移动实时变形（OHLC/量符合聚合规则、红绿翻转），其后全部月 K 淡化 1/3；
2. 周线源→季线：10 月中触发时 Q4 合成包含 10 月初至光标周（验证"季起始边界"）；
3. 日→日（两视图同标的/不同标的）：无合成、其后淡化；
4. 跨标的：B 的月线用 B 自己的周线合成（数值与 A 无关）；
5. 标的整段停牌：光标那根回退真实 K 线，淡化仍在，不崩溃；
6. 四种主图样式（空心/实心/收盘线/OHLC）+ 多/空镜像下合成与淡化均正确；
7. 清光标/关联/开边/钻取/退联动：全部瞬时恢复；
8. 拖动流畅度与现状一致（无指标重算介入）。

**阶段 B — 指标 as-of 重算**

改动：4.5 全部。

验收：

1. 月线合成点主图 MA/BOLL 等曲线点与数值栏读数 = 用"截至该周"序列重算值（可用 Xcode 单图对照或日志抽样核对至少 MA5/MA10、MACD、KDJ）；
2. 历史段、未来段数值与曲线零变化；未来段曲线淡化但值不变；
3. 快速来回拖动：图形实时，数值轻微滞后但最终精确；拖回已访问日期瞬时命中；
4. VOL/AMO 数值栏 = 合成累加量；
5. 切换指标配置后旧 override/缓存不被误用（configFingerprint 生效）；
6. 长时间拖动无内存持续增长（缓存上限生效）。

两阶段各自保证编译通过 + CI 成功 + 独立可演示，分别提交。

## 6. 边界与边角 case 清单

- [x] 光标在最后一根：dimFrom 越界 → 无淡化、synthetic 与库值一致（自然退化）
- [x] 聚合区间为空（停牌/无行情）：synthetic=nil，淡化生效，横线取真实 close
- [x] 同周期：不合成，淡化生效
- [x] 跨标的：各自取数
- [x] 范围框模式（rank <）互斥，不受影响
- [x] 镜像模式：合成 OHLC/量取负路径与真实 K 线一致
- [x] 主图坐标域/副图坐标域不变（合成值被完整周期值包络）
- [x] 空心样式：合成 K 线空心/实心颜色规则跟随 isUp（合成开 vs 合成收）
- [x] 收盘线样式：分段绘制无断点错位（合成点衔接两侧 x 坐标一致）
- [x] 跨月周归属：整周计入"起始交易日所在月"，不拆分（用户接受）
- [x] 数据更新后：缓存签名失效自动重查
- [x] tile 切周期/切标后重建：无残留 override
- [x] 双指缩放进行中：合成/淡化是渲染派生随当前可见窗口工作；居中让路逻辑已有
- [ ] 实施时确认：KlineItem 中 amount/volume 字段名与"额"显示链路（hideQuoteTurnover 下联动态不显示额，但 VOL/AMO 副图要用）
- [ ] 实施时确认：TDX 公式引擎是否支持跨周期引用；有则按 4.5 兜底
- [ ] 实施时确认：缺口（GapInfo）在淡化区的视觉是否需要同步淡化（默认：同步淡化）

## 7. 风险与对策

| 风险 | 等级 | 对策 |
| --- | --- | --- |
| 拖动中 as-of 重算卡顿（代码已有"拖拽禁止重算"的明确教训） | 高 | 严格异步 + ticket + 缓存（D4）；退路：月/季/年等短序列（目标总根数通常 < 1000）评估改为同步算，日→年（≤250 根来源/次）实测后定 |
| Canvas 入参增多导致 Equatable 失效、全量重绘 | 中 | 新增入参为值类型且默认 nil；用结构化 equatable 比较；合成 item 变化频率 = 光标移动频率（本就重绘），无额外负担 |
| override 漏接到某处读数（行情行/第三副图/第二光标统计） | 中 | 阶段 B 开工前全局 grep 所有 `sortedData[.*idx` / `[renderCursorIndex]` / `[selectedIndex]` 读数点，统一走 displayCursorItem / override 通道，列清单逐个过 |
| 污染 ChartCacheStore / prefetch 结果串扰 | 中 | as-of 产物只存独立 @State + 独立缓存类，绝不写 ChartCacheStore；引擎调用使用独立数据组 |
| 跨周期自定义公式 | 低 | 排查后有则该输出行不覆盖（保留原值） |
| 缓存内存膨胀 | 低 | LRU 上限 + 签名失效 |

## 8. 验证（编译 + CI + 真机手测）

1. 编译：`xcodebuild -project Kline.xcodeproj -scheme Kline -configuration Debug -destination 'generic/platform=iOS Simulator' build` 无 error、无新增 warning；CI 全绿后走 TrollStore 自动部署；
2. 手测路径：第 5 节两阶段验收清单逐条过；重点回归**范围框模式不受影响**、**单图模式无任何视觉变化**、**清光标恢复**；
3. 性能：iPad mini 4 上日/周/月/季 4 视图同屏，最快速度来回拖动来源光标，目标视图无明显掉帧（以现状范围框拖动流畅度为基准）。

## 9. 明确不做（Out of Scope）

- 不改「双竖轴范围框」一侧的任何行为；
- 不改联动开关、居中、边线、钻取等既有交互；
- 不持久化复盘状态（光标消失即恢复，不跨会话保留"历史时点"）；
- 不做"未来区域点击穿透/禁止交互"等额外手势语义；
- 不拆分跨月周（接受整周归属一侧的近似）；
- 不为复盘态新增任何用户设置项（透明度 1/3 固定为设计值）。

## 10. Critical Files

- `Kline/KlineChartView.swift` — 派生状态、合成算法、两个 Canvas 分段绘制、as-of 任务与 override、displayCursorItem（主要工作量）
- `Kline/KlineData.swift` — 仅复用 `periodDateRange` / `granularityRank`，预计无改动
- `Kline/KlineDetailView.swift` — `DualLinkSync` 预计无改动（必要时仅清场路径复核）
- `Kline/LinkedKlineTile.swift` — 预计无改动（metaID/period 已透传）；如新缓存类需要注入再小改
- `Kline/DatabaseManager.swift` — 仅复用 `fetchBars`，无改动
- 用户手册：`Kline/Kline-联动多图光标联动说明.md`（已按目标形态更新，实施完成后去掉顶部"待实施"状态标注并补技术索引）
