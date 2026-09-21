# 首页多布局重设计 Spec

## Why

首页目前几乎是空的：`HomeView` 只有顶部标题栏（Kline 图标 + 登录胶囊）+ 一行占位文案「首页 / 欢迎来到首页」，是四个 Tab 里唯一没有信息架构的页面。

用户要求：**理解本项目**，用 figma 原型为首页设计**至少三套**新布局方案（加上现有实现共 4 档），**保留现有实现**，并能在**个人中心切换**布局。

现状落差与可复用资产：
- 自选页 / 行情页已落地「A（现有）+ B/C/D（新方案）」四档布局、个人中心下拉切换、`figma/` 原型画廊的完整先例（见 `.trae/specs/redesign-favorites-market-layouts`），首页可直接沿用同一套做法，不引入新范式。
- 首页的**功能入口**全部已有实现：搜索模式（双击首页 / 行情页搜索图标共用）、自选 Tab、行情 Tab、模拟 Tab、公式管理中心（`FormulaCenterView`）、个人中心（主题 / 布局 / 本地更新）。

## What Changes

- 新增 figma 原型画廊 `figma/home-ui-proposals.html`：首页 4 档屏（A 现状复刻 / B 宫格 / C 分区列表 / D 卡片工作台）+ 「个人中心新增『首页布局』行」演示屏 + 方案对比表；支持 `#shot=<屏 id>` 单屏定位，逐屏截图存 `figma/_shots/`（沿用既有命名与「不纳入提交」惯例）。
- [PageLayoutStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/PageLayoutStore.swift) 增加 `HomeLayoutStyle`（A/B/C/D）与 `@Published var homeLayout`，`UserDefaults` key `kline.homeLayout`，**默认 B**（用户确认：新方案作为默认，进首页即见内容）。
- 个人中心新增一行设置「首页布局」，复用既有 `LayoutDropdownButton` / `LayoutOptionsPanel`；浮层仍挂页面容器层、互斥链由 6 项扩为 7 项。
- 首页改造为**按布局分发的容器**（对齐 [FavoritesView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift#L28-L40) / [MarketView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketView.swift) 惯例），现有实现等价搬进 A 档视图（A 档呈现与交互零变化）；B/C/D 为新增视图。
- 新增共享骨架 `Kline/Home/HomePageKit.swift`：入口数据模型 `HomeEntryKind` + 三档共用的入口控件（宫格磁贴 / 列表行 / 卡片）+ 顶部标题栏 + 搜索模式视图 + 公式管理全屏 overlay，各档只做组合，不复制逻辑。
- [HomeView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeView.swift) 新增 `@Binding var selectedTab`，让首页入口能跳自选 / 行情 / 模拟（更新 3 处调用方：ContentView 两处 + MarketPageKit 搜索 overlay 传 `.constant`）。
- 无障碍标识：四档内容根统一挂 `home.page`；`home.welcome` 在 A 档保留；`KlineUITests` 的「首页已显示」判定改为 `home.page`（布局无关，默认档位变化不会误报）。
- **BREAKING**：无。仅新增文件、新增枚举与仓库字段、把首页既有 body 等价搬进 A 档视图、给 `HomeView` 增一个带默认回退的绑定。

## Impact

- Affected specs: `redesign-favorites-market-layouts`（个人中心设置行由五行扩为六行、浮层互斥链 6→7）、`add-trading-layout-options`（下拉组件与选择面板复用范围扩大）
- Affected code:
  - 修改 [PageLayoutStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/PageLayoutStore.swift)（加 `HomeLayoutStyle` + `homeLayout`）
  - 修改 [TradingLayoutSettings.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/TradingLayoutSettings.swift)（加 `HomeLayoutSettingRow`）
  - 修改 [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L44-L96)（加一行设置 + 一个容器层浮层 + 互斥链 6→7）
  - 修改 [HomeView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Home/HomeView.swift)（改分发容器 + 加 `selectedTab` 绑定）
  - 修改 [ContentView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/ContentView.swift#L226-L240)（两个 `HomeView(...)` 调用点补绑定）
  - 修改 [MarketPageKit.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift#L707-L712)（搜索 overlay 的 `HomeView(...)` 补 `.constant` 绑定）
  - 修改 [KlineUITests.swift](file:///c:/Users/sunck/home/projects/ios/Kline/KlineUITests/KlineUITests.swift#L69-L76)（首页判定标识改 `home.page`）
  - 新增 `Kline/Home/HomePageKit.swift`、`HomeLayoutAView.swift`、`HomeLayoutBView.swift`、`HomeLayoutCView.swift`、`HomeLayoutDView.swift`
  - 新增 `figma/home-ui-proposals.html`
  - 工程文件无需改动：`Kline.xcodeproj` 使用 `PBXFileSystemSynchronizedRootGroup`，新增文件自动纳入编译

## 交付分期

- **阶段一（设计稿）**：Task 1–3。figma 原型画廊 + 逐屏截图，用户先看稿定方案。
- **阶段二（骨架 + 入口 + 分发容器）**：Task 4–8。布局仓库、个人中心一行、首页分发容器与 A 档等价搬运、共享骨架，独立可编译可真机验收。
- **阶段三（B/C/D 三档 + 跳转打通）**：Task 9–13。
- **阶段四（验收）**：Task 14–15。

***

## 内容范围（用户确认）

首页新方案的内容 = **快捷入口区**（复用项目既有实现，不新增数据源、不做新统计）。

大盘概览（指数条 + 涨跌家数）、我的自选列表、模拟账户汇总**不在本次范围**；后续若要加，另开 spec 追加。

### 共享入口清单（`HomeEntryKind`，四档共用同一份数据）

| 入口 | 图标（SF Symbol） | 行为（全部复用既有实现） |
|---|---|---|
| 搜索标的 | `magnifyingglass` | `isSearching = true` → 现有搜索模式（返回按钮 + 搜索框 + `SearchPageView`） |
| 自选 | `folder` | `selectedTab = 1`（底部 Tab 同序号） |
| 行情 | `chart.bar` | `selectedTab = 2` |
| 模拟交易 | `gamecontroller` | `selectedTab = 3` |
| 公式管理 | `function` | 首页容器层全屏 overlay 打开 `FormulaCenterView(initialKind: .tech, onClose:)` |
| 个人中心 | `person.circle` | `isProfilePresented = true`（其中的主题 / 布局 / 本地更新即为「设置」类入口） |

## 设计档位（本次要落地的 4 档）

| 档 | 名称 | 信息架构要点 |
|---|---|---|
| A | 现有实现（**保留**） | 顶部标题栏（Kline 图标 + 名称 + 右侧「登录」胶囊）+ 分隔线 + 居中占位（「首页」+「欢迎来到首页」）；搜索模式下为 返回 + 搜索框 + `SearchPageView` |
| B | 宫格快捷入口（**默认档**） | 顶部标题栏 + 一行搜索条（点击进搜索）+ 「快捷入口」分组标题 + 入口宫格（每格图标 28pt + 名称 13pt、格高 88pt；列数按可用宽度自适应：≥960 四列 / ≥640 三列 / 否则两列） |
| C | 分区列表入口 | 顶部标题栏 + 按用途分三组（「行情」：行情 / 自选；「研究」：搜索 / 公式管理；「账户」：模拟交易 / 个人中心）的入口行（左图标方块 28pt + 标题 16pt + 副标题 12pt + 右侧 chevron，行高固定 56pt，行间 `Divider`） |
| D | 卡片工作台 | 顶部标题栏 + 顶部大卡（搜索标的，含说明文案）+ 2×2 中卡（自选 / 行情 / 模拟交易 / 公式管理，卡高 104pt，含图标 + 标题 + 一句说明）+ 底部一行小卡（个人中心，高 64pt） |

### 通用约束（4 档全部适用）

- 复用既有实现与单例，不新增数据源、不改任何持久化结构：`isSearching` / `isProfilePresented` 绑定、`selectedTab` 绑定、`FormulaCenterView`。
- 全部使用语义化颜色（`Color(.systemBackground)` / `Color(.secondarySystemBackground)` / `.primary` / `.secondary`），深色模式可读；禁止写死白底。
- 所有可点击元素命中区 ≥ 44×44pt；行高 / 卡高 / 格高固定，状态切换与点击不引起布局抖动。
- 搜索模式（`isSearching == true`）为**四档共用**，逐项保持现状：返回按钮 + 搜索框 + 自动聚焦 + `SearchPageView`；切换布局不改变搜索行为。
- 首页在「行情页搜索图标」场景被复用（`MarketPageKit` 的 overlay）：该场景传 `selectedTab: .constant(2)`，行为与现状一致。

## ADDED Requirements

### Requirement: 首页布局偏好持久化

系统 SHALL 在 `PageLayoutStore` 中提供 `homeLayout`（`ObservableObject` 单例 + `UserDefaults` key `kline.homeLayout`），取值域为 A / B / C / D，**默认 B**；选择变更后首页 SHALL 立即生效，App 重启后保持。

#### Scenario: 切换后立即生效并持久化

- **WHEN** 用户在个人中心把「首页布局」从 B 改为 D
- **THEN** 切回首页立刻呈现 D 档，杀掉 App 重启后仍是 D

#### Scenario: 非法/缺失存储值回退默认

- **WHEN** `UserDefaults` 中 `kline.homeLayout` 为空或不是 A/B/C/D
- **THEN** 首页布局回退为 B，不崩溃

### Requirement: 个人中心「首页布局」设置行

系统 SHALL 在个人中心新增一行「首页布局」，右侧为显示当前档名的下拉触发按钮（字号 12 / 高 28 / `.plain` / 蓝色前景），点击后在页面容器层居中弹出四选项面板（210pt 宽、行内 `padding(.horizontal,12)/.vertical,10)` + `Divider`、蓝色 checkmark、底部「完成」、`systemBackground` + `cornerRadius(12)` + `shadow(black 20%, radius 12, y 4)`），与既有主题 / 布局弹窗逐项一致；该行置于「行情页布局」行下方。

#### Scenario: 打开与关闭选择面板

- **WHEN** 用户点击「首页布局」右侧按钮
- **THEN** 弹出四选项面板（A / B / C / D），当前项带蓝色 checkmark；点选项即切换，点「完成」或遮罩关闭

#### Scenario: 七个浮层两两互斥

- **WHEN** 任意浮层（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 首页布局 / 公式中心）已打开时点另一行按钮
- **THEN** 同时只呈现一个浮层，无叠层错位

### Requirement: 首页四档布局

系统 SHALL 让首页按 `PageLayoutStore.homeLayout` 呈现 A / B / C / D 四档之一；四档共用同一份入口清单、同一个标题栏与同一套搜索模式。

#### Scenario: A 档行为零变化

- **WHEN** 布局为 A
- **THEN** 首页与改造前的呈现、交互、无障碍标识（`home.welcome`）完全一致

#### Scenario: B 档宫格自适应列数与点击

- **WHEN** 在 B 档以横屏 iPad 宽度（≥960pt）呈现
- **THEN** 入口宫格为四列；点任一格进入对应功能（自选 / 行情 / 模拟 / 公式管理 / 个人中心 / 搜索）

#### Scenario: C 档分组入口行点击

- **WHEN** 在 C 档点「行情」分组的「行情」行
- **THEN** 底部 Tab 切到行情页（`selectedTab == 2`），选中态同步

#### Scenario: D 档卡片入口点击

- **WHEN** 在 D 档点顶部大卡
- **THEN** 进入搜索模式（与双击首页 Tab、点行情页搜索图标完全一致的界面）；点底部小卡进入个人中心

#### Scenario: 公式管理入口

- **WHEN** 在任一档点「公式管理」
- **THEN** 首页容器层全屏呈现 `FormulaCenterView`（初始落「技术指标」段），页内「返回」关闭后回到首页原档位

#### Scenario: 搜索模式四档一致

- **WHEN** 任一档进入搜索模式
- **THEN** 呈现与现状逐项一致的搜索界面（返回按钮 + 搜索框自动聚焦 + `SearchPageView`）；点返回回到该档首页内容

### Requirement: 首页入口跳转底部 Tab

系统 SHALL 让首页入口能切换底部 Tab（自选 / 行情 / 模拟），通过给 `HomeView` 增加 `@Binding var selectedTab` 实现，索引与 `ContentView.menuItems` 一致（0 首页 / 1 自选 / 2 行情 / 3 模拟）。

#### Scenario: 首页 → 自选 → 返回首页

- **WHEN** 在首页点「自选」入口
- **THEN** 底部 Tab 选中态与内容区切到自选页；再点底部「首页」可回到首页且档位不变

#### Scenario: 行情页搜索 overlay 不受影响

- **WHEN** 在行情页点搜索图标（走 `HomeView` 的 overlay 复用）
- **THEN** 呈现的仍是搜索界面，且不会改动底部 Tab 选中态

### Requirement: 首页无障碍标识

系统 SHALL 在四档首页内容根挂无障碍标识 `home.page`，并保留 A 档的 `home.welcome`；`KlineUITests` 的首页判定 SHALL 改用布局无关的 `home.page`。

#### Scenario: 默认档位变化不影响冒烟用例

- **WHEN** 默认布局为 B（非 A）时运行 `test02_TabSwitching_ShowsEachPage`
- **THEN** 用例仍能判定首页已显示（`home.page` 存在），不因档位不同而失败

### Requirement: figma 原型画廊交付

系统交付 SHALL 包含自包含的 `figma/home-ui-proposals.html`（无外链依赖），按既有 `figma/favorites-market-ui-proposals.html` 的画廊形态组织：iPad mini 4 横屏设备框（1024×768，等比缩放至 573×430）、区块内方案切换器、屏内编号标注与右侧标注栏（描述 / 布局标注 / 优势 / 代价）、一张跨方案对比表；支持 `#shot=<屏 id>` 单屏定位，供无头浏览器逐屏截图到 `figma/_shots/`。

#### Scenario: 单屏定位可截图

- **WHEN** 用无头浏览器打开 `figma/home-ui-proposals.html#shot=homeB`
- **THEN** 页面直接呈现首页 B 档那一屏，无多余区块干扰截图

#### Scenario: 画廊覆盖全部档位

- **WHEN** 打开画廊
- **THEN** 首页 4 档均可切换查看；个人中心演示屏展示新增的「首页布局」行与四选项面板（共六行布局/主题设置行）

### Requirement: 真机验证闭环

系统 SHALL 按项目既定闭环交付：Windows 下执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`，退出码 0 / 6 / 7 视为构建通过；每次交付说明本轮 build 号、改动内容与真机验证路径。

#### Scenario: 阶段构建通过

- **WHEN** 阶段二 / 三编码完成
- **THEN** 闭环命令返回 0 / 6 / 7，且 `git status` 无遗留未提交改动

## MODIFIED Requirements

### Requirement: 个人中心设置行与浮层互斥

个人中心 SHALL 呈现**六行**设置行（Kline 显示主题 / 快捷面板布局 / 模拟页布局 / 自选页布局 / 行情页布局 / **首页布局**）+ 公式管理入口 + 本地更新面板；任一行触发的浮层（主题、四个既有布局选择面板、首页布局选择面板、公式管理中心）SHALL 同时只呈现一个。

（原「个人中心五行设置行、六个浮层互斥」扩展为六行、七个浮层。）

## REMOVED Requirements

无。