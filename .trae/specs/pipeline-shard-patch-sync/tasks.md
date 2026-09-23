# Tasks

> 交付纪律（遵循 `.trae/skills/kline-device-validation-loop`）：设备侧改动收尾用
> `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`。

- [ ] Task 0: 【前置】准备干净基线（**不需要还原设备、不需要手动点击**）
  - [ ] SubTask 0.1: 把 `C:\Users\sunck\home\tdx.db`（**已核实仍是 8.28**：`MAX(daily.date)=20260828`、14,008,185 行）复制为 `C:\Users\sunck\home\tdx_baseline.db`，**覆盖**上一轮被写成 9.22 的那份
  - [ ] SubTask 0.2: 核实新基线 `MAX(daily.date)=20260828`；设备主库保持 9.22 **不动**
  - 验收：基线为 8.28；单包出包仍得 843,767 行量级

- [ ] Task 1: 【聚合语义】全局一次性确定当期周期 + 增量合并（周/月/季/年统一）
  - [ ] SubTask 1.1: 先**核对现状**：确认 `txt_patch_builder.py:501-518` 对 `append` 已是「基线该周期尾部 + 新日线」增量合并、只有 `rewrite` 全量重算（把结论写进报告）
  - [ ] SubTask 1.2: 开局**一次性**由基线最大交易日推出**当期**周/月/季/年四个周期，作为「可能不完整」的候选集；**不得**在每个标的里重复判断
  - [ ] SubTask 1.3: 每个标的只对**被新数据触及的周期**做一次索引范围查询取基线 bar，与新日线**合并**（open 取周期首行、high/low 取极值、close 取末行、vol/amo 累加）；基线无该周期 bar → 直接用新数据聚合
  - [ ] SubTask 1.4: 把该逻辑从周/月**扩展到季/年**（口径：季 `YYYYQ`、年 `YYYY`；`date` = 该周期首个交易日）
  - [ ] SubTask 1.5: 确认停牌标的（新数据为空）不产生任何 bar
  - 验收：常态 `append` 只重算 1~2 个周期 bar；`rewrite` 全量重算；`--self-check` 抽样验证季/年线「不多不少」

- [ ] Task 2: 【差分路径】补丁携带五张表
  - [ ] SubTask 2.1: `live_db_builder.build_bucket_file` 增加 `periods` 参数（默认 `PERIODS`）
  - [ ] SubTask 2.2: 补丁出包时传 `periods=('daily','weekly','monthly','quarterly','yearly')`
  - [ ] SubTask 2.3: 设备端 `apply-patch`（单包）与会话 `apply` 的表列表都加 `quarterly` / `yearly`（主库缺表则跳过）
  - 验收：补丁新增约 2.3 万行 / 2.1 MB；应用后主库 `quarterly.MAX(date)`、`yearly.MAX(date)` **前移**（不再停在 20260806）

- [ ] Task 3: 【每日路径】当期季/年 bar 写进**增量库**
  - [ ] SubTask 3.1: 定位每日定时链路（`WatchlistSyncManager` / 东财直连）写增量库的收尾处
  - [ ] SubTask 3.2: 对受影响标的，用「**主库当期 bar ⊕ 新日线**」合并出当期季/年 bar，写入**增量库**（`live_quarterly` / `live_yearly`）
    - MUST NOT 只用增量库窗口内的几天（否则写坏完整周期值）
    - 当期周期允许是进行中的（与 `aggregate_full_periods` 既有约定一致）
  - [ ] SubTask 3.3: 记录代价（受影响标的数 × 2 行）与耗时
  - 验收：跑一次每日更新后，增量库里受影响标的的当期季/年 bar 已含当日数据，且值 = 「主库当期 bar ⊕ 新日线」手算结果

- [ ] Task 4: 【增量库发布五张表 + 周期感知裁剪】
  - [ ] SubTask 4.1: `LiveDataStore` 发布 `live_quarterly` / `live_yearly`（不再对季/年线返回 nil）；查询层统一「live 覆盖 main」
  - [ ] SubTask 4.2: 裁剪改为**周期感知**：季/年线只保留**当期**（`date >= 当期起始`），旧周期 bar 删掉 —— 否则旧 bar 会在后续主库更新后**遮蔽**主库正确值
  - [ ] SubTask 4.3: 核对日/周/月的裁剪行为**不变**
  - [ ] SubTask 4.4: `build_and_deploy.py` 部署
  - 验收：季/年线视图走「live 覆盖 main」；当期 bar 不被裁、更早周期 bar 被裁；日/周/月行为不变

- [ ] Task 5: 【设备侧会话】`POST /sync/patch-session/{begin,apply,commit,rollback}`
  - [ ] SubTask 5.1: **独立 sqlite3 连接**打开主库 + 会话级 pragma（**硬要求**：MUST NOT 用 App 的共享连接开事务）
  - [ ] SubTask 5.2: `begin` → `BEGIN IMMEDIATE`；`apply?name=` → `ATTACH` + 写**五张表** + `DETACH`；`commit` → `meta.last_date`（`MAX(...)` 防回退）+ `COMMIT` + 关连接 + `loadMetaList()` + `notifyMainDBChanged()`；`rollback` → `ROLLBACK` + 关连接
  - [ ] SubTask 5.3: **看门狗 120s（2 分钟）**无进展 → 自动 `ROLLBACK` + 关连接
    - 取 2 分钟而非 30s：冷缓存下 PC 单分片出包 / 设备单分片写入都可能到十几秒，30s 会误杀「正常但慢」的会话
  - [ ] SubTask 5.4: 文件名逐个做与 `apply-patch` 同规格的安全校验；任一步失败整体回滚并返回原因
  - [ ] SubTask 5.5: **原 `POST /sync/apply-patch` 保持可用且语义不变**
  - [ ] SubTask 5.6: `build_and_deploy.py` 部署
  - 验收：4 片通过 4 个 `apply` 请求喂入、1 次 `commit` 提交；`dataVersion` **只自增一次**；失败整体回滚；弃置 120s 后看门狗自动回滚

- [ ] Task 6: 【设备端 APPLY 提速】量测后决定
  - [ ] SubTask 6.1: 在本机 1.4GB 库**副本**上对比两种写法耗时与语义（命中改值 / 新日期插入 / 未命中丢弃 / 行数正确）
  - [ ] SubTask 6.2: 仅当**快 ≥20% 且语义正确**才改 Swift 并 build+deploy 真机验证
  - [ ] SubTask 6.3: 收益不足 20%，**或出现读写失败 / 未写成功等任何问题** → 放弃并记录，接受 21.5s 作为下界
  - 验收：给出「采用 / 放弃」结论与实测耗时对比

- [ ] Task 7: 【大文件下载 + 手动核对】
  - [ ] SubTask 7.1: 修掉 1.4GB 下载 503（改流式返回，不整份读进内存）
  - [ ] SubTask 7.2: 新增 `TrollRestore/verify_main_db.py`（**手动触发**）：拉设备主库到本地，核对五张表 `MAX(date)`、3611 只标的日线末日、缺口（抽样含指数）、抽查取值（含 1 只 rewrite 标的）
  - [ ] SubTask 7.3: 确认**流水线内不做 db 内容校验**、日志只打印标量
  - [ ] SubTask 7.4: `build_and_deploy.py` 部署
  - 验收：`verify_main_db.py` 能拉下 1.4GB 并给出核对报告；流水线日志无大块数据

- [ ] Task 8: 【编排器】新增 `TrollRestore/sync_pipeline.py`
  - [ ] SubTask 8.1: 一次 `sandbox_cli.forward()` 并全程保持；与 PC 首批出包**并发启动**
  - [ ] SubTask 8.2: PC 侧 `--shards N --workers W` 并行出包；分片产出后**立即 PUT + 立即 apply**（与 PC 后续分片**完全重叠**）
  - [ ] SubTask 8.3: 全部片 apply 成功后 `commit`；最后清增量库 + reload（各**一次**）
  - [ ] SubTask 8.4: 逐份打印「出包 / PUT / APPLY」耗时与状态；任一步失败 → `rollback` 且**不**清库
  - 验收：N=4/W=4 一次跑通，`commit` 返回 `ok:true`，总耗时显著低于 57.8s

- [ ] Task 9: 【实测与调参】
  - [ ] SubTask 9.1: 跑 N=4/W=4，记录总耗时与分段耗时（对照串行基线 57.8s）
  - [ ] SubTask 9.2: 再跑 (N=2,W=2) 与 (N=6,W=6)，选**稳定且最快**的组合
  - [ ] SubTask 9.3: **手动跑 `verify_main_db.py` 全量核对**（五张表 `MAX(date)`、3611 只末日、缺口、抽查取值）
  - [ ] SubTask 9.4: **观察设备日志**在长事务窗口内有无 `SQLITE_BUSY` / 写失败 / 界面异常
  - [ ] SubTask 9.5: 实测数字写入 `tasks.md` 与 `.trae/documents/live-sync/` 对应篇
  - 验收：总耗时显著低于 57.8s；全量核对通过；无 BUSY/异常；给出推荐 N/W 与理由

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
| 待填 | — |

## 实测对照（待填）

| 方案 | 总耗时 | PC 出包 | PUT | APPLY | 备注 |
| :--- | ---: | ---: | ---: | ---: | :--- |
| 串行基线（单包，仅日/周/月） | 57.8s | 25.4 | 5.9 | 21.5 | 已实测 |
| 流水线 N=2/W=2 | — | | | | |
| 流水线 N=4/W=4 | — | | | | |
| 流水线 N=6/W=6 | — | | | | |
| **推荐** | — | | | | |

## Task 6 量测结论（待填）

| 写法 | 耗时 | 语义正确 | 结论 |
| :--- | ---: | :--- | :--- |
| `INSERT OR REPLACE`（现状） | — | ✅ | — |
| `UPDATE ... FROM` + `INSERT ... WHERE NOT EXISTS` | — | — | 采用 / 放弃 |

## 全量核对结论（Task 9.3，待填）

| 检查 | 结果 |
| :--- | :--- |
| daily / weekly / monthly / quarterly / yearly 的 `MAX(date)` | — |
| 3611 只标的日线末日 = 20260922 | — |
| 缺口（抽样含指数） | — |
| 抽查取值（含 1 只 rewrite 标的） | — |