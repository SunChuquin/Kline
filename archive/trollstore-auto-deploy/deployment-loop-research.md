# TrollStore 自动部署闭环 — 摸索过程与历史沉淀（归档）

> 本文档归档 `2026-09-07 ~ 2026-09-08` 打通「Windows + GitHub Actions + 部署助手 + TrollStore 免弹窗自动安装 + opener 装后自动打开」这一闭环期间，从项目记忆里固化下来的**摸索过程、尝试过的死路、已退役形态与历史结论**。
>
> **闭环现已是稳定形态、无需再看本文**。现行事实/约束/约定见 `c:\Users\sunck\.trae-cn\memory\projects\-c-Users-sunck-home-projects-ios--p2-4e5c445026d816ee62d7\project_memory.md`。
>
> **目录**
> 1. [部署形态演进史](#1-部署形态演进史)
> 2. [尝试过的死路 / 不可行结论](#2-尝试过的死路--不可行结论)
> 3. [已退役 / 被取代的形态](#3-已退役--被取代的形态)
> 4. [历史约束与权限踩坑](#4-历史约束与权限踩坑)
> 5. [方案 B / 方案 A 背景与取舍](#5-方案-b--方案-a-背景与取舍)
> 6. [数据与方法迁移记录](#6-数据与方法迁移记录)
> 7. [部署相关约束（原 Hard Constraints 3-12）](#7-部署相关约束原-hard-constraints-3-12)
> 8. [方案 A Lessons Learned（原项目记忆现行段）](#8-方案-a-lessons-learned原项目记忆现行段已归档)

---

## 1. 部署形态演进史

| 阶段 | 时间 | 形态 | 结局 |
|---|---|---|---|
| ① 签名版部署 | 早期 | Xcode 自动签名 + `apps install` 装 IPA（`com.sunck.Kline.4G3V8W86TN`，User 态） | 已被 TrollStore 版取代 |
| ② AFC 公共目录中转 | 2026-09-07 | `deploy_kline_to_ipad.py` AFC push IPA 到 `/var/mobile/Media/Downloads/` + 远程触发 | 部署助手沙盒直连取代 |
| ③ 沙盒直连 | 2026-09-07 | KlineHTTP `/sandbox/<path>` + `sandbox_cli.py`，电脑直接读写 Kline-TS Documents | 现行 |
| ④ 自动部署助手 | 2026-09-07 | `deploy_gui.py`（自动轮询 + notify 触发 + 自动部署） | 现行 |
| ⑤ 免弹窗 + 自动打开 | 2026-09-08 | TrollStore 设为 Never + opener root 守护自动打开新版 | 现行（终态） |

- **两代闭环描述（历史）**：
  - 旧「TrollStore 更新闭环」（2026-09-07，需手动点「打开」+「Install」）：CI 构建（未签名+ad-hoc+entitlements）→ 下载 IPA → AFC push 到 iPad `Downloads/` → Kline 前台 `remote_update.py`（usbmux forward 5051 → POST /install-local）触发 → 用户 iPad 点「打开」+「Install」。
  - 现行终态（2026-09-08）：触发 → 自动安装（Never）→ opener 自动打开 → 本地服务自动绑定，全程无需 iPad 操作。

## 2. 尝试过的死路 / 不可行结论

- **用 Web Inspector/WebDriver 点系统级原生弹窗全部不可行**：远程自动化授权、URL Scheme 拉起确认、TrollStore Install 按钮都无法通过 Web Inspector 或 WebDriver 点击。→ 放弃该路线，改走「root helper + Never」。
- **WebView（Web Inspector/CDP）无法对自定义 URL Scheme 做顶层导航**：`webinspector launch` 卡死、`runtime_evaluate` 无反应、CDP `Page.navigate` 返回空 frameId；判定不通，用户手动在 Safari 地址栏输入才可行。
- **`springboard` 服务及其他工具（diagnostics/lockdown/mounter/webinspector）均无锁屏/解锁/密码输入能力**；XCTest UI 自动化需 Mac+Xcode+开发者模式+授权，不适用于 Windows 电脑 USB 直连。→ 锁屏/托盘不可程序化控制。
- **ES WiFi HTTP 上传依赖 ES 文件浏览器保持前台**：后台会断开 HTTP 监听线程导致 503 错误（研究者尝过的旁路，未采用）。
- **HouseArrestService 对 TrollStore 侧载的 Kline 不可用**：报 `AppNotInstalledError`，因该安装方式不登记容器，为安装方式的根本差异，非代码可修复。
- **`apps install` 对 TrollStore 版 IPA（ad-hoc 签名）会失败**：签名版部署才用 `apps install`。

## 3. 已退役 / 被取代的形态

- `deploy_kline_to_ipad.py`（AFC push 公共区推 IPA，含 `--pull-logs`）→ 由 `deploy_gui.py` 沙盒直连取代。文件保留供参考。
- 公共区 `/var/mobile/Media/Downloads` 作 IPA 中转 → 改为沙盒 `Documents/Downloads`。
- A1 双写日志到公共目录 + `--pull-logs` → 退役，日志只写沙盒 `debug_log.txt`。
- A2 面板「导入 tdx.db（从 Downloads）」「使用旧版行情库（Xcode 版）」按钮 → 退役。A2 面板现扫/装沙盒 `Documents/Downloads`。
- 签名版部署（`apps install`）→ 退役，现行一律 TrollStore + No-sandbox 形态。

## 4. 历史约束与权限踩坑

> 以下均为摸索期结论，多数仍指导现行构建，但已收敛进 `project_memory.md` 的现行约束；此处保留完整推理供回溯。

- **keychain 注入组合**：`com.apple.private.security.no-sandbox` + `platform-application` + `com.apple.private.security.storage.AppDataContainers`（2026-09-07 最终组合）。
  - 仅 no-sandbox（或 +container-required=false）→ App 启动闪退（"Launched process exited during launch"，无崩溃报告，exec 阶段拦截）。
  - **`platform-application` 是 no-sandbox 生效的必要条件**。
  - 副作用①：UIActivityViewController 共享面板闪退（CoreImage GL 空指针崩溃）→ 用本地 HTTP + URL Scheme 替代。
  - 副作用②：写自身容器无权限（NSCocoaErrorDomain 513）→ 必须补 `AppDataContainers=true`（TrollStore 官方 README 指明）。
- **App 切后台后 HTTP 监听 socket 会被系统冻结**，新连接无法接入，除非有 VoIP/audio/location 等特定后台权限（注入此类权限大概率被 AMFI 忽略）。
- **`com.apple.developer.*` 类后台权限需要 provisioning profile 对应 capability 才能激活**，仅注入 entitlement 大概率被 AMFI 忽略。
- **TrollStore 侧载安装的 App 不会在 iOS 的 Installation Lookup 登记容器**，HouseArrestService 无法访问其沙盒。
- **部署助手进程未重启会导致新版检测逻辑不生效**：表现为用户打开 Kline 后助手仍显示等待。

## 5. 方案 B / 方案 A 背景与取舍

- **方案 B**：手动把 TrollStore 安装确认弹窗设为「Never」→ 可免弹窗安装，但**无法自动打开**应用。是现行方案的免弹窗前提。
- **方案 A**：嵌入 root helper（`opener`/`rootprobe`）→ 可实现**完全自动化（免弹窗 + 自动打开）**，但需代码改动。最终打通。
  - 落地文档：`TrollStore-方案A-免确认自动安装.md`（含阶段 0-4 实施步骤及风险回滚策略，保留在仓库根）。
  - 早期实施设想（已由最终实现取代，保留核实）：嵌入 `trollstorehelper` 二进制到 `Kline.app/`，并单独注入其 entitlements；用 Swift `posix_spawn` 调 `posix_spawnattr_set_persona_np` 等私有函数取 root；用 `LSApplicationWorkspace.openApplication(withBundleID:)` 自动打开新版；代码需宏/编译条件隔离，不影响 Xcode 版构建。
  - `trollstorehelper` 二进制在安装时被 TrollStore 自动重签，无需单独处理签名。
- **一次性手动配置**：现行零触碰只需一次性在 TrollStore 设置里把安装确认改为 Never。

## 6. 数据与方法迁移记录

- **行情库迁移（2026-09-07）**：电脑端完整 `tdx.db`（3611 标的）→ `migrate_tdxdb.py` 经 KlineHTTP `POST /upload`（流式写盘，1.35GB 不攒内存）传到公共 Downloads → Kline「导入 tdx.db」拷贝进容器。要点：①TrollStore 版新容器只有种子库（1 标的），行情打转多半是数据缺失；②platform-application 下写容器需 `AppDataContainers` entitlement（否则 513）；③大文件上传必须流式写 FileHandle（攒 Data 会 OOM）。
- **误杀/误判教训**：`apps pull com.sunck.Kline` 报 `InstallationLookupFailed` 曾误判为"house_arrest 全挂"，实际是 Xcode 版 bundle id 带 Team ID 后缀（`com.sunck.Kline.4G3V8W86TN`）；遇到同名 App 并存先 `apps list` 查完整 id。
- **沙盒中已存在 tdx 文件不会被 `copyBuiltin` 覆盖**：需手动删除旧副本或添加字段。

## 7. 部署相关约束（原项目记忆 Hard Constraints 3-12，已归档）

> 以下曾在项目内存的 Hard Constraints 里留存，随部署闭环稳定后固化到本文档。它们仍指导现行构建/部署，但不需每次会话都内联在内存中；需要做部署相关改动时再回看本文。
>
> - CI 构建流程：`CODE_SIGNING_ALLOWED=NO` 完全禁用签名 → 随后必须 ad-hoc 签名；`xcodebuild archive` 需加 `-allowProvisioningUpdates`
> - keychain 注入组合见 §4（`no-sandbox` + `platform-application` + `AppDataContainers`）
> - TrollStore 版「安装到 TrollStore」必须走本地 HTTP + URL Scheme（`apple-magnifier://install?url=http://127.0.0.1:5051/sandbox/...`），**不要用 UIActivityViewController**（必崩）
> - TrollStore 侧载 App 不在 Installation Lookup 登记容器 → HouseArrestService 不可用；跨沙盒文件操作用 `try?` + `catch` 兜底避免闪退
> - **CI 产物显示名 = Kline-TS**（PlistBuddy 改 CFBundleDisplayName），与 Xcode 版（Kline）区分
> - **双 Kline 并存**：Xcode 版 bundle id = `com.sunck.Kline.4G3V8W86TN`（User 态）；TrollStore 版 = `com.sunck.Kline`（System 态）。查 Xcode 版容器必须用带后缀完整 id（否则 `InstallationLookupFailed`）
> - **System/User 容器隔离（data vault）**：TrollStore 版即使 no-sandbox 也读不了 Xcode 版容器 —— 跨态数据迁移必须经电脑中转
> - **文件 App 对 Kline-TS 沙盒可见**：能管理其 Documents；两个 Kline 沙盒靠显示名区分；文件 App 够不到公共区 `/var/mobile/Media/Downloads`
> - 权限自检仅保留 Downloads + 根目录两项（勿加 SMS 检查避免误导）
> - `Kline.entitlements` 需含 `com.apple.private.persona-mgmt`（方案A root spawn 用；Xcode 工程未引用该文件，不影响 Xcode 版构建）

## 8. 方案 A Lessons Learned（原项目记忆现行段，已归档）

> 以下原在 `project_memory.md` 的 Lessons Learned 段，随闭环稳定后归档至此。新会话默认不需内联，涉及 opener / KlineHTTPServer / 部署助手时回看本文。

- **方案A「装完自动打开」闭环（2026-09-08 端到端打通，现行终态）**：`opener.m`（root 守护）+ `KlineHTTPServer.spawnDetached` + CI 嵌入，配合 TrollStore「Never」免弹窗 → 触发→自动安装→自动打开→本地服务自动上线。证据链日志：`found ver=X>cur` → `new version detected -> open` → `openApplicationWithBundleID:com.sunck.Kline -> 1` → `open ret=0`。教训：
  1. **版本滞后陷阱**：装版本 N 由「当前在跑的前一版 N-1」嵌入的 opener 触发——给 opener 加修复，得先装上一版、再装 N 才用上新 opener（会造一串版本号）
  2. **opener/rootprobe 是裸二级制，须单独签 no-sandbox**（在通用 `find ! -name Kline codesign` 之后单独 `codesign -f -s - --entitlements "$ENT"`，并把它俩从 find 排除）——否则 root 守护仍在沙盒，写不了日志、读不了系统容器
  3. **`LSApplicationWorkspace` 默认不在进程里**：须 `loadLSFrameworks()` 对私有框架 `dlopen`（MobileCoreServices/CoreServices/LaunchServices/SpringBoardServices/MobileInstallation），再 `NSClassFromString+performSelector`
  4. **版本判定用 `v != cur`**（不必更高），避免为触发自动打开造无用递增版本
  5. **KlineHTTPServer 绑定失败须自动退避重试**：自动拉起太快撞上旧进程 5051 未释放（`Address already in use`，`allowLocalEndpointReuse` 只救 TIME\_WAIT）→ `.failed` 分支按 `0.8s×N` 退避重建（`bindRetry<10`），`.ready` 复位
  6. opener.m：`loadLSFrameworks` 调用 `logmsg` 需前置声明；C `snprintf` 不能用 ObjC 格式符 `%@`
- **部署助手状态读取要等足**：`GET /status` 部署中会经历多状态切换，且新版冷启动 + 服务器自动重试有延迟；TRAE 轮询太快会误读成失败，应等数秒再判