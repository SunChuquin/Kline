# Checklist

> 勾选依据：**代码级核对** 或 **本次真跑输出**（命令 stdout / 设备日志可查）。

## 门槛：先量准预算（Task 0）

- [x] 只读原型**没有写任何库、没有动设备**（基线库 `(size, mtime)` 跑完未变）
- [x] A（分类 + 解析）实测 11.4s（首版原型 23.6s → 融合句柄后 15.0s → 最终 11.4s）
- [x] B（改写文件解析 + 与基线比对）实测 8.9s（首版 70.9s → 修 append 白取后 19.9s → 加周一缓存后 10.1s）
- [x] C（出包）实测 5.1s → 76.3 MB
- [x] 补丁实际行数 843,767 与体积 76.3 MB 已记录
- [x] 给出 A+B+C+D+E 总预算 57.8s 并明确 **< 60s**
- [x] 未触发「≥60s 则停下」分支

## 分类（Task 1）

- [x] `changed_files` 返回新增 `kind`（`append`/`rewrite`/`new`），既有键不变（两处调用方未受影响）
- [x] 三处采样（头 4KB / `旧长度/2` 处 4KB / 旧尾 4KB）**排除末尾 18 字节**；三处全一致 ⇒ `append`
- [x] 拿不准（读失败、长度异常、超短文件）一律 `rewrite`
- [x] 每文件恰 2 次句柄（旧 1、新 1），三次采样在同一句柄内 seek
- [x] 真实目录实测 `append=3440 / rewrite=197 / new=4`，8.1s（冷启 16.2s）

## txt 直出差分（Task 2）

- [x] 全程**不重建 `tdx.db`**；旧值真相源是基线库
- [x] `append` 文件只解析 `旧长度 - 18` 之后的行，全部计新增，未做行级比对
- [x] `rewrite` 文件与基线逐行比对，**只产出真正不同的行**
- [x] 补丁表结构与字段顺序**逐字沿用** `build_bucket_file`（`bkt_meta`/`bkt_daily`/`bkt_weekly`/`bkt_monthly`）
- [x] 周/月线口径与 `tdx_parser.handle_data` 一致（open 取周期首行、high/low/close/vol/amo 归并、date=周期首个交易日）
- [x] **正确性硬门槛通过**：`--self-check 200` → 文件级 **匹配 200 / 不一致 0**，周期级 **匹配 600 / 不一致 0**
- [x] 全流程**没有 1.4GB 级全文件读**（只有 `(size, mtime)` 复核，无 sha256 路径）
- [x] 基线库只读（`mode=ro` + `PRAGMA query_only=1`）且跑完 `(size, mtime)` 未变
- [x] `new` 与「主库无此标的」的 txt 被**整段跳过**并列出（30 个），不再浪费入包

## 设备侧按行落主库（Task 3）

- [x] 新增 `POST /sync/apply-patch`，邻接既有 `/sync/*` 风格
- [x] 合并不在 HTTP 线程同步执行（`DispatchQueue.main.async` 进入，`performOnDBQueue` 执行，完成回主线程响应）
- [x] 写入是**一条集合式 SQL**（`INSERT OR REPLACE ... SELECT ... FROM bkt.bkt_* JOIN main.meta ON m.file=b.file`），**未在 Swift 里逐行 bind**
- [x] 映射键是 `file`（未用 `code`）
- [x] 单事务 + 失败 ROLLBACK；响应含失败原因
- [x] 完成后更新 `meta.last_date`（带 `MAX(...)` 兜底**防回退**）+ `loadMetaList()` + `notifyMainDBChanged()`
- [x] **不替换整个 `tdx.db`**、**不需要重启 App**、**不经过增量库**
- [x] 响应含日/周/月行数、覆盖标的数、`skippedFiles`、`latestDate`
- [x] 会话级 pragma（cache_size / temp_store / synchronous）加了 `defer` 还原，不影响其它路径

## 端到端实测（Task 4）

- [x] 四步串起来跑通，各阶段耗时有原始输出留档
- [x] **端到端总耗时 57.8s < 60s**（余量约 2s，已如实说明偏紧）
- [x] 设备日志确认 `[Patch] ... 已按行写入主库 843767 行 · 覆盖 3611 只 · 最新 20260922` + `[DB] dataVersion → 1`
- [x] 3611 只标的日线末日**全部 = 20260922**（例外 0）；`meta.last_date` 全部 = 20260922
- [x] 缺口检查 30 只（含 `27#HSI` 等指数）：库内日期集合与新 txt **完全一致**
- [x] 取值抽查 3 只（`SH#600519` 6010 行 / `SZ#000001` 8459 行 / `27#HSI` 9063 行）：**值不一致 0**
- [x] 「只更新差异」核对：写入 843,767 行 = 全库 14,008,185 行的 **6.0%**
- [x] 补丁体积 76.3 MB 与该量级相符（不是全库级几百 MB）
- [x] 实测数字写入 `tasks.md` 交付记录
- [ ] **未直接读回设备 `tdx.db` 内容**（1.4GB：HTTP GET 503、AFC pull 因 TrollStore 容器隔离失败）→ 已改用「同一补丁 + 同一 SQL + 设备日志 + 本地基线穷尽核对」的证据链，并在 tasks.md 如实标注为已知局限

## 本地基线同步（Task 5）

- [x] 提供 `TrollRestore/apply_patch_local.py`（与设备侧同一条集合式 SQL）
- [x] 文档写明该步骤**不计入 60s 预算**（实测 56.8s），但不做会导致下一轮重复计算已同步差异
- [x] 已在真实基线上应用：843,767 行、`MAX(last_date)` 20260828 → **20260922**；daily +61,276 行（新增）、weekly +14,432、monthly +3,611
- [x] 幂等与「`last_date` 不回退」「主库无此 file 正确跳过」已在小库副本上验证

## 硬约束回归

- [x] `MainDBMerger`（App 内手点「合并到 tdx.db」）语义未改动
- [x] 差分包契约（表名/字段顺序）未改动
- [x] 增量库结构与「增量优先、主库补齐」的查询语义未改动（清库后 App 正确降级为「仅主库」）
- [x] 四时刻自动更新链路（`WatchlistSyncManager` / 东财直连）未受影响
- [x] `tdx_parser.py` 的 `--rebuild` / `--prev-dir` 保留可用（本流程不再调用）
- [x] PC 侧脚本对基线库只读打开；写入只发生在**显式 `--yes`** 的 `apply_patch_local.py`
- [x] 整库替换老路（`/upload` + 重启）保持不变

## 待用户真机确认

1. 打开 Kline：自选/K线图直接可见 20260922 且**未重启**（增量库已删，走纯主库）
2. 抽查一只本次「历史被改写」的标的（如 `SH#600519`），确认历史价格与 PC 侧一致、无跳空
3. 端到端耗时是否稳定 < 60s（冷缓存下可能偏慢，见 tasks.md「余量偏紧」）