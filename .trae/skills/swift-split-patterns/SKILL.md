---
name: "swift-split-patterns"
description: "Stage-2 decision tree for SwiftUI large-file split: five refactor patterns ranked by risk (type move / global fn / extension move / Equatable leaf component / state-domain ObservableObject) plus hard red-lines. Load when designing the split plan or choosing what NOT to split."
---

# 阶段二：拆分决策树（模式选择 + 红线）

输入：侦察地图。输出：分域拆分方案（每域标注模式、预估行数、风险、提交顺序）。

## 五级模式（风险从低到高）

| 模式 | 适用 | 做法 | 风险 |
|---|---|---|---|
| ① 纯类型移动 | 独立 class/struct/enum | 直接搬新文件，同 module 引用不变 | 极低 |
| ② 纯函数全局化 | 无 self 依赖的小函数 | 提为全局函数 | 极低 |
| ③ extension 方法平移 | 实例方法群（管线/UI 构建器） | 新文件 `extension 同类型`，`private`→`internal`，调用点零改动 | 低（最常用） |
| ④ 纯渲染叶子组件 | 输出只由 props 决定的视图 | 方法 struct 化：props 驱动 + `View, Equatable` + 调用点 `.equatable()` | 低-中 |
| ⑤ 状态域 ObservableObject | 低频离散且**无 .onChange 挂钩**的 @State 组 | 打包 model + `@StateObject` 持有 | 中 |

**模式⑤附加规则**：
- 修饰符判据 = "是否有人需要因它重绘"：body 读/动画挂钩 → `@Published`；body 零读 → 普通 var；init 一次定 → `let`
- 缓存恢复逻辑整体进 model init（`StateObject(wrappedValue:)` 注入，autoclosure 语义与 `State(initialValue:)` 等价）
- 模型属性若未来会被 body/onChange 读，注释强制标明"须升 @Published"

## 红线（明确不拆，直接拒绝）
- 被 `.onChange(of:)` 挂钩的状态——升级后 `.onChange` 失效须改 `.onReceive`，时序语义改变
- 高频每帧写的状态——不得与低频状态混入同一 model（@Published 任一字段变化触发全订阅者重算）
- 手势状态机内嵌的分支——参数爆炸 + 历史踩坑注释密集，搬运净损失
- class 引用型缓存（改内部不触发重绘是设计意图）——保持普通 var，不标 @Published
- body 本身建议保留在主文件作入口（extension 里放 body 可行但不推荐）

## 分域方案输出格式
每个域一行：`域ID | 模式 | 包含成员 | 预估行数 | 新文件名 | 风险 | 提交顺序（链式依赖者串行）`。
中风险/多域任务必须走规划模式（计划文件 + 用户批准）后才开始执行。
