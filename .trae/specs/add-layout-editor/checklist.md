# Checklist

## 阶段一：模型可变 + 编解码 + 写接口

- [ ] `PageLayoutNode` 全字段为 `var`，且新增 `let uuid` 不参与编解码（`encode(to:)` 不输出、`init(from:)` 重新生成）
- [ ] `PageLayoutNode.encode(to:)` 只输出与 `type` 相关的字段（`vstack` 不写 `title`、`widget` 不写 `spacing`、`divider`/`spacer` 无字段）
- [ ] 编解码往返一致：`decode(encode(file))` 与原 `file` 业务字段完全相同（`uuid` 除外）
- [ ] `PageLayoutPadding` 只输出非 0 的边；`PageLayoutWidth` 的 `"infinity"` 与数字都能正确往返
- [ ] `WidgetParams.values` 可写；`WidgetParamValue` 可编码
- [ ] `PageLayoutFile.defaultLayoutID` 仍映射到 JSON 的 `"default"` 键，往返不丢字段
- [ ] `PageLayoutNode.make(type:)` 对 9 种合法 type 都能给出合理默认值，非法 type 返回 nil
- [ ] 树操作便捷成员齐备且语义正确：`containerKey`（`vstack`/`hstack`/`zstack`/`scroll` → `.children`，`card`/`frame` → `.child`，其余 → nil）、`childList`、`appendChild`、`removeChild(uuid:)`
- [ ] `PageLayoutCodec` 三方法齐备（`decode` / `encode` / `canonicalText`），`encode` 用 `.prettyPrinted + .sortedKeys`，输出可直接落盘与展示
- [ ] `PageLayoutConfigStore.decode` 已改为复用 `PageLayoutCodec`，无重复实现
- [ ] `save(_:page:)` 写沙盒后同步 `lastModDates`，不破坏「同值不写」与 `reloadIfChanged`
- [ ] `resetToBuiltIn(page:)` 能把内置默认文本写回沙盒并生效；未注册内置默认时返回 false 不崩溃
- [ ] `builtInText(page:)` / `currentFile(page:)` 可用
- [ ] 阶段一未改动任何 UI 文件：首页四档呈现、JSON 优先 + 硬编码回退链、无障碍锚点全部不变
- [ ] 阶段一独立可编译并已交付（给出 build 号）

## 阶段二：编辑器可用

### 入口与页面
- [ ] 个人中心新增「布局编辑器」行，位置在「首页布局」行之后、公式管理之前，视觉与其余设置行同构
- [ ] 该行整行可点且命中区 ≥ 44pt；右侧为蓝色「首页」+ `chevron.right`
- [ ] 点击后全屏打开布局编辑器；`PageLayoutEditorView` 的顶部栏逐项对齐 `FormulaCenterView.header`（返回胶囊样式、居中标题 17 semibold、右侧胶囊）
- [ ] 个人中心浮层互斥链已由 7 项扩为 8 项（编辑器与主题/五个布局下拉/公式管理互相排斥）
- [ ] 编辑器默认停在 `PageLayoutStore.homeLayout` 对应的档位
- [ ] 未保存改动时点「返回」会先弹确认

### 模型与编辑
- [ ] `PageLayoutEditorModel` 用 `PageLayoutConfigStore.currentFile` 取底本；取不到时先 `resetToBuiltIn` 再取
- [ ] 脏标记用**规范化 JSON 文本**比较（不使用 `Equatable`，避免 `uuid` 击穿）
- [ ] `parent(of:)` 遍历定位父节点与下标，根节点无父时返回 nil
- [ ] `move(fromOffsets:toOffset:)` 仅同级生效；跨级不改顺序并给出「仅支持同级重排」提示
- [ ] 选中容器 → 新节点追加到该容器末尾；选中非容器 → 追加到父容器内其后；未选中 → 追加到根容器末尾
- [ ] 根节点不是容器时增删操作被拒并给提示，不崩溃
- [ ] 参数编辑（`compact` / `showsSparkline` / `limit` / `style` 等）写进节点 `params`，缺 `params` 时自动创建空 `WidgetParams`

### 树列表与检查器
- [ ] 树列表按缩进体现层级、容器可折叠、点击选中（行身份用 `uuid`）
- [ ] 树列表 `List` 行高固定、命中区 ≥ 44pt、颜色全走语义色
- [ ] `.onMove` 已接 `editor.move`，拖动同一级可改变顺序
- [ ] 检查器按 `node.type` 分支生成字段：`vstack`/`hstack`/`zstack`（spacing、alignment）、`scroll`（axis、spacing、padding 四边、showsIndicators）、`card`（title、compact）、`frame`（maxWidth infinity、alignment、minHeight）、`widget`（控件名 + 该控件参数）
- [ ] `widget` 节点的参数表单由 `HomeWidgetEditorSchema` 驱动，7 个控件与 `HomeWidgetRegistry` 一一对应，参数键与实际使用一致（`compact` / `showsSparkline` / `limit` / `style`）
- [ ] 检查器底部「删除本节点」可用，根节点禁用
- [ ] 未选中节点时检查器显示引导文案

### 预览
- [ ] `HomeLayoutPreviewPane` 始终显示当前草稿档位的 1:1 渲染（不做 `scaleEffect`）
- [ ] 预览使用真实 `HomePageModel` 数据（指数 / 自选 / 模拟 / 涨幅榜都是真数据）
- [ ] 预览区本体不响应点击（`.allowsHitTesting(false)`），顶部工具条的「全屏」按钮可点
- [ ] 草稿任一变化（参数 / 顺序 / 增删 / JSON 应用）都会立即重绘预览
- [ ] 全屏预览铺满页面、可交互（点行情行能打开 K 线详情），顶部标注「预览模式 · 入口与 Tab 切换不生效」且有返回
- [ ] `HomeWidgetRegistry` 内部持有的 `openDetail` 未被改动（两处预览共用同一注册表）

### 保存与恢复默认
- [ ] 「保存」写回 `Documents/Layouts/home.json`，状态条显示「已保存」
- [ ] 保存后返回首页立即呈现新配置（走既有 JSON 优先路径）
- [ ] 「恢复默认」先弹确认，确认后沙盒被内置默认覆盖、草稿与首页同步回到内置默认
- [ ] 状态条在「未保存改动 / 已保存 / 已恢复默认 / JSON 错误」间切换时文字不抖动

- [ ] 阶段二独立可编译并已交付（给出 build 号）

## 阶段三：搭积木 + JSON 原文

- [ ] 「添加节点」`Menu` 覆盖 9 种节点类型，新增后结构合法、可继续在检查器编辑
- [ ] 「添加控件」`Menu` 覆盖 7 个控件，新增的 `widget` 节点 `name` 在注册表内（预览不出现「未注册控件」占位）
- [ ] 控件名下拉切换控件时旧 `params` 被清空，不残留无关键
- [ ] 删除含子树的容器会整棵移除，且预览同步更新
- [ ] 对 `card`/`frame`（`child` 语义）添加子节点时，已有 `child` 会被替换并给出提示
- [ ] JSON 原文 `TextEditor` 等宽 12、关闭自动纠错、有语义色圆角边框
- [ ] 「应用到树」成功 → 预览刷新 + 清除错误 + 状态提示；失败 → 显示可读错误原因且草稿与预览不变
- [ ] 「由当前树生成」产出的文本与保存到沙盒的文本一致
- [ ] 切到 JSON 页签时自动由当前树生成文本，不显示过期内容
- [ ] 阶段三独立可编译并已交付（给出 build 号）

## 真机验收

- [ ] ⏳ 编辑器可从个人中心打开，四档可切换，树能完整展示当前档位结构
- [ ] ⏳ 改参数（spacing / compact / limit / style）后页内预览立即变化
- [ ] ⏳ 同级拖动重排生效；跨级拖动被拒并有提示
- [ ] ⏳ 新增 / 删除节点与控件生效
- [ ] ⏳ JSON 原文可生成、可应用；写坏 JSON 报错且草稿不变
- [ ] ⏳ 保存后返回首页立即呈现新布局；恢复默认回到内置默认；未保存返回有提示
- [ ] ⏳ 回归：首页四档呈现、快捷入口、点行开 K 线详情、搜索、公式管理中心、条件单、个人中心、`home.page` 锚点均正常
- [ ] ⏳ 沙盒 `Documents/Layouts/home.json` 内容与编辑器保存的一致

## 工程与交付

- [ ] 新增文件无需手改 `Kline.xcodeproj`（Swift 文件走同步组）
- [ ] 保留不动的文件确实未被改动：`HomeView.swift` / `PageLayoutRenderer.swift` / `PageWidgetRegistry.swift` / `HomeWidgetRegistry.swift` / `Widgets/` 下 11 个控件 / `PageLayoutStore.swift`
- [ ] 三个阶段各自独立可编译、可真机演示
- [ ] 每个阶段交付时说明了 build 号、改动与理由、真机验证路径与回归点