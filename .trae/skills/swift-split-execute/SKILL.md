---
name: "swift-split-execute"
description: "Stage-3 execution for SwiftUI file split: PowerShell line-range splicing skeleton, five splicing pitfalls, cross-file access-level relaxation, and Combine/Equatable/@Published constraints. Load in the agent that physically moves code between files."
---

# 阶段三：切片搬迁执行 + 跨文件约束

## PowerShell 行区间切片骨架（>150 行的块移动必用，比 Read+Edit 省 token 且零转录错误）

```powershell
$enc = New-Object System.Text.UTF8Encoding($false)   # 必须 UTF-8 无 BOM，保留 LF
$lines = [System.IO.File]::ReadAllLines($src)
$moved = $lines[a..b] | ForEach-Object { $_ -replace '^    private ', '    ' }   # private→internal
# 写新文件：header 数组逐行展开（见坑1）+ $moved + @('','}')；用 [System.IO.File]::WriteAllLines
# 从源文件删除区间：多段时用 Hashtable 记录行号，一次性重建文件
```

## 五个切片坑（每次切片前自查）
1. 新文件 header **每一行**显式以 `//` 开头——漏前缀 = "expressions are not allowed at the top level"
2. 切片范围必须包含方法上方**紧邻的 `@ViewBuilder` / doc 注释行**——漏掉报 "opaque return type"（ViewBuilder 缺失）
3. PowerShell 函数参数传数组会产生**嵌套数组**，WriteAllLines 时 toString 成单行（import 全挤一行报 Consecutive statements）——header/imports 逐行展开，勿把数组当元素塞外层数组
4. 多段切片时行号以**同一份原始快照**计算，删除按降序或 Hashtable 一次性重建，禁止边删边算
5. `private` 泛型辅助（如 `clamp<T>`）被搬出方法引用时不可访问，引发**连锁类型推断假错误**（如荒谬的 String→Int）——真错被掩盖，先放宽泛型辅助

## 跨文件约束（搬迁前逐条核对）
- 跨文件 extension 无法访问源文件 `private` 成员——搬出前 grep 搬出方法体内引用的全部 private 成员，逐一放宽（`@State private var x` → `@State var x`）
- 本项目工具链 `import SwiftUI` **不含** ObservableObject/@Published——新建 ObservableObject 文件必须 `import Combine`
- 文件级 `private func`（日志入口等）跨文件不可见——被共享的放宽 internal
- 纯渲染组件 props 含**元组数组**不自动合成 Equatable——用具名 struct 承载或手写 `==`
- `@Published` 对 `toggle()/append()/removeAll()` mutating **不触发通知**——改赋值；`$x` Binding 用 `Binding(get:set:)`
- 类方法搬出后引用 `Self.staticMember` 不变；`nonisolated`/`@MainActor` 修饰原样保留
