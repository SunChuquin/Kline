# Tasks

## 阶段一：模型可变 + 编解码 + 仓库写接口（零 UI 变化）

- [x] Task 1: `Kline/App/PageLayout/PageLayoutSchema.swift` 升级为可编辑模型
  - [x] SubTask 1.1: `PageLayoutNode` 全字段 `let` → `var`；新增 `let uuid: UUID` + `var id: UUID { uuid }`（满足 `Identifiable`；编辑期身份，`init(from:)` 里生成、`encode(to:)` 不输出）
  - [x] SubTask 1.2: `PageLayoutNode` 实现 `Encodable`：`encode(to:)` **只输出与 `type` 相关的字段**；原有 `Decodable` 白名单校验保留（未知 `type` 仍抛 `dataCorruptedError`）
  - [x] SubTask 1.3: `PageLayoutPadding`：字段 `var` + `init(top:leading:bottom:trailing:)`（默认 0）+ `static let zero` + 实现 `Encodable`（**只输出非 0 的边**）；`PageLayoutWidth` 实现 `Encodable`（`"infinity"` / 数字）
  - [x] SubTask 1.4: `WidgetParams.values` 由 `private let` → `var`、加 `isEmpty`；`WidgetParamValue` 加 `Encodable`；`WidgetParams` / `PageLayoutWidth` 加 `Equatable`；`PageLayoutDefinition` / `PageLayoutFile` 字段 `var` + `Codable`（`defaultLayoutID` 双向映射 `"default"`）
  - [x] SubTask 1.5: 新增节点工厂 `static func make(type:)`（白名单外返回 nil），9 种类型默认值齐备
  - [x] SubTask 1.6: 新增 `ContainerKey` / `containerKey` / `childList` / `appendChild`（`.child` 已有子节点时替换并返回 true）/ `removeChild(uuid:)` / `flattened()` / `firstNode(uuid:)` / `firstParent(of:)`
  - [x] SubTask 1.7: 向后兼容：`PageLayoutRenderer` / `HomeWidgetRegistry` / `HomeView` / `Widgets/` 控件**一行未改**即编译通过（run=35621629404）

- [x] Task 2: 新增 `Kline/App/PageLayout/PageLayoutCodec.swift`
  - [x] SubTask 2.1: `static func decode(_ text: String) -> PageLayoutFile?`
  - [x] SubTask 2.2: `static func encode(_ file: PageLayoutFile) -> String?`：`JSONEncoder` + `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`
  - [x] SubTask 2.3: `static func canonicalText(_ file: PageLayoutFile) -> String?`（与 `encode` 同一口径）
  - [x] SubTask 2.4: 顶部注释写明「唯一编解码口径」；阶段二追加 `decodeResult(_:)`（把失败原因带出来供 JSON 页签展示），`decode` 改为复用它

- [x] Task 3: `Kline/App/PageLayout/PageLayoutConfigStore.swift` 补齐写接口
  - [x] SubTask 3.1: 私有 `decode(_:)` 删除，`reload` 改走 `PageLayoutCodec.decode`
  - [x] SubTask 3.2: `@discardableResult func save(_ file: PageLayoutFile, page: String) -> Bool`：编码 → 写沙盒（`write(text:to:)` 改为返回 `Bool`）→ `apply`（同值不写）→ `syncModDate`
  - [x] SubTask 3.3: `func builtInText(page: String) -> String?`
  - [x] SubTask 3.4: `@discardableResult func resetToBuiltIn(page: String) -> Bool`（未注册 / 解码失败 / 写失败均返回 false，不崩溃）
  - [x] SubTask 3.5: `func currentFile(page: String) -> PageLayoutFile?`
  - [x] SubTask 3.6: 文件头注释更新为「读 + 写」，写明同步 mtime 与回退链不变

- [x] Task 4: 阶段一闭环
  - [x] SubTask 4.1: 编码自查（引擎目录内零 `Home*` 引用；`PageLayoutRenderer` 用到的 14 个字段名与类型全部保持一致）
  - [x] SubTask 4.2: `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "refactor(page-layout): 配置模型可编辑化 + 编解码与仓库写接口（零 UI 变化）"` —— exit 6 云端构建成功 **run=35621629404**（设备锁屏未安装）
  - [x] SubTask 4.3: 交付说明（见最终交付说明；真机验证路径：四档呈现与回退行为不变、首页可用）

## 阶段二：编辑器可用（入口 + 页面 + 改参数与顺序 + 双预览 + 保存）

- [x] Task 5: 首页控件可编辑参数描述表 `Kline/Home/Editor/HomeWidgetEditorSchema.swift`
  - [x] SubTask 5.1: `WidgetParamDescriptor`（`key` / `title` / `kind`）+ `Kind { toggle(default:), stepper(default:range:note:), options(_:default:) }`
  - [x] SubTask 5.2: `WidgetDescriptor`（`name` / `title` / `params`）+ `static let all`，7 个控件与 `HomeWidgetRegistry` 注册顺序一一对应；参数键 `compact` / `showsSparkline` / `limit`（0…20，note「0 = 全部」）/ `style`（list/chips）与实际使用一致
  - [x] SubTask 5.3: `descriptor(for:)` + `nodeTypeTitles`（9 种中文名）

- [x] Task 6: 编辑态模型 `Kline/Home/Editor/PageLayoutEditorModel.swift`
  - [x] SubTask 6.1: `@MainActor final class PageLayoutEditorModel: ObservableObject`；`@Published` 八项齐备（`styleID` 初始 = `PageLayoutStore.homeLayout.rawValue`）
  - [x] SubTask 6.2: `loadFromStore()` / `reloadFromStoreKeepingStyle()`：取 `currentFile` 底本（不可用时先 `resetToBuiltIn`），记录 `savedText` 作为脏标记基准
  - [x] SubTask 6.3: 派生：`layoutRoot` / `styleTitle` / `isDirty`（规范化文本比较）/ `flattenedRows`（应用折叠，返回 `[LayoutTreeRow]`）/ `selectedNode` / `canRemoveSelected` / `canMoveSelected`
  - [x] SubTask 6.4: 树查询：`node(for:)`（经 `firstNode`）/ `parentInfo(of:)`（经 `firstParent`）
  - [x] SubTask 6.5: 树编辑：`select` / `toggleCollapse` / `move(fromOffsets:toOffset:)`（仅同级，跨级给「已忽略跨级拖动：仅支持同级重排」）/ `moveSelectedUp` / `moveSelectedDown` / `insertNode(type:)` / `insertWidget(name:)` / `removeSelected()`
  - [x] SubTask 6.6: 参数编辑：`setBool` / `setInt` / `setString` / `setWidgetName`（同名早退，避免误清参数）/ `setNodeTitle` / `setSpacing` / `setPaddingEdge` / `setPaddingUniform` / `setAlignment` / `setAxis` / `setShowsIndicators` / `setCompact` / `setMaxWidthInfinity` / `setMinHeight`
  - [x] SubTask 6.7: JSON 页签：`generateJSONFromTree()` / `applyJSONToTree()`（失败仅记 `jsonError`，草稿不变）；`readable(_:)` 把 `DecodingError` 转成可读文案（含位置路径）
  - [x] SubTask 6.8: 动作：`save()` / `resetToDefault()` / `loadFromStore()`
  - [x] SubTask 6.9: **就地改动的重绘**：所有改动方法末尾统一调 `touchDraft()`（`objectWillChange.send()`）；视图侧全部走 `editor` 的 setter / `Binding(get:set:)`，无直改 class 属性

- [x] Task 7: 页面骨架 `Kline/Home/Editor/PageLayoutEditorView.swift`
  - [x] SubTask 7.1: 顶部栏逐项对齐 `FormulaCenterView.header`（返回胶囊 / 居中「布局编辑器」17 semibold / 右侧「全屏预览」胶囊）
  - [x] SubTask 7.2: 档位行：`HomeLayoutStyle.allCases` 分段 + 右侧 `styleTitle`
  - [x] SubTask 7.3: 页签行：「表单」/「JSON 原文」分段 + 右侧「保存」「恢复默认」（恢复默认先确认）
  - [x] SubTask 7.4: 上半编辑区：表单 = `LayoutNodeTreeList`(宽 320) + `Divider` + `LayoutNodeInspector`；JSON = 通栏 `TextEditor`（等宽 12、关自动纠错、自绘圆角边框）+「由当前树生成」/「应用到树」+ 错误文案
  - [x] SubTask 7.5: 下半预览区：`HomeLayoutPreviewPane` 通栏
  - [x] SubTask 7.6: 底部状态条（固定高 28、`lineLimit(1)`）：未保存改动 / 已保存 / 已恢复默认 / JSON 错误
  - [x] SubTask 7.7: `.overlay` 挂全屏预览；`.onAppear` 载入；未保存返回先弹确认
  - [x] SubTask 7.8: `@StateObject previewModel = HomePageModel()`（两处预览共用真实数据）

- [x] Task 8: 树列表与检查器
  - [x] SubTask 8.1: `LayoutNodeTreeList.swift`：`List` + `ForEach(editor.flattenedRows)`（行身份 `LayoutTreeRow.id = node.uuid`）、缩进体现层级、容器可折叠、点击选中、行高固定 44、`.onMove` 接 `editor.move`
  - [x] SubTask 8.2: 底部工具条（横向 `ScrollView` 防溢出）：「排序/完成」切换（编辑态才可拖动，注释说明 iOS 15 限制）、「上移」「下移」、两个 `Menu`（9 种节点 / 7 个控件）
  - [x] SubTask 8.3: `LayoutNodeInspector.swift`：按 `node.type` 生成字段（stack / scroll / card / frame / widget），`widget` 参数由 `HomeWidgetEditorSchema` 驱动；行高 44 + `Divider`
  - [x] SubTask 8.4: 底部固定「删除本节点」（根节点禁用并说明）+ 未选中引导文案
  - [x] SubTask 8.5: 命中区 ≥ 44pt、行高固定、颜色全走语义色

- [x] Task 9: 两处预览
  - [x] SubTask 9.1: `HomeLayoutPreviewPane.swift`：工具条（左「预览（只读）· 档位 X」+ 右侧「全屏」`Button`，带 `accessibilityIdentifier("layoutEditor.preview.expand")`，条高 44）；滚动区整体 `.allowsHitTesting(false)`
  - [x] SubTask 9.2: 1:1 宽度（无 `scaleEffect`）；改动经 `touchDraft` 立即重绘
  - [x] SubTask 9.3: `HomeLayoutFullPreviewView.swift`：铺满、「返回」胶囊 + 「预览 · 档位 X」+ 「预览模式 · 入口与 Tab 切换不生效」提示；可交互
  - [x] SubTask 9.4: 两处都用业务回调为空的 `HomeLayoutContext`；`HomeWidgetRegistry` 内部 `openDetail` 未改

- [x] Task 10: 个人中心入口
  - [x] SubTask 10.1: `TradingLayoutSettings.swift` 新增 `LayoutEditorSettingRow(onOpen:)`（左「布局编辑器」16pt + 右「首页」+`chevron.right`，`minHeight: 44`）
  - [x] SubTask 10.2: `ProfileDetailView.swift` 在「首页布局」行之后、公式管理之前插入该行
  - [x] SubTask 10.3: 新增 `@State showLayoutEditor` + 容器层全屏 overlay（`.transition(.opacity)` + `zIndex(1000)`）
  - [x] SubTask 10.4: 浮层互斥链 7 → **8**（新增 `showLayoutEditor` 的 `onChange`，并加入其余 7 个的清除列表）

- [x] Task 11: 阶段二闭环
  - [x] SubTask 11.1: 编码自查（`List` 行身份用 uuid、`@Published` 同值不写、行高固定、命中区 ≥ 44pt）；复核中修掉元组 keypath 编译错误并补齐编辑态拖动
  - [x] SubTask 11.2: `build_and_deploy.py "feat(layout-editor): 个人中心入口 + 全屏布局编辑器（改参数/顺序 + 双预览 + 保存/恢复默认）"` —— exit 6 云端构建成功 **run=35624017142**（设备锁屏未安装）
  - [x] SubTask 11.3: 交付说明（见最终交付说明）

## 阶段三：搭积木 + JSON 原文

- [x] Task 12: 节点增删与控件切换走通
  - [x] SubTask 12.1: `insert(_:)` 的三种选中状态（选中容器 → 追加末尾；选中非容器 → 插到父容器内其后；未选中 → 追加到根容器末尾）与「根不是容器」的拒绝路径齐备
  - [x] SubTask 12.2: `setWidgetName` 换控件时清空旧 `params`（同名早退，避免误清已调好的参数）
  - [x] SubTask 12.3: 「删除本节点」对含子树的容器整棵移除；根节点按钮禁用并说明
  - [x] SubTask 12.4: 对 `card`/`frame`（`child` 语义）添加子节点时替换已有 `child` 并提示「该容器仅容纳一个子节点，已替换」

- [x] Task 13: JSON 原文页签走通
  - [x] SubTask 13.1: `TextEditor` 等宽 12、`.disableAutocorrection(true)`（iOS 15 可用）、自绘 `RoundedRectangle` 边框
  - [x] SubTask 13.2: 「应用到树」成功 → 换树 + 清选中/折叠 + 清错误 + 提示；失败 → 可读错误原因，草稿与预览不变
  - [x] SubTask 13.3: 「由当前树生成」用 `canonicalText`，与保存到沙盒的文本同口径
  - [x] SubTask 13.4: 切到 JSON 页签时自动 `generateJSONFromTree()`（`tabBinding` setter）

- [x] Task 14: 阶段三闭环
  - [x] SubTask 14.1: 编码自查 + **独立只读核验代理逐条核验 checklist（61 条可静态核验项）**，据其结果修掉 4 处问题（`WidgetParamValue` 解码顺序改 Int→Double→Bool→String、入口行命中区 36→44、预览「全屏」改真 `Button` + 无障碍标识、树行高统一 44 去掉多余 padding）
  - [x] SubTask 14.2: `build_and_deploy.py "fix(layout-editor): 校验并修复解码顺序、入口命中区、预览按钮与树行高（阶段三闭环）"` —— **编译通过**（`Build .app (unsigned)` / `Package .app to .ipa` / `Upload artifact` 三步全绿，run=35625454063）；该 run 仅在最后一步「Publish latest build to GitHub Release」遇到 GitHub API **HTTP 500**（服务端瞬时错误，非代码问题），故整体结论为 failure
  - [x] SubTask 14.3: 交付说明（见最终交付说明）

## 阶段四：验收

- [ ] Task 15: 真机验收（需设备解锁 + Kline 在前台）
  - [ ] SubTask 15.1: 个人中心 → 布局编辑器可打开；四个档位可切换；树能完整展示当前档位结构
  - [ ] SubTask 15.2: 改 `spacing` / `compact` / `limit` / `style` 后下半预览立即变化
  - [ ] SubTask 15.3: 「排序」模式下拖动重排生效（或「上移/下移」生效）；跨级拖动被拒并有提示
  - [ ] SubTask 15.4: 新增 / 删除节点与控件生效；「添加子节点」在容器上可用
  - [ ] SubTask 15.5: JSON 原文可生成、可应用；写坏 JSON 报错且草稿不变
  - [ ] SubTask 15.6: 「保存」后返回首页立即呈现新布局；「恢复默认」回到内置默认；未保存时返回有提示
  - [ ] SubTask 15.7: 回归点：首页 A/B/C/D 四档呈现、快捷入口、点行开 K 线详情、搜索、公式管理中心、条件单、个人中心、`home.page` 锚点均正常；沙盒 `Documents/Layouts/home.json` 内容与编辑器保存的一致

- [x] Task 16: 收尾
  - [x] SubTask 16.1: 工作区无临时残留改动（临时校验脚本已删除，`git status` 干净）
  - [x] SubTask 16.2: 回填 tasks / checklist 核验结果，纯文档单独提交

## 第二轮：控件内容可配置

### 阶段五：参数引擎扩展（字符串数组 + 动态候选，零行为变化）

- [x] Task 17: `WidgetParamValue` / `WidgetParams` 支持有序字符串数组
  - [x] SubTask 17.1: `PageLayoutSchema.swift`：`WidgetParamValue` 增 `case strings([String])`；`init(from:)` 先试 `[String]` 再走 Int→Double→Bool→String；`encode(to:)` 输出字符串数组；错误文案含 `[string]`；`Equatable` 合成验证
  - [x] SubTask 17.2: `WidgetParams` 增 `func strings(_ key:) -> [String]?`（缺键/类型不符 nil；显式 `[]` 返回空数组）；核对空 params 省略逻辑不会吞掉仅含 `entries: []` 的参数表（values 非空即输出）；另补 `optionalString(_:)` 供动态单选缺省语义
  - [x] SubTask 17.3: `PageLayoutCodec` 往返单测式自查：`entries`/`indices` 数组编解码一致；含数组的旧版容错（`try?` 兜底空表）推演通过
  - [x] SubTask 17.4: 编译通过，首页四档呈现零变化（此时尚无控件读取数组）

- [x] Task 18: 候选源描述与 provider
  - [x] SubTask 18.1: `HomeWidgetEditorSchema.swift`：`Kind` 增 `orderedList(source:maxCount:note:)` / `dynamicOptions(source:note:)`；新增 `struct ParamCandidate`（id/title/subtitle/iconName?）与 `enum WidgetParamCandidates { entries, indices, favoritesGroups, simAccounts }`
  - [x] SubTask 18.2: 新增 `Kline/Home/Editor/WidgetParamCandidateProvider.swift`（`@MainActor enum`，`static func candidates(_:)` / `defaultTitle(_:)` / `defaultOrder(for:)`）：entries 映射 `HomeEntryKind.allCases`；indices 取 `DatabaseManager.shared.metaList`（候选按名称排序；**默认序列取库顺序前 4 不排序**，对齐 HomePageModel）；favoritesGroups 首项「全部」(allGroupID)+`FavoritesStore.groups`；simAccounts 首项「全部账户」(allAccountID)+`SimStore.accounts`
  - [x] SubTask 18.3: 核对 `MetaItem` 的 id/name/code 字段名与 `SimAccount` 的名称字段（实现时以实际定义为准），provider 仅 `import Foundation` 不引 SwiftUI

- [x] Task 19: 编辑器模型与检查器支持两种新参数形态
  - [x] SubTask 19.1: `PageLayoutEditorModel` 增 `setStrings`、`removeParam`、`listAppend/listRemove/listMove(key:...)`（去重、maxCount 拦截并给 banner「最多选择 N 项」、边界提示）；均调 `touchDraft()`；同值不写；listMove 手动实现移动语义（本文件仅 Foundation/Combine，不可用 SwiftUI 的 Array.move）
  - [x] SubTask 19.2: `LayoutNodeInspector.swift` 增 `OrderedListParamRow`：已选区（icon+标题+副标题、上移/下移/删除、行高 44、命中区 44pt）+「可添加」候选区（只列未选项、达 maxCount 全部置灰并说明）+ 空选引导文案；行身份用 candidateID；**缺省态展示生效中的默认序列（所见即所得），首次删除/排序先把默认序列落地为自定义**；展开后经 `ScrollViewReader` 自动把「已选」区滚动到检查器可视顶部（修复长列表首行落在可视区/删除栏下方、点击落空，复跑时定位）
  - [x] SubTask 19.3: 增 `DynamicOptionsParamRow`：Menu 单选，首项（默认项）= 删除该键（回落缺省，落盘无键），当前选中实时显示
  - [x] SubTask 19.4: `DynamicCandidatesReader` 订阅 DatabaseManager.$metaList / FavoritesStore.$groups / SimStore.$accounts，候选随数据变化即时刷新
  - [x] SubTask 19.5: JSON 原文页签验证数组参数可生成/应用；写坏元素类型（如 entries 给数字）有可读错误且草稿不变（沿用 decodeResult 错误链）

### 阶段六：快捷入口自由装配

- [x] Task 20: 入口枚举与呈现通道
  - [x] SubTask 20.1: `HomePageKit.swift`：`HomeEntryKind` 增 `alertRecords`（标题「触发记录」/icon `clock.arrow.circlepath`/tint `.pink`/formulaKind nil）与 `layoutEditor`（标题「布局编辑」/icon `square.grid.3x3`/tint `.indigo`）
  - [x] SubTask 20.2: `HomeOverlayTarget` 增 `.alertRecords` / `.layoutEditor`；`HomeOverlays` 增两全屏分支（`AlertRecordView(onClose:)`、`PageLayoutEditorView(onClose:)`，共用 opacity + zIndex(1000)）
  - [x] SubTask 20.3: `HomeView.perform(_:)` 补两分支写 `overlayTarget`；单值 target 无堆叠，编辑器两处预览 onEntry 均为空闭包，物理上无法再开第二层，返回只关最上层
  - [x] SubTask 20.4: B/C/D 回退视图 switch 补全：HomeView 注入 `onOpenAlertRecords`/`onOpenLayoutEditor` 两闭包（接到同一 overlayTarget）；回退视图视觉不变，快捷行仍为默认全部入口（#Preview 补空闭包）
  - [x] SubTask 20.5: 锚点：`HomeQuickEntryChip` 对新 case 自动产出 `home.entry.alertRecords` / `home.entry.layoutEditor`，无需额外改动（确认即可）

- [x] Task 21: 控件按参数渲染入口集合
  - [x] SubTask 21.1: `HomeQuickEntryRow` 改收 `kinds: [HomeEntryKind] = .allCases`；空数组 → `EmptyView`（无滚动区内边距残留）
  - [x] SubTask 21.2: `HomeWidgetRegistry` 的 quickEntryRow builder：`p.strings("entries")` 缺省=allCases；存在=rawValue 映射保序+去重+过滤未知（去重在独立核验后补齐）；`[]`=空
  - [x] SubTask 21.3: `HomeWidgetEditorSchema` 给 quickEntryRow 声明 `entries` 参数（orderedList / .entries / 无上限 / note「缺省 = 全部入口」）
  - [x] SubTask 21.4: 双预览验证：编辑器内增删移入口，页内预览即时变化（test98 已覆盖）；全屏预览中入口点击不生效（onEntry 空闭包，维持既有标注）

### 阶段七：四个内容控件数据源选择

- [x] Task 22: `HomePageModel` 按参数取数
  - [x] SubTask 22.1: `indexRows(selectedIDs: [String]?) -> [MarketRow]`：nil/空=现前 4；否则按 id 保序解析、去重、过滤失效、防御性上限 4；0 有效回落前 4（独立核验指出后修正：显式 `[]` 与全失效均回落）；`indexQuotes` 快照保留
  - [x] SubTask 22.2: `favoriteRows(groupID:limit:)`：groupID 字符串解析（allGroupID/实体/非法→全部），resolveMetaItems 后预取+截断（limit 0=前 5，1…20 生效）
  - [x] SubTask 22.3: `simSummary(accountIDString:)` 与 `topPositions(accountIDString:)`：UUID 解析失败/缺省=nil 全部；具体账户下持仓按 accountID 过滤（resolveSimAccountID 失效回落 nil）
  - [x] SubTask 22.4: `refreshMarketAggregates()` 同一次遍历调两次 `boardAggregate(types:includesBreadth:)` 预算主板与 ETF指数两套（mainBoardTypes=`["沪深主板"]`、etfIndexTypes=`["沪深京指数","扩展行情指数"]`），新增 `gainersRows(board:)` / `gainersReady(board:)`；breadth 仅主板算（ETF 不算涨跌停），口径不动
  - [x] SubTask 22.5: 回退视图 B/C/D 继续用旧属性（indexQuotes/favoriteRows/simSummary/topGainers 保留），不受新方法影响
  - [x] SubTask 22.6（实现补充）: `rowsReadyOnly(_:prefetch:)` 保证 body 周期只读 `MarketRowCache.rows`（@Published），缺失先给临时壳并在 `DispatchQueue.main.async` 注册/预取+发 objectWillChange，规避「更新期发布」紫警

- [x] Task 23: 注册表与描述表接线
  - [x] SubTask 23.1: `home.marketOverview` builder 读 `indices` 调 `indexRows(selectedIDs:)`；breadth 固定主板；控件视图 init 不变
  - [x] SubTask 23.2: `home.favorites` builder 读 `group`（optionalString）+ `limit` 调 `favoriteRows(groupIDString:limit:)`；空态/onEmptyTap 行为不变
  - [x] SubTask 23.3: `home.simSummary` builder 读 `account`；`HomeSimSummaryBlock` 加 `accountIDString` 入参，summary/positions 均走 model 新方法（保持视图分层、改动最小）
  - [x] SubTask 23.4: `home.topGainers` builder 读 `board`（"etfIndex" / 默认 mainBoard）调 `gainersRows/gainersReady(board:)`
  - [x] SubTask 23.5: `HomeWidgetEditorSchema` 四项参数声明齐备（indices maxCount 4；group/account dynamicOptions；board 静态 options mainBoard/etfIndex 默认 mainBoard）；favorites 的 limit note 为「0 = 默认前 5」
  - [x] SubTask 23.6: 默认 JSON 不新增任何键（`HomeLayoutDefaults.swift` 零改动，沙盒默认 home.json 实测四档均无 entries/indices 等键）；恢复默认=现状呈现

### 阶段八：测试与验收

- [x] Task 24: UI 测试（KlineUITests，iPad mini 5 模拟器）
  - [x] SubTask 24.1: 新增 `test98_Home_QuickEntriesConfigurable`（规划名 test96，因 test91-97 编号已占用顺延）：快捷入口行删 search、tech 下移、首页即时生效、杀进程重启持久化、恢复默认回齐；含横滑首页入口行与树列表懒加载滚动两个 helper
  - [x] SubTask 24.2: 新增 `test99_Home_MarketOverviewIndicesConfigurable`（规划名 test97）：默认 4 只指数、删除后候选可点、加回达 4/4 全部候选禁用、持久化、恢复默认
  - [x] SubTask 24.3: 回归既有首页/行情用例（test91/92/93/95/96/97）未改锚点；`home.entry.` 旧 6 锚点保持
  - [x] SubTask 24.4: 未加任何临时诊断标识；树内定位用既有锚点 `layout.tree.widget.<name>` + 树面板坐标滑动解决懒加载

- [x] Task 25: iPad mini 5 模拟器构建安装 + 沙盒日志（人工目视项并入 Task 15 真机验收）
  - [x] SubTask 25.1: 已确认 iPad mini 5（UDID 54291852-68BE-45BF-ACC0-72CEAEF10A0B）Booted，全程 `open -a Simulator` GUI 前台
  - [x] SubTask 25.2: `bash scripts/kline_deploy_mac.sh`（前台等待返回）xcodebuild 构建+安装+启动，commit afb1097 已 push
  - [ ] SubTask 25.3: 目视验收（待用户）：8 入口默认呈现；编辑器入口增删移+清空；触发记录/布局编辑器两入口可开可关；四控件参数切换；四档独立（自动化已覆盖 entries/indices 主链路）
  - [x] SubTask 25.4: 沙盒核对：默认 home.json 四档无 entries/indices 键；注入 `entries=["picker","tech","alertRecords","layoutEditor"]` 与 `indices=["327","324"]` 后首页按序渲染 4 入口 2 指数；恢复默认后键消失；日志无 error/crash/紫警
  - [ ] SubTask 25.5: 回归目视（待用户，与 Task 15 合并）：四档布局、点行开 K 线、搜索、公式中心、条件单、个人中心、悬浮按钮延迟显示

- [x] Task 26: 第二轮收尾
  - [x] SubTask 26.1: 独立只读核验代理逐条核验第二轮 checklist，修复 4 项问题（indices 空选/全失效回落前 4、entries builder 去重、动态单选默认项删键、已选/候选行命中区 44pt）；44pt 改动后复跑暴露第 5 项——展开后首屏已选行位于检查器可视区外/被底部删除栏遮挡致点击落空，补 `ScrollViewReader` 展开自动定位 + 测试 helper 等 0.5s 动画；最终 test98（89.8s）/ test99（124.6s）复跑 0 failures
  - [x] SubTask 26.2: 工作区无临时残留（注入文件已还原）；回填 tasks/checklist
  - [x] SubTask 26.3: 主体改动经部署脚本提交 afb1097 并 push；核验修复与文档回填为后续补充提交

### 阶段九：拖拽装配（跨级拖入容器）——第三轮

- [x] Task 27: 模型层跨级拖入 API（PageLayoutEditorModel.swift）
  - [x] SubTask 27.1: 新增 `enum DropRejection { targetMissing, notContainer, intoSelfOrDescendant }`（本轮补 `crossLevel`）与 `validateDrop(_ draggingUUID:into targetUUID:) -> DropRejection?`；自环判定用「目标是否落在被拖节点子树内（含自身）」
  - [x] SubTask 27.2: 新增 `moveInto(_ draggingUUID:container targetUUID:) -> Bool`：校验不过 → banner + false（不 touchDraft）；原父==目标且已在末尾 → 视作无操作（banner「该节点已在此容器末尾」，不 touchDraft）；否则原父 `removeChild` → 目标 `appendChild`（`.child` 非空 banner「该容器仅容纳一个子节点，已替换」，`.children` banner「已移入：<容器名>」）→ 展开目标容器 + `select(被拖节点)` + `touchDraft()`；另加 `reportDropRejected` 供松手后被拒时写 banner（同句不重复发布）
  - [x] SubTask 27.3: 跨级拖入 API 放在新增 `// MARK: - 树操作：跨级拖入` 段内；既有 `move(fromOffsets:toOffset:)` / `moveSelectedUp/Down` / `canMoveSelected` 零改动
- [x] Task 28: 树列表拖拽交互与落点反馈（LayoutNodeTreeList.swift）
  - [x] SubTask 28.1: 非根行 `.onDrag { NSItemProvider(object: node.uuid.uuidString as NSString) }`（根行只作落点，不可拖）
  - [x] SubTask 28.2: 所有行 `.onDrop(of: [.text], delegate:)` + `NodeDropDelegate: DropDelegate`；`performDrop` 用 `loadObject` 异步取 uuid 串 → `Task { @MainActor in }` 调模型
  - [x] SubTask 28.3: **路线 A（实测后定稿）**：节点树由 `List` 改为 `ScrollView + LazyVStack`（`List` 吞掉自身行发起的拖拽会话，行内/List 层/外层三处 `.onDrop` 全零回调）；叶子落点改红色高亮（不用系统 `.forbidden`，避免松手拿不到 `performDrop`）；落点行蓝/红高亮与选中蓝底区分（本条中的「排序」开关与 `layoutEditor.sortingToggle` 锚点已由 SubTask 28.6 删除）
  - [x] SubTask 28.4: 复核点击选中、折叠展开、滚动、行高 44、既有锚点（`layout.tree.<type>` / `layout.tree.widget.<name>`）未被拖拽手势破坏；拖拽悬停不写 banner；编译错误修复（`rowHeight` 私有可见性 → fileprivate）
  - [x] SubTask 28.5: **只读核验发现的缺陷修复**：排序模式下半区原先用 `targetIndex + 1` 当锚点，而扁平行是 DFS 先序（容器行的下一行是它的第一个子节点），拖到容器行下半区会被模型判成跨级、报「已忽略跨级拖动」；改为 `indexAfterTargetRow` 跳过后代行取下一个同级/更浅的行；改后 `build-for-testing` 再次通过
  - [x] SubTask 28.6（用户新需求）：**拖拽即排序，删除模式开关**——一次拖拽内按落点分区自动判定意图（容器行 上边缘 12pt=前插 / 中 20pt=拖入 / 下边缘 12pt=后插；叶子行 上半=前插 / 下半=后插），删除工具条「排序」开关与锚点 `layoutEditor.sortingToggle`；视图侧 `LayoutDropResolution`（into / insertBefore / insertAfter / reject）统一驱动悬停反馈与松手动作，`LayoutDragSession` 透传拖拽源（非 `@State`，避免打断拖拽会话）；模型侧新增 `DropRejection.crossLevel` 与按兄弟定位的 `move(beforeSibling:)/move(afterSibling:)`（彻底取代吃扁平行下标的 `indexAfterTargetRow` 方案）；悬停三态反馈（前插/后插行顶/行底 2pt 蓝线、拖入蓝底蓝框、非法红底红框）；`build` 与 `build-for-testing` 均通过
- [x] Task 29: UI 测试（KlineUITests，iPad mini 5 模拟器）
  - [x] SubTask 29.1: `test100_Home_EditorDragNodeIntoStack`：确保默认 → 打开编辑器 → 拖「快捷入口行」（行中心）到「滚动区」行**中间区** → 读 JSON 原文断言缩进 **+4 空格**（节点深度 +1 = JSON 结构层 +4）且排在 `home.topGainers` 之后 → 保存 → 杀进程重启仍保持 → 恢复默认（实跑 84.5s 通过）
  - [x] SubTask 29.2: `test101_Home_EditorDragInvalidTarget`：① 把「滚动区」拖到其子孙「卡片」行中间区 → 断言 banner「不能把节点拖入它自己或它的子节点」且结构不变；② 跨级插入：把「大盘概览」控件行（行中心）拖到**相邻**的「大盘概览卡片」行**上边缘区** → 断言 banner「跨级移动请拖到容器行中间区，同级排序请拖到同级行上/下边缘」且结构不变（实跑 92.8s 通过）
  - [x] SubTask 29.4: `test102_Home_EditorDragReorderSibling`：拖「快捷入口行」到 `home.header` 行**上边缘区** → 断言缩进不变、顺序变为排在 `home.header` 之前 → 保存 → 杀进程重启仍保持 → 恢复默认（实跑 75.6s 通过）
  - [x] SubTask 29.5（测试基建）：落点几何统一为 helper——app 侧树列表加锚点 `layoutEditor.treeList`；测试侧 `treeViewport`（真实可视区）+ `treeRowRect`（同行元素并集 + 纵向居中补余量，避开「叶子行 firstMatch 只是标题 → 行顶算高 7pt → 落点跑到上一行」与「同一标识匹配多行」两坑）+ `TreeDropZone.before/.into/.after`；可见性改为「行 rect 完整落在可视区」（`isHittable` 对懒加载裁掉的行不判假，曾致长按打到工具栏按钮弹出 Menu 吃掉手势）
  - [x] SubTask 29.3: 回归复跑（编辑器/树交互相关）`test96/97/98/99` 全部通过；`test91`（ETF 种子库二级菜单）、`test92`（刘海机型横向安全区）为 iPad mini 5 上的既有环境性失败
- [x] Task 30: 设备验证与收尾
  - [x] SubTask 30.1: iPad mini 5（UDID 54291852-68BE-45BF-ACC0-72CEAEF10A0B）前台跑 `xcodebuild test`（模拟器带 GUI，禁后台）：test100/101/102 + 回归 test96/97/98/99 全通过
  - [x] SubTask 30.2: 沙盒 `Documents/Layouts/home.json` 结构核对（可解析、四档结构完整、B 档根子节点为默认顺序＝用例末尾「恢复默认」已落盘）+ `debug_log.txt` 无 error/crash/残留诊断日志
  - [ ] SubTask 30.3: `KLINE_DEVICE_ID=<udid> bash scripts/kline_deploy_mac.sh "<描述>"` 前台部署并 push
  - [x] SubTask 30.4: 独立只读核验代理逐条核验第三轮 checklist，修复后复跑并回填


# Task Dependencies

- Task 2 depends on Task 1（`Encodable` 在 Task 1 建立）
- Task 3 depends on Task 2
- Task 4 depends on Task 1、Task 2、Task 3
- Task 6 depends on Task 4、Task 5
- Task 7 / Task 8 / Task 9 depends on Task 6
- Task 10 depends on Task 7
- Task 11 depends on Task 7、Task 8、Task 9、Task 10
- Task 12 / Task 13 depends on Task 11
- Task 14 depends on Task 12、Task 13
- Task 15 depends on Task 14
- Task 16 depends on Task 15（文档回填部分已完成，真机验收结论待 Task 15 后补）
- Task 18 depends on Task 17；Task 19 depends on Task 18
- Task 20 / Task 21 depends on Task 19（检查器先能编辑有序列表，再接入口数据）
- Task 22 depends on Task 17；Task 23 depends on Task 22、Task 19
- Task 24 depends on Task 21、Task 23
- Task 25 depends on Task 24
- Task 26 depends on Task 25
- Task 28 depends on Task 27（模型先有跨级拖入 API，视图才有落点可调）
- Task 29 depends on Task 28
- Task 30 depends on Task 29