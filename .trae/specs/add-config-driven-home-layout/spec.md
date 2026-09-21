# 首页 JSON 配置驱动布局 Spec

## Why

首页现有 4 档布局（A/B/C/D）是**硬编码在 Swift 里的**：每档一个 `HomeLayout*View`，逐行写死了「用哪些区块、什么顺序、怎么分栏、compact 还是非紧凑」。想调整顺序、换分栏、改参数，必须改代码、重新构建、重新部署。

用户诉求：**把四页（首页 / 自选页 / 行情页 / 模拟页）各方案用到的控件封装成单独的个体，再在沙盒目录放一套 JSON 配置文件，通过配置的方式组织指定页面的具体布局方式。**

本轮范围（用户确认）：
- **只做首页试点**，跑通后用同一套机制推广到自选 / 行情 / 模拟（推广另开 spec）。
- **等价搬迁**：JSON 只用来描述现有的 A/B/C/D 四档，逐项复刻现有呈现，行为零变化、可逐档对照验收；不支持配置出 A~D 之外的新布局。
- **内置默认 + 沙盒覆盖**：首启把内置默认 JSON 种入沙盒 `Documents/Layouts/`；可在沙盒里改 JSON 立即生效；删文件则重新种回默认。
- **一控件一文件**：首页用到的每个控件（含现在写成 `private func` 的区块）都提升为独立 `struct` + 独立文件，配一份「控件名 → 视图」注册表。

现状可复用资产：
- 项目已有成熟的**沙盒 JSON 落盘惯例**：`Documents/<模块>/<name>.json` + `loadFromDisk()` / `saveToDisk()`（`FavoritesStore` / `MarketConfigStore` / `SimStore` / `LinkedViewStore`），`JSONEncoder` 用 `.prettyPrinted + .sortedKeys + .atomic`。本变更沿用同一惯例。
- 首页 B/C/D 档的内容块**已经是参数化共享组件**（`HomeContentBlocks.swift` 的 `HomeMarketOverviewStrip` / `HomeFavoritesBlock` / `HomeSimSummaryBlock` / `HomeTopGainersBlock` 都接收 `compact` / `showsSparkline` / `style`），天然适合被 JSON 以 `params` 组合。
- 首页数据契约**已收敛**在 `HomePageModel`（只读快照 + 防抖聚合），布局视图只读快照，不需要新增数据源。
- `Kline.xcodeproj` 使用 `PBXFileSystemSynchronizedRootGroup`，新增 `.swift` 文件无需改工程文件。

## What Changes

### 一、控件抽取（一控件一文件）

把 `Kline/Home/HomeContentBlocks.swift` 与 `Kline/Home/HomePageKit.swift` 里的控件拆成 `Kline/Home/Widgets/` 下的一控件一文件：

| 控件 | 新文件 | 来源 |
|---|---|---|
| `HomeHeaderBar` | `Widgets/HomeHeaderBar.swift` | HomePageKit（含 `home.page` 锚点） |
| `HomeQuickEntryRow` | `Widgets/HomeQuickEntryRow.swift` | HomePageKit |
| `HomeQuickEntryChip` | `Widgets/HomeQuickEntryChip.swift` | HomePageKit |
| `HomeSectionCard` | `Widgets/HomeSectionCard.swift` | HomeContentBlocks |
| `HomeQuoteRow` | `Widgets/HomeQuoteRow.swift` | HomeContentBlocks |
| `HomeMarketOverviewStrip` | `Widgets/HomeMarketOverviewStrip.swift` | HomeContentBlocks |
| `HomeFavoritesBlock` | `Widgets/HomeFavoritesBlock.swift` | HomeContentBlocks |
| `HomeSimSummaryBlock` | `Widgets/HomeSimSummaryBlock.swift` | HomeContentBlocks |
| `HomeTopGainersBlock` | `Widgets/HomeTopGainersBlock.swift` | HomeContentBlocks |
| `HomeSearchModeView` | `Widgets/HomeSearchModeView.swift` | HomePageKit |
| `HomePlaceholderBlock` | `Widgets/HomePlaceholderBlock.swift` | **新增**：A 档占位（「首页」/「欢迎来到首页」+ `home.welcome` 锚点） |

留在 `HomePageKit.swift` 的只有**与布局无关的共享物**：入口清单 `HomeEntryKind`、浮层目标 `HomeOverlayTarget` + `HomeOverlays` / `.homeOverlays(...)`。`HomeContentBlocks.swift` 抽空后删除。

**行为零变化**：控件实现逐行搬运（含字号 / 间距 / 语义色 / 命中区 / `accessibilityIdentifier`），不顺手改样式。文件内 `private` 的配色助手（`homeQuoteTint` / `homePillColor` / `homeProfitColor`）随使用它的控件迁移，按需放宽为 `internal`。

### 二、通用 JSON 布局引擎（`Kline/App/PageLayout/`，与页面无关）

- `PageLayoutSchema.swift`：配置文件与节点树的 Codable 模型。
  - `PageLayoutFile`：`schemaVersion` / `page` / `default` / `layouts: [String: PageLayoutDefinition]`
  - `PageLayoutDefinition`：`title` / `shortTitle` / `root: PageLayoutNode`
  - `PageLayoutNode`：`type`（`vstack` / `hstack` / `zstack` / `scroll` / `card` / `frame` / `widget` / `divider` / `spacer`）+ 该类型专属可选字段（`spacing` / `alignment` / `padding` / `axis` / `maxWidth` / `minHeight` / `title` / `compact` / `name` / `params`）+ `children: [PageLayoutNode]?` + `child: PageLayoutNode?`。按 `type` 解码，未知 `type` 直接解码失败（**不静默忽略**，便于发现配置写错）。
  - `WidgetParams`：`[String: WidgetParamValue]`（`bool` / `int` / `double` / `string` 四型）+ 带默认值的取值方法 `bool(_:default:)` / `int(_:default:)` / `double(_:default:)` / `string(_:default:)`。
- `PageWidgetRegistry.swift`：泛型注册表 `PageWidgetRegistry<Context>`，把 `控件名 → (Context, WidgetParams) -> AnyView`。未注册的控件名 → 渲染出可诊断的占位（不崩溃、不静默空白）。
- `PageLayoutRenderer.swift`：`PageLayoutRenderer<Context>`，按节点树生成 `AnyView`。容器节点语义与现有 SwiftUI 写法逐项对齐：
  - `vstack` → `VStack(alignment:spacing:)`；`hstack` → `HStack(alignment:spacing:)`
  - `scroll` → `ScrollView(.vertical/.horizontal, showsIndicators:)`，`padding` 写到内层 `VStack(spacing:)`（对齐现有 `padding(16)` + `VStack(spacing: 12)` 写法）
  - `card` → `HomeSectionCard` 同款卡片容器（标题 13pt secondary + 浅灰底 + `cornerRadius(12)` + `compact` 控内边距 10/12）
  - `frame` → `.frame(maxWidth: .infinity, alignment: .top)` / `minHeight` 等
  - `divider` / `spacer` 直译
- `PageLayoutConfigStore.swift`：配置读写与回退。
  - 沙盒路径 `Documents/Layouts/<page>.json`
  - 首启种入：沙盒缺文件 → 把内置默认写入沙盒（等同现有 `loadFromDisk()` 返回 false 时的 `resetAll()` 思路）
  - 读回退链：**沙盒 JSON → 内置默认（并种回沙盒）→ 该页硬编码布局（保底）**；任一环节解析失败只降级、不崩溃
  - `reloadIfChanged(page:)`：比对文件修改时间，变了才重解码，供页面 `onAppear` 调用

### 三、首页接入

- 新增 `Kline/Home/HomeLayoutContext.swift`：`model: HomePageModel` + 容器注入的闭包（`onProfile` / `onEntryTap` / `onSelectTab` / `onOpenFormula` / `onOpenCondOrder`）。控件本身仍不持状态、不发命令。
- 新增 `Kline/Home/HomeWidgetRegistry.swift`：注册 7 个首页控件。

  | 控件名 | 视图 | `params` |
  |---|---|---|
  | `home.header` | `HomeHeaderBar` | 无 |
  | `home.quickEntryRow` | `HomeQuickEntryRow` | 无 |
  | `home.placeholder` | `HomePlaceholderBlock` | 无 |
  | `home.marketOverview` | `HomeMarketOverviewStrip` | `compact` |
  | `home.favorites` | `HomeFavoritesBlock` | `compact` / `showsSparkline` / `limit` |
  | `home.simSummary` | `HomeSimSummaryBlock` | `compact` |
  | `home.topGainers` | `HomeTopGainersBlock` | `style`（`list` / `chips`）/ `compact` |

- 新增内置默认 `Kline/Home/Layouts/home.json`：A/B/C/D 四档，逐项复刻现有 `HomeLayout{A,B,C,D}View` 的节点树（详见下文「配置样例」）。
- [HomeView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeView.swift#L28-L54) 的非搜索态分发改为：**JSON 优先**（`PageLayoutConfigStore` 拿到该页配置且含 `layoutStore.homeLayout.rawValue` 档 → 用 `PageLayoutRenderer` 渲染）；否则回落到现有 `HomeLayout{A,B,C,D}View`。
- 搜索态仍由容器直接走 `HomeSearchModeView`（它是**模式**不是布局，不进 JSON）；浮层仍走 `.homeOverlays(target:)`。
- `PageLayoutStore` / 个人中心「首页布局」下拉**完全不变**（`HomeLayoutStyle` 仍是 A/B/C/D 选择器，JSON 只需定义这四个 id）。

### 四、非目标（本轮不做）

- 不推广到自选 / 行情 / 模拟（机制已按泛型设计，另开 spec）。
- 不做「用 JSON 配置 A~D 之外新布局」的超集能力（本轮只等价搬迁）。
- 不做配置编辑 UI（改 JSON 走沙盒直连）。
- 不做 figma 原型（本次零视觉变化）。
- 不改 `HomePageModel` 数据口径、不改任何持久化结构、不改 `PageLayoutStore`。

### 五、BREAKING

无。JSON 渲染与现有硬编码视图**等价**，且硬编码视图保留为保底回退。

## Impact

- Affected specs: `redesign-home-layouts`（A/B/C/D 四档的呈现契约不变，仅渲染来源由硬编码改为配置驱动）
- Affected code（新增，工程文件无需改动 —— Swift 文件走同步组）：
  - 新增 `Kline/App/PageLayout/PageLayoutSchema.swift`、`PageWidgetRegistry.swift`、`PageLayoutRenderer.swift`、`PageLayoutConfigStore.swift`
  - 新增 `Kline/Home/Widgets/` 下 11 个控件文件（含共享配色助手 `HomeWidgetPalette.swift`）
  - 新增 `Kline/Home/HomeLayoutContext.swift`、`HomeWidgetRegistry.swift`
  - 新增 `Kline/Home/HomeLayoutDefaults.swift`
- **实现调整（内置默认的承载方式）**：原计划把内置默认放在资源文件 `Kline/Home/Layouts/home.json`。实测判定该路径不可靠 —— `Kline.xcodeproj` 用的是 `PBXFileSystemSynchronizedRootGroup`，同步组只按文件类型默认归档，未知类型（仓库里 `.tdx` 就靠 `PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions` 才进 Resources），`.json` 同样有不被纳入 Resources 的风险，而当前环境（Windows）无法本地构建验证。故改为放在 Swift 多行字符串常量 [HomeLayoutDefaults.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeLayoutDefaults.swift)（编译期必然进二进制），内容与「配置样例」逐字一致；由 `HomeView.onAppear` 通过 `registerBuiltInDefaults(page:json:)` 注入，`PageLayoutConfigStore` 保持与页面无关。**用户可见的沙盒配置文件 `Documents/Layouts/home.json` 与「沙盒改配置即时生效」行为完全不变**。工程文件仍无需改动
- Affected code（修改）：
  - [HomePageKit.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomePageKit.swift)（抽出控件后只留 `HomeEntryKind` / `HomeOverlayTarget` / `HomeOverlays`）
  - [HomeLayoutAView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeLayoutAView.swift)（改为组合 `HomePlaceholderBlock`，保底回退角色）
  - [HomeView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeView.swift)（JSON 优先分发）
- Affected code（删除）：
  - `Kline/Home/HomeContentBlocks.swift`（内容已迁至 `Widgets/`）
- 保留不动：`HomeLayoutBView.swift` / `HomeLayoutCView.swift` / `HomeLayoutDView.swift` / `HomePageModel.swift` / [PageLayoutStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/PageLayoutStore.swift) / [TradingLayoutSettings.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/TradingLayoutSettings.swift) / [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift)
- 无障碍锚点（必须保持）：`home.page`（`HomeHeaderBar` 的 `Text("Kline")`，`KlineUITests.swift` 的首页判定依赖）、`home.welcome`（A 档占位）、`home.entry.<rawValue>`（快捷入口 chip）

## 交付分期

- **阶段一（控件抽取）**：Task 1–2。一控件一文件，A/B/C/D 呈现零变化，独立可编译可真机验收。
- **阶段二（引擎 + 首页接入）**：Task 3–8。通用引擎、配置仓库、内置默认 JSON、首页 JSON 优先分发（含硬编码回退）。
- **阶段三（等价性验收）**：Task 9–10。逐档对照、沙盒改配置生效验证、锚点回归。

## 配置样例（内置默认 `home.json`，等价搬迁）

```json
{
  "schemaVersion": 1,
  "page": "home",
  "default": "B",
  "layouts": {
    "A": {
      "title": "A · 现有首页（保留）",
      "shortTitle": "A",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "home.header" },
          { "type": "divider" },
          { "type": "widget", "name": "home.placeholder" }
        ]
      }
    },
    "B": {
      "title": "B · 横滑入口 + 卡片网格（默认）",
      "shortTitle": "B",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "home.header" },
          { "type": "divider" },
          { "type": "widget", "name": "home.quickEntryRow" },
          {
            "type": "scroll", "axis": "vertical", "showsIndicators": true,
            "padding": { "top": 16, "leading": 16, "bottom": 16, "trailing": 16 },
            "spacing": 12,
            "children": [
              { "type": "card", "title": "大盘概览",
                "child": { "type": "widget", "name": "home.marketOverview",
                           "params": { "compact": false } } },
              { "type": "hstack", "alignment": "top", "spacing": 12,
                "children": [
                  { "type": "frame", "maxWidth": "infinity", "alignment": "top",
                    "child": { "type": "card", "title": "我的自选",
                               "child": { "type": "widget", "name": "home.favorites",
                                          "params": { "compact": false, "showsSparkline": true } } } },
                  { "type": "frame", "maxWidth": "infinity", "alignment": "top",
                    "child": { "type": "card", "title": "模拟账户",
                               "child": { "type": "widget", "name": "home.simSummary",
                                          "params": { "compact": false } } } }
                ] },
              { "type": "card", "title": "涨幅榜",
                "child": { "type": "widget", "name": "home.topGainers",
                           "params": { "style": "list", "compact": false } } }
            ]
          }
        ]
      }
    },
    "C": {
      "title": "C · 横滑入口 + 分区列表",
      "shortTitle": "C",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "home.header" },
          { "type": "divider" },
          { "type": "widget", "name": "home.quickEntryRow" },
          {
            "type": "scroll", "axis": "vertical", "showsIndicators": true,
            "padding": { "top": 16, "leading": 16, "bottom": 16, "trailing": 16 },
            "spacing": 12,
            "children": [
              { "type": "card", "title": "大盘概览", "compact": true,
                "child": { "type": "widget", "name": "home.marketOverview",
                           "params": { "compact": true } } },
              { "type": "card", "title": "我的自选", "compact": true,
                "child": { "type": "widget", "name": "home.favorites",
                           "params": { "compact": true, "showsSparkline": false } } },
              { "type": "card", "title": "模拟账户", "compact": true,
                "child": { "type": "widget", "name": "home.simSummary",
                           "params": { "compact": true } } },
              { "type": "card", "title": "涨幅榜", "compact": true,
                "child": { "type": "widget", "name": "home.topGainers",
                           "params": { "style": "list", "compact": true } } }
            ]
          }
        ]
      }
    },
    "D": {
      "title": "D · 横滑入口 + 工作台混排",
      "shortTitle": "D",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "home.header" },
          { "type": "divider" },
          { "type": "widget", "name": "home.quickEntryRow" },
          {
            "type": "scroll", "axis": "vertical", "showsIndicators": true,
            "padding": { "top": 16, "leading": 16, "bottom": 16, "trailing": 16 },
            "spacing": 12,
            "children": [
              { "type": "card", "title": "大盘概览",
                "child": { "type": "widget", "name": "home.marketOverview",
                           "params": { "compact": false } } },
              { "type": "hstack", "alignment": "top", "spacing": 12,
                "children": [
                  { "type": "frame", "maxWidth": "infinity", "alignment": "top",
                    "child": { "type": "card", "title": "模拟账户", "compact": true,
                               "child": { "type": "widget", "name": "home.simSummary",
                                          "params": { "compact": true } } } },
                  { "type": "frame", "maxWidth": "infinity", "alignment": "top",
                    "child": { "type": "card", "title": "我的自选", "compact": true,
                               "child": { "type": "widget", "name": "home.favorites",
                                          "params": { "compact": true, "showsSparkline": false, "limit": 3 } } } }
                ] },
              { "type": "card", "title": "涨幅榜",
                "child": { "type": "widget", "name": "home.topGainers",
                           "params": { "style": "chips", "compact": false } } }
            ]
          }
        ]
      }
    }
  }
}
```

## ADDED Requirements

### Requirement: 控件个体化（一控件一文件）

系统 SHALL 把首页各档用到的每个控件实现为独立 `struct` + 独立文件，置于 `Kline/Home/Widgets/` 下；控件只接收数据与闭包，不持有状态、不发命令、不直接跳转。

#### Scenario: 控件被多档复用
- **WHEN** 同一控件（如 `HomeFavoritesBlock`）在 B/C/D 档以不同 `params` 组合出现
- **THEN** 存在且仅存在一份控件实现；各档差异只由入参表达

#### Scenario: 控件抽取不改变呈现
- **WHEN** 抽取完成后在真机上切换 A/B/C/D 四档
- **THEN** 每档的字号、间距、颜色、分栏、hit 区与抽取前逐项一致

### Requirement: JSON 配置驱动页面布局

系统 SHALL 支持用 JSON 描述一个页面各档布局的节点树，并在运行时按节点树渲染页面。

#### Scenario: 配置可用时按配置渲染
- **WHEN** `Documents/Layouts/home.json` 存在且解析成功，且其中定义了 `PageLayoutStore.homeLayout` 所选档位
- **THEN** 首页非搜索态按该档位的节点树渲染

#### Scenario: 配置缺失时种入内置默认
- **WHEN** 沙盒中没有 `Documents/Layouts/home.json`
- **THEN** 系统把内置默认配置写入沙盒该路径，并立即用它渲染，用户无需任何操作

#### Scenario: 配置解析失败时降级不崩溃
- **WHEN** 沙盒 JSON 语法错误或含未知节点 `type`
- **THEN** 该文件被视为不可用，回退到内置默认（并种回沙盒）；若内置默认也不可用，回退到该页现有硬编码布局视图；全程不崩溃

#### Scenario: 档位未在配置中定义
- **WHEN** 所选档位 id（如 `C`）在配置文件中不存在
- **THEN** 回退到配置里的 `default` 档；`default` 也不存在时回退到硬编码布局视图

#### Scenario: 沙盒改配置即时生效
- **WHEN** 用户（或调试方）在沙盒里把 `home.json` 中 `spacing` 由 `12` 改为 `24`
- **THEN** 重新进入首页（`onAppear` 触发 `reloadIfChanged`）后新值生效，无需重新安装

#### Scenario: 未注册控件名可诊断
- **WHEN** 配置里出现注册表中不存在的 `widget` 名
- **THEN** 该节点渲染出可识别的占位提示（含控件名），不静默空白、不崩溃

### Requirement: 布局选择入口保持不变

系统 SHALL 保持 `PageLayoutStore` 与个人中心「首页布局」下拉的现有行为不变。

#### Scenario: 个人中心切换档位
- **WHEN** 在个人中心把「首页布局」由 B 切到 D
- **THEN** 首页立即切换为 D 档呈现（无论该档由 JSON 还是硬编码渲染）

### Requirement: 无障碍锚点不回归

系统 SHALL 保持既有无障碍标识可被 XCTest 稳定命中。

#### Scenario: 首页判定锚点
- **WHEN** UITest 等待 `app.staticTexts["home.page"]`
- **THEN** 四档下均能命中（锚点挂在共享标题栏的 `Text("Kline")` 上）

#### Scenario: A 档占位锚点与入口锚点
- **WHEN** A 档下等待 `home.welcome`，或在任意档下等待 `home.entry.<rawValue>`
- **THEN** 均能命中

## MODIFIED Requirements

### Requirement: 首页非搜索态分发

首页容器非搜索态的分发来源由「按 `PageLayoutStore.homeLayout` 直接分发到 `HomeLayout*View`」改为「优先按 JSON 配置渲染，配置不可用时回落到现有 `HomeLayout*View`」。搜索态（`HomeSearchModeView`）与浮层（`.homeOverlays`）的挂载方式不变。