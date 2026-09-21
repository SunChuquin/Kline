# 布局编辑器（个人中心入口 + 独立全屏页 + 实时预览）Spec

## Why

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