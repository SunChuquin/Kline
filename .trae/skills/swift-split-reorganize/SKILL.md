---
name: "swift-split-reorganize"
description: "Directory-level reorganization for iOS projects: git mv with 100% rename history, pbxproj membershipExceptions constraints (resource folders are immovable), and synchronized-group notes. Load when reorganizing files into subfolders rather than splitting a single file."
---

# 附加流程：目录层级重组

与单文件拆分不同——移动的是文件本身。流程与约束：

## 执行
1. **先查 pbxproj 是否有写死路径**：`membershipExceptions` / `PBXFileReference` 的 `path`——资源文件夹（如 `Indicators/*.tdx`）路径被 exception 引用时**不可移动改名**
2. `git mv`（保留 100% rename 历史），先 `git status` 确认无未提交内容混入
3. PBXFileSystemSynchronizedRootGroup 项目：子文件夹自动收编 .swift，移动后无需改 pbxproj
4. 遇到用户自己的未提交文件被误 stage（如 `git add -A` 带入）：`git restore --staged <path>` 移出，不要替用户提交

## 验证
- `git status` 确认全部显示 `R`（rename）而非 D+A
- CI 构建通过（同步组递归收编生效）
- **Xcode 需重开一次**：外部新增/移动的文件会让编辑器索引滞后，误报 "Cannot find X in scope"（编译实际能过）
- 记录新结构约定（含不可移动路径的硬约束）到项目记忆
