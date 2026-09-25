# 布局编辑器（个人中心入口 + 独立全屏页 + 实时预览）Spec

> **三轮规划**：第一轮（节点树结构编辑，已交付待真机验收）见下文全部既有章节；第二轮「控件内容可配置」（快捷入口自由装配 + 四个内容控件数据源选择，2026-09-24 用户确认范围）见「第二轮深化」；**第三轮「节点拖拽装配」（把节点/控件拖入容器，2026-09-24 用户提出）见文末「第三轮深化」**。

## Why（第一轮）

上一变 `add-config-driven-home-layout` 已把首页四档布局变成 JSON 配置驱动（沙盒 `Documents/Layouts/home.json`），但当时**明确把「配置编辑 UI」列为非目标**——要改一个数字，只能用 `KlineHTTPServer` 沙盒直连手改 JSON，或者把文件拷来拷去。手改 JSON 对「调间距、换顺序、试参数」这类高频试错极不友好。

用户诉求：**在个人中心加一个布局编辑器入口和独立的全屏全局页面，能方便地编辑调整；最好还能实时预览。**

本轮范围（用户确认）：
- **完整搭积木**：不只改参数，还要能**新增 / 删除任意节点**（含 `vstack` / `hstack` / `scroll` / `card` / `frame` 等嵌套容器与控件节点），真正自由重组。
- **表单 + JSON 原文双页签**：默认结构化表单（选中、拖动排序、开关、步进器），同时提供 JSON 原文页签可直改文本并给出解析错误提示。
- **页内常驻预览 + 全屏预览两者都要**。
- **手动保存 + 恢复默认**：顶部「保存」写沙盒立即生效；「恢复默认」回退内置默认；未保存时返回要提示。

本轮只覆盖**首页**（唯一已 JSON 化的页面）；自选 / 行情 / 模拟尚未配置化，其编辑器随各自的配置化 spec 一并做。

## What Changes

### 一、把配置模型从「只读镜像」升级为「可编辑模型」

[PageLayoutSchema.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/PageLayout/PageLayoutSchema.swift) 现在的 `PageLayoutNode` 是 `final class` + 全 `let`，只够解码 + 渲染。要搭积木必须可变：

- `PageLayoutNode` 全字段 `let` → `var`；新增 `let uuid: UUID`（**只作编辑期身份**，用于 SwiftUI 列表身份与「当前选中节点」，不参与编解码）。
- 补齐编码能力：`PageLayoutNode` / `PageLayoutDefinition` / `PageLayoutFile` / `PageLayoutPadding` / `PageLayoutWidth` / `WidgetParams` / `WidgetParamValue` 全部实现 `Codable`。
  - `PageLayoutNode.encode(to:)` **只输出与 `type` 相关的字段**（`vstack` 不写 `title`、`widget` 不写 `spacing` 等），保持配置干净可读；
  - `PageLayoutPadding` 只输出非 0 的边（解码侧缺省即 0，往返一致）。
- 新增节点工厂 `PageLayoutNode.make(type:)`：给出每种类型的合理默认值（`scroll` 默认 `axis: vertical` + `padding 16` + `showsIndicators: true`，`frame` 默认 `maxWidth: infinity` + `alignment: top`，`card` 默认 `title: "新卡片"`…）。
- 新增树操作便捷方法：`var containerKey: ContainerKey?`（`.children` / `.child`）、`var childList: [PageLayoutNode]`、`func append(_:)`、`func removeChild(uuid:)`。

### 二、编解码与规范化文本

新增 `Kline/App/PageLayout/PageLayoutCodec.swift`（与页面无关）：
- `decode(_ text: String) -> PageLayoutFile?`
- `encode(_ file: PageLayoutFile) -> String?`：`JSONEncoder` + `.prettyPrinted` + `.sortedKeys`（不转义斜杠），产出即为落盘与 JSON 页签展示用的规范文本
- `canonicalText(_ file: PageLayoutFile) -> String?`

`PageLayoutConfigStore.decode` 改为复用 Codec（消除重复）。

### 三、配置仓库补齐写接口

[PageLayoutConfigStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/PageLayout/PageLayoutConfigStore.swift) 现在只有读路径，新增：

- `@discardableResult func save(_ file: PageLayoutFile, page: String) -> Bool`：编码 → 写沙盒 → 更新内存并发布（同值不写）→ 同步 `lastModDates`，返回是否成功
- `@discardableResult func resetToBuiltIn(page: String) -> Bool`：把已注册的内置默认文本写回沙盒并生效
- `func builtInText(page: String) -> String?`
- `func currentFile(page: String) -> PageLayoutFile?`（编辑器进入时取草稿底本）

现有 `reloadIfChanged` / `layout(id:for:)` / 回退链行为不变。

### 四、首页控件「可编辑参数」描述表

新增 `Kline/Home/Editor/HomeWidgetEditorSchema.swift`：与 [HomeWidgetRegistry.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeWidgetRegistry.swift) 的 7 个控件一一对应，声明每个控件的显示名与可编辑参数（键、标题、类型、默认值、取值范围 / 可选项）：

| 控件 | 可编辑参数 |
|---|---|
| `home.header` / `home.quickEntryRow` / `home.placeholder` | 无 |
| `home.marketOverview` | `compact`（开关） |
| `home.favorites` | `compact`（开关）、`showsSparkline`（开关）、`limit`（步进 0…20，0 = 全部） |
| `home.simSummary` | `compact`（开关） |
| `home.topGainers` | `style`（选项 list / chips）、`compact`（开关） |

### 五、编辑器页面（独立全屏全局页）

新增 `Kline/Home/Editor/` 下：

- **`PageLayoutEditorModel.swift`**（`@MainActor ObservableObject`）：编解码之外的**全部编辑态**——当前档位 id、草稿 `PageLayoutFile`、选中节点 `uuid`、折叠集合、JSON 原文文本、JSON 错误、状态提示、脏标记（`canonicalText(草稿) != 进入时的规范文本`），以及树操作（选中 / 同级移动 / 新增节点 / 新增控件节点 / 删除节点 / 由 JSON 文本应用草稿）与动作（`save()` / `resetToDefault()` / `loadFromStore()`）。
  - 节点的父子定位靠遍历整棵树按 `uuid` 匹配（树规模 < 40 节点，遍历成本可忽略）。
  - 新增规则：选中容器 → 追加到它的容器子节点末尾；选中非容器 → 追加到父容器的该节点之后；未选中 → 追加到根容器的末尾。根节点不是容器时拒绝操作并给提示。
- **`PageLayoutEditorView.swift`**：全屏页面（呈现方式沿用 `FormulaCenterView` 的容器层 overlay 惯例）。结构：
  - 顶部栏：`返回`胶囊（chevron.left + 返回，`gray.opacity(0.12)` 底 + `cornerRadius(8)`）/ 居中标题「布局编辑器」/ 右侧「全屏预览」胶囊 —— 逐项对齐 `FormulaCenterView.header`
  - 档位行：A / B / C / D 分段（编辑哪一档），与首页当前档默认一致
  - 页签行：「表单」/「JSON 原文」+ 右侧「保存」/「恢复默认」胶囊
  - **上半编辑区**（约占一半高）：
    - 表单页签：左 `LayoutNodeTreeList`（宽 320）+ `Divider` + `LayoutNodeInspector`（自适应）
    - JSON 页签：通栏 `TextEditor`（等宽字体 12，`autocorrectionDisabled`），下方一行「由当前树生成」/「应用到树」+ 错误文案
  - **下半预览区**（剩余高度）：`HomeLayoutPreviewPane` 通栏 1:1 渲染（不缩放、只读 `.allowsHitTesting(false)`）
  - 底部状态条：`未保存改动` / `已保存` / `已恢复默认` / JSON 错误
  - `.overlay` 挂 `HomeLayoutFullPreviewView`
- **`LayoutNodeTreeList.swift`**：扁平化的节点树列表（按缩进体现层级、容器可折叠、点击选中），带 `+ 新增` 入口与 `.onMove` 同级拖动排序（跨级拖动忽略并给提示）。
- **`LayoutNodeInspector.swift`**：选中节点的字段表单（按 `node.type` 分支生成对应控件）+ 「添加子节点」（选类型 / 选控件）与「删除本节点」按钮；未选中时显示引导文案。
- **`HomeLayoutPreviewPane.swift`**：页内常驻预览。用 `PageLayoutRenderer` + `HomeWidgetRegistry` + **真实 `HomePageModel` 数据**渲染当前草稿档位；不做缩放（保证宽度即真实宽度、所见即所得）；只读。
- **`HomeLayoutFullPreviewView.swift`**：全屏预览，铺满页面、真实可交互（点行情行仍能打开 K 线详情），顶部标注「预览模式 · 入口与 Tab 切换不生效」并给返回。

### 六、个人中心入口

- [TradingLayoutSettings.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/TradingLayoutSettings.swift) 新增 `LayoutEditorSettingRow { onOpen }`：左「布局编辑器」、右侧蓝色 `首页` + `chevron.right`（字号 12、`frame(minHeight: 36)`，与既有设置行同构），整行可点、命中区 ≥ 44pt。
- [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift)：在「首页布局」行之后、公式管理之前插入该行；新增 `@State showLayoutEditor`；容器层 overlay 挂全屏 `PageLayoutEditorView`（`.transition(.opacity)` + `zIndex(1000)`）；**浮层互斥链由 7 项扩为 8 项**。

### 七、非目标（本轮不做）

- 不自选 / 行情 / 模拟页（尚未 JSON 化）。
- 不做撤销 / 重做、不做多套配置的另存与命名（只有「保存」与「恢复默认」）。
- 不做跨级拖拽（只在同级内重排；跨级请删除后重新添加到目标容器）。
- 不改 `PageLayoutStore` / 个人中心既有五行布局下拉 / 首页渲染与回退逻辑 / 无障碍锚点。
- 不做 figma 原型（编辑器沿用项目既有设置页与全屏页视觉惯例）。

### 八、BREAKING

无。阶段一（模型可变 + 编解码 + 仓库写接口）不改变任何现有行为；编辑器是纯新增 UI。

## Impact

- Affected specs: `add-config-driven-home-layout`（其「不做配置编辑 UI」的非目标由本 spec 取代；引擎与配置/回退契约不变）
- Affected code（修改）：
  - [PageLayoutSchema.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/PageLayout/PageLayoutSchema.swift)（字段可变 + `Codable` + `uuid` + 工厂 + 树操作）
  - [PageLayoutConfigStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/PageLayout/PageLayoutConfigStore.swift)（`save` / `resetToBuiltIn` / `builtInText` / `currentFile`）
  - [TradingLayoutSettings.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/TradingLayoutSettings.swift)（`LayoutEditorSettingRow`）
  - [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift)（一行入口 + 一个全屏 overlay + 互斥链 7→8）
- Affected code（新增，工程文件无需改动 —— Swift 文件走同步组）：
  - `Kline/App/PageLayout/PageLayoutCodec.swift`
  - `Kline/Home/Editor/HomeWidgetEditorSchema.swift`、`PageLayoutEditorModel.swift`、`PageLayoutEditorView.swift`、`LayoutNodeTreeList.swift`、`LayoutNodeInspector.swift`、`HomeLayoutPreviewPane.swift`、`HomeLayoutFullPreviewView.swift`
- 保留不动：[HomeView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeView.swift)（首页仍 JSON 优先 + 硬编码回退）、`PageLayoutRenderer.swift` / `PageWidgetRegistry.swift` / `HomeWidgetRegistry.swift` / `Widgets/` 下 11 个控件 / `PageLayoutStore.swift`
- 无障碍锚点（必须保持）：`home.page` / `home.welcome` / `home.entry.<rawValue>`；UI 测试 `KlineUITests.swift` 的首页判定不受影响
- 已知技术风险：编辑期身份 `uuid` 会使同一棵树「重新解码后」不再相等 —— 因此**脏标记一律用规范化 JSON 文本比较，不用 `Equatable`**（对齐项目既有教训「含 `let id = UUID()` 的类型会击穿 `.equatable()`」）

## 交付分期

- **阶段一（模型 + 编解码 + 写接口）**：Task 1–3。零 UI 变化，四档呈现与回退链不变，独立可编译可真机验收。
- **阶段二（编辑器可用：入口 + 页面 + 改参数/顺序 + 双预览 + 保存）**：Task 4–9。
- **阶段三（搭积木 + JSON 原文）**：Task 10–12。
- **阶段四（真机验收）**：Task 13–14。

## ADDED Requirements

### Requirement: 布局编辑器入口

系统 SHALL 在个人中心提供「布局编辑器」入口，打开独立的全屏编辑器页面。

#### Scenario: 从个人中心进入
- **WHEN** 用户在个人中心点击「布局编辑器」行
- **THEN** 全屏打开布局编辑器页面，默认停在首页当前档位（`PageLayoutStore.homeLayout`）

#### Scenario: 与其他浮层互斥
- **WHEN** 布局编辑器打开
- **THEN** 主题选择 / 五行布局下拉 / 公式管理全部关闭；反向亦然

### Requirement: 结构化编辑节点树

系统 SHALL 允许对当前档位的节点树做参数修改、同级重排、显隐切换与节点增删。

#### Scenario: 修改参数并即时预览
- **WHEN** 在检查器里把选中 `scroll` 节点的 `spacing` 由 12 改为 24
- **THEN** 下半常驻预览立即按新间距重绘，无需保存

#### Scenario: 同级拖动重排
- **WHEN** 在树列表里把「涨幅榜」卡片拖到「大盘概览」之前
- **THEN** 节点顺序改变且预览同步更新

#### Scenario: 新增节点
- **WHEN** 选中一个 `hstack` 容器并选择「添加子节点 → card」
- **THEN** 该容器末尾出现一个新的 `card` 节点（默认标题「新卡片」），可在检查器里继续改标题与子节点

#### Scenario: 新增控件节点
- **WHEN** 选中 `card` 节点并选择「添加子节点 → 控件 → 我的自选」
- **THEN** 该卡片下出现 `widget` 节点（`name = home.favorites`），其参数可在检查器里编辑

#### Scenario: 删除节点
- **WHEN** 选中某节点并点「删除本节点」
- **THEN** 该节点（含其子树）从草稿中移除，预览同步更新

#### Scenario: 跨级拖动被拒
- **WHEN** 试图把节点拖到非同级位置
- **THEN** 顺序不变，并给出「仅支持同级重排」的提示

### Requirement: JSON 原文编辑

系统 SHALL 提供 JSON 原文页签，可直改配置文本并在解析失败时保持草稿不变。

#### Scenario: 应用到树
- **WHEN** 在 JSON 页签里改动文本并点「应用到树」
- **THEN** 文本解析成功则替换当前档位草稿并刷新预览；解析失败则显示错误原因、草稿与预览均不变

#### Scenario: 由当前树生成
- **WHEN** 点「由当前树生成」
- **THEN** 文本被替换为当前草稿的规范化 JSON（与保存到沙盒的文本一致）

### Requirement: 实时预览

系统 SHALL 提供页内常驻只读预览与全屏预览。

#### Scenario: 页内常驻预览
- **WHEN** 编辑器页面处于表单或 JSON 页签
- **THEN** 下半区始终显示当前草稿档位的 1:1 渲染结果，使用真实行情/自选/模拟数据，且不响应点击

#### Scenario: 全屏预览
- **WHEN** 点顶部「全屏预览」
- **THEN** 铺满打开预览页，渲染当前草稿档位并允许真实交互（点行情行可打开 K 线详情）；顶部标注「预览模式 · 入口与 Tab 切换不生效」

### Requirement: 保存与恢复默认

系统 SHALL 支持手动保存到沙盒并立即生效，以及恢复内置默认。

#### Scenario: 保存
- **WHEN** 点「保存」
- **THEN** 整份配置写回 `Documents/Layouts/home.json`，状态条显示「已保存」，返回首页立即为新配置的呈现；未保存改动时返回编辑器会提示

#### Scenario: 恢复默认
- **WHEN** 点「恢复默认」并确认
- **THEN** 沙盒文件被内置默认覆盖，草稿与首页同步回到内置默认呈现

#### Scenario: 脏标记
- **WHEN** 草稿的规范化 JSON 与进入编辑器时的文本不一致
- **THEN** 状态条显示「未保存改动」

### Requirement: 既有行为不回归

系统 SHALL 不改变首页现有渲染、回退与锚点行为。

#### Scenario: 首页渲染路径
- **WHEN** 保存后返回首页
- **THEN** 仍走「JSON 配置优先 → 硬编码 `HomeLayout*View` 回退」的既有路径

#### Scenario: 无障碍锚点
- **WHEN** 运行既有 UI 测试
- **THEN** `app.staticTexts["home.page"]` 仍能命中

## MODIFIED Requirements

### Requirement: 配置仓库职责

`PageLayoutConfigStore` 由「只读 + 首启种入」扩展为「读 + 写」：新增 `save(_:page:)` / `resetToBuiltIn(page:)` / `builtInText(page:)` / `currentFile(page:)`；解码统一走 `PageLayoutCodec`。原有沙盒路径、回退链（沙盒 → 内置默认 → 硬编码视图）、`reloadIfChanged` 与「同值不写」语义均不变。

## REMOVED Requirements

### Requirement: 不做配置编辑 UI

**Reason**: 上一变把「改配置只能走沙盒直连手改 JSON」列为非目标，是当时的范围收敛；用户现已明确提出需要可视化编辑器。
**Migration**: 沙盒直连改 JSON 的方式仍然可用（编辑器就是在同一份文件上读写），两者不冲突。

---

# 第二轮深化：控件内容可配置（快捷入口自由装配 + 内容控件数据源选择）

## Why（第二轮）

第一轮编辑器解决了「布局结构」（节点树增删 / 排序 / 标量参数），但**控件内部展示什么内容**仍然全部写死：

- `home.quickEntryRow` 直接 `ForEach(HomeEntryKind.allCases)` 写死 6 个入口，描述表里「无可编辑参数」——用户不能删、不能换序、不能加入口；
- `home.marketOverview` 指数固定取沪深京指数前 4 只（[HomePageModel.refreshIndexQuotes](file:///Volumes/home/repositories/Kline2/Kline/Home/HomePageModel.swift#L120-L127)）；
- `home.favorites` 固定展示「全部」虚拟分组前 5 只；
- `home.simSummary` 固定全部账户汇总；
- `home.topGainers` 涨幅榜固定只对沪深主板排名。

用户诉求：**控件里展示什么也交由用户配置**，首先是快捷入口行——把 Kline 的无参独立页面作为候选池，由用户自选、排序；并同步把其余内容控件能配的数据源一并开放。

### 用户已确认的范围决策（2026-09-24）

1. **快捷入口候选池**：现有 6 项 + 新增「触发记录」「布局编辑器」共 **8 项**；**不纳入**主题选择、自选/行情/模拟三个底部 Tab（历史上因与底栏重复剔除）、本地更新（需新包全屏导航壳，留待后续）。
2. **配置深度**：仅「选哪些 + 排序」，名称 / 副标题 / 图标 / 颜色由系统统一维护，不做自定义外观。
3. **配置粒度**：A/B/C/D 四档各自独立（参数挂在各档 widget 节点的 `params` 上，与 `home.json` 结构一致）。
4. **同批范围**：快捷入口 + 四个内容控件（大盘概览 / 我的自选 / 模拟汇总 / 涨幅榜）的数据源选择一并完成。

## 独立页面可达性盘点（候选池界定依据）

**纳入候选池（无参数、任意上下文可全屏打开，共 8 项）**：

| id（rawValue） | 名称 | 目标 | 现状 |
|---|---|---|---|
| `search` | 搜索标的 | 首页搜索模式 | 现有 |
| `tech` | 技术指标 | `FormulaCenterView(.tech)` | 现有 |
| `picker` | 选股指标 | `FormulaCenterView(.picker)` | 现有 |
| `strategy` | 交易策略 | `FormulaCenterView(.strategy)` | 现有 |
| `condOrder` | 条件单 | `SimCondListView(accountID: nil)` | 现有 |
| `profile` | 个人中心 | `ProfileDetailView` | 现有 |
| `alertRecords` | 触发记录 | `AlertRecordView(onClose:)` | **新增**（目前仅从条件单页内进入） |
| `layoutEditor` | 布局编辑器 | `PageLayoutEditorView(onClose:)` | **新增**（目前仅从个人中心进入） |

**明确排除（需上下文参数，不适合通用入口）**：K 线详情（需 `MetaItem`）、回测参数/结果与选股运行（需策略/公式 doc）、公式编辑器与条件单编辑/详情（需文档或单据 id）、交易下单（需标的+账户）、表头设置与 K 线设置/指标选择（需行情页或图表上下文）；主题选择为居中弹窗而非独立页、本地更新是个人中心内嵌组件、三个 Tab 页与底栏重复——均不纳入本轮。

## What Changes（第二轮）

### 一、参数引擎扩展：标量 → 支持有序字符串数组 + 动态候选

[PageLayoutSchema.swift](file:///Volumes/home/repositories/Kline2/Kline/App/PageLayout/PageLayoutSchema.swift)：

- `WidgetParamValue` 新增 `case strings([String])`；`init(from:)` **先试 `[String]` 再走既有 Int→Double→Bool→String 标量顺序**（数组与标量互不兼容，先试不影响标量）；错误文案更新为「仅支持 bool / int / double / string / [string]」；`encode(to:)` 输出 JSON 字符串数组；`Equatable` 自动合成继续可用。
- `WidgetParams` 新增 `func strings(_ key: String) -> [String]?`：**返回可选**——缺键 / 类型不符 = nil（回落默认），键存在但为空数组 = `[]`（显式清空，语义不同于缺省）。
- 旧版 App 读含数组的新配置：`WidgetParams.init(from:)` 既有 `try?` 兜底为整表空，不崩溃（quickEntryRow 本就不读标量参数，行为正常）——向前兼容安全。

[HomeWidgetEditorSchema.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/HomeWidgetEditorSchema.swift)：

- `WidgetParamDescriptor.Kind` 新增两种形态：
  - `orderedList(source:maxCount:note:)`：**有序多选**，值 = 候选 id 的有序字符串数组；`maxCount` 非 nil 时编辑器限制选择数量。
  - `dynamicOptions(source:note:)`：**动态单选**，值 = 候选 id 字符串；候选在运行时从数据层解析（区别于既有静态 `.options`）。
- 新增候选源枚举与候选结构：
  - `struct ParamCandidate { let id/title/subtitle/iconName: String? }`（只含字符串/基础类型，不引 SwiftUI；`iconName` 为 SF Symbol 名）
  - `enum WidgetParamCandidates { case entries, indices, favoritesGroups, simAccounts }`
- 新增 `Kline/Home/Editor/WidgetParamCandidateProvider.swift`（`@MainActor`，只依赖既有单例）：
  - `.entries` → 由 `HomeEntryKind.allCases` 映射（id=rawValue，含 icon/subtitle）
  - `.indices` → `DatabaseManager.shared.metaList` 中 `type == "沪深京指数"`（约 119 只；id=`String(meta.id)`、title=名称、subtitle=代码；按名称排序便于长菜单查找）
  - `.favoritesGroups` → 「全部」（`FavoritesStore.allGroupID.uuidString`，固定首项）+ `FavoritesStore.shared.groups`（含公式分组，id/name 现成；隐藏分组也列出——首页是独立展示面）
  - `.simAccounts` → 「全部账户」（`SimStore.allAccountID.uuidString`，固定首项）+ `SimStore.shared.accounts`

### 二、编辑器检查器支持两种新参数形态

- [PageLayoutEditorModel.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/PageLayoutEditorModel.swift) 新增 `setStrings(_:key:)`（写 `.strings`，同值不写）与有序列表编辑动作：`listAppend(key:candidateID:)` / `listRemove(key:candidateID:)` / `listMove(key:from:to:)`（同级重排、去重、maxCount 拦截）；单选复用既有 `setString`。全部走 `touchDraft()` 即时刷新双预览。
- [LayoutNodeInspector.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/LayoutNodeInspector.swift) 新增两类参数行：
  - **`OrderedListParamRow`**：已选区每行 icon+标题+副标题，右侧「上移 / 下移 / 删除」（行高 44、命中区 ≥ 44pt）；底部「+ 添加」`Menu` 只列未选项（候选按标题排序、Menu 自身可滚动，支撑指数 ~119 只场景）；达到 `maxCount` 时菜单禁用并给说明；已选为 0 时显示引导文案（允许空）。
  - **`DynamicOptionsParamRow`**：`Menu` 单选，首项为「默认（全部）」= 缺省（不写键）；其余候选来自 provider；当前选中项实时显示。
- 检查器按需 `@ObservedObject` 观察 `FavoritesStore` / `SimStore`（分组增删、账户增删后候选与合法性即时更新）；`DatabaseManager.metaList` 就绪后指数候选自然出现（检查器出现晚于数据库就绪的概率极低，且仅影响候选列表展示）。

### 三、快捷入口行自由装配

- [HomePageKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomePageKit.swift) 的 `HomeEntryKind` 新增两 case（rawValue 一旦发布即稳定，写进用户 JSON，不可再改）：
  - `alertRecords`：标题「触发记录」/ 副标题「条件单触发与提醒」/ 图标 `clock.arrow.circlepath` / tint `.pink` / `formulaKind = nil`
  - `layoutEditor`：标题「布局编辑器」/ 副标题「自定义首页布局」/ 图标 `square.grid.3x3` / tint `.indigo` / `formulaKind = nil`
- `HomeOverlayTarget` 新增 `case alertRecord` / `case layoutEditor`；`HomeOverlays` 增补两个全屏分支：`AlertRecordView(onClose:)`、`PageLayoutEditorView(onClose:)`（同样 `.transition(.opacity) + .zIndex(1000)`；编辑器内保存会发布配置，关闭后首页已是新配置）。
- [HomeView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeView.swift) 的 `perform(_:)` 增补两个分支（写 `overlayTarget`）；JSON 渲染路径不受影响。
- [HomeQuickEntryRow.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Widgets/HomeQuickEntryRow.swift) 由无参改为接收 `kinds: [HomeEntryKind]`：空数组时渲染 `EmptyView`（零高度，不保留滚动区内边距）。
- [HomeWidgetRegistry.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeWidgetRegistry.swift) 的 `home.quickEntryRow` builder 解析 `p.strings("entries")`：
  - **键缺省 → `HomeEntryKind.allCases`（8 项，旧配置零变化、未来新增入口自动出现）**；
  - 键存在 → rawValue 映射，按数组顺序排列、**去重、过滤未知 id**；
  - 显式 `[]` → 空行。
- [HomeWidgetEditorSchema.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/HomeWidgetEditorSchema.swift) 给 `home.quickEntryRow` 增加一个参数：key `entries`、`.orderedList(source: .entries, maxCount: nil)`。
- 硬编码回退视图 [HomeLayoutBView](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutBView.swift) / [HomeLayoutCView](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutCView.swift) / [HomeLayoutDView](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutDView.swift)：各自 `perform(_:)` 的 switch 因枚举新增 case 必须补全——由 HomeView 注入两个新闭包（`onOpenAlertRecord` / `onOpenLayoutEditor`，接到同一个 `homeOverlays` 目标），回退路径下快捷行仍按 `allCases` 默认呈现；这是对第一轮「保留不动」文件的最小必要改动，回退视图的视觉与行为不变。
- 无障碍锚点新增 `home.entry.alertRecords` / `home.entry.layoutEditor`；既有 6 个锚点保持不变。

### 四、四个内容控件的数据源选择

| 控件 | 新参数键 | 参数形态 | 缺省语义 | 渲染侧取数 |
|---|---|---|---|---|
| `home.marketOverview` | `indices` | `.orderedList(source: .indices, maxCount: 4)` | 缺键/空数组 = 现状（沪深京指数前 4） | 按 id 顺序解析 meta → `rowCache.row(for:prefetch:false)`；按用户选择展示、不补齐；仅当有效 id 为 0 个时整体回落前 4 |
| `home.favorites` | `group` | `.dynamicOptions(source: .favoritesGroups)` | 缺键/非法 id/空串 = 「全部」虚拟分组 | `resolveMetaItems(groupID:)` → 按 `limit` 截断 |
| `home.simSummary` | `account` | `.dynamicOptions(source: .simAccounts)` | 缺键/非法 id/空串 = 全部账户 | `summary(accountID:)`；持仓按 `position.accountID` 过滤 |
| `home.topGainers` | `board` | 既有静态 `.options(["mainBoard","etfIndex"])` | `mainBoard` | 复用行情页 `MarketPageKit` 的类型集口径（主板=`["沪深主板"]`；ETF指数=`["沪深京指数","扩展行情指数"]`）排名 |

- [HomePageModel.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomePageModel.swift) 扩展（保持「body 内不做 O(n) 聚合」原则）：
  - `func indexRows(selectedIDs: [String]?) -> [MarketRow]`：nil/空 → 现有前 4 逻辑；否则按 id 保序解析、过滤失效；既有 `indexQuotes` 快照保留给回退视图用。
  - `func favoriteRows(groupID: String?, limit: Int) -> [MarketRow]`：groupID 解析（全部固定 id / 实体分组 / 非法→全部），`resolveMetaItems` 后触发行预取并按 limit 截断；**limit 缺省口径修正为 0 = 前 5（与现状实际行为一致）**，1…20 生效（描述表 note 由「0 = 全部」改为「0 = 默认前 5」）。
  - `func simSummary(accountIDString:) / simTopPositions(accountIDString:)`：字符串→UUID 解析，非法/缺省回落 `nil`（全部）；持仓在具体账户下按 `accountID` 过滤。
  - `refreshMarketAggregates()` 在现有 250ms 防抖任务内**同时预算两套涨幅榜**（主板 / ETF指数），以类型集合为键缓存；`func topGainers(board: String) -> [MarketRow]` 供注册表读取；**涨跌家数 `breadth` 仍固定沪深主板口径，不开放配置**。
- [HomeWidgetRegistry.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeWidgetRegistry.swift) 四个 builder 改读新参数并调用上述方法；控件视图（`HomeMarketOverviewStrip` / `HomeFavoritesBlock` / `HomeSimSummaryBlock` / `HomeTopGainersBlock`）的 init 签名尽量不变，由注册表完成参数→数据的映射。
- 大盘概览指数格仍为等分 `HStack`，故 **`indices` 候选上限 4**（与现有视觉一致；超过 4 个名称会挤压，需先把指数区改为横滑——列入非目标）。
- 合法性兜底统一原则：**有序入口列表允许空（用户显式清空）；单选/指数类参数遇到空或失效一律回落默认，不展示空白控件、不崩溃**。
- 内置默认 `homeLayoutDefaultsJSON` **不写任何新参数键** → 四档默认呈现与第一轮完全一致；「恢复默认」自然回到默认数据源。

### 五、预览、JSON 页签与测试

- 页内常驻预览与全屏预览共用真实 `HomePageModel`，新参数改动经 `touchDraft()` 立即重绘（指数选择、分组、账户、板块切换所见即所得）；全屏预览维持「预览模式 · 入口与 Tab 切换不生效」标注，入口点击不接线（与第一轮一致）。
- JSON 原文页签原生支持字符串数组：`"entries": ["search","tech"]`、`"indices": ["1","5"]`、`"group": "<uuid>"`；「应用到树」沿用既有解析错误展示与失败不动草稿语义；写坏的 id 不阻断解析（渲染层过滤/回落）。
- UI 测试（KlineUITests，**iPad mini 5 模拟器**，锚点先行）：
  - 新增用例：编辑器中选中「快捷入口行」widget 节点 → 检查器出现有序入口编辑 → 删除一项/上移/添加「触发记录」→ 下半预览 chip 集合与顺序即时变化；保存回首页后 `home.entry.*` 锚点的存在性与顺序一致；恢复默认后 8 项回齐。
  - 新增用例：大盘概览节点检查器指数候选非空（种子库含 119 只沪深京指数），选 2 只后预览指数格为 2；达 4 个后「+ 添加」禁用。
  - 回归：默认配置下首页入口仍为默认 8 项集合的超集行为、`test03` 等既有锚点用例不回归。

### 六、非目标（第二轮不做）

- 不做入口/条目的自定义名称、图标、颜色；不做自定义外链/任意标的入口。
- 不纳入主题选择、三个底部 Tab 页、本地更新；不接入任何需上下文参数的页面。
- 大盘涨跌家数口径不可配；指数区不改横滑、选择上限 4；涨幅榜不增加第三种分类。
- 不改自选 / 行情 / 模拟页自身；不把内容配置能力扩到非首页（随各自页面配置化 spec 再做）。
- 四档不共享配置、不做配置跨档复制。

### 七、BREAKING

无。第二轮为参数模型加 case + 纯增量 UI 与取数分支：所有新参数键缺省即现状；旧沙盒 `home.json` 与未升级用户呈现零变化；旧版 App 读新版配置也仅忽略参数、不崩溃。

## Impact（第二轮）

- Affected specs：本 spec 第一轮章节（编辑器从「结构 + 标量参数」扩到「内容选择」，第一轮的参数描述表与检查器均为增量修改，契约不变）
- 修改：
  - [PageLayoutSchema.swift](file:///Volumes/home/repositories/Kline2/Kline/App/PageLayout/PageLayoutSchema.swift)（`WidgetParamValue.strings` + `WidgetParams.strings(_:)`）
  - [HomeWidgetEditorSchema.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/HomeWidgetEditorSchema.swift)（两种新 Kind + 候选源枚举 + quickEntryRow/四控件参数声明；limit 备注修正）
  - [PageLayoutEditorModel.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/PageLayoutEditorModel.swift)、[LayoutNodeInspector.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/LayoutNodeInspector.swift)（新参数行 + 列表编辑动作）
  - [HomePageKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomePageKit.swift)（+2 入口 case、+2 overlay 目标）
  - [HomeView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeView.swift)（perform 分支 + 给回退视图注入新闭包）
  - [HomeLayoutBView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutBView.swift) / [HomeLayoutCView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutCView.swift) / [HomeLayoutDView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutDView.swift)（switch 补全，最小改动）
  - [HomeQuickEntryRow.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Widgets/HomeQuickEntryRow.swift)（kinds 入参 + 空态）
  - [HomeWidgetRegistry.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeWidgetRegistry.swift)（5 个 builder 参数接线）
  - [HomePageModel.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomePageModel.swift)（按参数取数方法 + 双板块预算）
  - `KlineUITests/KlineUITests.swift`（新增用例）
- 新增（Swift 同步组，无需改 pbxproj）：
  - `Kline/Home/Editor/WidgetParamCandidateProvider.swift`（含 `ParamCandidate` / `WidgetParamCandidates` / 两种新参数行视图可同放 `LayoutNodeInspector.swift` 或单列文件）
- 不改：`PageLayoutCodec` / `PageLayoutConfigStore`（数组随既有 Codable 自动支持）、`PageLayoutRenderer`、内置默认 JSON、`HomeLayoutDefaults`、其余控件视图、行情/自选/模拟页。

## ADDED Requirements（第二轮）

### Requirement: 有序字符串数组参数

系统 SHALL 在控件参数模型中支持有序字符串数组，并在 JSON 中以字符串数组编码。

#### Scenario: 缺省与显式空数组语义不同
- **WHEN** 某参数键不存在
- **THEN** `WidgetParams.strings(_:)` 返回 nil，控件回落默认行为
- **WHEN** 参数键存在且值为 `[]`
- **THEN** 返回空数组（非 nil），控件按「用户显式清空」处理

#### Scenario: 编解码往返
- **WHEN** 对含 `"entries": ["search","tech"]` 的配置做解码再编码
- **THEN** 数组内容与顺序保持不变；标量参数（bool/int/double/string）的既有解码优先级与行为不变

#### Scenario: 旧版兼容
- **WHEN** 旧版本 App 读取含字符串数组参数的配置
- **THEN** 参数表整体回落为空表、不崩溃，控件按无参数（默认）呈现

### Requirement: 快捷入口自由装配

系统 SHALL 允许用户在布局编辑器中为快捷入口行选择入口项集合与顺序，候选池为 8 个无参独立页面。

#### Scenario: 默认入口不变
- **WHEN** 配置中 `home.quickEntryRow` 节点没有 `entries` 参数
- **THEN** 快捷行按 `HomeEntryKind.allCases` 顺序展示全部 8 个入口（搜索标的 / 技术指标 / 选股指标 / 交易策略 / 条件单 / 触发记录 / 个人中心 / 布局编辑器），与升级前布局位置一致

#### Scenario: 增删与排序即时预览
- **WHEN** 用户在检查器中删除「选股指标」、把「条件单」上移到首位并添加「布局编辑器」
- **THEN** 页内常驻预览立即按新集合与顺序重绘；保存后首页快捷行与之完全一致

#### Scenario: 显式清空
- **WHEN** 用户删除全部已选入口并保存
- **THEN** 快捷行零高度不占位；检查器显示引导文案，用户可重新添加

#### Scenario: 新入口可达
- **WHEN** 用户点击「触发记录」入口
- **THEN** 首页以全屏 overlay 打开 `AlertRecordView`，页内返回关闭
- **WHEN** 用户点击「布局编辑器」入口
- **THEN** 全屏打开 `PageLayoutEditorView`，页内返回关闭

#### Scenario: 非法与冗余 id 容错
- **WHEN** 配置中出现未知入口 id、重复 id 或旧版本已移除的 id
- **THEN** 渲染时按顺序去重并过滤未知项，不崩溃、不展示占位残片

### Requirement: 动态候选数据源

系统 SHALL 为有序多选 / 单选参数提供运行时候选源：首页入口、沪深京指数、自选分组（含「全部」）、模拟账户（含「全部账户」）。

#### Scenario: 候选随数据变化
- **WHEN** 用户新增一个自选分组或模拟账户后回到编辑器
- **THEN** 对应控件参数的候选菜单立即包含新项；删除分组 / 账户后候选同步消失

#### Scenario: 已选数据源失效
- **WHEN** 配置指向的自选分组或模拟账户已被删除
- **THEN** 控件回落默认项（「全部」/「全部账户」）渲染，不展示空白、不崩溃

### Requirement: 内容控件数据源可配

系统 SHALL 支持为大盘概览选择指数（有序多选，上限 4）、为我的自选选择分组、为模拟汇总选择账户、为涨幅榜选择市场板块（沪深主板 / ETF指数），缺省均为当前硬编码行为。

#### Scenario: 大盘概览选指数
- **WHEN** 用户把 `indices` 设为两个指定沪深京指数的 id 并保存
- **THEN** 大盘概览指数区仅按配置顺序展示这两个指数，点击仍可打开对应 K 线详情；配置达到 4 项后编辑器禁止继续添加

#### Scenario: 我的自选选分组
- **WHEN** 用户为 `home.favorites` 选择某自选分组
- **THEN** 该卡片只展示该分组的标的（仍受 `limit` 约束，0 = 默认前 5）；空分组展示既有空态

#### Scenario: 模拟汇总选账户
- **WHEN** 用户为 `home.simSummary` 选择某模拟账户
- **THEN** 总资产 / 盈亏与持仓列表均只统计该账户；切回「全部账户」恢复汇总口径

#### Scenario: 涨幅榜选板块
- **WHEN** 用户把 `board` 切为 `etfIndex`
- **THEN** 涨幅榜按「沪深京指数 + 扩展行情指数」合并集排名取前 5；切回 `mainBoard` 恢复沪深主板口径；涨跌家数行始终保持沪深主板口径不变

### Requirement: 第二轮既有行为不回归

系统 SHALL 保持默认配置视觉零变化与既有锚点稳定。

#### Scenario: 默认呈现不变
- **WHEN** 不打开编辑器做任何保存（含旧沙盒配置升级后）
- **THEN** 四档首页的快捷入口（位置与默认集合）、大盘前 4 指数、自选全部前 5、全部账户汇总、主板涨幅榜均与第二轮发布前一致

#### Scenario: 锚点与回退链
- **WHEN** 运行既有 UI 测试与配置回退路径（JSON 不可用 → B/C/D 硬编码视图）
- **THEN** `home.entry.<rawValue>` 既有 6 锚点仍可命中（另新增 2 锚点）；回退视图可编译且入口动作（含两个新目标）可达

## MODIFIED Requirements（第二轮）

### Requirement: 首页控件可编辑参数描述表

第一轮中 `home.quickEntryRow` 为「无参数」；第二轮起其声明 `entries`（orderedList / .entries）。`home.marketOverview` 增加 `indices`（orderedList / .indices / maxCount 4），`home.favorites` 增加 `group`（dynamicOptions / .favoritesGroups）且 `limit` 备注更正为「0 = 默认前 5」，`home.simSummary` 增加 `account`（dynamicOptions / .simAccounts），`home.topGainers` 增加 `board`（静态 options：mainBoard / etfIndex）。`home.header` / `home.placeholder` 仍无参数。

## REMOVED Requirements（第二轮）

无。

---

# 第三轮深化：节点拖拽装配（把节点/控件拖入容器）

## Why（第三轮）

表单页签左侧节点树当前只支持**同级重排**：`List.onMove` → `PageLayoutEditorModel.move(fromOffsets:toOffset:)`（[PageLayoutEditorModel.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/PageLayoutEditorModel.swift#L169-L228)），跨级拖动被**显式拒绝**（banner「已忽略跨级拖动：仅支持同级重排」）。用户要把已有节点/控件搬到另一个容器（例如把某控件拖进「垂直堆栈」）时，只能「先选中目标容器 → 点添加节点」，且只能追加到末尾，无法搬运已有节点。本轮补齐拖拽的**接收方**：容器行成为合法落点。

## 接收方盘点（本轮核心结论）

判定依据是现成的容器语义 [PageLayoutSchema.swift](file:///Volumes/home/repositories/Kline2/Kline/App/PageLayout/PageLayoutSchema.swift#L229-L252) 的 `PageLayoutNode.containerKey`：**凡 `containerKey != nil` 的节点都应接收拖入，叶子一律不接收**。

| type | 中文名 | 子节点承载 | 可作拖拽源 | 接收拖入 | 落点语义 |
|---|---|---|---|---|---|
| `vstack` | 垂直堆栈 | `children[]` | ✅（非根行） | ✅ | 成为该容器最后一个子节点 |
| `hstack` | 水平堆栈 | `children[]` | ✅ | ✅ | 同上 |
| `zstack` | 层叠堆栈 | `children[]` | ✅ | ✅ | 同上（列表顺序 = 层级，后追加者在上） |
| `scroll` | 滚动区 | `children[]` | ✅ | ✅ | 同上 |
| `card` | 卡片 | `child`（单槽） | ✅ | ⚠️ 接收（单槽） | 空槽放入；非空替换原唯一子节点（banner 告知） |
| `frame` | 尺寸框 | `child`（单槽） | ✅ | ⚠️ 接收（单槽） | 同上 |
| `widget` | 控件 | 无 | ✅ | ❌ | 悬停时该行**红色高亮**（区别于可放的蓝色）+ 松手后 banner 说明，草稿不变 |
| `divider` | 分隔线 | 无 | ✅ | ❌ | 同上 |
| `spacer` | 占位 | 无 | ✅ | ❌ | 同上 |
| 根节点 | 四档根均为 `vstack` | 同其 type | ❌ 不可拖 | ✅ | 等价于追加到根末尾 |

补充规则：
- **折叠态容器同样接收**；拖入后自动展开该容器，便于立刻看到结果
- 单槽容器（card/frame）被替换掉的原唯一子节点（含整棵子树）随引用丢弃、无撤销，**必须 banner 明确告知**
- 拖拽源 = 除根节点外的所有行；根节点不可拖（与既有「根节点不可移动」一致）
- 节点树容器由 `List` 改为 `ScrollView + LazyVStack`（见下「实现取舍」）；**一次拖拽内部按落点分区自动判定意图**，不需要先切模式——容器行上/下边缘区 = 同级前插/后插，中间区 = 拖入该容器；叶子行上/下半区 = 前插/后插（详见下「落点分区」）

### 落点分区（2026-09-25 用户要求：拖拽即排序，不再依赖按钮/开关）

用户诉求原话：「我想拖拽时不只是处理容器接不接收，也要支持拖拽排序，现在排序只能点击排序相关按钮」。即**去掉「必须先打开排序开关」这一前置条件**，一次拖拽按落点位置自动判定三种意图：

| 目标行 | 落点位置 | 判定 |
|---|---|---|
| 容器行（`containerKey != nil`） | 上边缘区（`y < 12`） | 同级前插：插到该行**之前** |
| 容器行 | 中间区（`12 ≤ y ≤ 32`） | 拖入该容器（成为其子节点，跨级装配） |
| 容器行 | 下边缘区（`y > 32`） | 同级后插：插到该行**之后** |
| 叶子行（widget/divider/spacer） | 上半区（`y < 22`） | 同级前插 |
| 叶子行 | 下半区（`y ≥ 22`） | 同级后插 |

- 行高 44pt：容器行 12 / 20 / 12，叶子行 22 / 22（叶子没有子槽位，中间无「拖入」语义）
- 同级插入的合法性：目标行必须有父容器（根行没有），且与被拖节点**同父**；否则判 `.crossLevel` 拒绝并给出「跨级移动请拖到容器行中间区，同级排序请拖到同级行上/下边缘」
- 拖到自己所在行 = 无操作（不置脏、不写 banner）
- 悬停反馈三态：前插/后插 = 行顶/行底 **2pt 蓝线**（`insertionLine`）；拖入 = 整行蓝底 + 蓝框；非法 = 整行红底 + 红框（`accent = .red`）

### 实现取舍（相对已批准草案的偏差，2026-09-25 实测后定稿）

`List`（集合视图承载）会**吞掉由它自身行发起的拖拽会话**：`.onDrag` 有回调，但行内 / List 层 / 外层容器三处 `.onDrop` 全部零回调（三轮探针日志 0 命中；改为 `ScrollView + LazyVStack` 后同一次拖拽立刻有 `validateDrop` / `dropUpdated`）。即「保留 `List.onMove`」与「跨级拖入容器」在 iOS 26 不可兼得，用户选定路线 A：

1. 节点树改普通滚动视图，行分隔线自绘 `Divider()`，行高仍固定 44pt
2. 同级重排改由拖拽落点驱动（落点分区，无需开关），不再依赖 `List.onMove`
3. 叶子落点**不**使用系统 `.forbidden`：系统对 `.forbidden` 的落点不交付 `performDrop`，松手时拿不到回调、无法解释「为什么没反应」。故叶子行也报 `.move`（保证松手能进 `performDrop`），悬停时用**红色高亮**兜住「不可放」的视觉，松手后由模型 `moveInto` 统一写 banner
4. 拖拽悬停**不写 banner**（只做行高亮），banner 只在松手后被拒时写——避免拖拽过程中反复刷新视图

## What Changes（第三轮）

### 一、模型层：跨级拖入 API + 同级按兄弟重排 API（PageLayoutEditorModel.swift）
- 新增 `// MARK: - 树操作：跨级拖入`
- `enum DropRejection: Equatable { case targetMissing, notContainer, intoSelfOrDescendant, crossLevel }`（`crossLevel` 为本轮新增，用于「同级前插/后插但源与目标不同父」）
- `static func dropRejectionMessage(_:) -> String` 给出各拒绝原因的可读文案
- `func validateDrop(_ draggingUUID: UUID, into targetUUID: UUID) -> DropRejection?`：目标不存在 → `.targetMissing`；目标 `containerKey == nil` → `.notContainer`；目标落在被拖节点子树内（含自身）→ `.intoSelfOrDescendant`；否则 nil = 可投放
- `func reportDropRejected(_ rejection:)`：把拒绝原因写成 banner（悬停期间不写，仅松手后被拒时写）
- `@discardableResult func moveInto(_ draggingUUID: UUID, container targetUUID: UUID) -> Bool`：
  1. `validateDrop` 不过 → 写 banner + 返回 false（不 `touchDraft`）
  2. 原父 == 目标 且 被拖节点已是目标末尾 → 无操作（banner「该节点已在此容器末尾」，不 `touchDraft`）
  3. 原父 `removeChild(uuid:)` → 目标 `appendChild`：`.child` 非空时 banner「该容器仅容纳一个子节点，已替换」（沿用既有 `insert` 文案）；`.children` 时 banner「已移入：<容器名>」
  4. `collapsed.remove(目标 uuid)`、`select(被拖节点)`、`touchDraft()`
- **硬防护**：`.intoSelfOrDescendant` 必须拦死，否则 `children` 成环，`encode(to:)` 无限递归 → 栈溢出崩溃
- 新增同级按兄弟重排 API（放在既有 `move(fromOffsets:toOffset:)` 之后，**不改它**）：
  - `@discardableResult func move(_ draggingUUID: UUID, beforeSibling targetUUID: UUID) -> Bool`
  - `@discardableResult func move(_ draggingUUID: UUID, afterSibling targetUUID: UUID) -> Bool`
  - 两者转发到私有 `move(_:relativeToSibling:placeAfter:)`：直接在被拖节点的父容器 `childList` 上定位（先 `removeChild` 再按目标的新下标 `insert`），**彻底绕开「扁平行下标」的所有边界问题**——此前用 `targetIndex + 1` 当锚点，在 DFS 先序（容器行的下一行是其第一个子节点）下会把「拖到有子节点的容器行下半区」误判成跨级；改用兄弟定位后该缺陷不存在
  - 同父校验不过 → `reportDropRejected(.crossLevel)`；父容器是 `.child`（单槽）→ banner「该容器仅容纳一个子节点，不支持重排」
- 既有 `move(fromOffsets:toOffset:)` / `moveSelectedUp/Down` / `canMoveSelected` 零改动（检查器仍在用 `move(fromOffsets:toOffset:)`）

### 二、视图层：拖拽手势与落点反馈（LayoutNodeTreeList.swift）
- 工程 `IPHONEOS_DEPLOYMENT_TARGET = 15.0`，`.draggable/.dropDestination`（iOS 16+）不可用 → 用 `.onDrag` + `.onDrop(of:delegate:)`（iOS 13+）
- 列表容器：`ScrollView { LazyVStack(spacing: 0) { ...行 + Divider() } }` + 底部工具条（不用 `List`，理由见上「实现取舍」）
- 行修饰器 `NodeRowDragModifier`：非根行挂 `.onDrag { ... }`（payload = 节点 uuid 串，只需节点身份，不传整棵树；同时把 uuid 写进**不发布变化**的引用对象 `LayoutDragSession.sourceUUID` 供落点判定用——`@State` 写在 `.onDrag` 闭包里会触发重渲染、有打断拖拽会话的风险）；**所有行**（含根行）挂 `.onDrop(of: [.text], delegate:)`
- `NodeDropDelegate: DropDelegate`（非隔离协议 → 代理里不能同步读 `@MainActor` 模型，`rows` 快照 / `session` / `editor` 由修饰器透传）：
  - `validateDrop` = payload 是否为本树 uuid 串（`.text`）
  - `dropEntered/dropUpdated` 调**同一个** `resolution(forY: info.location.y)`（行局部坐标）得到落点解析结果，写进 `dropTargetUUID` + `dropResolution`，返回 `.move`；`dropExited/performDrop` 复位
  - `resolution(forY:)` 返回私有 `enum LayoutDropResolution: Equatable { case into, insertBefore, insertAfter, reject(DropRejection) }`，分区规则见上「落点分区」；同级插入走 `siblingInsertion(_:)`（校验目标行有父且与源同父，否则 `.reject(.crossLevel)`）
  - `performDrop`：先用**同一套** `resolution(forY:)` 复算一次（局部命名 `outcome`，避免与同名方法混淆）→ `loadObject(ofClass: NSString.self)` 取回 uuid 串 → `Task { @MainActor in ... }` 分发：`.into` → `editor.moveInto(uuid, container:)`、`.insertBefore` → `editor.move(uuid, beforeSibling:)`、`.insertAfter` → `editor.move(uuid, afterSibling:)`、`.reject(reason)` → `editor.reportDropRejected(reason)`
- 落点视觉：选中 = `Color.blue.opacity(0.12)`；前插/后插 = 行顶/行底 **2pt 蓝线**（`insertionLine`，`allowsHitTesting(false)`）；拖入 = 底色 `accent.opacity(0.2)` + `RoundedRectangle` 描边 2pt；非法 = 红底 + 红框（`accent = .red`）
- 底部工具条：**已删除原「排序/完成」开关**（拖拽落点分区后不再需要模式切换，锚点 `layoutEditor.sortingToggle` 一并移除）；保留「上移 / 下移」精确重排与「添加节点」/「添加控件」两个 Menu
- 拖拽悬停**不写 banner**（避免刷掉真实提示），仅在松手后被拒时由模型写 banner
- 原生 `onDrag` 需长按约 0.5s 才抬起，正常点击选中与滚动不受影响

### 三、测试（KlineUITests）
- 新增 `test100_Home_EditorDragNodeIntoStack`、`test101_Home_EditorDragInvalidTarget`、`test102_Home_EditorDragReorderSibling`（91/92/93/95/96/97/98/99 已占用）
- 结构断言口径：切「JSON 原文」页签读 `app.textViews.firstMatch.value`，比较 `home.quickEntryRow` 在 prettyPrinted JSON 里的**行缩进空格数**与前后顺序；断言限定在 B 档段内（避免与下半预览/其它档位同名文案混淆）。⚠️ JS​ON 结构每层缩进 2 空格，但节点树的一层深度隔了 `layouts.<档位>.root.children[{}]` 的 4 个结构层，故**节点深度每 +1 = 缩进 +4 空格**（实测：根的直接子节点 12 空格、拖入容器后 16 空格），断言必须按 +4 写
- 拖拽驱动：`XCUICoordinate.press(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)`（**两端都必须是坐标**，`XCUIElement` 版本不接受坐标作目标；必须带 `.slow` + 1.2s 落点保持，否则松手过快系统不交付 `performDrop`，表现为模型零回调）；源码为节点 uuid 串（`NSItemProvider(object:)` → 代理里 `loadObject(ofClass: NSString.self)`）
- 落点统一由 helper 按「行真实 rect + 命名分区」算出屏幕坐标，不再用 `dy` 归一化值：
  - `treeViewport`＝`app.scrollViews["layoutEditor.treeList"]` 的 frame（app 侧新加锚点），即树列表**真实可视区**
  - `treeRowRect`＝「与首个匹配元素同一行（行顶差 < 行高）的元素并集」再按「内容纵向居中于 44pt 行内」补回上下余量。⚠️ 两个已踩的坑：① 标识会传播到行内每个元素，只取 `firstMatch` 时叶子行命中的是**标题**（高 17、位于行内容顶部），只按它居中反推会把行顶算高约 7pt → 上边缘落点落到上一行、被当跨级拒绝、**同级排序静默失败**（test102 实测）；② 同一标识可能匹配多行（默认布局就有两个 `layout.tree.card`），并集必须按行高过滤
  - `TreeDropZone.before/.into/.after` → 行 rect 内代表点（`minY+6` / `midY` / `maxY-6`），与 app 侧 `resolution(forY:)` 分区一一对应
- 可见性判定不能用 `isHittable`：`ScrollView + LazyVStack` 会把**被视口裁掉的行**也报进无障碍树，且这些行 `isHittable` 仍返回 true。若按 `element.frame` 直接算落点，长按会打到视口外的控件上——实测落到工具栏「添加节点」按钮、弹出 Menu 吃掉整个手势（app 侧连 `onDrag` 都没有）。故 `revealTreeRows` 改为「按 `treeViewport` + `isRowFullyVisible`（行 rect 完整落在可视区内，留 2pt 余量）小步慢速滚动（60pt/步，方向按目标行在视口中线的上下决定）」，拖拽前用 `assertTreeRowsVisible` 断言完整可见
- 辅助：`waitTreeJSON` 轮询读 JSON（落库链路异步：`loadObject` → 主线程模型方法）
- test100：默认 → 打开编辑器 → 拖「快捷入口行」控件到「滚动区」行**中间区** → 断言缩进 **+4 空格**（节点深度 +1）且排在 `home.topGainers` 之后 → 保存 → 杀进程重启仍保持 → 恢复默认
- test101：①「滚动区」→ 其子孙「卡片」行中间区 → banner「不能把节点拖入它自己或它的子节点」且结构不变（`layout.tree.widget.home.marketOverview` 仍存在）；② 跨级插入：「大盘概览」控件行中心 → **上一行**「大盘概览卡片」行**上边缘区**（两者相邻保证同视口可点）→ 前插意图但不同父 → banner「跨级移动请拖到容器行中间区，同级排序请拖到同级行上/下边缘」且结构不变
- test102：拖「快捷入口行」到 `home.header` 行的**上边缘区** → 断言缩进不变（`jsonIndent` 相同）、顺序变为排在 `home.header` 之前 → 保存 → 杀进程重启仍保持 → 恢复默认
- 实跑结果（iPad mini 5 模拟器，2026-09-25）：test100/101/102 全通过（84.5s / 92.8s / 75.6s）；回归 test96/97/98/99 通过（25.4s / 23.8s / 73.8s / 108.6s）
- 回归：`test91/92/93/95/96/97` 必须复跑通过（test91 依赖 ETF 种子库二级菜单、test92 依赖刘海机型横向安全区，在 iPad mini 5 上属既有环境性失败，与本轮改动无关）
- 首页入口 helper 加固：`scrollHomeEntryIntoView` 原来只判 chip 是否横向在屏内就用它的 midY 做横滑 y——布局被改动后入口行可能被纵向滚出视口（如拖到滚动区末尾后 y≈776 > 屏高），算出的滑动 y 落到屏幕外使横滑手势完全无效，chip 永远滚不进来（曾致 test100/101/102 连环卡在「打开编辑器」前置）。现在先按「行 frame 与安全带（上避状态栏 30 / 下避底部菜单栏 30）的交集 ≥ 16pt」判定行是否在视口内，不在则先纵向滚动把它带进来（按行在屏中线上下决定上滑/下滑），再用交集中点作为横滑 y

### 四、非目标（第三轮不做）
- 预览区拖拽（预览 `allowsHitTesting(false)`）、从「添加节点/添加控件」菜单拖入（调色板拖拽）
- 撤销/重做；跨档位、跨页面拖拽；自定义拖拽浮层预览（用系统的）
- 系统 `.forbidden` 落点光标（改为红色高亮，理由见上「实现取舍」）、拖拽自动滚动（拖到滚动区边缘不自动滚屏）

### 五、BREAKING
无。`.onDrag/.onDrop` 是新增手势；默认布局、配置结构、JSON 格式、既有无障碍锚点均不变。

**交互/外观差异（非 BREAKING，需知悉）**：
1. 节点树去掉 `List` 后行分隔线为自绘，行内边距与滚动位置与之前略有差异
2. **底部工具条的「排序/完成」开关已删除**——拖拽落点分区后不再需要在两个模式间切换；同级重排仍可用「上移 / 下移」按钮做精确调整
3. 悬停反馈新增「前插/后插蓝线」形态（原只有蓝底描边）

## Impact（第三轮）
- Affected specs：布局编辑器（第一轮「结构化编辑节点树」Requirement 的能力扩展）
- Affected code：[PageLayoutEditorModel.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/PageLayoutEditorModel.swift)（+跨级拖入 API `moveInto/validateDrop/reportDropRejected` 与同级按兄弟重排 `move(beforeSibling:)/move(afterSibling:)`、`DropRejection.crossLevel`）、[LayoutNodeTreeList.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/LayoutNodeTreeList.swift)（+onDrag/onDrop/DropDelegate/落点三分区/三态反馈，-「排序」开关）、`KlineUITests/KlineUITests.swift`（+3 用例：test100/101/102）；`PageLayoutSchema.swift` 与 `HomeLayoutDefaults.swift` 零改动

## ADDED Requirements（第三轮）

### Requirement: 拖拽节点/控件到容器

系统 SHALL 允许在表单页签的节点树中把任意非根节点拖到「容器行」上，使其成为该容器的子节点；拖到非容器行则拒绝且不改变草稿。

#### Scenario: 拖入数组容器
- **WHEN** 用户长按拖动某控件行，松手在「垂直堆栈」行的**中间区**
- **THEN** 该控件成为该堆栈最后一个子节点，树缩进层级 +1、预览即时刷新、草稿置脏；保存后 JSON 结构正确（目标容器 `children` 末尾含该节点，原父不再含）

#### Scenario: 拖入单槽容器
- **WHEN** 用户把某节点拖到「卡片」行的中间区，而卡片已有子节点
- **THEN** 该节点成为卡片唯一子节点、原子节点被替换，状态栏提示「该容器仅容纳一个子节点，已替换」

#### Scenario: 拖入折叠容器
- **WHEN** 用户把节点拖到已折叠的容器行中间区
- **THEN** 拖入成功且该容器自动展开，用户可立即看到结果

#### Scenario: 悬停落点分区反馈
- **WHEN** 拖拽悬停在容器行的上边缘区 / 中间区 / 下边缘区
- **THEN** 分别显示：行顶 2pt 蓝线（前插）/ 整行蓝底 + 蓝框（拖入）/ 行底 2pt 蓝线（后插）
- **WHEN** 拖拽悬停在叶子行的上半区 / 下半区
- **THEN** 分别显示行顶 / 行底 2pt 蓝线

#### Scenario: 非法落点（自身或后代）
- **WHEN** 用户把一个容器拖到它自己的子孙容器行**中间区**
- **THEN** 拖拽中该行显示**红底红框**，松手后被拒绝并给出说明，节点树与草稿保持不变（禁止成环）

#### Scenario: 非法落点（跨级前插/后插）
- **WHEN** 用户把某节点拖到**不同父**的某行上/下边缘区（例如拖到上一级容器行的下边缘区）
- **THEN** 拖拽中该行显示**红底红框**，松手后状态栏提示「跨级移动请拖到容器行中间区，同级排序请拖到同级行上/下边缘」，节点树与草稿保持不变

#### Scenario: 拖回原处与取消
- **WHEN** 用户把某节点拖到它当前父容器行上、且它已是该容器最后一个子节点
- **THEN** 视为无操作：草稿不变、不置脏
- **WHEN** 拖拽中途取消（松手在树外 / 空白区）
- **THEN** 落点高亮消失、拖拽状态完全复位

#### Scenario: 持久化
- **WHEN** 拖入后保存并杀进程重启
- **THEN** 新的父子关系与顺序保持不变

#### Scenario: 同级重排（拖拽落点，无需开关）
- **WHEN** 用户把某节点拖到同级某行的**上边缘区 / 上半区**（容器行 y<12）或**下边缘区 / 下半区**（容器行 y>32）
- **THEN** 该节点插到目标行**之前** / **之后**，缩进层级不变，顺序即时更新、草稿置脏；无需事先打开任何排序开关
- **WHEN** 用户使用上移 / 下移按钮
- **THEN** 与某个同级兄弟交换位置，行为与本轮之前完全一致

## MODIFIED Requirements（第三轮）

### Requirement: 结构化编辑节点树

第一轮能力为「增 / 删 / 改 / 同级重排 + 折叠 + 选中」；第三轮起增加**跨级拖入容器**（`onDrag` + `onDrop`，接收方 = `containerKey != nil` 的 6 种容器 + 根节点）。节点树容器由 `List` 改为 `ScrollView + LazyVStack`（`List` 会吞掉自身行发起的拖拽会话），故同级重排也改由**一次拖拽内的落点分区**驱动（容器行 上边缘 12 / 中 20 / 下边缘 12，叶子行上/下半区 22/22），模型侧新增按兄弟定位的 `move(beforeSibling:)/move(afterSibling:)`（不再吃扁平行下标，规避 DFS 先序边界缺陷）；其限制（`.child` 单槽容器不可重排、不同父的插入判 `.crossLevel` 拒绝）保持不变；底部工具条的「排序/完成」开关**已删除**，上移/下移按钮保留。行高 44pt、点击选中、折叠展开、无障碍锚点（`layout.tree.<type>` / `layout.tree.widget.<name>`）全部保持。

## REMOVED Requirements（第三轮）

无。

---

## Why（第四轮，2026-09-25）

用户原话：**「让布局编辑器全屏吧，它现在还显示了底部导航栏，然后把布局编辑器的预览去掉，只需要留下全局预览功能，4个布局方案的切换按钮也尽量跟标题栏整合为一行，让布局编辑器真正的内容可以显示的更多」**

三个问题，三条改动理由：
1. **底部导航栏还在**：编辑器此前由首页用 `HomeOverlays(target: .layoutEditor)` 在**首页视图内部**呈现，而首页在 `ContentView` 的 VStack 里只占底栏以上区域 —— 页面内 overlay 结构上不可能盖住底栏。
2. **页内常驻预览吃掉了下半屏**：本轮起预览只在全屏预览页看，页内预览整块删除（`HomeLayoutPreviewPane.swift` 文件删除）。
3. **四档切换独占一行**：并入标题行，省下一整行高度。

## What Changes（第四轮）

### 一、全屏呈现：编辑器提到 `ContentView` 根层（PageLayoutEditorView.swift / ContentView.swift / HomeView.swift / HomePageKit.swift）

- 新增 `HomeLayoutEditorRouter`（`ObservableObject` 单例，`@Published var isPresented`），与 K线详情页的 `DetailRouter` 同做法，定义在 `PageLayoutEditorView.swift`。
- `ContentView` 根 ZStack 里新增一支「若 `isPresented` 则全屏呈现 `PageLayoutEditorView`」（并列于 K线详情页之后），根层 ZStack 铺满整屏 → 自然盖住底部导航栏。
- `HomeView.onOpenLayoutEditor()` 由「置 `overlayTarget = .layoutEditor`」改为「置位 router」；`HomeOverlayTarget` 的 `.layoutEditor` 分支（case / id / HomeOverlays switch 臂）整体删除（无引用，避免死代码）。
- 个人中心入口（`ProfileDetailView`）**不改**：`ProfileDetailView` 本身已是根层全屏覆盖层，其内部呈现的编辑器本来就铺满整屏（含底栏），无需改动。

### 二、去掉页内常驻预览

- `PageLayoutEditorView.body` 移除 `HomeLayoutPreviewPane(...)` 与其上下两条分隔线；`editArea` 占满除标题行 / 页签行 / 状态条外的全部高度。
- 删除文件 `Kline/Home/Editor/HomeLayoutPreviewPane.swift`（工程用 `PBXFileSystemSynchronizedRootGroup`，删文件即从 target 移除，无需改 pbxproj）。
- 「全屏预览」胶囊按钮保留并加锚点 `layoutEditor.fullPreview`；`previewModel`（真实 `HomePageModel`）保留，仅供全屏预览使用。
- `PageLayoutEditorModel.styleTitle` 随之无引用，删除（档位说明改由分段控件自身表达）。

### 三、四档切换并入标题行

- 原「档位行」（分段 A/B/C/D + `styleTitle` 文本，独占一行约 44pt）删除，分段控件移入 `header`。
- `header` 由「返回 / ←Spacer→ 标题 ←Spacer→ 全屏预览」改为单行「返回 / 标题 / 分段 A|B|C|D / ←Spacer→ 全屏预览」，左右内边距 16、上下 8。
- 新增锚点 `layoutEditor.stylePicker`。

### 四、非目标（第四轮不做）

- 不改编辑器内部编辑能力（树 / 检查器 / JSON 页签 / 拖拽）；
- 不做可拖拽分栏宽度、不做预览与编辑并排；
- 不动个人中心入口的呈现方式。

### 五、BREAKING

无。锚点 `layoutEditor.back/title/save/resetDefault/treeList` 全部保留（测试 98/99/100/101/102 实跑通过）。

## MODIFIED Requirements（第四轮）

### Requirement: 实时预览

预览**只有全屏预览一种**：页内常驻预览已删除（`HomeLayoutPreviewPane.swift` 移除）。编辑器页面本身不再占用纵向空间做预览，编辑区独占剩余高度；草稿改动仍经 `touchDraft()` 即时反映到全屏预览页。

#### Scenario: 全屏预览
- **WHEN** 点顶部「全屏预览」（锚点 `layoutEditor.fullPreview`）
- **THEN** 铺满打开预览页，渲染当前草稿档位并允许真实交互（点行情行可打开 K 线详情）；顶部标注「预览模式 · 入口与 Tab 切换不生效」

### Requirement: 布局编辑器入口

编辑器是**全屏页面**：由 `HomeLayoutEditorRouter.shared.isPresented` 触发、在 `ContentView` 根 ZStack 呈现，铺满整屏**含底部导航栏**；关闭走页内「返回」（有未保存改动先弹确认）。

#### Scenario: 从首页入口打开
- **WHEN** 点首页快捷入口「布局编辑」（锚点 `home.entry.layoutEditor`）或个人中心「布局编辑」行
- **THEN** 全屏打开编辑器，底部导航栏被完全盖住（不可见、不可点），页面自带「返回」

## REMOVED Requirements（第四轮）

### Requirement: 页内常驻预览

原「编辑器下半常驻只读预览（`HomeLayoutPreviewPane`，1:1 不缩放、`allowsHitTesting(false)`）」**删除**：预览统一走全屏预览页。

---

## 附录 A：ProfileView（「测试页面」）控件 / 容器盘点（第五轮前置侦察，2026-09-25）

用户原话：**「请你详细梳理 `/Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift` 中的所有控件和容器，给 `/Volumes/home/repositories/Kline2/.trae/specs/add-layout-editor` 做补充」**

本轮**只做盘点，不改任何代码**。用途：为「将来把布局编辑器从首页扩展到本页」界定候选池与列出缺口，格式对齐第二轮「独立页面可达性盘点（候选池界定依据）」。

> ⚠️ **方向修订（2026-09-25，见第五轮）**：用户核对本附录后明确 —— **不**把 ProfileView 做成可编辑页；本附录的产出改为「**控件/容器词表缺口清单**」，用于把测试页面有、编辑器没有的类型抽成**页面无关的通用控件**补进编辑器（当前仍只编辑首页）。概念、层级、控件与数据那张四节仍然是准确的事实记录；第五、六节的「page 化 / profile.json / 本页锚点」**不再实施**。

盘点范围包含本页直接引用的三个组件文件 [HorizontalScrollCard.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/HorizontalScrollCard.swift)、[ListCard.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/ListCard.swift)、[DetailPage.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/DetailPage.swift) 与数据源 [MockData.swift](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift)。

### 一、页面定位与呈现层级（与首页的关键差异）

| 项 | ProfileView 事实 | 与首页（`HomeView`）对比 |
|---|---|---|
| 入口 | `ContentView.handleTabTap`：**已在模拟页时再点一次底部「模拟」（index 3）** → `isTestPresented = true`（[ContentView.swift](file:///Volumes/home/repositories/Kline2/Kline/App/ContentView.swift#L223-L230)）。无工具栏入口、无公式/条件单类入口 | 首页是默认 Tab，另有 8 项快捷入口 |
| 呈现层 | `ContentView` 主体 ZStack 的 `.overlay`（[ContentView.swift](file:///Volumes/home/repositories/Kline2/Kline/App/ContentView.swift#L110-L122)）——**在根 ZStack 之外**，故铺满整屏**含底部导航栏** | 首页在 VStack 内只占底栏以上区域；第四轮编辑器为盖住底栏专门提到根层 router |
| 页面壳 | `VStack(spacing:0){ 导航栏; Divider; 主内容 }` + 背景 `ignoresSafeArea()` + `ignoresSafeArea(.container, edges:.bottom)`（[ProfileView.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L136-L138)） | 壳形态一致（同款贴底三件套），可直接复用「页面壳 → 容器 → widget」渲染思路 |
| 数据来源 | 全部是 `MockData.swift` 的**编译期全局常量**（7 个），无 ViewModel、无网络/DB | 首页由 `HomePageModel` 驱动，运行期真数据 |
| 无障碍锚点 | **本页与三个组件文件均无任何 `accessibilityIdentifier`**（已全目录 grep 确认） | 首页有 `home.entry.*`、`home.card.*` 等；本页扩展为可编辑页前必须先补锚点 |
| 状态 | 两个 `@State`：`selectedItemTitle: String?`、`isDetailPresented`（[ProfileView.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L13-L14)），仅服务于卡片项点击 → 二级页 | 首页状态在 `HomePageModel` + `ChartConfigStore` 等 |

### 二、容器清单（对照节点词表 `vstack/hstack/zstack/scroll/card/frame`）

节点类型白名单与容器语义见 [PageLayoutSchema.swift](file:///Volumes/home/repositories/Kline2/Kline/App/PageLayout/PageLayoutSchema.swift#L75-L75)（9 种 type）与 [containerKey](file:///Volumes/home/repositories/Kline2/Kline/App/PageLayout/PageLayoutSchema.swift#L237-L240)（`vstack/hstack/zstack/scroll → .children`，`card/frame → .child`）。

| # | 容器 | 对映节点类型 | 位置 | 关键参数 |
|---|---|---|---|---|
| 1 | 根 `VStack(spacing: 0)` | `vstack` | [L17](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L17-L17) | spacing 0；3 个子节点（导航栏 / Divider / 主内容） |
| 2 | 顶部导航栏 `HStack` | `hstack` | [L19-L35](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L19-L38) | 默认 spacing 8；`.frame(height: 56)` + `.padding(.top, -5)` + 白底 |
| 3 | 主内容 `VStack(spacing: 16)` | `vstack` | [L44-L134](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L44-L134) | spacing 16、`.padding(16)`；2 个子节点（顶部固定卡片 / 左右分栏） |
| 4 | 左右分栏 `HStack(spacing: 16)` | `hstack` | [L52-L132](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L52-L132) | spacing 16；2 个子节点（两个纵向滚动区） |
| 5 | 左列 `ScrollView(.vertical, showsIndicators: false)` | `scroll` | [L54-L88](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L54-L88) | axis=vertical；`.frame(maxWidth: .infinity)` 等分宽度 |
| 6 | 左列内 `VStack(spacing: 16)` | `vstack` | [L55-L86](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L55-L86) | spacing 16、`.padding(.trailing, 8)`；5 个子节点 |
| 7 | 右列 `ScrollView(.vertical, showsIndicators: false)` | `scroll` | [L91-L131](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L91-L131) | 同上，`.frame(maxWidth: .infinity)` |
| 8 | 右列内 `VStack(spacing: 16)` | `vstack` | [L92-L129](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L92-L129) | spacing 16、`.padding(.leading, 8)`；6 个子节点 |

补充事实：

- **未使用** `zstack` / `card` / `frame` 三种节点类型；宽度等分靠修饰符 `.frame(maxWidth: .infinity)` 而非 `frame` 容器节点（节点词表的 `frame` 支持 `maxWidth/minHeight/alignment`，理论上可表达式化）。
- `scroll` 词表已支持 `axis / spacing / padding / showsIndicators`（见 [make(type:)](file:///Volumes/home/repositories/Kline2/Kline/App/PageLayout/PageLayoutSchema.swift#L202-L208)），**左右分栏整体可用节点树表达**：`vstack(16)[ card, hstack(16)[ scroll(vertical, padding.trailing=8)[vstack(16)[…]], scroll(vertical, padding.leading=8)[vstack(16)[…]] ] ]`。
- 两列**各自独立纵向滚动**（同屏两组滚动视图），这是本页与首页（单层 `scroll`）最显著的结构差异。

### 三、控件清单（叶子与复合卡片）

#### 3.1 本页直接书写的叶子控件

| 控件 | 位置 | 样式要点 | 可交互 |
|---|---|---|---|
| 返回 `Button` | [L21-L27](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L21-L27) | `Image(systemName: "chevron.left")` 24pt + `.padding(.leading, 16)` | 置 `isPresented = false` |
| 标题 `Text("测试页面")` | [L30-L32](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L30-L32) | `.font(.title)` + `.bold`；因前有返回钮、后有 `Spacer()` 而**左对齐**（非居中，与编辑器标题栏风格不同） | 否 |
| `Spacer()` | [L34](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L34-L34) | 撑开标题行 | 否 |
| `Divider()` | [L41](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L41-L41) | 导航栏与内容分隔 | 否 |
| 占位 `Rectangle` ×3 | [L81-L84](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L81-L84) / [L118-L121](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L118-L121) / [L124-L127](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L124-L127) | `fill(systemGray5/4)`、高 150 / 200 / 180、`.cornerRadius(12)` | 否（纯撑高占位，注释即「额外的占位卡片」） |

#### 3.2 复合卡片：`HorizontalScrollCard`（横滑卡，本页 6 个实例）

组件 [HorizontalScrollCard.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/HorizontalScrollCard.swift#L11-L53)：

- 外框：`VStack(alignment:.leading, spacing:12)` → `.padding(16)` → `.background(systemBackground)` → `.cornerRadius(12)` → `.shadow(black 0.05, radius 4, y 2)`
- 标题栏 `HStack`：`Text(data.title)`（`.headline` + `.bold`）+ `Spacer()` + **二选一**：`updateTime` 非空 → `Text(time)`（`.subheadline`、灰）；否则 `showMore == true` → `Image("chevron.right")` 16pt 灰
- 主体：`ScrollView(.horizontal, showsIndicators:false)` + `HStack(spacing:16)` + `ForEach(items){ Button { onItemTap?(item.title) } label: { HorizontalCardItemView(item:) } }` → **每个 item 都是一个 Button（可点）**

条目视图 [HorizontalCardItemView](file:///Volumes/home/repositories/Kline2/Kline/Profile/HorizontalScrollCard.swift#L56-L87) 有**两支**，由 `item.icon` 是否为 nil 决定：

| 分支 | 结构 | 关键样式 |
|---|---|---|
| 图标型（`icon != nil`） | `VStack(spacing:8){ Image(systemName: icon); Text(title) }` | 图标 `showBackground ? 28 : 24` pt、色 = `item.color`、`showBackground` 时 `frame(56×56)` + `systemGray5` 底 + `cornerRadius(12)`；文字 12pt |
| 文字型（`icon == nil`，仅行业数据） | `VStack(spacing:8){ Text(title); Text(subtitle) }` | 标题 14pt；副标题 13pt、色 = `item.color`（涨红跌绿由构造函数决定）；`padding(12,20,12,20)` + `systemGray5` 底 + `cornerRadius(8)` |

#### 3.3 复合卡片：`ListCard`（列表卡，本页 3 个实例）

组件 [ListCard.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/ListCard.swift#L11-L76)：

- 外框与 `HorizontalScrollCard` 完全一致（padding 16 / radius 12 / shadow 同参）
- 标题栏 `HStack`：`Text(data.title)`（`.headline` + `.bold`）+ `Spacer()` + **二选一**：`updateTime` → 灰 `.subheadline` 文本；否则 `showMore == true` → `Text("更多")`（灰 `.subheadline`，与横滑卡的 `chevron.right` **不同**）
- 主体：`VStack(spacing:12)` + `ForEach(items){ Button { onItemTap?(item.title) } label: { HStack(spacing:12){ … } } }`，行内四段（后两段可选）：
  1. `rank` 非空 → `Text(String(rank))` 14pt bold、`rank <= 3 ? .red : .gray`、`frame(width:24, alignment:.center)`
  2. `Text(title)` 14pt + `.lineLimit(1)`
  3. `Spacer()`
  4. `badge` 非空 → `Text(badge)` 12pt 白字 + `padding(2,6,2,6)` + `background(item.badgeColor)` + `cornerRadius(4)`
- 注：`ListCardItem.subtitle` 字段存在但**本组件未渲染**（[MockData.swift](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift#L64-L80) 定义，`ListCard` 未使用）——扩展为 widget 参数时不要把它当已支持项。

#### 3.4 二级页：`DetailPage`（overlay，非本页内容）

由卡片项点击触发：`selectedItemTitle = title; isDetailPresented = true` → `.overlay { if isDetailPresented, let title = selectedItemTitle { DetailPage(isPresented: $isDetailPresented, title: title).transition(.opacity) } }`（[ProfileView.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L139-L146)）

[DetailPage.swift](file:///Volumes/home/repositories/Kline2/Kline/Profile/DetailPage.swift#L10-L58) 结构：`VStack(spacing:0){ 导航栏 HStack(返回 chevron.left 24pt + `padding(.leading,16)` + `Text(title)` `.title` bold + Spacer，`frame(height:56)` + `padding(.top,-5)` + 白底); Divider(); 内容 VStack(spacing:24){ Image("info.circle") 64pt blue; Text(title) `.title` bold; Text("这是「\(title)」的详情页面。…") `.body` 灰、居中、`padding(.horizontal,32)` }.frame(maxHeight:.infinity) }`。

- 其导航栏与 `ProfileView` 顶部导航栏是**逐参重复的同一形态**（56pt / `-5` top / chevron 24pt / `.title` bold），仅缺 `accessibilityIdentifier`。
- **9 个卡片实例的点击全部汇聚到这一个 `DetailPage`**，差异只在传入的 `title`。

### 四、数据来源与复用关系（用于候选池去重）

全部取自 [MockData.swift](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift) 的全局 `let` 常量，**7 个常量被 9 个卡片实例使用，其中 2 个被复用两次**：

| 常量 | 结构 | 标题 | items 数 | 条目形态 | 使用位置 | 次数 |
|---|---|---|---|---|---|---|
| `industryData` | `HorizontalCardData` | 热门行业 | 6 | 文字型（含涨跌幅 `subtitle`） | [L46](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L46-L49) 顶部固定 | 1 |
| `appRecommendData` | `HorizontalCardData` | 应用推荐 | 8 | 图标型 | [L57](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L57-L60) 左、[L112](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L112-L115) 右 | **2** |
| `hotNewsData` | `ListCardData` | 今日热点 | 5 | rank + badge，`updateTime` 有值 | [L63](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L63-L66) 左 | 1 |
| `leftExtraData` | `HorizontalCardData` | 市场动态 | 6 | 图标型，`updateTime` = 刚刚更新 | [L69](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L69-L72) 左 | 1 |
| `moreHotNewsData` | `ListCardData` | 财经要闻 | 8 | rank + badge | [L75](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L75-L78) 左、[L106](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L106-L109) 右 | **2** |
| `dataCenterData` | `HorizontalCardData` | 数据中心 | 4 | 图标型（`showBackground: false`） | [L94](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L94-L97) 右 | 1 |
| `rightExtraData` | `HorizontalCardData` | 工具中心 | 5 | 图标型 | [L100](file:///Volumes/home/repositories/Kline2/Kline/Profile/ProfileView.swift#L100-L103) 右 | 1 |

- 结构体定义：[HorizontalCardItem](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift#L11-L36)（两个便捷构造：图标型 / 文字型，文字型 `isUp` 决定红绿）、[HorizontalCardData](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift#L39-L44)、[ListCardItem](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift#L64-L80)、[ListCardData](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift#L83-L88)。
- 两个 `HorizontalCardItem`/`ListCardItem` 都含 `let id = UUID()`（[L12](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift#L12-L12)、[L65](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift#L65-L65)）——**每次构造 id 都不同**，若将来把这套数据接进节点树/缓存，需按业务字段比较，避免 UUID 击穿（与 `KlineItem` 同类坑）。
- 左右两栏复用同一常量，**证明节点树无需去重**：同一 widget 可在同一棵树里出现多次。

### 五、可编辑候选界定（若把布局编辑器扩展到本页）

**可直接映射为现有节点词的**：

| 现状控件 | 建议节点表达 | 可编辑参数（建议） |
|---|---|---|
| 两个纵向 `ScrollView` + 内部 `VStack` | `scroll(vertical)` + `vstack(spacing:16)` | 已支持：`axis / spacing / padding / showsIndicators` |
| 左右分栏 `HStack` | `hstack(spacing:16)` | 已支持：`spacing / alignment`；宽度等分由 `frame(maxWidth:.infinity)` 承载 |
| `Divider()` | `divider` 叶子 | 已支持（无参数） |
| 三个占位 `Rectangle` | 建议**不进节点树**；若要进树需 `spacer`（但 `spacer` 词表**无高度参数**，150/200/180 硬编码无法表达 → 需扩参或新增占位 widget） | — |

**建议新增为本页专属 widget 的（需注册进 `HomeWidgetRegistry` 同类注册表）**：

1. `profile.hscrollCard`（横滑卡）：参数 = **数据源 id（7 选 1）**、`showMore` 覆盖、`updateTime` 覆盖；渲染即 `HorizontalScrollCard`
2. `profile.listCard`（列表卡）：参数 = 数据源 id（仅 `hotNewsData` / `moreHotNewsData` 两个 `ListCardData` 常量）

**明确不适合进节点树的**：

- 顶部导航栏（返回 + 标题）——页面固定壳，与首页一样由页面自身维护（首页 `home.header` 走 widget 是个例外，本页标题是硬编码「测试页面」）
- 左右分栏本身作为「整块布局」时可进树（见上表），但**卡片内 padding（16）/ 卡间距（16）/ 列 padding（trailing|leading 8）目前是硬编码**，节点词表的 `scroll.padding` 只能表达滚动区边距，卡片内外边距若要可编辑需扩参
- `DetailPage` overlay —— 点击卡片项触发的二级页，属跳转目标而非页面内容，与首页 K线详情页同类，不进树

### 六、扩展到本页必须先补的缺口（本轮不动，仅登记）

| # | 缺口 | 位置 / 证据 |
|---|---|---|
| 1 | 编辑器的页面键**硬编码 `"home"`** | `PageLayoutEditorModel.page = "home"`（[PageLayoutEditorModel.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/Editor/PageLayoutEditorModel.swift#L36-L36)）→ 需改为可切换/带参数 |
| 2 | 配置仓库只有 `home.json`，无 page → 文件名映射 | `PageLayoutConfigStore.save(_:page:)` / `resetToBuiltIn(page:)` / `builtInText(page:)` 已带 page 形参，但内置默认文本与沙盒路径需为 `profile` 增一套（参考 [HomeLayoutDefaults.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutDefaults.swift)） |
| 3 | `HomeWidgetRegistry` 只注册首页 widget | 需为本页两种卡片注册 widget 类型与数据源候选 |
| 4 | 数据源是**编译期常量**（`let` 全局），不能按 id 动态枚举/校验 | [MockData.swift](file:///Volumes/home/repositories/Kline2/Kline/Data/MockData.swift#L46-L176) 的 7 个常量需改为「可枚举表（id → 数据）」才能做参数候选与失效回退（对比首页的 `HomeWidgetRegistry` 动态候选机制） |
| 5 | 本页 body 需由 `PageLayoutRenderer` 驱动 | `PageLayoutRenderer<HomeLayoutContext>` 目前泛型上下文是首页专用；需为本页提供 context 或抽象出通用 context |
| 6 | **零无障碍锚点** | 三个组件文件与本页均无 `accessibilityIdentifier`（已 grep 确认）→ 扩展后 UI 测试需补锚点，建议沿用首页命名习惯 `profile.card.<name>` |
| 7 | 本页是「演示/测试页」，数据全 mock | 编辑配置的收益是**布局演示**而非真实业务；若目标是真业务页面，应优先考虑其他 Tab 页 |

### 七、结论

- 本页结构是**首页的简化镜像**：`vstack[ 导航栏, divider, vstack[ 卡片, hstack[ scroll[vstack[卡片…]], scroll[vstack[卡片…]] ] ] ]`，只用得上 `vstack / hstack / scroll / divider` 四种节点词，**不涉及 `zstack / card / frame`**；左右双列独立滚动是本页独有结构。
- 现有节点词表**足以表达本页骨架**（分栏 / 滚动轴 / 间距 / 边距均可表态），真正的工作量在**两种卡片 widget 的注册 + 数据源从常量改为可枚举表 + page 键与配置仓库的 page 化**（缺口 1–5）。
- 候选池规模：**卡片 9 实例 → 2 个 widget 类型 + 7 个数据源候选**；占位 `Rectangle` 3 个不建议进树；导航栏与 `DetailPage` 明确排除。

---

## Why（第五轮，2026-09-25）：把测试页面的控件吸收为「通用控件」

用户核对附录 A 后明确方向（原话）：**「不需要编辑测试页面啊，我是让你把测试页面里有的而现有布局编辑器里没有的给整合进布局编辑器，未来布局编辑器的控件和容器我希望是绝大多数页面都能使用的（除了K线页面的单图和多图），暂时你只需要让我编辑首页就行了」**

即：附录 A 的产出**不是**让 ProfileView 变成可编辑页，而是当作**控件/容器词表缺口清单**用 —— 把测试页面用到、而编辑器词表没有的类型，抽成**页面无关的通用控件**补进编辑器；当前仍然只编辑首页。

### 一、词表缺口结论（对照附录 A 二/三节）

| 测试页面用到 | 编辑器原有词表 | 结论 |
|---|---|---|
| 横滑卡片（`HorizontalScrollCard`） | 无 | **补** → `common.hscrollCard` |
| 列表卡片（`ListCard`） | 无 | **补** → `common.listCard` |
| 灰色占位矩形（`Rectangle` 高 150/200/180） | 无（`home.placeholder` 是首页欢迎块，语义不同） | **补** → `common.placeholder`（高度可调） |
| 竖向滚动区 / 水平堆栈 / 竖向堆栈 / 分隔线 | `scroll` / `hstack` / `vstack` / `divider` | 已具备，不补 |
| 左右双列各自滚动 | `hstack` + 2×`scroll` | 已具备（可表达式化），不补 |
| 顶部导航栏 / 二级详情页 | `home.header`（首页专属）/ 无 | 不进词表（页面壳与跳转目标） |

### 二、参数引擎补「自由文本」能力（此前是真正的拦路项）

原有 5 种参数形态（bool / 数字步进 / 静态单选 / 候选多选 / 动态单选）**都无法表达「卡片标题」「条目文案」这类自由文本**，故本轮先补参数类型：

- `WidgetParamDescriptor.Kind` 新增 `.text(placeholder:note:)` 与 `.textList(placeholder:note:)`
- `LayoutNodeInspector.paramRow` 新增两分支：`.text` 走 `row` + 右对齐 `TextField`（写法对齐 `card` 的标题字段）；`.textList` 走新 `TextListParamRow`（每行「序号 + 输入框 + 删除」，标题行右侧「添加一条」）
- 存储**复用既有** `WidgetParamValue.strings([String])`（第二轮已支持）与 `PageLayoutEditorModel.setStrings`，`home.json` 结构不变

### 三、通用控件实现（新文件 `Kline/App/PageLayout/CommonLayoutWidgets.swift`）

放在**页面无关的引擎目录**（与 `PageLayoutRenderer` / `PageWidgetRegistry` 同级），文件内含四部分：

1. `enum CommonWidgetName`：`common.hscrollCard` / `common.listCard` / `common.placeholder`
2. `registerCommonLayoutWidgets<Context>(into:)`：**泛型函数，构建器忽略 `Context`**（只读 `WidgetParams`）——任何页面的注册表都能合并这一组，这是「绝大多数页面通用」的**结构保证**（不是约定）
3. 三个视图：
   - `CommonHScrollCard`：标题栏 + 横向滚动灰底 chip（条目文字来自参数）
   - `CommonListCard`：标题栏 + 竖向列表（序号自动生成、前 3 条红色）
   - `CommonPlaceholderBlock`：固定高度浅灰圆角块
   - 视觉逐项对齐测试页：卡片 `padding(16)` + `cornerRadius(12)` + `shadow(black 0.05, r4, y2)`；横滑卡右上角 `chevron.right`、列表卡右上角「更多」文字（与测试页两种卡片的差异一致）；条目为空时渲染**可诊断提示**而非静默空白
4. `CommonLayoutWidgetSchema`：三个控件的可编辑参数描述（`title` / `items` / `updateTime` / `showsMore` / `height`）

### 四、接入点（两行增量）

- `HomeWidgetRegistry.init` 末尾：`registerCommonLayoutWidgets(into: &r)`
- `HomeWidgetEditorSchema.all` 末尾：`+ CommonLayoutWidgetSchema.all` → 三个新控件立刻出现在「添加控件」菜单与检查器参数表单

### 五、非目标（第五轮不做）

- **不做** ProfileView 的可编辑化（`page` 参数化 / `profile.json` / 本页锚点 / renderer 驱动本页，一律不做）
- **不抽取**跨页共享注册表（当前只有首页可编辑；复用口已由 `registerCommonLayoutWidgets` 留好）
- **不改**容器词表（现有 9 种节点类型已覆盖测试页所需）
- **不接**真实数据源（通用控件的条目文案由配置给定，不绑 MockData / DB）

### 六、BREAKING

无。`home.*` 七个控件、`home.json` 结构与既有无障碍锚点全部不变；新控件与两种新参数类型都是**纯增量**，旧配置解码不受影响。

## ADDED Requirements（第五轮）

### Requirement: 页面无关的通用控件

布局编辑器提供一个**页面无关**的控件组：横滑卡片（`common.hscrollCard`）、列表卡片（`common.listCard`）。它们**只读 `WidgetParams`**、不依赖任何页面上下文，任何页面的控件注册表都能用 `registerCommonLayoutWidgets(into:)` 合并这一组。

> 落地后修订（2026-09-25，用户反馈）：原先一并做的「灰色占位块」（`common.placeholder`）**已删除**——它无任何配置引用、且与既有的 `home.placeholder`（A 档欢迎块）在「添加控件」菜单里重名，用户判定无用。通用控件组因此是**两个**。既有 `home.placeholder` 保持不变（A 档默认布局引用、`home.welcome` 锚点）。

#### Scenario: 在首页编辑器里添加通用控件
- **WHEN** 打开布局编辑器 → 「添加控件」→ 选「横滑卡片」
- **THEN** 树里新增该控件节点，检查器出现「卡片标题 / 条目 / 右上角时间 / 显示更多图标」四项参数

#### Scenario: 条目为空时的可诊断呈现
- **WHEN** 通用卡片控件的「条目」为空
- **THEN** 卡片内显示一行灰字提示（说明在检查器填写条目），**不出现静默空白**

#### Scenario: 条目文本编辑即时生效
- **WHEN** 在检查器里点「添加一条」/ 修改某行文本 / 点行尾删除
- **THEN** 参数以 `[String]` 写入节点 `params`、草稿置脏，全屏预览即时反映

### Requirement: 自由文本参数类型

参数描述表新增两种形态：`.text`（字符串）与 `.textList`（字符串数组，每行一条）。存储沿用既有 `WidgetParamValue.string` / `.strings`，JSON 结构不变。

#### Scenario: 旧配置兼容
- **WHEN** 加载不存在这两种参数键的既有 `home.json`
- **THEN** 解码、渲染、编辑行为与改动前完全一致