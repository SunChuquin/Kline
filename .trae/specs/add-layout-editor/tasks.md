# Tasks

## 阶段一：模型可变 + 编解码 + 仓库写接口（零 UI 变化）

- [x] Task 1: `Kline/App/PageLayout/PageLayoutSchema.swift` 升级为可编辑模型
  - [x] SubTask 1.1: `PageLayoutNode` 全字段 `let` → `var`；新增 `let uuid: UUID` + `var id: UUID { uuid }`（满足 `Identifiable`；编辑期身份，`init(from:)` 里生成、`encode(to:)` 不输出）
  - [x] SubTask 1.2: `PageLayoutNode` 实现 `Encodable`：`encode(to:)` **只输出与 `type` 相关的字段**（`vstack`/`hstack`/`zstack` 写 `spacing`/`alignment`/`children`；`scroll` 写 `axis`/`spacing`/`padding`/`showsIndicators`/`children`；`card` 写 `title`/`compact`/`child`；`frame` 写 `maxWidth`/`minHeight`/`alignment`/`child`；`widget` 写 `name`/`params`；`divider`/`spacer` 只写 `type`）；原有 `Decodable` 白名单校验保留（未知 `type` 仍抛 `dataCorruptedError`）
  - [x] SubTask 1.3: `PageLayoutPadding`：字段 `var` + `init(top:leading:bottom:trailing:)`（默认 0）+ `static let zero` + 实现 `Encodable`（**只输出非 0 的边**）；`PageLayoutWidth` 实现 `Encodable`（`"infinity"` / 数字）
  - [x] SubTask 1.4: `WidgetParams.values` 由 `private let` → `var`、加 `isEmpty`；`WidgetParamValue` 加 `Encodable`；`WidgetParams` / `PageLayoutWidth` 加 `Equatable`；`PageLayoutDefinition` / `PageLayoutFile` 字段 `var` + `Codable`（`defaultLayoutID` 的 CodingKeys 双向映射 `"default"`）
  - [x] SubTask 1.5: 新增节点工厂 `static func make(type:)`（白名单外返回 nil），9 种类型默认值齐备
  - [x] SubTask 1.6: 新增 `ContainerKey` / `containerKey` / `childList` / `appendChild`（`.child` 已有子节点时替换并返回 true，由调用方提示）/ `removeChild(uuid:)` / `flattened()` / `firstNode(uuid:)` / `firstParent(of:)`
  - [x] SubTask 1.7: 向后兼容：`PageLayoutRenderer` / `HomeWidgetRegistry` / `HomeView` / `Widgets/` 控件**一行未改**即编译通过（run=35621629404）

- [x] Task 2: 新增 `Kline/App/PageLayout/PageLayoutCodec.swift`
  - [x] SubTask 2.1: `static func decode(_ text: String) -> PageLayoutFile?`
  - [x] SubTask 2.2: `static func encode(_ file: PageLayoutFile) -> String?`：`JSONEncoder` + `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`
  - [x] SubTask 2.3: `static func canonicalText(_ file: PageLayoutFile) -> String?`（与 `encode` 同一口径）
  - [x] SubTask 2.4: 顶部注释写明「唯一编解码口径」

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

- [ ] Task 6: 编辑态模型 `Kline/Home/Editor/PageLayoutEditorModel.swift`
  - [ ] SubTask 6.1: `@MainActor final class PageLayoutEditorModel: ObservableObject`；`@Published`：`styleID`（初始 `PageLayoutStore.shared.homeLayout.rawValue`）、`file: PageLayoutFile?`、`selectedUUID: UUID?`、`collapsed: Set<UUID>`、`jsonText: String`、`jsonError: String?`、`showsJSONTab: Bool`、`banner: String?`
  - [ ] SubTask 6.2: `loadFromStore()`：从 `PageLayoutConfigStore.currentFile(page:)` 取底本（不可用时先 `resetToBuiltIn` 再取），记录 `savedText = canonicalText(file)` 作为脏标记基准
  - [ ] SubTask 6.3: 派生：`layoutRoot: PageLayoutNode?`（当前档位的 root）、`styleTitle: String`、`isDirty: Bool`、`flattenedRows: [(node: PageLayoutNode, depth: Int)]`（应用折叠）、`selectedNode: PageLayoutNode?`
  - [ ] SubTask 6.4: 树查询：`node(for id: UUID) -> PageLayoutNode?`、`parentInfo(of id: UUID) -> (parent: PageLayoutNode, index: Int)?`（走 `firstNode` / `firstParent`）
  - [ ] SubTask 6.5: 树编辑：`select(_:)`、`toggleCollapse(_:)`、`move(fromOffsets:toOffset:)`（**仅同级**；跨级则 `banner = "仅支持同级重排"` 并返回）、`insertNode(type:)`、`insertWidget(name:)`、`removeSelected()` —— 规则：选中容器 → 追加到它末尾；选中非容器 → 追加到父容器内其后；未选中 → 追加到根容器末尾；根不是容器 / 根节点被删除时拒绝并给 `banner`
  - [ ] SubTask 6.6: 参数编辑：`setBool(_:_:on:)` / `setInt(_:_:on:)` / `setString(_:_:on:)`（写进 `node.params`，缺 `params` 时先建空表）
  - [ ] SubTask 6.7: JSON 页签：`generateJSONFromTree()`、`applyJSONToTree()`（解析失败 → `jsonError` 有值且草稿不变）
  - [ ] SubTask 6.8: 动作：`save()`、`resetToDefault()`、`loadFromStore()` + 统一的 `touchDraft()`（就地改动后触发重绘，见下）
  - [ ] SubTask 6.9: **就地改动的重绘**：树节点是引用类型，就地改字段不会触发 `@Published`，所有改动方法末尾必须调 `touchDraft()`（内部 `objectWillChange.send()`），否则预览不刷新

- [ ] Task 7: 页面骨架 `Kline/Home/Editor/PageLayoutEditorView.swift`
  - [ ] SubTask 7.1: 顶部栏逐项对齐 `FormulaCenterView.header`（左「返回」胶囊：chevron.left 16 semibold + 「返回」15 medium、`Color.gray.opacity(0.12)`、`cornerRadius(8)`、`padding(.horizontal,10)/.vertical,6)`、`padding(.leading,16)`；居中「布局编辑器」17 semibold；右侧「全屏预览」胶囊同款式）
  - [ ] SubTask 7.2: 档位行：A/B/C/D 分段（读写 `editor.styleID`），右侧显示 `editor.styleTitle`
  - [ ] SubTask 7.3: 页签行：「表单」/「JSON 原文」分段 + 右侧「保存」/「恢复默认」胶囊（恢复默认先弹确认）
  - [ ] SubTask 7.4: 上半编辑区（约占一半高）：表单页签 = `LayoutNodeTreeList`（宽 320）+ `Divider` + `LayoutNodeInspector`；JSON 页签 = 通栏 `TextEditor`（等宽 12、`autocorrectionDisabled`、自绘圆角边框）+「由当前树生成」/「应用到树」+ 错误文案
  - [ ] SubTask 7.5: 下半预览区（占一半）：`HomeLayoutPreviewPane` 通栏
  - [ ] SubTask 7.6: 底部状态条（固定高度）：`未保存改动` / 已保存 / 已恢复默认 / JSON 错误
  - [ ] SubTask 7.7: `.overlay` 挂 `HomeLayoutFullPreviewView`；`.onAppear { editor.loadFromStore() }`；点「返回」时若 `editor.isDirty` 先弹确认
  - [ ] SubTask 7.8: `@StateObject private var previewModel = HomePageModel()`（两处预览共用真实数据）

- [ ] Task 8: 树列表与检查器
  - [ ] SubTask 8.1: `LayoutNodeTreeList.swift`：用 `editor.flattenedRows` 平铺（缩进体现层级、容器有展开箭头、点击选中、选中行高亮）；行标题 = 节点类型中文名（`nodeTypeTitles`）/ 控件显示名（`HomeWidgetEditorSchema.descriptor(for:)`）；副标题摘要（`card` 显标题、`widget` 显控件名、`scroll` 显轴与间距）；`.onMove` 接 `editor.move(fromOffsets:toOffset:)`
  - [ ] SubTask 8.2: 列表底部工具条：「+ 添加节点」`Menu`（9 种类型）与「+ 添加控件」`Menu`（7 个控件）→ `insertNode(type:)` / `insertWidget(name:)`
  - [ ] SubTask 8.3: `LayoutNodeInspector.swift`：按 `node.type` 生成字段 —— `vstack`/`hstack`/`zstack`（spacing 步进、alignment 选项）、`scroll`（axis 选项、spacing、四边 padding、showsIndicators 开关）、`card`（title 输入、compact 开关）、`frame`（maxWidth infinity 开关、alignment、minHeight）、`widget`（控件名下拉 + 按 `HomeWidgetEditorSchema` 生成的参数控件）；行高固定、`Divider` 分隔
  - [ ] SubTask 8.4: 检查器底部「删除本节点」（选中根节点时禁用）+ 未选中时的引导文案
  - [ ] SubTask 8.5: 命中区 ≥ 44pt、行高固定（不抖动）、颜色全走语义色

- [ ] Task 9: 两处预览
  - [ ] SubTask 9.1: `HomeLayoutPreviewPane.swift`：顶部一行（「预览（只读）· 档位 X」+ 右侧「全屏」胶囊），下方 `ScrollView` 内用 `PageLayoutRenderer(registry: HomeWidgetRegistry.shared.registry, context:)` 渲染 `editor.layoutRoot`；**滚动区整体 `.allowsHitTesting(false)`**（顶部工具条仍可点）
  - [ ] SubTask 9.2: 1:1 宽度（不做 `scaleEffect`）；`editor` 任一改动（含 `touchDraft`）立即重绘
  - [ ] SubTask 9.3: `HomeLayoutFullPreviewView.swift`：铺满页面；顶部栏「返回」胶囊 + 居中「预览 · 档位 X」+ 右侧提示「预览模式 · 入口与 Tab 切换不生效」；下方 1:1 渲染且可交互（点行情行会打开 K 线详情）
  - [ ] SubTask 9.4: 两处预览都用「业务回调为空实现」的 `HomeLayoutContext(model: model, onProfile: {}, onEntry: { _ in }, onSelectTab: { _ in })`；`HomeWidgetRegistry` 内部持有的 `openDetail` 不改

- [ ] Task 10: 个人中心入口
  - [ ] SubTask 10.1: `TradingLayoutSettings.swift` 新增 `LayoutEditorSettingRow(onOpen:)`：左「布局编辑器」16pt + 右 `HStack { Text("首页") ; Image(systemName: "chevron.right") }`（12pt 蓝色）、`frame(minHeight: 36)`、整行 `contentShape(Rectangle())` + `.onTapGesture`
  - [ ] SubTask 10.2: `ProfileDetailView.swift` 在「首页布局」行之后、`FormulaCenterSettingRow` 之前插入该行（`.padding()` + `secondarySystemBackground` + `cornerRadius(12)`）
  - [ ] SubTask 10.3: 新增 `@State private var showLayoutEditor = false` + 容器层 overlay（`ZStack { PageLayoutEditorView(onClose: { showLayoutEditor = false }) }` + `.transition(.opacity)` + `.zIndex(1000)`）
  - [ ] SubTask 10.4: 浮层互斥链由 7 项扩为 8 项（新增 `showLayoutEditor` 的 `onChange`，并加入其余 7 个 `onChange` 的清除列表）

- [ ] Task 11: 阶段二闭环
  - [ ] SubTask 11.1: 编码自查（不在 `body` 内做整树遍历重算、`List` 行身份用 `uuid`、`@Published` 同值不写、行高固定、命中区 ≥ 44pt）
  - [ ] SubTask 11.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(layout-editor): 个人中心入口 + 全屏布局编辑器（改参数/顺序 + 双预览 + 保存/恢复默认）"`
  - [ ] SubTask 11.3: 交付说明（build 号 / 改动与理由 / 真机验证路径）

## 阶段三：搭积木 + JSON 原文

- [ ] Task 12: 节点增删与控件切换走通
  - [ ] SubTask 12.1: 校验 Task 8.2 的两个 `Menu`（添加节点 / 添加控件）在三种选中状态下都可用（选中容器 / 选中非容器 / 未选中）
  - [ ] SubTask 12.2: 检查器里的控件名下拉可把 `widget` 节点换成另一个控件（`name` 改写后清空旧 `params`，避免残留无关键）
  - [ ] SubTask 12.3: 「删除本节点」对含子树的容器整棵移除；根节点按钮禁用并给出说明
  - [ ] SubTask 12.4: 新增 `card`/`frame`（`child` 语义）节点后，检查器里「添加子节点」把 `child` 置为单一子节点（已有 `child` 时替换并提示）

- [ ] Task 13: JSON 原文页签走通
  - [ ] SubTask 13.1: `TextEditor` 等宽 12、`autocorrectionDisabled`、固定区域、自绘 `RoundedRectangle` 边框（语义色）
  - [ ] SubTask 13.2: 「应用到树」成功 → 刷新预览 + 清空 `jsonError` + 状态条提示；失败 → 显示错误原因（含 `DecodingError` 可读描述）且草稿与预览不变
  - [ ] SubTask 13.3: 「由当前树生成」把文本重置为当前草稿规范 JSON（与保存到沙盒的文本一致）
  - [ ] SubTask 13.4: 切页签时自动 `generateJSONFromTree()`（避免显示过期文本）

- [ ] Task 14: 阶段三闭环
  - [ ] SubTask 14.1: 编码自查
  - [ ] SubTask 14.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(layout-editor): 支持节点增删与 JSON 原文编辑"`
  - [ ] SubTask 14.3: 交付说明

## 阶段四：验收

- [ ] Task 15: 真机验收（需设备解锁 + Kline 在前台）
  - [ ] SubTask 15.1: 个人中心 → 布局编辑器可打开；四个档位可切换；树能完整展示当前档位结构
  - [ ] SubTask 15.2: 改 `spacing` / `compact` / `limit` / `style` 后下半预览立即变化
  - [ ] SubTask 15.3: 同级拖动重排生效；跨级拖动被拒并有提示
  - [ ] SubTask 15.4: 新增 / 删除节点与控件生效；「添加子节点」在容器上可用
  - [ ] SubTask 15.5: JSON 原文可生成、可应用；写坏 JSON 报错且草稿不变
  - [ ] SubTask 15.6: 「保存」后返回首页立即呈现新布局；「恢复默认」回到内置默认；未保存时返回有提示
  - [ ] SubTask 15.7: 回归点：首页 A/B/C/D 四档呈现、快捷入口、点行开 K 线详情、搜索、公式管理中心、条件单、个人中心、`home.page` 锚点均正常；沙盒 `Documents/Layouts/home.json` 内容与编辑器保存的一致

- [ ] Task 16: 收尾
  - [ ] SubTask 16.1: 确认验收后沙盒配置处于预期状态，工作区无临时残留改动
  - [ ] SubTask 16.2: 回填 tasks / checklist 核验结果，纯文档单独提交

# Task Dependencies

- Task 2 depends on Task 1（`Encodable` 在 Task 1 建立）
- Task 3 depends on Task 2
- Task 4 depends on Task 1、Task 2、Task 3
- Task 6 depends on Task 4、Task 5
- Task 7 depends on Task 6
- Task 8 depends on Task 6
- Task 9 depends on Task 6
- Task 10 depends on Task 7（页面类型需已存在）
- Task 11 depends on Task 7、Task 8、Task 9、Task 10
- Task 12 / Task 13 depends on Task 11
- Task 14 depends on Task 12、Task 13
- Task 15 depends on Task 14
- Task 16 depends on Task 15
- Task 5 与 Task 1–4 相互独立，可与阶段一并行推进