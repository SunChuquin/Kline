---
name: "kline-device-validation-loop"
description: "Ships Kline iOS changes in independently buildable stages via CI + TrollStore, pausing for on-device user validation each stage. Invoke for Kline feature/bugfix iterations needing device verification."
---

# Kline 迭代技能

Kline 项目（Windows 写码 / GitHub Actions 构建 / TrollStore 零触碰部署到 iPad mini 4）的功能开发与修复标准打法：**小步分阶段、每阶段独立可编译可演示。**

## 何时使用

任何对Kline项目的改动。

## 标准节奏

1. **需求对齐**：风险小的简单需求不用拆阶段；但复杂需求得先写计划文档（放 `.trae/documents/<feature>-plan.md`，参考已有计划文档风格：Context → 现有代码（带行号）→ 分步实现 → 边界 → 验收清单 → Critical Files）。
2. **拆阶段**：每阶段是一次可独立编译、独立演示、用户可单独验收的闭环；阶段顺序先视觉/数据骨架后复杂计算（例：先合成 K 线+淡化，后指标异步重算）；
3. **执行当前阶段**：编码自查 → **闭环命令 **→ **当退出码等于"0 完整部署成功"、"6 云端构建成功" 或 "7 云端正在构建中，网络不稳定，稍后请手动重试**"时，应交付给用户；可若是其它退出码则需要AI自行规划解决 → 如果用户没有明确要求更新**项目记忆**就不要主动更新。

## 编码自查

- 只改与当前阶段相关的文件；新增文件遵守目录结构；新增复杂功能且代码体积较大时需要通过 `.trae/skill/swiftui-large-file-split` 完成模块化封装。
- 警惕 SwiftUI 陷阱：
  - `Color.opacity(_:)` 入参是 **Double**，不是 CGFloat；
  - 新增局部变量勿遮蔽同函数已有参数（如 `subChart(model:slot:)` 的 `slot: SubSlot`，槽位下标用 `subSlotIndex`）；
  - 含 `let id = UUID()` 的值类型（如 KlineItem）每次新建都会击穿 `.equatable()` 优化，自定义 `==` 只比业务内容；
  - 拖拽期间禁止主线程重算指标（既有明确教训），实时跟随只做廉价派生，重算走后台 + 任务序号防过期 + 缓存。

## 提交规范

- 中文提交信息，格式 `<type>(<scope>): <简述>`，如 `feat(link-replay A): ...`、`fix(link-replay): ...`、`docs: ...`；

## 闭环命令

用户的缺省要求是提交当前仓库全部改动，即执行以下命令（强制要求：使用前台阻塞方式执行）：

`python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`

