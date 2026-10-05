# 局域网设备联机同步（个人中心入口）Spec

## Why

用户在同一个局域网内有多台设备（模拟器 / 真机）都装着 Kline。目前沙盒配置（自选 / 模拟 / 布局）与数据库（主库 tdx.db、增量库 tdx_live.db）只能在单台设备上各自维护，换设备要靠电脑中转。目标：在**个人中心**新增「联机同步」入口，让任意两台设备直连，**选择性**地互相同步沙盒配置乃至主库 / 增量库。

## 现状可复用能力（已核实）

| 能力 | 位置 | 结论 |
| :--- | :--- | :--- |
| 设备端 HTTP 服务 | [KlineHTTPServer.swift](file:///Volumes/home/repositories/Kline2/Kline/Infrastructure/KlineHTTPServer.swift)（前台 `0.0.0.0:5051`，仅前台可用） | 直接复用作传输通道 |
| 流式写沙盒文件 | `PUT/POST /sandbox/<rel>`（KlineHTTPServer.swift:250-259） | 已支持大文件流式落盘 |
| 读 / 列 / 删沙盒 | `GET /sandbox`、`GET /sandbox/<path>`、`DELETE /sandbox/<path>` | 已有 |
| 增量库热重载 | `POST /sync/reload`、`GET /sync/status` | 已有 |
| Bonjour / 设备发现 | 无（全仓无 NWBrowser/NetService） | **需新增** |
| 个人中心入口模式 | [ProfileDetailView.swift:131-147](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileDetailView.swift#L131-L147)（"Python 引擎实验室"按钮行 → 全屏页） | 沿用同一模式 |
| 待同步文件 | `Documents/Favorites/favorites.json`、`Documents/Simulation/sim.json`、`Documents/Layouts/<page>.json`、指标公式目录（`Documents/indicator/<周期>/*.tdx`、`Documents/formula/picker/*.tdx`、`Documents/formula/strategy/*.tdx`，见 FormulaKind.swift:15-17）、`Documents/tdx_live.db`(+manifest)、`Documents/tdx.db` | 见 TdxSyncConfig.swift:53-63 等 |

## What Changes

- **新增个人中心「联机同步」入口**：ProfileDetailView 增加一行设置项（样式同"Python 引擎实验室"），点击打开全屏 `LANSyncView`。
- **新增 Bonjour 设备发现**：现有 5051 `NWListener` 注册 `_klinesync._tcp` 服务（服务名 = 设备名）；新增 `NWBrowser` 浏览同网段设备；支持手动输入 `IP:端口` 兜底（模拟器间 / Bonjour 失效场景）。
- **新增服务端端点**（在 KlineHTTPServer 内）：
  - `POST /sync/backup`：接收方在覆盖前把将被覆盖的文件 / 目录快照到 `Documents/Backups/<时间戳>/`，返回备份路径。
  - `POST /sync/reload-config`：配置 / 指标文件落盘后重载 FavoritesStore / SimStore / PageLayoutConfigStore / SystemIndicatorStore，无需重启 App。
  - `POST /sync/request-pair`：发起方请求配对，接收方前台弹确认框，同意后签发仅本会话有效的 token（后续同步请求 header 携带）。
  - 扩展 `GET /sync/status`：附加设备名、App 版本、可同步内容清单（单文件：路径/字节数/mtime；指标目录：聚合文件数与总字节数）。
- **新增传输引擎**（客户端侧，URLSession）：推送（本机→对端，走已有 `PUT /sandbox/<rel>`）与拉取（对端→本机，走已有 `GET /sandbox/<path>`），流式传输、进度回调、sha256 校验、失败重试；指标目录按文件清单逐文件传输。
- **同步语义 = 文件级整份替换（无合并）**，与现有 USB 整库替换语义一致；指标公式目录为**整目录镜像**（备份后清空对端目录再写入全部文件）。
- **生效策略**：配置 / 指标与增量库同步完成后自动热重载（新增 `/sync/reload-config` + 已有 `/sync/reload`）；**主库 tdx.db 整库替换沿用「启动时打开」语义，完成后提示用户重启 App 生效**。
- **安全**：传输开始前，接收方 App 内弹出确认框（两端都在前台才能传，天然可确认），确认后签发仅本会话有效的 token，后续传输请求带 token；覆盖任何文件 / 目录前先走 `/sync/backup` 自动备份。

**不做**（明确排除）：字段级 / 记录级合并（鸡生蛋问题，超出最小实现）；跨网段 / 云端中继；iOS 系统文件 App 或共享面板集成；后台常驻监听（系统会冻结，现有约束不变）。

## Impact

- Affected specs: 无既有 spec 被修改；与 `pipeline-shard-patch-sync`（PC→设备单向）、`add-live-data-auto-sync`（增量库契约）**互补不冲突**。
- Affected code:
  - `Kline/Profile/ProfileDetailView.swift`（新增入口行）
  - `Kline/Profile/LANSyncView.swift`（新文件：页面 UI）
  - `Kline/Infrastructure/LANSyncDiscovery.swift`（新文件：Bonjour 广播 + 浏览 + 手动 IP）
  - `Kline/Infrastructure/LANSyncTransfer.swift`（新文件：传输引擎）
  - `Kline/Infrastructure/KlineHTTPServer.swift`（新增 3 个端点 + 扩展 status + Bonjour 注册）
  - `KlineUITests/LANSyncUITests.swift`（新文件：双模拟器联测）

## ADDED Requirements

### Requirement: 个人中心联机同步入口

个人中心页面 SHALL 新增「联机同步」设置行，点击后全屏打开联机同步页面，样式与现有"Python 引擎实验室"入口一致。

#### Scenario: 打开联机同步页面

- **WHEN** 用户在个人中心点击「联机同步」行
- **THEN** 全屏展示 LANSyncView，显示本机名称、端口 5051 服务状态（真实探测，非假在线）、以及对端设备列表

### Requirement: 局域网设备发现

系统 SHALL 通过 Bonjour（`_klinesync._tcp`）自动发现同网段运行 Kline 且位于前台的设备，并提供手动 `IP:端口` 直连兜底。

#### Scenario: 双端自动发现

- **WHEN** 设备 A 与设备 B 在同一局域网、两端 Kline 均在前台
- **THEN** A 的设备列表中出现 B（显示设备名、IP、App 版本），反之亦然；点击即可连接（`GET /sync/status` 校验对端为 Kline 且版本兼容）

#### Scenario: 手动 IP 兜底

- **WHEN** Bonjour 发现失败（如模拟器网络隔离）
- **THEN** 用户可在页面内手动输入对端 `IP:端口` 直连，后续流程与自动发现一致

### Requirement: 选择性同步内容与方向

同步页面 SHALL 支持选择传输方向（推送=本机→对端 / 拉取=对端→本机）与同步内容 6 类多选：自选（favorites.json）、模拟（sim.json）、页面布局（Documents/Layouts/*.json）、指标公式（indicator / formula/picker / formula/strategy 三个 *.tdx 目录）、增量库（tdx_live.db + manifest）、主库（tdx.db）。

#### Scenario: 查看对端可同步内容

- **WHEN** 用户连接到对端设备
- **THEN** 页面按上述 6 类列出本机与对端的内容量（单文件显示字节数 / mtime；指标公式显示文件数与总字节数），供对比后勾选

#### Scenario: 选择性推送配置

- **WHEN** 用户勾选「自选 + 模拟」、方向为推送并开始
- **THEN** 仅这两类文件被传输到对端，其余内容不受影响；完成后对端自动重载对应页面数据

#### Scenario: 指标公式整目录镜像

- **WHEN** 用户勾选「指标公式」、方向为推送并开始
- **THEN** 对端先备份原 indicator / formula 目录，随后清空并写入本机的全部 *.tdx 文件；完成后对端公式中心立即反映新指标（SystemIndicatorStore 重载）

#### Scenario: 主库整库同步

- **WHEN** 用户勾选「主库 tdx.db」
- **THEN** 页面明确警示体积与耗时（≈GB 级）、提示"替换后需重启 App 生效"；传输走流式 + 进度条，接收方先落临时文件再原子替换

### Requirement: 传输安全（确认 + 备份）

传输开始前接收方 SHALL 弹窗确认；接收方 SHALL 在覆盖任何既有文件前将其备份到 `Documents/Backups/<时间戳>/`；传输 SHALL 进行 sha256 完整性校验，失败即中止且不替换目标文件。

#### Scenario: 接收方确认

- **WHEN** 设备 A 发起推送到设备 B
- **THEN** B 前台弹出"A 要向你同步以下内容…（清单）"确认框；同意后签发会话 token，A 后续请求携带 token；拒绝则 A 收到失败提示

#### Scenario: 覆盖前自动备份

- **WHEN** B 上将被覆盖的 favorites.json 已存在
- **THEN** B 先将其复制到 Documents/Backups/<时间戳>/favorites.json 再执行替换；主库 / 增量库同理（仅备份被覆盖文件本身，不做整库副本）；指标公式则备份整个目录快照

#### Scenario: 校验失败中止

- **WHEN** 传输完成后 sha256 与源端不符
- **THEN** 删除临时文件、目标文件保持原状，UI 报错并允许重试

### Requirement: 同步后生效

配置 / 指标公式与增量库同步完成后，接收方 SHALL 自动热重载受影响的存储（配置与指标走新增 `/sync/reload-config`，增量库走已有 `/sync/reload`），无需杀进程；主库替换完成后 SHALL 提示用户重启 App。

#### Scenario: 配置热重载

- **WHEN** 对端推送的 sim.json 落盘成功
- **THEN** 接收方 SimStore 重新加载并发布更新，模拟页立即反映新数据，无需重启

#### Scenario: 指标热重载

- **WHEN** 指标公式目录镜像完成
- **THEN** 接收方 SystemIndicatorStore 重载，公式中心 / K线图立即反映新指标，无需重启

#### Scenario: 增量库热重载

- **WHEN** tdx_live.db 替换完成
- **THEN** 走已有 `/sync/reload` 广播数据版本，图表 / 条件单用新数据重查

## REMOVED Requirements

（无）
