# Tasks

## 阶段一：公式类型隔离 + 公式管理页骨架

- [x] Task 1: 新增公式类型与公式库仓库 `Kline/Formula/FormulaKind.swift`
  - [x] SubTask 1.1: 定义 `FormulaKind`（`tech` / `picker` / `strategy`，各带中文标题「技术指标」「选股指标」「交易策略」，`CaseIterable` + `Identifiable`），并写明三类各自的目录与 `KIND=` 取值
  - [x] SubTask 1.2: 定义公式文档值类型 `FormulaDoc`：`id`（= 文件名，稳定不变）、`kind`、`name`、`pickBody`、`pickRef`（仅 strategy）、`rules`（仅 strategy）
  - [x] SubTask 1.3: 定义 `FormulaLibraryStore: ObservableObject` 单例：`@Published private(set) var pickers` / `strategies`；目录 `Documents/formula/picker` 与 `Documents/formula/strategy`（`FileManager.urls(for:.documentDirectory)` + `createDirectory(withIntermediateDirectories:true)`）
  - [x] SubTask 1.4: 实现 `.tdx` 序列化/解析：`serialize(doc:)` 输出 `KIND=` / `NAME=` /（strategy 才有）`PICKREF=` / `PICK:` / `RULES:`；`parse(content:id:kind:)` 逐段解析，缺 `KIND=` 或与目录不符的文件跳过
  - [x] SubTask 1.5: 实现 `save(_:)` / `doc(kind:id:)` / `rename(kind:id:to:)`（只改 `NAME=`，不改 `id`）/ `delete(kind:id:)` / `reload(kind:)` / `formulaText(id:)`；新增 `id` 取目录内 `PICK_<n>` / `STR_<n>` 最大序号 +1；文件名安全化复用 `CustomIndicatorStore.sanitized`
  - [x] SubTask 1.6: 测试求值复用 `TDXFormulaEngine.evaluate(formula:data:)`，提供 `testPicker(formula:data:) -> (lines:[TDXOutputLine], hit:Bool, error:String?)`

- [x] Task 2: 技术指标装载侧加 `KIND=` 硬隔离
  - [x] SubTask 2.1: [SystemIndicatorStore.parse](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/SystemIndicatorStore.swift#L58-L92) 解析 `KIND=`，非 `TECH`（含未知值）返回 nil；缺省视为 `TECH`
  - [x] SubTask 2.2: `loadAllPeriods()` / `reload(period:)` 跳过非 TECH 文件且不报错（保持既有目录扫描结构）
  - [x] SubTask 2.3: [CustomIndicatorStore.materializeTDX](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/CustomIndicator.swift#L106-L124) 落地内容改为以 `KIND=TECH` 开头；`SystemIndicatorStore.saveTemplate` 写回时同样保留 `KIND=TECH`
  - [x] SubTask 2.4: 自查：不扫描 `Documents/formula/**`，不引入任何技术指标与选股/策略目录的交叉读取

- [x] Task 3: 公式管理页骨架 `Kline/Formula/FormulaCenterView.swift`
  - [x] SubTask 3.1: 页面骨架：导航栏（「返回」/「公式管理」/「＋ 新建」）+ 三段分段控件（技术指标 / 选股指标 / 交易策略）+ 当前段内容；支持 `initialKind` 入参以便被按类型打开
  - [x] SubTask 3.2: 技术指标段：「仅出现在 K 线图主图 / 副图指标选择中」说明条 + 「系统指标」小节（`SystemIndicatorStore.mainIndicatorDefs` / `subIndicatorDefs`，标题显示 `名称 · 主图/副图 · 组`）+ 「自定义技术指标」小节（`CustomIndicatorStore.indicators`）
  - [x] SubTask 3.3: 技术指标段的点击行为复用既有编辑器：系统指标 → `SystemIndicatorEditorContainer`；自定义 → `IndicatorEditSheet`（`isSystemIndicator: false`）；「＋ 新建」在技术指标段进入自定义技术指标编辑器
  - [x] SubTask 3.4: 选股指标段与交易策略段先落列表骨架（名称 + 摘要 + 角标信息 + 行内编辑/删除按钮），编辑动作先弹占位提示，待阶段二/三接真实编辑器
  - [x] SubTask 3.5: 全页语义色 + 命中区 ≥ 44×44pt + iOS 15 兼容（不用 `NavigationStack` / `Table` / `Chart` / `@Observable`）

- [x] Task 4: 个人中心主入口
  - [x] SubTask 4.1: 新增 `FormulaCenterSettingRow`（标题「公式管理」+ 右侧 `chevron.right`），规格对齐 [KlineThemeSettingRow](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L66-L70) 同层的既有行（`secondarySystemBackground` + 圆角 12 + `padding`）
  - [x] SubTask 4.2: 在 [ProfileDetailView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L66-L86) 的 ScrollView 内主题行下方插入该行，并用全屏 overlay 承载 `FormulaCenterView`（沿用既有 overlay + `zIndex` + `.transition(.opacity)` 惯例）

- [x] Task 5: 阶段一闭环
  - [x] SubTask 5.1: 编码自查（`Color.opacity` 入参 Double、不遮蔽同名参数、`@Published` 同值赋值加守卫、不在 `body` 内重算）
  - [x] SubTask 5.2（run=35507868539，退出码 6 构建成功）: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(formula): 公式类型隔离·选股/策略公式库·公式管理页骨架"`
  - [x] SubTask 5.3: 交付说明（build 号 / 改动与原因 / 真机验证路径），等待用户验收（见最终交付说明）

## 阶段二：选股公式库 + 自选引用迁移

- [x] Task 6: 选股公式编辑器（复用 `IndicatorEditSheet` 的 picker 模式）
  - [x] SubTask 6.1: [IndicatorEditSheet](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Formula/FormulaEditorView.swift#L148-L229) 新增 `mode: .picker` 分支：只保留「名称 / 公式 / 常用符号 / 全选 / 清空 / 测试公式 / 保存 / 取消」，隐藏作用域、适用范围、线条样式与颜色
  - [x] SubTask 6.2: picker 模式的「测试公式」调用 `FormulaLibraryStore.testPicker`，提示文案为「✓ 解析成功 · 输出 X：<最后一根值> · 命中 / 未命中（最后一根 > 0 视为命中）」或「✗ <中文错误>」
  - [x] SubTask 6.3: 中心页选股段的「＋ 新建」与行内编辑接上该编辑器，保存走 `FormulaLibraryStore.save`

- [x] Task 7: 选股公式库与自选的引用迁移
  - [x] SubTask 7.1: [FavoritesGroup](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift#L25-L51) 新增 `formulaID: String?`；`FavoritesRoot.schemaVersion` 升级为 2（`currentSchema = 2`），解码保持逐项兜底
  - [x] SubTask 7.2: `loadFromDisk()` 成功后执行 `migrateFormulaGroupsIfNeeded()`：对 `kind == .formula && formulaID == nil && 内嵌文本非空` 的分组，在选股库建同名公式（重名加序号后缀）→ 回写 `formulaID` → `formula = nil` → `cachedMatches = nil`；迁移有条目变动时 `saveToDisk()`
  - [x] SubTask 7.3: 迁移幂等：`formulaID != nil` 直接跳过；`schemaVersion` 已是 2 时不重复导入
  - [x] SubTask 7.4: [refreshFormulaGroup](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift#L301-L359) 改为按 `formulaID` 从 `FormulaLibraryStore.formulaText(id:)` 取公式文本；取不到时置 `cachedMatches = []` 并回传失败原因（不崩溃）
  - [x] SubTask 7.5: 中心页删除选股公式前，扫描 `FavoritesStore.groups` 的被引用分组并二次确认（文案列出分组名）；确认后清空相关分组的 `formulaID` 与 `cachedMatches`

- [x] Task 8: 自选分组编辑器改为「引用公式」
  - [x] SubTask 8.1: [FavAddGroupSheet](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift#L569-L632) 的公式类型分支：移除内嵌 `TextEditor`，改为选股公式单选列表 + 「去公式管理新建」；未选公式不允许创建
  - [x] SubTask 8.2: [FavFormulaEditorSheet](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift#L636-L695) 同样改为「选择公式库条目」+ 跳转；保存时写入 `formulaID` 并清空旧结果
  - [x] SubTask 8.3: 自选页公式分组行的展示改用引用公式名称；引用失效时显示「公式已删除」+「重新选择」入口

- [x] Task 9: 行情「选股」Tab 入口
  - [x] SubTask 9.1: [MarketView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketView.swift#L295-L331) 顶部工具区新增「公式」图标按钮（视觉对齐既有 28×28 图标，命中区 44×44pt），点击打开中心页并定位到选股段；二级胶囊栏（趋势/震荡/反转/情绪）保持原样不动

- [ ] Task 10: 阶段二闭环
  - [ ] SubTask 10.1: 用既有公式分组做一次旧档升级自测（分组保留、刷新结果一致、二次启动不重复导入）——⏳ 需真机：四次云端构建均因 iPad 锁屏未下发安装，待解锁后手动部署验证（静态核验见 checklist「自选引用迁移」节）
  - [x] SubTask 10.2（run=35508522689，退出码 6 构建成功）: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(formula): 选股公式库·自选公式分组引用迁移·选股入口"`
  - [x] SubTask 10.3: 交付说明，等待用户验收（见最终交付说明）

## 阶段三：交易策略公式（PICK + RULES）

- [x] Task 11: 策略规则目录与解析校验 `Kline/Formula/StrategyFormula.swift`
  - [x] SubTask 11.1: 定义 `StrategyRuleKind`（8 种）与 `StrategyRuleCatalog`：中文标题、`SimCondKind` 映射注释、参数键表（`PRICE`/`STOP_LOSS`/`TRAILING`/`TIME`/`CHANGE_PCT`/`MA_CROSS`/`GRID`/`BATCH`，键名与取值域严格对齐 [SimCondParams](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimConditionModels.swift#L148-L180)）
  - [x] SubTask 11.2: 定义 `StrategyRuleCall { kind, params: [String: String], raw }` 与 `StrategyRuleParser.parse(lines:) -> ([StrategyRuleCall], [String])`：识别 `KEYWORD(KEY=VAL, ...)`、忽略空行与 `{注释}`、未知关键字报出行号、参数名未识别时报错
  - [x] SubTask 11.3: 定义 `StrategyValidator.validate(doc:) -> [String]`：选股条件缺失 / `PICKREF` 与内嵌 `PICK` 同时存在 / RULES 为空 / 参数缺失 / 数值越界（`COUNT` 2~5、`STEP`>0、`PCT`>0）/ 同类型重复 / `STOP_LOSS` 双腿皆空 / `GRID` 的 `LOW >= HIGH` / `GRID` 与 `BATCH` 并存
  - [x] SubTask 11.4: 定义 `StrategyPreview.summary(doc:pickerName:) -> String`：选股条件摘要 + 各规则的中文触发语义清单 + 固定补充说明「触发后的下单指令（方向 / 数量 / 报价方式）本阶段未定义，留待接入执行阶段」
  - [x] SubTask 11.5: 内嵌 `PICK:` 段的语法校验复用 `TDXFormulaEngine.evaluate`（在编辑器数据上跑一次）；`PICKREF` 指向已删除公式时输出「引用的选股公式已不存在，请重新选择或改用内嵌选股条件」

- [x] Task 12: 策略编辑器 `Kline/Formula/StrategyFormulaEditorView.swift`
  - [x] SubTask 12.1: 页面骨架：名称输入 + 选股条件二选一分段（内嵌公式 / 引用选股公式）+ 规则列表 + 预览卡 + 校验红字 + 保存
  - [x] SubTask 12.2: 内嵌模式复用 `FormulaTextView` + `FormulaInputController`（min 高 140）；引用模式为选股公式单选列表（显示名称 + 摘要）
  - [x] SubTask 12.3: 规则行：类型下拉（8 种）+ 按 `StrategyRuleCatalog` 动态渲染参数输入（数值用步进/文本框，枚举用分段或下拉），行内删除，「＋ 添加规则」追加；切换类型只重置该行参数
  - [x] SubTask 12.4: 编辑即时刷新预览与校验；校验不通过时保存置灰；保存序列化写回 `Documents/formula/strategy/STR_<n>.tdx`
  - [x] SubTask 12.5: 文案明确本阶段不执行：预览区与保存成功提示均带「仅定义与校验，不会生成条件单或下单」

- [x] Task 13: 中心页交易策略段接真实编辑器 + 模拟页入口
  - [x] SubTask 13.1: 中心页策略段接 `StrategyFormulaEditorView`（新建 / 编辑 / 删除），列表行显示「选股条件摘要 + M 条规则」
  - [x] SubTask 13.2: [SimSharedViews.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimSharedViews.swift) 新增 `SimStrategyFormulaEntryButton`（44×44pt 命中区、语义色）
  - [x] SubTask 13.3: 在 `SimulationLayoutAView` / `BView` / `CView` 三处工具栏挂该入口，打开中心页并定位到交易策略段

- [x] Task 14: 阶段三闭环
  - [x] SubTask 14.1: 自测 8 种规则的解析/校验/预览（含非法参数与组合冲突），并确认策略公式不出现在 K 线页指标面板（静态核验：`StrategyFormula.swift:315-409` 覆盖 12 条校验；`Kline/Formula` 下无 `SimStore` 调用；`ChartSheetKit.swift` 无选股/策略引用）
  - [x] SubTask 14.2（run=35509393130，退出码 6 构建成功）: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(formula): 交易策略公式·PICK+RULES 解析校验预览·模拟页入口"`
  - [x] SubTask 14.3: 交付说明，等待用户验收（见最终交付说明）

# Task Dependencies

## 验收修正（对照 checklist 静态核验发现的缺口）

- [x] Task 15: 核验缺口修正
  - [x] SubTask 15.1: `favorites.json` 的 `schemaVersion` 升级写回：读到旧版本（< 2）时，即使没有公式分组可迁移，也要把档改写为 2
  - [x] SubTask 15.2: `IndicatorEditSheet` 选股模式下隐藏「恢复编译时内容」按钮（该按钮只对系统指标有意义）
  - [x] SubTask 15.3: `SystemIndicatorStore.parse` 增加头部预扫描：文件任意位置出现 `KIND=` 且非 TECH 即不装载（防止手工把策略/选股内容粘进指标目录、`KIND=` 落在 `FORMULA:` 之后时漏判）
  - [x] SubTask 15.4: 策略编辑器：内嵌选股公式非空但样例行情未就绪时，就地提示「样例行情未就绪，语法校验待行情到达后进行」（不置灰保存）

- Task 2 依赖 Task 1（`FormulaKind` 与序列化先定型）
- Task 3 依赖 Task 1；Task 4 依赖 Task 3
- Task 6 / Task 7 依赖 Task 1、Task 3（编辑器与列表骨架先就位）
- Task 8 依赖 Task 7（引用模型先落地）
- Task 9 依赖 Task 3
- Task 11 依赖 Task 1（`FormulaDoc` 的 `pickRef` / `rules` 字段）
- Task 12 依赖 Task 6（公式输入组件复用约定）、Task 11
- Task 13 依赖 Task 12
- 阶段一（Task 1-5）、阶段二（Task 6-10）、阶段三（Task 11-14）严格串行；阶段内 Task 2 与 Task 3/4 可并行，Task 6 与 Task 7 可并行