# Checklist

> 状态说明：✅ = 已核验通过（独立只读核验代理逐条核验 + 云端构建产物）。⏳ = 需设备解锁 + Kline 在前台的真机动作，本轮三次交付均因「设备无人值守」停在云端构建成功，**待用户真机验收**。

## 阶段一：模型可变 + 编解码 + 写接口

- [x] `PageLayoutNode` 全字段为 `var`，且新增 `let uuid` 不参与编解码（`CodingKeys` 无 uuid、`init(from:)` 重新生成、`encode(to:)` 不输出）
- [x] `PageLayoutNode.encode(to:)` 只输出与 `type` 相关的字段（`vstack`/`hstack`/`zstack` 只写 spacing/alignment/children；`widget` 不写 spacing；`divider`/`spacer` 只写 `type`）
- [x] 编解码往返一致：`decode(encode(file))` 与原 `file` 业务字段一致；空 `params` 被省略（渲染侧 `node.params ?? WidgetParams()` 已把 nil 归一为空表，语义等价）
- [x] `PageLayoutPadding` 只输出非 0 的边；`PageLayoutWidth` 的 `"infinity"` 与数字都能正确往返
- [x] `WidgetParams.values` 可写；`WidgetParamValue` 可编码
- [x] `PageLayoutFile.defaultLayoutID` 双向映射 JSON 的 `"default"` 键，往返不丢字段
- [x] `PageLayoutNode.make(type:)` 对 9 种合法 type 都能给出合理默认值，非法 type 返回 nil
- [x] 树操作便捷成员齐备且语义正确：`containerKey`（`vstack`/`hstack`/`zstack`/`scroll` → `.children`，`card`/`frame` → `.child`，其余 → nil）、`childList`、`appendChild`（`.child` 替换并返回 true）、`removeChild(uuid:)`、`flattened()`、`firstNode(uuid:)`、`firstParent(of:)`
- [x] `PageLayoutCodec` 方法齐备（`decode` / `encode` / `canonicalText` / 阶段二追加的 `decodeResult`），`encode` 用 `.prettyPrinted + .sortedKeys + .withoutEscapingSlashes`，输出可直接落盘与展示
- [x] `PageLayoutConfigStore` 已无自带 `JSONDecoder`，解码统一走 `PageLayoutCodec`（`reload` / `resetToBuiltIn` 均复用）
- [x] `save(_:page:)` 写沙盒后同步 `lastModDates`，不破坏「同值不写」与 `reloadIfChanged`
- [x] `resetToBuiltIn(page:)` 能把内置默认文本写回沙盒并生效；未注册 / 解码失败 / 写失败均返回 false 不崩溃
- [x] `builtInText(page:)` / `currentFile(page:)` 可用
- [x] 阶段一未改动任何 UI 文件：首页四档呈现、JSON 优先 + 硬编码回退链、无障碍锚点全部不变
- [x] 阶段一独立可编译并已交付：**run=35621629404**

## 阶段二：编辑器可用

### 入口与页面
- [x] 个人中心新增「布局编辑器」行，位置在「首页布局」行之后、公式管理之前
- [x] 该行整行可点且命中区 ≥ 44pt（`.frame(minHeight: 44)`，核验后已由 36 修正为 44）；右侧为蓝色「首页」+ `chevron.right`
- [x] 点击后全屏打开布局编辑器；顶部栏逐项对齐 `FormulaCenterView.header`（返回胶囊样式、居中标题 17 semibold、右侧胶囊）
- [x] 个人中心浮层互斥链已扩为 **8** 项，且 7 个既有 `onChange` 的清除列表里都含 `showLayoutEditor = false`
- [x] 编辑器默认停在 `PageLayoutStore.homeLayout` 对应的档位
- [x] 未保存改动时点「返回」会先弹确认

### 模型与编辑
- [x] `PageLayoutEditorModel` 用 `PageLayoutConfigStore.currentFile` 取底本；取不到时先 `resetToBuiltIn` 再取
- [x] 脏标记用**规范化 JSON 文本**比较（不使用 `Equatable`，避免 `uuid` 击穿）
- [x] `firstParent(of:)` 遍历定位父节点与下标，根节点无父时返回 nil
- [x] `move(fromOffsets:toOffset:)` 仅同级生效；跨级不改顺序并给出「已忽略跨级拖动：仅支持同级重排」
- [x] `moveSelectedUp/Down` 在边界给出「已到本层顶部/底部」提示；`.child` 容器与根节点不可重排
- [x] 选中容器 → 新节点追加到该容器末尾；选中非容器 → 追加到父容器内其后；未选中 → 追加到根容器末尾
- [x] 根节点不是容器时增删操作被拒并给提示，不崩溃
- [x] 参数编辑写进节点 `params`，缺 `params` 时自动创建空表；换控件名时清空旧 `params`（同名早退）

### 树列表与检查器
- [x] 树列表按缩进体现层级、容器可折叠、点击选中（行身份用 `LayoutTreeRow.id = node.uuid`）
- [x] 树列表 `List` 行高固定 44、命中区 ≥ 44pt、颜色全走语义色
- [x] `.onMove` 已接 `editor.move`；并提供「排序/完成」开关（iOS 15 下 `List` 的 `.onMove` 只在编辑态生效）与「上移/下移」作为精确重排路径
- [x] 检查器按 `node.type` 分支生成字段：`vstack`/`hstack`/`zstack`（spacing、alignment）、`scroll`（axis、spacing、四边 padding、showsIndicators）、`card`（title、compact）、`frame`（maxWidth infinity、alignment、minHeight）、`widget`（控件名 + 该控件参数）
- [x] `widget` 参数表单由 `HomeWidgetEditorSchema` 驱动，7 个控件与 `HomeWidgetRegistry` 一一对应，参数键与实际使用一致（`compact` / `showsSparkline` / `limit` / `style` 三处口径相互校验）
- [x] 检查器底部「删除本节点」可用，根节点禁用并给出说明
- [x] 未选中节点时检查器显示引导文案

### 预览
- [x] `HomeLayoutPreviewPane` 始终显示当前草稿档位的 1:1 渲染（不做 `scaleEffect`）
- [x] 预览使用真实 `HomePageModel` 数据（`@StateObject` 在编辑页创建，两处预览共用）
- [x] 预览滚动区不响应点击（`.allowsHitTesting(false)`），工具条的「全屏」是真 `Button`（带 `accessibilityIdentifier("layoutEditor.preview.expand")`）
- [x] 草稿任一变化（参数 / 顺序 / 增删 / JSON 应用）都会立即重绘预览（所有改动方法均调 `touchDraft()`）
- [x] 全屏预览铺满页面、可交互（点行情行能打开 K 线详情），顶部标注「预览模式 · 入口与 Tab 切换不生效」且有返回
- [x] `HomeWidgetRegistry` 内部持有的 `openDetail` 未被改动（diff 为空），两处预览共用同一注册表

### 保存与恢复默认
- [x] 「保存」写回 `Documents/Layouts/home.json`，状态条显示「已保存」
- [x] 保存后返回首页立即呈现新配置（`HomeView` 观察 `PageLayoutConfigStore.shared`，`apply` 会发布）
- [x] 「恢复默认」先弹确认，确认后沙盒被内置默认覆盖、草稿与首页同步回到内置默认
- [x] 状态条在「未保存改动 / 已保存 / 已恢复默认 / JSON 错误」间切换时文字不抖动（固定高 28 + `lineLimit(1)`）

- [x] 阶段二独立可编译并已交付：**run=35624017142**

## 阶段三：搭积木 + JSON 原文

- [x] 「添加节点」`Menu` 覆盖 9 种节点类型，新增后结构合法、可继续在检查器编辑
- [x] 「添加控件」`Menu` 覆盖 7 个控件，新增的 `widget` 节点 `name` 在注册表内（预览不出现「未注册控件」占位）
- [x] 控件名下拉切换控件时旧 `params` 被清空，不残留无关键（同名重复选择不改动，避免误清）
- [x] 删除含子树的容器会整棵移除，且预览同步更新
- [x] 对 `card`/`frame`（`child` 语义）添加子节点时，已有 `child` 会被替换并提示
- [x] JSON 原文 `TextEditor` 等宽 12、关闭自动纠错、有语义色圆角边框
- [x] 「应用到树」成功 → 换树 + 清选中/折叠 + 清除错误 + 状态提示；失败 → 显示可读错误原因（含 `DecodingError` 位置路径）且草稿与预览不变
- [x] 「由当前树生成」产出的文本与保存到沙盒的文本一致（同走 `canonicalText`）
- [x] 切到 JSON 页签时自动由当前树生成文本，不显示过期内容
- [x] 阶段三独立可编译并已交付：**run=35625454063**（编译与打包全绿；仅最后一步 GitHub Release 上传遇 API HTTP 500 服务端瞬时错误）

## 真机验收

- [ ] ⏳ 编辑器可从个人中心打开，四档可切换，树能完整展示当前档位结构
- [ ] ⏳ 改参数（spacing / compact / limit / style）后页内预览立即变化
- [ ] ⏳ 「排序」模式下拖动重排生效（或「上移/下移」生效）；跨级拖动被拒并有提示
- [ ] ⏳ 新增 / 删除节点与控件生效
- [ ] ⏳ JSON 原文可生成、可应用；写坏 JSON 报错且草稿不变
- [ ] ⏳ 保存后返回首页立即呈现新布局；恢复默认回到内置默认；未保存返回有提示
- [ ] ⏳ 回归：首页四档呈现、快捷入口、点行开 K 线详情、搜索、公式管理中心、条件单、个人中心、`home.page` 锚点均正常
- [ ] ⏳ 沙盒 `Documents/Layouts/home.json` 内容与编辑器保存的一致

## 工程与交付

- [x] 新增文件无需手改 `Kline.xcodeproj`（Swift 文件走同步组；已确认工程文件无对新文件的显式引用）
- [x] 保留不动的文件确实未被改动：`HomeView.swift` / `PageLayoutRenderer.swift` / `PageWidgetRegistry.swift` / `HomeWidgetRegistry.swift` / `Widgets/` 下 11 个控件 + `HomeWidgetPalette.swift` 配色助手 / `PageLayoutStore.swift`（`git diff` 均为空）
- [x] 三个阶段各自独立可编译：run=35621629404（阶段一）、run=35624017142（阶段二）、run=35625454063（阶段三，编译通过）
- [ ] ⏳ 三个阶段各自可真机演示（构建产物已就绪，待设备解锁后在设备上安装验收）
- [x] 每个阶段交付说明了 build 号、改动与理由、真机验证路径与回归点

---

# 第二轮：控件内容可配置

> 状态说明：✅ = 独立只读核验代理逐条静态核验通过（含 4 处修复复核），并由 test98/test99 在 iPad mini 5 模拟器实跑通过；🧪 = 沙盒注入实测；👤 = 需用户在真机/模拟器目视（并入第一轮 Task 15）。用例实际编号 test98/test99（规划的 96/97 因编号被既有批量用例占用而顺延）。

## 阶段五：参数引擎扩展

- [x] ✅ `WidgetParamValue` 含 `strings([String])` case；解码顺序为先 `[String]` 后 Int→Double→Bool→String，数组与四类标量互不误读
- [x] ✅ `WidgetParams.strings(_:)` 返回可选：缺键/类型不符 = nil；键存在为 `[]` 时返回空数组（两语义可区分）；另补 `optionalString(_:)`
- [x] ✅ `"entries": ["search","tech"]` 经 Codec 解码→再编码后内容与顺序一致；`canonicalText` 输出含数组且 sortedKeys 下稳定
- [x] ✅ 仅含 `"entries": []` 的参数表不会因 isEmpty 被整表省略（空数组是有效配置）
- [x] ✅ 旧版兼容推演：旧 App 读数组参数时 WidgetParams `try?` 兜底空表、不崩溃
- [x] ✅ `Kind.orderedList(source:maxCount:note:)` 与 `Kind.dynamicOptions(source:note:)` 定义齐备；`ParamCandidate` 只含基础类型，文件仅 import Foundation
- [x] ✅ WidgetParamCandidateProvider 四源正确：entries=HomeEntryKind 全量；indices=沪深京指数（候选按名称排序；默认序列取库顺序前 4 对齐渲染）；groups 首项「全部」(固定 allGroupID)；accounts 首项「全部账户」(固定 allAccountID)
- [x] ✅ `setStrings` / `removeParam` / `listAppend` / `listRemove` / `listMove`：去重、maxCount 拦截与 banner 提示正确，全部触发 touchDraft，同值不写
- [x] ✅ OrderedListParamRow：行高 44、命中区 44pt（核验后由 40 修正）、上移/下移/删除可用、「可添加」只列未选项、达上限全部置灰并说明、空选有来源专属引导（indices 空选提示回落前 4）；🧪 展开后 `ScrollViewReader` 自动把「已选」区定位到检查器可视顶部（修复首行被底部删除栏遮挡、点击落空；test98/99 复跑验证）
- [x] ✅ DynamicOptionsParamRow：首项（默认项）= 删键（核验后由写固定 id 修正）；选中项名称实时显示
- [x] ✅ 检查器经 DynamicCandidatesReader 订阅 $metaList/$groups/$accounts，候选随数据变化即时刷新
- [x] ✅ 阶段五后首页四档默认呈现零变化（HomeLayoutDefaults 零改动；test98/99 起点均先恢复默认）

## 阶段六：快捷入口自由装配

- [x] ✅ HomeEntryKind 新 case `alertRecords` / `layoutEditor` 的 title/subtitle/icon/tint/formulaKind 齐备，追加在枚举末尾，既有 6 个 rawValue 不变
- [x] ✅ HomeOverlayTarget 两新 case 与 HomeOverlays 两全屏分支呈现正确（共用 opacity + zIndex 1000，页内返回关闭）
- [x] ✅ HomeView.perform 两新分支可达；单值 overlayTarget 无堆叠，两处预览 onEntry 为空闭包，从编辑器内无法再开第二层
- [x] ✅ B/C/D 回退视图 switch 全部补全编译通过，新闭包由 HomeView 注入；回退视图快捷行仍为默认全部入口
- [x] ✅ HomeQuickEntryRow 收 kinds 入参：缺省 8 项顺序正确；显式集合保序/去重（核验后补齐）/过滤未知 rawValue；空数组零高度无内边距残留
- [x] ✅ schema 中 quickEntryRow 的 `entries` 描述（orderedList/.entries/无上限/note）与渲染读取键一致
- [x] ✅ 新锚点 `home.entry.alertRecords` / `home.entry.layoutEditor` 存在；既有 6 锚点不变
- [x] ✅ 编辑器内增删移入口时页内预览即时变化（test98 覆盖）；全屏预览点击入口不生效（onEntry 空闭包）

## 阶段七：四个内容控件数据源选择

- [x] ✅ indexRows：nil/空→前 4；显式 id 保序解析、去重、失效过滤；0 个有效 id→回落前 4（核验后修正空数组与全失效两路径）；指数点击仍开对应 K 线（行复用既有 MarketRow）
- [x] ✅🧪 indices 参数 maxCount = 4，编辑器选满后候选全部禁用（test99 覆盖）
- [x] ✅ favoriteRows(groupID:limit:)：全部固定 id/实体分组/非法 id 三路径正确；limit 0=前 5、1…20 生效；空分组显示既有空态、空态点击切自选页
- [x] ✅ simSummary/topPositions 按 accountID 字符串解析：非法/缺省=全部；具体账户下总资产、盈亏、持仓均只含该账户
- [x] ✅ topGainers(board:)：mainBoard=`["沪深主板"]`、etfIndex=`["沪深京指数","扩展行情指数"]`，两套在同一次遍历内预算；breadth 始终主板口径（ETF 不算涨跌停）
- [x] ✅ 注册表四个 builder 的参数键（indices/group/account/board）与 schema 描述、model 方法三处一致
- [x] ✅ favorites 的 limit 描述 note 已改为「0 = 默认前 5」
- [x] ✅🧪 默认配置文件不新增任何参数键（HomeLayoutDefaults 零改动；沙盒默认 home.json 四档实测均无 entries/indices）；「恢复默认」回到第一轮完全一致的呈现（test98/99 收尾断言）
- [x] ✅ JSON 原文页签：数组与单选取值可生成、可应用（沿用 Codec/decodeResult）；写坏元素类型有可读错误且草稿不变；坏 id 不阻断解析（渲染侧各路径均有过滤/回落）

## 阶段八：测试与验收

- [x] ✅ test98_Home_QuickEntriesConfigurable 在 iPad mini 5 模拟器通过（实跑 89s）：删除/排序→首页锚点集合与顺序即时生效→杀进程重启持久化→恢复默认回齐
- [x] ✅ test99_Home_MarketOverviewIndicesConfigurable 通过（实跑 121s）：默认 4 只、删后候选可点、加回 4/4 全部候选 isEnabled=false、持久化、恢复默认
- [x] ✅ 既有锚点静态零改动（旧 6 入口 id、树/检查器锚点为新增）；既有批量用例 test91/92/93/95/96/97 保持可编译
- [x] ✅ xcodebuild 在 iPad mini 5（UDID 54291852）完成 build-for-testing 与部署；模拟器全程经 Simulator.app GUI 可见
- [ ] 👤 真机/模拟器目视验收：8 默认入口；入口增删移/清空；触发记录与布局编辑器两入口开合；分组/账户/板块参数切换；保存生效；恢复默认；A/B/C/D 四档配置相互独立（自动化已覆盖 entries/indices 主链路）
- [x] ✅🧪 沙盒 `Documents/Layouts/home.json`：注入 entries/indices 后首页按序渲染 4 入口 2 指数，恢复默认后键消失；近 15 分钟日志无 error/crash/紫警
- [ ] 👤 回归目视：四档布局、点行开 K 线、搜索、公式中心三分段、条件单、个人中心、悬浮按钮延迟 1 秒显示正常
- [x] ✅ 第二轮独立只读核验代理逐条核验（1 中 3 低全部修复并复跑 test98/99 通过）；无临时诊断标识；注入文件已还原
- [x] ✅ 变更已按版本管理规范提交并 push（afb1097；核验修复与文档回填为后续补充提交）

## 阶段九：拖拽装配（跨级拖入容器）——第三轮

- [ ] 接收方与 `containerKey` 判定严格一致：`vstack/hstack/zstack/scroll`（`children`）与 `card/frame`（`child`）接收（拖到行中间区）；`widget/divider/spacer` 无中间区（上/下半区 = 同级前后插）
- [ ] 拖拽源 = 除根节点外的所有行；根行不注册 `.onDrag`，但可接收拖入（四档根为 `vstack`）
- [ ] 折叠态容器行同样接收，且拖入后该容器自动展开
- [ ] 单槽容器（card/frame）非空替换有 banner「该容器仅容纳一个子节点，已替换」明确告知
- [ ] 拖回原处（原父 == 目标 且 已在末尾）为无操作：不写草稿、不置脏，仅给提示
- [ ] 自环防护生效：拖入自身或子孙（中间区）**红底红框** + 松手后被拒 + banner，杜绝 `children` 成环导致的 `encode` 无限递归（**不得出现崩溃**）
- [ ] 拖拽取消 / 拖出列表外：落点高亮消失、拖拽状态完全复位，草稿不变
- [ ] 拖入成功走 `touchDraft()` → 预览即时刷新；`select(被拖节点)` 生效；落点高亮（蓝/红）与选中蓝底视觉可区分
- [ ] 拖拽悬停不写 `banner`（避免刷掉真实提示）；仅松手后被拒时由模型写 banner
- [ ] 既有 `moveSelectedUp/Down` / `canMoveSelected` 零改动（上移/下移按钮行为与之前完全一致）；新增的是 `move(beforeSibling:)/move(afterSibling:)`。`move(fromOffsets:toOffset:)` 随 `List.onMove` 一起退出使用（去 `List` 后已无调用方，方法本体保留未改）
- [ ] **无需任何开关**：一次拖拽按落点分区自动判定意图——容器行 上边缘 12pt=前插 / 中 20pt=拖入 / 下边缘 12pt=后插；叶子行 上半=前插 / 下半=后插（原「排序」开关与锚点 `layoutEditor.sortingToggle` 已删除）
- [ ] 同级前插/后插走 `move(beforeSibling:)/move(afterSibling:)`（按父容器 `childList` 兄弟定位，不再吃扁平行下标）→ 拖到「有子节点的容器行」下边缘区能正确插到该容器之后，不再被误判跨级
- [ ] 不同父的插入判 `.crossLevel` 拒绝并给 banner「跨级移动请拖到容器行中间区，同级排序请拖到同级行上/下边缘」
- [ ] 悬停反馈三态齐备：前插/后插 = 行顶/行底 2pt 蓝线（`insertionLine`）；拖入 = 蓝底 + 蓝框；非法 = 红底 + 红框
- [x] 节点树改为 `ScrollView + LazyVStack` 后：点击选中、折叠展开、滚动、行高 44 与既有锚点（`layout.tree.<type>` / `layout.tree.widget.<name>`）均正常；树列表 `ScrollView` 新增测试锚点 `layoutEditor.treeList`（供测试读真实可视区）
- [x] `PageLayoutSchema.swift` 与 `HomeLayoutDefaults.swift` 零改动；配置 JSON 格式与既有键语义不变
- [x] test100_Home_EditorDragNodeIntoStack 在 iPad mini 5 模拟器实跑通过（84.5s）：拖到滚动区行**中间区**，JSON 行缩进 **+4 空格**（节点深度 +1，JSON 结构层差 4）、位于目标容器子节点末尾、保存后杀进程重启仍保持、恢复默认正常
- [x] test101_Home_EditorDragInvalidTarget 实跑通过（92.8s）：① 拖滚动区到其子孙卡片行中间区 → banner「不能把节点拖入它自己或它的子节点」且结构不变；② 跨级插入（大盘概览行中心 → 相邻的卡片行上边缘区）→ banner「跨级移动请拖到容器行中间区，同级排序请拖到同级行上/下边缘」且结构不变
- [x] test102_Home_EditorDragReorderSibling 实跑通过（75.6s）：拖快捷入口行到 `home.header` 行**上边缘区** → 缩进不变、顺序变为排在 `home.header` 之前、保存后杀进程重启仍保持、恢复默认正常
- [x] 测试落点几何：`treeViewport`（`layoutEditor.treeList`）+ `treeRowRect`（同行元素并集 + 纵向居中补余量）+ `TreeDropZone` 三态；可见性按「行 rect 完整落在可视区」判定，不用 `isHittable`（`ScrollView + LazyVStack` 会把屏外行也报进无障碍树且 `isHittable` 仍为 true，直接按 frame 算落点会打到工具栏按钮弹 Menu 吃掉手势）
- [x] 回归：test96/97/98/99 复跑通过（25.4s / 23.8s / 73.8s / 108.6s）；test91（ETF 种子库二级菜单）、test92（刘海机型横向安全区）在 iPad mini 5 上属既有环境性失败
- [x] 沙盒 `Documents/Layouts/home.json` 核对：可解析、schemaVersion/四档结构完整、B 档根子节点顺序为默认（`header → divider → quickEntryRow → scroll(card 大盘概览 / hstack(frame,frame) / card 涨幅榜)`，即用例末尾「恢复默认」已落盘）；`Documents/debug_log.txt` 无 error/fatal/crash，无残留诊断日志
- [x] 相对已批准草案的实现偏差已在 spec.md 记录（去 `List`、**删除「排序」开关改统一落点分区**、叶子落点无系统禁止光标、行分隔线自绘、新增 `DropRejection.crossLevel` 与按兄弟重排 API）
- [ ] 变更已按版本管理规范提交并 push

## 阶段十：编辑器全屏化与页面瘦身（第四轮，2026-09-25）

- [x] 编辑器由「首页内部 overlay」改为「`ContentView` 根 ZStack 呈现」（新增 `HomeLayoutEditorRouter`，与 `DetailRouter` 同做法）→ 铺满整屏、**底部导航栏被完全盖住**
- [x] `HomeOverlayTarget` 删除 `.layoutEditor` 分支（case / id / `HomeOverlays` switch 臂），无死代码残留；`HomeView.onOpenLayoutEditor()` 改为置位 router
- [x] 个人中心入口不改（`ProfileDetailView` 本身即根层全屏覆盖层，其内编辑器本就铺满整屏）
- [x] 页内常驻预览删除：`HomeLayoutPreviewPane.swift` 文件删除（同步组自动移出 target）、`PageLayoutEditorView` 移除该视图与两条分隔线、「全屏预览」胶囊保留（锚点 `layoutEditor.fullPreview`）
- [x] `PageLayoutEditorModel.styleTitle` 无引用后删除
- [x] 四档切换（A/B/C/D 分段）由独立「档位行」并入 `header` 单行：返回 / 标题 / 分段 / ←Spacer→ 全屏预览；新增锚点 `layoutEditor.stylePicker`
- [x] 编译通过；编辑器相关 5 个用例实跑通过：test98（72.2s）、test99（101.3s）、test100（80.6s）、test101（69.6s）、test102（73.1s）
- [ ] 用户设备验收：编辑器铺满整屏（底栏不可见）、无页内预览、四档切换在标题行、内容区明显变高
- [x] 变更已按版本管理规范提交并 push（commit 0117a56，已推到 `main`）

## 阶段十一：ProfileView 控件 / 容器盘点（文档补充，第五轮前置侦察，2026-09-25）

> 用户原话：「请你详细梳理 `Kline/Profile/ProfileView.swift` 中的所有控件和容器，给 `.trae/specs/add-layout-editor` 做补充」。本轮**零代码改动**，结论落在 spec.md「附录 A」。

- [x] 盘点范围覆盖 `ProfileView.swift` 全文 + 三个被引用组件（`HorizontalScrollCard.swift` / `ListCard.swift` / `DetailPage.swift`）+ 数据源 `MockData.swift`
- [x] 容器清单 8 项逐项对映节点词表：根 `vstack` / 导航栏 `hstack` / 主内容 `vstack` / 左右分栏 `hstack` / 左右两个 `scroll` / 左右两个内层 `vstack`；确认本页**不使用** `zstack` / `card` / `frame`
- [x] 控件清单：返回 `Button` ×1、标题 `Text` ×1、`Spacer` ×1、`Divider` ×1、占位 `Rectangle` ×3、`HorizontalScrollCard` ×6（含 `HorizontalCardItemView` 图标型 / 文字型两支）、`ListCard` ×3、`DetailPage` overlay ×1
- [x] 数据来源与复用：`MockData` 7 个常量 → 9 个卡片实例（`appRecommendData`、`moreHotNewsData` 各用两次）；登记 `let id = UUID()` 的 UUID 击穿风险与「同一 widget 可重复出现、节点树无需去重」结论
- [x] 候选池界定：2 个候选 widget（`profile.hscrollCard` / `profile.listCard`，参数 = 数据源 id）+ 7 个数据源候选；3 个占位 `Rectangle`、顶部导航栏、`DetailPage` 明确排除
- [x] 缺口登记 7 项（`page` 键硬编码 `"home"`、配置仓库无 page→文件映射、`HomeWidgetRegistry` 未注册本页卡片、数据源为编译期常量不可枚举、`PageLayoutRenderer` context 是首页专用、**本页零无障碍锚点**、本页为纯 mock 演示页）
- [x] 关键结构结论：本页是首页的简化镜像，左右**双列各自独立滚动**为独有结构；`scroll` 词表已支持 `axis/spacing/padding/showsIndicators`，骨架可由现有节点树完整表达
- [x] 本轮未触任何 `.swift` 文件（`git status` 仅 spec 文档变更）

## 阶段十二：把测试页面的控件吸收为「通用控件」（第五轮，2026-09-25）

> 方向修订：**不**把 ProfileView 做成可编辑页；附录 A 转为「控件/容器词表缺口清单」，把测试页有、编辑器没有的类型抽成**页面无关的通用控件**（当前仍只编辑首页）。

- [x] 词表缺口核对完成：需补 3 项（横滑卡片 / 列表卡片 / 灰色占位块）；`scroll` / `hstack` / `vstack` / `divider` 与「左右双列各自滚动」已具备，容器词表**不改**
- [x] 参数引擎补自由文本能力：`WidgetParamDescriptor.Kind` 新增 `.text(placeholder:note:)` 与 `.textList(placeholder:note:)`（原有 5 种形态无法表达卡片标题 / 条目文案）
- [x] `LayoutNodeInspector.paramRow` 新增两分支：`.text` = `row` + 右对齐 `TextField`（对齐 `card` 标题字段写法）；`.textList` = 新 `TextListParamRow`（每行「序号 + 输入框 + 删除」+ 标题行右侧「添加一条」）
- [x] 存储复用既有 `WidgetParamValue.strings([String])` 与 `PageLayoutEditorModel.setStrings`，**JSON 结构不变**（无编解码改动）
- [x] 新文件 `Kline/App/PageLayout/CommonLayoutWidgets.swift`（页面无关引擎目录）：`CommonWidgetName`（`common.hscrollCard` / `common.listCard` / `common.placeholder`）
- [x] `registerCommonLayoutWidgets<Context>(into:)` 为**泛型函数且构建器忽略 Context**（只读 `WidgetParams`）→ 任何页面注册表可直接复用（「让绝大多数页面通用」的结构保证，非约定）
- [x] 三个视图视觉对齐测试页：卡片 `padding(16)` + `cornerRadius(12)` + `shadow(black 0.05, r4, y2)`；横滑卡右上角 `chevron.right`、列表卡右上角「更多」；列表序号前 3 条红色；条目为空渲染**可诊断提示**（不静默空白）
- [x] `CommonLayoutWidgetSchema` 描述三项控件参数（`title` / `items` / `updateTime` / `showsMore` / `height`）
- [x] 接入两行增量：`HomeWidgetRegistry.init` 末尾 `registerCommonLayoutWidgets(into: &r)`；`HomeWidgetEditorSchema.all` 末尾 `+ CommonLayoutWidgetSchema.all`
- [x] 编译通过 + 安装启动成功（`kline_deploy_mac.sh`，iPad mini 5 模拟器 54291852，**BUILD SUCCEEDED**、`com.sunck.Kline: 23621`）
- [x] 代码变更已提交并 push（commit a9e07fc）
- [ ] 用户设备验收：编辑器「添加控件」里出现「横滑卡片 / 列表卡片 / 占位块」；选中后检查器出现新参数；填条目 → 全屏预览即时生效；重启后配置保持
- [ ] 回归点：既有 7 个 `home.*` 控件、四档呈现、`home.json` 解码与既有锚点行为不变