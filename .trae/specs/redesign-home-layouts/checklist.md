# Checklist

> 核验方式：逐条对照实现代码（静态核验，文件 + 行号）与原型文件。标 ⏳ 的为纯视觉/交互项，需真机确认。

## figma 原型画廊

- [x] `figma/home-ui-proposals.html` 为自包含单文件（620 行），无外链依赖（无 CDN / 无远程字体 / 无远程图片）—— 全文 `http(s)://` 只出现在 `xmlns` 命名空间（HTML:223）与 data-URI favicon（HTML:7），无 `@import url(`
- [x] 设备框与既有画廊一致（iPad mini 4 横屏 1024×768，等比缩放至 573×430，`.bezel` 深色外壳）—— `.screen-wrap{width:573px;height:430px}` + `.screen{width:1024px;height:768px;transform:scale(.55957)}`（HTML:56-57），与 `favorites-market-ui-proposals.html` 同参数
- [x] 首页 4 屏齐全且可切换：A 现状复刻 / B 宫格快捷入口 / C 分区列表入口 / D 卡片工作台 —— `#scr-homeA`/`#scr-homeB`/`#scr-homeC`/`#scr-homeD`（HTML:265/282/300/314），切换器 `HOME_IDS`（HTML:577-584）
- [x] A 屏与现状逐项对应：标题栏（Kline 图标 + 名称 + 右侧「登录」胶囊）+ 分隔线 + 居中「首页 / 欢迎来到首页」+ 底部四 Tab —— 截图 `figma/_shots/home_A.png` 逐项复核
- [x] B 屏含搜索条 + 「快捷入口」宫格（6 格、4 列、图标在上名称在下）—— 截图 `home_B.png`（布局标注 §2/§3/§4/§5/§6）
- [x] C 屏含三组（行情 / 研究 / 账户）入口行，行有标题 + 副标题 + chevron —— 截图 `home_C.png`（布局标注 §2/§3/§4/§5）
- [x] D 屏含顶部大卡（搜索）+ 2×2 中卡 + 底部小卡（个人中心）—— 截图 `home_D.png`（布局标注 §2/§3/§5/§6）
- [x] 个人中心演示屏展示六行设置行（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 首页布局）与四选项选择面板 —— `#scr-profileHomeLayout`（HTML:360）+ 截图 `home_profile.png`（面板内 B 项蓝色 checkmark）
- [x] 每屏有编号标注，且与右侧标注栏条目一一对应（描述 / 布局标注 / 优势 / 代价）—— `MARKS` 每屏 5–6 条坐标（HTML:541-547）与 `SCREENS[id].ann` 条数逐屏相等：homeA 5/5、homeB 6/6、homeC 6/6、homeD 6/6、profileHomeLayout 6/6（HTML:487-535）
- [x] 跨方案对比表覆盖 4 档，维度含信息密度 / 横屏利用 / 首屏信息量 / 操作步数 / 实现复杂度 / 适配场景 —— HTML:397 表头六项齐备，398-401 共 4 档数据行
- [x] 支持 `#shot=<屏 id>` 单屏定位，无头浏览器截图时无多余区块干扰 —— CSS `body.shot` 隐藏 hero / 区块标题 / 切换器 / 标注栏 / 对比表 / 说明文字（HTML:192-199）+ JS 解析 hash 并给对应 `.section` 加 `shot-on`（HTML:592-605）
- [x] 逐屏截图已输出到 `figma/_shots/`（`home_A`/`home_B`/`home_C`/`home_D`/`home_profile`，均 700×560，与既有 `fav_A.png` 同尺寸），每屏无溢出 / 无文字截断 / 无元素重叠 —— 5 张 PNG 逐张目视复核（设备框四边完整、C 屏最长副标题「技术指标 / 选股指标 / 交易策略」未截断、D 屏三段卡片不溢出）

## 布局偏好与个人中心

- [x] `HomeLayoutStyle` 取值域 A/B/C/D，带 `title` / `shortTitle`，满足 `LayoutOptionsPanel` 泛型约束（`CaseIterable & Hashable & Identifiable`）—— `PageLayoutStore.swift:67-87`（String rawValue 枚举天然 Hashable），面板复用未新增第二套
- [x] `PageLayoutStore.homeLayout` 写入 `UserDefaults`（key `kline.homeLayout`），**默认值为 B** —— `PageLayoutStore.swift:97`（key）、`:110-112`（`@Published` + `didSet` 写盘）、`:122-124`（`?? .b`）
- [x] 存储值非法或缺失时回退 B 且不崩溃 —— `PageLayoutStore.swift:124`（`HomeLayoutStyle(rawValue:) ?? .b`）
- [x] 个人中心出现新设置行「首页布局」，位于「行情页布局」行下方，右侧下拉按钮显示当前档名（字号 12 / 高 28 / `.plain` / 蓝色前景）—— `ProfileDetailView.swift:105-109`（插入位置）+ `TradingLayoutSettings.swift:165-179`（新行，复用 `LayoutDropdownButton`：字号 12 / `frame(height: 28)` / `.buttonStyle(.plain)` / `.foregroundColor(.blue)`）
- [x] 新选择面板与 `KlineThemeOptionsPanel` 逐项一致（210pt 宽、行内 padding、蓝色 checkmark、底部「完成」、圆角 12、阴影 black 20% radius 12 y 4）—— 复用泛型 `LayoutOptionsPanel`（`TradingLayoutSettings.swift:45-98`），未新增第二套面板
- [x] 新浮层挂在页面容器层 overlay（`black 25%` 遮罩 + 居中 + `.transition(.opacity)` + `zIndex(1000)`），不被 ScrollView 裁剪 —— `ProfileDetailView.swift:202-216`
- [x] 七个浮层（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 首页布局 / 公式中心）互斥，同时只呈现一个 —— `ProfileDetailView.swift:227-247`（7 个 `onChange`，任一置 true 时清其余 6 项）
- [x] 切换首页布局无需重启即生效；重启后仍保持所选档位 —— `@Published` + `didSet` 写 UserDefaults；`HomeView.swift:22` `@ObservedObject layoutStore`，`body` 内按 `layoutStore.homeLayout` 分发

## 首页四档

- [x] `HomeView` 按 `homeLayout` 分发 A/B/C/D 四档 —— `HomeView.swift:33-45`（与 `FavoritesView` 同构的 `switch`）
- [x] A 档即改造前实现（标题栏 + 分隔线 + 居中占位），`home.welcome` 标识保留 —— `HomeLayoutAView.swift:17-30`（`HomeHeaderBar` + `Divider` + 居中 `Text("首页")`/`Text("欢迎来到首页")`，标识在 `:29`）
- [x] B 档：搜索条 + 「快捷入口」宫格；列数按可用宽度自适应（≥960 四列 / ≥640 三列 / 否则两列）—— `HomeLayoutBView.swift:35`（搜索条）、`:38-46`（分组标题）、`:49-58`（`LazyVGrid` + `HomeEntryTile`）、`:76-86`（`gridColumns`）
- [x] C 档：三组入口行，行高固定 56pt，副标题 12pt，行间 `Divider`，`ScrollView` + `LazyVStack` —— `HomeLayoutCView.swift:40-44`（三组固定顺序）、`:51-59`（`ScrollView`+`LazyVStack`）、`:64-87`（组卡片：组标题 13pt + 行间 `Divider` 缩进 56）；行高 56 在 `HomePageKit.swift:217`
- [x] D 档：大卡 + 2×2 中卡（高 104）+ 小卡（高 64），卡片背景 `Color(.secondarySystemBackground)` + `cornerRadius(12)` —— `HomeLayoutDView.swift:46`（大卡 76）、`:49-53`（2×2 中卡 104）、`:56`（小卡 64）；卡片样式在 `HomePageKit.swift:232-276`
- [x] 四档共用同一份入口清单（`HomeEntryKind` 6 项：搜索 / 自选 / 行情 / 模拟 / 公式管理 / 个人中心），无重复实现 —— `HomePageKit.swift:23-80`；三档布局视图只做组合（B 91 行 / C 105 行 / D 79 行），入口文案 / 图标 / 色值未在档内重复定义
- [x] 四档均使用语义化颜色，深色模式可读（无写死白底）—— `Kline/Home/` 全目录 Grep `Color.white|Color.black|.white|.black` 无匹配；背景一律 `Color(.systemBackground)` / `.secondarySystemBackground` / `.systemGray5` / `.systemGray6`（`.gray` 仅用于搜索图标与占位字，与改造前逐项一致）
- [ ] ⏳ 所有可点击元素命中区 ≥ 44×44pt；行高 / 卡高 / 格高固定，点击与状态切换不抖动 —— 代码层已核（宫格格 88、列表行 56、卡片 76/104/64、搜索条外观 36 补到 44、标题栏胶囊沿用改造前尺寸），实际手感需真机确认
- [x] 搜索模式四档共用且与现状逐项一致（返回按钮 + 搜索框自动聚焦 + `SearchPageView`），点返回回到该档首页内容 —— `HomePageKit.swift:283-335`（`HomeSearchModeView`：`.focused` + `asyncAfter(0.05)` 自动聚焦、返回清空 `searchText` 并置 `isSearching = false`）；`HomeView.swift:28-30` 搜索态先于档位分派
- [x] 公式管理入口在首页容器层全屏呈现 `FormulaCenterView`（初始「技术指标」段），页内「返回」关闭后回到原档位 —— `HomePageKit.swift:341-363`（`homeOverlays`，`initialKind: .tech` + `.transition(.opacity)` + `zIndex(1000)`）；入口触发 `HomeView.swift:65-67`

## 跳转与标识

- [x] 首页「自选 / 行情 / 模拟」入口切底部 Tab，索引与 `ContentView.menuItems` 一致（1 / 2 / 3）—— `HomeView.swift:20`（`@Binding selectedTab`）、`:53-55`（`onSelectTab`）；三档映射 `HomeLayoutBView.swift:64-73`、`HomeLayoutCView.swift:91-100`、`HomeLayoutDView.swift:65-74`
- [x] 三处 `HomeView(...)` 调用方均已更新：ContentView 两处传 `$selectedTab`、MarketPageKit 搜索 overlay 传 `.constant(2)`、`#Preview` 传 `.constant(0)` —— `ContentView.swift:230,238`、`MarketPageKit.swift:710-711`、`HomeView.swift:71`
- [x] 行情页搜索图标（`MarketPageKit` overlay）行为与改造前一致，不会改动底部 Tab 选中态 —— `MarketPageKit.swift:709-711`（传常量 2 并注释说明；搜索态先于档位分派，不改 `selectedTab`）
- [x] `home.page` 挂在四档共用的标题栏 `Text("Kline")` 上（不挂内容根容器：SwiftUI 容器标识未必暴露成元素）；`KlineUITests.test02` 改用 `app.staticTexts["home.page"]` 判定首页已显示 —— `HomePageKit.swift:98-101`（标识落点，`:85-87` 注释说明理由）、`HomeLayoutAView.swift:8`（不在档内重复挂）、`KlineUITests.swift:76`
- [x] 默认档位为 B 时既有冒烟用例不误报（首页判定不再依赖 A 档专有文案）—— `KlineUITests.swift:73-76`（注释与断言均改为 `home.page`）；`home.page` 由四档共用的 `HomeHeaderBar` 提供，B 档亦存在

## 工程与交付

- [x] 新增文件全部位于 `Kline/` 目录树内，无需手工改 `project.pbxproj`（依赖 `PBXFileSystemSynchronizedRootGroup`）—— 两次提交的 `--stat` 清单中均未出现 `project.pbxproj`（阶段二 7812ce8 15 文件 / 阶段三 7498dce 12 文件）
- [x] 未新增数据源、未改任何持久化文件结构（`favorites.json` / `market_columns.json` / `sim.json` 不变）—— 两次提交清单中 `Kline/Data/`、`FavoritesStore.swift`、`MarketConfigStore.swift`、`SimStore.swift` 均无改动；改动仅限布局仓库、个人中心、`Kline/Home/` 与调用方
- [x] 阶段二 / 三闭环命令均返回 0 / 6 / 7，构建通过 —— 阶段二 run=35550562651（退出码 6：云端构建成功、设备锁屏未下发）；阶段三 run=35551076040（退出码 0：已部署 Kline v1.0.2 (348)）
- [x] A 档下首页行为与改造前一致（回归点）；`git status` 无遗留未提交改动，spec 三件套随闭环命令一并提交 —— `HomeLayoutAView` 与改造前 body 逐项等价（标题栏 / 分隔线 / 占位 / `home.welcome` / 搜索模式）；`git status --porcelain` 输出为空；spec 三件套在 7812ce8 提交、核验结果回填在 7498dce 之后单独提交

***

# 变更二核验：快捷入口横滑行 + 首页内容区

> 核验方式同前：静态核验（文件 + 行号）+ 首批 ⏳ 项需真机确认。本变更**不改动** A 档 / 个人中心 / 仓库 / 底部栏 / 其他页面，回归面为零。

## 快捷入口横滑行

- [ ] 三档（B/C/D）共用同一行横滑入口 —— 三档均渲染 `HomeQuickEntryRow`，行实现只在 `HomePageKit.swift` 一处
- [ ] 入口行为 `ScrollView(.horizontal, showsIndicators: false)` 单行 chips，内容超宽时可左右拖动；底部导航栏四项 Tab 不受影响（未改 `ContentView`）
- [ ] 入口清单恰好 6 项且为：搜索标的 / 技术指标 / 选股指标 / 交易策略 / 条件单 / 个人中心 —— `HomeEntryKind` 的 `allCases` 与之一致
- [ ] **已剔除**与底部栏重复的自选 / 行情 / 模拟交易 —— 全项目 Grep 入口清单中不再含这三项（`HomeEntryKind` 无对应 case，页面无相关磁贴/行/卡）
- [ ] 每个 chip 命中区 ≥ 44×44pt、高度固定 76pt，点击与切档不抖动；图标 22 / 名称 13、语义色
- [ ] 点「技术指标」/「选股指标」/「交易策略」分别全屏呈现 `FormulaCenterView` 并落在 tech / picker / strategy 段
- [ ] 点「条件单」全屏呈现 `SimCondListView(accountID: nil)`（全部账户汇总），关闭后回到原档位
- [ ] 点「个人中心」经 `isProfilePresented` 打开；点「搜索标的」进入现有搜索模式
- [ ] 第一轮遗留的 `HomeEntryTile` / `HomeEntryRow` / `HomeEntryCard` / `HomeSearchBar` 已删除，全项目无引用残留（不留死代码）

## 首页内容区（四块）

- [ ] 入口行下方呈现四块：大盘概览条 / 我的自选 / 模拟账户汇总 / 涨幅榜 Top N，三档口径一致
- [ ] 大盘概览条：前 4 只「沪深京指数」的名称 / 现价 / 涨跌幅（红涨绿跌）+ 沪深主板涨 / 跌 / 平与涨停（`pct >= 9.8`）/ 跌停（`pct <= -9.8`）家数；点指数项进 K 线详情
- [ ] 我的自选：取 `FavoritesStore.allGroup` 前 5，含名称 / 代码、现价、涨跌幅胶囊与近 20 日迷你走势（复用 `MarketSparkline`）；点行进详情
- [ ] 我的自选空态：显示「暂无自选，去自选页添加」，点击切自选页（`selectedTab = 1`）
- [ ] 模拟账户汇总：`SimStore.summary(accountID: nil)` 的总资产 / 当日盈亏（含百分比）/ 持仓占比 + 持仓 Top N（现价 / 盈亏）；点击切模拟页（`selectedTab = 3`）
- [ ] 涨幅榜 Top N：仅取已就绪的沪深主板行，按 `changePct` 降序前 5、过滤 nil；未就绪显示「加载中」占位而非错值；点行进详情
- [ ] 四块均使用语义化颜色、固定高度；空态 / 加载态切换不引起布局抖动

## 数据口径与性能

- [ ] 新增 `HomePageModel`（`@StateObject` 由 `HomeView` 持有，向三档 `@ObservedObject` 消费），快照字段齐备（指数 / 涨跌家数 / 自选 / 涨幅榜）
- [ ] `Kline/Home/` 内 `body` 中无全表遍历或 O(n) 聚合 —— 聚合与排序全部在 `HomePageModel` 内完成（Grep 三档布局视图与内容块视图，无 `for` / `.filter` / `.sorted` 于全量行集合上）
- [ ] 行数据陆续到位时按 **250ms 防抖**合并重算（对齐 `MarketPageModel.scheduleOverviewRefresh` 写法），不在每行到达时重算
- [ ] 未就绪行不参与聚合、不显示错值；`@Published` 赋值带同值守卫
- [ ] 未新增数据源、未改持久化结构（`favorites.json` / `market_columns.json` / `sim.json` 不变）

## 浮层与标识

- [ ] 首页容器层浮层为单一目标枚举（公式三域 / 条件单），同时只呈现一个；关闭后回到首页原档位
- [ ] `home.page` 仍挂在共享标题栏的软件名 `Text` 上（四档可用），`home.welcome` 在 A 档保留
- [ ] 未改动 `KlineUITests`，冒烟用例（首页判定 `home.page`）仍成立

## figma 同步与工程

- [ ] `figma/home-ui-proposals.html` 的 B / C / D 三屏已更新为「横滑入口行 + 内容区」，A 屏与个人中心屏未变
- [ ] 三屏的布局标注 / 优劣势已重写（体现「不再与底部栏重复、入口可横滑、内容区信息量」），对比表六维度已更新
- [ ] 重截 `home_B.png` / `home_C.png` / `home_D.png`（700×560，与既有截图同尺寸），逐屏无溢出 / 截断 / 重叠；画廊仍为自包含单文件、支持 `#shot=`
- [ ] A 档零变化（`HomeLayoutAView` 未改）；`PageLayoutStore` / `ProfileDetailView` / `TradingLayoutSettings` / `ContentView` / `MarketPageKit` / `KlineUITests` 无改动
- [ ] 闭环命令返回 0 / 6 / 7；`git status` 无遗留未提交改动