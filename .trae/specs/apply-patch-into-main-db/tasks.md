# Tasks

> 交付纪律（遵循 `.trae/skills/kline-device-validation-loop`）：设备侧改动收尾用
> `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`。
>
> 场景固定：`--old-txt-dir C:\Users\sunck\home\tdx_data_old`（止于 20260828）、
> `--new-txt-dir C:\Users\sunck\home\tdx_data`（止于 20260922；3641 文件 = **3440 纯追加 + 197 历史改写 + 4 新上市**，
> 已按 Task 0 实测口径修正，非早先的 3442/195）。
> **不再调用 `tdx_parser.py --prev-dir`**（实测 585.1s，见 spec）。

- [x] Task 0: 【门槛】只读原型量准 PC 侧三段耗时，确认总预算 < 60s 才继续
  - [x] SubTask 0.1: 只读原型 `build_logs/_proto_task0.py`（`build_logs/` 在 gitignore，不进仓库）
  - [x] SubTask 0.2: 未写任何库、未动设备；补丁只写临时文件后立即删除
  - [x] SubTask 0.3: 实测 **PC 侧 A+B+C = 31.5s**，含 D/E 总预算 **47.0s < 60s** → **门槛通过**
  - 验收结论：**通过**（余量约 13s）

  **实测数据（2026-09-23）**

  | 阶段 | 实测 | 说明 |
  | :--- | ---: | :--- |
  | A 分类 + 解析 | **15.0s** | 3641 文件；每文件只开 2 次句柄 |
  | B 比对/汇总 | **10.1s** | 197 个 rewrite 全行比对 + 3440 个 append 只查基线尾部 |
  | C 出包 | **6.4s** | 842,816 行 → **76.2 MB** |
  | D 推送 | 6.8s | 76.2MB ÷ 11.2MB/s（实测吞吐） |
  | E 设备端 UPSERT | 8.7s | 按 25.2 万行/1.3s 的 2× 估 |
  | **合计** | **47.0s** | **< 60s ✅** |

  **两个关键发现（实现时必须遵守）**

  1. **txt 末尾有 18 字节页脚** `#数据来源:通达信\r\n`（GBK，恰 18 字节），新数据追加在**页脚之前** →
     旧文件最后 18 字节必然与同位置新文件不同。**判定「纯追加」必须排除末尾 18 字节**，
     否则全部文件被误判为 rewrite（实测：不排除时 append=0，排除后 append=3440）。
     这也是 `tdx_parser.py` 里 `last_size -= 18` 的由来。
     解析 append 文件时：`seek(o_sz - 18)` → `readline()` 丢掉页脚行 → 其余即新增数据行。
  2. **197 个 rewrite 是真全历史改写**（92.7% 日线行变化、最早追溯到 1994-01-03，中位 2658 行/文件），
     所以 76MB 补丁是**真实必需**，不是浪费。另有 17 个文件虽判为 rewrite 但日线 0 变化（只尾部差异）。

  **两处非必要浪费（原型第一版踩到，已消除）**

  - 分类与解析**融合**成一次：每文件 2 次句柄（旧 1 次采样、新 1 次），而非 3 次 → A 23.6s → 15.0s
  - **周一映射缓存**：避免每行构造 `datetime` → B 19.9s → 10.1s
  - append 文件的周/月只查基线**最后 8 行**（`ORDER BY date DESC LIMIT 8`），
    而非整段历史（否则 3440 × ~1200 行白取，B 段多花 ~50s）

- [x] Task 1: 【分类】`src/txt_changes.py` 增加 `append / rewrite / new` —— 已完成，实测 `append=3440 / rewrite=197 / new=4`，8.1s（每文件恰 2 次句柄）。已知：8 个超短文件因采样长度超出可比对区间被判 `rewrite`（符合「拿不准一律 rewrite」）
  - [ ] SubTask 1.1: 按**旧文件长度**在新文件上取三处采样（头 4KB / `旧长度/2` 处 4KB / 旧尾 4KB）与旧文件同位置比对；三处全一致 ⇒ `append`，任一不同 ⇒ `rewrite`；仅新目录有 ⇒ `new`
  - [ ] SubTask 1.2: 返回值增加 `kind: {file: "append"|"rewrite"|"new"}`，既有键不变
  - [ ] SubTask 1.3: **拿不准一律按 `rewrite`**；每个文件只开两次句柄（旧一次、新一次），在同一句柄内做多次 seek，避免放大逐文件打开开销
  - 验收：对真实目录实测 `append≈3442 / rewrite≈195 / new=4`，耗时与 18.6s（2 次打开/文件）同量级

- [x] Task 2: 【出包】新增 `src/txt_patch_builder.py`：txt 直出差分 —— 已完成。
  **正确性硬门槛通过**：`--self-check 200` → 文件级 匹配 200 / 不一致 0，周期级 匹配 600 / 不一致 0。
  **实测修正两个原型缺陷**：① `seek(o_sz-18)` 后**不该再 `readline()`**（新数据就追加在页脚位置、页脚在新文件最末），
  原型的 `readline()` 丢掉每个 append 文件的第一根新增日线（≈3440 行）并产生假周期行；
  ② **主库无此标的的 txt 必须整段跳过**（设备侧 `JOIN main.meta` 会丢弃），而不是 force_full 全量入包。
  最终：`append=3417 / rewrite=194 / 跳过 30`，**A 10.9s + B 8.3s + C 5.3s = 24.5s**，补丁 **843,767 行 / 76.3 MB**，
  `latestDate=20260922`，3611 只（= 主库标的数）。
  - [ ] SubTask 2.1: `append` 文件 → 从 `旧长度` 起解析尾部行，全部计 `new_only`，**不做行级比对**
  - [ ] SubTask 2.2: `rewrite` 文件 → 整文件解析，与**基线库**逐行比对（按 `file→meta_id` 查基线行），**只产出真正不同或新增的行**
  - [ ] SubTask 2.3: `new` 文件 → 全部行按新增
  - [ ] SubTask 2.4: 用 `live_db_builder.build_bucket_file` 出 `patch_<seq>.db`（**表结构逐字沿用**），manifest 含 `patches` 项
  - [ ] SubTask 2.5: 周/月线：只对**产出了日线差异**的 file 重算（口径与既有实现一致，不得另发明）
  - 验收：对同一对 txt 目录，产物与「重建库后跑 `diff_live_patch --no-prune`」的结果**逐行一致**（这是正确性硬门槛）

- [x] Task 3: 【设备侧】新增 `POST /sync/apply-patch`：按行 UPSERT 进主库 —— 已完成（SQL 语义已用本机 sqlite3 真跑验证；真机见 Task 4）。
  **实测修正一处缺陷**：原 `UPDATE meta SET last_date = (SELECT MAX(...))` 在补丁只含**旧日期**时会让 `last_date` **回退**
  （实跑复现 20260902→20260828）→ 已加 `MAX(COALESCE(...))` 兜底。
  未复用 `MainDBMerger`（它是 App 内手点路径且逐行 bind，与「一条集合式 SQL」硬要求不符）；`MainDBMerger` 本身未改动。
  - [ ] SubTask 3.1: `KlineHTTPServer.swift` 加路由；**不在 HTTP 线程同步执行**，完成后回主线程响应
  - [ ] SubTask 3.2: 在 `DatabaseManager.dbQueue` 上、单事务、**一条集合式 SQL**：
    `INSERT OR REPLACE INTO <表>(meta_id,date,open,high,low,close,vol,amo) SELECT m.id,b.date,b.open,b.high,b.low,b.close,b.vol,b.amo FROM bkt.bkt_<表> b JOIN main.meta m ON m.file=b.file`
    （daily/weekly/monthly 各一条；表不存在则跳过）
  - [ ] SubTask 3.3: 更新 `meta.last_date`（`SELECT b.file, MAX(b.date) ... GROUP BY b.file` + 批量 UPDATE），随后热刷新
  - [ ] SubTask 3.4: 响应含行数统计（日/周/月、覆盖标的数、`latestDate`）；失败 ROLLBACK + 原因
  - 验收：推 `patch_<seq>.db` 后 `POST /sync/apply-patch` 返回 200 与行数统计；**不重启 App**、**不经过增量库**

- [x] Task 4: 【端到端实测】跑通到 iPad 并留档
  - [x] SubTask 4.1: 四步逐步计时（见下方交付记录）
  - [x] SubTask 4.2: 设备侧核对（日志 + 本地基线穷尽核对，见交付记录）
  - [x] SubTask 4.3: 核对「只更新差异」：写入 843,767 行，相对全库 1400 万行 = **6.0%**
  - [x] SubTask 4.4: 实测数字已回填本文件与 `.trae/documents/live-sync/`

- [x] Task 5: 【本地基线同步】把同一补丁应用到 PC 本地基线 —— 已完成：新增 `TrollRestore/apply_patch_local.py`，
  与设备侧**同一条集合式 SQL**，默认 `--dry-run`、真写需 `--yes`、失败 ROLLBACK、不备份（1.4GB）。
  小库副本 `--yes` 跑两次**幂等**、`last_date` 前移不回退、主库无此 file 正确跳过；真实基线只做 dry-run（daily 664,611 / weekly 141,822 / monthly 37,334，覆盖 3638 file）。
  - [ ] SubTask 5.1: 提供一次性脚本/命令：把 `patch_<seq>.db` 按行 UPSERT 进本地基线库（同一集合式 SQL，SQLite 版）
  - [ ] SubTask 5.2: 文档写明**该步骤不计入 60s 预算**（可另跑），但不做的话下一轮会重复算已同步的差异
  - 验收：基线库应用补丁后与设备主库内容一致

# Task Dependencies

- **Task 0 是门槛**：结论 ≥ 60s 则停止，不进入 Task 1~3
- Task 2 依赖 Task 1（需要分类）
- Task 3 独立（设备侧），可与 Task 1、2 并行
- Task 4 依赖 Task 2、3
- Task 5 依赖 Task 4（补丁已在设备侧验证过）

# 交付记录（真机）

| build | 内容 |
| :--- | :--- |
| v1.0.2 (377) | `POST /sync/apply-patch`（补丁按行落主库，集合式 SQL）+ txt 直出差分脚本 |
| v1.0.2 (378) | apply-patch 会话级 pragma（cache_size 32MB / temp_store MEMORY / synchronous NORMAL）加速批量写 |

## 端到端实测（2026-09-23，真机）

**流程**：`txt_patch_builder` → `push_bucket_usb --apply-main`（PUT → apply-patch → 清增量库 → reload）

| 阶段 | 实测 | 备注 |
| :--- | ---: | :--- |
| PC 出包 A+B+C | **25.4s** | A 11.4（分类+解析，2 句柄/文件）/ B 8.9（比对聚合）/ C 5.1（出包 843,767 行 → 76.3 MB） |
| usbmux forward 建立 | 4.1s | 每次运行的固定开销 |
| PUT 补丁 76.3 MB | 5.9s | **12.92 MB/s** |
| **设备端 APPLY（主库 UPSERT）** | **21.5s** | 843,767 行（日 664,611 / 周 141,822 / 月 37,334），覆盖 3611 只，跳过 0；**加 pragma 前是 27.9s** |
| 清增量库 + reload | 0.5s | 增量库已不存在（上轮已删），按设计**不报错**继续 |
| **合计** | **57.8s** | **< 60s ✅**（余量约 2s，偏紧） |

**设备侧证据（`Documents/debug_log.txt`）**

```
02:06:24 沙盒上传开始: .../Documents/live/patch_6.db len=79994880
02:06:30 上传完成: 79994880 bytes
02:06:51 [Patch] 补丁 patch_6.db 应用进主库成功：已按行写入主库 843767 行（日664611/周141822/月37334） · 覆盖 3611 只 · 最新 20260922
02:06:51 [DB] dataVersion → 1（主库被内部合并改写）
02:06:51 [Cache] dataVersion 变化 → 重取行 n=3611 coveredFile=0
02:06:52 沙盒DEL ... exists=false   ← 增量库上轮已删，按设计不报错
02:06:05 [Live] 增量库不存在 → 降级「仅主库」   ← App 已切换为纯主库读取
```

**内容核对（穷尽，在「收到同一补丁的本地基线」上做）**

| 检查 | 结果 |
| :--- | :--- |
| 3611 只标的的日线末日 | **全部 = 20260922**（例外 0） |
| `meta.last_date` | **全部 = 20260922**（例外 0） |
| 缺口检查（30 只含指数：库内日期集合 vs 新 txt 日期集合） | **完全一致**（不一致 0） |
| 取值抽查（`SH#600519` 6010 行 / `SZ#000001` 8459 行 / `27#HSI` 9063 行） | **值不一致 0** |
| 「只更新差异」 | 写入 843,767 行 vs 全库 14,008,185 行 = **6.0%** |

**为什么是「在本地基线上核对」而不是直接读设备库**：设备 `tdx.db` 是 1.4 GB，
`GET /sandbox/tdx.db` 返回 503、`pymobiledevice3 apps pull` 对 TrollStore 版报
`InstallationLookupFailed`（容器隔离，与既有文档一致）。
故采用证据链：①补丁内容已做 200 文件全量重算交叉验证（0 不一致）→ ②设备端用的是**同一条集合式 SQL**
（已用本机 sqlite3 真跑验证语义）→ ③设备日志确认 843,767 行写入成功且 `dataVersion` 自增 →
④在**收到同一补丁的本地基线**上做穷尽核对（上表）。
**未直接读回设备库内容** —— 这是本次验证的已知局限。

**两处如实说明**

1. **余量偏紧**：57.8s 距 60s 只剩约 2s。PC 侧 A 段受磁盘冷缓存影响（实测分类冷启 16.2s vs 热 8.1s），
   冷缓存下可能超 60s。设备端 APPLY（21.5s）是最大单项，占了 37%。
2. **30 个 txt 无对应标的**：3641 个 txt 里有 30 个在主库 `meta` 中不存在
   （26 个是 `42#/46#/12#` 等被 `tdx_parser` 条件过滤、从未导入；4 个是新上市），
   它们**无法**通过补丁进入主库（要进得先插 `meta` 行）→ 已被生成器跳过并在日志里列出。

## Task 0 实测结论

| 阶段 | 预算 | 实测 | 偏差 |
| :--- | ---: | ---: | :--- |
| A 分类 + 解析 | ~20s | **11.4s** | 优于预算 |
| B 改写文件行级比对 | ~10s | **8.9s** | 符合 |
| C 出包 | ~3s | **5.1s** | 略差（Python 绑定 843k 行是下限） |
| D 推送 | ~7s | **5.9s** | 符合（12.92 MB/s） |
| E 设备端 UPSERT | ~10s | **21.5s** | **严重低估**（原按 25.2 万行/1.3s 外推；实际 iPad mini 4 上 84 万行 UPSERT 慢得多） |
| **合计** | ~50s | **57.8s** | 达标但余量薄 |