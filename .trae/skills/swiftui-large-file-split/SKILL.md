---
name: "swiftui-large-file-split"
description: "ORCHESTRATOR for SwiftUI/iOS large-file split tasks. Invoke when user asks to split/refactor a large Swift file, reduce file size, or organize code into subfolders. It dispatches stage skills to sub-agents (or keeps work on the main agent per the criteria inside) and owns the sub-agent decision rules."
---

# 总调度：SwiftUI 大文件拆分

本 skill 是**调度器**，不含具体操作细节——按阶段把下方碎片 skill 分派给对应执行者（主 agent 或子代理）。碎片间通过「阶段产出物」衔接，不共享原始过程输出。

## 总流程与分发表

```
侦察(1) → 决策/规划(2) → [用户批准] → 分轮执行(3) → 验证收尾(4)
                └──────── 附加：目录重组(reorganize) 走独立小循环 ────────┘
```

| 阶段 | 碎片 skill | 默认执行者 |
|---|---|---|
| 1 侦察（四张地图） | `swift-split-recon` | **子代理**（Explore 类）|
| 2 决策树/分域方案 | `swift-split-patterns` | 主 agent（或 Plan 子代理，见判据） |
| 3 切片搬迁+跨文件约束 | `swift-split-execute` | 主 agent（域独立时才并行子代理） |
| 4 验证闭环+自更新 | `swift-split-verify` | 主 agent |
| 附 目录层级重组 | `swift-split-reorganize` | 主 agent |

调度动作 = 给执行者两条信息：①「加载碎片 skill X」②该阶段专属输入（目标文件、侦察结论、本域成员清单）。

## 子代理判据（核心决策规则）

### 何时拆子代理（满足任一即拆）
- **A 产出体积失衡**：侦察需大量 Grep/Read（文件 >1000 行或状态属性 >15 个）——原始输出只对侦察有用，子代理消化后只回结论地图，保护主上下文
- **B 方案需多方案权衡**：中风险任务（状态域打包/渲染核心域）——Plan 子代理独立设计，避免主 agent 既当运动员又当裁判
- **C 多域并行且互相独立**：各域成员集合无交集、行号互不依赖时，可并行 general-purpose 子代理各领一个域
- **D 主上下文已深**：长会话（>60% 窗口）时，机械执行下沉子代理，主 agent 只保留编排与验收

### 何时不用拆（主 agent 直接干，满足任一即不拆）
- **a 小任务**：文件 <300 行，或方案只命中单一低风险模式（纯类型移动/纯函数全局化）
- **b 强依赖对话上下文**：用户刚给过口头约束/确认（如"不要影响手势"、"这个注释别动"）——子代理看不到这些，转述必有损耗
- **c 链式行号依赖**：每轮切片后行号漂移，下一轮依赖上一轮结果——必须主 agent 串行（并行子代理会互相踩）
- **d 敏感交互区**：手势/光标/绘制核心等历史踩坑密集区——需要用户逐步确认，不适合一次性委托

### 拆几个
- 侦察：最多 **2-3 个并行** Explore（按地图分工，如"状态矩阵"+"调用方普查"），超过则合并
- 规划：**1 个** Plan 子代理（给它全部侦察结论 + 用户红线）
- 执行：默认 **0 个**（主 agent 串行）；仅当满足 C 且域间零耦合才并行，数量 = 独立域数（上限 3）
- 判据优先级：红线 d > 链式 c > 上下文 b > 规模 a——冲突时选更保守的

### 示例流程（实战复盘：状态域拆分三期规划）
```
用户："开始规划第三步状态域拆分"
→ EnterPlanMode（中风险任务进规划模式）
→ 并行 2× Explore 子代理：①31 个状态属性全景盘点 ②既有 ObservableObject 模式与订阅粒度调研
   （各回结论报告，主上下文只增两份摘要）
→ 1× Plan 子代理：基于两份结论产出分期方案（硬约束/分期/验证/风险）
→ 主 agent 审阅 → 写计划文件 → NotifyUser 用户批准
→ 分期串行执行（每期独立提交走端到端脚本），执行不拆子代理（行号链式依赖）
```
该案例同时展示两条判据：A/B 成立所以侦察与设计拆出去；c 成立所以执行不拆。

## 调度纪律
- 每阶段结束把**结论**（非过程）写回主线：地图表格、分域方案、每轮 CI 结果
- 任何阶段发现任务实际是"目录重组"而非"单文件拆分"→ 切换 `swift-split-reorganize`
- 全部轮次完成后执行 `swift-split-verify` 的自更新协议：本次实战的新坑/更优做法回写到**对应碎片**（坑归哪个阶段就更新哪个碎片），本调度器只在决策树/判据变化时更新
- 碎片更新以 `skill: <摘要>` 单独提交，与代码提交分离
