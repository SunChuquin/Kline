---
name: "swiftui-large-file-split"
description: "SwiftUI/iOS 大文件（上帝视图/大类）拆分工作流：侦察→决策树→切片搬迁→CI 验证闭环。Invoke when user asks to split/refactor/extract a large Swift file, reduce file size, or organize code into modules/subfolders."
---

# SwiftUI 大文件拆分工作流

从 Kline 项目实战提炼（KlineChartView.swift 5100+ 行 → 1242 行，11 个域文件，全程零功能/性能回归）。适用于任何 SwiftUI/iOS 大文件拆分与目录重组。

## 第一步：侦察（决定拆什么，约 40% 工作量）

拆之前必须完成四张"地图"，全部用 Grep 获得（不要凭感觉）：

1. **结构清单**：`^(final class|struct|enum|extension|// MARK)|^    (func|private func|var body|@ViewBuilder)` 带行号——得到全部类型/方法/分区的精确边界。
2. **状态用途矩阵**：对每个 `@State`/`@ObservedObject` 属性，grep 全部读写点，标注：谁读谁写、写入表达式形式（整值赋值 vs toggle/append 原地改）、是否被 `.onChange(of:)` 挂钩、body 是否读它、写入线程。
3. **调用方普查**：拟搬出符号的全部调用点（含跨文件 extension），决定搬迁后访问级别。
4. **写频率分级**：高频（拖动/缩放每帧写）vs 低频离散（点按/异步回调）。

## 第二步：拆分决策树（按风险从低到高选模式）

| 模式 | 适用 | 做法 | 风险 |
|---|---|---|---|
| ① 纯类型移动 | 独立 class/struct/enum | 直接搬到新文件，同 module 引用不变 | 极低 |
| ② 纯函数全局化 | 无 self 依赖的小函数 | 提为全局函数 | 极低 |
| ③ extension 方法平移 | 实例方法群（管线/UI 构建器） | 搬到新文件 `extension 同类型`，`private`→`internal`，调用点零改动 | 低（最常用） |
| ④ 纯渲染叶子组件 | 输出只由 props 决定的视图 | 方法 struct 化：props 驱动 + `View, Equatable` + 调用点 `.equatable()` | 低-中 |
| ⑤ 状态域 ObservableObject | 低频离散且**无 .onChange 挂钩**的 @State 组 | 打包 model + `@StateObject` 持有 | 中 |

**明确不拆**（红线）：
- 被 `.onChange(of:)` 挂钩的状态——升级 ObservableObject 后 `.onChange` 失效、须改 `.onReceive`，时序语义改变
- 高频每帧写的状态——不得与低频状态混入同一 model（@Published 任一字段变化触发全订阅者重算）
- 手势状态机内嵌的联动分支——参数爆炸 + 历史踩坑注释密集，搬运净损失
- class 引用型缓存（改内部不触发重绘是**设计意图**）——保持普通 var，不标 @Published

## 第三步：搬迁执行

小改动用 Edit 工具；**超过 ~150 行的块移动用 PowerShell 行区间切片**（比 Read+Edit 往返省 token 且零转录错误），脚本骨架：

```powershell
$enc = New-Object System.Text.UTF8Encoding($false)   # 必须无 BOM
$lines = [System.IO.File]::ReadAllLines($src)
$moved = $lines[a..b] | ForEach-Object { $_ -replace '^    private ', '    ' }  # private→internal
# 写新文件：$h + $moved + @('','}')；用 [System.IO.File]::WriteAllLines 保 LF
# 从源文件删除区间（多段用Hashtable记录行号后一次性重建）
```

**五个已踩过的坑（每次切片前自查）**：
1. 新文件 header **每一行**都要显式以 `//` 开头——漏前缀 = "expressions are not allowed at the top level"
2. 切片范围必须包含方法上方**紧邻的 `@ViewBuilder` / doc 注释行**——漏掉会报 "opaque return type"（ViewBuilder 缺失）
3. PowerShell 函数参数传数组会产生**嵌套数组**，WriteAllLines 时被 toString 成单行（import 全挤一行报 Consecutive statements）——header/imports 逐行展开，不要把数组当元素塞进外层数组
4. 保留原文件的行尾风格（LF）与 UTF-8 无 BOM
5. `private` 泛型辅助函数（如 `clamp<T>`）被搬出方法引用时不可访问，会引发**连锁类型推断假错误**（如 String→Int 的荒谬报错）——真错误被掩盖，先放宽泛型辅助

## 第四步：依赖放宽与跨文件约束

- 跨文件 extension 无法访问源文件 `private` 成员——搬出前 grep 搬出方法体内引用的全部 private 成员，逐一放宽（`@State private var x` → `@State var x`）
- 本项目工具链下 `import SwiftUI` **不含** ObservableObject/@Published——新建 ObservableObject 文件必须 `import Combine`
- 文件级 `private func`（如日志入口）跨文件不可见——被共享的放宽为 internal
- 纯渲染组件 props 含**元组数组**时不会自动合成 Equatable——用具名 struct 承载或手写 `==`
- `@Published` 对 `toggle()/append()/removeAll()` 等 mutating **不触发通知**——改赋值形式；`$x` Binding 需手动 `Binding(get:set:)`

## 第五步：验证闭环（每轮独立提交）

1. **一轮一域一提交**：任何一轮失败可单独 revert；提交信息注明轮次
2. 用项目端到端脚本提交（本项目：`python TrollRestore/build_and_deploy.py "<msg>" --files <相对仓库根的路径>`——注意路径相对仓库根，如 `Kline/Chart/x.swift`）
3. CI 失败 → 读 `build_logs/failed-run-*.log` 提取 `error:` 行 → 修复重提（预期 1-2 轮，编译器兜底漏改，零静默风险）
4. 新增文件后 **Xcode 需重开一次**刷新同步组索引，否则编辑器误报 "Cannot find X in scope"（编译实际能过）
5. 真机冒烟：拆完后按域列清单（如进度条动画、拖动流畅度、切周期缓存恢复），性能敏感域先量基线再对比
6. **收尾必做**：执行文末「使用后自更新协议」——回顾四问并更新本文件，与代码提交分离单独提交

## 目录层级重组（附加流程）

- 用 `git mv`（保留 100% rename 历史），先 `git status` 确认无未提交混入
- **先查 pbxproj 是否有写死路径**（membershipExceptions / PBXFileReference 的 path）——资源文件夹（如 `Indicators/*.tdx`）路径被 exception 引用时不可移动
- PBXFileSystemSynchronizedRootGroup 项目：子文件夹自动收编，移动后无需改 pbxproj
- 遇到用户自己的未提交文件被误 stage：`git restore --staged <path>` 移出，不要替用户提交

## 使用后自更新协议（每次任务收尾必须执行）

本 skill 是活文档：每次**实际使用**本 skill 完成拆分/重组任务后，在提交并 CI 通过（或失败修复完成）的收尾阶段，强制执行以下回顾，并直接更新本文件：

### 回顾四问
1. 实际过程是否遇到了本文档**没有覆盖**的坑？→ 新坑写入对应章节的坑清单
2. 是否有比本文档**更优**的做法（更少轮次/更少 CI 失败/更清晰结构）？→ 替换或增强对应步骤描述
3. 是否出现了**新的拆分模式**或不适用本文档的场景？→ 补充决策树分支或红线
4. 现有条目是否有已**过时/重复**的？→ 合并或标注过时原因

### 更新纪律
- 每条坑必须含「症状 → 原因 → 修法」三要素，禁止无案例的泛化表述
- 只增强不删核心条目；确认过时的需注明原因再合并
- 控制篇幅：同类坑合并陈述，坑清单超过 10 条时收敛为高频 Top 条目 + 折叠归档
- 更新随任务收尾提交（单独 commit，信息格式：`skill: <一句话变更摘要>`），与代码提交分离
- 更新完成后在本文件末尾 Changelog 追加一行

### Changelog
- 2026-09-16 创建：提炼自 Kline 项目 KlineChartView 六轮拆分 / MarketFieldKit 四文件切分 / 三期状态域打包 / 目录层级重组实战。
