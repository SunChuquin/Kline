---
name: "kline-device-validation-loop"
description: "Ships Kline iOS changes in independently buildable stages, build/install to the connected device, and pause for on-device user validation. Invoke for ANY Kline feature/bugfix task requiring device verification, on macOS or Windows."
---

# Kline 迭代技能（macOS / Windows 双平台）

Kline（iOS）功能开发与修复标准打法：**小步分阶段，每阶段独立可编译、可演示、用户真机验收。**

## 何时使用

任何对 Kline 项目的代码改动。

## 闭环命令（唯一随平台变化的部分，前台阻塞执行）

- **macOS（家里，本机构建直装）**：
  `bash scripts/kline_deploy_mac.sh "<提交描述>"`
  脚本自动跟随 **Xcode 当前选中的运行设备**（模拟器或真机皆可）：已启动的模拟器优先，否则取已连接真机；
  构建 → 安装启动（模拟器走 simctl、真机走 devicectl）→ git 提交推送一条龙；任一步失败非零退出且不提交代码。
  注意：xcodebuild 必须**非沙箱**执行，否则 #Preview 宏插件被拦截会误报 macro implementation not found；
  要用别的设备时 `KLINE_DEVICE_ID=<模拟器UDID或真机ECID> bash scripts/...` 覆盖。
- **Windows（公司，GitHub Actions 构建 + TrollStore 部署到 iPad mini 4）**：
  `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`
  退出码 **0=部署成功 / 6=云端构建成功 / 7=云端构建中网络抖动（稍后重试）** 均可交付；其它退出码自行排查。

不确定平台时先执行 `uname -s`（Darwin = macOS）。

## 标准节奏

1. **需求对齐**：简单需求直接做；复杂需求先写计划 `.trae/documents/<feature>-plan.md`（Context → 现有代码（带行号）→ 分步实现 → 边界 → 验收清单 → Critical Files）。
2. **拆阶段**：视觉/数据骨架先行、复杂计算在后；每阶段是一次独立可编译、可演示、用户可单独验收的闭环。
3. **执行当前阶段**：编码自查 → 闭环命令成功 → 交付。交付时说清三件事：①本轮装的是哪个 build；②改了什么、为什么（bug 讲根因与推导链）；③请用户在真机验证的具体操作路径、预期现象与回归点。用户确认后才算闭环；未明确要求不要主动更新项目记忆。

## 编码自查

- 只改当前阶段相关文件；新增大型复杂功能按 `.trae/skills/swiftui-large-file-split` 做模块化封装。
- SwiftUI 高频陷阱：
  - `Color.opacity(_:)` 入参是 **Double**，不是 CGFloat；
  - 勿遮蔽同函数已有参数（如 `subChart(model:slot:)` 的 `slot`，槽位下标用 `subSlotIndex`）；
  - 含 `let id = UUID()` 的值类型（如 KlineItem）每次新建都击穿 `.equatable()`，自定义 `==` 只比业务字段；
  - 拖拽期间禁止主线程重算指标：实时跟随只做廉价派生，重算走后台 + 任务序号防过期 + 缓存。

## 提交规范

中文 `<type>(<scope>): <简述>`，如 `feat(link-replay A): ...`、`fix(link-replay): ...`、`docs: ...`；纯文档单独提交；会话结束前推送完毕不留未提交改动。
