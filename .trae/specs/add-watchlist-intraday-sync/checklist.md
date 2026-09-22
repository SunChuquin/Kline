# Checklist

> 勾选依据：**代码级核对**（逐行读到实现）或**本次真跑输出**（有 stdout / 设备返回可查）。
> 需人工在真机上操作才能确认的项，统一列在文末「待用户真机确认」，未勾选。

## 清单并集（Task 1）

- [x] `WatchlistSymbols` 以主库 `meta` 表（`id`/`file`/`code`）建字典，未把 6 位 `code` 直接当键；同码不同 file 的键被丢弃并记日志（`buildMaps`，WatchlistSymbols.swift:39-63）
- [x] 并集覆盖 6 类：自选 / 分组（含公式组 `cachedMatches`）/ 置顶 / 预警 / 条件单 / 委托（`collectRefs` :82-111）
- [x] 输出统一为 `SH#600000` 形式的 `file`，扩展指数为 `27#xxx` / `62#xxx` / `102#xxx`
- [x] 清单为空时返回空集且不报错、不写库（`unionFiles` :126-140 返回空 Set；`WatchlistSyncManager` 有「跳过：清单为空」分支）

## 东财取数（Task 2）

- [x] secid 映射与 `live_db_builder.secid_for_file` 一致：`SH#`→`1.`、`SZ#`/`BJ#`→`0.`、`SH#999999`→`1.000001`（EastmoneyQuoteFetcher.swift:148-161）
- [x] 扩展指数从内置覆盖表取 secid；缺失的 `27#HS*` 被识别并跳过（`unmappable` + 逐条 `skipped` 记录，非静默）
- [x] 批量快照每批 ≤ 100 个 secid；OHLC 用 `f17/f15/f16/f2`，量额用 `f5/f6`
- [x] 交易日一律由 `f124` 按北京时间（UTC+8）换算；**无任何**以本机日期充当交易日的分支（`beijingDateFormatter` 显式 `TimeZone(secondsFromGMT: 8*3600)`）
- [x] 请求带 User-Agent；失败有指数退避重试；单批失败不影响其他批
- [ ] 30 只跨市场样本（含 1 只扩展指数）实测拿到当日 OHLC + 成交量 + 成交额 → **待真机**

## 调度与触发（Task 3 / 4）

- [x] 调度时刻为四档 11:00 / 14:30 / 15:05 / 17:30（`TdxSyncConfig.defaultScheduleTimes:45`）
- [x] 老用户一次性迁移：存档值恰等于旧三档才替换，用户自定义值不动（`TdxSyncConfig:96-104`，有日志）
- [x] 非交易日不触发；前台缺失时回到前台补跑一次；同刻重复触发被去重（复用既有 `checkSchedule` 语义）
- [x] 写入增量库走 `(file, date)` UPSERT，`live_meta` 用 `INSERT OR IGNORE` 补缺失标的
- [x] 内容确实变化才自增 `dataVersion`：写前判定，只写库里没有或任一字段超 `1e-6` 容差不同的行；过滤后无变化则**不开事务、不写行、不刷新**（`_upsertDailyLocked`）
- [x] 清单东财同步与云端 manifest 拉取独立触发，云端失败不影响东财直连
- [x] 11:00 / 14:30 的写入在 UI 上被标注为「盘中快照」（`slotSemantics`，LocalUpdateView）
- [x] 设置面板展示并集标的数、四时刻各自最近结果、批次与命中数、当日最新交易日，并区分四态
- [ ] 触发后日志可见完整链路：并集 N 只 → 命中 M 只 → 写入当日一根 → `dataVersion` 自增 → `MarketRowCache` 重取 → `sweepConditions(.dataReload)` → **待真机**
- [ ] 条件单 + 预警各挂一个（并集内标的），触发一次拉取后均产生对应触发记录 → **待真机**

## 导入端重建（Task 5）

- [x] `tdx_parser.py` 提供重建模式，忽略 `last_size` 后从头全量读入并覆盖写入（`--rebuild`，`py_compile` 通过）
- [x] 默认增量行为保持不变（未传参时仍是原交互式流程）
- [ ] 同一份 txt 下，重建模式对已除权标的的历史价格与 txt 逐行一致 → **待用户在通达信客户端全量更新时一并验证**（本机未跑，避免改写主库）

## 差分包（Task 6 / 7）

- [x] `patch_<seq>.db` 表结构与分片一致（`bkt_meta`/`bkt_daily`/`bkt_weekly`/`bkt_monthly`），可含任意多日期 —— **真机实测跨 1990-01-02 ~ 2026-09-22**
- [x] 补丁包不占用、不影响分片的 30 片滚动；清理策略独立（「最近 N 个」只作用于幂等记录长度，`maxMergedPatchRecords = 10`）
- [x] manifest 含 `patches` 数组，元素带 `file`/`id`/`bytes`/`rows`/`sha256`（Optional，旧 manifest 向后兼容）
- [x] 设备侧合并补丁包后 `dataVersion` 自增，且该标的历史与主库逐行一致、无跳空 —— **真机实测**：合并 251,849 行 / 1.3s；抽查 `27#HSI` 9,046 行等，**值不一致 = 0**
- [x] `diff_live_patch.py` 按 `file` 关联，未使用 `meta_id`（`ATTACH base` + 全 SQL 库前缀）
- [x] 差异判定包含 `open/high/low/close/vol/amo` 任一字段变化，且包含基线中不存在的 `(file, date)`（真跑输出含 `changed` 与 `new_only` 两条分支）
- [x] 基线库只读打开，跑完 sha256 与 mtime/size 均未变（真跑输出：两库均「✅ 未被修改」）
- [x] 新旧库完全一致时不产空包，明确打印「无差异」（exit 0）
- [x] 附加门槛：基线**不自洽**时拒绝出包（exit 3），杜绝假差异 —— `tdx_project/tdx.db` 实测被拦下（否则会产 1231 万行假差异）
- [x] `/sync/merge-bucket` 放行 `patch_` 前缀，且保留 `lastPathComponent` + 后缀白名单 + `resolveSandboxPath` 越界校验

## 实测留档（Task 8）

- [x] 上传吞吐有原始输出留档：USB `/sandbox` PUT，64 MB 样本两次 → **10.74 / 11.70 MB/s**（1,379.7 MB 按 11.2 MB/s 外推 ≈ 123 秒；**未真跑 1.38 GB 整库替换** —— 会覆盖设备主库并强制重启，且用户将自行做全量更新）
- [x] 常态差分包体积与实际秒数有原始输出留档：**22.500 MB / 251,849 行 / 生成 400.0 秒**
- [x] 设备侧合并实际耗时留档：**1.3 秒**
- [x] spec「答疑」表中被替换为实测值的项已标注「实测」，推算项单独标注「推算」/「外推」

## 硬约束回归

- [x] 主库 `tdx.db` 表结构与「启动时打开」语义未被改动（`tdx_parser.py` 只新增 `--rebuild` 模式，未改表）
- [x] PC 侧脚本对 `tdx.db` / 基线库均为只读打开（`mode=ro` + `PRAGMA query_only=1`，且每次跑完复核 sha256/mtime/size）
- [x] 未引入设备内常驻进程（无 root 守护）
- [x] 东财为第三方接口，失败路径有降级与逐条日志，不阻塞 App 主流程
- [x] 既有 `add-live-data-auto-sync` 能力未被破坏 —— **真机回归**：分片 `bucket_20718.db` 合并成功（meta=3312 / daily=3303 / 0.1s）

## 构建与部署

- [x] 全量 Swift 编译通过 + 资源打包成功 + TrollStore 部署完成：**v1.0.2 (376)**，`run=35726729340`
- [x] `.gitignore` 的 `*.txt` 会吞掉资源文件，已加例外（`!Kline/Resources/universe_secids.txt`、`!src/data/universe_secids.txt`）

## 待用户真机确认（本机无法验证，需人工操作）

1. 个人中心 → 本地更新：确认出现「清单标的自动更新」子区，行高 48、深浅色正常、布局不跳动
2. 关闭同步开关 → 状态「未启用」、「立即更新」置灰；打开 → 可点
3. 点「立即更新」→ 「同步中」+ 进度 + 按钮禁用；结束转为「已同步 / 失败」并刷新各行
4. 并集为空时 → 「已跳过（见最近结果）」+「跳过：清单为空」
5. 四个时刻行标题应为：`11:00 · 盘中快照`、`14:30 · 盘中快照`、`15:05 · 收盘`、`17:30 · 收盘`
6. 修改「更新时刻」→ 子区时刻行与语义说明随之动态变化
7. 到点或回前台补跑后，对应时刻行的结果被刷新
8. 查 `Documents/debug_log.txt`：应有 `[WatchlistSync]` 完整链路日志；**重复拉取同一快照时不应出现 `dataVersion` 自增**
9. **监控触发**：给并集内某标的挂「价格上穿 X」条件单 + 一个预警 → 触发一次拉取后应产生对应记录
10. 30 只跨市场样本（含 1 只 `27#`/`62#`/`102#` 扩展指数）确认能取到当日 OHLC + 成交量 + 成交额