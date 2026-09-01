# K 线设置面板设计规范

> 本文档定义 K 线详情页右下角「⚙ 设置」按钮所打开面板的结构、视觉规格与交互规范。
> 整理日期：2026-09-01。
> 对应的布局总览图请见 `Kline-页面布局设计.md` 第 1 节「页面骨架」中的设置面板 overlay 说明。

---

## 目录

- [1. 设计目标](#1-设计目标)
- [2. 整体结构](#2-整体结构)
- [3. 构建块规格](#3-构建块规格)
- [4. 交互约定](#4-交互约定)
- [5. 代码入口映射](#5-代码入口映射)
- [6. 旧版迁移清单](#6-旧版迁移清单)

---

## 1. 设计目标

**对齐 iOS 设置 App（分组 Inset Grouped 风格）**，解决旧版的以下问题：

1. 下拉选择行（行情周期 / 联动视图数量 / K 线类型）使用 SwiftUI `Menu`，在 iPad 上以 popover 形式依附于左侧的小灰块弹出，位置随控件不同而变化，观感随意。
2. 各 Section 标题、Menu 行、Toggle 行、重置按钮各自带有独立的 padding 实现，行间间距/字号/圆角不统一，视觉上"乱"。
3. 重置按钮夹在两个分组之间、无背景卡片，红色字体直排，辨识度与重要度不匹配。

本规范通过 **统一的构建块 + 单一 confirmationDialog 弹出点**，保证"加一个新设置项只需选一个行类型，不需要改 padding / 字号"。

---

## 2. 整体结构

面板为**从底部弹出**的 sheet（实际由 `ZStack alignment:.bottom` + 遮罩 overlay 实现，避免 `.fullScreenCover` 白屏问题，见项目"硬约束"说明）。

```
┌───────────────────────────────────────┐
│  顶部遮罩（黑 0.35，点击关闭）         │  ← 不在面板内，整屏覆盖上部 25%
├───────────────────────────────────────┤ ← 面板（高度 = 屏幕高 × 0.75，白底，top 16 圆角）
│ ◄── Header ───────────────────────► │  ← 见 3.1
├───────────────────────────────────────┤ ← Divider
│                                       │
│  "通用"                              │  ← Section 标题
│  ┌─────────────────────────────────┐  │
│  │ 行情周期               日线  ›  │  │  ← 选择行（stSelectionRow）
│  ├─────────────────────────────────┤  │
│  │ 联动视图数量          2 视图 ›  │  │
│  └─────────────────────────────────┘  │
│                                       │
│  ┌─────────────────────────────────┐  │
│  │  ↺ 重置当前标的联动视图配置    │  │  ← 危险行（stDestructiveRow，独立分组）
│  └─────────────────────────────────┘  │
│                                       │
│  "显示"                              │  ← Section 标题
│  ┌─────────────────────────────────┐  │
│  │ K线类型            蜡烛图   ›  │  │  ← 选择行
│  ├─────────────────────────────────┤  │
│  │ 跳空缺口                   [●]  │  │  ← 开关行（stToggleRow）
│  │ 在 K 线之间标出跳空缺口区域    │  │
│  ├─────────────────────────────────┤  │
│  │ 缺口回补后消失             [○]  │  │
│  │ 开启时缺口被回补后整体隐藏…    │  │
│  ├─────────────────────────────────┤  │
│  │ 最新价线                   [●]  │  │
│  │ ......                         │  │
│  │（K线类型以下共 6 行，省略）│  │
│  └─────────────────────────────────┘  │
│                                       │
└───────────────────────────────────────┘
```

所有选择/开关**不再**使用 `Menu { }`；选择项统一改为 **整行 Button → `confirmationDialog(titleVisibility: .visible)`**，始终从面板底部弹出，位置完全一致（不受行所在高度影响）。

---

## 3. 构建块规格

以下常量是"规范"。**新增任何设置项时，请不要自行发明 padding / 字号，请直接调用已经定义好的 helper。**

### 3.1 面板外壳 & Header

| 属性 | 值 |
|---|---|
| 容器高度 | `geometry.size.height × 0.75` |
| 背景 | `Color.white` |
| 顶部圆角 | `RoundedRectangle(cornerRadius: 16, style: .continuous)` |
| Header 行高 | 内容 17pt semibold + 上下 14pt + 分隔线 |
| Header 左 | "K线设置" 17pt **semibold** 黑字 |
| Header 右 | "完成" 15pt **semibold** 蓝字（.blue），点击关闭面板 |
| Header 横向 padding | 18pt |
| Header 分隔线 | 默认 Divider 紧贴底部 |

代码：[`settingsHeader(title:onClose:)`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L762-L780)

### 3.2 Section 分组标题（`stSectionTitle`）

| 属性 | 值 |
|---|---|
| 字号 | 13pt semibold |
| 字色 | `Color.gray.opacity(0.85)` |
| 左 padding | 32pt（与卡片圆角外沿对齐；比卡片内容多 16pt，形成"小标题缩进到分组外"的效果） |
| 上 padding | 18pt（与上一个分组底部拉开距离） |
| 下 padding | 6pt（与紧接的卡片上沿保持间距） |

代码：[`stSectionTitle(_:)`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L782-L790)

### 3.3 分组卡片（`stGroupedCard`）

所有"行"必须放在分组卡片内，不能直接裸放在 ScrollView 中。

| 属性 | 值 |
|---|---|
| 外层水平 padding | 16pt（离面板左右边缘留白） |
| 卡片背景色 | `Color(red: 0.95, green: 0.95, blue: 0.97)` ≈ #F2F2F7，iOS 设置默认灰 |
| 卡片圆角 | **10pt**（`.cornerRadius(10)`，不带 style 参数，兼容所有 SwiftUI） |
| 卡片内 VStack spacing | **0**（行间分隔线通过 `stDivider()` 显式插入，统一 16pt 起画） |

代码：[`stGroupedCard<Content>`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L792-L800)

### 3.4 行间分隔线（`stDivider`）

| 属性 | 值 |
|---|---|
| 渲染 | SwiftUI 内置 `Divider()` |
| leading padding | **16pt**（与行内容左 padding 对齐，不会贴到卡片左边缘） |
| 位置 | **两张"选择/开关/危险"行之间**显式插入；分组第一行**前**和最后一行**后**不画 |

代码：[`stDivider()`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L802-L805)

### 3.5 下拉选择行（`stSelectionRow`）

用于**从多个固定候选**中选一个：行情周期 / 联动视图数量 / K 线类型。

| 属性 | 值 |
|---|---|
| 行高 | **44pt**（与 iOS 设置行一致） |
| 水平 padding | 16pt |
| 命中区 | `.contentShape(Rectangle())`，整行可点 |
| 按钮样式 | `.buttonStyle(.plain)`（不附加默认高亮/按压色） |
| 左标签 | 16pt 黑字 regular，固定文案（"行情周期" / "K线类型"） |
| 中间 Spacer | `minLength: 12`，把右侧推到最右边 |
| 右值 | 15pt 灰字，`lineLimit(1)` + `layoutPriority(1)`，保证长值优先显示完整而挤压左标签空间 |
| 右指示箭头 | `chevron.right` 12pt semibold，`Color.gray.opacity(0.6)`，不可去掉 —— 它向用户传达"点击后展开更多选项"的语义 |

**禁止**：直接在此行内用 `Menu` / `Picker`。点击事件只做一件事：切换一个 `@State` Bool 触发 `confirmationDialog`。

代码：[`stSelectionRow(title:value:onTap:)`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L807-L829)

### 3.6 开关行（`stToggleRow`）

用于 Bool 型图层开关：跳空缺口 / 缺口回补后消失 / 最新价线 / 指标不挤压 K 线 / 裸 K。

| 属性 | 值 |
|---|---|
| 水平 padding | 16pt |
| 垂直 padding | 10pt（行高随副标题自动，通常约 54pt） |
| 左侧 VStack spacing | 3pt（标题与副标题之间） |
| 左标题 | 16pt 黑字 regular，不加粗 |
| 左副标题 | 12pt 灰字，`fixedSize(h:false, v:true)` 允许换行（长说明两行也没问题）|
| 右 Toggle | `labelsHidden()` + `.tint(.blue)`，单独右对齐；**标题不得写在 Toggle 的 label 参数里**，否则副标题无法独立显示；HStack spacing 12 + `Spacer(minLength:12)` 推到最右 |

代码：[`stToggleRow(title:subtitle:isOn:)`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L831-L850)

### 3.7 危险操作行（`stDestructiveRow`）

用于"重置当前标的联动视图配置"这类破坏性操作。**必须独立成一个单独分组卡片**，视觉上与正常选择/开关分隔开。

| 属性 | 值 |
|---|---|
| 行高 | 44pt |
| 水平 padding | 无（内部通过 HStack Spacer 对中） |
| 内容色 | `.red` 整个 HStack 设色（图标 + 文字一起红） |
| 图标 | `arrow.counterclockwise` 14pt medium |
| 字号 | 16pt **medium** |
| 对中 | 两侧 Spacer 对称 |

点击不直接执行，而仍然触发一个带 `role:.destructive` 的确认流程（`confirmationDialog` 或 `alert`）。

代码：[`stDestructiveRow(title:onTap:)`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L852-L868)

---

## 4. 交互约定

### 4.1 下拉选择（禁止 Menu / popover）

```
旧 ✗  Menu { options } label: { 灰底小芯片 }
       ↳ iPad 上 popover 出现在芯片位置，iPhone 可能走底部菜单
新 ✓  stSelectionRow → 修改 @State showXxxPicker = true
       ↳ ScrollView 级别的 .confirmationDialog("标题", isPresented: $showXxxPicker, titleVisibility: .visible)
```

confirmationDialog 的特点：
- 在 iPhone（compact）上一律从**屏幕底部**弹出；
- 在 iPad（regular）上也会弹出为底部式 sheet / 居中卡片，不会依附于行位置（这是和 Menu 的本质差别）。
- 必须有 `Button("取消", role: .cancel)` 作为最后一项。
- 当前选中项**不需要**在选项中单独加 checkmark（因为所选值已经在选择行右侧一直显示着了）。

所有选择器声明都挂在 settingsOverlay 内的 ScrollView 上，用链式 `.confirmationDialog(...).confirmationDialog(...)` 叠加。

### 4.2 开关切换

直接用 `isOn.animation()` 绑定到 `ChartConfigStore` 的发布属性，确保切开关立即重绘。

### 4.3 关闭面板的 4 个触发点

1. Header 右上"完成"按钮
2. 遮罩（顶部 25% 空白 + 面板左右以外区域）点击
3. 以上两个都用 `withAnimation { showSettings = false }`，带 opacity transition
4. 代码中其它位置切换也应走相同语句

---

## 5. 代码入口映射

| 职责 | 位置 |
|---|---|
| 面板整体容器 & 遮罩 | [`settingsOverlay(geometry:)`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L636-L758)，L638-L647 ZStack 遮罩层 |
| Header + 完成按钮 | [`settingsHeader(title:onClose:)`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L762-L780) |
| 分组标题 | [`stSectionTitle(_:)`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L782-L790) |
| 分组卡片容器 | [`stGroupedCard`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L792-L800) |
| 行间分隔线 | [`stDivider`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L802-L805) |
| 选择行 | [`stSelectionRow`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L807-L829) |
| 开关行 | [`stToggleRow`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L831-L850) |
| 危险行 | [`stDestructiveRow`](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L852-L868) |
| 3 个 confirmationDialog 选择器 | ScrollView 尾部链式声明，[settingsOverlay L721-L750](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L721-L750) |
| 重置确认 confirmationDialog | 紧接重置分组卡片后面，[L677-L687](file:///Volumes/home/repositories/Kline2/Kline/KlineDetailView.swift#L677-L687) |
| 状态：3 个选择器开关 | KlineDetailView L171-L174：`@State showPeriodPicker / showViewCountPicker / showChartStylePicker` |
| 绑定的数据源 | `@ObservedObject config = ChartConfigStore.shared` 全应用共享，切换周期写 `config.selectedPeriod`，切换K线类型写 `config.chartStyle`，各图层开关写 `config.displaySettings.*`，裸 K 写 `config.showBareK` |
| 联动视图数量 & 重置 | 通过 `LinkedViewStore.shared.setViewCount / reset`，并带 `nameHint:` 补齐名称/code/type，避免生成空信息（见 `LinkedViewStore` 修复记录） |

---

## 6. 旧版迁移清单

如果你在未来看到以下代码形态，**请立即按本规范重构**：

| 旧代码形态 | 改为 |
|---|---|
| `Menu { ForEach(...) Button {} } label: { HStack { 文本 + chevron.up.chevron.down } .gray.background.cornerRadius(frame maxWidth leading) }` | `stSelectionRow` + 独立的 `confirmationDialog` |
| 单独裸放在 ScrollView 里的 `Button("重置")`（无卡片背景）| `stGroupedCard { stDestructiveRow }` + `confirmationDialog` |
| `Toggle(isOn: ...) { Text(title) }` + 独立 `subtitle()` 在 `VStack(spacing:4)` + 外层再 `.padding(.vertical,6)` + 末尾 `Divider.padding(.leading,16)` | `stToggleRow`（已经包含 16pt 水平 padding、标题/副标题两行布局、右对齐无标签 Toggle） |
| `settingsSectionTitle` 旧版（12pt semibold / top 16 / bottom 4 / hpad 16）| `stSectionTitle`（13pt / top 18 / bottom 6 / hpad 32）；**旧 helper 已删除，引用会直接编译失败** |
| toggleRow 旧 helper（引用已删除）| `stToggleRow` |

---

### 新增一个设置项的流程（速查）

1. 在 `ChartDisplaySettings`（或 `ChartConfigStore` 顶层）加对应字段 `var xxx = false`，确保 `@Published` 触发重绘。
2. 选分组：通用（卡片 1）/ 危险操作（新卡片）/ 显示（卡片 3），或必要时开新分组卡片。
3. 选行类型：
   - 如果是多选项 → 定义新的 `@State private var showXxxPicker = false`；写一个 `stSelectionRow`；在 ScrollView 上追加一个 `.confirmationDialog("选择 XXX", isPresented: $showXxxPicker) { ForEach(allCases) { c in Button(c.rawValue){ withAnimation { config.xxx = c }}} Button("取消", role:.cancel){}}`
   - 如果是开关 → `stToggleRow(title:subtitle:isOn: $config.displaySettings.xxx)`，并在前后各一行用 `stDivider()` 连起来（第一行之前、最后一行之后不要分）
   - 如果是危险操作 → `stGroupedCard { stDestructiveRow(title: ...)` + 一个 `confirmationDialog / alert` 确认
4. 检查 Section 标题是否已经存在；开新分组时记得在卡片上方加 `stSectionTitle("分组名")`。
5. 真机打开面板检查：行高 / 分隔线 / 左标题对齐 / 右控件对齐 / 弹出一致性。

---

> 以上规范一旦修改，请同步更新本文档并在 `Kline-页面布局设计.md` 对应章节中链接此处。
