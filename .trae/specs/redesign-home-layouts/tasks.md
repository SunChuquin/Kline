# Tasks

## 阶段一：figma 原型画廊（设计稿先行，用户看稿定方案）

- [x] Task 1: 新建 `figma/home-ui-proposals.html` 骨架 + 首页 4 档屏
  - [x] SubTask 1.1: 复用 `figma/favorites-market-ui-proposals.html` 的画廊骨架（`:root` 变量、`.bezel` 设备框、`.screen-wrap` 573×430 + `.screen` 1024×768 `scale(.55957)`、`.switcher`/`.seg`、`.marker` 标注、`.ncard` 标注栏、`.cmp` 对比表、`.tabbar` 底部导航、`#shot=` 单屏定位），不引入任何外链依赖
  - [x] SubTask 1.2: A 屏照现状复刻：顶部标题栏（Kline 图标 + 名称 + 右侧「登录」胶囊）+ 分隔线 + 居中占位（「首页」/「欢迎来到首页」）+ 底部四 Tab
  - [x] SubTask 1.3: B 屏宫格：标题栏 + 一行搜索条 + 「快捷入口」分组标题 + 6 格宫格（图标 28 / 名称 13 / 格高 88，四列）
  - [x] SubTask 1.4: C 屏分区列表：标题栏 + 三组（行情 / 研究 / 账户）入口行（图标方块 + 标题 + 副标题 + chevron，行高 56 + `Divider`）
  - [x] SubTask 1.5: D 屏卡片工作台：标题栏 + 顶部大卡（搜索标的 + 说明）+ 2×2 中卡（自选 / 行情 / 模拟交易 / 公式管理，高 104）+ 底部小卡行（个人中心，高 64）
  - [x] SubTask 1.6: 每屏配编号标注 + 标注栏（描述 / 布局标注 / 优势 / 代价），并在 `SCREENS` 表里登记 `cap`/`desc`/`ann`/`pro`/`con`

- [x] Task 2: 个人中心演示屏 + 方案对比表
  - [x] SubTask 2.1: 个人中心演示屏：六行设置行（主题 / 快捷面板布局 / 模拟页布局 / 自选页布局 / 行情页布局 / **首页布局**）+ 四选项选择面板（210pt 宽、蓝色 checkmark、底部「完成」）
  - [x] SubTask 2.2: 方案对比表：4 档按「信息密度 / 横屏利用 / 首屏信息量 / 操作步数 / 实现复杂度 / 适配场景」横向对比

- [x] Task 3: 截图与自检交付
  - [x] SubTask 3.1: 按 `#shot=<屏 id>` 逐屏截图（无头 Edge / Chrome `--screenshot`），输出到 `figma/_shots/`（`home_A.png` / `home_B.png` / `home_C.png` / `home_D.png` / `home_profile.png`，均为 700×560，与既有截图同尺寸）
  - [x] SubTask 3.2: 自检：每屏无溢出 / 无文字截断 / 无重叠、编号标注与标注栏条目一一对应、设备框尺寸与既有画廊一致
  - [x] SubTask 3.3: 交付说明（画廊路径 + 截图路径 + 4 档一览），等用户定档

## 阶段二：仓库 + 个人中心入口 + 分发容器（A 档行为零变化）

- [x] Task 4: 布局偏好仓库扩字段 `Kline/App/PageLayoutStore.swift`
  - [x] SubTask 4.1: 新增 `HomeLayoutStyle`（a/b/c/d），带 `rawValue` / `title`（「A · 现有首页（保留）」/「B · 宫格快捷入口（默认）」/「C · 分区列表入口」/「D · 卡片工作台」）/ `shortTitle` / `CaseIterable` / `Hashable` / `Identifiable`，写法对齐既有两个枚举
  - [x] SubTask 4.2: `PageLayoutStore` 增加 `@Published var homeLayout`，`didSet` 写 `UserDefaults`（key `kline.homeLayout`），`private init()` 读回并回退 **`.b`**
  - [x] SubTask 4.3: 确认 `HomeLayoutStyle` 满足 `LayoutOptionsPanel` 的泛型约束（`CaseIterable & Hashable & Identifiable where AllCases == [Self]`），不新增下拉组件

- [x] Task 5: 个人中心新增「首页布局」行
  - [x] SubTask 5.1: 在 [TradingLayoutSettings.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/TradingLayoutSettings.swift#L165-L179) 新增 `HomeLayoutSettingRow`（标题 16pt + 右侧 `LayoutDropdownButton(title: store.homeLayout.shortTitle, isOpen:)`，`frame(minHeight: 36)`），与「行情页布局」行同构
  - [x] SubTask 5.2: 在 [ProfileDetailView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L105-L109) 的「行情页布局」行下方插入该行，并配一个容器层 overlay（`black 25%` 遮罩 + 居中 `LayoutOptionsPanel(options: HomeLayoutStyle.allCases, ...)` + `.transition(.opacity)` + `zIndex(1000)`）
  - [x] SubTask 5.3: 把互斥 `onChange` 链由 6 项扩为 7 项（新增 `showHomeLayoutPanel` 的 `onChange`，并把它加入其余 6 个 `onChange` 的清除列表）

- [x] Task 6: 首页共享骨架 `Kline/Home/HomePageKit.swift`
  - [x] SubTask 6.1: `HomeEntryKind` 枚举（`search` / `favorites` / `market` / `simulation` / `formula` / `profile`）：`title`、`subtitle`、`icon`、`tint`
  - [x] SubTask 6.2: `HomeHeaderBar`（**等价搬入**现有标题栏）与 `HomeSearchBar`（只读搜索条，仅 B 档使用）
  - [x] SubTask 6.3: 三档共用入口控件：`HomeEntryTile`（宫格）、`HomeEntryRow`（列表行）、`HomeEntryCard`（参数化大 / 中 / 小卡）
  - [x] SubTask 6.4: `HomeSearchModeView`：**等价搬入**现有搜索模式（返回按钮 + 搜索框 + 自动聚焦 + `SearchPageView`），四档共用
  - [x] SubTask 6.5: `HomeOverlays`（ViewModifier + `func homeOverlays(showFormulaCenter:)`）：公式管理全屏 overlay
  - [x] SubTask 6.6: 入口动作统一由容器注入的闭包承担（`onProfile` / `onTap` / `action`），控件本身不发命令、不持状态

- [x] Task 7: 首页分发容器 + A 档等价搬运
  - [x] SubTask 7.1: 新增 `HomeLayoutAView`：把现有 `HomeView` 的 body 等价搬入（标题栏 / 分隔线 / 居中占位；`home.welcome` 标识保留在「欢迎来到首页」上）
  - [x] SubTask 7.2: [HomeView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeView.swift#L25-L48) 改为分发容器：`@ObservedObject layoutStore`，`isSearching` 为真时统一走 `HomeSearchModeView`，否则按 `layoutStore.homeLayout` 分发四档；B/C/D **先临时回落到 A 档视图**（代码注释标明下一阶段替换）
  - [x] SubTask 7.3: 四档内容根统一挂 `accessibilityIdentifier("home.page")`（阶段三改为挂在四档共用标题栏的软件名 `Text` 上——容器上的标识在 SwiftUI 里未必暴露成无障碍元素，详见 Task 12.3）；公式管理 overlay 经 `homeOverlays(...)` 挂容器层

- [x] Task 8: 阶段二闭环
  - [x] SubTask 8.1: 编码自查（`Color.opacity` 入参 Double、勿遮蔽同名参数、`@Published` 同值赋值加守卫、不在 `body` 内做重计算、只改本阶段相关文件）
  - [x] SubTask 8.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(home-layout): 首页布局仓库与个人中心入口 + 分发容器（A 档等价搬运）"`
  - [x] SubTask 8.3: 交付说明（build 号 / 改动与理由 / 真机验证路径：个人中心新增「首页布局」行可切 4 档，A 档下首页与改造前一致）

## 阶段三：B / C / D 三档 + 跳转打通

- [x] Task 9: 首页 B（宫格快捷入口，默认档）
  - [x] SubTask 9.1: 新增 `HomeLayoutBView`：标题栏 + `HomeSearchBar` + 「快捷入口」分组标题 + `LazyVGrid` 宫格（格高 88、间距 12、水平内边距 16）
  - [x] SubTask 9.2: 列数按可用宽度自适应（复用 [MarketLayoutCView.gridColumns](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketLayoutCView.swift#L76-L86) 的口径：≥960 四列 / ≥640 三列 / 否则两列），入口 `onSelectTab` / `onSearch` / `onProfile` 由容器闭包驱动

- [x] Task 10: 首页 C（分区列表入口）
  - [x] SubTask 10.1: 新增 `HomeLayoutCView`：标题栏 + 三组入口行（「行情」= 行情 / 自选；「研究」= 搜索标的 / 公式管理；「账户」= 模拟交易 / 个人中心），组标题 13pt `.secondary`、行高固定 56pt、行间 `Divider`
  - [x] SubTask 10.2: 行点击走同一套容器闭包；行内不使用 `List`（避免默认样式与整页滚动耦合），用 `ScrollView` + `LazyVStack`

- [x] Task 11: 首页 D（卡片工作台）
  - [x] SubTask 11.1: 新增 `HomeLayoutDView`：标题栏 + 顶部大卡（搜索标的，含一行说明）+ 2×2 中卡（自选 / 行情 / 模拟交易 / 公式管理，高 104）+ 底部小卡（个人中心，高 64）
  - [x] SubTask 11.2: 卡片背景 `Color(.secondarySystemBackground)` + `cornerRadius(12)`，图标着色用 `tint`；点击命中区覆盖整卡（`contentShape(Rectangle())`）

- [x] Task 12: 入口跳转与标识打通
  - [x] SubTask 12.1: `HomeView` 增加 `@Binding var selectedTab: Int` 并透传给四档；`onSelectTab` 实现 `selectedTab = index`（索引与 `ContentView.menuItems` 一致：自选 1 / 行情 2 / 模拟 3）
  - [x] SubTask 12.2: 更新 3 处 `HomeView(...)` 调用方：ContentView 两个 case 传 `$selectedTab`，MarketPageKit 搜索 overlay 传 `.constant(2)`，`#Preview` 传 `.constant(0)`
  - [x] SubTask 12.3: [KlineUITests](file:///c:/Users/sunck/home/projects/ios/Kline/KlineUITests/KlineUITests.swift#L69-L76) 的 `test02_TabSwitching_ShowsEachPage` 首页判定由 `app.staticTexts["home.welcome"]` 改为 `app.staticTexts["home.page"]`（`home.page` 改挂在共享标题栏的软件名 `Text` 上，容器标识未必暴露成元素），保证默认档位为 B 时用例不误报
  - [x] SubTask 12.4: 四档互切自测（入口点击、搜索模式往返、公式管理 overlay 开关、切档后 Tab 选中态与滚动位置正常）

- [x] Task 13: 阶段三闭环
  - [x] SubTask 13.1: 编码自查（同上四项 + 卡片 / 宫格滚动性能）
  - [x] SubTask 13.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(home-layout): 首页 B/C/D 三套布局 + 入口跳转与标识"`（run=35551076040，退出码 0，已部署 Kline v1.0.2 (348)）
  - [x] SubTask 13.3: 交付说明，等待真机验收

## 阶段四：验收

- [x] Task 14: 逐条核验 checklist（figma 画廊 / 仓库与个人中心 / 首页四档 / 跳转与标识 / 工程与交付），失败条目回填 tasks 修复后重验
- [x] Task 15: 最终交付说明（各阶段 build 号、4 档一览、真机验证路径与回归点、`git status` 无遗留改动）

## 阶段五（变更二）：figma 画廊同步更新（设计稿先行）

- [x] Task 16: 更新 `figma/home-ui-proposals.html` 的 B / C / D 三屏
  - [x] SubTask 16.1: B 屏改为「一行横滑入口行（6 项 chips）+ 内容区卡片网格（大盘概览条通栏 / 自选 + 模拟汇总 2 列 / 涨幅榜通栏）」
  - [x] SubTask 16.2: C 屏改为「同一行横滑入口行 + 四块通栏卡片的紧凑分区列表」
  - [x] SubTask 16.3: D 屏改为「同一行横滑入口行 + 工作台混排（概览条大卡 / 2 列小卡 / 涨幅榜横滑 chips）」
  - [x] SubTask 16.4: A 屏与个人中心屏**保持不变**；重写 B/C/D 三屏的 `cap`/`desc`/`ann`/`pro`/`con`（要点：不再与底部栏重复、入口可横滑、内容区信息量），更新对比表六维度取值
  - [x] SubTask 16.5: 重截 `figma/_shots/home_B.png` / `home_C.png` / `home_D.png`（沿用 `#shot=` 与 700×560 窗口，A 屏与个人中心屏截图不动），逐屏自检无溢出 / 截断 / 重叠

## 阶段六（变更二）：首页数据层 + 共享横滑入口行

- [x] Task 17: 新增首页数据层 `Kline/Home/HomePageModel.swift`
  - [x] SubTask 17.1: `@MainActor final class HomePageModel: ObservableObject`，快照字段 `indexQuotes: [MarketRow]` / `breadth: HomeBreadth?`（`up`/`down`/`flat`/`limitUp`/`limitDown`/`validCount`）/ `favoriteRows: [MarketRow]` / `topGainers: [MarketRow]`
  - [x] SubTask 17.2: 指数快照：`DatabaseManager.metaList` 中 `type == "沪深京指数"` 取前 4 只，经 `MarketRowCache.row(for:prefetch:false)` 注册后按就绪状态输出
  - [x] SubTask 17.3: 涨跌家数与涨幅榜：只遍历 `MarketRowCache.rows` 中 `meta.type == "沪深主板"` 且 `hasBars` 的行，一次性聚合（涨/跌/平 + 涨停 `pct >= 9.8` / 跌停 `pct <= -9.8`）与排序（`changePct` 降序取前 5，过滤 nil）
  - [x] SubTask 17.4: 自选快照：`FavoritesStore.allGroup` 的标的取前 5，经 `MarketRowCache.rows(for:prefetch:)` 触发行预取（自选恒为高优先级）
  - [x] SubTask 17.5: 刷新时机：订阅 `MarketRowCache.$rows` 变化 → **防抖 250ms** 合并重算（写法对齐 `MarketPageModel.scheduleOverviewRefresh`）；订阅 `FavoritesStore` / `SimStore` 变化 → 立即重算对应块；同值不赋值（`@Published` 守卫）
  - [x] SubTask 17.6: 新增只读派生 `simSummary`（读 `SimStore.shared.summary(accountID: nil)`）与 `simPositions`（`positions` + `snapshot(for:)` 取前 5），捕获 `SimQuoteCenter` 取不到的标的时退回成本价，不显示错值
  - [x] SubTask 17.7: 编码自查：`body` 内禁止全表遍历 / O(n) 聚合；`Color.opacity` 入参 Double；异步回写统一切 `MainActor`

- [x] Task 18: 共享骨架改造 `Kline/Home/HomePageKit.swift`
  - [x] SubTask 18.1: `HomeEntryKind` 重构为 6 项：`search` / `tech` / `picker` / `strategy` / `condOrder` / `profile`；更新 `title`（搜索标的 / 技术指标 / 选股指标 / 交易策略 / 条件单 / 个人中心）、`subtitle`、`icon`（`magnifyingglass` / `function` / `line.3.horizontal.decrease.circle` / `chart.xyaxis.line` / `bell.badge` / `person.circle`）、`tint`
  - [x] SubTask 18.2: 新增 `HomeQuickEntryRow`（`ScrollView(.horizontal, showsIndicators: false)` + `HStack(spacing: 12)`，左右内边距 16、高 76）+ `HomeQuickEntryChip`（图标 22 + 名称 13、`Color(.secondarySystemBackground)` + `cornerRadius(12)`、`contentShape(Rectangle())`、命中区 ≥44×44、标识 `home.entry.<kind>`）
  - [x] SubTask 18.3: **删除**不再被使用的 `HomeEntryTile` / `HomeEntryRow` / `HomeEntryCard` / `HomeSearchBar`（不留死代码）；`HomeHeaderBar` 与 `HomeSearchModeView` 保持不变
  - [x] SubTask 18.4: `HomeOverlays` 由多个 Bool 改为单一目标枚举：`enum HomeOverlayTarget: Identifiable { case formula(FormulaKind); case condOrder }`，`func homeOverlays(target: Binding<HomeOverlayTarget?>)`；`formula` 呈现 `FormulaCenterView(initialKind:onClose:)`、`condOrder` 呈现 `SimCondListView(accountID: nil, onClose:)`，均 `.transition(.opacity)` + `zIndex(1000)`

- [x] Task 19: 首页容器接线 `Kline/Home/HomeView.swift`
  - [x] SubTask 19.1: 加 `@StateObject private var model = HomePageModel()`、`@State private var overlayTarget: HomeOverlayTarget?`；入口动作映射改为：`onSearch` / `onOpenFormula(FormulaKind)` / `onOpenCondOrder` / `onProfile` / `onSelectTab(Int)`（空态「去自选页」与模拟卡跳转仍用 `onSelectTab`）
  - [x] SubTask 19.2: 三档视图签名统一为 `init(model: HomePageModel, onSelectTab:onSearch:onOpenFormula:onOpenCondOrder:onProfile:)`，A 档签名保持不变
  - [x] SubTask 19.3: 编码自查 + 编译自查（`HomeView` 的 `#Preview` 补 `HomePageModel`；确认无遗留旧控件引用）

## 阶段七（变更二）：三档内容区改造 + 闭环

- [x] Task 20: 新增内容块视图 `Kline/Home/HomeContentBlocks.swift`
  - [x] SubTask 20.1: `HomeMarketOverviewStrip`（指数 chips：名称 + 现价 + 涨跌幅；涨跌家数行：涨 / 跌 / 平 + 涨停 / 跌停；点了指数进详情）
  - [x] SubTask 20.2: `HomeFavoritesBlock`（`compact: Bool` + `limit: Int` 参数化：行式 / 卡片式两种排版均由同一实现承载，含迷你走势开关；空态「暂无自选，去自选页添加」可点）
  - [x] SubTask 20.3: `HomeSimSummaryBlock`（总资产 / 当日盈亏 + 百分比 / 持仓占比 + 持仓 Top N；点击切模拟页）
  - [x] SubTask 20.4: `HomeTopGainersBlock`（`style: .list / .chips` 参数化：列表式与一行横滑 chips 式；未就绪占位「加载中」）
  - [x] SubTask 20.5: 全部使用语义化颜色与固定高度；行 / 卡可点区域 `contentShape(Rectangle())`；空态与加载态不引起布局抖动

- [x] Task 21: 三档布局改造（入口行统一 + 内容区各异）
  - [x] SubTask 21.1: `HomeLayoutBView`：`HomeHeaderBar` + `HomeQuickEntryRow` + 内容区**卡片网格**（概览条通栏 → 自选卡 / 模拟汇总卡 2 列 → 涨幅榜通栏卡，带迷你走势）
  - [x] SubTask 21.2: `HomeLayoutCView`：同一入口行 + 内容区**分区列表**（四块通栏卡片，内部紧凑行、无迷你走势；组标题 13pt `.secondary`）
  - [x] SubTask 21.3: `HomeLayoutDView`：同一入口行 + 内容区**工作台混排**（概览条大卡 → 2 列小卡：模拟汇总 + 自选 Top 3 紧凑 → 涨幅榜横滑 chips），删除旧的大卡 / 2×2 / 小卡入口实现
  - [x] SubTask 21.4: 三档互切自测：入口行内容一致、公式三域与条件单浮层互斥、自选空态与涨幅榜加载态、切档后滚动位置与 Tab 选中态正常

- [ ] Task 22: 阶段七闭环
  - [ ] SubTask 22.1: 编码自查（死代码清理确认、`body` 内无全表遍历、防抖生效、44pt 命中区）
  - [ ] SubTask 22.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(home-layout): 首页快捷入口改横滑行（剔除与底部栏重复项）+ 新增四块内容区"`
  - [ ] SubTask 22.3: 交付说明，等待真机验收

## 阶段八（变更二）：验收

- [ ] Task 23: 逐条核验 checklist 的「变更二」章节（入口行 / 内容区 / 数据口径 / 浮层 / figma 同步 / 工程），失败条目回填 tasks 修复后重验
- [ ] Task 24: 最终交付说明（build 号、入口与内容区一览、真机验证路径与回归点、`git status` 无遗留改动）

## 阶段九（变更二收尾）：档位名称同步

- [ ] Task 25: 修正档位名称（变更二漏项）：三档形态已从「宫格 / 分组列表 / 大卡」变为「横滑入口 + 内容区」，`HomeLayoutStyle.title` 仍是旧名，个人中心面板会误导用户
  - [ ] SubTask 25.1: [PageLayoutStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/PageLayoutStore.swift#L76-L83) 的 `HomeLayoutStyle.title` 改为：`A · 现有首页（保留）` / `B · 横滑入口 + 卡片网格（默认）` / `C · 横滑入口 + 分区列表` / `D · 横滑入口 + 工作台混排`
  - [ ] SubTask 25.2: `figma/home-ui-proposals.html` 的个人中心演示屏（`#scr-profileHomeLayout`）四个选项文案同步为新名（保持 A 屏不动），并重截 `figma/_shots/home_profile.png`
  - [ ] SubTask 25.3: 执行闭环命令 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "fix(home-layout): 首页档位名称同步为横滑入口形态"`

# Task Dependencies

- Task 2 依赖 Task 1（同一 HTML 文件、共用画廊骨架与 `SCREENS` 表）
- Task 3 依赖 Task 1、Task 2
- Task 5 依赖 Task 4
- Task 7 依赖 Task 4、Task 6
- Task 8 依赖 Task 5、Task 7
- Task 9 / 10 / 11 依赖 Task 6、Task 8
- Task 12 依赖 Task 9、Task 10、Task 11（跳转闭包需四档都在位）
- Task 13 依赖 Task 12
- Task 14 / 15 依赖 Task 13
- 阶段一与阶段二可并行（figma 原型不改 Swift 代码）

## 变更二

- Task 16（figma 更新）与 Task 17 / 18 可并行（前者只改 `figma/`，不碰 Swift）
- Task 17（数据层）与 Task 18（共享骨架）可并行（不同文件）
- Task 19 依赖 Task 17、Task 18（容器要同时接线模型与浮层枚举）
- Task 20 依赖 Task 17（内容块消费模型快照）
- Task 21 依赖 Task 18、Task 19、Task 20（三档要同时用到入口行、模型与内容块）
- Task 22 依赖 Task 21
- Task 23 依赖 Task 16、Task 22；Task 24 依赖 Task 23
- 变更二不改动 A 档、`PageLayoutStore`、个人中心、`ContentView`、`MarketPageKit`、`KlineUITests`（回归面为零）