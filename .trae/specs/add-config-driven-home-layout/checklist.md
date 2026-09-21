# Checklist

## 控件个体化

- [ ] `Kline/Home/Widgets/` 下每个控件都是独立 `struct` + 独立文件：`HomeHeaderBar` / `HomeQuickEntryRow` / `HomeQuickEntryChip` / `HomeSearchModeView` / `HomeSectionCard` / `HomeQuoteRow` / `HomeMarketOverviewStrip` / `HomeFavoritesBlock` / `HomeSimSummaryBlock` / `HomeTopGainersBlock` / `HomePlaceholderBlock`
- [ ] 每个控件的实现与抽取前逐行等价（字号 / 间距 / 语义色 / 固定行高 / ≥44pt 命中区均未顺手改动）
- [ ] 控件只接收数据与闭包，不持有状态、不发命令、不直接跳转
- [ ] `HomeContentBlocks.swift` 已删除，`HomePageKit.swift` 只保留 `HomeEntryKind` / `HomeOverlayTarget` / `HomeOverlays`，全量编译无残留引用
- [ ] `HomePlaceholderBlock` 承载 A 档占位且与现 `HomeLayoutAView` 内容一致（`Text("首页").font(.title)` + 「欢迎来到首页」+ `frame(maxHeight: .infinity)`）

## JSON 配置驱动

- [ ] `PageLayoutSchema.swift` 按 `type` 解码节点树；未知 `type` 解码失败（不静默忽略）
- [ ] `WidgetParams` 缺 key 或类型不符时取默认值，不抛错
- [ ] `PageWidgetRegistry<Context>` 与 `PageLayoutRenderer<Context>` 与具体页面无关（不引用任何 `Home*` 类型）
- [ ] 容器节点渲染语义与现有写法对齐：`scroll` 的 `padding` 写在内层 `VStack(spacing:)` 上；`card` 与 `HomeSectionCard` 的标题字号 / 内边距 10/12 / `cornerRadius(12)` / 浅灰底一致；`frame` 支持 `maxWidth: infinity` + `alignment: top`
- [ ] 未注册控件名渲染含控件名的可诊断占位，不崩溃、不静默空白
- [ ] `PageLayoutConfigStore` 沙盒路径为 `Documents/Layouts/<page>.json`，落盘用 `.prettyPrinted + .sortedKeys + .atomic`
- [ ] 首启沙盒缺文件时自动种入内置默认，用户无需操作即可正常渲染
- [ ] 沙盒 JSON 非法时自动回退内置默认并重种，全程不崩溃
- [ ] 内置默认也不可用时回退到硬编码 `HomeLayout*View`，首页仍可用
- [ ] 所选档位 id 在配置中缺失时回退到配置的 `default`，再缺失才退硬编码
- [ ] `reloadIfChanged(page:)` 按文件修改时间判断，变了才重解码
- [ ] 内置默认 `home.json` 的 A/B/C/D 四档与现有 `HomeLayout{A,B,C,D}View` 逐项对应（B/C/D 的卡片顺序、`compact`、`showsSparkline`、涨幅榜 `style`、D 档自选 `limit: 3`、半宽 `frame(maxWidth: infinity)` 全部正确）
- [ ] 内置默认 JSON 的读取方式已实测确认（同步组自动纳入 Resources，或按 Task 6.3 改为 Swift 常量内嵌且只保留一条来源）

## 首页接入

- [ ] `HomeWidgetRegistry` 注册 7 个 `home.*` 控件，入口动作映射与现有 `perform(_:)` 逐项一致（搜索 / 三个公式分段 / 条件单 / 个人中心）
- [ ] `HomeView` 非搜索态在配置可用时走 `PageLayoutRenderer`，不可用时回落硬编码视图
- [ ] 搜索态仍走 `HomeSearchModeView`、浮层仍走 `.homeOverlays(target:)`，未进 JSON
- [ ] `PageLayoutStore`、个人中心「首页布局」下拉、`TradingLayoutSettings`、`ProfileDetailView` 均未被改动
- [ ] `HomeView.onAppear` 调用了 `reloadIfChanged(page: "home")`
- [ ] `body` 内不做 JSON 解码 / 节点树重排；`AnyView` 树结构稳定、未用 `id()` 强制重建

## 行为等价与验收

- [ ] 真机 A/B/C/D 四档呈现与改造前逐项一致（含滚动行为与紧凑行高）
- [ ] 沙盒改 `home.json` 的 `spacing` 12→24 后重进首页生效，未重新安装
- [ ] 沙盒 JSON 写坏后自动回退、删文件后重新种回默认，均不崩溃
- [ ] `home.page` 四档均可被 `app.staticTexts[...]` 命中；`home.welcome`（A 档）与 `home.entry.<rawValue>` 均未回归
- [ ] 首页快捷入口、点行开 K 线详情、进搜索、进公式管理中心、进条件单、进个人中心全部正常
- [ ] 验收结束后沙盒 JSON 与控件名已恢复默认，工作区无临时残留改动

## 工程与交付

- [ ] 新增文件无需手改 `Kline.xcodeproj`（Swift 文件走同步组）；若内置默认改为资源文件且需改动工程文件，已在 spec 的 Impact 中补记
- [ ] 三个阶段各自独立可编译、可真机演示，且均已通过 `build_and_deploy.py` 交付
- [ ] 每个阶段交付时说明了 build 号、改动与理由、真机验证路径与回归点