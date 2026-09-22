# 端到端增量升级闭环（< 60 秒，补丁按行落到设备主库 tdx.db）Spec

## Why

用户要用**新旧两份 txt 目录**走完整链路推到 iPad，效果是：设备沙盒 `tdx.db` 里所有标的都是 `20260922` 且无缺口，
历史有差异的**只更新差异行**，且**整流程 < 60 秒**。

### 关键实测（2026-09-23，本机真跑）

| 项 | 值 | 怎么测的 |
| :--- | :--- | :--- |
| 旧 txt → 新 txt 缺口 | `20260828` → `20260922`（17 个交易日） | 抽读取最后一条数据行 |
| 变更文件 | **3641 / 3641 全部变更**（`stat` 判定 0.07s） | `txt_changes` 实跑 |
| 其中 **纯追加** | **3442**（头 4KB 一致、文件变大） | 全量头 4KB 比对 |
| 其中 **历史被改写** | **195**（头 4KB 不同） | 同上 |
| 仅新目录有（新上市） | **4** | 同上 |
| 改写集合的历史行数 | daily 636,069 + weekly 134,311 + monthly 31,935 = **802,315 行** | 按 file 从基线库查出 |
| 预计新增行 | 3446 × 17 ≈ **58,582 行** | 推定 |
| **补丁总量（上界）** | ≈ **860,897 行 / 77.1 MB**（93.9 B/行） | 计算 |
| USB 吞吐 | **11.2 MB/s** | 64MB 样本实测 |
| **导入这一步** | **585.1 秒（9 分 44 秒）** | 在 `tdx.db` 副本上真跑 `--prev-dir`（不碰真库） |

**结论：现有「先重建 PC 库、再差分」的路线不可能进 1 分钟。**
导入 585.1s 的原因已定位：`--prev-dir` 下 3641 个文件全算「变更」→ 逐文件 `last_size=0` **整文件重读并按全历史 UPSERT**，
等于一次全量重建（约 2300 万行写入）。这与「只改差异」的方向正好相反。

## What Changes

**核心转变：不再重建 PC 库，直接由「新 txt + 基线库」产出差异行。**

```
旧路线（慢）：新 txt --导入--> 重建 tdx.db(585s) --差分--> 补丁 --推--> 设备
新路线（快）：新 txt --与基线库逐行比对--> 补丁 --推--> 设备主库（行级 UPSERT）
```

- **PC 侧新增「txt 直出差分」**：以**基线库**为旧值真相源，逐文件比对，直接产出 `patch_<seq>.db`（沿用既有 `bkt_*` 契约）。
  - **纯追加**文件：文件前 `旧长度` 字节与旧 txt 逐字节一致 ⇒ 其历史行与库内必然相同 ⇒ **只解析尾部新增行**，全部计为 `新增`（不做行级比对）
  - **历史被改写**文件：整文件解析 → 与新/基线库逐行比对 → 只产出**真正不同**的行（复权改写只影响除权日之前，可能只占该文件一部分历史）
  - **仅新目录有**的 file：全部行按新增
  - 分类判定：`txt_changes` 增加 `append / rewrite / new`（按旧长度三处采样比对；**拿不准一律按 `rewrite`**）
- **设备侧新增 `POST /sync/apply-patch`**：把补丁**按行 UPSERT 进主库 `tdx.db`**，用**一条集合式 SQL** 完成映射与写入
  （`INSERT OR REPLACE INTO daily(meta_id,date,...) SELECT m.id, b.date, ... FROM bkt.bkt_daily b JOIN main.meta m ON m.file=b.file`），
  单事务、随后更新 `meta.last_date` 并热刷新。**不替换整文件、不重启、不经过增量库。**
- **彻底去掉全量哈希校验**：本条流程内**不做任何 1.4GB 级全文件读数**。
  只读打开（`mode=ro` + `PRAGMA query_only=1`）即为「不会写坏输入」的机制保证；
  用 `(size, mtime)` 做前后比对（0 次全量读）。**不保留 `--verify-hashes` 这条可选路径**（用户明确不接受该耗时）。

## Impact

- Affected specs: `add-watchlist-intraday-sync`（差分包契约、变更判定）、`add-live-data-auto-sync`（主库合并、热刷新）
- Affected code:
  - 新增 `Kline/src/txt_patch_builder.py`（txt 直出差分；复用 `txt_changes`、`live_db_builder.build_bucket_file`）
  - 修改 `Kline/src/txt_changes.py`（增加 `append/rewrite/new` 分类）
  - 修改 `Kline/Infrastructure/KlineHTTPServer.swift`（新增 `/sync/apply-patch`）
  - 复用 `TrollRestore/push_bucket_usb.py`（推送）、`TrollRestore/diff_live_patch.py`（保留为「比对两个 db」的旧路径，不在本流程）
  - **不改**：`MainDBMerger`、差分包表结构、增量库结构、四时刻自动更新链路

## ADDED Requirements

### Requirement: txt 直出差分（不再重建 PC 库）

系统 SHALL 能在**不重建 `tdx.db`** 的前提下，由「新 txt 目录 + 基线库」产出差异补丁。

- 旧值真相源 = **基线库**（即设备当前主库内容的那份拷贝），不再依赖「先导入一遍」
- 按文件的 `append/rewrite/new` 分类选择路径；`append` 不做行级比对
- 补丁 MUST 只含**真正不同或新增**的行；MUST NOT 含值相同的行
- 补丁表结构与既有契约一致（`bkt_meta` / `bkt_daily` / `bkt_weekly` / `bkt_monthly`）

#### Scenario: 17 日缺口（本次真实场景）
- **WHEN** 3442 个纯追加 + 195 个历史改写 + 4 个新上市
- **THEN** 只有 195 个文件做行级比对；整流程无 1.4GB 级全量读

#### Scenario: 采样漏判
- **WHEN** 历史改写只发生在采样点之间
- **THEN** 会退化为「按 append 处理」→ 该 file 历史不更新。故 SHALL 保留 `--txt-compare content` 严格档，
  并在文档与 help 中写明这是「便宜但有采样盲区」的取舍

### Requirement: 补丁按行落到设备主库

系统 SHALL 提供可脚本化入口，把补丁的行**按主键 UPSERT 进设备主库 `tdx.db`**，
MUST NOT 替换整个 `tdx.db`、MUST NOT 要求重启 App、MUST NOT 依赖增量库中转。

- 映射 MUST 用 `file`（避开 `code` 的 55 处重复）
- 写入 MUST 为**一条集合式 SQL**（不在 Swift 里逐行 bind），单事务，失败 ROLLBACK
- 完成后 MUST 更新 `meta.last_date` 并热刷新（`dataVersion` 自增）
- 响应 SHALL 返回行数统计（日/周/月、覆盖标的数、最新交易日）

#### Scenario: 一次到位
- **WHEN** 推送补丁并触发应用
- **THEN** 主库中这些 `(file, date)` 与补丁逐行一致，`latest_date` 前移到 `20260922`，无需重启

#### Scenario: 失败
- **WHEN** 任一步失败
- **THEN** 整体 ROLLBACK，主库原样，响应含原因

### Requirement: 动工前先量准预算（门槛）

系统 SHALL 在改动设备侧之前，先用**只读原型**量准 PC 侧三段耗时，确认总预算 < 60s 再动设备侧。

#### Scenario: 预算不达标
- **WHEN** A/B/C 实测合计已使总预算超过 60s
- **THEN** 停止实施并回报，不得「先做再补」

## MODIFIED Requirements

### Requirement: 变更判定（原：stat / content / bc 三档）

在原有三档之上增加**每文件的变更类型** `append / rewrite / new`，供直出差分选路径。原三档语义与用法不变。

## REMOVED Requirements

### Requirement: 差分前的 PC 库重建（本次流程内的 `tdx_parser --prev-dir` 全量重写路径）

**Reason**：实测 585.1s，与「只改差异」目标相反，且使 < 60s 不可能。

**Migration**：`tdx_parser.py` 的 `--prev-dir` / `--rebuild` 保留不动（仍是「重建本地库」的正当工具，
例如用户想在 TDX 客户端补全量后重建一次）；但**本流程不再调用它**。
本流程改用 `txt_patch_builder.py` 直出差分。

## 分阶段预算（实测锚点 vs 待实测）

| 阶段 | 预算 | 依据 |
| :--- | ---: | :--- |
| A 分类 + 解析候选行 | ~20s | **实测锚点**：头 4KB 分类 3641 文件 = 18.6s（2 次打开/文件；开销与读的字节数无关，是 OS/杀软）。与解析合并做，不再增加打开次数 |
| B 改写文件行级比对（txt vs 基线库） | ~10s | 195 个文件 ≈ 97.5 万行；**待实测** |
| C 出包写盘 | ~3s | **实测锚点**：25 万行出包 2.0s |
| D 推送 | ~7s | **实测**：77.1MB ÷ 11.2MB/s |
| E 设备端行级 UPSERT 进主库 | ~10s | **实测锚点**：25.2 万行合并 1.3s；主库更大 + meta 更新，按 2× 估 |
| **合计** | **~50s** | 余量约 10s |

**预算达标的前提**：B 段实测后补丁体积不显著超过 77.1MB 上界（改写文件只产出真正不同的行，实际应更小）。
若 B 段实测使合计超 60s，按「动工前先量准预算」这条 Requirement 停下回报。

## 风险与边界

- **采样盲区**：三处采样判 append 是**便宜但非完备**的；严格档 `--txt-compare content` 可消除，代价约 +30s（不在 1 分钟承诺内）。
- **本地基线需要同步**：补丁在设备侧生效后，PC 本地基线也滞后了。SHALL 提供「把同一补丁应用到本地基线」的步骤
  （行级 UPSERT，预计约 10s），**该步骤不计入本流程的 60s 预算**（可另跑）；否则下一轮差分会把已同步的差异再算一遍。
- **1 分钟依赖缓存状态**：A 段的 18.6s 是逐文件打开开销（机械盘/杀软敏感）。本机 77GB 空闲、目录为本地盘，预计稳定。
- **不改**：`MainDBMerger` 的合并语义（仍服务于 App 内手点场景）、四时刻自动更新链路、增量库查询语义。
- **保留旧路径**：`diff_live_patch.py`（比对两个 db 出包）仍可用，用于「基线 vs 新库」的常规差分；本流程只是不再依赖它重建库。