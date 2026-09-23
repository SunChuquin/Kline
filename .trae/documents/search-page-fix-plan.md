# 搜索页面整改计划（热门搜索历史化 + 背景不透明 + 结果长按管理）

## 一、Summary（本轮目标）

用户报的三个问题都落在**同一个共享搜索页面**上，因此改一处即覆盖首页 / 行情页的全部 A/B/C/D 布局：

| # | 问题                | 根因（已定位）                                                                                                                          | 方案                                                                                                                             |
| - | ----------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 1 | 所有搜索页面的「热门搜索」永不更新 | `SearchPageView` 里是写死的 5 只字符串常量                                                                                                  | 改为**本地搜索历史**（UserDefaults 持久化，最近点开的标的倒序，最多 10 条）；无历史时回落固定 5 只                                                                  |
| 2 | 行情页打开的搜索页「完全透明」   | ① `HomeSearchModeView` 把 `.background` 加在 `.frame(minHeight:56)` **之前** → 头部上下各约 8pt 透明带；② 搜索页自身无背景 → 结果区整块透明，行情表透出（且点击会穿透到背后表格） | 头部 `.frame(minHeight:56)` 提到 `.background` 之前；`HomeSearchModeView` 根 VStack 与 `SearchPageView` 根视图补 `Color(.systemBackground)` |
| 3 | 搜索出来的列表不能长按管理     | 结果行只有 `Button`（点击开详情），无长按手势                                                                                                      | 结果行（含类型筛选结果）加长按面板：加/取消自选、加入指定分组、备注…、设置/取消预警 —— 与行情页行长按**同一套面板与同一套动作逻辑**（抽公共 Kit，不复制第二套）                                        |

附带修正（同一区域内的确定性缺陷，已列明供你否决）：

* 4a.「股票类型」三个 chip 现在是 `searchText = "沪深主板"` 走关键字 LIKE 查询 → **必然 0 命中**，改为**类型筛选**（按 `meta.type` 过滤列出该类全部标的，chip 高亮选中态，再点一次取消）。

* 4b. 搜索 0 命中时永远显示「搜索中…」→ 搜索完成且无结果时改显示「未找到匹配的标的」。

明确不做（用户已确认边界）：图表页内的搜索**栏**下拉（`KlineDetailView.chartSearchBar` / `LinkedKlineTile` 的 `SearchContentView`）本轮不加长按、不改热门搜索。

## 二、Current State Analysis（现状与证据）

### 2.1 搜索页面只有一个实现，被所有布局共用

* 搜索页面 = [SearchPageView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/SearchPageView.swift)（`@Binding searchText`，无自己的状态模型）。

* 首页侧：搜索态由 [HomeView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeView.swift#L36-L38) 最先判断 → `HomeSearchModeView` → `SearchPageView`。A/B/C/D 硬编码档与 JSON 配置档（`PageLayoutConfigStore` 的 `page: "home"`）都从这一处进；双击首页 Tab 也走这里（[ContentView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/ContentView.swift#L180-L198)）。

* 行情页侧：A/C 档走 [MarketHeaderBar](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift#L526-L533) 的放大镜、B/D 档走 [MarketToolBar](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift#L628-L630)，两者都只写 `model.homeSearchActive = true`，再由 [MarketSheets](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift#L759-L780) 的容器层 overlay 复用 `HomeView(isSearching:)`。

结论：**改** **`SearchPageView`** **+** **`HomeSearchModeView`** **两个文件即覆盖全部布局**，无需逐档改动。

### 2.2 三个问题的具体代码位置

1. 热门搜索写死：[SearchPageView.swift:40](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/SearchPageView.swift#L40) `ForEach(["贵州茅台", "比亚迪", "宁德时代", "东方财富", "药明康德"]...)`，无任何数据源。
2. 类型 chip 无效：[SearchPageView.swift:64-L66](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/SearchPageView.swift#L62-L73) 点一下把 `"沪深主板"` 当关键词写入 `searchText` → [performSearch](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/SearchPageView.swift#L136-L140) → `DatabaseManager.performSearch` 做 `name LIKE '%沪深主板%' OR code LIKE ...` → 0 行。
3. 透明背景两处：

   * [HomeSearchModeView.swift:53-L54](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/Widgets/HomeSearchModeView.swift#L51-L54)：`.background(Color(.systemBackground))` 在 `.frame(minHeight: 56)` 之前 → 背景只覆盖内容自然高度（约 40pt），被 56pt 框居中后上下各留约 8pt 透明带。

   * [SearchPageView.swift:15-L22](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/SearchPageView.swift#L15-L22) 根 VStack 无背景；而 [MarketSheets 的 overlay](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift#L763-L769) 也没有兜底背景 → 行情表从搜索区透出，且因无命中视图，触摸会落到背后的行情行上。
4. 无长按：[SearchPageView.swift:96-L130](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/SearchPageView.swift#L96-L130) 结果行是 `Button { DetailRouter.shared.open }`，无 `.onLongPressGesture`。行情页/自选页的长按面板是自绘的（[MarketPageKit.swift:738-L742](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift#L735-L742)），明确不用 `.contextMenu`。
5. 「搜索中…」常驻：[SearchPageView.swift:86-L94](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/SearchPageView.swift#L86-L94) 以 `searchResults.isEmpty` 作为加载态判据，0 命中时永远停在加载态。

### 2.3 可直接复用的既有件（不新造）

* 面板与弹窗：[FavoritesRowMenu.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesRowMenu.swift) 的 `FavoritesOverlayCard` / `FavoritesRowMenuPanel` / `FavoritesNoteSheet` / `FavoritesBatchAlertSheet`（单只预警走 count==1 的批量弹窗），加分组走既有 `AddToGroupSheet(meta:fav:)`。

* 长按面板的**动作口径**（无分组上下文：加/取消自选、加入指定分组、备注、设置/取消预警）现只存在于 [MarketPageModel](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift#L395-L449)（`menuTarget` / `openRowMenu` / `rowMenuItems` / `performRowMenu`）。自选页有分组口径，不参与。

* 历史上限与持久化惯例：`UserDefaults` + `kline.` 前缀 key（见 `KlineThemeStore` 的 `kline.displayTheme`）。

## 三、Proposed Changes

### 改动 1（新文件）`Kline/Home/SearchHistoryStore.swift`

**Why**：热门搜索改成「本地搜索历史」需要一份持久化、可观察、去重有序的记录；独立成 Store 文件，与 `FavoritesStore.swift` / `MarketConfigStore.swift` / `KlineTheme.swift` 同惯例（同步组项目，新增 `.swift` 无需改 pbxproj）。

**What/How**：

```swift
/// 一条搜索历史：只存回显与再次检索所需的字段（id 去重、name 用于回填搜索框）
struct SearchHistoryEntry: Codable, Equatable, Identifiable {
    let id: Int
    let name: String
    let code: String
    let type: String
}

/// 本地搜索历史（热门搜索的数据源）：最近点开的标的倒序、按 id 去重、最多 10 条。
/// UserDefaults 存 JSON；无历史时由搜索页回落固定清单（本 Store 不掺业务）。
@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()
    static let maxCount = 10
    private static let storageKey = "kline.searchHistory"   // 惯例：kline.<domain>

    @Published private(set) var entries: [SearchHistoryEntry] = []
    private let defaults = UserDefaults.standard

    init() { load() }

    /// 记录一次点开：已存在则提到最前（去重），超出上限丢最旧
    func record(_ meta: MetaItem) { /* entries.removeAll { $0.id == meta.id }; insert(at:0); prefix(maxCount); save() */ }

    private func load() { /* defaults.data(forKey:) → JSONDecoder；失败按空处理 */ }
    private func save() { /* JSONEncoder → defaults.set(data) */ }
}
```

### 改动 2（重写）`Kline/Home/SearchPageView.swift`

**Why**：三个问题的宿主文件；同时把页面状态收进一个小模型，避免在 `body` 里遍历全表（项目硬约定）。

**What/How**：单文件内新增 `SearchPageModel` + 重写 `SearchPageView`，`#Preview` 保留。

```swift
/// 搜索页状态模型：结果快照 / 类型筛选快照 / 长按面板与弹窗目标。
/// 快照只在事件里算好（芯片点击、搜索回调），body 内不遍历 metaList（3611 只）。
@MainActor
final class SearchPageModel: ObservableObject {
    @Published var searchResults: [MetaItem] = []
    @Published var keywordDone = false          // 本次关键字搜索是否已回调（决定「未找到」还是「搜索中」）
    @Published var typeFilter: String? = nil    // 选中的股票类型（nil = 未筛选）
    @Published var typeResults: [MetaItem] = [] // 该类型全部标的快照
    @Published var rowMenuTarget: FavoritesRowMenuTarget? = nil
    @Published var noteEditorTarget: FavoritesRowMenuTarget? = nil
    @Published var alertSheetTargets: [MetaItem] = []
    @Published var addGroupTarget: MetaItem? = nil

    private let db = DatabaseManager.shared
    private let history = SearchHistoryStore.shared

    /// 关键字搜索（原 performSearch 搬入）：清空即清结果与完成标记
    func search(_ keyword: String) { ... db.searchMetaAsync ... }

    /// 类型 chip：再点同一个 = 取消筛选
    func toggleType(_ type: String) {
        if typeFilter == type { typeFilter = nil; typeResults = [] }
        else { typeFilter = type; typeResults = db.metaList.filter { $0.type == type } }
    }

    /// 打开结果：先记历史（热门搜索的唯一写入点），再开详情
    func open(_ meta: MetaItem, in list: [MetaItem]) {
        history.record(meta)
        DetailRouter.shared.open(meta, in: list)
    }

    // 长按面板（口径与行情页完全一致，逻辑来自 MetaRowMenuKit —— 见改动 4）
    func openRowMenu(_ meta: MetaItem) { rowMenuTarget = FavoritesRowMenuTarget(meta: meta, groupID: nil, isMarketPage: true) }
    func rowMenuItems(for target: FavoritesRowMenuTarget) -> [FavoritesRowMenuItem] { MetaRowMenuKit.items(for: target.meta) }
    func performRowMenu(_ action: FavoritesRowMenuAction, for target: FavoritesRowMenuTarget) { /* switch MetaRowMenuKit.perform(...) → 写 addGroupTarget / noteEditorTarget / alertSheetTargets */ }
}
```

视图结构（分支顺序即优先级：关键字 > 类型筛选 > 默认页）：

```swift
var body: some View {
    VStack(spacing: 0) {
        if !searchText.isEmpty { resultList }                       // 关键字结果
        else if let t = model.typeFilter { typeList(t) }            // 类型筛选结果
        else { defaultView }                                        // 热门搜索 + 股票类型
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color(.systemBackground))                           // ← 透明问题兜底（问题 2）
    .onChange(of: searchText) { model.search($0) }                   // 保持 iOS 15 旧签名
    .overlay { rowMenuLayers }                                      // 面板挂在页面自身容器层
    .sheet(item: $model.addGroupTarget 的 IdentifiableMeta 包装) { AddToGroupSheet(meta:fav:) }
}
```

逐项细节：

1. **热门搜索（问题 1）**：`private var hotNames: [String]` = `historyStore.entries.map(\.name)`，为空时回落 `static let fallbackHotNames = ["贵州茅台","比亚迪","宁德时代","东方财富","药明康德"]`；`SearchPageView` 用 `@ObservedObject private var historyStore = SearchHistoryStore.shared` 订阅，点开结果后回来立即刷新。chip 外观沿用现状（`systemGray5` 底 + `cornerRadius(20)` + padding 6/16），点击仍是 `searchText = name`（保持「热搜 = 检索入口」语义，不做直接跳详情）。标题仍为「热门搜索」。
2. **股票类型（4a）**：chip 改为调 `model.toggleType(type)`；选中态 = `.foregroundColor(.white)` + `.background(Color.accentColor)`，未选中 = `.primary` + `systemGray5`；padding / `cornerRadius(20)` 与热门 chip 完全一致（不产生两种手感）。选中类型的结果列表顶部加一行 13pt 次要色标题「沪深主板 · 共 N 只」，避免列表无上下文。
3. **结果行渲染统一（问题 3 + 4b）**：关键字结果与类型筛选结果共用 `resultRow(_ item:in:)`；列表容器由 `VStack` 改 `LazyVStack`（沪深主板约 1800 只，非懒加载会卡）。行内 `.contentShape(Rectangle())` + `.onTapGesture { model.open(item, in: list) }`（与 `MarketTableRow` 同款内层点击），外层容器 `.onLongPressGesture(minimumDuration: 0.5) { withAnimation(.easeOut(duration: 0.15)) { model.openRowMenu(item) } }` —— 与行情页 `rowCard` 的「内层点击 + 外层长按」结构一致，避免同一视图上两种手势互相吞。空态：`model.keywordDone && searchResults.isEmpty` → 「未找到匹配的标的」（文案与 `SearchContentView` 一致），否则「搜索中…」。
4. **长按面板落点**：`rowMenuLayers` 照抄 [MarketSheets.rowMenuLayers](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift#L796-L830) 的三段结构（面板 / 备注 / 预警，均用 `FavoritesOverlayCard` 包装，`onSelect` 先关面板再执行动作），备注保存走 `FavoritesStore.shared.setNote`。

### 改动 3（局部编辑）`Kline/Home/Widgets/HomeSearchModeView.swift`

**Why**：修头部透明带 + 给整页兜底不透明（问题 2）。

**What/How**：

* 头部（现 53/54 行）顺序互换，并把宽度撑满提前：

```swift
HStack { 返回按钮 + 搜索框 }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: 56)
    .background(Color(.systemBackground))
```

* 根 VStack 补铺底（`Divider` 与 `SearchPageView` 区域一并盖住）：

```swift
VStack(spacing: 0) { 头部; Divider(); SearchPageView(searchText: $searchText).frame(maxHeight: .infinity) }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color(.systemBackground))
```

Home 侧的搜索态与行情 overlay 侧同时收益：不再透出背后内容，也不再让点击穿透到行情表。

### 改动 4（小重构）`Kline/Favorites/FavoritesRowMenu.swift` + `Kline/Market/MarketPageKit.swift`

**Why**：搜索页的长按面板必须与行情页同口径（同项、同顺序、同不可用原因、同动作）。直接复制一份 20+20 行到搜索页违反项目「不复制第二套弹窗 / 面板」的既有约定，故把**无分组上下文**的面板逻辑抽成一个小 Kit，两处共用。

**What/How**：

* `FavoritesRowMenu.swift` 末尾（`FavoritesAlertKit` 之后）新增：

```swift
/// 「无分组上下文」行菜单逻辑：行情页 / 搜索页共用（不出现固顶与移前移后）。
/// 自选页有分组口径，仍走 FavoritesPageKit.rowMenuItems。
@MainActor
enum MetaRowMenuKit {
    /// 面板项：加/取消自选、加入指定分组、备注…、设置/取消预警（含不可用原因）
    static func items(for meta: MetaItem) -> [FavoritesRowMenuItem] { /* 现 MarketPageModel.rowMenuItems 的内容原样搬入 */ }

    /// 需要弹窗的动作交回调用方；就地完成的返回 nil
    enum Outcome { case addToGroup(MetaItem); case note(FavoritesRowMenuTarget); case alert(MetaItem) }

    static func perform(_ action: FavoritesRowMenuAction,
                        for target: FavoritesRowMenuTarget) -> Outcome? { /* 现 MarketPageModel.performRowMenu 的分支原样搬入 */ }
}
```

* `MarketPageKit.swift`：`rowMenuItems(for:)` 改为 `MetaRowMenuKit.items(for: target.meta)`；`performRowMenu(_:for:)` 改为 `switch MetaRowMenuKit.perform(action, for: target)` 写回 `addGroupTarget` / `noteEditorTarget` / `alertSheetTargets`。**对外行为逐项不变**（同项、同顺序、同 reason、同落点），`menuTarget` / `openRowMenu` / 面板挂载处均不动。

## 四、Assumptions & Decisions

| 项            | 决定                                                                           | 理由                                       |
| ------------ | ---------------------------------------------------------------------------- | ---------------------------------------- |
| 热门搜索的数据源     | 本地搜索历史（最近点开倒序、去重、上限 10）；**无历史回落固定 5 只**                                      | 用户本轮选定；回落保证首启不是空区块                       |
| 写历史的时机       | 只在**点开搜索结果**时写（开详情前）                                                         | 「点开过的标的」是最强信号；纯输入不入历史，避免噪声               |
| 点热搜 chip 的行为 | 只回填搜索框（不直接跳详情）                                                               | 保持「热搜 = 检索入口」的现状语义，行为可预期                 |
| 类型筛选的选中态     | 可再点取消回默认页；选中时蓝底白字                                                            | 与页内其它 chip 尺寸一致，仅用色区分状态                  |
| 长按面板项        | 与行情页完全一致（无固顶 / 移前移后；无「取消自选」的危险色变体差异）                                         | 搜索结果不在任何分组里，分组态项目无意义                     |
| 列表实现         | 换 `LazyVStack`                                                               | 类型筛选可上 1800 行，非懒加载会卡顿                    |
| 图表页搜索栏       | 本轮不动                                                                         | 用户明确「不是搜索栏」，且搜索页已覆盖入口需求                  |
| 兼容约束         | 不引入 iOS 16+ API（`onChange` 用新旧两种签名中的旧签名、`ObservableObject` 而非 `@Observable`） | 与 `FavoritesRowMenu.swift` 头部既有约定一致      |
| 工程文件         | 新增 `.swift` 无需改 `project.pbxproj`                                            | 项目用 `PBXFileSystemSynchronizedRootGroup` |

## 五、Verification（验收）

### 5.1 编码自查（提交前）

* `git diff` 逐文件复核：仅动上述 4 个文件（1 新增 + 3 修改），无 `project.pbxproj` 改动、无残留 `.contextMenu`、无死代码。

* 重点复核 `Refresh` 相关：`SearchPageView` 的 `#Preview` 仍可编译（`SearchPageView(searchText: .constant(""))`）。

* 全局 Grep 确认无第二处「热门搜索」实现、`MetaRowMenuKit` 只有行情页与搜索页两个调用方。

### 5.2 构建 + 部署（前台阻塞，禁止后台）

```powershell
python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "fix(search-page): 热门搜索改本地历史 + 搜索页背景不透明 + 结果行长按管理" --files Kline/Home/SearchHistoryStore.swift Kline/Home/SearchPageView.swift Kline/Home/Widgets/HomeSearchModeView.swift Kline/Favorites/FavoritesRowMenu.swift Kline/Market/MarketPageKit.swift
```

退出码按 `.trae/skills/kline-device-validation-loop` 约定处理：`0`/`6` → 交给用户真机验收；`1`（编译失败，读 `build_logs` 修到绿）`2`/`3`/`4`/`7` → 我自行排查续跑。

### 5.3 真机验收清单（交给你在 iPad 上按序验证）

前置：先随便点开过 1\~2 只标的以便有历史，再逐项验；每项都要在**首页四档 + 行情页四档**各走一遍（设置里切布局）。

1. **背景不透明（问题 2）**：行情页四档 → 点放大镜/工具条「搜索」→ 搜索页整页为白（深色模式为深底），**背后行情表不再透出、也不再有触摸穿透**；顶部返回按钮行的上下不再出现约 8pt 透明缝隙。
2. **热门搜索 = 历史（问题 1）**：首次进入显示固定 5 只；点开搜索结果里任一标的 → 返回搜索页 → 该标的出现在「热门搜索」第一位；再点开另一只 → 新标的排第一，旧的退位；反复点开同一只不产生重复项；最多 10 条。
3. **股票类型（4a）**：点「沪深主板」→ 立即列出该类型全部标的（顶部显示「沪深主板 · 共 N 只」），chip 变蓝底白字；点「沪深京指数」「扩展行情指数」各自正确；再点当前 chip → 取消筛选回到热门搜索页。
4. **长按管理（问题 3）**：长按搜索结果行（含类型筛选结果行）→ 弹出居中面板（与行情页长按同款）：加自选 / 加入指定分组 / 备注… / 设置预警；点「加自选」→ 去自选页确认已加入；点「备注…」写内容保存 → 再次长按该行，面板右侧出现备注摘要；无模拟账户时「设置预警」置灰并给出原因。
5. **回归点**：

   * 行情页 / 自选页行长按面板与动作**逐项不变**；

   * 图表页（`KlineDetailView` 副图二 🔍、`LinkedKlineTile` 的搜索栏）下拉搜索行为不变；

   * 首页双击 Tab 打开搜索、行情页搜索入口在所有布局仍可进入且返回后回到原页面。

### 5.4 收尾

* 你确认真机通过后：把本轮决策（热搜历史口径、长按面板共用 Kit、背景铺底规则）沉淀进 `memory/project_memory.md`；按 `版本管理` 规则确保改动全部推送完毕（`build_and_deploy.py` 已含 add/commit/push）。

## Critical Files

| 文件                                            | 动作                                                               |
| --------------------------------------------- | ---------------------------------------------------------------- |
| `Kline/Home/SearchHistoryStore.swift`         | 新增：搜索历史 Store（UserDefaults `kline.searchHistory`）                |
| `Kline/Home/SearchPageView.swift`             | 重写：新增 `SearchPageModel`、类型筛选、结果行长按、热门搜索历史化、背景铺底、空态修正             |
| `Kline/Home/Widgets/HomeSearchModeView.swift` | 编辑：头部 `frame`/`background` 顺序、根 VStack 铺底                        |
| `Kline/Favorites/FavoritesRowMenu.swift`      | 编辑：新增 `MetaRowMenuKit`（无分组上下文行菜单共用逻辑）                            |
| `Kline/Market/MarketPageKit.swift`            | 编辑：`rowMenuItems` / `performRowMenu` 改为调用 `MetaRowMenuKit`（行为不变） |

