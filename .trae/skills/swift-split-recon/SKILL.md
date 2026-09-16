---
name: "swift-split-recon"
description: "Stage-1 recon for SwiftUI large-file split: builds four maps (structure inventory, state-usage matrix, caller census, write-frequency tiers) via Grep. Load this skill in a recon sub-agent (or main agent) BEFORE planning any split; output is conclusions only, never raw dumps."
---

# 阶段一：侦察——四张地图

拆之前必须完成四张"地图"，全部用 Grep 获得（不要凭感觉，也不要把原始 grep 输出直接倒进主上下文）。

## 地图 1：结构清单
`^(final class|struct|enum|extension|// MARK)|^    (func|private func|var body|@ViewBuilder)` 带行号。
产出：全部类型/方法/MARK 分区的精确边界表（含每个方法上方紧邻的 `@ViewBuilder`/doc 注释行——切片时必须同行切割）。

## 地图 2：状态用途矩阵
对每个 `@State`/`@ObservedObject`/`@StateObject`/`@Binding` 属性，grep 全部读写点，逐条标注：
- 谁读谁写（方法名 + 行号）
- 写入表达式形式：整值赋值 vs `toggle()/append()/removeAll()` 原地改
- 是否被 `.onChange(of:)` 挂钩、回调里做什么
- body / 派生计算属性是否读它
- 写入线程（主线程 / Task @MainActor / detached 后台）

## 地图 3：调用方普查
拟搬出符号的全部调用点（同文件 + 跨文件 extension + 其他文件）。决定搬迁后访问级别（private→internal 清单）。

## 地图 4：写频率分级
- 高频：拖动/缩放手势每帧写（selectedIndex、visibleCount、panOffset 类）
- 中频：重算/异步回调写
- 低频离散：点按/sheet 开关
- 一次性：init 写入后只读

## 输出纪律（给侦察执行者）
- 侦察可能在子代理中执行：**只回结论**（地图表格 + 风险点 + 建议拆分域清单），不回原始 grep 输出
- 每张地图以"能直接支撑决策"为完成标准：域划分建议 + 每域预估行数 + 每域风险标注
