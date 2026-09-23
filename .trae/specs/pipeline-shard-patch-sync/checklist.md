# Checklist

> 勾选依据：**代码级核对** 或 **本次真跑输出**（命令 stdout / 设备日志 / 核对报告可查）。

## 前置：干净基线（Task 0）

- [ ] `tdx_baseline.db` 已从 `tdx.db`（8.28）重新复制，且 `MAX(daily.date) = 20260828`
- [ ] 设备主库**未被改动**（仍是 9.22）—— 本 spec 明确**不需要还原设备**
- [ ] 前置自检：单包出包仍得 843,767 行量级

## 聚合语义：增量合并（Task 1）

- [ ] 已核对并记录：现状 `append` 是**增量合并**、只有 `rewrite` 全量重算（附代码位置）
- [ ] 当期周/月/季/年四个周期是**开局一次性**确定的（**不是**每个标的分头判断）
- [ ] 每个标的只对**被新数据触及的周期**做一次索引范围查询取基线 bar
- [ ] 合并规则正确：`open` 取周期首行、`high/low` 取极值、`close` 取末行、`vol/amo` 累加
- [ ] 基线无该周期 bar → 直接用新数据聚合
- [ ] 季/年线口径与 `tdx_parser.period_key` 一致（季 `YYYYQ`、年 `YYYY`；`date` = 周期首个交易日）
- [ ] **只有 `rewrite` 才整只标的全量重算**（常态 `append` 不重算全周期）
- [ ] 停牌标的（新数据为空）不产生任何 bar
- [ ] `--self-check` 抽样验证季/年线「不多不少」

## 五张表 · 三条路径

### 差分路径（Task 2）
- [ ] `build_bucket_file` 增加 `periods` 参数，**默认值与现状一致**
- [ ] 补丁包含 `bkt_quarterly` / `bkt_yearly`
- [ ] 设备端 `apply-patch`（单包）与会话 `apply` 的表列表都含 `quarterly` / `yearly`
- [ ] **实测**：补丁新增约 2.3 万行 / 2.1 MB
- [ ] **实测**：应用后主库 `quarterly.MAX(date)`、`yearly.MAX(date)` **前移**（不再停在 20260806）

### 每日路径（Task 3）
- [ ] 受影响标的的当期季/年 bar 写进**增量库**
- [ ] 数据源是「**主库当期 bar ⊕ 新日线**」，**不是**只用增量库窗口内的几天
- [ ] 当期周期允许是进行中的（与 `aggregate_full_periods` 一致）
- [ ] 已验证：值与手算结果一致；已记录代价与耗时

### 全量路径（Task 3 → 见 Task 2 验收中的验证项）
- [ ] 已核实 `tdx_parser` 产出五张表且口径一致（附证据：行数、`MAX(date)`、代码位置）
- [ ] 文档记明「全量路径无需改代码」

## 增量库发布五张表（Task 4）

- [ ] `LiveDataStore` 发布 `live_quarterly` / `live_yearly`（不再返回 nil）
- [ ] 查询层统一「live 覆盖 main」
- [ ] 裁剪是**周期感知**的：当期季/年 bar **不被删**、更早周期 bar 被删
- [ ] 日/周/月裁剪行为**未变**
- [ ] 已部署

## 设备侧会话（Task 5）

- [ ] 会话使用**独立 sqlite3 连接**（**不是** App 的共享主库连接）
- [ ] `begin` → `BEGIN IMMEDIATE`；`apply?name=` → `ATTACH` + 写**五张表** + `DETACH`；`commit` → `meta.last_date`（`MAX(...)` 防回退）+ `COMMIT` + 关连接
- [ ] `rollback` 可用；失败时整体回滚
- [ ] **看门狗 120s（2 分钟）**无进展自动 `ROLLBACK` + 关连接
- [ ] 文件名逐个做与 `apply-patch` 同规格的安全校验
- [ ] `commit` 后 `loadMetaList()` + `notifyMainDBChanged()`
- [ ] **`dataVersion` 只自增一次**
- [ ] 原单包 `POST /sync/apply-patch` **未改动**、仍可用
- [ ] 已部署

## 设备端 APPLY 提速（Task 6）

- [ ] 已在本机 1.4GB 库副本上量测两种写法的耗时
- [ ] 语义核对：命中改值 / 新日期插入 / 未命中丢弃 / 行数统计正确
- [ ] 结论明确：**收益 ≥20% 才落地**；不足或有任何读写异常 → 放弃并记录，接受 21.5s 下界
- [ ] 若落地：真机验证行数、`latestDate`、抽查值一致

## 大文件下载 + 手动核对（Task 7）

- [ ] `GET /sandbox/<path>` 能流式下载 1.4GB（不再 503）
- [ ] `TrollRestore/verify_main_db.py` 可手动跑并输出核对报告
- [ ] **流水线内不做 db 内容校验**；日志只打印标量，**没有**大块库内容

## 编排器（Task 8）

- [ ] usbmux forward **只建立一次**并全程保持
- [ ] forward 建立与 PC 首批出包**并发**
- [ ] PC 侧 `--shards N --workers W` **并行**出包（总耗时显著低于 25.4s）
- [ ] 分片产出后**立即 PUT + 立即 apply** → 设备落库与 PC 出包**完全重叠**（日志时间线可见）
- [ ] 全部片 apply 成功后 `commit`；清增量库 + reload 各只做**一次**
- [ ] 失败时报进度、`rollback`、**不**清库

## 实测与调参（Task 9）

- [ ] N=4/W=4 跑通，`commit` 返回 `ok:true`
- [ ] 记录了 (N=2,W=2) / (N=4,W=4) / (N=6,W=6) 的总耗时与分段耗时
- [ ] **总耗时显著低于串行基线 57.8s**（预期 ~25s，Task 6 有效则 ~18s）
- [ ] **手动全量核对通过**：五张表 `MAX(date)`、3611 只末日 = 20260922、缺口、抽查取值
- [ ] **设备日志在长事务窗口内无 `SQLITE_BUSY` / 写失败 / 界面异常**
- [ ] 给出推荐 N/W 及理由
- [ ] 实测数字写入 `tasks.md` 与 `.trae/documents/live-sync/` 对应篇

## 硬约束回归

- [ ] 增量库「同一 date 以增量库为准」的合并规则未变（只是新增两张表参与）
- [ ] 单包路径（`--shards 1` + `apply-patch`）行为不变
- [ ] `MainDBMerger` 未改动
- [ ] 四时刻自动更新链路未受影响（除 Task 3 新增的季/年线写入）
- [ ] PC 侧对基线库仍只读打开；写只发生在显式 `--yes` 的 `apply_patch_local.py`
- [ ] `meta.last_date` 防回退的 `MAX(...)` 兜底仍在（会话 `commit` 里也要有）

## 待用户确认

1. 流水线跑完后打开 Kline，确认自选/K线图显示到 9.22 且未重启
2. **切到季线/年线视图**，确认最后一根已到 2026Q3 / 2026
3. 触发一次**每日定时更新**，再切季线/年线，确认当期 bar 已含当日数据
4. 是否要单独立项 `POST /sync/replace-main`（取代已退役的手动导入按钮）