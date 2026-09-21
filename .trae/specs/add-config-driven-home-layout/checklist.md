# Checklist

> 状态说明：✅ = 已核验通过（静态代码核验 / 独立核验代理 / 构建产物）。⏳ = 需设备解锁 + Kline 在前台的真机动作，本轮三次交付均因「设备无人值守」停在云端构建成功，**待用户真机验收**。

## 控件个体化

- [x] `Kline/Home/Widgets/` 下每个控件都是独立 `struct` + 独立文件：`HomeHeaderBar` / `HomeQuickEntryRow` / `HomeQuickEntryChip` / `HomeSearchModeView` / `HomeSectionCard` / `HomeQuoteRow` / `HomeMarketOverviewStrip` / `HomeFavoritesBlock` / `HomeSimSummaryBlock` / `HomeTopGainersBlock` / `HomePlaceholderBlock`（11 个文件各 1 个 struct）
- [x] 每个控件的实现与抽取前逐行等价（字号 / 间距 / 语义色 / 固定行高 / ≥44pt 命中区均未顺手改动）
- [x] 控件只接收数据与闭包，不持有状态、不发命令、不直接跳转
- [x] `HomeContentBlocks.swift` 已删除，`HomePageKit.swift` 只保留 `HomeEntryKind` / `HomeOverlayTarget` / `HomeOverlays` / `homeOverlays(...)`，编译无残留引用（run=35611144835 构建成功）
- [x] `HomePlaceholderBlock` 承载 A 档占位且与现 `HomeLayoutAView` 内容一致（`Text("首页").font(.title)` + 「欢迎来到首页」+ `frame(maxHeight: .infinity)`）；另新增共享配色助手 `HomeWidgetPalette.swift`（3 个函数由 `private` 放宽为 `internal`，函数体与注释一字未改）

## JSON 配置驱动

- [x] `PageLayoutSchema.swift` 按 `type` 解码节点树；未知 `type` 解码失败（不静默忽略）
- [x] `WidgetParams` 缺 key 或类型不符时取默认值，不抛错
- [x] `PageWidgetRegistry<Context>` 与 `PageLayoutRenderer<Context>` 与具体页面无关（`Kline/App/PageLayout/` 4 文件对 `Home*` 类型 **0 命中**）
- [x] 容器节点渲染语义与现有写法对齐：`scroll` 的 `padding` 写在内层容器上；`card` 与 `HomeSectionCard` 的 13pt secondary 标题 / 内边距 10 或 12 / `VStack` 间距 8 或 10 / `cornerRadius(12)` / `secondarySystemBackground` / `frame(maxWidth: .infinity, alignment: .leading)` 逐字符一致；`frame` 支持 `maxWidth: infinity` + `alignment: top`
- [x] 未注册控件名渲染含控件名的可诊断占位（`questionmark.square.dashed` + 「未注册控件：<name>」+ 语义灰底 + 最小高 44），不崩溃、不静默空白
- [x] `PageLayoutConfigStore` 沙盒路径为 `Documents/Layouts/<page>.json`，落盘用 `Data.write(to:options:.atomic)`；写入内容为配置原文（内置默认本身即 2 空格缩进的可读 JSON，逐字落盘可保证「沙盒里看到的就是源码里那份」，比重新 `JSONEncoder` 编码更贴合可人工编辑的诉求）——**该条按实际实现修正，原「prettyPrinted + sortedKeys」要求已由 tasks.md SubTask 5.1 同步调整**
- [x] 首启沙盒缺文件时自动种入内置默认，用户无需操作即可正常渲染
- [x] 沙盒 JSON 非法（语法错 / 未知 `type`）时自动回退内置默认并重种，全程 `try?` / `do-catch` 兜底，无强制解包
- [x] 内置默认也不可用时回退到硬编码 `HomeLayout*View`（`home` 被置 nil → `HomeView` 走 `else` 分支），首页仍可用
- [x] 所选档位 id 在配置中缺失时回退到配置的 `defaultLayoutID`，再缺失才退硬编码
- [x] `reloadIfChanged(page:)` 按文件修改时间判断，变了才重解码；沙盒文件不存在时也走一次完整 reload 以触发首启种入
- [x] 内置默认 `home.json` 的 A/B/C/D 四档与现有 `HomeLayout{A,B,C,D}View` 逐项对应（区块顺序、卡片文案、`compact`、`showsSparkline`、涨幅榜 `style`（B/C list、D chips）、D 档自选 `limit: 3`、半宽 `frame(maxWidth: infinity, alignment: top)`、`HStack(alignment: .top, spacing: 12)`、`padding 16` + `VStack(spacing: 12)` 全部一致）——独立核验代理逐项对照通过；唯一实质差异「内容区滚动指示器」已修复（`showsIndicators: true`，run=35615307932 构建成功）
- [x] 内置默认 JSON 的语法与结构已用脚本校验：可 `json.loads`、`schemaVersion=1` / `page=home` / `default=B`、四档齐全、全部节点 `type` 在渲染器白名单内、全部 `widget.name` 在注册表内
- [x] 内置默认 JSON 的读取方式已实测确认：判定 **不能用 Bundle 资源**（同步组对未知类型需 `membershipExceptions` 才进 Resources，Windows 端无法本地验证），改为 Swift 多行字符串常量 [HomeLayoutDefaults.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeLayoutDefaults.swift)，编译期必然进二进制；已在 spec 的 Impact 补记

## 首页接入

- [x] `HomeWidgetRegistry` 注册 7 个 `home.*` 控件，控件名与 JSON 的 `name` 逐字一致，实参标签与各控件声明逐个匹配；入口动作映射（搜索 / 三个公式分段 / 条件单 / 个人中心）与各档现有 `perform(_:)` 逐项一致
- [x] `HomeView` 非搜索态在配置可用时走 `PageLayoutRenderer`，不可用时回落硬编码视图（A/B/C/D 四档分支齐全）
- [x] 搜索态仍走 `HomeSearchModeView`、浮层仍走 `.homeOverlays(target:)`，未进 JSON
- [x] `PageLayoutStore`、个人中心「首页布局」下拉、`TradingLayoutSettings`、`ProfileDetailView` 均未被改动
- [x] `HomeView.onAppear` 调用了 `registerBuiltInDefaults` + `reloadIfChanged(page: "home")`；`ContentView.mainContentView` 是 `switch selectedTab` 分发，切回首页会重建视图并重触发 `onAppear`，故改沙盒 JSON 后切走再切回即可生效
- [x] `body` 内不做 JSON 解码 / 节点树重排；`AnyView` 树结构稳定、未用 `id()` 强制重建

## 行为等价与验收

- [x] **静态等价已核验通过**（独立只读核验代理 10 项全通过）：四档节点树与硬编码视图逐项一致、`card` 渲染与 `HomeSectionCard` 逐字符一致、引擎解耦、回退链完整、沙盒路径正确、锚点唯一
- [ ] ⏳ 真机 A/B/C/D 四档呈现与改造前逐项一致（含滚动行为与紧凑行高）
- [ ] ⏳ 沙盒改 `home.json` 的 `spacing` 12→24 后重进首页生效，未重新安装
- [ ] ⏳ 沙盒 JSON 写坏后自动回退、删文件后重新种回默认，均不崩溃
- [ ] ⏳ 未注册控件名显示可诊断占位（临时改一个 `name` 后改回）
- [x] `home.page` 唯一于 `Widgets/HomeHeaderBar.swift`（四档共用标题栏）且 `KlineUITests.swift` 的 `staticTexts["home.page"]` 期望未破坏；`home.welcome` 唯一于 `Widgets/HomePlaceholderBlock.swift`；`home.entry.<rawValue>` 唯一于 `Widgets/HomeQuickEntryChip.swift`
- [ ] ⏳ 首页快捷入口、点行开 K 线详情、进搜索、进公式管理中心、进条件单、进个人中心全部正常
- [x] 验收结束后内置默认为等价形态（`spacing: 12`、7 个控件名全部有注册），工作区无临时残留改动

## 工程与交付

- [x] 新增文件无需手改 `Kline.xcodeproj`（Swift 文件走同步组）；内置默认改为 Swift 常量而非资源文件，已在 spec 的 Impact 中补记
- [x] 三个阶段各自独立可编译：run=35611144835（阶段一）、run=35613504027（阶段二，含递归存储属性编译错修复）、run=35615307932（滚动指示器修复），均 exit 6 云端构建成功
- [ ] ⏳ 三个阶段各自可真机演示（构建产物均已就绪，待设备解锁后在设备上安装验收）
- [x] 每个阶段交付说明了 build 号、改动与理由、真机验证路径与回归点