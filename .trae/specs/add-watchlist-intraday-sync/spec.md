# 清单驱动盘中行情自动更新 + 复权差分重灌 Spec

## Why

现状：Kline 只能**手动**把 PC 上的通达信数据拷进设备沙盒，且整库替换要杀进程重启。

但用户真正关心的标的只在 App 内自己维护的 6 类清单里（自选 / 分组 / 置顶 / 预警 / 条件单 / 委托）。这些清单**只存在于设备上**（`Documents/Favorites/favorites.json`、`Documents/Simulation/sim.json`），PC 侧无从得知——所以「PC 先算好再推」存在鸡生蛋问题。

目标：
1. **设备侧**在交易日 **11:00 / 14:30 / 15:05 / 17:30** 用已验证可用的东财数据源，自动拉取「6 类清单并集」标的的当日K线，写入增量库并触发条件单/预警重扫。**不依赖 PC**，人不在电脑前也成立。
2. **PC 侧**保留「重灌」通道：用户用通达信客户端补缺口 / 通达信复权因子改写历史后，由 PC 出**差分包**推设备。

几十天的历史缺口由用户在通达信客户端侧全量更新解决，本 Spec 不负责补缺口算法。

---

## 答疑（用户三问）

### 问 1：全量推送到 iPad 要多久？

| 项 | 数值 | 出处 |
| :--- | :--- | :--- |
| 主库 `tdx.db` 体积 | **1,379.7 MB**（1,446,756,352 B） | 实测文件大小，mtime 2026-08-31 |
| 通道 | `POST /upload`（**流式**，非 `/sandbox`） | [migrate_tdxdb.py](file:///c:/Users/sunck/home/projects/ios/TrollRestore/migrate_tdxdb.py) |
| 记录吞吐 | **6~11 MB/s**（记录值 2-4 分钟） | `migrate_tdxdb.py:7,59`；`.trae/documents/Kline-数据源改版-可行性分析与实施计划.md:14,57` |
| **实测吞吐（本次）** | **10.74 / 11.70 MB/s**（USB，64 MB 样本两次） | 本次实跑：`PUT#1 5.96s 10.74 MB/s`、`PUT#2 5.47s 11.70 MB/s` |
| 拉取侧参照 | 13 MB/s | `migrate_tdxdb.py:7`（house_arrest） |

**结论：全量 ≈ 2~4 分钟传输，且整库替换后仍需重启 App**（主库维持「启动时打开」语义，见 [add-live-data-auto-sync/spec.md](file:///c:/Users/sunck/home/projects/ios/Kline/.trae/specs/add-live-data-auto-sync/spec.md)）——加上重新走一遍增量合并，实际中断成本更高。

**按本次实测吞吐线性外推**：1,379.7 MB ÷ 11.2 MB/s ≈ **123 秒（≈2.05 分钟）**，与记录值 2-4 分钟吻合。

### 问 2：3 千多只「当天一根K线」的差分升级要多久？

**先修正一个前提**：不能只更新最新一根。主库存的是**前复权价**（源头 txt 首行即标「前复权」，如 `C:\Users\sunck\home\tdx_data\SH#600519.txt`），而前复权因子来自通达信 gbbq 股本变迁：**每新增一次除权除息，该标的的全部历史价格会被重新缩放**。

所以真实的「差分」= ① 全体追加当天 1 根 + ② 受影响标的**整段历史重灌**。

量化依据：

| 量 | 数值 | 出处 |
| :--- | :--- | :--- |
| 全市场标的 | 3,611 只 | 主库 meta |
| 日线总行数 | 14,008,185 行（平均 **3,880 行/只**） | `.trae/specs/scale-live-db-to-whole-market/spec.md:200` |
| 单行成本 | **93.9 B/行**（实测校准，见下方实测用例；原推算 80~100 B/行命中） | 本次实测 |
| 除权除息频次 | 2025 全年 **5,547 次**；2026 截至 09-04 已 **4,386 次** → 常态 **22~24 只/交易日**（分红季 5-7 月高度集中，峰值可达上百只） | 本机 `C:\new_tdx64\T0002\hq_cache\gbbq`（5,552,750 B / 191,474 条）category==1 统计 |
| 实测单日片 | **576 KB**（3,312 只，含 meta+索引） | [manifest.json](file:///c:/Users/sunck/home/projects/ios/Kline/build_logs/live_eastmoney/manifest.json) |

推算结果（每行成本已由本次实测校准为 **93.9 B/行**）：

| 场景 | 数据量 | 推送耗时（按实测 11.2 MB/s） | 设备合并耗时 |
| :--- | :--- | :--- | :--- |
| ① 纯追加当天 1 根（3,611 行） | ≈ **0.34 MB** | < 0.1 秒 | < 0.1 秒 |
| ② 常态差分（①+ 22~24 只整段重灌 ≈ 11 万行） | ≈ **10.2~10.9 MB** | ≈ 1 秒 | ≈ 0.6 秒 |
| ③ 分红季峰值（①+ 上百只重灌 ≈ 48 万行） | ≈ **43.9 MB** | ≈ 4 秒 | ≈ 2.5 秒 |
| 对比：全量 | 1,379.7 MB | ≈ 2.05 分钟 | —（且需重启 App） |

**实测用例（本次真跑，非推算）**：把「历史最长的 24 只」（平均 **8,331 行/只**，是市场平均 3,880 的 2.1 倍）做整段重灌：

| 环节 | 实测值 |
| :--- | :--- |
| 差异产物 | `patch_2.db` **22.500 MB** / **251,849 行**（daily 199,969 + weekly 41,917 + monthly 9,963）→ **93.9 B/行** |
| 包内覆盖日期跨度 | 1990-01-02 ~ 2026-09-22（跨 36 年） |
| PC 生成总耗时 | **400.0 秒（6.7 分钟）**：两库 sha256 校验 14.5s + 自洽性检查 37.4s + 差异扫描/出包 386.7s + 完整性复核 13.3s |
| USB 传输 | HTTP 200（22.5 MB，按 11.2 MB/s ≈ 2 秒） |
| 设备合并 | **1.3 秒** → `合并完成 meta=24 daily=199969 weekly=41917 monthly=9963 覆盖=3314只` |
| 设备状态变化 | `dailyCount 3,303 → 203,272`；`earliestDate 20260922 → 19900102` |
| 逐行一致性抽查 | `27#HSI` 9,046 行 / `SH#999999` / `SZ#399001` —— **值不一致 = 0**；各多 1 行（20260922 当日K线，主库尚无） |

**结论：差分把每天要传的量从 1.38 GB 降到约 10 MB（约 1/140），传输+合并从分钟级降到秒级**；真正的成本转移到了 **PC 侧生成（6.7 分钟/次）**——这是盘后任务，可接受。代价是无法用「全量替换」的粗暴方式，必须维护一套差分包契约。

> 注：`①` 的每日自动更新走**设备侧东财直连**，不产生差分包；差分包只在「复权改写 / 缺口补齐」时由 PC 生成。

### 问 3：差分用「新 tdx.db vs 旧 tdx.db」还是「新 txt vs 旧 txt」？

**推荐：新 tdx.db vs 旧 tdx.db。**

| 维度 | A. db vs db（**推荐**） | B. txt vs txt |
| :--- | :--- | :--- |
| 是否复用现有链路 | ✅ 直接复用 [tdx_parser.py](file:///c:/Users/sunck/home/projects/ios/Kline/src/tdx_parser.py) 的唯一一份解析/过滤实现 | ❌ 需要再写一套与 tdx_parser 等价但独立的解析（GBK、表头偏移、`42#/46#/12#` 与「债」条件过滤），**两套实现必然漂移** |
| 差异口径 | ✅ 与设备主库同表同字段，差异行可直接生成差分包，零格式转换 | ❌ 文本差异需再映射回库表口径 |
| 磁盘占用 | ❌ 需双份库 ≈ 2.8 GB | ✅ 需旧 txt 快照 ≈ 0.7 GB |
| 每日重建成本 | ❌ 需重建整库（解析 + 插 1,400 万行） | ✅ 省掉建库 |
| 抗导出设置变化 | ✅ 库是产物，设置变化在解析期暴露 | ❌ 列序 / 表头 / 复权选项一变即静默出错 |
| 缺口补齐 | ✅ 「几十天缺口」的全部新行天然落入差异 | ⚠️ 需自行按日期范围聚合 |

关键取舍：本项目明确以「**唯一一份实现，不会两套漂移**」为工程原则（见 [build_live_buckets_pc.py](file:///c:/Users/sunck/home/projects/ios/TrollRestore/build_live_buckets_pc.py) 文档说明）。B 方案为了省 0.7 GB 磁盘和几分钟建库时间，代价是多养一套解析器，**不划算**。

补充事实（供参考，非推荐依据）：`C:\Users\sunck\home\tdx_data` 现有 **3,637 个 txt / 701.5 MB**，比 db（1,379.7 MB）小——所以 txt 方案的磁盘优势存在，但仍不足以抵消双实现风险。

**关键前置（实测推翻了一个初始假设）**：差分方案要求基线库是**自洽**的（`meta` 表与数据表用同一套 `meta_id`）。

原先打算用 `C:\Users\sunck\home\projects\tdx_project\tdx.db` 当基线，**实测该库不自洽**：
- 它的 `meta` 表用字母序 id `1..3611`，而数据表是 id `3..3637`；
- 按 `meta_id` 直接对齐两库时，**1400 万行日线的值差异为 0**——说明它的数据表其实就是新库同一份，只有 `meta` 表是另一套 id 排序；
- 于是按 `file` 关联会产出 **1231 万行假差异**，完全不可用。

**正确做法**：基线 = 设备上已同步过的那一版主库**整份拷贝**（同一文件天然自洽）。首次使用时拷一份存档，之后每次重建 `tdx.db` 再与它对比。差分生成器已内置 `check_meta_consistency` 门槛：基线不自洽即 **exit 3、不产包**，杜绝假差异被推给设备。

---

## 方案选型（已确认）

**采纳**：设备侧东财直连（4 时刻、清单驱动）+ PC 侧 db-diff 差分包（按需/盘后）

**理由**：清单在设备上，设备自己拉取最自然，且避开「PC 需先知道设备清单」的鸡生蛋问题；PC 只在「复权改写 / 缺口补齐 / 整库重建」时出差分包。

**不采纳**：
- 云端 GitHub Actions 定时（已于境外 runner 被行情源 502 拒绝，实测失败）
- 仅追加当天 1 根的「增量」（无法覆盖复权改写历史，会让图表出现跳空）

**已确认的两个选型**：
1. 取数位置 = **设备侧直连**（清单只存在设备上，PC 无从得知）
2. 差分对比基准 = **db vs db**（复用唯一一份解析实现；基线需自洽，见「问 3」的关键前置）

**实现期追加约束（原 spec 未覆盖，实施中发现）**：
- 设备侧写入必须加「写前判定」：`INSERT OR REPLACE` 即使写入相同值也会改写 SQLite 页 → 空跑也会让 `dataVersion` 自增。已改为只写入库里没有或任一字段超 `1e-6` 容差不同的行，过滤后无变化即完全跳过事务与刷新。
- 补丁包与分片一致「下载到临时路径 → 合并成功即删」，故「最近 N 个」上限只作用于幂等记录长度（`maxMergedPatchRecords = 10`），与分片 30 片滚动完全无关。
- 门禁复用既有 `TdxSyncConfig.enabled` 与 `tradingDaysOnly`，未新增开关；清单东财同步与云端 manifest 拉取**独立触发、互不影响成败**。

---

## What Changes

- **新增设备侧东财取数器**：按 6 类清单并集拉当日K线，`ulist.np/get` 批量（100 只/批，清单量级只数通常 1~3 批），交易日以快照 `f124` 按北京时间换算（沿用既有口径，绝不用本机日期）。
- **新增清单并集聚合入口**：6 类清单 → `file` 集合（`SH#600000` 形式），缺失映射的扩展行情指数走内置 secid 覆盖表。
- **调度时刻扩展**：由 11:00 / 14:30 / 15:05 → **11:00 / 14:30 / 15:05 / 17:30**。
- **写入走既有热刷新链路**：写入增量库后 `dataVersion` 自增 → `MarketRowCache` 重取 + `SimStore.sweepConditions(trigger: .dataReload)`，**条件单/预警自动重扫，无需新触发机制**。
- **新增差分包契约**：`patch_<seq>.db`，表结构复用分片（`bkt_meta/bkt_daily/bkt_weekly/bkt_monthly`），但**可含任意多个历史日期、不受 `KEEP_BUCKETS=30` 限制**；manifest 增加 `patches` 数组，与 `buckets` 并列。
- **修改导入端**：[tdx_parser.py](file:///c:/Users/sunck/home/projects/ios/Kline/src/tdx_parser.py#L553-L563) 的 `last_size` 增量（`fp.seek(last_size)` 只读新行）**会漏掉复权改写的历史行**，增加全量重读模式。
- **新增 PC 差分生成器**：ATTACH 新库与旧库基线，按 `file`（**不能按 meta_id**，见下）出差异行 → 差分包。
- 主库 `tdx.db` 表结构、设备侧主库读写语义**均不改动**（非 BREAKING）。

## Impact

- Affected specs: `add-live-data-auto-sync`（调度时刻、推送通道、`LocalUpdateView` 面板）、`add-conditional-orders` / 预警（`SimCondTrigger.dataReload` 触发源）
- Affected code:
  - 新增 `Kline/Data/WatchlistSymbols.swift`（6 类清单并集）、`Kline/Infrastructure/EastmoneyQuoteFetcher.swift`（东财取数）
  - 修改 [TdxSyncManager.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Infrastructure/TdxSyncManager.swift)（调度时刻）、`TdxSyncConfig.swift`（时刻表）、[LocalUpdateView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/LocalUpdateView.swift)（状态展示）
  - 修改 [LiveDataStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/LiveDataStore.swift)（差分包合并）、[KlineHTTPServer.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Infrastructure/KlineHTTPServer.swift)（合并端点复用）
  - 修改 [tdx_parser.py](file:///c:/Users/sunck/home/projects/ios/Kline/src/tdx_parser.py)（全量重读模式）
  - 新增 `TrollRestore/diff_live_patch.py`（db-diff 差分包生成）、复用 `push_bucket_usb.py`
  - 复用 `src/data/universe_secids.txt`（278 行，扩展指数 secid 覆盖表）

## ADDED Requirements

### Requirement: 清单并集

系统 SHALL 从 App 内维护的 6 类清单（自选 / 分组 / 置顶 / 预警 / 条件单 / 委托）聚合出唯一的 `file` 集合，作为自动更新与差分包的目标范围。

聚合口径：
- 自选 / 分组：`FavoritesStore` 各组 `manualMetaIDs` + 公式组 `cachedMatches` 的并集（`metaID`）
- 置顶：各组 `pinnedMetaIDs`
- 预警 / 条件单：`sim.json` 的 `conditionalOrders`（其中 `isAlertOnly` 为预警）
- 委托：`sim.json` 的 `orders`
- `metaID` / `code` → `file` 的转换 MUST 以主库 `meta` 表（`id`/`file`/`code`）为唯一基准建字典；MUST NOT 直接用 6 位 `code` 当键（主库 `code` 有 55 处重复）

#### Scenario: 空清单
- **WHEN** 用户未添加任何标的
- **THEN** 并集为空，本次拉取跳过且不报错、不写库

#### Scenario: 复权标的
- **WHEN** 某标的已除权，其历史前复权价与设备库内不一致
- **THEN** 本需求只负责当日K线；历史不一致由「差分包」需求负责（见下）

### Requirement: 设备侧东财当日K线拉取

系统 SHALL 在设备侧直接向公开行情接口请求「清单并集」标的的当日K线，MUST NOT 依赖 PC 在场。

口径 MUST 与已验证可用的生成端一致（[live_db_builder.py](file:///c:/Users/sunck/home/projects/ios/Kline/src/live_db_builder.py)）：
- 批量快照 `ulist.np/get`，每批 ≤ **100** 个 secid
- OHLC 取 `f17/f15/f16/f2`（开 / 高 / 低 / 收），量额取 `f5/f6`
- 交易日 MUST 取 `f124`（秒级 epoch）按**北京时间 UTC+8** 换算，**绝不用本机日期**
- 带 User-Agent、失败指数退避重试、`f124` 缺失时整批丢弃（不造假日K线）

secid 映射：
- `SH#` → `1.<code>`；`SZ#` / `BJ#` → `0.<code>`；`SH#999999` → `1.000001`
- `27#` / `62#` / `102#` 扩展行情指数 → 查内置覆盖表（现表 278 行；**已知缺口 25 只 `27#HS*` 恒生系**，缺失的标出并跳过）

#### Scenario: 盘中拉取
- **WHEN** 到达 11:00 / 14:30（盘中）
- **THEN** 写入的是**当日未完成K线**，UI MUST 标注「快照」语义，不得让用户误判为已收盘

#### Scenario: 收盘后拉取
- **WHEN** 到达 15:05 / 17:30
- **THEN** 写入的是当日完整K线

#### Scenario: 部分失败
- **WHEN** 某些标的在接口无数据或映射缺失
- **THEN** 成功的照常写入，失败的逐条记日志并在设置面板显示样例，不整体失败

### Requirement: 四时刻调度

系统 SHALL 在交易日北京时间 **11:00 / 14:30 / 15:05 / 17:30** 各触发一次拉取，MUST NOT 在非交易日触发。

#### Scenario: 前台依赖
- **WHEN** App 不在前台或设备锁屏（iOS 无后台能力，含 TrollStore 版）
- **THEN** 该时刻跳过，回到前台时补跑一次（沿用既有「到点补跑」语义），不静默丢失

#### Scenario: 去重节流
- **WHEN** 同一时刻被重复触发（定时 + 回前台补跑）
- **THEN** 只执行一次

### Requirement: 监控触发复用

系统 SHALL 复用既有热刷新链路触发监控，MUST NOT 新增独立触发机制。

#### Scenario: 条件单与预警重扫
- **WHEN** 东财拉取写入增量库且内容确实变化
- **THEN** `DatabaseManager.dataVersion` 自增 → `MarketRowCache` 重取受影响行 → `SimStore.sweepConditions(trigger: .dataReload)` 重扫条件单与预警，并按既有规则产生触发记录

#### Scenario: 内容无变化
- **WHEN** 拉取结果与库内一致（如重复拉取同一快照）
- **THEN** 指纹未变，不自增 `dataVersion`，不触发重扫（避免发布风暴）

### Requirement: 差分包契约

系统 SHALL 支持一种「历史重灌包」`patch_<seq>.db`，用于承载复权改写导致的历史K线覆盖，且 MUST NOT 受 `KEEP_BUCKETS`（30）限制。

- 表结构 MUST 与分片一致（`bkt_meta` / `bkt_daily` / `bkt_weekly` / `bkt_monthly`），从而设备侧合并逻辑可完全复用
- 包内 MAY 含任意多个日期（跨年亦可），同 `(file, date)` 以包内为准覆盖
- manifest MUST 增加 `patches` 数组（与 `buckets` 并列），元素含 `file` / `id` / `bytes` / `rows` / `sha256`
- 清理策略 MUST 与分片区分（分片按 30 片滚动，补丁包按最近 N 个滚动，N 可配）

#### Scenario: 复权改写覆盖
- **WHEN** 某标的 2026 年除权，其 2001~2026 全历史前复权价变化，差分包含该标的全部历史行
- **THEN** 设备合并后该标的历史价格与 PC 新库逐行一致，图表无跳空

#### Scenario: 不破坏分片滚动
- **WHEN** 差分包数量增长
- **THEN** `buckets` 仍按 30 片滚动，互不影响

### Requirement: PC 差分生成

系统 SHALL 在 PC 侧由「新库 vs 旧库基线」产出差分包，并 SHALL 保证只读打开基线库。

- 关联键 MUST 用 `file`，**MUST NOT 用 `meta_id`**：`meta_id` 是各库自增分配，跨库不可比（实测 `tdx_project/tdx.db` 的 `meta` 表按字母序重排 `id 1..3611`，而新库按导入顺序，同一标的 id 不同）
- 基线库 MUST 先通过**自洽性校验**（`meta` 表与数据表用同一套 `meta_id`）：不通过则拒绝出包并给出可操作提示，**绝不允许把假差异推给设备**（实测 `tdx_project/tdx.db` 不自洽，按 `file` 关联会产出 1231 万行假差异）
- 差异判定 MUST 覆盖 `open/high/low/close/vol/amo` 任一字段变化（复权改写典型表现为全历史价格变、量额不变）
- 新库中「基线里不存在的 `(file, date)`」MUST 计入差异（覆盖缺口补齐）
- 基线库 MUST 只读打开（`mode=ro` + `PRAGMA query_only=1`），跑完 MUST 核对 sha256 与 mtime/size 未变（沿用 `build_live_buckets_pc.py` 的硬约束）

#### Scenario: 无差异
- **WHEN** 新旧库完全一致
- **THEN** 不产出空包，打印「无差异」并正常退出

#### Scenario: 基线不自洽
- **WHEN** 基线库的 `meta` 表与数据表不使用同一套 `meta_id`
- **THEN** 校验失败、不产包、退出码非 0，并提示改用「设备已同步版本主库的整份拷贝」当基线

#### Scenario: 基线库不存在
- **WHEN** 基线库文件不存在（首次使用）
- **THEN** 明确提示需先建立基线（拷一份设备已同步的主库），或退化为「按用户指定日期范围出包」，不得静默产出全库级大包

### Requirement: 导入端全量重读

系统 SHALL 支持对 txt 源做全量重读入库，以覆盖复权改写的历史行。

现实现靠 `meta.last_size` + `fp.seek(last_size)` 只追加新行（[tdx_parser.py](file:///c:/Users/sunck/home/projects/ios/Kline/src/tdx_parser.py#L553-L563)），**复权改写的历史行会被永久漏掉**。

#### Scenario: 重建模式
- **WHEN** 以重建模式运行
- **THEN** 忽略 `last_size`、从头读全量并覆盖写入，跑完更新 `last_size` 基线

---

## MODIFIED Requirements

### Requirement: 调度时刻与状态展示（原：11:00 / 14:30 / 15:05）

原 `TdxSyncConfig` 的更新时刻为三档。修改为四档（新增 **17:30**）。

`LocalUpdateView` 的「数据同步」分区在原「云端同步状态」基础上，SHALL 增加「清单标的自动更新」子区，展示：清单并集标的数、四个时刻各自的最近执行结果（成功/跳过/失败原因）、本次请求批次数与命中数、当日最新交易日；并区分「未启用 / 已同步 / 同步中 / 失败」四种状态。

## REMOVED Requirements

无。

---

## 风险与边界

- **前台硬边界**：iOS（含 TrollStore 版）无后台能力，四个时刻任一时刻 App 不在前台即跳过，仅回前台补跑。这是本方案的硬约束，无法用代码绕过。
- **盘中快照语义**：11:00 / 14:30 写入的是当日未完成K线，会让条件单/预警基于「当前快照」触发；UI MUST 标注，避免被误认为收盘价。
- **东财为第三方公开接口**：无 SLA、可能限流或改字段。因此 MUST 保留失败降级与逐条日志；且 `17:30` 与 PC 差分通道互为兜底。
- **复权改写滞后**：设备侧东财只给当日一根（当日价即新基准原始价），历史重灌依赖 PC 差分通道。PC 不常开时，已除权标的会出现「历史 + 当日」衔接跳空，直到下一次差分推送。
- **扩展指数缺口**：`27#HS*` 恒生系 25 只不在覆盖表内，设备侧东财取不到，只能等 PC 通道（本机 vipdoc `ds/lday` 有 274/299 命中）。
- **差分包体积峰值**：分红季（5-7 月）每日重灌标的可达上百只，单包约 40~60 MB，USB/局域网单次 PUT 仍可承受（秒级），但 `/sandbox` PUT 为整包内存缓冲，MUST 关注 iPad mini 4 内存上限。
- **不引入 root 守护**：不做设备内常驻进程。