# Kline 混合架构改造方案（Web UI + 原生核心 + Python 引擎）

> 状态：审计稿 v0.1，待用户确认后才进入实施
> 日期：2026-11-17
> 审计方式：三路并行代码摸底（页面耦合 / 桥接协议 / 基础设施），全部结论来自当前仓库实读

---

## 1. 背景与目标

### 1.1 动机

- 管理类 UI（模拟交易、训练、回测、公式、策略、设置）占全仓库约一半代码面积，迭代频繁；
- AI 开发循环（TRAE / Cursor）在 Web + Python 生态中效率更高，SwiftUI 改动需频繁真机验证；
- Web 资源（Vite dist）可以走「引擎包同款」热更通道，**管理 UI 可不重装 IPA 就更新**，缩短「云端构建 → TrollStore 装机」循环。

### 1.2 目标分工

| 层 | 技术 | 职责 |
| --- | --- | --- |
| 原生宿主 | Swift | 系统能力、K线图表、全部状态 Store、数据/同步层、WKWebView 宿主与桥接路由 |
| Web 视图层 | Vue 3 + TS + Vite | 管理类页面的视图与交互（表单、列表、编辑器、报告） |
| 业务引擎 | Python | 业务计算、缠论结构、策略规则（现状保持不变） |

### 1.3 改造原则（渐进式）

1. **图表不动**：Chart/ 目录是全项目最不能动的资产；
2. **Store 不动**：所有 ObservableObject / UserDefaults 状态留在原生，Web 只做视图层；
3. **目录不大迁徙**：Swift 现有布局不动，只新增 `Kline/Web/` 放 Vite 工程；
4. **单页试点先行**：先打通一条低频页面的桥接并真机验证，验收通过后才铺开；
5. **原生页保留不删**：试点期原生实现完整保留，任何 Web 页面失败可整体回退。

---

## 2. 现状盘点（审计结果）

### 2.1 代码面积

全仓库约 160 个 Swift 文件，其中：

- **Chart/ 约 20 个文件**：图表渲染、手势、惯性、光标、图例、缠论绘制，沉淀了几十条渲染规则 —— **铁律留原生**；
- **管理/编辑器 UI 约 70 个文件**：Formula 13、Simulation 13、Trading 11、Profile 9、Home 编辑器 9、Training 6、Backtest 5、Market 配置 5；
- 其余为 App 壳层、数据层（Data/）、基础设施（Infrastructure/）、Python 桥（Python/）。

**关键发现**：仓库已有 JSON 驱动的页面布局引擎（`PageLayoutSchema` / `PageLayoutRenderer` / `PageWidgetRegistry`）—— 布局配置已经 JSON 化、控件注册表与视图构建器解耦。这是 Web 化的现成接缝：Web 侧将来可复用同一份布局 schema。

### 2.2 桥接现状

| 通道 | 形态 | 说明 |
| --- | --- | --- |
| Swift ↔ Python | 临时 JSON 文件交换（`kline_py_<uuid>_in.json` → 子进程 → 输出文件） | 契约：顶层 `ok==true`；消息形态为 **op + payload**（如 `chan.py` 的 `op="chan"`）；另有 `callBin` 二进制零拷贝通道 |
| Python 脚本位置 | `Bundle.main/PyScripts/`（随 IPA 打包） | `chan.py` 等业务脚本在 `Kline/PyScripts/`；Python 运行时引擎仍为独立 Engine.app，有版本配对校验 |
| 设备 HTTP | `KlineHTTPServer`，端口 5051（`KLINE_HTTP_PORT` 可覆盖），DispatchQueue 队列隔离 | 已承载 sandbox 文件读取、LANSync 同步路由、IPA 下载/安装等 JSON 动作 |
| Web ↔ Swift | **不存在** | 全仓库零 `WKWebView` / `WKScriptMessageHandler` / `WKURLSchemeHandler` 使用，桥接宿主是全新工作 |

### 2.3 构建与分发现状

- `build.yml`：main 分支 push 触发（排除 KlineTests / .github / figma 等路径），macOS 云构建 → TrollStore entitlements 注入 + ad-hoc 签名 → `Kline.ipa` → artifact + GitHub Release `latest`；
- `GitHubRemoteUpdate.swift`：IPA 下载已实现 `?t=` 时间戳穿透 CDN 缓存、ZIP 魔数 + 最小体积 + sha256 完整性校验；
- 部署目标 `IPHONEOS_DEPLOYMENT_TARGET = 15.0`（与 iPad mini 4 / iOS 15.8.8 一致）；
- 引擎包历史惯例可复用：`files.sha256` 逐文件校验、`?nc=<epoch>` 穿透缓存、激活前完整性检查。

---

## 3. 分层边界（搬 / 留清单）

### 3.1 铁律留原生

| 范围 | 理由 |
| --- | --- |
| `Chart/` 全部（约 20 文件） | 高频渲染 + 手势 + 缠论绘制，几十条沉淀规则 |
| Home / Market / Favorites 的实时列表与行情 widgets | 行情实时数据高频刷新，Web 桥接不划算 |
| App 壳层：`KlineApp` / `ContentView` / `SidebarDrawer` / `FloatingAccessory*` | 导航壳、手势、生命周期 |
| 全部 Store 与数据层：`Data/`、`Infrastructure/`、各 `*Store.swift`、`Trading/` 纯逻辑（SimStore、SimCondEngine） | 状态必须留在原生，Web 只消费快照 |
| Python 桥 `Python/` 全部 | 现状可用，不重构 |

### 3.2 首批搬 Web（P1 试点，低频 + 低耦合）

| 模块 | 文件 | 核心依赖 | 适配度 |
| --- | --- | --- | --- |
| Profile 设置页 | `ProfileView`、`ProfileDetailView`、`DetailPage`、`ListCard`、`HorizontalScrollCard` | 各配置 Store（只读写回） | 容易 |
| Training 配置与记录 | `TrainingSetupSheet`、`TrainingRecordListView`、`TrainingCondListView`、`TrainingStore`(留) | TrainingStore 快照 | 容易 |
| Backtest 参数与结果 | `BacktestParamView`、`BacktestResultView`、`NetValueChartView`(Web canvas 重绘) | 回测结果快照 | 容易 |

### 3.3 二批搬 Web（P2，编辑器栈）

| 模块 | 文件数 | 说明 |
| --- | --- | --- |
| Simulation 编辑器栈 | ~10 | SimCond 编辑/列表/详情、选标、告警记录、StrategyGenConfirm —— 表单+列表甜点区；需 SimState 快照协议 |
| Formula 中心与策略编辑 | ~8 | 公式编辑器是表单+代码编辑；注意指标预览联动图表仍走原生回调 |
| Trading 交易票据 | TradeTicketView 等低频表单 | 下单动作走桥接，SimStore 留原生 |

### 3.4 远期可选（P3，暂不承诺）

- Home / 页面布局编辑器（9 文件）：依赖 `PageLayoutRenderer` 实时预览联动，难度高、收益中等；
- 「Web 面板 + 原生图表同屏混排」：UIView 无法嵌入 WKWebView，需桥接协议支撑布局同步，列为待评估项，**首期看盘页整页原生，不做拼接**。

---

## 4. Web ↔ Swift 桥接协议 v1

### 4.1 消息信封（对齐提案 + 现有 op+payload 兼容）

```json
// 请求（Web → Swift）
{ "id": "req_001", "module": "training", "action": "start_session", "payload": { "symbol": "SH#600000", "period": "day" } }

// 响应（Swift → Web，按 id 配对）
{ "id": "req_001", "ok": true, "data": { } }
{ "id": "req_001", "ok": false, "error": { "code": "store_not_ready", "message": "..." } }

// 事件推送（Swift → Web，Store 变化广播）
{ "event": "training.state", "payload": { } }
```

**关键设计**：`module: "py"` 时 `action` 直接映射为现有 Swift↔Python 桥的 `op` 透传 → 三层协议同族，不长出第三套方言。

### 4.2 通道

- **Web → Swift**：`WKScriptMessageHandler` 单 channel（`kline`），JSON 字符串传递；
- **Swift → Web**：`evaluateJavaScript` 派发到页面全局 dispatcher（window.klineBus）；
- **模式**：request/response（id 配对）+ 事件推送（快照节流 ≥0.25s，对齐现有 UI 更新节奏惯例）。

### 4.3 状态快照模式

每个 Web 化模块定义一份**只读快照 schema**（如 `training.snapshot`、`backtest.result`）：

- Store 留原生，`@Published` 变化 → 路由层节流后推快照给 Web；
- Web 的所有写操作都是「动作」（action），由原生 Store 执行后回推新快照 —— Web 侧不持有状态，天然避免双状态源。

### 4.4 协议单一事实源

- `Kline/Web/src/protocol/bridge-protocol.ts`（TS 类型定义）+ Swift 侧 `WebBridge/MessageRouter` Codable 镜像；
- 协议样例纳入 golden 测试锁定（两端对拍），防止协议腐化。

### 4.5 加载方式

- **生产**：`WKURLSchemeHandler` 自定义 scheme（`kline://app/`）加载内嵌 dist —— 无 CORS、无 ATS 问题；
- **开发**：`KlineHTTPServer` 新增 `/web/` 静态路由托管 dist → **PC 浏览器直接打开真机页面对着真数据调试**，不用每次装机；桥接层在两种模式下行为一致（同一信封，传输通道抽象）。

---

## 5. Web 资源分发方案

| 方案 | 内容 | 阶段 |
| --- | --- | --- |
| A. 内嵌 IPA（基线） | dist 作为 Bundle 资源随 `build.yml` 出包 | P0/P1 一期 |
| B. 热更通道（二期） | Release 资产 `web-ui.zip` + `files.sha256`；复用 `GitHubRemoteUpdate` 惯例：`?nc=` 时间戳穿透 → ZIP 魔数 + sha256 校验 → 下载到 `Documents/WebUI/<version>/` → 激活前逐文件校验 → `kline://` 按版本加载；校验失败**回退内嵌版** | P3 |

红线：Web 资源**不得进首帧**（懒加载，与 Python 引擎同一条红线）；热更包必须先校验后激活。

---

## 6. 兼容性与性能红线

1. **构建目标**：`vite build.target = 'safari15'`；禁用仅 Safari 16+ 的 CSS/JS 特性（部署目标 15.0 实证）；
2. **组件库**：不用 Element Plus（重），自绘轻量组件，对齐《Kline-设置面板设计规范》《Kline-页面布局设计》；44×44pt 触达、语义色、固定行高防布局变形等既有规范在 CSS 层等效执行；
3. **主题同步**：Web 用 CSS variables，与 `KlineTheme` 建立单一映射表；原生主题变化 → 桥接事件推送 → Web 切换，保证深浅色一致；
4. **内存预算**：iPad mini 4 仅 2GB —— WKWebView 进程目标 **≤150MB**（P0 试点实测，超标即止）；懒加载、页面退出回收；
5. **首帧红线**：WKWebView 不进首帧（与 Python 引擎同一条红线）；
6. **不做同屏混排**：看盘页整页原生，Web 页面为全屏独立导航页。

---

## 7. 分阶段实施路线

> 每阶段独立可构建、可单独装机、经用户真机验收后进入下一阶段（对齐 kline-device-validation-loop 流程）。

| 阶段 | 内容 | 验收标准 |
| --- | --- | --- |
| P0 桥接骨架 | `WebBridge.swift` + `MessageRouter` + Vue3 工程搭建 + 试点页只读版（Profile 设置页） | 真机打开 Web 页正常；桥接往返延迟实测记录；WKWebView 内存增量 ≤150MB；原生功能零回归 |
| P1 试点页可交互 | Profile / Training / Backtest 三页完整可交互；协议 golden 测试入库 | 真机滚动流畅；写操作全部落原生 Store；深浅色主题同步正确 |
| P2 编辑器栈铺开 | Simulation / Formula / Trading 视图迁移 | 每页迁移后原生页仍可回退；SimState 快照协议稳定 |
| P3（可选） | 热更通道 + 布局编辑器评估 | 热更包校验/回退机制真机验证通过 |

---

## 8. 风险与回退

| 风险 | 缓解 |
| --- | --- |
| 2GB 设备内存超预算 | P0 实测门禁；超标即止或降级（减页面/缩快照） |
| iOS 15 WebKit 兼容坑 | safari15 构建目标 + 试点期真机全量回归 |
| 双栈主题/规范漂移 | CSS variables 单一映射表 + 设置面板设计规范等效执行 |
| 协议腐化 | bridge-protocol.ts 单一事实源 + golden 测试锁两端 |
| Web 页面失败 | 试点期原生实现保留不删，可整体回退 |

---

## 9. 待确认决策点（实施前需用户拍板）

1. **首批试点页**：建议 Profile 设置页 + Training 配置/记录 + Backtest 参数/结果，是否认可？
2. **组件库路线**：建议纯自绘轻组件（不用 Element Plus），是否认可？
3. **热更通道**：建议二期（P3）再做，一期只内嵌，是否认可？
4. ~~Web 工程目录：建议 `Kline/Web/`~~ **已定：仓库根 `Web/`** —— pbxproj 为 objectVersion 77 同步组结构，`Kline/` 内一切文件自动吸入 target（node_modules 会污染工程）；dist 经「Copy PyScripts」同款脚本阶段拷入 bundle 根 `WebUI/`（详见 §10）。
5. **协议 golden 测试**：是否纳入 CI（build.yml 目前不跑 Swift 测试，可先落 PC 侧 Python/脚本对拍）？

---

## 10. 实施记录

### P0 桥接骨架（2026-11-17）

**Swift（`Kline/WebBridge/`，同步组自动纳入 target）**

| 文件 | 职责 |
| --- | --- |
| `WebBridgeEnvelope.swift` | 协议 v1 信封 + 常量（channel/scheme/bundleDir）+ JS 注入安全编码（JSON 双重编码避免手工转义） |
| `WebMessageRouter.swift` | module+action 分发：`app`(ping/reportRtt/memory/info)、`theme`(get)、`profile`(snapshot)；事件推送 theme.changed / app.memory；页面就绪门控 |
| `WebUISchemeHandler.swift` | `kline://app/<path>` → bundle 根 `WebUI/`；MIME 映射（js 必须 text/javascript，模块脚本强校验）；".." 路径穿越防御 |
| `MemoryFootprint.swift` | phys_footprint 内存探针（与 Xcode 内存报告同口径） |
| `WebHostView.swift` | 全屏宿主页：懒加载不进首帧；主题推送（onAppear/colorScheme/themeStore 三路）；加载失败明确报错页 |

**Web（仓库根 `Web/`，避开 pbxproj 同步组）**：Vue3 + TS + Vite（target safari15），`klineBus.ts` 桥接客户端（id 配对 + 事件订阅 + NO_BRIDGE 降级），`ProfilePilotPage.vue` 只读快照试点页（版本/主题/同步调度/主库状态/桥接探针卡片）。

**集成**：个人中心新增「Web 试点（P0）」全屏入口（对齐 Python 引擎实验室呈现模式）；「Copy PyScripts」阶段扩展拷贝 `Web/dist` → bundle `WebUI/`（缺失时警告不阻断，宿主页显式报错）；build.yml 在 xcodebuild 前增加 `npm ci && npm run build`；`.gitignore` 排除 `Web/node_modules/` 与 `Web/dist/`。

**验收口径（P0）**：真机打开 Web 页正常渲染；页面探针显示桥接 RTT 与内存足迹（同步落 debug_log）；主题切换实时生效；原生功能零回归。
