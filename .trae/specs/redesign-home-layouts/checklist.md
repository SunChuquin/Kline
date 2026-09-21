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