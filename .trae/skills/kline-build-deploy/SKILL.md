---
name: "kline-build-deploy"
description: "Kline end-to-end CI build & deploy via build_and_deploy.py. Invoke whenever committing/pushing Kline changes, watching GitHub Actions builds, or deploying to the iPad. Enforces ONE foreground command (no background+sleep polling) and exit-code-based branching."
---

# Kline CI 构建与部署闭环（build_and_deploy.py 唯一正确用法）

本 skill 封装 `c:\Users\sunck\home\projects\ios\TrollRestore\build_and_deploy.py` 的标准调用方式。该脚本本身已是**端到端闭环**：git add/commit/push → 轮询 Actions run → 失败拉日志摘录 error → 成功通知 deploy_gui.py（:5052）→ 等待部署终态。**调用方只需要一条前台命令，脚本返回时一切已定论。**

## 核心纪律：一条前台命令跑完，禁止后台 + 轮询

❌ **禁止**（错误姿势，浪费且多此一举）：
- `run_in_background=true` 跑脚本，再另起一条 `sleep 120` / 轮询 `gh run view` 的命令等结果
- 脚本还在跑就手动 `gh run list` 查状态

✅ **正确姿势**：前台直跑，把 Shell timeout 拉满：

```powershell
python c:\Users\sunck\home\projects\ios\TrollRestore\build_and_deploy.py "<提交描述>" --files <文件1> <文件2>
```

- Shell 工具 `timeout` 设 **600000**（10 分钟上限）。典型耗时：构建 40~85s + 排队 + 门禁 30s + 下载/传输/安装 1~3min ≈ 3~6 分钟，通常够用。
- 若命令真被系统转后台（超时自动转入），**等完成通知即可**，仍不许另起轮询；期间可继续做与本次提交无关的工作。
- 只想构建不等部署时才用 `--no-wait`（默认必须完整等待终态）。

## 参数规则

| 参数 | 规则 |
|---|---|
| `<提交描述>` | 必填，一句话说清"为什么"。PowerShell 不支持 heredoc，用单行引号 |
| `--files` | 路径**相对仓库根**（`Kline/Chart/x.swift`），多写一层 `Kline/Kline/` 会 pathspec 不匹配 |
| `--files` 缺省 | 触发 `git add -A`——**高危**：会把用户自己的未跟踪文档（如 `.trae/documents/*.md`）误提交。除非确认工作区干净，**必须显式传 `--files`** |
| `--repo` / `--branch` | 默认 `Kline` 仓库 / `main`，无需传 |

## 退出码决策表（唯一决策依据）

| 退出码 | 含义 | 下一步动作 |
|---|---|---|
| 0 | 构建成功且部署完成/已通知 | 收尾；按域跑冒烟清单（见 `kline-device-validation-loop`） |
| 1 | 构建失败 | 脚本已打印 RESULT + error 摘录；完整日志在 `c:\Users\sunck\home\projects\ios\build_logs\failed-run-<rid>.log`。修复代码后**重跑本脚本** |
| 2 | git 提交/推送失败（含"无可推送变更"） | 检查暂存区/远端；"无可推送变更"说明代码没改或已推过，不要重跑空提交 |
| 3 | 部署助手无法自动启动 | 检查 deploy_gui.py 窗口/venv 路径，手动拉起后重跑 |
| 4 | 等待超时（run 未出现/构建超时/部署未达终态） | 凭 RESULT 里 run_id 用 `gh run view <rid>` 查看实况，再决定重跑或续跑 |
| 5 | 助手正忙（上次部署还没完） | 等助手空闲后重跑 |
| 6 | **设备无人值守**（构建已成功，iPad 锁屏/未前台/USB 断连） | **不要重新构建**。解锁 iPad → 打开 Kline 保持前台 → 凭 RESULT 里的 run_id 执行下方续跑命令 |

## exit 6 续跑（无需重新构建）

iPad 解锁且 Kline 在前台后，POST 通知助手用已构建好的 IPA 续装：

```powershell
python -c "import json,urllib.request; req=urllib.request.Request('http://127.0.0.1:5052/notify', data=json.dumps({'run_id':'<run_id>'}).encode(), headers={'Content-Type':'application/json'}); print(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=5).read().decode())"
```

**必须绕过系统代理**（本机 `HTTP_PROXY=127.0.0.1:10808` 且 NO_PROXY 为空，直连会 503 假象），上面代码用空 ProxyHandler 已处理。

## 坑速查

- **RESULT 块只在失败路径输出**；成功路径只有进度日志 + 最后一行 `🎉 ✅ 部署完成...`，不要去找不存在的 RESULT。
- 助手 `/notify` 先回响应后启动部署，status 会短暂残留上一次终态（如"✅ 部署完成：旧build"）——脚本的 `wait_deploy_done` 已用 baseline 快照防竞态，调用方**无需也不要**自己去轮询 :5052/status。
- `--files` 提交 skill/文档等非代码文件也会触发一次 CI 构建，属正常现象（构建会绿）。
- 首次部署后冒烟验证流程见 `kline-device-validation-loop` skill。
