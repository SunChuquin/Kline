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