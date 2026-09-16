---
name: "swift-split-verify"
description: "Stage-4 verify loop for SwiftUI file split: one-domain-one-commit via build_and_deploy.py, CI failure triage from build_logs, Xcode index refresh, smoke checklist, and the mandatory post-task self-update protocol. Load when closing out any split round."
---

# 阶段四：验证闭环 + 自更新

## 验证闭环（每轮独立提交）
1. **一轮一域一提交**：任何一轮失败可单独 revert；提交信息注明轮次
2. 端到端脚本提交（本项目：`python TrollRestore/build_and_deploy.py "<msg>" --files <路径>`——路径**相对仓库根**，如 `Kline/Chart/x.swift`，多写一层 `Kline/Kline/` 会 pathspec 不匹配）
3. CI 失败 → 读 `build_logs/failed-run-*.log` 提取 `error:` 行 → 修复重提。预期 1-2 轮，编译器兜底漏改，零静默风险
4. 新增文件后 **Xcode 需重开一次**刷新同步组索引，否则编辑器误报 "Cannot find X in scope"（编译实际能过）
5. 真机冒烟：按域列清单（进度条动画、拖动流畅度、切周期缓存恢复等），性能敏感域先量基线再对比

## 使用后自更新协议（收尾必做）
本 skill 体系是活文档。每次实际使用完成拆分/重组任务后，在收尾阶段执行「回顾四问」，并更新对应碎片 skill（哪个阶段的坑就更新哪个碎片）：

1. 实际过程遇到碎片文档**没有覆盖**的坑？→ 写入该碎片坑清单
2. 有比文档**更优**的做法？→ 替换或增强对应步骤
3. 出现**新模式**或不适用场景？→ 通知总调度更新决策树/红线
4. 现有条目**过时/重复**？→ 合并或标注过时原因

**纪律**：坑必须含「症状→原因→修法」三要素；只增强不删核心条目；碎片坑清单超 10 条收敛 Top 条目；更新与代码提交分离（`skill: <摘要>` 单独 commit），并在该碎片 Changelog 追加一行。
