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
3. **每阶段固定五步**：编码自查 → 提交推送 → **等 CI 成功** → 设备就绪门禁（脚本自动执行：经 usbmux forward 探测设备 KlineHTTP :5051，30s 窗口内不响应则判定无人值守，返回退出码 6，**不通知部署、不重试构建**）→ 通知部署 → **明确告知用户本轮验收点，然后停下等真机结论**，不要自行推进下一阶段。遇到退出码 6 视为"人不在设备面前"：提示用户解锁 iPad、打开 Kline 保持前台，然后凭 run_id 走下方手动链路 `POST :5052/notify` 续跑部署即可（构建产物已在，无需重新提交）。
4. **用户确认后**：再进入下一阶段；全部完成后更新计划文档状态为"已验收"，并把关键决策/踩坑沉淀进项目记忆（`memory/project_memory.md`）。
5. **文档与代码同步**：功能涉及用户可见行为时，同一次迭代内同步更新用户手册（如 `Kline-联动多图光标联动说明.md`）：行为描述、对照表、场景示例、FAQ、清除/生效时机表都要改；代码注释与实现不一致时顺手修正注释。

## 工具链（首选一键脚本）

- **一键端到端**：`python c:\Users\sunck\home\projects\ios\TrollRestore\build_and_deploy.py "<提交描述>"`（在 Kline 仓库根执行）
  - 内部完成 add→commit→push（含 rebase 重试）、按 headSha 匹配本次 run、轮询构建、失败自动拉日志摘录 error 行（退出码 1）；构建成功后先过**设备就绪门禁**（见下），通过才 `POST :5052/notify {run_id}` 触发部署并等部署终态；
  - 部署助手离线时脚本会用 `.venv-ios\Scripts\pythonw.exe` 后台自动拉起，无需手动开 GUI；
  - 退出码：0 成功 / 1 构建失败 / 2 git 失败 / 3 助手无法启动 / 4 超时 / 5 助手忙 / **6 设备无人值守**。
  - **退出码 6 = 人不在设备面前，构建已完成、等待后续人工处理**：CI 构建成功，但部署前门禁在 30s 窗口内探测不到设备上的 KlineHTTP（:5051）——iPad 锁屏 / Kline 未在前台 / USB 断连（结果 JSON 含 `run_id`、`reason`）。此时脚本**不会**通知部署助手、也不会重试构建；处理方式：请用户解锁 iPad 并打开 Kline 保持前台，AI 再凭 `run_id` 用下方手动链路的 `POST :5052/notify {"run_id":<RUN_ID>}` 续跑部署（或用户下次回来时重发指令），已成功的构建产物直接复用。可用 `--device-timeout <秒>` 调整窗口（默认 30）。
  - 注意（真机实测结论，别再走回头路）：**afc 在锁屏下仍可正常列目录/传文件**（配对关系的 escrow bag 使其不受锁屏限制），无法用来判别锁屏；门禁信号只能依赖"Kline 在前台才在线"的 KlineHTTP。
- 需要分多步精细控制时（如只推 CI 暂不部署、或文档提交无需部署），用手动链路：
  - `gh run list --repo SunChuquin/Kline --limit 1` 查状态；`gh run view <id> --log-failed` 拉错误（PowerShell 下用 `2>$null | Select-String "error:"` 过滤）；
  - 通知部署（**必须绕过本机代理**，否则回环被拦成假 503）：
    ```
    python -c "import json,urllib.request; op=urllib.request.build_opener(urllib.request.ProxyHandler({})); req=urllib.request.Request('http://127.0.0.1:5052/notify',data=json.dumps({'run_id':<RUN_ID>}).encode(),headers={'Content-Type':'application/json'},method='POST'); print(op.open(req,timeout=5).read().decode())"
    ```
  - 30 秒后查 `http://127.0.0.1:5052/status`（同样 ProxyHandler({}) 绕过代理），确认 `✅ 部署完成：Kline vX.X.X (build)` 的 build 号已更新。
- 环境注意：本机 shell 是旧版 Windows PowerShell（5.x），**不支持 `&&` 与 bash heredoc**；用 `;` 分隔命令，commit 多段信息用多个 `-m`。

## 编码自查（提交前）

- 保证至少编译通过（用户工程标准：不把编译失败推给用户）；CI 失败必须修到绿再交付；
- 只改与当前阶段相关的文件；新增文件遵守目录结构，避免改 project.pbxproj（同目录新增 Swift 类型优先放入已有文件）；
- 警惕 SwiftUI 陷阱（本项目实踩过）：
  - `Color.opacity(_:)` 入参是 **Double**，不是 CGFloat；
  - 新增局部变量勿遮蔽同函数已有参数（如 `subChart(model:slot:)` 的 `slot: SubSlot`，槽位下标用 `subSlotIndex`）；
  - 含 `let id = UUID()` 的值类型（如 KlineItem）每次新建都会击穿 `.equatable()` 优化，自定义 `==` 只比业务内容；
  - 拖拽期间禁止主线程重算指标（既有明确教训），实时跟随只做廉价派生，重算走后台 + 任务序号防过期 + 缓存。

## 提交规范

- 中文提交信息，格式 `<type>(<scope>): <简述>`，如 `feat(link-replay A): ...`、`fix(link-replay): ...`、`docs: ...`；
- 功能/修复提交建议带第二个 `-m` 说明根因与方案；纯文档单独提交；
- 会话内所有改动按仓库 `.trae/rules/版本管理.md` 在会话结束前推送完毕，不留未提交改动。

## 交付给用户时

明确说清三件事：①本轮装的是哪个 build；②改了什么、为什么（bug 要讲根因，最好复现推导链）；③请在真机上**具体验证什么路径**（给出操作步骤与预期现象，包括回归点：确认旧功能未受影响）。用户回复"确认/没问题"后才算闭环，再做文档状态与记忆沉淀。
