# Checklist

> 核验方式：逐条对照实现代码（静态核验，文件 + 行号），必要时用既有公式分组做一次旧档升级自测核对数据。标 ⏳ 的为纯视觉/交互项，需真机确认。
> 本轮闭环构建：阶段一 run=35507868539、阶段二 run=35508522689、阶段三 run=35509393130、验收修正 run=35509886960，均退出码 6（云端构建成功）；因 iPad 锁屏未在前台，四次都未下发安装，真机项待用户解锁后手动部署验证。

## 类型与存储隔离

- [x] `FormulaKind` 三类齐备（技术指标 / 选股指标 / 交易策略），各带中文标题 —— `FormulaKind.swift:14-28`
- [x] 选股公式落 `Documents/formula/picker/*.tdx`、策略公式落 `Documents/formula/strategy/*.tdx`，与技术指标目录 `Documents/indicator/<周期>` 完全不交叉 —— `FormulaKind.swift:73-78`；全仓 grep `Documents/formula|formula/picker|formula/strategy` 仅命中 `FormulaKind.swift:16-17,72,76-77` 与一处注释
- [x] 三类 `.tdx` 均带 `KIND=` 头（`TECH` / `PICKER` / `STRATEGY`）；`KIND=` 缺失按 `TECH` 处理 —— `FormulaKind.swift:277`、`SystemIndicatorStore.swift:71-74,65-73`（头部预扫描）
- [x] `SystemIndicatorStore` 只装载 `KIND=TECH`，目录内非 TECH 文件被跳过且不报错 —— `SystemIndicatorStore.swift:65-73`（任意位置非 TECH 直接 return nil）、`:117,258`（解析失败即跳过）
- [x] `CustomIndicatorStore` 落地 `USER_*.tdx` 与 `saveTemplate` 回写均带 `KIND=TECH` —— `CustomIndicator.swift:111-112`、`SystemIndicatorStore.swift:205-208`
- [x] 技术指标装载路径不读取 `Documents/formula/**`（grep 无交叉引用）—— 同上 grep 结果，`SystemIndicatorStore.swift` 仅 `:74` 引用 `FormulaKind` 类型

## K 线页不串味（核心验收）

- [x] 主图指标面板条目来源仍为 `SCOPE=main && KIND=TECH` + 自定义技术指标（主图） —— `ChartSheetKit.swift:86-87`、`SystemIndicatorStore.swift:191`
- [x] 副图指标面板条目来源仍为 `VOL/AMO` + `SCOPE=sub && KIND=TECH`（按 `GROUP=` 分组）+ 自定义技术指标（副图） —— `ChartSheetKit.swift:198-204,230`
- [x] 面板内无任何选股公式 / 策略公式的名称或入口；K 线页未新增中心页入口 —— `ChartSheetKit.swift` 全文无 `FormulaCenterView` / `FormulaLibraryStore` 引用；`FormulaCenterView` 调用点仅在 FavoritesView / MarketView / ProfileDetailView / Simulation×3
- [ ] ⏳ 真机：新建 3 个选股公式 + 2 个策略公式后，K 线页主/副图指标面板条目与新建前完全一致
- [x] 指标面板文案明确为「技术指标公式」（「公式编辑」/「+ 新增/管理」处有说明） —— `ChartSheetKit.swift:48,58,167`

## 选股公式库

- [x] `FormulaDoc` 含 `id`（= 文件名）、`kind`、`name`、`pickBody`、`pickRef`、`rules` —— `FormulaKind.swift:41-48`
- [x] 新增条目 `id` 为 `PICK_<n>` / `STR_<n>`（目录内最大序号 +1），重命名只改 `NAME=` 不改 `id` —— `FormulaKind.swift:220-233`（nextID）、`:154-171`（rename 沿用原 id）
- [x] 仓库能力齐备：`doc(kind:id:)` / `save` / `rename` / `delete` / `reload` / `formulaText(id:)` —— `FormulaKind.swift:90,98,130,154,173,188,103`
- [x] 编辑器 picker 模式隐藏作用域、适用范围、线条样式与颜色，只保留名称/公式/符号/测试/保存/取消 —— `FormulaEditorView.swift:318,341,391`（三处 `if !isPicker`）、`:283-285`（恢复按钮也隐藏）
- [x] 「测试公式」复用 `TDXFormulaEngine.evaluate`，显示输出行最后一根值并给出「命中 / 未命中（>0 命中）」结论；解析失败显示中文错误 —— `FormulaKind.swift:252-272`、`FormulaEditorView.swift:470-481`
- [x] 选股跑批未新增取数路径，仍走 `MarketRowCache.matchFormula` —— `FavoritesStore.swift:409,420`

## 交易策略公式

- [x] 文件格式为 `KIND=STRATEGY` / `NAME=` / 可选 `PICKREF=` / 可选 `PICK:` / 必填 `RULES:` —— `FormulaKind.swift:276-291`
- [x] `StrategyRuleKind` 8 种与 `SimCondKind` 一一对应，参数键与 `SimCondParams` 字段语义一致 —— `StrategyFormula.swift:25-33,104-183`（目录表逐类注释映射）
- [x] 解析器识别 `KEYWORD(KEY=VAL, ...)`，忽略空行与注释，未知关键字报出行号 —— `StrategyFormula.swift:212-275`（`:220-221` 跳过空行/注释、`:239` 未知规则带行号、`:265` 未识别参数）
- [x] 校验覆盖：选股条件缺失、`PICKREF` 与内嵌 `PICK` 同时存在、RULES 为空、参数缺失、数值越界、同类型重复、`STOP_LOSS` 双腿皆空、`GRID` 的 `LOW >= HIGH`、`GRID` 与 `BATCH` 并存 —— `StrategyFormula.swift:315,319,323,327,333,338,342,351,374,377-399,406`
- [x] 预览为一句自然语言（选股条件摘要 + 规则触发语义清单），并带「下单指令本阶段未定义」的补充说明 —— `StrategyFormula.swift:440,443-455`；编辑器 `StrategyFormulaEditorView.swift:553,557`
- [x] 本阶段不生成条件单、不调用 `SimStore.submit`、不向模拟账户写入数据（grep 无相关调用）—— `Kline/Formula` 下 grep `SimStore|submit(|SimCondOrder|SimCondEngine` 仅命中注释
- [x] 校验失败就地红字、保存置灰，不弹 alert —— `StrategyFormulaEditorView.swift:570-589`、`:182,219`（disabled）、全文无 `.alert`
- [x] 引用的选股公式被删除时，编辑器给出「引用的选股公式已不存在」提示且文件不损坏 —— `StrategyFormula.swift:323-325`、`StrategyFormulaEditorView.swift:120-124,795-801`

## 公式管理页与入口

- [x] 中心页三段（技术指标 / 选股指标 / 交易策略）互不串味，`＋ 新建` 随当前段变化 —— `FormulaCenterView.swift:88-92`（switch kind）、`:520-533`（newAction）
- [x] 技术指标段分「系统指标」「自定义技术指标」两小节，分别进入 `SystemIndicatorEditorContainer` 与 `IndicatorEditSheet` —— `FormulaCenterView.swift:191,194,444,422`
- [x] 中心页支持按类型打开（`initialKind`），域内跳转能直接落到对应段 —— `FormulaCenterView.swift:71-75`
- [x] 个人中心出现「公式管理」行，规格与既有主题/布局行一致，点击打开中心页 —— `ProfileDetailView.swift:86-90`、`FormulaCenterView.swift:16-35`
- [x] 行情「选股」Tab 工具区新增「公式」入口（28×28 视觉 + 44×44pt 命中区），二级胶囊栏（趋势/震荡/反转/情绪）保持原样 —— `MarketView.swift:337-347`（`if topMenu == .picker` 内 44×44 + contentShape，外层 28×28）；`secondLevelBar` 未改动
- [x] 模拟页 A/B/C 三布局工具栏均有「策略公式」入口，统一组件放在 `SimSharedViews.swift` —— `SimSharedViews.swift:899-912`、`SimulationLayoutAView.swift:305`、`BView.swift:114`、`CView.swift:232`
- [x] 全部新界面使用语义色，深色模式可读；可点击元素命中区 ≥ 44×44pt；无 `NavigationStack` / `Table` / `Chart` / `@Observable` —— `Kline/Formula` 下 grep 四个禁用 API 零命中；`Color.white/black` 仅用于蓝底白字与 `.opacity` 阴影/遮罩

## 自选引用迁移

- [x] `FavoritesGroup` 新增 `formulaID: String?`，`favorites.json` 的 `schemaVersion` 升级为 2，解码逐项兜底 —— `FavoritesStore.swift:35,105`（currentSchema=2）、`:181-184`（旧版本打回写标记）；公式相关字段全 Optional，合成解码走 `decodeIfPresent`
- [x] 读档后自动迁移：公式分组建同名选股公式 → 回写 `formulaID` → 清空内嵌 `formula` 与 `cachedMatches` → 写盘一次 —— `FavoritesStore.swift:112-117,129-160`
- [x] 迁移幂等：`formulaID != nil` 与已是 schemaVersion 2 的档都不重复导入 —— `FavoritesStore.swift:132`；版本 2 的档无内嵌文本可迁移，`migrated == false`
- [x] `refreshFormulaGroup` 改为按 `formulaID` 取公式文本，取不到时置空结果并给出「公式已删除，请重新选择」，不崩溃 —— `FavoritesStore.swift:386-396`
- [x] 删除被引用的选股公式有二次确认并列出引用分组名，确认后清空相关分组的 `formulaID` 与 `cachedMatches` —— `FormulaCenterView.swift:332-335,556-570`、`FavoritesStore.swift:260-267`
- [x] 自选新增/编辑公式分组不再内嵌公式输入，改为选择公式库条目 + 「去公式管理新建」；未选公式不允许创建 —— `FavoritesView.swift:605-612,629,674-716,808-813`
- [x] 自选页公式分组行显示引用公式名称，引用失效时显示「公式已删除」+「重新选择」 —— `FavoritesView.swift:539,549-558`、`FavoritesStore.swift:251`
- [ ] ⏳ 真机：用既有公式分组验证旧档升级——分组名/顺序/隐藏状态不变，点「刷新选股」结果与升级前一致；杀 App 重启后公式不重复

## 工程与交付

- [x] 新增文件全部位于 `Kline/Formula/`，diff 不含 `project.pbxproj` —— `git diff --name-only HEAD~4..HEAD` 无 `project.pbxproj`；4 个新文件均在 `Kline/Formula/`
- [x] 阶段一闭环命令返回 0 / 6 / 7 —— run=35507868539，退出码 6（构建成功）
- [x] 阶段二闭环命令返回 0 / 6 / 7 —— run=35508522689，退出码 6（构建成功）
- [x] 阶段三闭环命令返回 0 / 6 / 7 —— run=35509393130，退出码 6（构建成功）
- [x] 验收修正（Task 15）闭环返回 0 / 6 / 7 —— run=35509886960，退出码 6（构建成功）
- [x] 每阶段交付说明含 build 号、改动与原因、真机验证路径与回归点；`git status` 无遗留未提交改动 —— 见最终交付说明；本 spec 文档已提交（`.trae/specs/add-conditional-orders/checklist.md` 为本次开工前即存在的他人未提交改动，未触碰）

## 待真机验证（用户解锁 iPad 后部署）

- ⏳ K 线页主/副图指标面板不因选股/策略公式增删而改变（核心验收）
- ⏳ 旧档公式分组升级：分组保留、刷新选股结果一致、二次启动不重复导入
- ⏳ 公式管理三段入口（个人中心 / 行情选股 Tab / 模拟页三布局）与「返回」行为
- ⏳ 策略公式编辑器：8 种规则动态参数、内嵌/引用切换、预览与校验红字
- ⏳ 自选 → 「去公式管理新建」的 sheet → fullScreenCover → overlay 三层呈现栈的键盘与点击响应