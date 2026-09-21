# Tasks

## 阶段一：模型可变 + 编解码 + 仓库写接口（零 UI 变化）

- [ ] Task 1: `Kline/App/PageLayout/PageLayoutSchema.swift` 升级为可编辑模型
  - [ ] SubTask 1.1: `PageLayoutNode` 全字段 `let` → `var`；新增 `let uuid: UUID`（编辑期身份，`init(from:)` 里生成、`encode(to:)` 不输出）
  - [ ] SubTask 1.2: `PageLayoutNode` 实现 `Encodable`：`encode(to:)` **只输出与 `type` 相关的字段**（`vstack`/`hstack`/`zstack` 只写 `spacing`/`alignment`/`children`；`scroll` 写 `axis`/`padding`/`spacing`/`showsIndicators`/`children`；`card` 写 `title`/`compact`/`child`；`frame` 写 `maxWidth`/`minHeight`/`alignment`/`child`；`widget` 写 `name`/`params`；`divider`/`spacer` 无字段）；保留现有 `Decodable` 白名单校验
  - [ ] SubTask 1.3: `PageLayoutPadding`：字段 `var` + 实现 `Encodable`（**只输出非 0 的边**，与解码缺省 0 往返一致）；`PageLayoutWidth` 实现 `Encodable`（`.infinity` → `"infinity"`，`.points(v)` → 数字）
  - [ ] SubTask 1.4: `WidgetParams.values` 由 `private let` → `var`（供编辑器写参数）；`WidgetParamValue` 加 `Encodable`；`PageLayoutDefinition` / `PageLayoutFile` 字段 `var` + `Codable`（`defaultLayoutID` 的 CodingKeys 映射保持 `"default"`）
  - [ ] SubTask 1.5: 新增节点工厂 `static func make(type: String) -> PageLayoutNode?`（白名单外的 type 返回 nil）：`vstack` spacing 8；`hstack` spacing 8 alignment center；`zstack`；`scroll` axis vertical + spacing 8 + padding 16 + showsIndicators true；`card` title "新卡片" + compact false；`frame` maxWidth infinity + alignment top；`widget` name ""；`divider`；`spacer`
  - [ ] SubTask 1.6: 新增树操作便捷成员：`enum ContainerKey { case children, child }`、`var containerKey: ContainerKey?`（vstack/hstack/zstack/scroll → `.children`；card/frame → `.child`；widget/divider/spacer → nil）、`var childList: [PageLayoutNode]`、`func appendChild(_:)`（容器才生效）、`func removeChild(uuid:) -> Bool`
  - [ ] SubTask 1.7: 保持向后兼容：现有解码路径、`PageLayoutRenderer` / `HomeWidgetRegistry` / `HomeView` 一行不改即可编过（`let`→`var` 与新增 `uuid` 不破坏只读用法）

- [ ] Task 2: 新增 `Kline/App/PageLayout/PageLayoutCodec.swift`
  - [ ] SubTask 2.1: `static func decode(_ text: String) -> PageLayoutFile?`（复用现有 `JSONDecoder` 逻辑）
  - [ ] SubTask 2.2: `static func encode(_ file: PageLayoutFile) -> String?`：`JSONEncoder` + `[.prettyPrinted, .sortedKeys]`（不开启 `.withoutEscapingSlashes` 以外的手工替换）
  - [ ] SubTask 2.3: `static func canonicalText(_ file: PageLayoutFile) -> String?`（等价于 `encode`，作为脏标记与「由当前树生成」的统一口径）
  - [ ] SubTask 2.4: 顶部注释写明：本文件是配置文本的唯一编解码口径，落盘 / JSON 页签 / 脏标记都走它

- [ ] Task 3: `Kline/App/PageLayout/PageLayoutConfigStore.swift` 补齐写接口
  - [ ] SubTask 3.1: `decode(_:)` 改为复用 `PageLayoutCodec.decode`
  - [ ] SubTask 3.2: `@discardableResult func save(_ file: PageLayoutFile, page: String) -> Bool`：`PageLayoutCodec.encode` → 写沙盒（`.atomic`）→ `apply(page:file:text:)`（沿用同值不写）→ 同步 `lastModDates[page] = 当前文件 mtime`（避免下次 `onAppear` 重复重解码）
  - [ ] SubTask 3.3: `func builtInText(page: String) -> String?`（取已注册的内置默认文本）
  - [ ] SubTask 3.4: `@discardableResult func resetToBuiltIn(page: String) -> Bool`：内置默认文本写回沙盒并 `apply`；未注册内置默认时返回 false
  - [ ] SubTask 3.5: `func currentFile(page: String) -> PageLayoutFile?`（返回内部已解码的当前配置，供编辑器取草稿底本）
  - [ ] SubTask 3.6: 更新文件头注释：职责由「只读 + 种入」扩为「读 + 写」；明确 `save` 会同步 mtime、不破坏回退链

- [ ] Task 4: 阶段一闭环
  - [ ] SubTask 4.1: 编码自查（`Color.opacity` 入参 Double、勿遮蔽同名参数、`@Published` 同值赋值守卫、只改本阶段相关文件）
  - [ ] SubTask 4.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "refactor(page-layout): 配置模型可编辑化 + 编解码与仓库写接口（零 UI 变化）"`
  - [ ] SubTask 4.3: 交付说明（build 号 / 改动与理由 / 真机验证路径：四档呈现与回退行为不变、首页可用）

## 阶段二：编辑器可用（入口 + 页面 + 改参数与顺序 + 双预览 + 保存）

- [ ] Task 5: 首页控件可编辑参数描述表 `Kline/Home/Editor/HomeWidgetEditorSchema.swift`
  - [ ] SubTask 5.1: `struct WidgetParamDescriptor`（`key` / `title` / `kind`）+ `enum Kind { case toggle(default: Bool), stepper(default: Int, range: ClosedRange<Int>, note: String?), options([String], default: String) }`
  - [ ] SubTask 5.2: `struct WidgetDescriptor`（`name` / `title` / `params`）+ `static let all: [WidgetDescriptor]`，与 `HomeWidgetRegistry` 的 7 个控件一一对应：`home.header`/`home.quickEntryRow`/`home.placeholder` 无参数；`home.marketOverview` `compact`；`home.favorites` `compact` / `showsSparkline` / `limit`（0…20，note「0 = 全部」）；`home.simSummary` `compact`；`home.topGainers` `style`（list/chips）+ `compact`
  - [ ] SubTask 5.3: `static func descriptor(for name: String) -> WidgetDescriptor?` 与 `static let nodeTypeTitles: [String: String]`（9 种节点类型的中文显示名）

- [ ] Task 6: 编辑态模型 `Kline/Home/Editor/PageLayoutEditorModel.swift`
  - [ ] SubTask 6.1: `@MainActor final class PageLayoutEditorModel: ObservableObject`；`@Published`：`styleID`（初始 `PageLayoutStore.shared.homeLayout.rawValue`）、`file: PageLayoutFile?`、`selectedUUID: UUID?`、`collapsed: Set<UUID>`、`jsonText: String`、`jsonError: String?`、`showsJSONTab: Bool`、`banner: String?`
  - [ ] SubTask 6.2: `loadFromStore()`：从 `PageLayoutConfigStore.currentFile(page:)` 取底本（不可用时用 `resetToBuiltIn` 后的结果），记录 `savedText = canonicalText(file)` 作为脏标记基准
  - [ ] SubTask 6.3: 派生：`layoutRoot: PageLayoutNode?`（当前档位的 root）、`isDirty: Bool`（`canonicalText(当前 file) != savedText`）、`syncJSONText()`（把 `jsonText` 设为当前草稿的规范文本）
  - [ ] SubTask 6.4: 树查询：`func node(for uuid:) -> PageLayoutNode?`、`func parent(of uuid:) -> (parent: PageLayoutNode, index: Int)?`（遍历整棵树按 uuid 匹配）
  - [ ] SubTask 6.5: 树编辑：`select(_:)`、`toggleCollapse(_:)`、`move(fromOffsets:toOffset:)`（**仅同级**；跨级则设 `banner = "仅支持同级重排"` 并返回）、`insertNode(type:into:)`、`insertWidget(name:into:)`、`removeNode(_:)`（删除后清理选中与折叠集合）—— 规则：选中容器 → 追加到其容器子节点末尾；选中非容器 → 追加到父容器内该节点之后；未选中 → 追加到根容器末尾；根不是容器时报 `banner` 并拒绝
  - [ ] SubTask 6.6: 参数编辑：`func setBool(_ key:_ value:on:)` / `setInt(...)` / `setString(...)`（写进 `node.params`，缺 `params` 时先建空 `WidgetParams`）
  - [ ] SubTask 6.7: JSON 页签：`func generateJSONFromTree()`、`func applyJSONToTree()`（解析失败 → `jsonError` 有值且草稿不变）
  - [ ] SubTask 6.8: 动作：`save() -> Bool`（`PageLayoutConfigStore.save` + 更新 `savedText` + `banner = "已保存"`）、`resetToDefault() -> Bool`（`resetToBuiltIn` → 重新 `loadFromStore` → `banner = "已恢复默认"`）

- [ ] Task 7: 页面骨架 `Kline/Home/Editor/PageLayoutEditorView.swift`
  - [ ] SubTask 7.1: 顶部栏逐项对齐 `FormulaCenterView.header`：左「返回」胶囊（chevron.left 16 semibold + 「返回」15 medium、`Color.gray.opacity(0.12)`、`cornerRadius(8)`、`padding(.horizontal,10)/.vertical,6)`、`padding(.leading,16)`）、居中「布局编辑器」17 semibold、右侧「全屏预览」胶囊
  - [ ] SubTask 7.2: 档位行：A/B/C/D 分段（读写 `editor.styleID`），右侧显示该档 `title`
  - [ ] SubTask 7.3: 页签行：「表单」/「JSON 原文」分段 + 右侧「保存」/「恢复默认」胶囊（恢复默认先弹确认）
  - [ ] SubTask 7.4: 上半编辑区（`frame(maxHeight: .infinity)` 占一半）：表单页签 = `LayoutNodeTreeList`(宽 320) + `Divider` + `LayoutNodeInspector`；JSON 页签 = 通栏 `TextEditor`（等宽 12、`autocorrectionDisabled`、自绘圆角边框）+ 下方「由当前树生成」/「应用到树」+ 错误文案
  - [ ] SubTask 7.5: 下半预览区（占一半）：`HomeLayoutPreviewPane` 通栏
  - [ ] SubTask 7.6: 底部状态条：`未保存改动` / `已保存` / `已恢复默认` / JSON 错误（固定高度，文字不抖动）
  - [ ] SubTask 7.7: `.overlay { if showFullPreview { HomeLayoutFullPreviewView(...) } }`；`.onAppear { editor.loadFromStore() }`；返回时若 `editor.isDirty` 先弹确认
  - [ ] SubTask 7.8: `@StateObject private var previewModel = HomePageModel()` 供两处预览共用（真实数据）

- [ ] Task 8: 树列表与检查器
  - [ ] SubTask 8.1: `LayoutNodeTreeList.swift`：把当前档位节点树扁平化成 `[(node, depth)]`（折叠的容器跳过其子树）；`List` 行 = 缩进 + 展开箭头（容器）+ 类型/控件显示名 + 摘要（`card` 显标题、`widget` 显控件名、`scroll` 显轴与间距）；选中行高亮；`.onMove` 接 `editor.move(fromOffsets:toOffset:)`
  - [ ] SubTask 8.2: 树列表底部工具条：「+ 添加节点」`Menu`（9 种节点类型）+「+ 添加控件」`Menu`（7 个控件）→ 调 `insertNode` / `insertWidget`
  - [ ] SubTask 8.3: `LayoutNodeInspector.swift`：按 `node.type` 分支生成字段表单 —— `vstack`/`hstack`/`zstack`（spacing 步进 + alignment 选项）、`scroll`（axis 选项 + spacing 步进 + 四边 padding 步进 + showsIndicators 开关）、`card`（title 输入 + compact 开关）、`frame`（maxWidth infinity 开关 + alignment 选项 + minHeight 步进）、`widget`（控件名下拉 + 该控件参数按 `WidgetConfigDescriptor` 生成控件）；行内 `Divider` 分隔、每组固定行高
  - [ ] SubTask 8.4: 检查器底部「删除本节点」按钮（根节点禁用）+ 未选中时的引导文案（「在左侧选择节点开始编辑」）
  - [ ] SubTask 8.5: 所有可点元素命中区 ≥ 44pt，行高固定（点击与切换不抖动）；颜色全走语义色

- [ ] Task 9: 两处预览
  - [ ] SubTask 9.1: `HomeLayoutPreviewPane.swift`：顶部一行（「预览（只读）· 档位 X」+「全屏」按钮），下方 `ScrollView` 内 `PageLayoutRenderer(registry: HomeWidgetRegistry.shared.registry, context: HomeLayoutContext(model:previewModel, onProfile:{}, onEntry:{_ in}, onSelectTab:{_ in}))` 渲染 `editor.layoutRoot`；整块 `.allowsHitTesting(false)`（仅顶部工具条可点）
  - [ ] SubTask 9.2: 保证 1:1 宽度（不做 `scaleEffect`），草稿任一变化立即重绘
  - [ ] SubTask 9.3: `HomeLayoutFullPreviewView.swift`：铺满页面；顶部栏「返回」胶囊 + 居中「预览 · 档位 X」+ 右侧「预览模式 · 入口与 Tab 切换不生效」提示；下方 1:1 真实渲染（可交互，点行情行会打开 K 线详情）
  - [ ] SubTask 9.4: 全屏预览用独立 `HomeLayoutContext`（业务回调走 `HomeLayoutContext` 的空实现，`openDetail` 仍由 `HomeWidgetRegistry` 内部持有，不改引擎）

- [ ] Task 10: 个人中心入口
  - [ ] SubTask 10.1: [TradingLayoutSettings.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/TradingLayoutSettings.swift) 新增 `LayoutEditorSettingRow { onOpen }`：左「布局编辑器」16pt + 右 `HStack { Text("首页") ; Image(systemName: "chevron.right") }`（12pt、蓝色）、`frame(minHeight: 36)`、整行 `contentShape(Rectangle())` + `.onTapGesture`
  - [ ] SubTask 10.2: [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift) 在「首页布局」行之后、`FormulaCenterSettingRow` 之前插入该行（`.padding()` + `secondarySystemBackground` + `cornerRadius(12)`，与其余行同构）
  - [ ] SubTask 10.3: 新增 `@State private var showLayoutEditor = false` + 容器层 overlay（`ZStack { PageLayoutEditorView(onClose: { showLayoutEditor = false }) }` + `.transition(.opacity)` + `.zIndex(1000)`）
  - [ ] SubTask 10.4: 浮层互斥链由 7 项扩为 8 项（新增 `showLayoutEditor` 的 `onChange`，并把它加入其余 7 个 `onChange` 的清除列表）

- [ ] Task 11: 阶段二闭环
  - [ ] SubTask 11.1: 编码自查（不在 `body` 内做整树遍历重算、`List` 行的身份用 `uuid`、`@Published` 同值不写、行高固定、命中区 ≥ 44pt）
  - [ ] SubTask 11.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(layout-editor): 个人中心入口 + 全屏布局编辑器（改参数/顺序 + 双预览 + 保存/恢复默认）"`
  - [ ] SubTask 11.3: 交付说明（build 号 / 改动与理由 / 真机验证路径）

## 阶段三：搭积木 + JSON 原文

- [ ] Task 12: 节点增删与控件切换走通
  - [ ] SubTask 12.1: 校验 Task 8.2 的两个 `Menu`（添加节点 / 添加控件）在三种选中状态下都可用（选中容器 / 选中非容器 / 未选中）
  - [ ] SubTask 12.2: 检查器里的控件名下拉可把 `widget` 节点换成另一个控件（`name` 改写后清空旧 `params`，避免残留无关键）
  - [ ] SubTask 12.3: 「删除本节点」对含子树的容器整棵移除；根节点按钮禁用并给出说明
  - [ ] SubTask 12.4: 新增 `card`/`frame`（`child` 语义）节点后，检查器里「添加子节点」把 `child` 置为单一子节点（已有 `child` 时替换并提示）

- [ ] Task 13: JSON 原文页签走通
  - [ ] SubTask 13.1: `TextEditor` 等宽 12、`autocorrectionDisabled`、固定行高区域、自绘 `RoundedRectangle` 边框（语义色）
  - [ ] SubTask 13.2: 「应用到树」成功 → 刷新预览 + 清空 `jsonError` + 状态条提示；失败 → 显示错误原因（含 `DecodingError` 的可读描述）且草稿与预览不变
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