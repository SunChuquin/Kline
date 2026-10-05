# 局域网设备联机同步（个人中心入口）Spec

## Why

用户在同一个局域网内有多台设备（模拟器 / 真机）都装着 Kline。目前沙盒配置（自选 / 模拟 / 布局 / 指标公式）与数据库（主库 tdx.db、增量库 tdx_live.db）只能在单台设备上各自维护，换设备要靠电脑中转。目标：在**个人中心**新增「联机同步」入口，让设备按需把自己的内容**暴露**给同网段其他设备，由对方**主动拉取**，实现选择性地同步沙盒配置乃至主库 / 增量库。

## 隐私与安全模型（用户明确要求）

- **默认隐藏且不扫描**：App 启动、进入联机同步页面均不注册 Bonjour 广播、不启动浏览。
- **暴露 = 持续开关**：仅当用户点击「暴露」后才对外广播（`_klinesync._tcp`）；直至退出联机同步页面或再次点击取消暴露。
- **扫描 = 单次**：点击「扫描一次」只浏览约 4 秒自动停止，结果保留；绝不常驻扫描。
- **仅拉取，绝不推送**：主动触发方只能把对端内容拉到**本机**（覆盖本机前先备份本机原文件）；代码层面不存在向对端写文件的路径，对端设备永远不会被别人覆盖。
- **暴露即授权**：对端处于暴露态时自动签发会话 token；未暴露的设备拒绝配对（403）。
- 传输 sha256 校验，失败即弃置临时文件；大文件（主库 GB 级）流式传输 + 临时文件原子替换。

## What Changes

- **新增个人中心「联机同步」入口**：ProfileDetailView 增加一行设置项（样式同"Python 引擎实验室"），点击打开全屏 `LANSyncView`。
- **手动暴露**：`LANSyncAdvertiser`（NetService publish）仅在暴露开启时广播本机 5051 服务；退出页面自动下线。
- **单次扫描 + 手动直连**：`scanOnce`（NWBrowser 4s 窗口）发现同网段已暴露设备；手动输入 `IP:端口` 兜底。
- **服务端端点**（KlineHTTPServer）：
  - `GET /sync/status`：既有字段保留 + `device`（名称/版本）+ `items`（6 类内容清单）。
  - `POST /sync/request-pair`：暴露态（或 `KLINE_EXPOSED`/`KLINE_AUTOPAIR` 环境变量）→ 签发 token；否则 403。
  - `POST /sync/backup`、`POST /sync/reload-config`：token 门禁；备份快照与配置/指标/主库热重载（保留给外部脚本与本地流程使用）。
  - 沙盒上传 `.part` 原子化 + 可选 sha256 校验（既有 `/sandbox` PUT，供 PC 流水线，联机同步不使用）。
- **拉取引擎**（LANSyncTransfer，仅拉取）：计划 → 配对 → 本机备份（`Documents/Backups/<时间戳>/`）→ 逐文件流式下载 + sha 比对 + 原子覆盖 → 指标目录镜像清理本机多余 *.tdx → 本机热重载（配置/指标走 `/sync/reload-config` 同款 apply，增量库 `notifyExternalWrite`，主库提示重启）。
- **生效策略**：配置 / 指标 / 增量库同步后本机即时热重载；**主库 tdx.db 替换后提示重启 App**。

**不做**：推送 / 字段级合并 / 跨网段中继 / 后台常驻监听（系统会冻结）。

## Impact

- Affected specs: 无既有 spec 被修改；与 `pipeline-shard-patch-sync`（PC→设备单向）、`add-live-data-auto-sync`（增量库契约）互补不冲突。
- Affected code:
  - `Kline/Profile/ProfileDetailView.swift`（入口行）
  - `Kline/Profile/LANSyncView.swift`（三态页面：设备/配置/进度）
  - `Kline/Infrastructure/LANSyncModels.swift`（wire 契约）
  - `Kline/Infrastructure/LANSyncSupport.swift`（配对/暴露态 + 热重载 + 清单）
  - `Kline/Infrastructure/LANSyncDiscovery.swift`（单次扫描 + Advertiser + 手动直连）
  - `Kline/Infrastructure/LANSyncTransfer.swift`（仅拉取引擎）
  - `Kline/Infrastructure/KlineHTTPServer.swift`（端点扩展）
  - `KlineUITests/LANSyncUITests.swift`（双模拟器联测）

## ADDED Requirements

### Requirement: 个人中心联机同步入口

个人中心 SHALL 新增「联机同步」设置行，点击全屏打开 LANSyncView，显示本机服务状态（真实探测）。

### Requirement: 手动暴露（对外可见性开关）

本机对外可见性 SHALL 完全由用户手动控制：默认不广播；点击「暴露」后开始广播并自动授权配对；退出页面或再次点击即取消暴露并下线。

#### Scenario: 默认隐身

- **WHEN** Kline 启动、用户进入联机同步页面但未点暴露
- **THEN** 局域网内任何设备都发现不了本机（无 mDNS 记录），配对请求被拒（403）

#### Scenario: 暴露与取消

- **WHEN** 用户点击「暴露」开关
- **THEN** 本机以设备名广播 `_klinesync._tcp`（端口 5051）；再次点击或退出联机同步页面后广播停止

### Requirement: 单次扫描发现

点击「扫描一次」SHALL 只进行一次约 4 秒的 Bonjour 浏览后自动停止，展示发现的已暴露设备（名称 / 主机名:端口）；另提供手动 `IP:端口` 直连兜底。

#### Scenario: 扫描一次

- **WHEN** 用户点击「扫描一次」，同网段有设备处于暴露态
- **THEN** 约 4 秒内列表出现该设备并停止扫描；未暴露的 Kline 设备不出现

### Requirement: 仅拉取的选择性同步

主动方 SHALL 只能把对端的指定内容拉取到本机，覆盖本机前 SHALL 自动备份； SHALL 支持 6 类内容多选：自选 favorites.json、模拟 sim.json、页面布局 Layouts/*.json、指标公式（indicator / formula/picker / formula/strategy *.tdx，整目录镜像）、增量库 tdx_live.db(+manifest)、主库 tdx.db。

#### Scenario: 拉取自选

- **WHEN** 用户连接对端、勾选「自选」并开始拉取
- **THEN** 本机 favorites.json 先备份到 Backups/<时间戳>/，再被对端内容原子替换，自选页立即热重载；对端文件不变

#### Scenario: 主库拉取

- **WHEN** 勾选「主库 tdx.db」拉取
- **THEN** 流式下载 + sha256 校验 + 临时文件原子替换本机主库，完成后提示重启 App；对端只读不受影响

#### Scenario: 对端未暴露

- **WHEN** 主动方向未开启暴露的设备发起拉取
- **THEN** 配对被拒，本机提示「对端未开启暴露，无法获取其内容」

### Requirement: 传输完整性

每文件 SHALL sha256 校验，失败删除临时文件并保留本机原文件，可重试；传输有进度 / 速率展示。
