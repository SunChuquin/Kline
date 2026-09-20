# Checklist

> 核验方式：逐条对照实现代码（静态核验，文件 + 行号），必要时用既有公式分组做一次旧档升级自测核对数据。标 ⏳ 的为纯视觉/交互项，需真机确认。

## 类型与存储隔离

- [ ] `FormulaKind` 三类齐备（技术指标 / 选股指标 / 交易策略），各带中文标题 —— `FormulaKind.swift`
- [ ] 选股公式落 `Documents/formula/picker/*.tdx`、策略公式落 `Documents/formula/strategy/*.tdx`，与技术指标目录 `Documents/indicator/<周期>` 完全不交叉 —— `FormulaLibraryStore.swift`
- [ ] 三类 `.tdx` 均带 `KIND=` 头（`TECH` / `PICKER` / `STRATEGY`）；`KIND=` 缺失按 `TECH` 处理 —— `FormulaLibraryStore.serialize`、`SystemIndicatorStore.parse:58-92`
- [ ] `SystemIndicatorStore` 只装载 `KIND=TECH`，目录内非 TECH 文件被跳过且不报错 —— `SystemIndicatorStore.swift:58-92,96-121`
- [ ] `CustomIndicatorStore` 落地 `USER_*.tdx` 与 `saveTemplate` 回写均带 `KIND=TECH` —— `CustomIndicator.swift:106-124`、`SystemIndicatorStore.swift:198-206`
- [ ] 技术指标装载路径不读取 `Documents/formula/**`（grep 无交叉引用）

## K 线页不串味（核心验收）

- [ ] 主图指标面板条目来源仍为 `SCOPE=main && KIND=TECH` + 自定义技术指标（主图） —— `ChartSheetKit.swift:41-88`
- [ ] 副图指标面板条目来源仍为 `VOL/AMO` + `SCOPE=sub && KIND=TECH`（按 `GROUP=` 分组）+ 自定义技术指标（副图） —— `ChartSheetKit.swift:142-230`
- [ ] 面板内无任何选股公式 / 策略公式的名称或入口；K 线页未新增中心页入口 —— `ChartSheetKit.swift` 全文核验
- [ ] ⏳ 真机：新建 3 个选股公式 + 2 个策略公式后，K 线页主/副图指标面板条目与新建前完全一致
- [ ] 指标面板文案明确为「技术指标公式」（「公式编辑」/「+ 新增/管理」处有说明） —— `ChartSheetKit.swift:56-76,164-186`

## 选股公式库

- [ ] `FormulaDoc` 含 `id`（= 文件名）、`kind`、`name`、`pickBody`、`pickRef`、`rules` —— `FormulaKind.swift`
- [ ] 新增条目 `id` 为 `PICK_<n>` / `STR_<n>`（目录内最大序号 +1），重命名只改 `NAME=` 不改 `id` —— `FormulaLibraryStore.swift`
- [ ] 仓库能力齐备：`doc(kind:id:)` / `save` / `rename` / `delete` / `reload` / `formulaText(id:)` —— `FormulaLibraryStore.swift`
- [ ] 编辑器 picker 模式隐藏作用域、适用范围、线条样式与颜色，只保留名称/公式/符号/测试/保存/取消 —— `FormulaEditorView.swift` picker 分支
- [ ] 「测试公式」复用 `TDXFormulaEngine.evaluate`，显示输出行最后一根值并给出「命中 / 未命中（>0 命中）」结论；解析失败显示中文错误 —— `FormulaLibraryStore.testPicker`、picker 编辑器
- [ ] 选股跑批未新增取数路径，仍走 `MarketRowCache.matchFormula` —— `FavoritesStore.swift:301-359`

## 交易策略公式

- [ ] 文件格式为 `KIND=STRATEGY` / `NAME=` / 可选 `PICKREF=` / 可选 `PICK:` / 必填 `RULES:` —— `FormulaLibraryStore.serialize`
- [ ] `StrategyRuleKind` 8 种与 `SimCondKind` 一一对应，参数键与 `SimCondParams` 字段语义一致 —— `StrategyFormula.swift` 目录表
- [ ] 解析器识别 `KEYWORD(KEY=VAL, ...)`，忽略空行与注释，未知关键字报出行号 —— `StrategyRuleParser.parse`
- [ ] 校验覆盖：选股条件缺失、`PICKREF` 与内嵌 `PICK` 同时存在、RULES 为空、参数缺失、数值越界、同类型重复、`STOP_LOSS` 双腿皆空、`GRID` 的 `LOW >= HIGH`、`GRID` 与 `BATCH` 并存 —— `StrategyValidator.validate`
- [ ] 预览为一句自然语言（选股条件摘要 + 规则触发语义清单），并带「下单指令本阶段未定义」的补充说明 —— `StrategyPreview.summary`
- [ ] 本阶段不生成条件单、不调用 `SimStore.submit`、不向模拟账户写入数据（grep 无相关调用）
- [ ] 校验失败就地红字、保存置灰，不弹 alert —— `StrategyFormulaEditorView.swift`
- [ ] 引用的选股公式被删除时，编辑器给出「引用的选股公式已不存在」提示且文件不损坏 —— `StrategyValidator`

## 公式管理页与入口

- [ ] 中心页三段（技术指标 / 选股指标 / 交易策略）互不串味，`＋ 新建` 随当前段变化 —— `FormulaCenterView.swift`
- [ ] 技术指标段分「系统指标」「自定义技术指标」两小节，分别进入 `SystemIndicatorEditorContainer` 与 `IndicatorEditSheet` —— `FormulaCenterView.swift`
- [ ] 中心页支持按类型打开（`initialKind`），域内跳转能直接落到对应段 —— `FormulaCenterView.swift`
- [ ] 个人中心出现「公式管理」行，规格与既有主题/布局行一致，点击打开中心页 —— `ProfileDetailView.swift`
- [ ] 行情「选股」Tab 工具区新增「公式」入口（28×28 视觉 + 44×44pt 命中区），二级胶囊栏（趋势/震荡/反转/情绪）保持原样 —— `MarketView.swift`
- [ ] 模拟页 A/B/C 三布局工具栏均有「策略公式」入口，统一组件放在 `SimSharedViews.swift` —— `SimSharedViews.swift`、`SimulationLayoutAView/BView/CView.swift`
- [ ] 全部新界面使用语义色，深色模式可读；可点击元素命中区 ≥ 44×44pt；无 `NavigationStack` / `Table` / `Chart` / `@Observable` —— 三个新文件全文核验

## 自选引用迁移

- [ ] `FavoritesGroup` 新增 `formulaID: String?`，`favorites.json` 的 `schemaVersion` 升级为 2，解码逐项兜底 —— `FavoritesStore.swift:25-60,63-159`
- [ ] 读档后自动迁移：公式分组建同名选股公式 → 回写 `formulaID` → 清空内嵌 `formula` 与 `cachedMatches` → 立即存盘 —— `FavoritesStore.migrateFormulaGroupsIfNeeded`
- [ ] 迁移幂等：`formulaID != nil` 与已是 schemaVersion 2 的档都不重复导入 —— `FavoritesStore.swift`
- [ ] `refreshFormulaGroup` 改为按 `formulaID` 取公式文本，取不到时置空结果并给出「公式已删除，请重新选择」，不崩溃 —— `FavoritesStore.swift:301-359`
- [ ] 删除被引用的选股公式有二次确认并列出引用分组名，确认后清空相关分组的 `formulaID` 与 `cachedMatches` —— `FormulaCenterView.swift`
- [ ] 自选新增/编辑公式分组不再内嵌公式输入，改为选择公式库条目 + 「去公式管理新建」；未选公式不允许创建 —— `FavoritesView.swift:569-695`
- [ ] 自选页公式分组行显示引用公式名称，引用失效时显示「公式已删除」+「重新选择」 —— `FavoritesView.swift`
- [ ] ⏳ 真机：用既有公式分组验证旧档升级——分组名/顺序/隐藏状态不变，点「刷新选股」结果与升级前一致；杀 App 重启后公式不重复

## 工程与交付

- [ ] 新增文件全部位于 `Kline/Formula/`，diff 不含 `project.pbxproj`
- [ ] 阶段一闭环命令返回 0 / 6 / 7 —— 记录 run 号
- [ ] 阶段二闭环命令返回 0 / 6 / 7 —— 记录 run 号
- [ ] 阶段三闭环命令返回 0 / 6 / 7 —— 记录 run 号
- [ ] 每阶段交付说明含 build 号、改动与原因、真机验证路径与回归点；`git status` 无遗留未提交改动