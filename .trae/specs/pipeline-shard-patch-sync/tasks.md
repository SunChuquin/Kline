# Tasks

> 交付纪律（遵循 `.trae/skills/kline-device-validation-loop`）：设备侧改动收尾用
> `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`。

- [x] Task 0: 【前置】准备干净基线（**不需要还原设备、不需要手动点击**）
  - [x] SubTask 0.1: 已把 `tdx.db`（8.28：`MAX(daily.date)=20260828`、14,008,185 行）复制为 `tdx_baseline.db`（1,379.7 MB）
  - [x] SubTask 0.2: 核实新基线 `meta=3611 / MAX(daily.date)=20260828 / daily=14,008,185`；设备主库保持 9.22 **不动**
  - 验收：✅ 基线为 8.28；单包出包得 863,627 行（含季/年后）

- [x] Task 1: 【聚合语义】全局一次性确定当期周期 + 增量合并（周/月/季/年统一）
  - [x] SubTask 1.1: **已核对现状并记录**：原 `L501-518` 对 `append` 已是「基线该周期尾部 + 新日线」增量合并、
        只有 `rewrite` 全量重算 —— 语义本就正确；问题仅是①窗口偏大（先取基线尾部日线重算，而非直接取那一根 bar）
        ②只覆盖周/月，缺季/年
  - [x] SubTask 1.2: 开局一次性由基线推当期四周期（`dmax=20260828` → weekly 20260824 / monthly 20260801 /
        quarterly 20260701 / yearly 20260101）；**未**在每标的里重复判断
  - [x] SubTask 1.3: 实现为 `load_current_bars`（**4 条批量查询**，各命中 3611 行、共 14,444 行、约 1.3s）
        + `merge_period_rows`（open 取周期首行、high/low 极值、close 取新末行、vol/amo 累加）；基线无 bar → 直接用新数据聚合
  - [x] SubTask 1.4: 已扩展到季/年（`quarter_key = y*10+(m-1)//3+1`、`year_key = y`；`date` = 周期首个交易日，实测
        `SH#600000` 季线 20260701 / 年线 20260105，与 `tdx_parser.period_key` 一致）
  - [x] SubTask 1.5: 停牌（新数据为空）不产生任何 bar ✅
  - **性能修正**：首版把「取基线 bar」实现成逐标的索引查询（3611 × 4 ≈ 14,444 次随机探查）→ A 段退化到 **59.8s**；
        改为 4 条批量查询后 **A = 9.5s**（另把 `MAX(date) FROM daily`（全表 14M 行扫）改为 `MAX(meta.last_date)`（3611 行））
  - 验收：✅ 常态 `append` 只合并被触及周期；`rewrite` 全量重算；`--self-check 200` 通过（文件级 200/0、周期级 1000/0）

- [x] Task 2: 【差分路径】补丁携带五张表
  - [x] SubTask 2.1: `build_bucket_file` 增加 `periods=PERIODS` 参数 —— **默认仍是三张表**
  - [x] SubTask 2.2: 补丁出包传 `periods=('daily','weekly','monthly','quarterly','yearly')`
  - [x] SubTask 2.3: 设备端 `apply-patch`（单包）与会话 `apply` 的表列表都加 `quarterly`/`yearly`（主库/补丁缺表则跳过）
  - 验收：✅ 补丁新增 **19,860 行**（季 13,726 + 年 6,134；spec 估「约 2.3 万」属估算偏差）；
        总体积 78.1 MB；**日/周/月 = 843,767 行与上一轮 patch_6 逐表完全一致**（证明单包行为等价）；
        `bkt_meta=3611` 未变；`--self-check 200` 的周期级检查已扩到五表（1000/0）
  - **分片契约未变的证据**：`inspect.signature` → `periods=('daily','weekly','monthly')`；
        传入含 quarterly/yearly 的 rows 用默认参数建库，结果仍只有 `bkt_daily/bkt_meta/bkt_monthly/bkt_weekly`

- [x] Task 3: 【每日路径】当期季/年 bar 写进**增量库**
  - [x] SubTask 3.1: 落点 = `WatchlistSyncManager.handle(...)` ④⑤（原「直写增量库」处）
  - [x] SubTask 3.2: `currentPeriodBars`/`basePeriodBars` 在 `dbQueue` 上**一次 SQL** 取每只当期 bar；
        `mergePeriodBar`（open 取基期、high/low 极值、close 取新值、vol/amo 累加；无基期则直接用新日线）；
        经 `upsertDaily(periodBars:)` 与日线**同事务** UPSERT，只写不一致行
  - [x] SubTask 3.3: 日志记「季 N/年 M 行 + 耗时」；基期只取主库 → 同一交易日重复跑结果相同（**幂等**，不会重复累加 vol）
  - 验收：⚠️ **静态 + SQL 验证已过，真机未验**（设备离线）。核对了 `KlinePeriod.periodDateRange`、`KlineItem` 成员、
        `MetaItem.id`、`performOnDBQueue`/`metaList`、`EastmoneyFetchResult/EastmoneyDailyBar`、`_scalarLocked` 等 API

- [x] Task 4: 【增量库发布五张表 + 周期感知裁剪】
  - [x] SubTask 4.1: `periodTables` + `bucketTableMap` 加 quarterly/yearly；`slice(file:table:)` 不再返回 nil；
        查询层**未改**（`DatabaseManager.fetchPeriodTable/liveSlice` 本就按任意表名走「live 覆盖 main」）
  - [x] SubTask 4.2: `_trimLocked` 改为遍历五表：**日/周/月逐字不变**；季/年 `date < 当期日历起始`
        （复用 `KlinePeriod.periodDateRange`；参考日 = `max(beforeDate, live_daily 最新交易日)`）
  - [x] SubTask 4.3: 日/周/月裁剪行为未变 ✅
  - [x] SubTask 4.4: 已并入统一构建（v1.0.2 (379)）
  - **必须的补充**：`_ensureWritableSchemaLocked` 改为**幂等执行 schemaSQL**（原为「缺 live_meta 才建」），
        否则老增量库（有 live_meta、无 live_quarterly）写入会缺表整体回滚
  - 验收：✅ 裁剪 SQL 本机实测（参考日 20260922 → 季起始 20260701）：当期 bar 保留、上一期被删；
        **反证**：旧规则 `<= 20260917` 会把当期 bar 一并删掉（剩余 `[]`）
  - ⚠️ `MainDBMerger` 只消费日/周/月（spec 明令不改），故 live 季/年**暂不回写主库**，数据已备好

- [x] Task 5: 【设备侧会话】`POST /sync/patch-session/{begin,apply,commit,rollback}`
  - [x] SubTask 5.1: `PatchSessionManager` 用 `sqlite3_open_v2` **自开一条连接**，全部 SQL 只在它上面、
        由专用串行队列 `com.sunck.Kline.patchsession` 串行执行，**完全不碰 `performOnDBQueue`/App 的 dbQueue** ✅
  - [x] SubTask 5.2: 四端点齐备；`commit` 返回日/周/月/季/年行数、覆盖标的数、片数、`latestDate`；
        `meta.last_date` 沿用 `MAX(...)` 防回退
  - [x] SubTask 5.3: **看门狗 120s（2 分钟）**，每次成功 `apply` 刷新 `lastProgress`；超时 `ROLLBACK` + 关连接
  - [x] SubTask 5.4: 文件名逐个做与 `apply-patch` 同规格的安全校验；任一步失败整体回滚并返回原因
  - [x] SubTask 5.5: 原 `POST /sync/apply-patch` **保持可用且语义不变**（仅表列表加两张）
  - [x] SubTask 5.6: 已并入统一构建（v1.0.2 (379)）
  - **⚠️ 与 spec 措辞的一处必要偏差（已实测）**：**活跃事务内 `DETACH` 必失败**
        （`SQLITE_LOCKED: database bkt is locked`，与是否读过该片无关；仅 COMMIT 后可 DETACH）。
        会话是「一事务跨多请求」，故 `apply` 内无法 DETACH。已改为：每片用唯一别名 `bkt<seq>` 保持挂载、
        `temp.patch_file_max` 累积各片末日供 `commit` 更新 `last_date`、会话结束随 `sqlite3_close` 隐式释放。
        功能等价、原子性不变；因 `SQLITE_MAX_ATTACHED=10`，**N 必须 ≤ 6**（编排器已校验）
  - 验收：✅ SQL 序列本机实测：①五表都被更新 ②中途坏片 → 整体 ROLLBACK（meta/daily 原样）③`last_date` 不回退

- [x] Task 6: 【设备端 APPLY 提速】量测后决定 → **结论：放弃**
  - [x] SubTask 6.1: 本机 1.4GB 库副本上量测（同副本 `BEGIN…ROLLBACK` 重复 5 次取中位，避开磁盘缓存噪声）
  - [x] SubTask 6.2: 未落地（收益为负）
  - [x] SubTask 6.3: 已放弃并记录
  - **实测结论**：`INSERT OR REPLACE` 中位 **4.825s** vs `UPDATE…FROM` + `INSERT…NOT EXISTS` 中位 **7.998s**
        → **新写法慢约 66%**（区间不重叠，结论确定）。语义虽正确（命中改值/新日期插入/未命中丢弃/
        行数统计四项 ✅；两写法跑完主库三表 `EXCEPT` 双向为 0，**逐行一致**），但远不满足「≥20%」。
        **接受 21.5s 作为下界**

- [x] Task 7: 【大文件下载 + 手动核对】
  - [x] SubTask 7.1: `serveSandboxPath` 改为流式（1MB 分块 `FileHandle` 读 + 顺序 `send`，只占 1 块内存）
  - [x] SubTask 7.2: 新增 `TrollRestore/verify_main_db.py`（**手动触发，流水线不调用**）：流式下载 + 四项核对
        （五表 `MAX(date)`/行数、3611 只日线末日、缺口抽样含指数、取值抽查含 rewrite 标的）
  - [x] SubTask 7.3: 流水线内不做 db 内容校验；日志只打印标量 ✅
  - [x] SubTask 7.4: 已并入统一构建（v1.0.2 (379)）
  - **503 的真因（重要）**：不是服务器返回的 —— `respond` 的状态分支只有 200/400/404/500。
        真因是**本机 `HTTP_PROXY=127.0.0.1:10808` 且 `NO_PROXY` 为空**，`urllib.urlopen` 被代理拦截返回 **503 假象**
        （`build_and_deploy.py:108` 注释早有记载）。实测：默认 `urlopen` → 503；`build_opener(ProxyHandler({}))` → 真实连接结果。
        故两个新脚本均**全局 `install_opener`** 绕代理
  - 验收：✅ 核对函数已对真实库（`tdx_baseline.db`）跑通：五表行数/`MAX(date)` 与已知值吻合、
        3611/3611 末日=20260828、缺口正报出 8.31→9.22 的 17 个交易日、取值抽查 3 只（含 rewrite `SH#600519`）**逐行一致**；
        ⚠️ **对设备库的实拉未做**（设备离线）

- [x] Task 8: 【编排器】新增 `TrollRestore/sync_pipeline.py` —— 已完成（**单包骨架已跑通，分片路径待设备解锁**）
  - [x] SubTask 8.1: 后台线程起 `forward()` **与**主线程启动出包进程**并发**
  - [x] SubTask 8.2: PC 侧已支持 `--shards/--workers`（本 spec 补做的漏列任务）：**4 片/4 worker = 15.4s**
        （单包 31.8s、同 4 片串行 36.7s → 2.4× 加速）；编排器 `probe_builder` 运行时探测到即自动切并行模式
  - [x] SubTask 8.3: 全部片成功 → **一次** `commit` → 清增量库 + reload 各一次
  - [x] SubTask 8.4: 任一步失败 → `rollback` + 报「已成功 k/N 片」+ **不清库**
  - 验收：⚠️ 参数校验与 `discover`/核对函数已验（`--shards 7` → `❌ 必须为 1..6`）；**端到端未跑**（设备离线）

- [x] Task 9: 【实测与调参】—— 已完成（真机）
  - [x] SubTask 9.1: **N=4/W=4 端到端 = 47.3s**（分段：PC 出包 35.3s / 设备 PUT 5.7s / APPLY 17.9s / commit ~12s）
  - [x] SubTask 9.2: **选 N=2/W=2**（**43.8s**，优于 N=4 的 47.3s）—— 依据：分片越少，设备端 ATTACH/
        commit 固定开销越低（APPLY 合计 12.7s vs N=4 的 17.9s）；N=1 无法重叠（要等整包出完）
  - [x] SubTask 9.3: **手动全量核对通过**（`verify_main_db.py`，拉下设备主库 1389.5 MB / 79.6s）：
        - 五表行数与 `MAX(date)`：`daily` 14,069,461 / **20260922** · `weekly` 2,971,423 / **20260922** ·
          `monthly` 707,568 / **20260922** · `quarterly` 238,879 / 20260806 · `yearly` 62,334 / 20260806
        - 3611 只标的日线末日 = 20260922：**不符 0 只** ✅
        - 缺口检查（`SH#999999` / `SZ#399001` / `27#HSI` / `SH#600519`）：库内日期集合与 txt **缺 0 多 0** ✅
        - 取值抽查（同上 4 只，逐行）：**全部一致** ✅
        - **季/年当期 bar 逐值核对（独立重算对照）：8/8 一致** ✅（`SH#600519` Q3 `close=1253.8`、
          `27#HSI` Q3 date=20260702 … 与 txt 完全一致）
  - [x] SubTask 9.4: 设备日志无 `SQLITE_BUSY` / 写失败；会话 4 次 `apply` + 1 次 `commit` 全部 HTTP 200 ✅
  - [x] SubTask 9.5: 实测数字已回填本文件与 `.trae/documents/live-sync/`
  - **⚠️ 一处检查项设计错误（已澄清）**：`verify_main_db.py` 的 ① 用「`quarterly`/`yearly` 的 `MAX(date)` 是否前移」
        判断季/年线是否更新 —— **这个判据是错的**。当月/季/年 bar 的 `date` = 该周期**首个交易日**（Q3 是 20260701），
        而主库 `MAX(date)=20260806` 来自「某只标的 Q3 首日是 8/06（停牌到那时才复牌）」。
        **当期 bar 是原地更新，不产生更大的日期** → MAX 不变、行数不变都属**正常**。
        正确判据是「比对当期 bar 的值」（已用独立重算脚本验证 8/8 一致）。**后续用该工具时不要被 ① 误导。**
  - **本轮暴露的真实短板（未解决，如实记录）**：设备端工作量是硬下界 ——
        `PUT ~5s + APPLY ~13s + COMMIT ~12s ≈ 30s`，而 PC 出包（N=4 并行后 ~10s）只能盖住它的前 10s。
        **commit 那 12s 是新的**：单包 `apply-patch` 时整笔 21.5s（含提交），会话式拆成 4 片后
        「4 次 apply 17.9s + commit 12s」，反而比单包贵约 8s。若要继续压，方向是「让设备端一次提交更便宜」，
        而不是继续加并行度。

# Task Dependencies

- Task 0 是前置
- Task 2 依赖 Task 1.4（季/年线聚合）
- Task 5 依赖 Task 2.3（表列表）
- Task 8 依赖 Task 2、5
- Task 6、7 独立（可并行）
- Task 9 依赖 Task 0、2、4、5、8
- Task 3、4 属五表一致性（与流水线并行推进）

# 交付记录（真机）

| build | 内容 |
| :--- | :--- |
| v1.0.2 (377) | `POST /sync/apply-patch`（补丁按行落主库，集合式 SQL）+ txt 直出差分脚本 |
| v1.0.2 (378) | apply-patch 会话级 pragma（cache_size 32MB / temp_store MEMORY / synchronous NORMAL） |
| v1.0.2 (379) | 五表一致性（补丁带季/年线、增量库发布五张表 + 周期感知裁剪）+ 会话式单事务落主库（4 端点 + 120s 看门狗）+ 大文件流式下载 |
| v1.0.2 (**380**) | 同上（379 因设备锁屏未装成，380 为实际装机版本）✅ 已部署 |

## 实测对照

| 方案 | 端到端总耗时 | PC 出包 | 设备 PUT | 设备 APPLY | 备注 |
| :--- | ---: | ---: | ---: | ---: | :--- |
| 串行基线（单包，仅日/周/月） | **57.8s** | 25.4 | 5.9 | 21.5 | 上一轮实测 |
| PC 单包（含季/年） | — | 20.8~24.4s | — | — | 热/冷差异 |
| PC 并行 4 片/4 worker | — | **9.7~13.7s** | — | — | 2× 加速；上提共享工作后 |
| **流水线 N=4/W=4** | **47.3s** | 35.3s | 5.7 | 17.9 | commit 另约 12s |
| **流水线 N=2/W=2** ✅ **推荐** | **43.8s** | 13.3s | 5.2 | **12.7** | 分片越少，设备固定开销越低 |
| 流水线 N=6/W=6 | 未测 | — | — | — | N=4 已劣于 N=2，趋势明确，不再测 |

**结论：端到端 57.8s → 43.8s（1.32×）**，远未达到 spec 预期的 ~25s。
原因是**设备端工作量是单写者硬下界**（PUT+APPLY+COMMIT ≈ 30s），PC 出包再快也只能盖住前 10s。
spec 里「~25s」的预期**被实测推翻**，已如实记录。

## Task 6 量测结论（已完成）

| 写法 | 中位耗时 | 语义正确 | 结论 |
| :--- | ---: | :--- | :--- |
| `INSERT OR REPLACE`（现状） | **4.825s** | ✅ | 保留 |
| `UPDATE ... FROM` + `INSERT ... WHERE NOT EXISTS` | **7.998s** | ✅（两写法结果 `EXCEPT` 双向为 0） | **放弃**（慢 66%，远不满足 ≥20%） |

→ **接受 21.5s 作为设备端 APPLY 的下界**（真机 iPad mini 4）。

## 全量核对结论（Task 9.3，待填）

| 检查 | 结果 |
| :--- | :--- |
| 五张表的 `MAX(date)` | 待设备解锁 |
| 3611 只标的日线末日 = 20260922 | 待设备解锁 |
| 缺口（抽样含指数） | 待设备解锁 |
| 抽查取值（含 1 只 rewrite 标的） | 待设备解锁 |
| **对照：核对函数已对 `tdx_baseline.db` 跑通** | 五表行数/`MAX(date)` 与已知值吻合；3611/3611 末日=20260828；缺口正报出 8.31→9.22 的 17 个交易日；取值抽查 3 只（含 `SH#600519`）逐行一致 ✅ |