# Kline P2 全页面 Vant 化改造计划

> 状态：**已全部交付（P2-0 ~ P2-7 完成，2026-11-19）**
> 日期：2026-11-18
> 用户拍板：①Tab 栏保留原生（SwiftUI 底栏不动，四个 Tab 内容页逐页换 Web）②迁移顺序按原计划 Favorites → Market → Home → Simulation，弹层三件套放最后 ③除 K 线图表外所有页面（含图表页内的设置页/指标面板/快捷面板）全部 Vant 实现
>
> 交付记录（commit 序）：P2-0 基建 → P2-1 Favorites → P2-2 Market → P2-3 Home → P2-4 Simulation → P2-5a 弹层容器+设置/搜索 → P2-5b 指标面板 → P2-6a 快捷面板+Web 票面 → P2-6b-1 公式中心 tech 段 → P2-6c-1 LANSync/LocalUpdate/Debug 实验室（全屏 Web 页容器）→ P2-6c-2 Backtest（SVG 净值图）→ P2-6c-3 Training 设置浮层+记录管理 → **P2-7 收尾（布局系统全量清除 + fixtures reserved 转正）**。
> 边界决策：训练态闭环保留原生（K 线训练图表/快捷面板训练态/条件单预警浮层/回放推进 advanceOneBar——回放联动延迟敏感，§5.2 条款）；公式编辑器与选股/策略公式中心保留原生（编辑器语法高亮可后置条款）。

---

## 1. Summary

除 K 线图表（`KlineDetailView` 的图表绘制本体）之外的全部 UI 迁移到 Vue3 + Vant 4 视图层：四个 Tab 内容页、图表页弹层（设置页/指标控制面板/搜索/快捷面板）、全部功能页（Training/Backtest/Formula/Trading/Profile 剩余/Debug 实验室）。原生层收敛为：**K 线图表（全屏覆盖组件）、数据/同步层、Python 引擎、底部 Tab 栏**。状态 Store 全部留原生，Web 只发动作与消费快照（协议 v2 写回模式）。布局系统（PageLayout 引擎 + 编辑器 + 四页 A-D 切换）随各页批次退役。

## 2. 现状盘点（侦察结论）

| 页面/面板 | 现文件 | 呈现方式 | 关键依赖 | 批次 |
| --- | --- | --- | --- | --- |
| 底部 Tab 栏 | `ContentView.swift` bottomMenuBar | **原生保留** | selectedTab | — |
| 自选页 | `FavoritesView` + LayoutA-D + `FavoritesPageKit` | Tab 内容 | FavoritesStore / MarketRowCache / DetailRouter | P2-1 |
| 行情页 | `MarketView` + LayoutA-D + `MarketPageKit` + `MarketColumnConfigPanel` | Tab 内容 | MarketRowCache / MarketConfigStore | P2-2 |
| 首页 | `HomeView` + LayoutA-D + Widgets/ + Editor/ | Tab 内容 | PageLayoutConfigStore / HomeWidgetRegistry（退役） | P2-3 |
| 模拟页 | `SimulationView` + LayoutA-C + `SimCond*` 编辑器栈 | Tab 内容 | SimStore / SimCondEngine | P2-4 |
| K 线图表 | `KlineDetailView` + Chart/ 绘制全家 | **原生保留**（全屏覆盖） | — | — |
| K 线设置页 | `KlineDetailView` settingsOverlay | 图表弹层 | ChartConfigStore | P2-5 |
| 指标控制面板 | `ChartSheetKit`（主图/副图指标格、公式入口、自定义管理） | 图表弹层（底部 sheet） | ChartConfigStore / `KlineChartViewState` | P2-5 |
| 图表搜索面板 | `KlineDetailView` chartSearchBar | 图表弹层 | DatabaseManager | P2-5 |
| 快捷面板 | `FloatingAccessoryPanel` + `QuickPanelLayouts(BC)`（A/B/C 三方案：账户切换/行情头/方向胶囊/交易时段） | 悬浮球弹出（仅图表页） | SimStore / TradingLayoutStore | P2-5 |
| Training | `TrainingSetupSheet`（浮层）/ `TrainingRecordListView` / `TrainingCondListView` | 浮层+页 | TrainingStore / TrainingSessionController（回放联动） | P2-6 |
| Backtest | `BacktestParamView` / `BacktestResultView` / `NetValueChartView`（GeometryReader+Path 手绘） | 页 | 回测引擎 | P2-6 |
| Formula | `FormulaCenterView` / `FormulaEditorView` / `StrategyDetailView` / `StrategyFormulaEditorView` / `StrategyPickListView` | 全屏页 | FormulaEngine / SystemIndicatorStore | P2-6 |
| Trading 票据 | `TradeTicketView` / `TradeTicketKit` | 浮层 | SimStore | P2-6 |
| Profile 剩余 | `LANSyncView` / `LocalUpdateView` | 全屏页 | 各自 Store | P2-6 |
| Debug 实验室 | `PythonEngineLabView` | 全屏页 | PythonEngineHost | P2-6 |

已就位的地基（P1 交付）：klineBus 协议 v2（fixtures 契约测试）、WebTabHost 前身 = 全屏 overlay 式 `WebHostView`、Vant 4.10.2 按需引入、USB 调试隧道、组件库六件套。

## 3. 技术设计

### 3.1 WebTabHost：Tab 内容的通用 Web 容器（P2-0 建）

- **单 WebView 承载四页**：一个常驻 WKWebView 渲染 Vue SPA（vue-router 4 + keep-alive），Tab 栏仍是原生。原生 `selectedTab` 变化 → 推事件 `nav.tab {index}` → Web 切路由；Web 内跳 Tab → 动作 `nav.switchTab {index}` → Swift 改 selectedTab。
- 容器：`Kline/WebBridge/WebTabHostView.swift`（复用 WebUISchemeHandler / router / 主题推送三路机制）；懒创建、切 Tab 不销毁（keep-alive）。
- **渐进替换机制**：`ContentView.mainContentView` 的每个 Tab 分支逐批替换为 WebTabHost；被替换的原生 View 类**保留不删**（回退 = 改回一行分支），布局退役专项单独清。
- Web 端新增 `src/pages/favorites|market|home|simulation.vue`；Vue Router：history 模式改 hash（scheme/HTTP 双通道兼容）。

### 3.2 Vant 主题对接（P2-0 建）

- CSS variables 桥：`theme.css` 中把 `--k-*` 映射到 `--van-*`（Vant 4 官方变量体系），如 `--van-primary-color: var(--k-accent)`、背景/文字/边框全套；`[data-theme='dark']` 覆盖 `--van-*` 深色组。
- ConfigProvider 不引入（避免组件树包裹），纯变量方案保证 `theme.changed` 事件切 `data-theme` 时 Vant 组件自动跟随。
- 验收：Vant 组件验收卡在夜间模式下全组件深色正确。

### 3.3 Web 弹层浮层模式（P2-5 图表弹层，新技术）

- 模式：弹层打开时**按需插入全屏 WKWebView 浮层**（单例预创建常驻隐藏，避免每次 100ms 实例化），body 渲染「遮罩 + 面板」；关闭时 JS 动作 `sheet.close` → Swift 移除浮层。弹层打开期间图表手势被 WebView 挡住 = 符合既有交互（弹层打开本就不操作图表）。
- 协议：`sheet.open {name, payload}`（Swift→Web 方向：插入浮层并路由到对应面板）/ `sheet.close {}`（Web→Swift）；面板数据走各自快照动作（`chart.settings.snapshot`、`chart.indicators.snapshot` 等，进 fixtures）。
- 收益：KlineDetailView 的弹层状态机（isAnyPopupActive 等）保留，只是面板渲染主体从 SwiftUI 换 Web；图表绘制本体零改动。

### 3.4 行情快照通道（P2-1/P2-2 实测定参）

- Favorites/Home/Market 实时数据：`market.snapshot` 推送（节流参数 P2-1 实测定，预估 1s）或「页面就绪拉一次 + changed 事件触发拉取」；增量优化留实测后决定。字段集按列配置过滤（27 字段不全发）。
- 回测净值曲线：**轻量 SVG 自绘组件**（曲线 + 最大回撤区间 + 基线，与现有 Path 逻辑等价的 Web 版），不引 ECharts。

### 3.5 协议演进纪律

每批新增动作/事件：先进 `protocol.ts` 注释清单 + fixtures `reserved` 区块（形状锁定）→ Swift 实装 → reserved 转正（进 KnownActions/knownEvents + 测试清单）。

## 4. 分批实施

| 批次 | 内容 | 协议新增 | 验收 |
| --- | --- | --- | --- |
| **P2-0 基建** | vue-router + WebTabHostView + Vant 主题对接 + nav.tab/switchTab 协议 + 试点页并入路由（Profile 成为 /profile 路由，Tab 栏暂仍指原生 Profile） | nav.* | 真机四 Tab 混排：已换 Tab 内容来自 Web、其余原生；Vant 夜间模式正确 |
| **P2-1 Favorites** | Favorites Tab 换 Web：分组 Tab（Vant Tabs）+ 行列表（高密度行自绘，Vant SwipeCell 左滑、IndexBar 分组索引）+ 下拉刷新（KPullRefresh/Vant PullRefresh）+ 长按动作（ActionSheet）；`favorites.*` 全套实装；撤该页 A-D 布局分支 | favorites.* | 功能对齐原生默认布局（列表/分组/固顶/备注/刷新/进图表）；行情刷新节奏不掉点；进原生图表正常 |
| **P2-2 Market** | Market Tab 换 Web：分类 + 高密度行情表（列配置语义保留，Vant 化的列配置面板）+ 搜索/加分组浮层 | market.* + market.config.* | 同上口径 |
| **P2-3 Home** | Home Tab 换 Web：默认布局功能对齐（入口宫格/行情条/自选块/摘要块），撤 JSON 布局引擎该页部分（HomeWidgetRegistry/Editor 入口） | home.* | 首页入口全部可用；搜索进列表正常 |
| **P2-4 Simulation** | Simulation Tab 换 Web：SimCond 编辑器栈 Vant 化（Form/Field/Stepper/Picker）+ 布局退役该页部分；SimState 快照协议 | sim.* | 模拟交易全流程真机走通 |
| **P2-5 弹层三件套** | Web 弹层浮层模式（3.3）+ 三个面板 Vant 化：K线设置页（ChartConfigStore 快照写回）、指标控制面板（主图/副图槽位选择/参数/公式入口）、快捷面板（悬浮球触发，账户/方向胶囊/交易时段，A/B/C 布局退役只留一套）、图表搜索面板 | sheet.* + chart.* | 真机：弹层打开/关闭/主题/写回即时生效图表；图表手势弹层外零回归 |
| **P2-6 功能页全家** | Training（含回放控制桥接）/ Backtest（参数表单 + 结果页 + SVG 净值图）/ Formula 全家（编辑器是文本域 + 语法高亮可后置）/ TradeTicket / LANSync / LocalUpdate / Debug 实验室 | 各域动作 | 各页功能对齐 |
| **P2-7 收尾复核** | 布局系统全量清除（PageLayout 引擎四件套/编辑器全家/个人中心五个布局行/TradingLayoutStore 视情况）+ 协议 fixtures 全量转正 + 文档收尾 | — | 全 App 无 PageLayout 残留；全部 fixtures 测试绿 |

每批独立构建、装机、真机验收后进下一批（kline-device-validation-loop 流程）。

## 5. 假设与边界

1. K 线图表绘制本体（Chart/ 渲染全家）**永不动**；`LinkedKlineTile` 联动多图也保留原生。
2. Training 回放与图表的实时联动（TrainingSessionController 驱动）走桥接事件，P2-6 时验证延迟可接受；不可接受则该页保留原生（边界案例，单独汇报）。
3. `NetValueChartView` 直接 Vant 化为 SVG（iOS 15 无 Charts 的手绘图，无原生依赖）。
4. 原生页面在 Web 版验收通过前保留在代码中（整体回退能力）；P2-7 才物理清除。
5. Vant 深色模式走纯 CSS 变量方案（不引 ConfigProvider）。
6. Debug 实验室也 Vant 化（它是全屏表单页，无特殊性），若 P2-6 工作量超预期可延后单独一批。

## 6. 风险

| 风险 | 缓解 |
| --- | --- |
| 行情秒级快照推送在 2GB 设备的桥接性能 | P2-1 首个实时页实测定参；数据量按列配置裁剪；不行则降级为「事件通知 + 页面拉取」模式（拉取实测 <10ms） |
| Web 弹层浮层（P2-5）首例同屏混排 | P2-0 先用 Profile 页验证浮层容器机制（非弹层形态）；弹层三件套放最后批次 |
| 四页并行改动导致回归面大 | 每 Tab 独立批次 + 原生实现保留可回退 + 每批全量冒烟 |
| Vant 密度不贴金融表格 | 高密度行自绘（Vant 只供交互组件），token 钳制密度 |

## 7. 验证步骤（每批通用）

1. 本地 `npm run build` 绿；`WebBridgeProtocolTests` 绿（CI）
2. 云端构建成功 → TrollStore 装机 → 真机功能对齐清单逐项过
3. 调试通道（`http://127.0.0.1:5051/web/`）视觉核对
4. 深浅色三态切换跟随
5. 原生功能冒烟：四 Tab 切换、K 线详情打开/手势/弹层、模拟交易下单
