# Tasks

## 阶段一：控件抽取（一控件一文件，A/B/C/D 呈现零变化）

- [x] Task 1: 建立 `Kline/Home/Widgets/` 并逐控件迁移
  - [x] SubTask 1.1: 新建 `Widgets/HomeHeaderBar.swift`：把 [HomePageKit.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomePageKit.swift#L143-L187) 的 `HomeHeaderBar` 逐行搬入（软件名 `Text("Kline")` 上的 `accessibilityIdentifier("home.page")` **必须原样保留**）
  - [x] SubTask 1.2: 新建 `Widgets/HomeQuickEntryRow.swift`、`Widgets/HomeQuickEntryChip.swift`：搬入 [HomeQuickEntryRow / HomeQuickEntryChip](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomePageKit.swift#L91-L141)（保留 `home.entry.<rawValue>` 锚点、chip `minWidth 168 / minHeight 68` 不动）
  - [x] SubTask 1.3: 新建 `Widgets/HomeSearchModeView.swift`：搬入 [HomeSearchModeView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomePageKit.swift#L189-L246)（含 `@FocusState` 自动聚焦 0.05s）
  - [x] SubTask 1.4: 新建 `Widgets/HomeSectionCard.swift`：搬入 [HomeSectionCard](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeContentBlocks.swift#L23-L41)，`compact` 默认 false、内边距 10/12 不变
  - [x] SubTask 1.5: 新建 `Widgets/HomeQuoteRow.swift`：搬入 [HomeQuoteRow](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeContentBlocks.swift#L70-L121)，同时把配色助手 `homeQuoteTint` / `homePillColor` 一并迁入并按需放宽为 `internal`
  - [x] SubTask 1.6: 新建 `Widgets/HomeMarketOverviewStrip.swift`：搬入 [HomeMarketOverviewStrip](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeContentBlocks.swift#L127-L211)（含 `@ObservedObject rowCache`、固定高度 50/52）
  - [x] SubTask 1.7: 新建 `Widgets/HomeFavoritesBlock.swift`：搬入 [HomeFavoritesBlock](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeContentBlocks.swift#L217-L244)
  - [x] SubTask 1.8: 新建 `Widgets/HomeSimSummaryBlock.swift`：搬入 [HomeSimSummaryBlock](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeContentBlocks.swift#L251-L360)，配色助手 `homeProfitColor` 随迁并放宽为 `internal`
  - [x] SubTask 1.9: 新建 `Widgets/HomeTopGainersBlock.swift`：搬入 [HomeTopGainersBlock](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeContentBlocks.swift#L366-L448)（含 `Style.list / .chips`）
  - [x] SubTask 1.10: 新建 `Widgets/HomePlaceholderBlock.swift`：把 [HomeLayoutAView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeLayoutAView.swift#L24-L31) 的占位内容提升为独立控件（`Text("首页").font(.title)` + `Text("欢迎来到首页")` + `accessibilityIdentifier("home.welcome")` + `frame(maxHeight: .infinity)`），实现与现呈现逐项一致
  - [x] SubTask 1.11: 精简 `HomePageKit.swift`：只保留 `HomeEntryKind`、`HomeOverlayTarget`、`HomeOverlays` / `.homeOverlays(...)`；删除已迁出的控件与本文件 `#Preview`
  - [x] SubTask 1.12: 删除 `Kline/Home/HomeContentBlocks.swift`（内容已全部迁出），并全量编译确认无残留引用
  - [x] SubTask 1.13: [HomeLayoutAView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeLayoutAView.swift) 改为组合 `HomePlaceholderBlock`（呈现不变，`home.welcome` 仍在）

- [ ] Task 2: 阶段一闭环
  - [ ] SubTask 2.1: 编码自查（`Color.opacity` 入参 Double、勿遮蔽同名参数、`@Published` 同值赋值守卫、只改本阶段相关文件、不顺手改样式）
  - [ ] SubTask 2.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "refactor(home-widgets): 首页控件抽取为一控件一文件（呈现零变化）"`
  - [ ] SubTask 2.3: 交付说明（build 号 / 改动与理由 / 真机验证路径：切 A/B/C/D 四档与改造前逐项一致；点快捷入口、开详情、进搜索、进公式中心、进条件单均正常）

## 阶段二：通用 JSON 布局引擎 + 首页接入

- [ ] Task 3: 引擎数据模型 `Kline/App/PageLayout/PageLayoutSchema.swift`
  - [ ] SubTask 3.1: `PageLayoutFile`（`schemaVersion` / `page` / `default` / `layouts`）、`PageLayoutDefinition`（`title` / `shortTitle` / `root` / `id` 由字典键提供）
  - [ ] SubTask 3.2: `PageLayoutNode`：`type` + 各类型专属可选字段 + `children` / `child`；用 `init(from:)` 按 `type` 解码；未知 `type` 抛错
  - [ ] SubTask 3.3: `PageLayoutAxis` / `PageLayoutAlignment` / `PageLayoutPadding` 等枚举与结构，`alignment` 支持 `top` / `center` / `bottom` / `leading` / `trailing`
  - [ ] SubTask 3.4: `WidgetParams`：`[String: WidgetParamValue]`（bool / int / double / string）+ 带默认值取值方法；缺 key 或类型不符一律取默认值

- [ ] Task 4: 注册表与渲染器
  - [ ] SubTask 4.1: `Kline/App/PageLayout/PageWidgetRegistry.swift`：泛型 `PageWidgetRegistry<Context>`（`register(_ name:builder:)` / `builder(for:) -> ((Context, WidgetParams) -> AnyView)?`）
  - [ ] SubTask 4.2: `Kline/App/PageLayout/PageLayoutRenderer.swift`：`PageLayoutRenderer<Context>`，`func view(for node: PageLayoutNode) -> AnyView`
  - [ ] SubTask 4.3: 容器节点语义逐项对齐：`vstack`/`hstack`/`scroll`（padding 写内层 VStack）/`card`（对齐 `HomeSectionCard` 的 13pt secondary 标题、`cornerRadius(12)`、内边距 10/12）/`frame`（`maxWidth: infinity` + `alignment`）/`divider`/`spacer`
  - [ ] SubTask 4.4: 未注册控件名渲染可诊断占位（含控件名文案 + 语义灰底），不崩溃、不静默空白

- [ ] Task 5: 配置仓库 `Kline/App/PageLayout/PageLayoutConfigStore.swift`
  - [ ] SubTask 5.1: 沙盒路径 `Documents/Layouts/<page>.json`；`loadFromDisk()` 用 `JSONDecoder`（写法对齐 `MarketConfigStore`），`saveToDisk()` 用 `.prettyPrinted + .sortedKeys + .atomic`
  - [ ] SubTask 5.2: 内置默认种入：沙盒缺文件时把内置默认写入沙盒并返回该默认；解析失败时同样降级到内置默认并重种
  - [ ] SubTask 5.3: 回退链实现：沙盒 → 内置默认 → `nil`（`nil` 表示该页退硬编码视图），全程不崩溃；`@Published` 暴露 `home: PageLayoutFile?`（同值不写）
  - [ ] SubTask 5.4: `reloadIfChanged(page:)`：比对文件修改时间，变了才重解码（供页面 `onAppear` 调用）
  - [ ] SubTask 5.5: `layout(id:for page:) -> PageLayoutDefinition?`：按 id 取档，缺失回退 `default`，再缺失返回 `nil`

- [ ] Task 6: 内置默认配置 `Kline/Home/Layouts/home.json`
  - [ ] SubTask 6.1: 按 spec「配置样例」写入 A/B/C/D 四档（逐项复刻 `HomeLayout{A,B,C,D}View`：A 标题栏+分隔线+占位；B 大盘概览非紧凑 + 自选/模拟半宽 + 涨幅榜 list；C 四块通栏紧凑 + 涨幅榜 list；D 大盘概览非紧凑 + 模拟/自选半宽紧凑（自选 `limit: 3`）+ 涨幅榜 chips）
  - [ ] SubTask 6.2: 内置默认的读取方式：优先 `Bundle.main.url(forResource: "home", withExtension: "json", subdirectory: "Layouts")`；**验证同步组是否自动把该 JSON 纳入 Resources**（查看构建产物的 `Kline.app` 根目录与 `Layouts/` 子目录）
  - [ ] SubTask 6.3: 若未被自动纳入：改为在 `Kline/Home/Layouts/` 下新增 `HomeLayoutDefaults.swift` 内嵌同一份 JSON 字符串常量（内容与 `home.json` 逐字一致，仅保留一条默认来源，不长期留双路径），并在 spec 的 Impact 里补一行说明

- [ ] Task 7: 首页接入
  - [ ] SubTask 7.1: `Kline/Home/HomeLayoutContext.swift`：`model: HomePageModel` + `onProfile` / `onEntryTap` / `onSelectTab` / `onOpenFormula` / `onOpenCondOrder`
  - [ ] SubTask 7.2: `Kline/Home/HomeWidgetRegistry.swift`：注册 `home.header` / `home.quickEntryRow` / `home.placeholder` / `home.marketOverview` / `home.favorites`（读 `compact` / `showsSparkline` / `limit`）/ `home.simSummary` / `home.topGainers`（读 `style` / `compact`）；入口动作映射与现有 `perform(_:)` 逐项一致
  - [ ] SubTask 7.3: [HomeView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeView.swift#L28-L54) 非搜索态改为 JSON 优先：`config.home` 可用且含所选档 → `PageLayoutRenderer` 渲染；否则回落现有 `HomeLayout{A,B,C,D}View`；搜索态与 `.homeOverlays` 挂载方式不变
  - [ ] SubTask 7.4: `HomeView.onAppear` 调 `PageLayoutConfigStore.shared.reloadIfChanged(page: "home")`
  - [ ] SubTask 7.5: 编码自查（不在 `body` 内重解码 / 重排节点树；`AnyView` 树结构稳定不强制 `id()` 重建；`@Published` 同值不写）

- [ ] Task 8: 阶段二闭环
  - [ ] SubTask 8.1: 编译通过（无警告级错误、无残留引用）
  - [ ] SubTask 8.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(page-layout): 通用 JSON 布局引擎 + 首页配置驱动（含硬编码回退）"`
  - [ ] SubTask 8.3: 交付说明（build 号 / 改动与理由 / 真机验证路径）

## 阶段三：等价性验收

- [ ] Task 9: 逐档对照与配置生效验证
  - [ ] SubTask 9.1: 个人中心逐档切 A/B/C/D，与阶段一交付的呈现逐项对照（字号 / 间距 / 分栏 / 颜色 / 滚动行为）
  - [ ] SubTask 9.2: 验证沙盒覆盖：通过沙盒直连（`KlineHTTPServer` 以 Documents 为根）或文件工具改 `Documents/Layouts/home.json` 中 `spacing` 12→24，重进首页确认生效
  - [ ] SubTask 9.3: 验证回退：把沙盒 JSON 改成非法内容（如删掉一个逗号），确认自动回退内置默认且不崩溃、可用；删除沙盒文件确认重新种回默认
  - [ ] SubTask 9.4: 验证未注册控件名占位（临时改一个 `name` 为不存在的值，确认显示可诊断占位后改回）

- [ ] Task 10: 收尾
  - [ ] SubTask 10.1: 无障碍锚点回归：`home.page`（四档）、`home.welcome`（A 档）、`home.entry.<rawValue>`（快捷入口）
  - [ ] SubTask 10.2: 清理临时状态（沙盒 JSON 恢复为默认 `spacing: 12`、控件名恢复），确认工作区无未提交改动

# Task Dependencies

- Task 2 depends on Task 1
- Task 4 depends on Task 3
- Task 5 depends on Task 3
- Task 6 depends on Task 3
- Task 7 depends on Task 4、Task 5、Task 6
- Task 8 depends on Task 7
- Task 9 depends on Task 8、Task 1（对照基线为阶段一交付的呈现）
- Task 10 depends on Task 9
- Task 3 / Task 4 / Task 5 / Task 6 与 Task 1 相互独立，可在阶段一交付后并行推进