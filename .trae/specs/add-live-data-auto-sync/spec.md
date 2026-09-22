# Kline 增量行情库自动同步 Spec

## Why

当前只能**手动**把 Windows 电脑上的通达信数据拷进 Kline 沙盒：收盘后导出 → 生成整库 → 传输 → **杀进程重启 App** 才生效。这导致本地训练的自动化逻辑（委托/条件单/预警）无法用于盘中盯盘。

目标是：在 **Kline 处于前台且未锁屏** 的前提下，交易日自动在 **11:00 / 14:30 / 15:05** 更新 App 内被监控标的的行情数据，使条件单/预警能基于接近当日的新价触发。

**体积实测（决定架构）**：仓库内现有 `tdx.db` 只含 1 只标的（上证指数，8711 根日线 = 966 KB）→ 单行成本 ≈ **111 字节/根K线**。按此推算全库（1 GB+，用户实机主库）**不可能**走云端；而"并集清单标的的最近 N 根"只有几百 KB。因此：

| 库 | 内容 | 更新方式 |
| :--- | :--- | :--- |
| `Documents/tdx.db`（主库，1 GB+） | 全市场历史K线 | **保持现状不动**（整库替换仍手动，需重启） |
| `Documents/tdx_live.db`（**新增**，增量库） | 并集清单标的的最近 N 根日/周/月/季/年线 | 自动同步（USB / 局域网 / 云端），**无需重启** |

## 方案选型（已与用户确认）

**采纳**：A USB 一键直推 · B 局域网 WiFi 直推 · C 云端定时 + App 自动拉取（三通道并存，共用同一增量库契约）

**不采纳**：D 快捷指令自动化兜底（用户认为不需要）· E 设备内 root 常驻守护进程（成本高、风险大）

**数据来源**：云端公开行情接口为主（每日 3 次、标的数少，反爬压力极低）+ 电脑通达信导出为兜底

**云端形态**：增量补丁（不替换 1 GB+ 主库，另建增量库）；**清单**：仓库内统一 `symbols` 清单；**时刻**：11:00 / 14:30 / 15:05（北京时间，交易日）

## What Changes

- **新增增量库 `Documents/tdx_live.db`**：与主库同构的多周期K线库，但**以 `code` 为键**（而非主库自增 `meta_id`），从而与主库的 id 分配完全解耦。
- **App 读取层叠加合并**：`DatabaseManager` 查询时"增量库优先、主库补齐"，上层（行情页/自选/K线图/条件单/预警）**零改动**即可看到新数据。
- **热刷新（本 Spec 的关键）**：不再需要杀进程。增量库内容变化后自动重载并广播数据版本，驱动行缓存、条件单扫描、图表重新查询。
- **三通道写入**：USB（`usbmux forward` + 已有 `/sandbox` 接口）、局域网（`http://<设备IP>:5051/sandbox/tdx_live.db`）、云端（App 主动拉取）。
- **新增生成端**：本地脚本 + GitHub Actions 定时任务产出 `tdx_live.db` + `manifest.json`，发布到仓库 `data` 分支，设备经 jsDelivr CDN / raw 多源拉取。
- **新增设置 UI**：`LocalUpdateView` 内「数据同步」分区（开关、数据源、更新时刻、上次更新时间/版本、立即更新、日志、局域网地址）。
- 主库 `tdx.db` 的文件与流程**不改动**（非 BREAKING）；新增 `Info.plist` 局域网权限说明。

## Impact

- Affected specs: 条件单/预警（`SimCondEngine` 触发源 `dataReload`）、行情与自选列表（`MarketRowCache`）、K线图（`KlineDetailView`/`LinkedKlineTile` 的缓存失效）、`LocalUpdateView` 设置面板
- Affected code:
  - 新增 `Kline/Data/LiveDataStore.swift`、`Kline/Infrastructure/TdxSyncManager.swift`、`Kline/Infrastructure/TdxSyncConfig.swift`
  - 修改 [DatabaseManager.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/DatabaseManager.swift)、[MarketRowCache.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketRowCache.swift)、[LocalUpdateView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/LocalUpdateView.swift)、[KlineApp.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/KlineApp.swift)、`Info.plist`
  - 新增生成端 `src/live_db_builder.py`、`src/data/symbols.txt`、`.github/workflows/sync-live-db.yml`
  - 复用 [sandbox_cli.py](file:///c:/Users/sunck/home/projects/ios/TrollRestore/sandbox_cli.py)、[KlineHTTPServer.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Infrastructure/KlineHTTPServer.swift)、`build_and_deploy.py`

## ADDED Requirements

### Requirement: 增量库文件契约

系统 SHALL 在沙盒 `Documents/tdx_live.db` 维护一个以 `code` 为键的 SQLite 增量库，且 SHALL 不修改主库 `Documents/tdx.db`。

表结构（与主库字段语义一致，键改为 `code`）：

```sql
live_meta(code TEXT PRIMARY KEY, name TEXT, type TEXT, updated_at INTEGER)
live_daily(code TEXT, date INTEGER, open REAL, high REAL, low REAL, close REAL, vol REAL, amo REAL, PRIMARY KEY(code, date))
-- live_weekly / live_monthly / live_quarterly / live_yearly 同构
```

配套 `Documents/tdx_live.manifest.json`：

```json
{"version": 3, "generated_at": 1758500000, "trade_date": 20260922,
 "source": "eastmoney", "symbols": 268, "min_date": 20260808, "max_date": 20260922,
 "rows": {"daily": 8040, "weekly": 1608, "monthly": 402, "quarterly": 134, "yearly": 27},
 "sha256": "..."}
```

#### Scenario: 增量库缺失
- **WHEN** App 启动且 `Documents/tdx_live.db` 不存在
- **THEN** App 正常工作，全部查询走主库，同步功能显示"未同步"，不报错、不阻塞

#### Scenario: 增量库损坏
- **WHEN** `tdx_live.db` 存在但无法打开或缺少必需的表
- **THEN** App 记录日志、退化为纯主库读取，并把该库标记为不可用等待下一次同步覆盖

### Requirement: 主库 + 增量库叠加查询

系统 SHALL 在查询任一周期K线时以"增量库优先、主库补齐"的规则合并结果，且 SHALL 以 `code` 建立增量库记录与主库 `meta.id` 的映射。

合并规则：结果 = 增量库该标的所有行 ∪ 主库该标中 `date < 增量库该标最小 date` 的行，按 `date` 降序；同一 `date` 以增量库为准。

#### Scenario: 日线叠加
- **WHEN** 主库某标的日线截至 20260919，增量库含该标的 20260918~20260922 共 3 根
- **THEN** 该标的日线查询返回"20260918~20260922 来自增量库 + 更早的来自主库"，无重复日期、无缺失

#### Scenario: 标的不在增量库
- **WHEN** 查询的标的未被增量库覆盖
- **THEN** 结果与合并前完全一致（等价于纯主库读取）

#### Scenario: 上层零改动
- **WHEN** 行情列表、自选列表、K线图、条件单快照通过既有入口取数
- **THEN** 均能取到叠加后的最新K线，无需改动这些调用方代码

### Requirement: 增量库热刷新

系统 SHALL 在增量库内容变化后自动生效，**不得要求重启 App**。

#### Scenario: 外部通道写入后自动生效
- **WHEN** 通过 USB / 局域网 / 云端任一通道覆盖了 `tdx_live.db`
- **THEN** App 在"前台定时检查（默认 5 分钟）"或"回到前台"时检测到文件变化（mtime 或 sha256 变化），重载增量库、递增数据版本，行情行缓存与条件单扫描被触发，界面显示新数据

#### Scenario: 文件未变化
- **WHEN** 定时检查发现 `tdx_live.db` 的 mtime 与 sha256 与上次一致
- **THEN** 不重载、不刷新缓存，避免无谓的重算与闪烁

### Requirement: 云端发布链路

系统 SHALL 在交易日北京时间 11:00 / 14:30 / 15:05 自动产出并发布增量库，设备侧 SHALL 能从公开 CDN 拉取且无需鉴权。

#### Scenario: 定时产出
- **WHEN** GitHub Actions cron 触发（UTC 03:00 / 06:30 / 07:05，周一至周五）
- **THEN** 读取仓库内统一 `symbols` 清单，从公开行情接口取数生成 `tdx_live.db` + `manifest.json`，提交到 `data` 分支；生成失败时不覆盖上一版

#### Scenario: 设备拉取
- **WHEN** App 到达更新时刻或回到前台且已启用同步
- **THEN** 依次尝试 jsDelivr CDN → raw.githubusercontent → 可配置备用源，校验 `manifest` 的 `sha256` 与行数/日期后原子替换本地增量库；全部失败则保留上一版并在 UI 显示失败原因

#### Scenario: 反爬与稳定性
- **WHEN** 生成端访问公开行情接口
- **THEN** 优先使用可一次返回多标的的批量接口，带 User-Agent、请求间隔限速、指数退避重试（≥3 次）与失败降级；单次生成请求数受控（不发生逐标的数千次请求）

### Requirement: 通道 A/B（电脑在场时）

系统 SHALL 支持电脑侧主动推送增量库，且推送后同样无需重启 App。

#### Scenario: USB 一键直推
- **WHEN** 用户 iPad 连数据线、Kline 前台未锁屏，执行 USB 推送脚本
- **THEN** 经 `usbmux forward 5051` + `POST /sandbox/tdx_live.db` 完成写入，App 在热刷新周期内自动生效

#### Scenario: 局域网直推
- **WHEN** 电脑与设备在同一 Wi-Fi，执行局域网推送脚本并给出设备 IP
- **THEN** 经 `http://<设备IP>:5051/sandbox/tdx_live.db` 完成写入并自动生效；App 的「数据同步」分区 SHALL 显示设备当前局域网 IP 供脚本使用

### Requirement: 同步状态可视化

系统 SHALL 在 `LocalUpdateView` 提供「数据同步」分区，展示并可控：启用开关、数据源地址、更新时刻、上次更新时间与版本、覆盖标的数、立即更新、失败原因、日志入口。

#### Scenario: 状态可见
- **WHEN** 用户打开设置页
- **THEN** 能看到"上次同步时间 / manifest 版本 / 覆盖标的数 / 数据最新交易日"，并区分"未启用 / 已同步 / 同步中 / 失败"四种状态

#### Scenario: 手动触发
- **WHEN** 用户点「立即更新」
- **THEN** 立即执行一次拉取（含多源回退），过程中显示进度，结束时刷新状态与数据

## MODIFIED Requirements

### Requirement: 数据刷新传播（原：仅在启动时读一次）

原实现仅在 `DatabaseManager.init` 打开一次连接，替换文件后必须杀进程重启。修改为：除启动加载外，支持增量库热重载并广播数据版本，使既有 `isLoaded`/缓存失效链路（`MarketRowCache.prewarmMarketData`、`SimCondEngine.sweepConditions(trigger: .dataReload)`、`KlineDetailView.onChange(isLoaded)`）能被增量数据触发。

主库仍维持"启动时打开、整库替换需重启"的既有行为不变。

## REMOVED Requirements

无。

## 风险与边界

- **数据语义**：11:00 / 14:30 两次为盘中快照（当日K线可能未完成），15:05 为当日完整K线；UI SHALL 标注最新交易日与更新时间，避免误判。
- **前台依赖**：iOS 无后台能力（TrollStore 版亦无后台刷新），云端拉取必须 App 前台；这是本方案的硬边界（用户盯盘时前台即可满足）。
- **公开仓库**：仓库为 Public，`symbols` 清单与行情数据会被公开（行情本身是公开数据；清单仅放代码不放备注）。
- **CDN 可用性**：jsDelivr 对 GitHub 文件有缓存延迟，`data` 分支更新后可能需要短时间才可见；因此保留 raw 源与"备用源可配置"。
- **不引入 root 守护**：不做设备内常驻进程，避免 CI 嵌入新二进制与常驻风险。