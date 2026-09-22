# Tasks

> 交付纪律（遵循 `.trae/skills/kline-device-validation-loop`）：每阶段独立可编译、可演示、可单独真机验收；每阶段收尾用
> `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`（退出码 0/6/7 均可交付）并暂停等用户真机确认。
> 中文提交：`feat(watchlist-sync): ...`。主库 `tdx.db` 全程不改动。
>
> 分两阶段：**阶段 A（Task 1~4）= 设备侧四时刻自动更新 + 触发监控**，不依赖 PC，可独立验收；
> **阶段 B（Task 5~8）= PC 差分重灌通道**。

## 阶段 A：设备侧清单驱动自动更新（核心，可独立验收）

- [x] Task 1: 【清单并集】聚合出 6 类清单的唯一 `file` 集合
  - [x] SubTask 1.1: 新增 `Kline/Data/WatchlistSymbols.swift`：`metaID → file` + `code → file` 双字典（同码不同 file 的键**丢弃**并记日志）
  - [x] SubTask 1.2: 并集聚合——manual `manualMetaIDs` + 公式组 `cachedMatches` + 各组 `pinnedMetaIDs` + `conditionalOrders`（预警 + 条件单）+ `orders`，全部归一为 `file`
  - [x] SubTask 1.3: `debugSummary()`：并集标的数、前缀分布（SH/SZ/BJ/27/62/102/其他）、重复丢弃数、未映射样例（≤10）
  - 验收：清单为空 → 空集不报错；扩展指数归一到 `27#xxx`

- [x] Task 2: 【取数】设备侧东财当日K线取数器
  - [x] SubTask 2.1: 新增 `Kline/Infrastructure/EastmoneyQuoteFetcher.swift`：`file → secid`（特例表 → 前缀规则 → 覆盖表）；覆盖表落地为 `Kline/Resources/universe_secids.txt`（278 行），读不到时降级并记日志
  - [x] SubTask 2.2: `ulist.np/get` 每批 ≤100；OHLC 取 `f17/f15/f16/f2`、量额 `f5/f6`；空值丢弃
  - [x] SubTask 2.3: 交易日只由 `f124` 按北京时间 UTC+8 换算；缺失即丢弃（无本机日期分支）
  - [x] SubTask 2.4: UA + 指数退避重试（含首次 4 次）+ 批间间隔；单批失败不影响其他批
  - 附加修正：`.gitignore` 的 `*.txt` 会吞掉资源文件，已加 `!Kline/Resources/universe_secids.txt` 与 `!src/data/universe_secids.txt`（沿用既有例外写法）
  - 验收：口径与 `live_db_builder.py` 逐项对齐（附行号核对）

- [x] Task 3: 【写入 + 调度 + 触发】一次拉取全链路打通
  - [x] SubTask 3.1: 新增 `Kline/Infrastructure/WatchlistSyncManager.swift`；`LiveDataStore.upsertDaily(metas:bars:updatedAt:completion:)` 走 `(file, date)` UPSERT，`live_meta` 用 `INSERT OR IGNORE` 补缺
  - [x] SubTask 3.2: 四档时刻 **11:00 / 14:30 / 15:05 / 17:30** + **老用户一次性迁移**（存档值恰等于旧三档默认才替换，用户自定义值不动）
  - [x] SubTask 3.3: 复用 `_refreshAfterInternalWriteLocked` 走既有热刷新；云端同步失败不影响东财直连
  - 附加修正（spec 硬要求）：`INSERT OR REPLACE` 即使写同值也会改写 SQLite 页 → 空跑也会自增 `dataVersion`。已加「写前判定」：只写库里没有或**任一字段超 1e-6 容差不同**的行；过滤后无变化则**完全跳过事务与刷新**
  - 验收（待真机）：日志出现「并集 N 只 → 命中 M 只 → 写入当日一根 → dataVersion 自增」；全程不重启；重复快照不自增

- [x] Task 4: 【面板】清单标的自动更新状态展示
  - [x] SubTask 4.1: `LocalUpdateView` 新增「清单标的自动更新」子区：状态 / 最近结果 / 清单并集数 / 本次请求（命中·跳过·批次失败）/ 当日交易日 / 各时刻结果 / 立即更新
  - [x] SubTask 4.2: 四态（未启用 / 已同步 / 同步中 / 失败）+ 盘中快照语义标注（`11:00 · 盘中快照`、`15:05 · 收盘`，由 `slotSemantics` 按 < 15:00 判定）
  - 附加修正：清掉原写死三档的两处占位文案（编辑框 placeholder、说明行），改为跟 `scheduleTimes` 动态展开
  - 验收（待真机）：见 tasks 下方的真机步骤清单

## 阶段 B：PC 差分重灌通道

- [x] Task 5: 【导入端】`tdx_parser.py` 支持全量重读
  - [x] SubTask 5.1: 新增 `--rebuild`：忽略 `meta.last_size`、从头读全量并覆盖写入，跑完更新 `last_size` 基线；重建模式下不用旧的周期行做种子（避免周/月线重复累加）
  - [x] SubTask 5.2: 默认增量行为不变（未传参时仍是原交互式流程）
  - 验收：无需改表即幂等（既有 `INSERT OR REPLACE` + `PRIMARY KEY(meta_id,date)`）；`py_compile` 退出码 0
  - 边界：重建只「覆盖」不「删除」——源 txt 中被删除的日期不会从库中清理

- [x] Task 6: 【差分包契约】设备侧支持历史重灌包
  - [x] SubTask 6.1: `TdxLiveManifest` 增 `patches: [TdxLiveBucket]?`（Optional → 旧 manifest 向后兼容）；补丁包沿用分片表结构，可含任意多日期
  - [x] SubTask 6.2: 合并逻辑**零改动复用**（实测 `_mergeBucketLocked` 对包内日期本就不做任何校验）；补丁与分片一致「下载到临时路径 → 合并成功即删」
  - [x] SubTask 6.3: `/sync/merge-bucket` 放行 `patch_` 前缀（保留 `lastPathComponent` + 后缀白名单 + `resolveSandboxPath` 越界校验）；`push_bucket_usb.py` 经确认**无需改动**
  - 清理策略：因补丁合并后即删，「最近 N 个」独立上限只作用于**幂等记录长度**（`maxMergedPatchRecords = 10`，UserDefaults `kline.tdxsync.mergedPatches`，键优先 sha256），与分片 30 片滚动完全无关
  - 幂等：已合并的补丁（sha256 / 文件名）跳过下载与合并
  - 验收（待真机）：推一个含跨年历史行的补丁包 → 合并成功、`dataVersion` 自增、图表无跳空

- [x] Task 7: 【差分生成】PC 侧 db-diff 出包
  - [x] SubTask 7.1: 新增 `TrollRestore/diff_live_patch.py`：ATTACH 新库与基线库，按 **`file`** 关联
  - [x] SubTask 7.2: 差异判定覆盖 `open/high/low/close/vol/amo` 任一字段（浮点容差 `1e-6`，null-safe）+ 基线中不存在的 `(file, date)`；`quarterly`/`yearly` 缺表优雅跳过
  - [x] SubTask 7.3: 两库均 `mode=ro` + `PRAGMA query_only=1`；跑完核对 sha256 与 mtime/size 未变；无差异不产空包
  - [x] SubTask 7.4: 输出差异摘要 + 受影响 file 清单 txt（含 file/序号/bytes/rows/sha256，供 manifest `patches` 用）
  - **关键修正**：spec 原以为 `C:\Users\sunck\home\projects\tdx_project\tdx.db` 可当基线 —— 实测该库**不自洽**（其 `meta` 表用字母序 id 1..3611，数据表却是 id 3..3637；按 meta_id 比对时 1400 万行**值差异为 0**，说明数据表用的是新库同一 id 空间，而 meta 表是另一套）。按 file 关联会产出 1231 万行**假差异**。已加 `check_meta_consistency` 门槛：不自洽即 exit 3、不产包
  - **正确基线** = 设备上已同步过的那一版主库的**整份拷贝**（同一文件天然自洽）
  - 验收：小自洽库出包路径已实测通过（`patch_<seq>.db` 77,824 B / 435 行，daily 343 行跨 1998~2036，表名同为 `bkt_*`）；无差异 exit 0；同内容包 sha256 稳定

- [x] Task 8: 【实测留档】全量 vs 差分 的体积与耗时
  - [x] SubTask 8.1: 三个数字全部实测到位：
    - **① 上传吞吐**：USB `/sandbox` PUT，64 MB 样本两次 → **10.74 / 11.70 MB/s**；按 11.2 MB/s 外推 1,379.7 MB ≈ **123 秒（2.05 分钟）**，与历史记录 2-4 分钟吻合
    - **② 差分产物与生成耗时**：真实 1.4 GB 库对（24 只整段重灌、平均 8,331 行/只）→ `patch_2.db` **22.500 MB / 251,849 行**（**93.9 B/行**），生成总耗时 **400.0 秒**（sha256 14.5s + 自洽性 37.4s + 扫描出包 386.7s + 复核 13.3s）
    - **③ 设备合并**：22.5 MB / 251,849 行 → **1.3 秒**；`dailyCount 3,303 → 203,272`、`earliestDate 20260922 → 19900102`（跨 36 年并入）
  - [x] SubTask 8.2: 已回填 spec「答疑」表（问 1 增实测吞吐行；问 2 换为实测校准表 + 实测用例表），并标注实测/推算
  - 附加验证：下载设备 `tdx_live.db`（23.0 MB）与主库逐行对比 —— `27#HSI` 9,046 行 / `SH#999999` / `SZ#399001` **值不一致 = 0**，各多 1 行（20260922 当日K线，主库尚无）
  - 临时产物已清理：`_tp64.bin`、`_dev_live.db`、`_sim_new.db`、`_sim_base.db`、合成的 `patch_1.db`；**保留** `tdx_baseline.db`（1.38 GB，即为后续差分要用的基线）与已验证的 `patch_2.db`
  - 验收：三个数字均有原始 stdout 留档（本任务记录即原始输出）

# Task Dependencies

- Task 2 依赖 Task 1（需要并集才能定拉取范围）
- Task 3 依赖 Task 2（需要取到数据才能写库）
- Task 4 依赖 Task 3（需要能触发拉取才能验监控）
- Task 6 独立于阶段 A，可与 Task 5 并行
- Task 7 依赖 Task 5（重建能力）与 Task 6（差分包契约）
- Task 8 依赖 Task 7，且需要真机

# 留待真机验证的步骤清单（Task 3 / Task 4 / Task 6）

1. 个人中心 → 本地更新：确认出现「清单标的自动更新」子区，行高 48、深浅色正常、布局不跳动
2. 关闭同步开关 → 状态显示「未启用」、「立即更新」置灰；打开 → 可点
3. 点「立即更新」→ 出现「同步中」+ 进度指示 + 按钮禁用；结束转为「已同步 / 失败」并刷新各行
4. 并集为空时 → 「已跳过（见最近结果）」+「跳过：清单为空」
5. 四个时刻行标题应为：`11:00 · 盘中快照`、`14:30 · 盘中快照`、`15:05 · 收盘`、`17:30 · 收盘`
6. 修改「更新时刻」→ 子区时刻行与语义说明随之动态变化
7. 到点或回前台补跑后，对应时刻行的结果被刷新
8. 查 `Documents/debug_log.txt`：应有 `[WatchlistSync]` 完整链路日志；重复拉取同一快照时**不应**出现 `dataVersion` 自增
9. **监控触发**：给并集内某标的挂一个「价格上穿 X」条件单 + 一个预警 → 触发一次拉取后应产生对应记录
10. **差分包**：推一个 `patch_<seq>.db` → `/sync/status` 与日志显示合并成功、`dataVersion` 自增；分片滚动不受影响

# 交付记录（真机）

| build | 内容 |
| :--- | :--- |
| v1.0.2 (376) | 阶段 A + 阶段 B 全部实现（Task 1~7）。`run=35726729340`，**云端构建成功 + TrollStore 部署完成** → 全部 Swift 编译通过、资源打包成功 |

**已完成的真机实证（v1.0.2 (376)）**

```
# 设备侧分片合并（既有路径回归）
PUT  bucket_20718.db      HTTP 200    589824 B  {"ok":true}
MERGE bucket_20718.db     HTTP 200  0.1s  {"ok":true,"message":"合并完成 meta=3312 daily=3303 …"}

# 设备侧「历史重灌包」合并（Task 6 新增能力，首次真机验证）
before: … "dailyCount":3303, "earliestDate":20260922 …
PUT  patch_2.db           HTTP 200  23592960 B  {"ok":true}
MERGE patch_2.db          HTTP 200  1.3s  {"ok":true,"message":"合并完成 meta=24 daily=199969 weekly=41917 monthly=9963 覆盖=3314只"}
after : … "dailyCount":203272, "earliestDate":19900102 …   ← 跨 36 年历史并入成功

# 逐行一致性（下载设备 tdx_live.db 23.0 MB 与主库对比）
27#HSI       dev=9046  ref=9046  值不一致=0  仅设备有(比主库新)=0
SH#999999    dev=8715  ref=8714  值不一致=0  仅设备有(比主库新)=1
SZ#399001    dev=8670  ref=8669  值不一致=0  仅设备有(比主库新)=1
```

**仍待用户在真机确认**（需人工操作，见下方步骤清单第 1~9 项）：四时刻到点触发、面板四态与盘中快照标注、条件单/预警随新价触发、重复快照不自增 `dataVersion`。