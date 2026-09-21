# Checklist

> 核验方式：逐条对照实现代码（静态核验，文件 + 行号）与原型文件。标 ⏳ 的为纯视觉/交互项，需真机确认。

## figma 原型画廊

- [x] `figma/home-ui-proposals.html` 为自包含单文件，无外链依赖（无 CDN / 无远程字体 / 无远程图片）—— 全文 `http(s)://` 只出现在 `xmlns` 命名空间与 data-URI favicon，无 `@import url(`
- [x] 设备框与既有画廊一致（iPad mini 4 横屏 1024×768，等比缩放至 573×430，`.bezel` 深色外壳）—— `.screen-wrap{width:573px;height:430px}` + `.screen{width:1024px;height:768px;transform:scale(.55957)}`，与 `favorites-market-ui-proposals.html` 同参数
- [x] 首页 4 屏齐全且可切换 —— `#scr-homeA`/`#scr-homeB`/`#scr-homeC`/`#scr-homeD`，切换器 `HOME_IDS`
- [x] A 屏与现状逐项对应：标题栏（Kline 图标 + 名称 + 右侧「登录」胶囊）+ 分隔线 + 居中「首页 / 欢迎来到首页」+ 底部四 Tab —— 截图 `figma/_shots/home_A.png` 逐项复核
- [x] B/C/D 三屏已更新为「横滑入口行 + 内容区」形态（详见下节「变更二核验」）
- [x] 个人中心演示屏展示六行设置行（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 首页布局）与四选项选择面板 —— `#scr-profileHomeLayout` + 截图 `home_profile.png`（四项文案已同步为横滑入口形态的新档名）
- [x] 每屏有编号标注，且与右侧标注栏条目一一对应（描述 / 布局标注 / 优势 / 代价）—— `MARKS` 每屏坐标与 `SCREENS[id].ann` 条数逐屏相等
- [x] 跨方案对比表覆盖 4 档，维度含信息密度 / 横屏利用 / 首屏信息量 / 操作步数 / 实现复杂度 / 适配场景 —— `.cmp` 表头六项齐备 + 4 档数据行
- [x] 支持 `#shot=<屏 id>` 单屏定位，无头浏览器截图时无多余区块干扰 —— CSS `body.shot` 隐藏 hero / 区块标题 / 切换器 / 标注栏 / 对比表 / 说明文字 + JS 解析 hash 并给对应 `.section` 加 `shot-on`
- [x] 逐屏截图已输出到 `figma/_shots/`（`home_A`/`home_B`/`home_C`/`home_D`/`home_profile`，均 700×560，与既有 `fav_A.png` 同尺寸），每屏无溢出 / 无文字截断 / 无元素重叠 —— 逐张目视复核（设备框四边完整、横滑行第 6 项「部分露出」表意成立、C 屏最长副标题未截断）

## 布局偏好与个人中心

- [x] `HomeLayoutStyle` 取值域 A/B/C/D，带 `title` / `shortTitle`，满足 `LayoutOptionsPanel` 泛型约束（`CaseIterable & Hashable & Identifiable`）—— `PageLayoutStore.swift:67-87`，面板复用未新增第二套
- [x] `PageLayoutStore.homeLayout` 写入 `UserDefaults`（key `kline.homeLayout`），**默认值为 B** —— `PageLayoutStore.swift:97`（key）、`:110-112`（`@Published` + `didSet` 写盘）、`:122-124`（`?? .b`）
- [x] 存储值非法或缺失时回退 B 且不崩溃 —— `PageLayoutStore.swift:124`（`HomeLayoutStyle(rawValue:) ?? .b`）
- [x] 个人中心出现新设置行「首页布局」，位于「行情页布局」行下方，右侧下拉按钮显示当前档名（字号 12 / 高 28 / `.plain` / 蓝色前景）—— `ProfileDetailView.swift:105-109` + `TradingLayoutSettings.swift:165-179`
- [x] 新选择面板与 `KlineThemeOptionsPanel` 逐项一致（210pt 宽、行内 padding、蓝色 checkmark、底部「完成」、圆角 12、阴影 black 20% radius 12 y 4）—— 复用泛型 `LayoutOptionsPanel`（`TradingLayoutSettings.swift:45-98`）
- [x] 新浮层挂在页面容器层 overlay（`black 25%` 遮罩 + 居中 + `.transition(.opacity)` + `zIndex(1000)`），不被 ScrollView 裁剪 —— `ProfileDetailView.swift:202-216`
- [x] 七个浮层（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 首页布局 / 公式中心）互斥，同时只呈现一个 —— `ProfileDetailView.swift:227-247`（7 个 `onChange`，任一置 true 时清其余 6 项）
- [x] 切换首页布局无需重启即生效；重启后仍保持所选档位 —— `@Published` + `didSet` 写 UserDefaults；`HomeView.swift:22` `@ObservedObject layoutStore`，`body` 内按 `layoutStore.homeLayout` 分发
- [x] 档位名称与三档实际形态一致（变更二收尾修正）—— `PageLayoutStore.swift:78-81`：「A · 现有首页（保留）」/「B · 横滑入口 + 卡片网格（默认）」/「C · 横滑入口 + 分区列表」/「D · 横滑入口 + 工作台混排」

## 首页四档（变更二后的最终形态）

- [x] `HomeView` 按 `homeLayout` 分发 A/B/C/D 四档 —— `HomeView.swift:35-50`
- [x] A 档即改造前实现（标题栏 + 分隔线 + 居中占位），`home.welcome` 标识保留；**本次变更未改 A 档** —— `HomeLayoutAView.swift:13-35`（未出现在变更二提交 e129d81 的文件清单中）
- [x] B/C/D 三档共用同一行横滑入口（`HomeQuickEntryRow`）、同一标题栏、同一搜索模式，差异只在内容区 —— 三档均 `HomeHeaderBar + Divider + HomeQuickEntryRow(onTap: perform) + ScrollView{ 内容区 }`（`HomeLayoutBView.swift:24-61`、`HomeLayoutCView.swift`、`HomeLayoutDView.swift:24-63`）
- [x] B 档内容区＝卡片网格（概览通栏 → 自选带走势 / 模拟账户 2 列 → 涨幅榜通栏列表）—— `HomeLayoutBView.swift:33-57`
- [x] C 档内容区＝分区列表（四块通栏、全紧凑、无走势）—— `HomeLayoutCView.swift`
- [x] D 档内容区＝工作台混排（概览大卡 → 模拟账户 + 自选前 3 紧凑 2 列 → 涨幅榜横滑 chips）—— `HomeLayoutDView.swift:33-59`
- [x] 四档均使用语义化颜色，深色模式可读（无写死白底）
- [ ] ⏳ 所有可点击元素命中区 ≥ 44×44pt（chip 168×68、行 48/紧凑 40+2×2、chips 150×72）；高度固定、点击与切档不抖动 —— 代码层已核，实际手感需真机确认
- [x] 搜索模式四档共用且与现状逐项一致（返回按钮 + 搜索框自动聚焦 + `SearchPageView`），点返回回到该档首页内容 —— `HomePageKit.swift:194-250`；`HomeView.swift:30-32` 搜索态先于档位分派
- [x] 公式管理三域入口在容器层全屏呈现 `FormulaCenterView`（tech / picker / strategy），关闭后回到原档位 —— `HomePageKit.swift:266-295`（`homeOverlays`，`.id(target.id)` 保证切段重建）
- [x] 条件单入口在容器层全屏呈现 `SimCondListView(accountID: nil)`（全部账户汇总），关闭后回首页 —— `HomePageKit.swift:280`
- [x] 首页入口跳底部 Tab 仍可用（自选空态 → Tab 1、模拟卡 → Tab 3）—— `HomeLayoutBView.swift:43,49`、`HomeLayoutDView.swift:43,50`；`HomeView.swift:58-60` 写 `selectedTab`

## 跳转与标识（回归）

- [x] `home.page` 仍挂在四档共用的标题栏软件名 `Text` 上（三档行号已随文件精简变化）—— `HomePageKit.swift:147-148`（注释）、`:163`（标识）
- [x] `home.welcome` 在 A 档保留 —— `HomeLayoutAView.swift`（未改动）
- [x] `KlineUITests` 未改动，冒烟用例（首页判定 `home.page`）仍成立 —— 变更二两次提交的文件清单均无 `KlineUITests.swift`
- [x] 行情页搜索 overlay（`MarketPageKit`）未受影响 —— 该文件未出现在变更二提交清单中
- [x] `ContentView.swift` 未改动（底部栏四项 Tab 原样保留）—— 未出现在变更二提交清单中

## 工程与交付

- [x] 新增文件全部位于 `Kline/` 目录树内，无需手工改 `project.pbxproj` —— 变更二提交 e129d81（14 文件）与 c30795c（4 文件）均无 `project.pbxproj`
- [x] 未新增数据源、未改任何持久化文件结构（`favorites.json` / `market_columns.json` / `sim.json` 不变）—— `Kline/Data/`、`FavoritesStore.swift`、`MarketConfigStore.swift`、`SimStore.swift` 均无改动
- [x] 阶段二 / 三闭环命令均返回 0 / 6 / 7，构建通过 —— 阶段二 run=35550562651（退出码 6）；阶段三 run=35551076040（退出码 0，已部署 v1.0.2 (348)）
- [x] A 档下首页行为与改造前一致（回归点）；`git status` 无遗留未提交改动 —— `HomeLayoutAView` 与改造前 body 逐项等价；变更二提交后 `git status --porcelain` 输出为空

***

# 变更二核验：快捷入口横滑行 + 首页内容区

> 核验方式同前：静态核验（文件 + 行号）+ ⏳ 项需真机确认。本变更**不改动** A 档 / 个人中心 / 仓库字段 / 底部栏 / 其他页面，回归面为零。

## 快捷入口横滑行

- [x] 三档（B/C/D）共用同一行横滑入口 —— 三档均渲染 `HomeQuickEntryRow`，行实现只在 `HomePageKit.swift:96-140` 一处（`HomeQuickEntryRow` + `HomeQuickEntryChip`）
- [x] 入口行为 `ScrollView(.horizontal, showsIndicators: false)` 单行 chips，内容超宽时可左右拖动 —— `HomePageKit.swift:100-109`；6 项 chip（minWidth 168 + spacing 12 + 左右 16）合计约 1100pt > 1024pt（iPad mini 4 横屏），横屏下**必然需要左右拖动**
- [x] 入口清单恰好 6 项且为：搜索标的 / 技术指标 / 选股指标 / 交易策略 / 条件单 / 个人中心 —— `HomePageKit.swift:22-89`（`HomeEntryKind` 六个 case，`title` 与之一致）
- [x] **已剔除**与底部栏重复的自选 / 行情 / 模拟交易 —— `HomeEntryKind` 已无对应 case；`Kline/Home/` 全目录 Grep 无残留引用
- [x] 每个 chip 命中区 ≥ 44×44pt（168×68）、图标 22 / 标题 13 / 副标题 11、语义色 —— `HomePageKit.swift:114-140`
- [x] 点「技术指标」/「选股指标」/「交易策略」分别全屏呈现 `FormulaCenterView` 并落在 tech / picker / strategy 段 —— `HomePageKit.swift:277`（`initialKind: kind`）+ 三档 `perform` 走 `kind.formulaKind`（`HomeLayoutBView.swift:70-71`）
- [x] 点「条件单」全屏呈现 `SimCondListView(accountID: nil)`（全部账户汇总），关闭后回到原档位 —— `HomePageKit.swift:280`
- [x] 点「个人中心」经 `isProfilePresented` 打开；点「搜索标的」进入现有搜索模式 —— `HomeLayoutBView.swift:69,73`
- [x] 第一轮遗留的 `HomeEntryTile` / `HomeEntryRow` / `HomeEntryCard` / `HomeSearchBar` 已删除，全项目无引用残留 —— 变更二提交中 `HomePageKit.swift` 由 387 行精简至 304 行；`Kline/Home/` Grep 四个名字零命中

## 首页内容区（四块）

- [x] 入口行下方呈现四块：大盘概览条 / 我的自选 / 模拟账户汇总 / 涨幅榜 Top N，三档口径一致 —— `HomeContentBlocks.swift`（`HomeSectionCard` + 四个块），三档布局只传不同呈现参数
- [x] 大盘概览条：前 4 只「沪深京指数」的名称 / 现价 / 涨跌幅（红涨绿跌）+ 沪深主板涨 / 跌 / 平与涨停 / 跌停家数；点指数项进 K 线详情 —— `HomeContentBlocks.swift:127-215`（`HomeMarketOverviewStrip`，`@ObservedObject rowCache` 在第 135 行）
- [x] 我的自选：`FavoritesStore.allGroup` 前 5，含名称 / 代码、现价、涨跌幅胶囊与近 20 日迷你走势（复用 `MarketSparkline`）；点行进详情 —— `HomeContentBlocks.swift:217-249`（含 `MarketSparkline` 调用）+ `HomeQuoteRow`（`:70-125`）
- [x] 我的自选空态：「暂无自选，去自选页添加」且点击切自选页（`selectedTab = 1`）—— `HomeLayoutBView.swift:43` 传 `onEmptyTap: { onSelectTab(1) }`
- [x] 模拟账户汇总：总资产 / 当日盈亏（含百分比）/ 持仓占比 + 持仓 Top N（现价 / 盈亏）；点击切模拟页（`selectedTab = 3`）—— `HomeContentBlocks.swift:251-364`（读 `model.simSummary` / `simTopPositions` / `simSnapshot`）+ `HomeLayoutBView.swift:49`
- [x] 涨幅榜 Top N：仅取已就绪的沪深主板行、按 `changePct` 降序前 5、过滤 nil；未就绪显示「加载中」占位 —— `HomePageModel.swift:145-166`（聚合与排序）+ `HomeContentBlocks.swift:366-470`（`.list` / `.chips` 两式，`isReady` 决定占位）
- [x] 四块均使用语义化颜色、固定高度；空态 / 加载态切换不引起布局抖动 —— 行高固定 48 / 紧凑 40、概览指数区固定高度；`HomeQuoteRow` 紧凑行外层补 2pt 命中区而不改视觉高度
- [x] 行情数值能随 bars 陆续到位实时刷新 —— 四个块各自 `@ObservedObject rowCache = MarketRowCache.shared`（`HomeContentBlocks.swift:135/225/257/380`），数值经 `row.text/number` 读取（与 `MarketTileCard` 同机制）

## 数据口径与性能

- [x] 新增 `HomePageModel`（`@StateObject` 由 `HomeView` 持有，向三档 `@ObservedObject` 消费），快照字段齐备 —— `HomePageModel.swift:34-53`（`indexQuotes` / `breadth` / `favoriteRows` / `topGainers` / `isMarketReady`）；`HomeView.swift:24` `@StateObject`
- [x] `Kline/Home/` 内 `body` 中无全表遍历或 O(n) 聚合 —— `HomeContentBlocks.swift` Grep `for row in` / `.sorted` / `.filter(` / `rowCache.rows` 零命中；全表聚合只在 `HomePageModel.swift:145-155`
- [x] 行数据陆续到位时按 **250ms 防抖**合并重算 —— `HomePageModel.swift:97-106`（`DispatchWorkItem` + `asyncAfter(0.25)` + `Task { @MainActor in ... }`，与 `MarketPageModel.scheduleOverviewRefresh` 同写法）
- [x] 未就绪行不参与聚合、不显示错值 —— `HomePageModel.swift:148`（只遍历 `hasBars` 行）、`:157-160`（无有效聚合时 `breadth = nil` → 界面「加载中」）
- [x] `@Published` 赋值带同值守卫 —— `HomePageModel.swift:124,135,159-165`（按 `map(\.meta.id)` / `!=` 比较）
- [x] 未新增数据源、未改持久化结构 —— 变更二提交清单中 `Kline/Data/` 与三个 Store 均无改动

## 浮层与标识

- [x] 首页容器层浮层为单一目标枚举（公式三域 / 条件单），同时只呈现一个 —— `HomePageKit.swift:252-254`（`HomeOverlayTarget`）、`:266-295`（`HomeOverlays` 按 target 分支 + `.id` 重建）；`HomeView.swift:26,53` 单一 `@State overlayTarget`
- [x] `home.page` 仍挂在共享标题栏的软件名 `Text` 上（三档可用），`home.welcome` 在 A 档保留 —— `HomePageKit.swift:163`、`HomeLayoutAView.swift`
- [x] 未改动 `KlineUITests`，冒烟用例（首页判定 `home.page`）仍成立 —— 见上「跳转与标识（回归）」

## figma 同步与工程

- [x] `figma/home-ui-proposals.html` 的 B / C / D 三屏已更新为「横滑入口行 + 内容区」，A 屏未变 —— 变更二提交中该 HTML 改动 491 行；A 屏 HTML 与 `home_A.png` 未动
- [x] 三屏的布局标注 / 优劣势已重写（体现「不再与底部栏重复、入口可横滑、内容区信息量」），对比表六维度已更新 —— `SCREENS.homeB/C/D` 的 `cap/desc/ann(7 条)/pro/con` 与 `.cmp` 已同步
- [x] 重截 `home_B.png`（58,108B）/ `home_C.png`（52,917B）/ `home_D.png`（55,128B），均 700×560，与既有截图同尺寸；逐屏无溢出 / 截断 / 重叠；画廊仍为自包含单文件、支持 `#shot=` —— 三张新截图与 `home_profile.png`（档名同步后重截）逐一目视复核
- [x] A 档零变化；`PageLayoutStore`（仅档位名称 4 行）/ `ProfileDetailView` / `TradingLayoutSettings` / `ContentView` / `MarketPageKit` / `KlineUITests` 未被本次变更改动 —— 见提交清单
- [x] 闭环命令返回 0 / 6 / 7；`git status` 无遗留未提交改动 —— 变更二主体 run=35559443972（退出码 6：云端构建成功、设备锁屏未下发）；档位名称同步 run=35559808575（退出码 6，同上）；`git status --porcelain` 输出为空