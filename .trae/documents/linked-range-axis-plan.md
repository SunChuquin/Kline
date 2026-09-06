# 联动模式：更小周期视图用「双竖轴」框出来源周期K线范围

## Context（背景与目标）

联动模式（`KlineDetailView` 的 dualLink + cursorLinkEnabled 开启）下，当前所有视图在来源视图触发十字光标时，都按日期同步显示同一个十字光标（被联动视图始终居中）。

需求：当**更大周期**视图（周/月/季/年线）触发十字光标时，被联动的**更小周期**视图（日/周线）**不应显示十字光标**，而是显示**两根无标签的竖向竖轴**，把来源周期那根K线所覆盖的日期范围内的所有K线"框出来"：
- 周线触发 → 日线两竖轴包围那一周的日K线；
- 月线触发 → 周线、日线各自两竖轴包围那一个月的K线；
- 若范围大于当前可见K线数（如年线源→日线仅100根），**自动放大可见数量**让两竖轴都在屏幕内，并尽量居中。

## 关键现有代码（已确认，复用而非重写）

- `KlineChartView.swift`：
  - `DualLinkSync`（在 `KlineDetailView.swift`，约112行）：`@Published var cursorDate: Int?` + `var lastCursorFromRightUser`。
  - `publishLinkCursor(index:)` 约1983行：`cursorLinkEnabled && linkUserDragging` 时发布 `linkSync.cursorDate = date`。
  - `applyLinkCursor(_ date:)` 约2001行：被联动视图把光标居中（改 `endOffset` + `refreshCurves()` + `startPrefetch()`）。
  - `renderCursorIndex` 约941行：联动接收态由 `linkSync.cursorDate` 派生，否则 `selectedIndex`。
  - 光标绘制：body overlay ZStack `cursorOverlay`（约1793-1811行，跨全高）、`mainChart` 的 `mainCursorVLine`（约2724行）、副图 `subCursorVLine`（约2927行）。
  - 可见窗口状态：`visibleCount`/`endOffset`（@State，默认100/0）、`count`、`endIndex`、`startIndex`、`capVisibleCount`。
  - `nearestIndex(to:)` 约2036行（带"更近者"回退，**不能直接用**，见边界）。
  - `KlineItem.formattedDateWithWeekday`（`KlineData.swift` 62行）已有从 YYYYMMDD `Int` 拆 (年,月,日) 的写法，可反用。
- `KlineData.swift` `KlinePeriod` 约108行：daily/weekly/monthly/quarterly/yearly，无粒度、无日期范围计算。

## 实现步骤

### 1. `KlineData.swift` — `KlinePeriod`（约108行）
- 新增 `var granularityRank: Int`：daily=0 / weekly=1 / monthly=2 / quarterly=3 / yearly=4。
- 新增 `static func periodDateRange(_ period: KlinePeriod, date: Int) -> (Int, Int)`：把 `date` 拆 (年,月,日)，用 Calendar 算该K线覆盖的 YYYYMMDD 起止；日线=(当天,当天)，周线=(周一,周日)，月/季/年用 `Calendar.dateInterval(of: .month/.quarter/.year)`。
  - **周线起点固定 Monday**（`Calendar(identifier:.gregorian)` 显式设 `firstWeekday=2`），勿用用户地区默认 `.firstWeekday`。
  - 复用拆/拼辅助 `toYMD(_:)->(Int,Int,Int)` 与 `fromYMD(_:_:_:)->Int`（参考 `KlineItem` 53-59行反向）。

### 2. `KlineDetailView.swift` — `DualLinkSync`（约112行）
- 新增 `var sourcePeriod: KlinePeriod = .daily`（普通 var）与 `@Published var sourceRange: (Int, Int)? = nil`（必须 `@Published` 才能驱动目标侧排版重算）。
- 在清联动残留处（约1145行及419/516行切单图/退联动路径）把 `linkSync.sourceRange = nil` 一并复位（兜底，`cursorDate=nil` 时本就不会进范围分支）。

### 3. `KlineChartView.swift` — 主体
1. `renderCursorIndex`（942行）上方新增：
   ```
   private var linkRangeIndices: (left: Int, right: Int)? {
       guard cursorLinkEnabled, !drag.cursorDragging, !linkUserDragging,
             linkSync.cursorDate != nil,
             let rng = linkSync.sourceRange,
             self.period.granularityRank < linkSync.sourcePeriod.granularityRank else { return nil }
       let left = lowerBound(rng.0) ?? 0
       guard let rb = lowerBound(rng.1 + 1) else { return nil }   // 越界
       let right = rb - 1
       guard right >= left else { return nil }                    // 目标不在范围内
       return (left, right)
   }
   ```
2. 新增 `private func lowerBound(_ target: Int) -> Int?`：返回**第一个** `date >= target` 的下标，二分骨架复用 `nearestIndex` 但**去掉"更近者"回退**（约2052-2058行），保证语义是下界。
3. `renderCursorIndex` 第一行加：`if linkRangeIndices != nil { return nil }`，从此 `cursorOverlay`/`mainCursorVLine`/`subCursorVLine`/`legendValue`/`axisQuoteRow`/`notifyHasCursor` 全部自动走 nil 回退，**无需逐处屏蔽**。
4. `publishLinkCursor` 在 `linkSync.cursorDate = date`（约1994行）处同步：
   ```
   linkSync.sourcePeriod = self.period
   linkSync.sourceRange = date.map { Self.periodDateRange(self.period, $0) }
   ```
5. 新增 `private func centerLinkRange(left: Int, right: Int)`：开头 `guard !drag.twoFingerActive else { return }`（避免与双指缩放锚定冲突，见 A1）。范围 `span = right-left+1`；目标可见数 `need = min(max(span, count), capVisibleCount)`；`visibleCount = CGFloat(need)`；算一个让 `[left,right]` 居中的 `endOffset`（目标 end 落于 `clamp(right + (need-span)/2, ...)`），变化时赋值并 `refreshCurves()` + `startPrefetch()`。
   - 仅当 `span > count` 才放大；`span <= count` 时沿用当前可见数只做 re-center（避免"碰一下来源就把目标缩放跳变"）。
   - 数据不足（如年线源但日线仅100根）时 `need` 封顶 `capVisibleCount`，两轴可能不入屏，属合理降级，不崩溃。
6. `applyLinkCursor`（2001行）在 `guard let date, let idx = nearestIndex(to: date)` 成功之后、单光标居中之前插入：
   ```
   if let rg = linkRangeIndices {
       linkCursorActive = true; notifyHasCursor()
       centerLinkRange(left: rg.left, right: rg.right)
       return
   }
   ```
   否则维持原有单光标居中逻辑。
7. 新增 `@ViewBuilder private func linkRangeAxisOverlay(left: Int, right: Int, candleSpacing: CGFloat, height: CGFloat) -> some View`：用 `xPosition = (CGFloat(index - startIndex) + 0.5) * candleSpacing`（与 `mainCursorVLine` 2748行一致）画两根 1~1.5pt 全高竖线（灰色/高亮色，**无标签**），两线之间加一层 `Color.xx.opacity(0.05)` 淡填充以示意范围。
8. body overlay 的 ZStack（1793-1811行）内、两个 `cursorOverlay` **之前**插入：
   ```
   if let rg = linkRangeIndices {
       linkRangeAxisOverlay(left: rg.left, right: rg.right, candleSpacing: candleSpacing, height: geometry.size.height)
   }
   ```

## 边界与行为约定
- 目标侧用户自己拖十字光标（`drag.cursorDragging || linkUserDragging`）时，范围框消失、正常显示单个光标；松手后该视图成为新来源，其余视图按新周期/范围重绘（对称联动已有语义，复用即可）。
- 清光标/退联动：`cursorClearToken` 变化清 `selectedIndex/pinnedIndex`；`cursorDate=nil` 使 `linkRangeIndices=nil`，范围框自然消失。
- 更大周期源 → 更小周期全部正确框范围；同级（如周→周）不框范围，走原有单光标居中（`granularityRank <` 严格小于才生效）。

## 验证（端到端，编译 + 手动，不自动跑模拟器）
1. 编译通过：`xcodebuild -project Kline.xcodeproj -scheme Kline -configuration Debug -destination 'generic/platform=iOS Simulator' build` 无 error、无新增 warning。
2. 手动验证路径（按项目测试规则，由用户真机/模拟器确认）：
   - 周线源 → 日线：日线无十字、两无标签竖轴框住整周日K，范围居中。
   - 月线源 → 周线与日线：两者都出范围框；季/年线（更大）仍走单光标居中。
   - 年线源 → 日线仅100根装不下 → 自动放大可见数，两轴入屏；数据不足时不崩溃。
   - 目标侧自己拖光标 → 出现单光标、范围框消失；松手后成为新来源。
   - 清光标/退联动 → 范围框消失。

## Critical Files
- /Volumes/home/repositories/Kline2/Kline/KlineData.swift
- /Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift
- /Volumes/home/repositories/Kline2/Kline/KlineChartView.swift
- （`LinkedKlineTile.swift` 仅透传 period，如无编译需要则不改）