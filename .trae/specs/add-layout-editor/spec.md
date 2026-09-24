# 布局编辑器（个人中心入口 + 独立全屏页 + 实时预览）Spec

> **两轮规划**：第一轮（节点树结构编辑，已交付待真机验收）见下文全部既有章节；**第二轮「控件内容可配置」（快捷入口自由装配 + 四个内容控件数据源选择，2026-09-24 用户确认范围）见文末「第二轮深化」**。

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