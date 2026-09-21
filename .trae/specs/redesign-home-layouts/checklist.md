# Checklist

> 核验方式：逐条对照实现代码（静态核验，文件 + 行号）与原型文件。标 ⏳ 的为纯视觉/交互项，需真机确认。

## figma 原型画廊

- [ ] `figma/home-ui-proposals.html` 为自包含单文件，无外链依赖（无 CDN / 无远程字体 / 无远程图片）—— 全文仅 `xmlns` 命名空间与 data-URI favicon，无 `http(s)://` 资源引用、无 `@import url(`
- [ ] 设备框与既有画廊一致（iPad mini 4 横屏 1024×768，等比缩放至 573×430，`.bezel` 深色外壳）—— `.screen-wrap` 573×430 + `.screen` 1024×768 `scale(.55957)`，与 `favorites-market-ui-proposals.html` 同参数
- [ ] 首页 4 屏齐全且可切换：A 现状复刻 / B 宫格快捷入口 / C 分区列表入口 / D 卡片工作台 —— `#scr-homeA`/`#scr-homeB`/`#scr-homeC`/`#scr-homeD`
- [ ] A 屏与现状逐项对应：标题栏（Kline 图标 + 名称 + 右侧「登录」胶囊）+ 分隔线 + 居中「首页 / 欢迎来到首页」+ 底部四 Tab
- [ ] B 屏含搜索条 + 「快捷入口」宫格（6 格、四列、图标在上名称在下）
- [ ] C 屏含三组（行情 / 研究 / 账户）入口行，行有标题 + 副标题 + chevron
- [ ] D 屏含顶部大卡（搜索）+ 2×2 中卡 + 底部小卡（个人中心）
- [ ] 个人中心演示屏展示六行设置行（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 首页布局）与四选项选择面板 —— `#scr-profileHomeLayout`
- [ ] 每屏有编号标注，且与右侧标注栏条目一一对应（描述 / 布局标注 / 优势 / 代价）—— 每屏 `.marker` 编号与 `SCREENS` 表 `ann` 顺序一致
- [ ] 跨方案对比表覆盖 4 档，维度含信息密度 / 横屏利用 / 首屏信息量 / 操作步数 / 实现复杂度 / 适配场景
- [ ] 支持 `#shot=<屏 id>` 单屏定位，无头浏览器截图时无多余区块干扰 —— `body.shot` 隐藏 hero / 区块标题 / 切换器 / 标注栏 / 对比表
- [ ] 逐屏截图已输出到 `figma/_shots/`（`home_A`/`home_B`/`home_C`/`home_D`/`home_profile`），每屏无溢出 / 无文字截断 / 无元素重叠

## 布局偏好与个人中心

- [ ] `HomeLayoutStyle` 取值域 A/B/C/D，带 `title` / `shortTitle`，满足 `LayoutOptionsPanel` 泛型约束（`CaseIterable & Hashable & Identifiable`）
- [ ] `PageLayoutStore.homeLayout` 写入 `UserDefaults`（key `kline.homeLayout`），**默认值为 B** —— `PageLayoutStore.swift` 的 `private init()` 中 `?? .b`
- [ ] 存储值非法或缺失时回退 B 且不崩溃
- [ ] 个人中心出现新设置行「首页布局」，位于「行情页布局」行下方，右侧下拉按钮显示当前档名（字号 12 / 高 28 / `.plain` / 蓝色前景）
- [ ] 新选择面板与 `KlineThemeOptionsPanel` 逐项一致（210pt 宽、行内 padding、蓝色 checkmark、底部「完成」、圆角 12、阴影 black 20% radius 12 y 4）—— 复用同一泛型 `LayoutOptionsPanel`，未新增第二套面板
- [ ] 新浮层挂在页面容器层 overlay（`black 25%` 遮罩 + 居中 + `.transition(.opacity)` + `zIndex(1000)`），不被 ScrollView 裁剪
- [ ] 七个浮层（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 首页布局 / 公式中心）互斥，同时只呈现一个 —— `ProfileDetailView.swift` 7 个 `onChange`，任一置 true 时清其余 6 项
- [ ] 切换首页布局无需重启即生效；重启后仍保持所选档位 —— `@Published` + `didSet` 写 UserDefaults，容器 `@ObservedObject layoutStore`

## 首页四档

- [ ] `HomeView` 按 `homeLayout` 分发 A/B/C/D 四档 —— 与 [FavoritesView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift#L28-L40) 同构的 `switch`
- [ ] A 档即改造前实现（标题栏 + 分隔线 + 居中占位），`home.welcome` 标识保留
- [ ] B 档：搜索条 + 「快捷入口」宫格；列数按可用宽度自适应（≥960 四列 / ≥640 三列 / 否则两列）
- [ ] C 档：三组入口行，行高固定 56pt，副标题 12pt，行间 `Divider`，`ScrollView` + `LazyVStack`
- [ ] D 档：大卡 + 2×2 中卡（高 104）+ 小卡（高 64），卡片背景 `Color(.secondarySystemBackground)` + `cornerRadius(12)`
- [ ] 四档共用同一份入口清单（`HomeEntryKind` 6 项：搜索 / 自选 / 行情 / 模拟 / 公式管理 / 个人中心），无重复实现 —— 入口控件在 `HomePageKit.swift`，三档布局视图只做组合
- [ ] 四档均使用语义化颜色，深色模式可读（无写死白底）
- [ ] 所有可点击元素命中区 ≥ 44×44pt；行高 / 卡高 / 格高固定，点击与状态切换不抖动
- [ ] 搜索模式四档共用且与现状逐项一致（返回按钮 + 搜索框自动聚焦 + `SearchPageView`），点返回回到该档首页内容
- [ ] 公式管理入口在首页容器层全屏呈现 `FormulaCenterView`（初始「技术指标」段），页内「返回」关闭后回到原档位

## 跳转与标识

- [ ] 首页「自选 / 行情 / 模拟」入口切底部 Tab，索引与 `ContentView.menuItems` 一致（1 / 2 / 3）—— `HomeView` 的 `@Binding selectedTab` 写回
- [ ] 三处 `HomeView(...)` 调用方均已更新：ContentView 两处传 `$selectedTab`、MarketPageKit 搜索 overlay 传 `.constant(2)`、`#Preview` 传 `.constant(0)`
- [ ] 行情页搜索图标（`MarketPageKit` overlay）行为与改造前一致，不会改动底部 Tab 选中态
- [ ] `home.page` 挂在四档共用的标题栏 `Text("Kline")` 上（不挂内容根容器：SwiftUI 容器标识未必暴露成元素）；`KlineUITests.test02` 改用 `app.staticTexts["home.page"]` 判定首页已显示
- [ ] 默认档位为 B 时既有冒烟用例不误报（首页判定不再依赖 A 档专有文案）

## 工程与交付

- [ ] 新增文件全部位于 `Kline/` 目录树内，无需手工改 `project.pbxproj`（依赖 `PBXFileSystemSynchronizedRootGroup`）
- [ ] 未新增数据源、未改任何持久化文件结构（`favorites.json` / `market_columns.json` / `sim.json` 不变）
- [ ] 阶段二 / 三闭环命令均返回 0 / 6 / 7，构建通过
- [ ] A 档下首页行为与改造前一致（回归点）；`git status` 无遗留未提交改动，spec 三件套随闭环命令一并提交