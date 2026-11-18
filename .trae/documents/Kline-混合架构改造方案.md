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
| ~~Home / Market / Favorites 的实时列表与行情 widgets~~ | **2026-11-18 终局决策：实时页面 Web 化（§7 终局版）**，本条失效；高频行情以秒级快照推送支撑，P2 逐页验证刷新节奏 |
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

## 7. 分阶段实施路线（2026-11-18 终局版：实时页面 Web 化定案）

> **终局形态：全 App UI 走 Web，原生只留三样——K 线图表（全屏组件）、数据/同步层、Python 引擎。** 图表承载方式：Web 页面点击标的 → 桥接 → 原生 KlineDetailView 全屏覆盖（现有 DetailRouter 模式，零新增机制）。每阶段独立可构建、可单独装机、经用户真机验收后进入下一阶段。

| 阶段 | 内容 | 验收标准 |
| --- | --- | --- |
| P0 桥接骨架 ✅ | 已完成（Build #616：RTT 8~14ms、内存增量 ~1MB） | 已验收 |
| P1 Web 基建 + 试点页可交互 | KlineHTTP `/web/` 调试路由（PC 浏览器直开真机页面）；基础组件库（Element Plus 蓝本摘取）；快照写回规范 v2；Profile/Training/Backtest 可交互；注入采样日志清理 | PC 浏览器调试循环跑通；三页写操作全部落原生 Store；主题实时跟随 |
| P2 实时页面逐页 Web 化 | 每页一个批次 = 撤该页布局系统（布局退役并入）+ Vue 重写 + 行情快照推送通道 + 装机替换；建议次序 Favorites → Market → Home → Simulation（低频→高频，Simulation 最重放最后，可调） | 每批功能对齐原生版；行情刷新节奏不掉点；原生图表页零回归 |
| P3 收尾 | Formula/Trading/Backtest 等剩余编辑器栈迁移；协议 golden 锁 CI；布局系统全量清除复核 | 全 App 无 PageLayout 残留；协议 fixtures 两端对拍通过 |

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

## 9. 决策记录（2026-11-18 用户拍板）

1. **试点页铺开暂缓**：P1 启动前先对齐方案细节（见 §11），避免返工；首批页面候选仍为 Profile / Training / Backtest，启动时间由用户定。
2. **组件库（双蓝本）**：自绘但**非从零发明**——蓝本 = **Element Plus（信息密度 / 表单 / 表格类）+ Vant（移动端交互类：手势 / 下拉 / 轻提示 / 滚动）**，重写为贴合项目规范的自有轻组件（44pt 触达、语义色、KlineTheme CSS variables 映射、Safari 15 兼容由 agent 把关），不整体引入第三方库。源码注释标明参考来源。

   **双蓝本裁决顺序**（Agent 摘组件时按此裁决，不摇摆）：
   1. 交互规格（触屏手势、下拉、滚动、轻提示停留时长）→ **优先跟 Vant**；
   2. 信息密度与表单 / 表格类布局 → **优先跟 Element Plus**；
   3. 两者冲突 → **以当前页面已落地的视觉 token 为准**：新组件向已有 token 对齐，而不是向某个库对齐。

   已随 P0 实施锁定（KCard/KCell/KSwitch/KSelect/KDialog/KButton 六件套）。
3. **分发**：**长期随 IPA 内嵌**（CI npm build → bundle 根 `WebUI/`），热更通道**取消**——原 P3 的 web-ui.zip 热更项从方案移除。
4. **目录**：仓库根 `Web/`（pbxproj 同步组约束），已实施定案。
5. **布局系统整体退役（方向决策，执行另行安排）**：Web 开发循环（任意 PC、无需 macOS，agent 直接开发/测试 UI 布局与样式）使设备端可视化布局体系失去存在意义——PageLayoutEditorView 等编辑器、PageLayout JSON 布局引擎、四页 A/B/C/D 布局切换**后续均可删除**，每页只保留一套布局（agent 在 PC 上开发维护）。涉及几十个文件的退役专项：分页分批删、每批独立可编译可装机验收，不与 P1 抢窗口；本轮不动代码。
6. **协议 golden**：P1 落 fixtures + 两端解析测试，暂不锁 CI；P2（编辑器栈铺开）开工前收紧进 CI。

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

**P0 验收实测（Build #616，iPad mini 4 / iOS 15.8.8，2026-11-18）**：桥接往返页面实测 **8~14ms**（Swift 处理 0.35~1.26ms）；WebView 打开前后 phys_footprint 54.2→55.1MB（**App 进程增量 ~1MB**；WKWebView 内容进程独立不计入，整包口径 P1 前用 Xcode 内存报告补测）；theme.get→snapshot→ping 链路间隔 <50ms；`reportRtt`/`jsdiag` 持续落日志。

**P0 排障沉淀（三轮装机定位，教训价值高）**：
1. `JSONSerialization.data(withJSONObject:)` 对 **top-level String（JSON 文本）在 iOS 真机上返回失败**（isValidJSONObject 同样拒绝）——PC 上习惯性依赖它编码字符串字面量，真机全灭。JS 字符串字面量必须手工转义（`WebBridgeJS.jsStringLiteral`）。
2. ES module 顶层导出**不会自动挂到 window**——`window.klineBus` 需显式赋值（klineBus.ts 末尾），否则 Swift 侧 `window.klineBus.dispatch` 引用 undefined。
3. 排障方法论：响应全丢 + 零错误日志的矛盾，靠「时间链取证（6s = 页面超时值）」+「注入串构造失败日志」+「完成回调采样」三层探针收敛；桥接边界（klineBus 字符串入参兼容、全局异常回报 jsError）已内建防御与自报通道，后续 Web 页排障直接读日志。

---

## 11. 方案待对齐清单（P1 启动前逐项确认）

> 用户要求：铺页面前先了解清楚方案，避免返工。按影响面排序。

1. ~~实时页面的最终归属~~ **已定（2026-11-18）：实时页面 Web 化**，逐页推进（建议次序 Favorites → Market → Home → Simulation，可调）；布局退役并入各页批次执行。图表恒为原生全屏组件（DetailRouter 模式承载）。
2. **布局系统退役专项规划**：删 PageLayout 引擎四件套（Schema/Renderer/WidgetRegistry/ConfigStore）+ PageLayoutStore/TradingLayoutStore + 编辑器全家 + 四页 ×3 套备用布局 View + 个人中心五个布局设置行；每页留一套布局（选型待定：Home 现默认 B，Market/Favorites/Simulation 执行时定）。清点引用面后分页分批执行，每批装机验收；与 P1 页面铺开的先后次序由用户定。
3. **Web 页导航模式**：已验证「个人中心 → 全屏 overlay」一种；是否需要 Tab 内嵌 Web 页（与底部导航共存）的形态待定。
4. ~~PC↔设备 Web 调试通道~~ **已实现（2026-11-18，Build #619→#626）**：
   - 设备侧：KlineHTTPServer `GET /web/` 静态路由托管 bundle 内 WebUI dist + **`POST /bridge` PC 调试桥**（HTTP 信封 → WebMessageRouter 同一分发，真机 messageHandler 与 PC 通道无关共用；主线程跳转 + 回环门禁）；
   - Web 侧：klineBus **传输三态**（native 真机 messageHandler / pc `fetch('/bridge')` 同步请求响应 / none 占位），PC 模式真数据真写回（无事件推送，写回后回读权威状态）；
   - PC 侧：`TrollRestore/web_debug_tunnel.py` USB 隧道（python -m pymobiledevice3 usbmux forward；**WMI 分离启动 + 命名互斥单实例锁**；踩坑记录：pip .exe shim 与真实 python 进程生命周期不同步致 poll 误报、stdin=DEVNULL 致子进程 EOF 自杀、多 daemon 堆积互杀——均已修复）；
   - **用法**：PC 终端跑 `python web_debug_tunnel.py` 常驻 → 浏览器开 `http://127.0.0.1:5051/web/`（真数据真写回，Vant 深浅色跟随）；Agent 侧验收 = WMI 起 daemon + 浏览器自动化（路由/DOM/console/写回动作）+ debug_log 侧写，端到端自证无需用户参与；
   - 已知边界：pc 模式「内存足迹」显示 —（app.memory 为 native 事件推送，P2-1 改为主动拉取）；RTT 经 USB 隧道 ~50ms（真机直连 8ms）。
5. ~~状态快照写回规范~~ **已实现（2026-11-18，协议 v2）**：规范事实源 = [Web/src/types/protocol.ts](../../Web/src/types/protocol.ts)（信封/动作清单/事件清单/错误码表/写回模式完整文档注释）；fixtures 对拍样例 `KlineTests/Fixtures/bridge_protocol.json` + 解析测试 `WebBridgeProtocolTests.swift`（CI KlineTests 任务执行）；首个写回动作 `theme.set` 已落地（幂等、写回不回推快照——状态统一走 theme.changed 事件链路）。**P2 扩展预留**：market.snapshot 行情秒级快照通道。
6. **注入采样日志清理**：`injectionSampleRemaining` 取证已完成，P1 移除。

---

## 12. P2 前置护栏（2026-11-18，P1 闭环后、P2 开工前落定）

### 12.1 Vant 首个组件的三项真机验证清单

首个 Vant 蓝本组件 = **KPullRefresh（下拉刷新）**，Favorites 页直接要用。每个新摘组件验收必须过三项：

1. **触达与手势**：命中区 ≥44pt；手势（下拉刷新阈值触发、回弹）与页面滚动无冲突；无桌面化交互残留（不依赖 hover）；
2. **主题三态**：组件全部颜色走 `--k-*` tokens，日间 / 夜间 / 跟随系统切换无残留色、无对比度失效；
3. **体积与帧率**：单组件 dist 增量 ≤15KB gzip；真机（调试通道目测）滚动无可感知掉帧。

验收方式：PC 浏览器（`http://127.0.0.1:5051/web/`）看视觉 → 真机（TrollStore 装机）看手势与帧率。

### 12.2 Favorites bus schema（协议 v2 预留，已进 fixtures）

基于 Favorites 模块实读（FavoritesStore schema 5：manualFiles/pinnedFiles/notesByFile/globalPinnedFiles + 公式分组 cachedMatches；标的标识为稳定 `file` 如 `SH#600000`；行情字段 27 项来自 MarketField）：

**预留动作**（P2 实现，Swift 侧可先 stub）：
- `favorites.snapshot` → FavoritesSnapshot（下方 schema；rows 字段按列配置过滤，首批最小集：file/code/name/latestPrice/change/changePct/volume/turnover/lastDate + pinned/note）
- `favorites.refresh` {group?} → {}（下拉刷新触发重拉：手动分组走 MarketRowCache.refresh，公式分组走 refreshFormulaGroup——Web 只发动作）
- `favorites.openDetail` {file} → {}（进原生全屏图表，走 DetailRouter）
- `favorites.setNote` {file, note} → {}、`favorites.setPinned` {file, pinned} → {}（写回，幂等）

**预留事件**：
- `favorites.changed` {reason: "refresh"|"edit"} → 页面收到后**主动拉 snapshot**（拉取 <10ms；全量推送体积大，增量优化留 P2 实测后定）

**Schema 骨架**（fixtures `reserved` 区块承载形状，P2 实现前防漂移）：
```json
{ "tabs": ["全部", "…"], "groups": [ { "id": "…", "kind": "manual|formula", "name": "…",
  "rows": [ { "file": "SH#600000", "code": "…", "name": "…", "latestPrice": 0, "change": 0,
              "changePct": 0, "volume": 0, "turnover": 0, "lastDate": "20261118",
              "pinned": false, "note": "" } ] } ] }
```

进详情路径（Web 动作 → 原生全屏图表）：`favorites.openDetail` → `DetailRouter.shared.item` → KlineDetailView 全屏覆盖（既有模式零新增机制）。
