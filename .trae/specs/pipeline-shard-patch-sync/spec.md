# 补丁流水线（并行出包 + 会话式单事务）+ 五表全路径一致性 Spec

## Why

两件事：

1. **性能**：端到端 **57.8s**，距 60s 只剩约 **2s** 余量（PC 侧 A 段冷缓存实测 16.2s vs 热 8.1s）。
   根因是各阶段严格串行：`PC 出整包 25.4s → 建 USB 4.1s → PUT 5.9s → 设备 UPSERT 21.5s → 清库 0.5s`。
2. **五表一致性遗漏**：主库有五张周期表，但**三条更新路径里只有「全量重建」会让季/年线跟上**。
   差分路径只带日/周/月；每日定时路径只写增量库。→ 季线/年线视图长期滞后。

## 关键实测（2026-09-23，本机 + 真机）

| 事实 | 结论 | 怎么验的 |
| :--- | :--- | :--- |
| **`ATTACH` 在事务内可行** | 单事务与分片不冲突 | 本机 sqlite3 3.40.1：`BEGIN IMMEDIATE` → 写 → `ATTACH` 下一片 → 继续写 → `COMMIT` 全部成功 |
| **主库是 WAL** | 长写事务**不阻塞读** | `PRAGMA journal_mode` = `wal` |
| **单个 HTTP 请求开销可忽略** | 「开事务 → 多请求喂片 → 提交」不会白花时间 | 实测 `GET /sync/status` 0.0s、`POST /sync/reload` 0.0s、`DELETE /sandbox/...` 0.5s |
| 设备端 APPLY | **21.5s**（84 万行），单写者串行 | 真机实测 |
| 补丁规模（日/周/月） | 843,767 行 / 76.3 MB / 3611 只 | 真机实测 |
| **大文件下载不可用** | `GET /sandbox/tdx.db`（1.4GB）返回 **503**；AFC pull 因 TrollStore 容器隔离失败 | 真机实测 |
| 本机 | 6 逻辑核 / 73 GB 空闲 | — |

### 遗漏实证

主库季/年线停在旧值：`quarterly` 238,879 行 `MAX=20260806`、`yearly` 62,334 行 `MAX=20260806`
（而 `daily`/`weekly` 已到 20260828）。App 的季/年线视图**回落读主库**，所以视图里最后一根季线还是 `20260701`。

**并且**：`LiveDataStore.swift:945` 的裁剪只列了 `["daily","weekly","monthly"]`，
说明「季/年线不发布」**不是**存储模型的必然——当初的理由（有限窗口）**不成立**：
生产端（PC 分片生成器 / 设备侧每日路径）**都能拿到基线/主库**，足以算出正确的当期 bar。

## What Changes

**核心原则：五张周期表在任何一条更新路径上都要最新；聚合一律用「增量合并」而非整周期重算。**

- **聚合语义（三条路径统一）**：
  - 开局**一次性**由「基线/主库的最大交易日」推出**当期**周/月/季/年四个周期（不是每个标的分头判断）
  - 每个标的只对**被新数据触及的周期**做一次**索引范围查询**，取出基线/主库那一根 bar，与新日线**合并**
    （`open` 取周期首行、`high/low` 取极值、`close` 取末行、`vol/amo` 累加）
  - 若被触及的周期在基线里**没有** bar → 直接用新数据聚合
  - **只有 `rewrite`（除权改写）标的**才整只标的所有周期全量重算
  - 停牌标的：新数据为空 → 无新 bar → 不需动（其基线 bar 若落在当期，合并同样正确）
- **五张表落到三条路径**：
  - 差分路径：补丁携带 `bkt_quarterly` / `bkt_yearly`（PC 端用基线算出正确的当期 bar）
  - 每日定时路径：把当期季/年 bar 写进**增量库**（设备端用主库 bar ⊕ 新日线合并）
  - 全量重建路径：`tdx_parser` 已产出五张表 → **只验证，不改代码**
- **增量库（分片）也承载五张表**：`LiveDataStore` 不再对季/年线返回 nil，查询层统一「live 覆盖 main」
- `src/txt_patch_builder.py`：季/年线 + `--shards N` / `--workers W`
- **设备侧会话式落库**（独立 sqlite3 连接）：`/sync/patch-session/{begin,apply,commit,rollback}` + **120s 看门狗**
- **设备端 APPLY 提速实验**：`INSERT OR REPLACE` → `UPDATE ... FROM` + `INSERT ... WHERE NOT EXISTS`，先本机量测
- **修大文件下载**：`GET /sandbox/<path>` 支持 1.4GB 流式
- 新增 `TrollRestore/sync_pipeline.py`（编排器）与 `TrollRestore/verify_main_db.py`（**手动**全量核对）

## Impact

- Affected specs: `apply-patch-into-main-db`、`add-live-data-auto-sync`、`add-watchlist-intraday-sync`
- Affected code:
  - `Kline/src/live_db_builder.py`（`build_bucket_file` 加 `periods` 参数）
  - `Kline/src/txt_patch_builder.py`（季/年线增量合并 + `--shards`/`--workers`）
  - `Kline/Infrastructure/KlineHTTPServer.swift`（会话端点、表列表、大文件下载、可能的 SQL 优化）
  - `Kline/Data/LiveDataStore.swift`（发布五张表；裁剪改为**周期感知**）
  - `Kline/Data/`（每日路径把当期季/年 bar 写进增量库；落点实现时定位）
  - 新增 `TrollRestore/sync_pipeline.py`、`TrollRestore/verify_main_db.py`
  - **不改**：`MainDBMerger`

## ADDED Requirements

### Requirement: 五张周期表在所有更新路径上都最新

系统 SHALL 保证 `daily` / `weekly` / `monthly` / `quarterly` / `yearly` 在任何一条更新路径后都反映最新数据。

- **差分路径**：补丁 MUST 携带 `bkt_quarterly` / `bkt_yearly`；设备端 `apply` 的表列表 MUST 含这两张（主库缺表则跳过）
- **每日定时路径**：MUST 把当期季/年 bar 写进**增量库**
- **全量重建路径**：SHALL 只做验证（`tdx_parser` 已产出五张表），不改其逻辑
- 聚合口径 MUST 与 `tdx_parser.period_key` 一致：季 `YYYYQ`、年 `YYYY`；`date` = 该周期**首个交易日**

#### Scenario: 季/年线不再滞后（差分路径）
- **WHEN** 补丁应用后查主库
- **THEN** 3611 只标的的 `quarterly.MAX(date)` 与 `yearly.MAX(date)` 均前移（不再停在 20260806）

#### Scenario: 季/年线不再滞后（每日路径）
- **WHEN** 每日定时更新跑完
- **THEN** 增量库里受影响标的的当期季/年 bar 已含当日数据；季/年线视图（live 覆盖 main）显示到当期

### Requirement: 增量合并而非整周期重算

系统 SHALL 用「基线/主库已有 bar ⊕ 新日线」的方式得到周期 bar，**不得**为更新一根 bar 而重算整周期日线。

- 开局 SHALL **一次性**确定当期周/月/季/年四个周期（依据：基线/主库的最大交易日），**不得**在每个标的里重复判断
- 每个标的只对**被新数据触及的周期**做一次索引范围查询取基线 bar
- **仅 `rewrite`（除权改写）标的** SHALL 整只标的所有周期全量重算
- 触及的周期在基线里没有 bar → 直接用新数据聚合

#### Scenario: 常态增量（append）
- **WHEN** 某标的只追加了新交易日
- **THEN** 只重算被触及的 1~2 个周期 bar，其余周期 bar 不动、不进包

#### Scenario: 除权改写（rewrite）
- **WHEN** 某标的的前复权因子变化
- **THEN** 该标的所有周期全量重算并与基线逐行比对，只发真正不同的行

#### Scenario: 停牌标的
- **WHEN** 某标的本期无新数据
- **THEN** 不产生任何周期 bar（不会漏、也不会错）

### Requirement: 增量库承载五张表

`LiveDataStore` SHALL 发布 `live_quarterly` / `live_yearly`（不再对季/年线返回 nil），查询层统一「live 覆盖 main」。

- 分片生成器 SHALL 用基线算出**正确的当期**季/年 bar（不是只用窗口内几天）
- 裁剪 MUST 改为**周期感知**：季/年线只保留**当期**（`date >= 当期起始`），
  避免旧周期 bar 长期留在增量库、在后续主库更新后**遮蔽**主库的正确值
- 主库被更新后 MUST 清空增量库（现有编排器已做），避免 live 行比 main 陈旧

#### Scenario: 视图统一
- **WHEN** 查季/年线
- **THEN** 走与日/周/月相同的「live 覆盖 main」路径，当期 bar 来自 live（正确合并值），历史 bar 来自 main

#### Scenario: 裁剪不误删当期
- **WHEN** 裁剪运行
- **THEN** 当期季/年 bar（date = 当期首个交易日，远早于最近 N 个交易日）**不被删**；更早的周期 bar 被删

### Requirement: 分片并行出包

系统 SHALL 支持 `--shards N` / `--workers W`，每个 worker 独立完成自己那份的「分类+解析+比对+出包」并写自己的文件。

- 各份 `file` 集合**两两不交**、**并集 = 全部待处理标的**
- 每份表结构与契约与单包**逐字一致**
- `--shards 1` MUST 与现状**行为与耗时等价**

#### Scenario: 不重不漏
- **WHEN** `--shards 4`
- **THEN** 4 份 `bkt_meta.file` 并集 = 3611、两两交集为空、行数之和 = 单包

### Requirement: 会话式单事务落主库

系统 SHALL 提供会话端点，用**一条独立 sqlite3 连接**跨多个 HTTP 请求保持一个事务，使设备落库与 PC 出包**完全重叠**。

- **连接隔离是硬要求**：MUST 用独立连接，MUST NOT 在 App 的共享主库连接上开事务（否则 App 期间的写会被静默卷进我们的事务）
- 会话期间 SHALL 保持 `BEGIN IMMEDIATE ... COMMIT`；`apply` 逐个 `ATTACH` + 写**五张表** + `DETACH`
- `commit` SHALL 先更新 `meta.last_date`（`MAX(...)` 防回退）再 `COMMIT`，随后关连接 + `loadMetaList()` + `notifyMainDBChanged()`
- 任一步失败 MUST 整体 `ROLLBACK` 并关连接；**看门狗 120s（2 分钟）**无进展自动 `ROLLBACK` + 关连接
  - 取 2 分钟而非更短：PC 侧单分片出包在冷缓存下可能到十几秒，设备端单分片写入也可能到十几秒，
    30s 会在「正常但慢」的情况下误杀会话；2 分钟给足余量，同时仍能兜住真正被遗弃的会话
  - 代价（如实说明）：会话被遗弃时写锁最长被占 2 分钟，期间其它写操作拿 `SQLITE_BUSY`
- 单包 `POST /sync/apply-patch` MUST 保持可用且语义不变

#### Scenario: 完全重叠
- **WHEN** N=4：PC 出第 i+1 片的同时，设备正在 apply 第 i 片
- **THEN** 总耗时 ≈ max(PC 出包, PUT + APPLY) + 填充，显著低于 57.8s

#### Scenario: 中途失败 / 会话被遗弃
- **WHEN** 第 3 片 apply 失败，或 `begin` 后 120s 内无 `apply`
- **THEN** 前者 `ROLLBACK` 全部；后者看门狗自动回滚关连接释放写锁

### Requirement: 设备端 APPLY 提速（量测后决定）

系统 SHALL 在本机 1.4GB 库副本上量测 `UPDATE ... FROM` + `INSERT ... WHERE NOT EXISTS` 相对 `INSERT OR REPLACE` 的收益，
**仅当收益 ≥20% 且语义正确**才落地。

- 量测 MUST 覆盖：主键命中改值、新日期插入、未命中 file 被丢弃、行数统计正确
- 收益不足 20%，或出现**读写失败 / 未写成功**等任何问题 → **放弃并记录结论**，接受 21.5s 作为下界

### Requirement: 设备主库可被拉取用于验证（修大文件下载）

系统 SHALL 支持把设备主库（1.4GB）完整下载到 PC，用于**手动**核对。

- `GET /sandbox/<path>` MUST 流式返回大文件（当前 1.4GB 返回 503）
- **验证 MUST NOT 由流水线自动触发**（只提供手动入口 `TrollRestore/verify_main_db.py`）
- 流水线日志**只允许打印标量**（行数/耗时），MUST NOT 写库内容

## MODIFIED Requirements

### Requirement: 季/年线查询回落主库（原设计）

**原行为**：`LiveDataStore` 对季/年线返回 nil，视图回落主库。
**改为**：增量库发布五张表，查询统一「live 覆盖 main」。
**理由**：原设计的前提「有限窗口算不出完整周期」不成立——生产端有基线/主库可用。

### Requirement: 端到端流程（原：出包 → push_bucket_usb --apply-main）

原四步串行流程保留可用；新增编排器路径为其**并行加速版**，补丁内容、落库方式、清增量库语义不变。

## REMOVED Requirements

无。

## 测试前置：**不需要还原设备**

设备当前是 9.22，生成端只需一份**干净的 8.28 基线**：
把 `C:\Users\sunck\home\tdx.db`（**已核实仍是 8.28**）复制为 `tdx_baseline.db`（上一轮被写成了 9.22）。

`INSERT OR REPLACE` 无论值是否相同都会改写页 → 把 8.28→9.22 的补丁应用到 9.22 的设备上，**工作量与计时完全相同**。
无需 1.38GB 整库上传、无需重启、无需手动点击。

**正确性验证**：用 `verify_main_db.py` 把设备主库**全量拉下来**核对（五张表 `MAX(date)`、3611 只末日、缺口、抽查取值）。

## 预期收益（须实测）

| 项 | 现状 | 流水线后 |
| :--- | ---: | ---: |
| PC 出包（`--workers 4`） | 25.4s | **~8s** |
| USB 建立 + PUT | 4.1 + 5.9s | **藏在 PC 窗口内** |
| 设备 APPLY（与 PC 完全重叠） | 21.5s | 重叠后只暴露尾部 |
| **合计** | **57.8s** | **~25s**（Task 6 提速有效则 ~18s） |

## 风险与边界

- **长事务窗口（~25s）**：期间其它写操作（`MainDBMerger` 手点）会拿 `SQLITE_BUSY`；WAL 下读不受影响。Task 8 要观察日志。
- **增量库发布季/年线是查询层改动**（`LiveDataStore` + 裁剪规则），比原设计动的地方多，必须靠 Task 8 的全量核对兜住。
- **周期感知裁剪**：必须保证「当期 bar 不被删、旧周期 bar 被删」，否则旧 bar 会遮蔽主库正确值。
- **PC 并行边界**：真争用只有磁盘 I/O；若加速不明显，回退 `--workers 1`。
- **不改**：`MainDBMerger`、`meta.last_date` 的语义。