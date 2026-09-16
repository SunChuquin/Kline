---
name: "kline-device-validation-loop"
description: "Ships Kline iOS changes in independently buildable stages via CI + TrollStore, pausing for on-device user validation each stage. Invoke for Kline feature/bugfix iterations needing device verification."
---

# Kline 分阶段迭代 + 真机验收闭环

Kline 项目（Windows 写码 / GitHub Actions 构建 / TrollStore 零触碰部署到 iPad mini 4）的功能开发与修复标准打法：**小步分阶段、每阶段独立可编译可演示、部署后必须等用户真机确认再进入下一阶段**。不允许在未确认前连续堆功能。

## 何时使用

- 在 `c:\Users\sunck\home\projects\ios\Kline` 仓库做需要真机表现验证的功能 / 交互 / UI 改动；
- 用户描述了多部分需求（如"视觉层 + 数据层 + 文档"），可自然拆成独立验收的阶段；
- 用户按真机反馈提出调整或报 bug，需要"改→装→验"快速循环。

不适用：纯文档、纯注释、用户明确说"先别改/只评估"的场景（此时只产出分析或计划文档）。

## 标准节奏

1. **需求对齐**：涉及 UI/布局/交互语义时，先复述理解（必要时举具体例子走查）并请用户确认，再动手；复杂需求先写计划文档（放 `.trae/documents/<feature>-plan.md`，参考已有计划文档风格：Context → 现有代码（带行号）→ 分步实现 → 边界 → 验收清单 → Critical Files）。
2. **拆阶段**：每阶段是一次可独立编译、独立演示、用户可单独验收的闭环；阶段顺序先视觉/数据骨架后复杂计算（例：先合成 K 线+淡化，后指标异步重算）。
3. **执行当前阶段**：编码自查 → **闭环命令（强制要求：使用前台阻塞方式执行）** → **当退出码等于"0 成功"或者"6 设备无人值守"时，可以暂时完成交付并等待后续用户自行确认，若等于其它退出码则需要AI自行规划和解决** → **明确告知用户本轮验收点，然后停下等真机结论**，不要自行推进下一阶段。
4. **用户确认后**：再进入下一阶段；全部完成后更新计划文档状态为"已验收"，并把关键决策/踩坑沉淀进项目记忆（`memory/project_memory.md`）。
5. **文档与代码同步**：功能涉及用户可见行为时，同一次迭代内同步更新用户手册（如 `Kline-联动多图光标联动说明.md`）：行为描述、对照表、场景示例、FAQ、清除/生效时机表都要改；代码注释与实现不一致时顺手修正注释。

## 编码自查

- 只改与当前阶段相关的文件；新增文件遵守目录结构；新增复杂功能且代码体积较大时需要通过 `.trae/skill/swiftui-large-file-split` 完成模块化封装。
- 警惕 SwiftUI 陷阱：
  - `Color.opacity(_:)` 入参是 **Double**，不是 CGFloat；
  - 新增局部变量勿遮蔽同函数已有参数（如 `subChart(model:slot:)` 的 `slot: SubSlot`，槽位下标用 `subSlotIndex`）；
  - 含 `let id = UUID()` 的值类型（如 KlineItem）每次新建都会击穿 `.equatable()` 优化，自定义 `==` 只比业务内容；
  - 拖拽期间禁止主线程重算指标（既有明确教训），实时跟随只做廉价派生，重算走后台 + 任务序号防过期 + 缓存。

## 闭环命令（强制要求：使用前台阻塞方式执行）

`python c:\Users\sunck\home\projects\ios\TrollRestore\build_and_deploy.py "<提交描述>"`

## 提交规范

- 中文提交信息，格式 `<type>(<scope>): <简述>`，如 `feat(link-replay A): ...`、`fix(link-replay): ...`、`docs: ...`；
- 功能/修复提交建议带第二个 `-m` 说明根因与方案；纯文档单独提交；
- 会话内所有改动在会话结束前推送完毕，不留未提交改动。

## 交付给用户前

CI 失败必须修到绿才能交付，不把编译失败推给用户。

## 交付给用户时

明确说清三件事：①本轮装的是哪个 build；②改了什么、为什么（bug 要讲根因，最好复现推导链）；③请在真机上**具体验证什么路径**（给出操作步骤与预期现象，包括回归点：确认旧功能未受影响）。用户回复"确认/没问题"后才算闭环，再做文档状态与记忆沉淀。
