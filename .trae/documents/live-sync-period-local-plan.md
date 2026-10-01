# 周/月线从「云端分片」改「App 本地聚合」——实施计划

> 状态：**阶段 1 + 阶段 2 已实现并推送**（2026-10-01，commit `33b25f4` / `309840f`），等待模拟器验证（需先把「数据同步」总开关 `kline.tdxsync.enabled` 打开）
> 来源：[[Kline-境内CI云端生产方案]] §3.3 —— 云端只发日线表，周/月线由 App 从日线聚合。
> 已确认的三个选择：① 分片侧**直接摘掉** `bkt_weekly`/`bkt_monthly`；
> ② 聚合源 = **主库日线 ∪ 增量库日线**，按当期窗口**重算**；③ **只做「当期」**周/月。

## 1. Context（为什么要改）

云端分片原本自带 `bkt_weekly` / `bkt_monthly`，App 直接落 `live_weekly` / `live_monthly`。
现在云端**只发日线**（省体积、省一次聚合），周/月线必须在 App 侧从日线生成，
否则周/月线会停在主库最近一次同步日，盘中不再前进。

## 2. 现有代码（带行号）

| 位置 | 作用 | 与本次改动的关系 |
| :--- | :--- | :--- |
| [LiveDataStore.swift L200-L206](../../Kline/Data/LiveDataStore.swift#L200-L206) | `bucketTableMap`：`bkt_*` → `live_*` 映射 | **摘掉 weekly/monthly 两项** |
| [LiveDataStore.swift L743-L819](../../Kline/Data/LiveDataStore.swift#L743-L819) | `_mergeBucketLocked`：逐表 `INSERT OR REPLACE` | 缺 `bkt_*` 表本就 `continue`（L788），摘掉后天然兼容 |
| [LiveDataStore.swift L1003-L1055](../../Kline/Data/LiveDataStore.swift#L1003-L1055) | `_trimLocked` + `periodCalendarStart`（L1060-L1067） | ⚠️ **必须给 weekly/monthly 加周期感知**，否则当期 bar 会被 `date <= beforeDate` 裁掉 |
| [LiveDataStore.swift L1069-L1110](../../Kline/Data/LiveDataStore.swift#L1069-L1110) | `_allIncrementRowsLocked` / `_readRowsLocked` | 读增量库五表的现成写法，新增聚合要复用 |
| [WatchlistSyncManager.swift L168-L208](../../Kline/Infrastructure/WatchlistSyncManager.swift#L168-L208) | 「主库当期 bar ⊕ 新日线」→ 写季/年 | **阶段 2** 的样板（本阶段先不动） |
| [KlineData.swift L129-L160](../../Kline/Data/KlineData.swift#L129-L160) | `KlinePeriod.periodDateRange` | 取当期起始日（周=周一、月=1 号），**已现成** |
| MainDBMerger.swift L131-L139 | 合并后 `trim(beforeDate: dates[3])` | trim 只在显式合并后触发，是"增量库日线不完整"的根因 |

**硬约束（沿用 LiveDataStore 头部注释）**：主库 `tdx.db` 全程只读不改；
LiveDataStore 自持串行队列，**绝不**在持锁状态下回调 `DatabaseManager`，反向亦然。
→ 所以「读主库」必须先在 `DatabaseManager.dbQueue` 上取完，再进 LiveDataStore 队列。

## 3. 分阶段实现

### 阶段 1（本次）：云端分片消费路径改本地聚合

1. **`bucketTableMap` 摘掉 weekly/monthly**（[LiveDataStore.swift L200-L206](../../Kline/Data/LiveDataStore.swift#L200-L206)）
   → 周/月线不再从分片来，唯一来源变成本地聚合（与季/年模式一致）。
2. **`periodCalendarStart` 增加 weekly/monthly**（L1060-L1067）
   → `trim` 对当期周/月 bar 走周期感知分支，只保留当期。
3. **新增 `LiveDataStore.rebuildCurrentPeriodBars(referenceDate:mainDaily:completion:)`**
   - 入参：参考交易日（最新片日期）、`mainDaily`（调用方在主库队列上预取的主库日线）
   - 自队列内：按 `[当期起始, referenceDate]` 读 `live_daily` → 与 `mainDaily` **并集**（同 date 以增量库为准）
   - 按 file×周期聚合（`open` 取首行 / `high·low` 取极值 / `close` 取末行 / `vol·amo` 累加）
   - 单事务 `INSERT OR REPLACE` 进 `live_weekly` / `live_monthly` → `reloadAsync`
   - **重算而非累加** → 天然幂等；一次补多片也正确
4. **`DatabaseManager` 新增「按 file 列表 + 日期窗口读主库日线」**
   - 字段顺序与 `KlineItem` 一致；沿用现有 `meta_id IN (...)` 内联字面量写法
5. **`TdxSyncManager` 在分片全部合并完成后**触发：
   `referenceDate` = 本批分片最大交易日 → 算当期周/月起始 → 读主库日线 → 调用 3

### 阶段 2（已完成）：设备直连路径同步

`WatchlistSyncManager.handle()` 的主库读取由「只取季/年基期 bar」扩成**一次跨队列取两样**：
① 季/年 bar（老口径不变：主库当期 bar ⊕ 新日线）；② 主库日线（周/月当期窗口）。
写库顺序改为：`upsertDaily(日线 + 季/年)` → **日线落库后**再 `rebuildCurrentPeriodBars(参考日=交易日, mainDaily:)`
重算当期周/月 → 末尾只 `reloadAsync` 一次。
季/年仍走老口径（未纳入本次改动范围），周/月与云端分片路径共用同一套全量重算。

## 4. 边界与风险

| 边界 | 处理 |
| :--- | :--- |
| 分片仍带 weekly/monthly（云端先不改） | 摘掉映射后**不再读**，无冲突 |
| 当期窗口的早几天不在增量库（被 trim 过） | 由 `mainDaily` 并集补上；两者都缺 → 该周期 bar 缺失，不写（不覆盖主库） |
| 历史周/月 bar | **不写**，由主库（通达信导入）提供，本就是完整正确的 |
| 写入触发 dataVersion++ → 条件单全量重扫 | 仅写**受影响 file** 的当期 bar；条数与原来分片写入同量级 |
| 幂等 | 重算 + `INSERT OR REPLACE`；同一交易日重复跑结果相同 |
| 只有单个交易日数据时 | 当期 bar = 当日聚合（`open=high=low=close=当日`），与季/年线现有行为一致 |

## 5. 验收清单

- [x] 编译通过（`33b25f4`；分片合并后日志里应出现 `[TdxSync] 当期周/月聚合：…`）
- [ ] 设备上：日线正常；**周线/月线最新一根 = 当期**（date = 本周一 / 本月首日且是其首个交易日）
- [ ] 与主库历史周/月线衔接无断档、无重复
- [ ] 一次补齐多片（清空增量库后重下 30 片）后，当期周/月 bar 数值与云端 old 口径一致
- [ ] `trim` 后当期周/月 bar 未被误删

## 6. Critical Files

- [Kline/Data/LiveDataStore.swift](../../Kline/Data/LiveDataStore.swift) — 映射、trim、新增聚合
- [Kline/Data/DatabaseManager.swift](../../Kline/Data/DatabaseManager.swift) — 主库日线窗口读取
- [Kline/Infrastructure/TdxSyncManager.swift](../../Kline/Infrastructure/TdxSyncManager.swift) — 合并后触发
- （阶段 2）[Kline/Infrastructure/WatchlistSyncManager.swift](../../Kline/Infrastructure/WatchlistSyncManager.swift)