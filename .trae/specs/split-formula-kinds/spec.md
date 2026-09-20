# 三类公式分域 Spec

## Why

项目目前只有一个公式体系：**技术指标公式**（[SystemIndicatorStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/SystemIndicatorStore.swift) 的 `Documents/indicator/<周期>/*.tdx` + [CustomIndicator.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/CustomIndicator.swift) 的 `USER_*.tdx`）。**选股公式**没有独立实体，只是「自选分组」里的一段内嵌文本（[FavoritesStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift#L25-L51)、[FavoritesView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift#L617-L688)）；**交易策略公式**完全缺失。

三类公式共用同一套通达信语法，但语义、生命周期、出现位置完全不同：技术指标要落到 K 线主图/副图，选股公式只在全市场跑批时求值，策略公式表达「选什么 + 怎么买卖」。共用一套存储与列表，必然互相污染——最典型的就是选股/策略公式混进 K 线页的指标选择面板。本次先把三类公式在**类型、存储、列表、入口**四个层面彻底分开，为后续「选股/策略公式在 K 线页的表现」留出干净的接入点。

## What Changes

* 引入公式类型 `FormulaKind`（技术指标 / 选股指标 / 交易策略）与「一类型一目录」的物理隔离，`.tdx` 统一新增 `KIND=` 头

* 新增**选股公式库**：独立实体 `FormulaDoc` + 独立目录 `Documents/formula/picker/*.tdx`；自选的「公式分组」从内嵌公式改为**引用**公式库条目

* 新增**交易策略公式库**：`Documents/formula/strategy/*.tdx`，采用 `PICK + RULES` 双段格式。PICK 段是选股条件（可内嵌，也可 `PICKREF=` 引用库中选股公式），RULES 段逐行调用条件单（8 种，与 `SimCondKind` 一一映射，多行即成组合）。本阶段只做**定义 + 解析 + 校验 + 预览**，不生成真实条件单、不下单

* 新增**公式管理**中心页（三分段），入口：个人中心（主入口）+ 行情「选股」Tab、模拟页三个布局工具栏（域内跳转）

* K 线页主图/副图指标面板**只**呈现技术指标公式：`SystemIndicatorStore` 解析并过滤 `KIND=`，非技术指标一律不装载；并把面板文案明确为「技术指标公式」

* **BREAKING**：`favorites.json` 的 `schemaVersion` 1 → 2。`FavoritesGroup` 新增 `formulaID: String?`，原 `formula: String?` 仅保留用于旧档解码与一次性迁移。旧档首启自动迁移：为每个「公式分组」在选股库中建同名公式并建立引用；迁移后分组名、成员、隐藏状态均不变

## 三类公式隔离矩阵（本次定型）

| 维度    | 技术指标公式                                                      | 选股指标公式                                       | 交易策略指标公式                                      |
| ----- | ----------------------------------------------------------- | -------------------------------------------- | --------------------------------------------- |
| 语义    | 一条或多条输出线，画在主图/副图                                            | 一条判断表达式（最后一根输出值 > 0 = 命中）                    | 选股条件（PICK）+ 交易规则（RULES）                        |
| 存储目录  | `Documents/indicator/<周期目录>/*.tdx`（含 `USER_*.tdx`）         | `Documents/formula/picker/*.tdx`             | `Documents/formula/strategy/*.tdx`            |
| 文件头   | `KIND=TECH` + `NAME=` / `SCOPE=` / `GROUP=` / `COORD=` / `FORMULA:` | `KIND=PICKER` + `NAME=` / `FORMULA:`          | `KIND=STRATEGY` + `NAME=` / `PICKREF=` / `PICK:` / `RULES:` |
| 装载者   | `SystemIndicatorStore` / `CustomIndicatorStore`              | `FormulaLibraryStore`（pickers）               | `FormulaLibraryStore`（strategies）              |
| 周期维度  | 有（每周期一份独立副本）                                                | 无（跑全市场日线）                                    | 无（本阶段不做周期化）                                   |
| 可见位置  | K 线页主图/副图指标选择面板 + 公式管理「技术指标」段                               | 公式管理「选股指标」段 + 自选分组编辑；**不出现在 K 线页**          | 公式管理「交易策略」段 + 模拟页工具栏入口；**不出现在 K 线页**          |
| 本阶段能力 | 现状不变                                                        | 增删改查 + 测试 + 被自选分组引用                          | 增删改查 + 解析校验 + 语义预览（不执行、不下单）                   |
| 后续接入点 | —                                                           | 行情「选股」Tab 的二级分类（趋势/震荡/反转/情绪）待定               | 绑定账户、生成条件单组合、跑历史回测（下一阶段）                      |

## Impact

* Affected specs：无既有 spec 被修改（`.trae/specs` 下 `add-conditional-orders`、`add-second-floating-accessory`、`add-trading-layout-options` 与公式域无交集）

* Affected code：

  * 新增：`Kline/Formula/FormulaKind.swift`（类型 + 文档模型 + 仓库 + 序列化）、`Kline/Formula/StrategyFormula.swift`（规则目录/解析/校验/预览）、`Kline/Formula/FormulaCenterView.swift`（中心页三分段）、`Kline/Formula/StrategyFormulaEditorView.swift`（策略编辑器）

  * 修改：[SystemIndicatorStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/SystemIndicatorStore.swift)（`KIND=` 解析与过滤）、[CustomIndicator.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/CustomIndicator.swift)（落地文件写 `KIND=TECH`）、[FormulaEditorView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/FormulaEditorView.swift)（新增 picker 模式）、[FavoritesStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift)（schemaVersion 2 / `formulaID` / 迁移 / 刷新改走公式库）、[FavoritesView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift)（分组编辑器改为选库中公式）、[ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift)（公式管理入口行）、[MarketView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketView.swift)（选股 Tab 工具栏入口）、[SimSharedViews.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimSharedViews.swift) + `SimulationLayoutAView/BView/CView.swift`（策略公式入口）

***

## ADDED Requirements

### Requirement: 公式类型与存储隔离

系统 SHALL 用显式类型区分三类公式，并让三类公式落在互不交叉的目录，任何一类都不得被另一类的装载器读到。

* `FormulaKind` SHALL 为 `tech` / `picker` / `strategy`，各带中文标题（「技术指标」「选股指标」「交易策略」）与 `CaseIterable` / `Identifiable`

* 技术指标 SHALL 继续使用 `Documents/indicator/<周期目录>/*.tdx`；选股与策略 SHALL 使用 `Documents/formula/picker/*.tdx` 与 `Documents/formula/strategy/*.tdx`

* 三类 `.tdx` SHALL 统一带 `KIND=` 头（`TECH` / `PICKER` / `STRATEGY`）；`KIND=` 缺失时 SHALL 按 `TECH` 处理（兼容既有内置模板）

* `SystemIndicatorStore` SHALL 在解析时读取 `KIND=`，仅装载 `TECH`；遇到 `Documents/indicator` 目录内的非 TECH 文件 SHALL 跳过，{不报错、不影响其余指标}

#### Scenario: 选股/策略公式不进 K 线指标列表

* **WHEN** 用户在公式管理中新建 3 个选股公式与 2 个策略公式
* **THEN** 打开 K 线页主图指标面板与副图指标面板，条目集合与新建前完全一致（仍只有技术指标），且不出现任何选股/策略名称

#### Scenario: 目录被手工污染时仍能启动

* **WHEN** 用户通过文件 App 把一个 `KIND=STRATEGY` 的 `.tdx` 拷进 `Documents/indicator/daily/`
* **THEN** 该文件被 `SystemIndicatorStore` 忽略，K 线页不出现该指标，其余指标正常加载，App 不崩溃

#### Scenario: 技术指标文件仍可被旧内容识别

* **WHEN** 磁盘上是既有内置模板（无 `KIND=` 行）
* **THEN** 按 `TECH` 正常装载，`GROUP=` / `COORD=` / `SCOPE=` 行为与现状一致

### Requirement: 选股公式库

系统 SHALL 提供独立于自选分组的选股公式实体与仓库，支持增删改查与测试。

* `FormulaDoc` SHALL 至少包含：`id`（= 文件名，稳定不变）、`kind`、`name`（展示名与公式名，可重命名）、`pickBody`（公式文本）、`pickRef`（仅 strategy 使用）、`rules`（仅 strategy 使用）

* `FormulaLibraryStore` SHALL 为单例 `ObservableObject`，`@Published` 暴露 `pickers` / `strategies`，并提供 `doc(kind:id:)` / `save(_:)` / `rename(kind:id:to:)` / `delete(kind:id:)` / `reload(kind:)` / `formulaText(id:)`

* 新增条目的 `id` SHALL 由仓库生成（`PICK_<n>` / `STR_<n>`，取目录内最大序号 +1），**重命名只改 `NAME=` 行、不改 `id`**，以保证引用不失效

* 测试 SHALL 复用 `TDXFormulaEngine.evaluate`，在编辑器上就地显示每条输出线的最后一根有效值，并给出「命中 / 未命中（最后一根输出值 > 0 即命中）」结论；公式解析失败 SHALL 显示中文错误

* 选股公式跑全市场的能力 SHALL 沿用既有的 `MarketRowCache.matchFormula` 与 `FavoritesStore.refreshFormulaGroup`，本次不新增取数路径

#### Scenario: 新建并测试选股公式

* **WHEN** 用户在公式管理「选股指标」段新建公式 `MA5:=MA(CLOSE,5); MA20:=MA(CLOSE,20); CROSS(MA5,MA20);` 并点「测试公式」
* **THEN** 就地显示输出行最后一根值，并给出命中/未命中结论；点保存后公式出现在选股列表，同时落盘为 `Documents/formula/picker/PICK_1.tdx`

#### Scenario: 重命名不影响自选分组

* **WHEN** 某选股公式被 2 个自选分组引用，用户把它改名为「双均线金叉」
* **THEN** 两个分组仍正常刷新选股，列表与摘要显示新名称，无需重新绑定

#### Scenario: 删除被引用的选股公式有明确提示

* **WHEN** 用户删除一个被 2 个自选分组引用的选股公式
* **THEN** 删除前弹出确认，文案列出被引用的分组名并说明删除后这些分组将变为空；确认删除后，相关分组的 `formulaID` 置空、`cachedMatches` 清空，分组本身保留

### Requirement: 交易策略公式（PICK + RULES 双段）

系统 SHALL 以单文件双段格式定义交易策略公式，并提供解析、校验与语义预览。

* 文件格式 SHALL 为：
  `KIND=STRATEGY` → `NAME=` → 可选 `PICKREF=<选股公式 id>` → 可选 `PICK:` 段（多行公式）→ 必填 `RULES:` 段（多行规则）

* 选股条件 SHALL 支持两种写法且**二选一**：`PICKREF=` 引用选股公式库中的条目，或在 `PICK:` 段内嵌选股表达式。两者同时存在或都不存在 SHALL 校验失败并给出中文原因

* RULES 段每行 SHALL 形如 `KEYWORD(KEY=VAL, KEY=VAL)`，关键字与 `SimCondKind` 的映射 SHALL 为：

  | RULES 关键字      | 对应条件单     | 参数（键 `=` 值）                                          |
  | -------------- | --------- | --------------------------------------------------- |
  | `PRICE`        | 价格条件      | `OP`（`>=` / `<=`）、`VALUE`（触发价）                      |
  | `STOP_LOSS`    | 止盈止损（OCO） | `BASE`（`COST` / `LAST`，默认 `COST`）、`MODE`（`PRICE` / `PCT`）、`PROFIT`、`LOSS` |
  | `TRAILING`     | 回落卖出 / 反弹买入 | `PCT`（幅度）、`FLOOR`（可选保底价）                            |
  | `TIME`         | 时间条件      | `DATE`（`YYYY-MM-DD`）、`AT`（`HH:MM`，可选）                |
  | `CHANGE_PCT`   | 涨跌幅条件     | `PCT`（正 = 涨、负 = 跌）、`OP`（可选，默认 `>=`）                 |
  | `MA_CROSS`     | 均线条件      | `PERIOD`（`5` / `10` / `20` / `60`）、`DIR`（`UP` 上穿 / `DOWN` 下破） |
  | `GRID`         | 网格交易      | `BASE`、`LOW`、`HIGH`、`STEP`（%）、`QTY`、`MULT`（可选，1~5）    |
  | `BATCH`        | 分批建仓 / 卖出  | `TOTAL`（总数量）、`COUNT`（2~5）、`FIRST`（首批价）、`GAP`（每批价差） |

* 校验 SHALL 覆盖：未知关键字（报出行号）、参数缺失、数值越界、同类型规则重复声明、`STOP_LOSS` 的 `PROFIT` / `LOSS` 均为空、`GRID` 的 `LOW >= HIGH`、`GRID` 与 `BATCH` 同时出现、RULES 为空、选股条件缺失。任一失败 SHALL 就地红字展示，不弹 alert

* 预览 SHALL 用一句自然语言复述语义（选股条件摘要 + 各条规则的触发语义清单），并在预览区标注「触发后的下单指令（方向 / 数量 / 报价方式）本阶段未定义，留待接入执行阶段」

* 本阶段 SHALL NOT 生成真实条件单、SHALL NOT 调用 `SimStore.submit`、SHALL NOT 向模拟账户写入任何数据

#### Scenario: 组合规则解析

* **WHEN** RULES 段为
  `STOP_LOSS(BASE=COST, MODE=PCT, PROFIT=10, LOSS=5)`
  `TRAILING(PCT=3)`

* **THEN** 解析出 2 条规则，预览为「止盈 +10% 或 止损 −5% 时触发（以先到者为准）；自突破后回撤 3% 时触发」，且校验通过

#### Scenario: 非法参数被拦截且不落盘

* **WHEN** RULES 段为 `GRID(BASE=14.9, LOW=15.8, HIGH=13.5, STEP=1.5, QTY=300)`
* **THEN** 保存被拒绝，就地红字提示「网格价格区间下界不得高于上界」，不写文件、列表不新增条目

#### Scenario: 规则组合冲突被拦截

* **WHEN** RULES 段同时写 `GRID(...)` 与 `BATCH(...)`
* **THEN** 校验失败并提示「网格交易与分批建仓不宜同一策略并存，请保留其一」

#### Scenario: 引用已删除的选股公式

* **WHEN** 一个策略的 `PICKREF` 指向的选股公式已被删除，用户打开该策略
* **THEN** 编辑器就地红字提示「引用的选股公式已不存在，请重新选择或改用内嵌选股条件」，策略文件保持不损坏

### Requirement: 公式管理页（中心页）

系统 SHALL 提供唯一权威的公式管理页，三分段管理三类公式，并与既有编辑器复用同一套公式输入组件。

* 结构 SHALL 为：导航栏（左「返回」/ 中「公式管理」/ 右「＋ 新建」）+ 三分段控件（技术指标 / 选股指标 / 交易策略）+ 当前段列表；`＋ 新建` 行为随当前段变化（技术指标段 → 跳自定义技术指标编辑器；选股段 → 选股编辑器；策略段 → 策略编辑器）

* 技术指标段 SHALL 分两小节：「系统指标」与「自定义技术指标」，点条目分别进入既有的 `SystemIndicatorEditorContainer` 与 `IndicatorEditSheet`；段顶部 SHALL 标注「仅出现在 K 线图主图 / 副图指标选择中」

* 选股指标段每行 SHALL 显示：名称、公式摘要（单行）、「被 N 个自选分组引用」；行内提供编辑与删除

* 交易策略段每行 SHALL 显示：名称、选股条件摘要（引用则显示「引用：<公式名>」）、「M 条规则」；行内提供编辑与删除

* 页面 SHALL 支持被外部按类型直接打开（默认定位到指定段），供域内跳转使用

* 全部界面 SHALL 沿用项目既有约定：语义色（`Color(.systemBackground)` / `Color(.secondarySystemBackground)`）、命中区 ≥ 44×44pt、iOS 15（不使用 `NavigationStack` / `Table` / `Chart` / `@Observable`）

#### Scenario: 三段互不串味

* **WHEN** 用户在选股段浏览列表
* **THEN** 列表只含选股公式，不出现技术指标名（如 MACD）或策略名

#### Scenario: 中心页可被按类型打开

* **WHEN** 用户从模拟页「策略公式」入口进入
* **THEN** 中心页打开后直接停在「交易策略」段

### Requirement: 公式管理入口

系统 SHALL 在个人中心提供主入口，并在各业务域提供就近跳转入口，所有入口进入同一中心页。

* 个人中心 [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L66-L85) SHALL 新增「公式管理」行，规格与既有主题/布局设置行一致（`secondarySystemBackground` + 圆角 12 + 内边距），点击打开中心页

* 行情「选股」Tab SHALL 在顶部工具区新增「公式」图标按钮（沿用现有 28×28 图标视觉 + 44×44pt 命中区），打开中心页并定位到选股段

* 模拟页三个布局（A / B / C）工具栏 SHALL 各新增「策略公式」入口，打开中心页并定位到交易策略段；按钮组件 SHALL 统一放在 `SimSharedViews.swift` 供三处复用

* K 线页 SHALL **不**新增中心页入口；主图/副图指标面板只保留既有技术指标的就近编辑，并把文案明确为「技术指标公式」（「公式编辑」/「+ 新增/管理」的说明文字）

* 自选分组编辑（[FavAddGroupSheet](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift#L569-L632) / [FavFormulaEditorSheet](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift#L636-L695)）SHALL 不再内嵌公式输入：改为「选择选股公式」（列出公式库条目并单选）+「去公式管理新建」跳转；未选择公式时不允许创建公式分组

#### Scenario: 从模拟页进入策略公式

* **WHEN** 用户在模拟页（任一布局）点「策略公式」
* **THEN** 中心页打开并停在交易策略段，返回后回到模拟页，模拟页状态不丢失

#### Scenario: 自选公式分组不再重复维护公式

* **WHEN** 用户在自选页编辑一个公式分组
* **THEN** 界面上只提供公式库条目的选择与跳转，两处不再各存一份公式文本

### Requirement: 自选公式分组的引用迁移

系统 SHALL 把既有的「自选-公式分组」内嵌公式一次性迁移为对选股公式库的引用，且迁移无损、幂等。

* `FavoritesGroup` SHALL 新增 `formulaID: String?`；`formula: String?` 保留为解码字段，迁移完成后置 `nil`

* `favorites.json` 的 `schemaVersion` SHALL 升级为 2，且解码时逐项兜底（字段缺失不报错）

* 迁移 SHALL 在 `FavoritesStore` 读档后执行：对每个 `kind == .formula` 且 `formulaID == nil` 且内嵌文本非空的分组，在选股公式库中以分组名为名称创建公式（同名冲突则加序号后缀），回写 `formulaID` 并清空 `cachedMatches`；迁移结束 SHALL 立即 `saveToDisk()`

* 迁移 SHALL 幂等：`formulaID` 已存在的分组不再重复导入

* `refreshFormulaGroup` SHALL 改为按 `formulaID` 从公式库取公式文本；取不到（公式被删）SHALL 置空结果并给出「公式已删除，请重新选择」的可视提示，不得崩溃

#### Scenario: 旧档首启无损升级

* **WHEN** 磁盘上是 `schemaVersion 1` 的 `favorites.json`，含 2 个公式分组与 1 个自定义分组
* **THEN** 三个分组全部保留（名称、顺序、隐藏状态不变），两个公式分组已绑定到新创建的选股公式，点「刷新选股」结果与升级前一致；文件被改写为 `schemaVersion 2`

#### Scenario: 重复启动不重复导入

* **WHEN** App 第二次启动（已是 `schemaVersion 2`）
* **THEN** 选股公式库条目数量不变，不产生重复公式

***

## MODIFIED Requirements

### Requirement: K 线页指标选择面板

面板只呈现技术指标公式，且不因选股/策略公式的增删改而改变。

* 主图面板：系统主图指标（`SCOPE=main` 且 `KIND=TECH`）+ 自定义技术指标（主图）；「公式编辑」进入系统技术指标编辑器

* 副图面板：`VOL` / `AMO` 内置项 + 副图池（`SCOPE=sub` 且 `KIND=TECH`，按 `GROUP=` 分组）+ 自定义技术指标（副图）

* 面板内 SHALL 不出现任何选股公式、策略公式或其入口

### Requirement: 自选公式分组的刷新与展示

分组刷新与展示改为基于公式库引用，其余行为（候选池、进度回调、排序、结果缓存）保持不变。

* `refreshFormulaGroup` 的取公式来源改为 `FormulaLibraryStore.formulaText(id:)`

* 公式分组的行内展示 SHALL 显示引用公式的名称；引用失效时显示「公式已删除」并提供「重新选择」入口

***

## UI 设计规范

> 沿用项目既有令牌：页面底色 `Color(.systemBackground)`、分组卡片 `Color(.secondarySystemBackground)`、圆角（卡片 12 / chip 6）、强调色 `Color.blue`、强调红 `Color.red`、命中区 ≥ 44×44pt。线框图中数值为示意。

### 中心页 `FormulaCenterView`

```
┌──────────────────────────────────────────────────┐
│ 返回              公式管理              ＋ 新建  │ 44pt 导航栏
├──────────────────────────────────────────────────┤
│ [ 技术指标 ][ 选股指标 ][ 交易策略 ]              │ 32pt 分段（选中白底+阴影）
├──────────────────────────────────────────────────┤
│ 仅出现在 K 线图主图 / 副图指标选择中              │ 11pt 说明条
│ 系统指标                                          │
│ ┌ MA ────────────── 主图 · daily        > ┐      │ 行卡片：圆角 12，
│ ┌ MACD ──────────── 副图 · 量能          > ┐      │ 底色 secondarySystemBackground，
│ 自定义技术指标                                    │ 上下 padding 12、左右 14
│ ┌ 双均线 ────────── 副图 · 适用范围 全周期 > ┐      │
│ ＋ 新建技术指标                                   │
└──────────────────────────────────────────────────┘
分段切到「选股指标」：
│ ┌ 双均线金叉 ────── MA5:=MA(CLOSE,5); …  ┐        │
│ │                  被 2 个自选分组引用    [编辑][删] │
│ ＋ 新建选股公式                                   │
分段切到「交易策略」：
│ ┌ 趋势回踩策略 ──── 引用：双均线金叉          ┐     │
│ │                  3 条规则：止盈止损 / 回落卖出… [编辑][删] │
│ ＋ 新建策略公式                                   │
```

### 策略编辑器 `StrategyFormulaEditorView`

```
┌──────────────────────────────────────────────────┐
│ 取消            策略公式               测试·保存  │ 44pt
├──────────────────────────────────────────────────┤
│ 名称   [ 趋势回踩策略                     ]       │
├──────────────────────────────────────────────────┤
│ 选股条件   [ 内嵌公式 ][ 引用选股公式 ]            │ 二选一分段
│ （内嵌）公式输入框（复用 FormulaTextView，min 140）│ 引用时替换为下拉列表
├──────────────────────────────────────────────────┤
│ 交易规则（RULES）                        ＋ 添加  │
│ ┌ 止盈止损  BASE[成本价▾] MODE[百分比▾]           │ 每行一条规则：
│ │           PROFIT[10] %  LOSS[5] %      [删]    │ 高 46，左侧类型可下拉切换，
│ ┌ 回落卖出  PCT[3] %  FLOOR[  ]（可选）    [删]   │ 右侧参数就地输入，行间 0.5pt 分隔线
├──────────────────────────────────────────────────┤
│ 预览：对命中【5 日线上穿 20 日线】的标的：止盈 +10% │ 预览卡（一句话 + 灰色补充说明）
│ 或 止损 −5% 先到者触发；回撤 3% 触发。             │
│ ⓘ 触发后的下单指令（方向 / 数量 / 报价方式）本阶段  │
│   未定义，留待接入执行阶段。                       │
├──────────────────────────────────────────────────┤
│ ✗ 第 1 行：网格价格区间下界不得高于上界            │ 校验红字（就地，不弹 alert）
├──────────────────────────────────────────────────┤
│              保存策略公式（蓝底白字）              │ 50pt
└──────────────────────────────────────────────────┘
```

### 交互细节

* 切换「内嵌公式 / 引用选股公式」时保留另一侧的已填内容（切回来还在），保存时只写其中一侧

* 规则行切换类型时只重置该行的参数，不影响其他行与名称、选股条件

* 编辑任一字段即时刷新预览与校验结论；校验不通过时「保存」置灰

* 删除仍在被引用（自选分组引用选股公式）的条目，一律二次确认并列出引用方

***

## 工程与交付约定

* 新增文件全部位于 `Kline/Formula/`，依赖 `PBXFileSystemSynchronizedRootGroup`，无需手工改 `project.pbxproj`

* 三阶段各自独立可编译、可真机演示，每阶段用闭环命令 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`（Windows，退出码 0 / 6 / 7 均可交付）

* 提交信息：`feat(formula): ...` / `fix(formula): ...` / `docs(formula): ...`，每会话结束前推送完毕，不留未提交改动

* 编码自查：`Color.opacity(_:)` 入参为 Double；不遮蔽同名参数；`@Published` 同值赋值加守卫；不在 `body` 内做重计算