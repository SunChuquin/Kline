# 单源腾讯化 + 移除云端分片 —— 分阶段计划

## Context（为什么做）

用户决策（2026-10-16）：
1. **设备侧清单日更改腾讯**（不再直连东财）；
2. **删除云端分片链路**（代码 + 文档）——云端生成端容易被行情源按 IP 封锁，已弃用；
3. 同步更新**文档与项目记忆**。

触发点：真机日志里清单日更持续 `[EMQuote] HTTP 502`，用户问「为什么还有东财接口，我现在只用腾讯源了」。

## 现状审计（三层）

### 代码——东财仍活跃 2 处
| 位置 | 角色 | 归属 |
| :--- | :--- | :--- |
| `Kline/Infrastructure/WatchlistSyncManager.swift:123-124` | 清单日更编排，调 `EastmoneyQuoteFetcher.fetch` | **删** |
| `Kline/Infrastructure/EastmoneyQuoteFetcher.swift`（全文，481行） | `push2.eastmoney.com/ulist.np/get` 批量快照 | **删** |
| `Kline/PyScripts/quote_parse.py` `em_snapshot`(L24-29,138-)、`secid`(L52-54,319-351) | 东财快照解析 + secid 映射（Python 优先通道） | **删**这两 op |
| `Kline/Resources/universe_secids.txt`（278 行）+ `src/data/universe_secids.txt` | 东财 secid 覆盖表 | **删** |
| `src/live_db_builder.py:136/141/1150` | `push2his.eastmoney.com` + `push2.eastmoney.com/ulist.np/get`，`source="eastmoney"` | **删**（云端分片生成端） |
| `.github/workflows/sync-live-db.yml` | 云端定时产出分片 | **删** |
| `Kline/Infrastructure/TdxSyncManager.swift:340-372 / 403-487 / 503-575 / 577-629` | manifest 同步 / 分片下载 / 补丁 / 收尾 | **删**（**保留** L236-281 四时刻调度与触发） |
| `Kline/Profile/LocalUpdateView.swift` | 分片区 + 清单日更状态面板 | 改写 / 删区 |
| `KlineTests/QuoteParsingContractTests.swift`、`PyBridgeQuoteParsingTests.swift`、`Fixtures/quote_parsing.json`、`secid_mapping.json` | 东财契约测试与夹具 | **删**东财相关用例 |

### 已单源腾讯（保留）
- `Kline/Infrastructure/GapBackfill.swift`（补缺口；提交 `3fd6a71` 移除东财源，单源腾讯 `newfqkline`，62#/102# 腾讯无源段预过滤跳过）
- `src/tdx_parser.py:331-352`（腾讯无源指数过滤）

### 文档 / 项目记忆（仍写双源）
- `.trae/documents/live-sync/**`（modules / decisions / observability / pitfalls / INDEX）
- `.trae/documents/Kline-增量行情库自动同步.md`、`Kline-境内CI云端生产方案.md`、`market-favorites-refresh-plan.md`
- `.trae/documents/python-engine/Python引擎下沉可行性分析.md`（候选4「多源取数口径」含东财快照）、`实现进度梳理.md`
- `.trae/specs/`：add-watchlist-intraday-sync、add-criteria-contract-tests、pipeline-shard-patch-sync、add-live-data-auto-sync、scale-live-db-to-whole-market、analyze-python-engine-offload
- `project_memory.md` 第 3、13、25、79、80、95、97、129 行

## 设计决策（2026-10-16 用户更正后）

**「清单标的自动更新」是要保留的功能，只是把取数源从东财换成腾讯——不是删除。**
- 保留：`WatchlistSyncManager`（编排 / 状态发布 / 面板 / 手动触发 / 契约测试），`LocalUpdateView` 的「清单标的自动更新」子区原样保留。
- 替换：底层取数 `EastmoneyQuoteFetcher.fetch(files:completion:)` → 新建腾讯版取数器
  （同一结果契约：`bars[file]=当日一根`、`tradeDate`、`skipped/batchFailures` 分类），
  取数走 `web.ifzq.gtimg.cn/appstock/app/newfqkline/get`（复用 `GapBackfill` 的 file→腾讯码映射与
  **量纲吸附校准**，保证写增量库口径与主库一致），交易日取源侧最后一根 bar 的日期。
- 编排顺序不变：到点先补清单范围缺口 → 再跑清单日更（`TdxSyncManager.checkSchedule`）。

**只有「云端分片」链路直接删**（用户明确同意，云端生成端易被行情源按 IP 封锁）。

## 分阶段实现

### 阶段 1：清单日更改腾讯源（保留功能，只换取数底层）
**状态：已完成 + 真机部署（v1.0.2 (535)，2026-10-16）**
- 新增 `Kline/Infrastructure/TencentQuoteFetcher.swift`：与 `EastmoneyQuoteFetcher` **同一结果契约**
  （`bars[file]=最新一根` / `tradeDate` / `skipped` / `batchFailures`），逐只复用
  `GapBackfill.fetchGap`（腾讯 `newfqkline` 取数 + 锚点自校准）→ 与补缺口同一量纲口径。
- `GapBackfill.fetchGap` 由 private 放宽为 internal 供复用（唯一改动）。
- `WatchlistSyncManager`：新增「清单并集 ∩ 主库 meta」预过滤（不可映射 / 62#·102# 定制段 /
  无 `last_date`）+ **逐只按 `meta.last_date` 取主库锚点行**（按日期分组一次 dbQueue 多查），
  再交腾讯取数；编排 / 状态 / 面板 / 手动触发一律未动。
- 东财残留同批清理：删 `EastmoneyQuoteFetcher.swift`、`quote_parse.py` 的 `em_snapshot`/`secid` op、
  `universe_secids.txt`（两份）、`Fixtures/secid_mapping.json` 与两侧东财用例；
  `contract_golden.py` 同步去掉 `eastmoneySnapshot`/`secid_mapping` 两份 fixture（重生成已提交）。
- CI：build.yml 与 test.yml（golden 确定性 + KlineTests）**双绿**。
- 待办验收：真机点一次「立即更新」确认无 `[EMQuote]`、日志出现 `[TencQuote]` 且清单当日 bar 入增量库。

### 阶段 2：清理东财残留（低风险）—— **已并入阶段 1 同批完成**
- 删 `EastmoneyQuoteFetcher.swift`、`quote_parse.py` 的 `em_snapshot` / `secid` op、
  `universe_secids.txt`（Kline/Resources 与 src/data 两份）、东财相关用例与夹具。
- `LiveDataStore` / `KlineApp` 里东财路径的注释改中性表述。

### 阶段 3：删除云端分片链路（高风险，先补侦察）
**用户决策（2026-10-16）**
- **保留 LAN 联动**：`LANSync*` 五个文件 + `LANSyncView` + `LANSyncUITests` + 其依赖的
  `/sync/{status,request-pair,sha,backup,reload-config,live-reset}` 全部保留，**只删云端分片路由**。
- **整块删除** `LocalUpdateView` 的「数据同步」卡片（云端分片 UI）；保留
  `TdxSyncConfig.enabled / tradingDaysOnly / scheduleTimes / foregroundCheckInterval`
  给**腾讯链路四时刻调度**用（App 内不再有改开关/时刻的入口，用户已接受）。

**3a 设备侧删除清单（含调用方证据）**
- `Kline/Infrastructure/TdxSyncManager.swift`
  - **保留**：`config`/`isEnabled`、`start()`/`scheduleTimer()`/`installForegroundObserver()`、
    `checkSchedule`（四时刻 → 腾讯链路）、`updateNextScheduledText`、以及静态工具
    `mainLatestTradeDate`/`todayYMD`/`naturalDaysSince`/`minutes(of:)`/`minutesOfDay`/
    `slotText`/`isTradingDay`/`dayKey`/`nextSlotDescription`（`todayYMD`/`naturalDaysSince`
    被 `GapBackfill` 调用）。
  - **删除**：`TdxLiveBucket`/`TdxLiveManifest` 模型、`beginSync`/`manualSync`/`trySource`/
    `fetchFirstManifest`/`startShardedSync`/`downloadBuckets`/`syncPatches`/`applyTrimThenReload`/
    `downloadDB`/`finishSuccess`/`finishFailure`/`setError`/`verifyAndInstall`/`fetchManifest`/
    `decodeManifest`/`downloadFile`/`moveDownloaded`/`validate`/`verifyBucket`/`verifyPatch`/
    `selectBuckets`/`sha256Hex`/`patchKey`、以及 UserDefaults 本地记录键与
    `bucketTmpPath`。相关 `@Published`（`isSyncing`/`lastSyncAt`/`lastVersion`/`lastTradeDate`/
    `lastSource`/`lastError`/`lastBucketCount`/`lastBucketBytes`/`lastCovered*`/`lastUniverse`/
    `lastNote`）**只被已删的 UI 卡片读取** → 一并删（证据：`Favorites*` 只读 `TdxSyncConfig.enabled`）。
- `Kline/Infrastructure/TdxSyncConfig.swift`：删三源列表（CNB/GitHub raw/jsDelivr）、
  `manifestFileName`、URL 解析（目录型 base / 完整 db 地址）、`sourceText`、`scheduleText`；
  **保留** `enabled`/`tradingDaysOnly`/`scheduleTimes`/`foregroundCheckInterval`。
- `Kline/Data/LiveDataStore.swift`：删 `mergeBucket(atPath:)` 与 `_mergeBucketLocked`，类头分片合并说明改中性。
  **保留** `upsertDaily`/`trim`/`rebuildCurrentPeriodBars`/`rebuildGapPeriods`/`closeAndRemove`
  （`closeAndRemove` 被 `/sync/live-reset` 调用 —— LAN 工具链要用）。
- `Kline/Infrastructure/KlineHTTPServer.swift`
  - **删**：`/sync/merge-bucket`、`/sync/apply-patch`、`/sync/patch-session/{begin,apply,commit,rollback}`、
    `/sync/probe`（含各自执行体与结果契约类型）。
  - **保留**：`/sync/reload`、`/sync/status`、`/sync/sha`、`/sync/request-pair`、`/sync/backup`、
    `/sync/reload-config`、`/sync/live-reset`
    （证据：`TrollRestore/lansync.py:249/296/543/609/619/654` 与 `push_live_*.py` 依赖它们）。
- `Kline/Profile/LocalUpdateView.swift`：整块删「数据同步」卡片（`syncManager`/`syncConfig`
  相关声明、源地址/时刻表编辑、覆盖率/分片进度/最近结果行、`SyncState` 一族）；
  **保留**「主库合并」「清单标的自动更新」「补缺口」三张卡片。
- `Kline/App/KlineApp.swift`：启动注释改中性（只提腾讯链路四时刻调度）。

**3b 生成端删除清单**
- 删 `src/live_db_builder.py`、`src/txt_patch_builder.py`、`.github/workflows/sync-live-db.yml`。
- `src/contract_golden.py`：删 `import live_db_builder as ldb` 与 `aggregate_full_periods`
  交叉自检，并改 `period_aggregation.json` 的 `notes` 文案 → **重跑 `python src/contract_golden.py`
  再提交重生成的 fixtures**（`test.yml` 有「重跑后与已提交逐字节一致」门禁）。
  同步改 `KlineTests/PeriodAggregationContractTests.swift` 头注释。
- `Kline/PyScripts/period_aggregate.py` 头注释里对 `live_db_builder` 的引用改中性。

**3c 文档 + 项目记忆**
- `.trae/documents/live-sync/**` 整篇作废或改写；`Kline-增量行情库自动同步.md`、
  `Kline-境内CI云端生产方案.md`、`market-favorites-refresh-plan.md` 标注云端已弃用；
  `pipeline-shard-patch-sync` / `add-live-data-auto-sync` / `scale-live-db-to-whole-market`
  等规格标注废弃。
- `project_memory.md` 第 3/13/25/79/80/95/97/129 行；`Python引擎下沉可行性分析.md` 候选 4 标注云端已弃用。

**仓库外（不在本仓库，需用户点头后再动）**
`c:/Users/sunck/home/projects/ios/TrollRestore/` 下的 PC 侧分片工具会因设备路由删除而 404：
`sync_pipeline.py`（patch-session + `/sync/probe`）、`push_bucket_usb.py`（merge-bucket/apply-patch）、
`build_live_buckets_pc.py`（产出分片）。`lansync.py` / `push_live_usb.py` / `push_live_lan.py`
依赖的保留路由不受影响。

### 阶段 4：文档 + 项目记忆
- 现状改写为「设备侧单源腾讯（补缺口 + 清单范围日更）；云端分片已弃用」。
- 更新 `project_memory.md` 上述 8 行；`可行性分析.md` 候选 4 收窄为「腾讯取数口径」并标注云端已弃用。
- 删除/标注已作废规格。

## 边界与回归点
- **不可动**：`TdxSyncManager` 四时刻调度与触发（L236-281）、`GapBackfill` 全文、`MainDBMerger` 合并入主库、`LiveDataStore.upsertDaily` 与周期聚合、`LANSync*`（待确认后定）。
- **口径**：日更与补缺口必须共用同一量纲口径（清单范围补缺口 = 同一实现，天然一致）。
- **降级**：腾讯不可达时，日更与补缺口同样跳过并记日志，不写脏数据。

## 验收清单
1. 图片日志：到点只有清单范围补缺口，无 `[EMQuote]`；清单标的当日 bar 正确入增量库并触发条件单/预警重扫。
2. 引擎轮/降级轮测试绿；东财相关测试与夹具已随删除同步移除。
3. 分片链路删除后：`TdxSyncManager` 仅剩调度与触发；无 `manifest`/`bucket`/`patch` 残留引用；App 启动无异常。
4. 全量核对：清单标的日线连续（含缺口日），周期视图（周/月/季/年）数值正常。

## Critical Files
- `Kline/Infrastructure/TdxSyncManager.swift`（调度保留 / 分片删除）
- `Kline/Infrastructure/GapBackfill.swift`（保留）
- `Kline/Infrastructure/WatchlistSyncManager.swift`、`EastmoneyQuoteFetcher.swift`（删）
- `Kline/PyScripts/quote_parse.py`（删两 op）
- `Kline/Profile/LocalUpdateView.swift`（面板改绑）
- `Kline/Data/LiveDataStore.swift`、`Kline/Data/MainDBMerger.swift`（保留，局部清理）
- `src/live_db_builder.py`、`.github/workflows/sync-live-db.yml`（删）
- 文档：`.trae/documents/live-sync/**`、`python-engine/**`、相关 specs
