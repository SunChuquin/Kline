# Checklist

> 勾选依据：**代码级核对** 或 **本次真跑输出**（命令 stdout / 设备日志 / 核对报告可查）。
> ⚠️ 凡标「待设备解锁」的项，都是因为 `build_and_deploy.py` 返回 exit 6（iPad 锁屏未连接）而无法验证。

## 前置：干净基线（Task 0）

- [x] `tdx_baseline.db` 已从 `tdx.db`（8.28）重新复制：`meta=3611 / MAX(daily.date)=20260828 / daily=14,008,185`
- [x] 设备主库**未被改动**（仍是 9.22）
- [x] 前置自检：单包出包得 **863,627 行**（含季/年）

## 聚合语义：增量合并（Task 1）

- [x] 已核对并记录：现状 `append` 是**增量合并**、只有 `rewrite` 全量重算（原 `L501-518`）
- [x] 当期周/月/季/年四个周期是**开局一次性**确定的（`dmax=20260828` → 20260824 / 20260801 / 20260701 / 20260101）
- [x] 每个标的只对**被新数据触及的周期**取基线 bar —— 实现为 **4 条批量查询**（各命中 3611 行、共 14,444 行、约 1.3s）
- [x] 合并规则正确：`open` 取周期首行、`high/low` 取极值、`close` 取末行、`vol/amo` 累加
- [x] 基线无该周期 bar → 直接用新数据聚合（不回查基线）
- [x] 季/年线口径与 `tdx_parser.period_key` 一致（实测 `SH#600000` 季线 20260701 / 年线 20260105）
- [x] **只有 `rewrite` 才整只标的全量重算**（常态 `append` 不重算全周期）
- [x] 停牌标的（新数据为空）不产生任何 bar
- [x] `--self-check 200` 抽样验证通过（含季/年：文件级 200/0、周期级 **1000/0**）
- [x] **性能**：A 段 9.5s（首版逐标查询实现曾抬到 59.8s，已修回）

## 五张表 · 三条路径

### 差分路径（Task 2）
- [x] `build_bucket_file` 增加 `periods` 参数，**默认仍是三张表**（`inspect.signature` 已核）
- [x] 补丁包含 `bkt_quarterly` / `bkt_yearly`
- [x] 设备端 `apply-patch`（单包）与会话 `apply` 的表列表都含 `quarterly` / `yearly`
- [x] **实测**：补丁新增 **19,860 行**（季 13,726 + 年 6,134）、总体积 **78.1 MB**
- [x] **日/周/月 = 843,767 行与上一轮 patch_6 逐表完全一致**（证明单包行为等价）
- [ ] **实测**：应用后主库 `quarterly.MAX(date)`、`yearly.MAX(date)` 前移 → **待设备解锁**

### 每日路径（Task 3）
- [x] 受影响标的的当期季/年 bar 写进**增量库**（落点 `WatchlistSyncManager.handle`）
- [x] 数据源是「**主库当期 bar ⊕ 新日线**」（`currentPeriodBars`/`basePeriodBars` 一次 SQL 取主库 bar）
- [x] 当期周期允许是进行中的
- [x] 基期只取主库 → **同一交易日重复跑结果相同（幂等）**，不会重复累加 vol
- [ ] 真机验证值与手算一致 → **待设备解锁**

### 全量路径
- [x] 已核实 `tdx_parser` 产出五张表且口径一致（主库五表行数/`MAX(date)` 已核）
- [x] 文档记明「全量路径无需改代码」

## 增量库发布五张表（Task 4）

- [x] `LiveDataStore` 发布 `live_quarterly` / `live_yearly`（`periodTables` + `bucketTableMap` 已加，`slice` 不再返回 nil）
- [x] 查询层统一「live 覆盖 main」（**未改**查询层，本就按任意表名走）
- [x] 裁剪是**周期感知**的：季/年 `date < 当期日历起始`
- [x] **反证**：旧规则 `<= 20260917` 会把当期 bar 一并删掉（剩余 `[]`），新规则保留当期 ✅
- [x] 日/周/月裁剪行为**未变**
- [x] **必须的补充**：`_ensureWritableSchemaLocked` 改幂等执行 schemaSQL（否则老增量库写入会缺表整体回滚）
- [ ] 季/年线视图实际显示到 2026Q3 / 2026 → **待设备解锁**

## 设备侧会话（Task 5）

- [x] 会话使用**独立 sqlite3 连接**（`sqlite3_open_v2` + 专用串行队列，**完全不碰** `performOnDBQueue`）
- [x] `begin` → `BEGIN IMMEDIATE`；`apply?name=` → `ATTACH` + 写**五张表**；`commit` → `meta.last_date`（`MAX(...)` 防回退）+ `COMMIT` + 关连接
- [x] `rollback` 可用；失败时整体回滚（本机 SQL 序列实测：中途坏片 → meta/daily 原样）
- [x] **看门狗 120s（2 分钟）**，每次成功 `apply` 刷新计时
- [x] 文件名逐个做与 `apply-patch` 同规格的安全校验
- [x] `commit` 后 `loadMetaList()` + `notifyMainDBChanged()`
- [ ] `dataVersion` 只自增一次 → **待设备解锁**
- [x] 原单包 `POST /sync/apply-patch` **未改动语义**（仅表列表加两张）
- [x] 构建成功（v1.0.2 (379)）
- [x] **已实测并记录的一处必要偏差**：活跃事务内 `DETACH` 必失败（`SQLITE_LOCKED`）→ 改为每片唯一别名 `bkt<seq>` 保持挂载、随连接关闭释放；**N 必须 ≤ 6**（已校验）

## 设备端 APPLY 提速（Task 6）

- [x] 已在本机 1.4GB 库副本上量测（同副本 `BEGIN…ROLLBACK` ×5 取中位，避开缓存噪声）
- [x] 语义核对：命中改值 / 新日期插入 / 未命中丢弃 / 行数统计 **四项全过**
- [x] 两写法结果**逐行一致**（三表 `EXCEPT` 双向为 0）
- [x] **结论：放弃** —— `INSERT OR REPLACE` 4.825s vs 新写法 7.998s（**慢 66%**），远不满足 ≥20%
- [x] 结论与实测数字已写入 `tasks.md`；接受 21.5s 作为下界

## 大文件下载 + 手动核对（Task 7）

- [x] `GET /sandbox/<path>` 改为**流式**（1MB 分块，只占 1 块内存）
- [x] `TrollRestore/verify_main_db.py` 已写好（手动触发，含四项核对）
- [x] **流水线内不做 db 内容校验**；日志只打印标量
- [x] **503 真因已查明**：不是服务器返回的（`respond` 只有 200/400/404/500），而是本机 `HTTP_PROXY=127.0.0.1:10808`
  且 `NO_PROXY` 为空导致 `urllib` 被代理拦截 → 两个新脚本已**全局 `install_opener` 绕代理**
- [x] 核对函数已对 `tdx_baseline.db` 跑通：五表行数/`MAX(date)` 吻合、3611/3611 末日=20260828、
  缺口正报出 8.31→9.22 的 17 个交易日、取值抽查 3 只（含 rewrite `SH#600519`）**逐行一致**
- [ ] 对设备库的实拉 → **待设备解锁**

## 编排器（Task 8）

- [x] usbmux forward **只建立一次**并全程保持
- [x] forward 建立与 PC 首批出包**并发**（后台线程 + 主线程同时启动）
- [x] PC 侧 `--shards N --workers W` **并行**出包（本 spec 补做的漏列任务）：**4 片/4 worker = 15.4s**
- [x] 参数校验：`--shards 7` → `❌ 必须为 1..6`；`--workers 0`、缺 `--old-txt-dir` 均正确报错
- [x] 分片产出后**立即 PUT + 立即 apply** 的时序已实现
- [x] 全部片成功后 `commit` **一次**；清增量库 + reload 各**一次**
- [x] 失败时报进度、`rollback`、**不**清库
- [ ] 端到端真跑 → **待设备解锁**

## 实测与调参（Task 9）

- [x] **PC 侧**：单包 20.8~24.4s；**并行 4 片/4 worker 9.7~13.7s**（2× 加速）
- [x] 端到端 **N=4/W=4 = 47.3s**；**N=2/W=2 = 43.8s** → **推荐 N=2/W=2**
- [x] 分段：PC 出包 13.3s / 设备 PUT 5.2s / 设备 APPLY 12.7s / commit 约 12s
- [x] **手动全量核对通过**（拉设备主库 1389.5 MB / 79.6s）：
  daily/weekly/monthly `MAX(date)` 均 = **20260922**；3611 只末日不符 **0**；缺口 **缺 0 多 0**；取值抽查 **全部一致**
- [x] **季/年当期 bar 逐值核对 8/8 一致**（`SH#600519` / `SZ#000001` / `27#HSI` / `SZ#399001`）
- [x] 设备日志无 `SQLITE_BUSY` / 写失败；会话 4×`apply` + 1×`commit` 全 HTTP 200
- [x] 实测数字写入 `tasks.md` 与 `.trae/documents/live-sync/`

### 未达标（如实记录）

- [x] **端到端未达 spec 预期的 ~25s**：实测 43.8s（基线 57.8s → **1.32×**）。
  根因：**设备端工作量是单写者硬下界**（PUT+APPLY+COMMIT ≈ 30s），PC 出包再快也只能盖住前 10s。
  且会话式拆片后 `4×apply + commit` 比单包整笔贵约 8s。
- [x] 下一步方向（未做）：**让设备端一次提交更便宜**，而不是继续加并行度。
- [x] **`verify_main_db.py` 的 ① 判据有误**（用 `quarterly/yearly` 的 `MAX(date)` 前移判断是否更新）——
  当期 bar 是**原地更新**、`date` 不变，故 MAX 不变属正常。已在 `tasks.md` 与本文档标注，避免后续误导。

## 硬约束回归

- [x] **分片契约未变**：`build_bucket_file` 默认 `periods=('daily','weekly','monthly')`；
  传入含季/年的 rows 用默认参数建库，结果仍只有 `bkt_daily/bkt_meta/bkt_monthly/bkt_weekly`
- [x] 增量库「同一 date 以增量库为准」的合并规则未变（只是新增两张表参与）
- [x] 单包路径（`--shards 1` + `apply-patch`）行为不变（日/周/月行数与 patch_6 逐表一致）
- [x] `MainDBMerger` **未改动**（故 live 季/年暂不回写主库，已在 tasks.md 标注）
- [x] PC 侧对基线库只读打开；跑完 `(size, mtime)` 复核未变
- [x] `meta.last_date` 防回退的 `MAX(...)` 兜底仍在（会话 `commit` 里也有）

## 待用户确认

1. 打开 Kline：自选/K线图应显示到 **20260922** 且**未重启**（增量库已清，走纯主库）
2. **切到季线/年线视图**：应能看到当期 bar 已含 9/22（设备库里 `SH#600519` Q3 `close=1253.8` 已核对一致）
3. 触发一次**每日定时更新**，再切季线/年线，确认当期 bar 随当日数据更新
4. 是否继续投入「让设备端一次提交更便宜」——这是唯一还能显著压低端到端的方向
5. 是否要单独立项 `POST /sync/replace-main`（取代已退役的手动导入按钮）