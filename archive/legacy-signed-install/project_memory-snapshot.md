# 项目记忆快照（2026-09-04，旧签名形态相关段落）

> **快照时间**：2026-09-04
> **来源**：`c:\Users\sunck\.trae-cn\memory\projects\-c-Users-sunck-home-projects-ios--p2-4e5c445026d816ee62d7\project_memory.md`
> **性质**：静态历史留底，记录项目记忆在「签名 IPA + `apps install`」旧形态下的关键条目。**以 `.trae-cn/memory/` 内的现行项目记忆为准**，本快照不参与跨会话检索，仅作回退/对照参考。
> **新形态替代**：见 [../../Kline-Update-Plans.md](../../Kline-Update-Plans.md) 的「待办事项：同步更新其他文档」章节（A1~A7、B1~B8），等 TrollStore 新形态验证完成后按那份清单统一更新项目记忆。

---

## 摘录：与旧签名形态强相关的条目

以下段落**原样摘录**自 2026-09-04 的项目记忆，标注 ⚠️ 的为切换到 TrollStore 后需更新/已失效的点。

### 1. 项目概况 → iOS 安装工具链

> **iOS 安装工具链**：Python 3.10 venv `c:\Users\sunck\home\projects\ios\.venv-ios` + `pymobiledevice3 11.2.4`（经 USB 把 IPA 装到 iPad）

⚠️ **过时点**：「把 IPA 装到 iPad」隐含 `apps install`。TrollStore 版 IPA 是 ad-hoc 签名，`apps install` 会失败；新形态改为 AFC push 到 `/var/mobile/Media/Downloads/` + TrollStore 手动安装。对应待办 A1。

### 2. TRAE Windows 自动构建工作流（已验证）→ 第 7 步

> 7. **自动安装到 iPad** → `PM=c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pymobiledevice3.exe`；`%PM% usbmux list` 看设备；`%PM% apps install <ipa>` 升级式安装（**不先卸载**，保沙盒数据）；`%PM% apps list` 验证

⚠️ **过时点**：`apps install` 对 TrollStore 版不可用；`apps list` 对 TrollStore 侧载的 App 查不到（不在 Installation Lookup）。新形态用 `deploy_kline_to_ipad.py`（AFC push）+ 用户手动 TrollStore 安装。对应待办 A2。

### 3. 关键命令速查

> - 列最近 run：`gh run list --limit 3`
> - 阻塞监控：`gh run watch <ID> --exit-status`
> - 仅失败日志：`gh run view <ID> --log-failed`
> - **ipa 安装**：`%PM% apps install <ipa>`

⚠️ **过时点**：最后一条 `apps install` 是旧形态。新形态见 deploy_kline_to_ipad.py。

### 4. 沙盒调试日志闭环（2026-08-31 打通）→ 读取端

> - **读取端**（house_arrest，实测可用）：
>   - 拉取：`pymobiledevice3 apps pull com.sunck.Kline Documents/debug_log.txt <本地路径>`
>   - 列目录：`pymobiledevice3 apps afc com.sunck.Kline`（交互 shell，可 `ls Documents`）
>   - 注意 `apps pull`/`apps afc` 与 `apps install` 同属设备服务，无需 DDI 之外的新东西

⚠️ **过时点（关键）**：house_arrest / `apps pull` 对 TrollStore 侧载的 Kline **完全不可用**（报 `AppNotInstalledError`，因不在 Installation Lookup 登记）。这是旧形态切换到新形态后最易踩的坑。新形态需实现 A1 日志双写方案，改用 `afc pull Downloads/KlineLogs/debug_log.txt`。对应待办 A3。

### 5. 疑难问题诊断规则（重要约定）→ 第 4 步

> 4. 用 `apps pull com.sunck.Kline Documents/debug_log.txt` 拉取日志，**读取沙盒日志分析定位**并修复；

⚠️ **过时点**：同上，`apps pull` 对 TrollStore 版死路。对应待办 A4。

### 6. 验证记录（旧形态时间线）

> - 2026-08-27 首次完整闭环验证：正常推送 ✅ → 故意引入错误 ❌ → 日志定位 `ContentView.swift:130:27 cannot find 'nonExistentTab'` → 修复重推 ✅
> - 最终 IPA：`artifacts\Kline\Kline.ipa`（931089 字节）
> - 2026-08-31 **打通"自动安装到 iPad"**：识别 iPad mini4（iOS15.8.8）→ `apps install Kline.ipa` → `Installation succeed.` → `apps list` 确认 `com.sunck.Kline` 且 `ProfileValidated: true`。至此「构建 → 下载 → 安装」全自动闭环成立
> - 2026-09-03 **本地更新面板验证**：CI 构建 RUN 33886227348 通过，IPA 1,977,403 字节，含 no-sandbox + container-required 权限及 LocalUpdateView.swift 实现

ℹ️ 这三条是旧形态的历史验证记录，事实本身不变（当时确实用 `apps install` 装成功过签名版）。2026-09-03 那条已是新形态过渡期（ad-hoc 签名 + entitlements），但安装方式仍按旧形态描述，待新形态验证后补充。对应待办 A6。

### 7. Hard Constraints（与签名/apps install 相关）

> - tdx 指标文件新增可选字段 `COORD` …
> - 副图一/二两端方向箭头仅在拖动中显示…
> - CI 环境中 `xcodebuild archive` 命令必须添加 `-allowProvisioningUpdates` 参数以支持自动签名
> - 远端 workflow 需设置 `CODE_SIGNING_ALLOWED=NO` 完全禁用签名，随后必须进行 ad-hoc 签名
> - TrollStore 侧载安装的 App 不会在 iOS 的 Installation Lookup 登记容器，HouseArrestService 无法访问其沙盒

ℹ️ 第 3 条（`-allowProvisioningUpdates`）是旧签名形态 CI 的约束；第 4、5 条已是新形态约束，仍有效。对应待办 A7。

### 8. Engineering Conventions（部分相关）

> - USB 推送文件到 iPad 应使用 AFC 服务的公共文件区 `/var/mobile/Media/Downloads/`，而非 HouseArrestService
> - 推荐使用 `deploy_kline_to_ipad.py` 脚本通过 USB AFC 推送 IPA 到 `/var/mobile/Media/Downloads/`，默认行为无需参数
> - 本地更新功能实现在 `LocalUpdateView.swift`，嵌入到 `ProfileDetailView.swift` 中…
> - 权限自检功能用于验证 `no-sandbox` 权限是否生效…
> - 日志双写方案：`DebugLogger.swift` 将日志镜像一份到 `/var/mobile/Media/Downloads/KlineLogs/debug_log.txt`，包裹在 `do-catch` 中，失败静默降级
> - `deploy_kline_to_ipad.py` 新增 `--pull-logs` 参数，用 `afc pull Downloads/KlineLogs/debug_log.txt <local>` 代替 `apps pull`

ℹ️ 这些是新形态的约定，已部分落地（AFC push、LocalUpdateView、权限自检），A1 日志双写待实现。注意「日志双写方案」在项目记忆里记的是**计划态**（"将日志镜像一份"），实际代码 `DebugLogger.swift` 尚未实现双写，待 A1 落地。

---

## 新旧形态命令对照

| 操作 | 旧形态（本快照记录） | 新形态（TrollStore） |
|------|------------------|---------------------|
| 装 IPA | `pymobiledevice3 apps install <ipa>` | AFC push 到 Downloads + TrollStore 手动安装（`deploy_kline_to_ipad.py`） |
| 看已装 App | `apps list` 查 `ProfileValidated` | `apps list` 查不到 TrollStore 版；改为 AFC 看文件 + iPad 确认 |
| 读沙盒日志 | `apps pull com.sunck.Kline Documents/debug_log.txt` | `afc pull Downloads/KlineLogs/debug_log.txt`（A1 实现后） |
| 列沙盒目录 | `apps afc com.sunck.Kline`（house_arrest） | `afc ls Downloads/KlineLogs`（AFC 服务，不经 house_arrest） |
| CI 签名 | import cert + archive + exportArchive（需 3 个 Secrets） | build (unsigned) + ad-hoc sign + entitlements（无需证书 Secrets） |
| IPA 有效期 | 7 天 | 永久 |

---

## 通用约定（不随形态变化，仅备查）

以下条目与部署形态无关，新旧形态通用，摘录备查（不属于"过时点"）：

- 信息对齐协议（改前摊父链 / 确认式父链提问 / 结构化几何快照）—— 涉及布局/UI 调整的工作习惯
- 提交粒度：`git add` 只加具体源码文件，绝不 `git add .`/`-A`
- commit 风格：中文一句话描述 + 括号说明依据
- 推送分支：`main`（push 直接触发 workflow）
- IPA 落地目录：`c:\Users\sunck\home\projects\ios\artifacts\`
- 错误分析替代 Xcode：`--log-failed` 日志等价于 Xcode IDE 编译错误面板
- 设备未连接/未信任的处理（强制询问）：检测不到设备时用 AskUserQuestion，不自行重试
- 清理约定：用户反馈问题已解决时，主动删除为该问题添加的沙盒埋点

---

**快照结束**。如需回退到签名形态，参考本快照 + 同目录 [TRAE-Windows-Build-Workflow.md](./TRAE-Windows-Build-Workflow.md) + [iOS-GitHub-Actions-CI.md](./iOS-GitHub-Actions-CI.md) 三件套即可恢复旧形态全貌。
