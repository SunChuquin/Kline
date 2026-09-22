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

- [ ] Task 4: 【端到端实测】跑通到 iPad 并留档
  - [ ] SubTask 4.1: 四步逐步计时：`txt_patch_builder` → `push_bucket_usb`（PUT）→ `POST /sync/apply-patch` → 核对
  - [ ] SubTask 4.2: 设备侧核对：`latest_date == 20260922`；抽查标的（含 1 只扩展指数）**交易日连续无缺口**
  - [ ] SubTask 4.3: 核对「只更新差异」：写入主库的行数 ≈ 补丁行数（远小于全库 1400 万行）；补丁体积符合量级
  - [ ] SubTask 4.4: 把实测数字写进本文件交付记录与 `.trae/documents/live-sync/` 对应篇
  - 验收：**端到端总耗时 < 60s**；上述核对全部通过

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
| 待填 | — |

## Task 0 实测结论（待填）

| 阶段 | 实测 | 预算 |
| :--- | ---: | ---: |
| A 分类 + 解析 | — | ~20s（锚点 18.6s） |
| B 改写文件行级比对 | — | ~10s |
| C 出包 | — | ~3s |
| D 推送 | — | ~7s（实测 11.2MB/s） |
| E 设备端 UPSERT | — | ~10s |
| **合计** | — | **~50s** |