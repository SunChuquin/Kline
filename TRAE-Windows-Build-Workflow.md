# TRAE Windows 自动构建 iOS IPA 工作流

> **场景**：在 Windows 上运行 TRAE Word，生成 Swift 代码后自动推送 GitHub、监控 Actions 构建进度、下载 IPA、并在编译失败时依据日志自主修复。本流程已在本机实测通过，不依赖任何特定会话，可重复执行。

**作者**：sunchuquin  
**首次验证日期**：2026-08-27  
**示例项目**：Kline（仓库 `SunChuquin/Kline`，Bundle ID `com.sunck.Kline`）

---

## 📋 目录

1. [前置条件](#前置条件)
2. [工作流总览](#工作流总览)
3. [第一步：生成代码并推送](#第一步生成代码并推送)
4. [第二步：监控 Actions 运行进度](#第二步监控-actions-运行进度)
5. [第三步：下载 IPA 产物](#第三步下载-ipa-产物)
6. [第四步：编译失败分析与自修复](#第四步编译失败分析与自修复)
7. [第五步：自动安装到 iPad（pymobiledevice3）](#第五步自动安装到-ipadpymobiledevice3)
8. [完整闭环示例（本机实测）](#完整闭环示例本机实测)
9. [常用命令速查](#常用命令速查)
10. [故障排查](#故障排查)
11. [限制与注意事项](#限制与注意事项)

---

## 前置条件

| 项目 | 说明 | 验证命令 |
| :--- | :--- | :--- |
| Windows 本机 | 已安装 Git，且 SSH/HTTPS 推送权限就绪 | `git --version` |
| GitHub CLI | `gh` 已登录，token 含 `repo` 权限（下载产物需要） | `gh auth status` |
| 项目仓库 | 已配置 `.github/workflows/build.yml`，参考 [iOS-GitHub-Actions-CI.md](./iOS-GitHub-Actions-CI.md) | `gh run list` |
| GitHub Secrets | `CERTIFICATE_BASE64` / `CERTIFICATE_PASSWORD` / `PROVISION_PROFILE_BASE64` 已配置 | 见 CI 文档 |
| 工作目录 | 切换到 Xcode 项目所在目录（含 `.github` 子目录的仓库根） | `cd c:\Users\sunck\home\projects\ios\Kline` |
| iOS 安装工具链 | 已建 Python 3.10 venv 并装 `pymobiledevice3`（见第五步） | `.venv-ios\Scripts\pymobiledevice3.exe --help` |

> **关键点**：本工作流**不需要** Windows 安装 Xcode 或 act 等本地编译工具。所有编译在 GitHub Actions 的 `macos-latest` runner 上完成，TRAE 仅负责编排与诊断。IPA 安装则通过本机 `pymobiledevice3` 经 USB 推送到 iPad。

---

## 工作流总览

```
┌─────────────────────────────────────────────────────────────┐
│  TRAE (Windows)                                              │
│                                                              │
│  1. 生成/修改 Swift 代码                                      │
│  2. git add → commit → push ──────────┐                      │
│  3. gh run list（确认新 run 触发）      │                      │
│  4. gh run watch <id>（轮询直到结束）    │                      │
│  5a. 成功 → gh run download <id>        │                      │
│  5b. 失败 → gh run view --log-failed   │                      │
│      → 定位 error 行 → 修复 → 回到 1     │                      │
│  6. pymobiledevice3 apps install       │                      │
│      <ipa> （USB 推送到 iPad）          │                      │
└─────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                          ┌───────────────────────────────┐
                          │  GitHub Actions (macOS runner) │
                          │  checkout → setup Xcode        │
                          │  → import cert → install prof  │
                          │  → xcodebuild archive          │
                          │  → xcodebuild -exportArchive  │
                          │  → upload-artifact (Kline.ipa) │
                          └───────────────────────────────┘
```

核心思想：**TRAE 不直接编译 Swift，而是把 GitHub Actions 当作云端的 Xcode**。`gh` CLI 既是触发器，也是日志读取器，还是产物下载器；`pymobiledevice3` 则把下载好的 IPA 经 USB 一键装入 iPad，形成「构建 → 下载 → 安装」的完整闭环。

---

## 第一步：生成代码并推送

TRAE 在 Windows 上用 Edit/Write 工具修改 Swift 源文件，然后用 `git` 推送。

```powershell
# 切换到仓库根（含 .github/workflows 的目录）
cd c:\Users\sunck\home\projects\ios\Kline

# 仅添加本次改动的文件（避免误提交 secrets/证书等敏感文件）
git add Kline/ContentView.swift

# 提交（中文 commit message 完全可用）
git commit -m "修复编译错误：xxx（依据 GitHub Actions 日志诊断）"

# 推送到 main 分支，触发 push 类型的 workflow
git push origin main
```

> **触发条件**：本项目的 `build.yml` 同时配置了 `push: branches: [main]` 和 `workflow_dispatch`。所以 `git push` 会自动触发；如需在不改代码的情况下手动触发，用 `gh workflow run build.yml`。

---

## 第二步：监控 Actions 运行进度

推送后立即查询最新 run，然后用 `gh run watch` 阻塞等待结束。

```powershell
# 查询最新一次 run，获取 run ID
gh run list --limit 1

# 阻塞式监控（每 3 秒刷新，结束自动退出；成功返回 0，失败返回 1）
gh run watch <RUN_ID> --exit-status

# 非阻塞后台运行（适合让 TRAE 边等边干别的活）
# 在 RunCommand 里用 blocking=false，再用 CheckCommandStatus 轮询
gh run watch <RUN_ID> --exit-status
```

`gh run watch` 的输出会逐步显示每个 step 的状态：

```
JOBS
✓ build in 46s (ID 98395772652)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Setup Xcode
  ✓ Import Certificate
  ✓ Install Profile
  ✓ Build Archive      ← 编译在这一步
  ✓ Export IPA
  ✓ Upload IPA
  ✓ Post Run actions/checkout@v4
  ✓ Complete job
```

> **耗时参考**：Kline 项目典型构建 40~85 秒，其中 macOS runner 启动 + Xcode setup 约 20 秒，真正的 `xcodebuild archive` 约 15~60 秒。

---

## 第三步：下载 IPA 产物

构建成功后，IPA 作为 artifact 上传，名称在 `build.yml` 的 `actions/upload-artifact` 步骤中定义（本项目为 `Kline`）。

```powershell
# 下载到指定目录（artifact 会以子目录形式落地）
gh run download <RUN_ID> --dir c:\Users\sunck\home\projects\ios\artifacts

# 下载结果
# c:\Users\sunck\home\projects\ios\artifacts\Kline\Kline.ipa   (~931 KB)
```

下载完成后，IPA 文件即可自动安装到已连接的 iOS 设备（见下一步），也可手动交给 **爱思助手**、TrollStore 等工具。

---

## 第四步：编译失败分析与自修复

这是 TRAE 在 Windows 上替代 macOS 本地 Xcode 调试的关键能力。失败时 `gh run watch` 会以非零退出码退出，然后用 `--log-failed` 拉取失败 step 的日志。

```powershell
# 只看失败步骤的日志（比 --log 全量日志干净很多）
gh run view <FAILED_RUN_ID> --log-failed > failed.log

# 在 PowerShell 里用 Select-String 抓 error 行（带上下文）
gh run view <FAILED_RUN_ID> --log-failed 2>&1 | Select-String -Pattern "error:|warning:|ARCHIVE FAILED" -Context 0,2
```

### 实测案例

本机在 `ContentView.swift` 第 130 行引入 `selectedTab = nonExistentTab`（未定义符号），构建失败。日志关键行：

```
> build Build Archive   2026-08-27T06:58:01.6012180Z
  /Users/runner/work/Kline/Kline/Kline/ContentView.swift:130:27: error:
  cannot find 'nonExistentTab' in scope
> build Build Archive   2026-08-27T06:58:01.6060510Z
              selectedTab = nonExistentTab
  build Build Archive   2026-08-27T06:58:01.6124240Z
                            ^~~~~~~~~~~~~~
  build Build Archive   2026-08-27T06:58:01.6203290Z
  ** ARCHIVE FAILED **
```

### 错误信息格式解析

`xcodebuild` 的错误行格式与 Xcode IDE 完全一致，可直接定位：

| 字段 | 含义 | 本例值 |
| :--- | :--- | :--- |
| 文件路径 | 编译机上的源码绝对路径 | `.../Kline/ContentView.swift` |
| `行:列` | 源码中的位置 | `130:27` |
| `error:` | 错误等级（`error` 致命，`warning` 不阻断） | `error` |
| 错误消息 | Swift 编译器诊断 | `cannot find 'nonExistentTab' in scope` |
| `^~~~` | 指向出错列的插入符号 | 第 27 列 |

> **诊断技巧**：路径里的 `.../runner/work/Kline/Kline/Kline/ContentView.swift` 是 GitHub runner 上的临时路径，对应本机仓库的 `Kline/ContentView.swift`（去掉 `/Users/runner/work/Kline/Kline/` 前缀即可映射回本地）。

### 修复闭环

1. 用 Edit 工具改回正确代码（`nonExistentTab` → `index`）
2. `git add` + `git commit` + `git push`
3. 回到 [第二步](#第二步监控-actions-运行进度) 监控新一轮 run，直到成功
4. 进入 [第三步](#第三步下载-ipa-产物) 下载 IPA

---

## 第五步：自动安装到 iPad（pymobiledevice3）

这一步让 TRAE 把下载好的 IPA 经 **USB** 直接装到 iPad，无需再手动用爱思助手。本质是 CLI 版的 iOS 通信/安装工具，签名机制与爱思助手一致（都需要已签名的 IPA + 描述文件包含目标设备 UDID）。

### 5.1 一次性的环境准备（已完成，发现可复用）

scoop 里并**没有** `libimobiledevice`/`ideviceinstaller` 的现成 manifest（别照抄网络上"scoop install"的说法），本机改用 Python 版工具，装法如下：

```bash
# 本机默认 Python 是 3.8，太旧；pymobiledevice3 需要 ≥3.9，故用已装的 Python 3.10 建独立 venv
py -3.10 -m venv  c:\Users\sunck\home\projects\ios\.venv-ios
c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pip.exe install pymobiledevice3
# 装完即可用（成品可执行文件在 venv 的 Scripts 目录）
c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pymobiledevice3.exe --help
```

> 若日后换机器，只需重建这个 venv；`pymobiledevice3` 本身跨平台（Win/macOS/Linux 都支持 USB 连接 iOS）。

### 5.2 确认设备连接

```bash
# 列出通过 USB 连接的 iOS 设备（拿 UDID）
c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pymobiledevice3.exe usbmux list
```

成功应输出类似：

```json
[
    {
        "ConnectionType": "USB",
        "DeviceClass": "iPad",
        "DeviceName": "孙楚昆的iPad",
        "ProductType": "iPad5,2",
        "ProductVersion": "15.8.8",
        "UniqueDeviceID": "b36adcb0...f81fe"
    }
]
```

> **首次配对**：iPad 连接后若提示"要信任此电脑吗？"必须先在 iPad 上**手动点"信任"**——这一步物理上无法自动化，做一次，之后永久生效。若设备已通过爱思助手/iTunes 连接过，通常已自动信任。

### 5.3 安装 IPA（关键命令）

```bash
# 升级式安装：不卸载已装 App，直接覆盖应用本体，保留其沙盒/文档数据
c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pymobiledevice3.exe apps install ^
    c:\Users\sunck\home\projects\ios\artifacts\Kline\Kline.ipa
```

- 输出进度 `5%→100% Complete`，最后出现 **`Installation succeed.`** 即成功（Kline 实测约 2 秒）。
- **不要**先用 `apps uninstall` 卸载——那会清空沙盒数据；直接用 `apps install` 是升级语义，保数据。

### 5.4 验证已安装

```bash
# 查看已安装用户 App，确认 Bundle ID 存在
c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pymobiledevice3.exe apps list | Select-String "Kline"
```

确认出现 `com.sunck.Kline` 且 `"ProfileValidated": true` 即安装成功、签名有效。

---

## 完整闭环示例（本机实测）

以下三个 commit 构成 2026-08-27 的完整验证链，全部记录在 `git log` 中，可随时复查：

| 步骤 | Commit | 触发 Run | 结果 | 耗时 |
| :--- | :--- | :--- | :--- | :--- |
| 正常推送 | `2d24696` 添加 appVersion 启动日志 | `33047652179` | ✅ 成功 | 46s |
| 故意引入错误 | `43cbf02` 引入 nonExistentTab | `33047773410` | ❌ 失败（Build Archive） | 37s |
| 修复并重推 | `85bbeef` 改回 index | `33047857538` | ✅ 成功 | 1m21s |

最终产物：`c:\Users\sunck\home\projects\ios\artifacts\Kline\Kline.ipa`（931089 字节）。

---

## 常用命令速查

```powershell
# === 触发与监控 ===
gh run list --limit 5                      # 列出最近 5 次 run
gh run view <RUN_ID>                       # 查看某次 run 的 step 概览
gh run watch <RUN_ID> --exit-status        # 阻塞监控直到结束
gh workflow run build.yml                  # 手动触发（workflow_dispatch）
gh run cancel <RUN_ID>                     # 取消卡住的 run
gh run rerun <RUN_ID>                      # 重跑某次 run

# === 日志 ===
gh run view <RUN_ID> --log                 # 全量日志（很大）
gh run view <RUN_ID> --log-failed         # 仅失败 step 日志（推荐）

# === 产物 ===
gh run download <RUN_ID> --dir <PATH>     # 下载所有 artifacts 到指定目录
gh api repos/:owner/:repo/actions/runs/<RUN_ID>/artifacts   # 列出 artifact 元数据

# === Git ===
git add <具体文件>                          # 只加改动的文件，别用 git add .
git commit -m "消息"                       # 提交
git push origin main                       # 推送触发 Actions
git log --oneline -5                       # 查看最近提交

# === iOS 设备安装（USB） ===
SET PM=.venv-ios\Scripts\pymobiledevice3.exe   # 简写（在 ios 根目录执行）
%PM% usbmux list                            # 列出已连接 iOS 设备（拿 UDID）
%PM% apps list | findstr Kline             # 查看已装 App
%PM% apps install artifacts\Kline\Kline.ipa # 升级式安装 IPA
```

---

## 故障排查

| 现象 | 原因 | 处理 |
| :--- | :--- | :--- |
| `gh run watch` 一直 `queued` 超过 10 分钟 | runner 排队或卡死 | `gh run cancel <ID>` 后重推 |
| 旧 run 显示 `queued` 但实际已结束 | `gh` 状态显示缓存 | 忽略，以 `gh run view <ID>` 为准 |
| `error: cannot find 'xxx' in scope` | 未定义符号/拼写错误 | 按日志的 `文件:行:列` 定位修复 |
| `No signing certificate matching ...` | 证书未导入或 Secrets 缺失 | 检查 `CERTIFICATE_BASE64` 等 Secrets |
| `Provisioning profile does not include device` | 描述文件未含目标 UDID | 用 Appuploader 重新生成，勾选所有设备 |
| 产物目录为空 | `gh run download` 必须等 run 完全结束 | 先 `gh run watch` 等成功再下载 |
| `gh` 提示权限不足 | token 缺 `repo` scope | `gh auth refresh -s repo` 重新授权 |
| 推送被拒（non-fast-forward） | 远端有新提交 | `git pull --rebase origin main` 后再推 |
| `pymobiledevice3` 报 `TypeError: 'type' object is not subscriptable` | 本机默认 Python 3.8 太旧，工具需 ≥3.9 | 用 Python 3.10 venv（见第五步），勿用系统 3.8 |
| `usbmux list` 空 / 找不到设备 | 设备未连、或未点"信任此电脑" | 插好 USB、iPad 解锁并确认已信任 |
| `Installation failed` | IPA 签名失效/描述文件不含该设备 | 重新触发构建，确认描述文件含目标 UDID |

---

## 限制与注意事项

1. **免费 Apple 账号签名的 IPA 有效期仅 7 天**，过期需重新触发构建并重装。
2. **macOS runner 排队时间不固定**：GitHub 免费额度下，`macos-latest` 偶尔排队数分钟，属正常现象。
3. **Node.js 20 deprecation 警告**：`actions/checkout@v4` 与 `actions/upload-artifact@v4` 目前会强制跑在 Node 24，仅是警告不影响构建。如需消除，可升级到对应 v5 版本。
4. **敏感文件不入库**：`*.p12`、`*.mobileprovision`、`*_base64.txt`、`tdx.db` 等应放在 `.gitignore` 中或仓库根之外。本工作流中 `git add` 始终只加具体源码文件。
5. **TRAE 的 RunCommand 终端是 PowerShell**：命令里用 `;` 串联、用 `Select-String` 而非 `grep`、路径用反斜杠或正斜杠均可。
6. **错误分析只能读日志，不能下断点**：相比 macOS 本地 Xcode 调试，缺少交互式调试器。弥补方式：在代码里大量用 `os_log`/`print` 输出运行时日志，再用 Console.app 或设备日志分析。
7. **安装工具是 Python venv**：iOS 安装走 `.venv-ios`（Python 3.10），不要用系统默认的 Python 3.8。venv 目录较大，建议加入项目的 `.gitignore`。
8. **升级式安装保留数据**：重复装同一 App 直接用 `apps install` 即可（升级语义保沙盒数据），**不要**先 uninstall。
9. **首次配对需手动**：iPad 首次连电脑要人工点"信任"，之后永久生效，不影响后续自动化。

---

**文档版本**：2.0  
**更新日期**：2026-08-31  
**配套文档**：[iOS-GitHub-Actions-CI.md](./iOS-GitHub-Actions-CI.md)（CI 初始搭建指南）
