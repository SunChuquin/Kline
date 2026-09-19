# Tasks

> 每阶段都必须是**可独立编译、可独立演示、可单独验收**的闭环；每阶段结束用闭环命令交付：
> `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<type>(<scope>): <简述>"`
> 阶段顺序：先视觉/交互骨架，再程序化驱动，最后跨控件耦合。

- [x] Task 1: 搭出新按钮外壳、几何与落位（不含转圈驱动光标）
  - [x] SubTask 1.1: 把旧按钮的几何常量与描边原语抽出为可共享形态（不改变旧按钮任何可见行为）
  - [x] SubTask 1.2: 实现新按钮三圆结构 A'/B'/C'：直径 A'=128.8、B'=72.8、环 Z'=28、C'=27；A'、B'、环 Z' 无填充仅描边；C' 用 `Color(.label)` 实心 + 1pt 阴影达到视觉直径 28
  - [x] SubTask 1.3: C' 位置由角度参数驱动，圆心轨迹半径 50.4（校验与环 Z' 中径重合、内外各余 0.5）
  - [x] SubTask 1.4: `ContentView` overlay 装配两个按钮，共用 `selectedTab == 1 || == 2` 判定
  - [x] SubTask 1.5: 新按钮落位独立持久化（`kline.accessory2.centerX/centerY`）+ 首次默认落旧按钮对侧 + 启动时同侧矫正
  - [x] SubTask 1.6: 闭环命令交付本阶段（CI run=35431908818，云端构建成功）

- [x] Task 2: 新按钮触摸状态机（B' 交互 + 环 Z' 落点接管，不接图表）
  - [x] SubTask 2.1: 落 B' → 摁住/拖动整个按钮（复用旧按钮 `dragDelta` + 吸附逻辑），+15% 直径与 50% 透明度
  - [x] SubTask 2.2: 点击 B' → 果冻回弹（同参数），**不弹面板**
  - [x] SubTask 2.3: 闲置 3s 淡出至 25% 且 **C' 隐藏**；触碰即回 100%；令牌自增防泄漏
  - [x] SubTask 2.4: 环 Z' 落点即接管：C' 跳到落点角度并显现，**同一次触摸**继续拖动即转圈（正/反向）
  - [x] SubTask 2.5: 角度累积用里程表 + `wrap` 增量防跳变（`delta` 符号定方向），圆心 8pt 内冻结角度
  - [x] SubTask 2.6: 闭环命令交付本阶段（CI run=35432265739，云端构建成功）
    > 实现说明：接管时**只改显示角偏移、不动里程表**（否则第 4 阶段按 `odometer/18` 推进会在触摸瞬间凭空走进最多 10 根）；显示角 = 里程表 + 偏移，跨 0°/360° 仍由 `wrap` 增量保证无跳变。

- [x] Task 3: 新建命令通道并接入主格图表（程序化光标入口）
  - [x] SubTask 3.1: 新增两按钮协调对象（单例 `ObservableObject`），承载：光标命令、手势占用者 `activeOwner`
  - [x] SubTask 3.2: 让图表能识别「我是主格」（复用既有 owner index 传递方式，单图模式视为主格）
  - [x] SubTask 3.3: 主格 `KlineChartView` 订阅命令并在收到时施加到 `selectedIndex`（不接管既有手势路径）
  - [x] SubTask 3.4: 验证命令通道空转期不影响任何既有行为（无命令时零副作用）
  - [x] SubTask 3.5: 闭环命令交付本阶段（CI run=35432736407，云端构建成功）

- [x] Task 4: 转圈 → 光标联动语义
  - [x] SubTask 4.1: 无光标时按移动方向在对应边缘 K 线生成十字光标（复用 `ChartGestureHandlers.swift:106-121` 写法）
  - [x] SubTask 4.2: 已贴边后继续转 → 光标锁边 + 窗口推进
    > **有意偏离已批准 spec**：spec 写「复用 `startEdgeAutoScroll`，每秒推进 1 根」，但它与用户定死的**一圈 360° = 20 根**互相矛盾（按时间跑的无限动画器会让一圈的推进量取决于转速）。改为**按转圈步进**：每步把 `endOffset` 推进本次根数并锁光标回新边缘，不使用动画器，使「转一圈 = 窗口走 20 根」严格成立。
  - [x] SubTask 4.3: 18° = 1 根的进位用亚像素累计，避免手指微颤抖动
  - [x] SubTask 4.4: 转圈结束时收尾：复位 `cursorDragging`/`linkUserDragging`/`panOffset`，补一次 `refreshCurves` + `startPrefetch`（拖拽期不重算指标）
  - [x] SubTask 4.5: 闭环命令交付本阶段（CI run=35433175995，云端构建成功）

- [x] Task 5: 多图联动驱动第一格
  - [x] SubTask 5.1: 多图（2~4 tile）时命令只由第一格施加，其余格不响应
  - [x] SubTask 5.2: 第一格按既有出口 `publishLinkCursor` 发布，其余格居中跟随
  - [x] SubTask 5.3: 联动关闭时第一格仍可被驱动（不因未开联动而失效）
  - [x] SubTask 5.4: 闭环命令交付本阶段 —— **本阶段为验证型任务，三条链路逐行核对后全部通过、未改任何代码**，故不单独构建（代码状态与 Task 4 交付的 run=35433175995 完全相同）。
    > 核对要点：`isMainTile` 全仓仅两处赋值（单图 `KlineDetailView.swift:1178` 恒 true、多图 `LinkedKlineTile.swift:360` 为 `view.index == 0`），其余格在 `KlineChartView.swift:854/898` 首行即 return；`linkUserDragging` 是**各视图自己的 @State**（`KlineChartView.swift:84`），不在 `DualLinkSync` 里、不跨视图共享；接收端 `applyLinkCursor` 的守卫是 `cursorLinkEnabled` 与**自身** `drag.cursorDragging`（`LinkedReplaySupport.swift:553/561`），不读来源端的 `linkUserDragging`；接收端只写 `endOffset` 不写 `selectedIndex`，无回声。
    > 已知残留（不建议本阶段动）：①「第一格」依赖联动配置中 `index == 0` 唯一（与既有 `linkAutoCenter` 同一假设）；②双手同时操作两格时 `cursorDate` 会在两个来源间交替、接收格抖动，属既有「对称来源」语义；③抬手收尾不复位联动会话，其余格停在当前光标（与手指拖完抬手一致）。

- [ ] Task 6: 两按钮耦合（同侧互斥 + 手势期间强制闲置）
  - [ ] SubTask 6.1: 同侧互斥：`onChanged` 每帧判「被拖按钮是否越过屏幕中线」，越过即幂等地把另一方吸附到对侧；允许两者动画并行
  - [ ] SubTask 6.2: 手势占用：任一方 `onChanged` 首次置 `activeOwner`，`onEnded` 置回 `nil`；转圈手势同样计入占用
  - [ ] SubTask 6.3: 被占用方强制 `isDimmed = true` 并**作废其在途淡出计时**（令牌自增）；手势结束不主动恢复
  - [ ] SubTask 6.4: 被占用方自身被触碰时自然解锁回 100%
  - [ ] SubTask 6.5: 闭环命令交付本阶段

- [ ] Task 7: 知识沉淀文档（按 `module-knowledge-digest` + `mermaid-doc-convention`）
  - [ ] SubTask 7.1: `decisions/` 新增 4 篇：新按钮几何（含与旧按钮的关系 B'=旧A×1.3、环 Z'=旧D）、同侧互斥吸附、手势期间强制闲置（单向耦合）、C' 转圈驱动光标
  - [ ] SubTask 7.2: `pitfalls/` 视实际踩坑补充（若出现则一坑一篇）
  - [ ] SubTask 7.3: 更新 `modules/悬浮按钮.md`（新增新按钮的位置、状态机图、互斥与耦合机制图）与 `INDEX.md`
  - [ ] SubTask 7.4: 落盘后自动提交，汇报带哈希

# Task Dependencies

- Task 2 依赖 Task 1（新按钮外壳与 C' 渲染）
- Task 3 依赖 Task 1（协调对象与 overlay 装配）
- Task 4 依赖 Task 3（命令通道）+ Task 2（转圈角度产出）
- Task 5 依赖 Task 4
- Task 6 依赖 Task 1（两按钮均存在）+ Task 3（协调对象）
- Task 7 依赖 Task 1~6 全部完成
- 并行面：Task 2 与 Task 3 无相互依赖，可并行推进