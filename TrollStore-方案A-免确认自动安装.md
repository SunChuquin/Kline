# TrollStore 免弹窗自动安装 · 方案 A 落地清单

> 背景：当前 Kline-TS 部署闭环的最后一步（TrollStore 安装确认）依赖 iPad 手动点击，无法全自动。方案 A 让 Kline 自己以 root 安装并自动打开新版，彻底绕开 TrollStore 确认弹窗。
> 适用范围：本机唯一目标设备 iPad mini 4（iPad5,2，iOS 15.8.8，A8）。

## 目标

- Kline-TS 自身具备 root 安装能力，安装过程全程无弹窗、无手动确认。
- 安装成功后自动拉起新版 Kline（连同部署助手轮询 version 完成闭环）。
- 绝对不影响现有 Xcode 版部署路径。

## 已确认前提（可放心，无需重复排查）

- Xcode 工程不引用 `Kline.entitlements`：`Kline.xcodeproj/project.pbxproj` 仅有 `CODE_SIGN_STYLE = Automatic`，无 `CODE_SIGN_ENTITLEMENTS`。→ 加进 `Kline.entitlements` 的任何 entitlement 只作用于 CI 打的 TrollStore 版，对 Xcode 版零影响。
- 关键机制：以 root 运行子进程 = `posix_spawnattr_set_persona_np(..., 99, OVERRIDE)` + uid/gid=0（参考 `TrollStore/Shared/TSUtil.m` 的 `spawnRoot`），依赖调用方注入 `com.apple.private.persona-mgmt`。
- 启动任意已装 App = `[[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:]`（参考 `TrollStore/TrollStore/TSApplicationsManager.m`）。
- Kline 为纯 Swift 工程，无 ObjC bridge：`posix_spawn` 可 `import Darwin` + `dlsym` 调私有符号，无需建桥接头。
- 模拟器无法据此验证（无 profile 校验）；关键验证必须在 iPad 真机上进行。

---

## 阶段 0 · 决策：helper 二进制来源

- [ ] **选项 A 复用官方发布版** `TrollStore.app/trollstorehelper`（fat 静态二进制）——最快，但随 TrollStore 版本绑定。
- [~] **选项 B 自编极简 install-only helper**（推荐）——用 RootHelper 裁剪出只留 `install` 子命令，去掉 JIT/持久化等无关私有框架依赖，可控、易排错。

## 阶段 1 · 最小冒烟验证（先证 persona-mgmt 可用，再投入后续）

- [ ] 在 `Kline.entitlements` 增加：
  ```xml
  <key>com.apple.private.persona-mgmt</key>
  <true/>
  ```
- [ ] 只改这一处，构建新版 TrollStore IPA，仍走现有 TrollStore 安装（弹窗点一次）。
- [ ] 装好后用 Swift 起一个 persona-99/uid=0 的 `posix_spawn` 冒烟命令，确认拿到 root。
- [ ] **通过标准**：能 spawn 出 uid=0 进程。
  - 失败主因排查：AMFI 不认 persona（但已带 `platform-application`）、链接/符号问题。

## 阶段 2 · 嵌入 helper + 构建改造（两处小改，均在 CI）

- [ ] 按阶段 0 选型产出 `trollstorehelper`（arm64 fat）产物。
- [ ] `build.yml` 打包前拷入 `Kline.app/`：
  ```bash
  cp ./trollstorehelper "$APP_PATH/trollstorehelper"
  ```
- [ ] 对 helper 单独注入其 entitlements（避免 `codesign -f -s -` 无 ent 覆盖原值）：
  ```bash
  codesign -f -s - --entitlements RootHelper/entitlements.plist "$APP_PATH/trollstorehelper"
  ```
  注意与现有"对非主二进制 adhoc 签名"的 `find ... -exec` 循环的顺序与覆盖关系。

## 阶段 3 · Kline Swift 接入（核心，4 处）

- [ ] `spawnRoot` 的 Swift 实现：`import Darwin`，`dlsym` 调 `posix_spawnattr_set_persona_np / _uid_np / _gid_np`，persona=99 + uid/gid=0。
- [ ] 安装动作：`spawnRoot("\(Bundle.main.bundlePath)/trollstorehelper", ["install", ipaPath])`。
- [ ] 自动打开新版：安装返回 0 后用 `LSApplicationWorkspace.openApplication(withBundleID: "com.sunck.Kline")` 拉起新版。
  - ⚠️ **自我终止时序**：install 会先 kill 当前 Kline（同 bundle id），因此"打开新版"由 helper 返回后尚存的进程 / helper 内执行（或独立守护进程），不能由已死的旧 Kline 自己完成。
- [ ] 宏/编译条件隔离：该段代码仅 TrollStore 版编译，Xcode 版不触达。

## 阶段 4 · 端到端回归（双路径互不污染）

- [ ] 触发现有 deploy 流程：CI 构建 → 部署助手 → 全程无弹窗 → 装完自动拉起新版 → 助手轮询到 version 匹配。
- [ ] Xcode 回归：照常 Xcode 真机构建装 Xcode 版，确认照旧可用。
- [ ] 构建号验证沿用现有 PlistBuddy `Delete+Add CFBundleVersion` 注入逻辑。

---

## 风险与回滚

| 风险点 | 缓解 / 回滚 |
|---|---|
| persona-mgmt 在 A8 / iOS 15.8 上不生效 | 阶段 1 单独验证；不通过则不投入后续，回退方案 B（仅免确认） |
| 自动打开"自我唤醒"时序（旧进程被杀） | 由 helper 或守护进程触发 open（阶段 3 ⚠️ 重点实测） |
| CI 空 entitlements 覆盖 helper | 阶段 2 单独注入 helper entitlements |
| 对 Xcode 路径干扰 | 已从 pbxproj 排除（不引用 Kline.entitlements）；阶段 4 真机构建兜底确认 |

## 当前状态

- 阶段 0-4：未开始（尚未执行任何改动）。
- 已确认：Xcode 零影响、随 `Kline.entitlements` 生效、模拟器不可验证、Kline 为纯 Swift。