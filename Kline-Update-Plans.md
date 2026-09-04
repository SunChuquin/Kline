# Kline 远程更新与本地更新方案

> 本文档记录 Kline IPA 在 TrollStore 永久安装后的两种更新方案，以及验证优先级和操作手册。
> 创建时间：2026-09-04
> 最后更新：2026-09-04

***

## 当前状态快照（2026-09-04）

### ✅ 已完成

| 项                     | 状态    | 证据/位置                                                                                                                                                                                                         |
| --------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CI build.yml 改造       | ✅     | [build.yml](file:///c:/Users/sunck/home/projects/ios/Kline/.github/workflows/build.yml) — 未签名构建 + ad-hoc 签名 + entitlements 注入                                                                                 |
| Kline.entitlements 文件 | ✅     | [Kline.entitlements](file:///c:/Users/sunck/home/projects/ios/Kline/Kline.entitlements) — `no-sandbox` + `container-required`                                                                                 |
| A2 本地更新代码             | ✅     | [LocalUpdateView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/LocalUpdateView.swift) + [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/ProfileDetailView.swift) |
| CI 构建验证通过             | ✅     | RUN 33886227348，1m7s，commit `638d8a0`                                                                                                                                                                         |
| IPA 产物下载到本地           | ✅     | `c:\Users\sunck\home\projects\ios\artifacts\Kline.ipa`（1,977,403 字节）                                                                                                                                          |
| TrollStore 已装到 iPad   | ✅     | iPad mini 4 上已安装 TrollStore + Persistence Helper                                                                                                                                                              |
| 临时 GitHub Release     | ❌ 已清理 | `trollstore-temp-20260904105902` 已删除（tag + release 均清除）                                                                                                                                                       |

### ⏸ 待验证（等用户回到电脑前）

| 项                                                         | 依赖                                    | 预计耗时 |
| --------------------------------------------------------- | ------------------------------------- | ---- |
| 🥇 pymobiledevice3 `webinspector launch` 对 URL Scheme 的行为 | iPad USB 连接 + Safari Web Inspector 开启 | 5 分钟 |
| 🥉 A2 本地更新面板在 iPad 上的实际效果                                 | 先用 `afc push` 推 IPA 到 iPad            | 5 分钟 |
| no-sandbox 权限是否真的生效                                       | A2 面板的"权限自检"按钮                        | 1 分钟 |

### ❌ 未开始

| 项                                        | 依赖               |
| ---------------------------------------- | ---------------- |
| Gitee 仓库创建 + access token 获取             | 用户操作（Gitee 网站）   |
| 🥈 Kline HTTP 服务器代码（`Network.framework`） | 仅当 🥇 不通时才做      |
| Gitee Release 上传的 CI 步骤                  | 仅当 🥇 或 🥈 需要时才做 |
| `remote_update.py` 脚本                    | 仅当 🥈 需要时才做      |

### 设备与环境信息

| 项                 | 值                                                               |
| ----------------- | --------------------------------------------------------------- |
| 设备                | iPad mini 4（`iPad5,2`，A8 芯片）                                    |
| iOS 版本            | 15.8.8                                                          |
| UDID              | `b36adcb0...f81fe`（完整值在项目记忆里）                                   |
| TrollStore        | 已安装 + Persistence Helper 已设置                                    |
| Web Inspector     | 已开启（设置 → Safari → 高级）                                           |
| Remote Automation | 已开启（同上）                                                         |
| pymobiledevice3   | 版本 11.2.4，venv 路径 `c:\Users\sunck\home\projects\ios\.venv-ios\` |
| Bundle ID         | `com.sunck.Kline`                                               |
| Team ID           | `4G3V8W86TN`（仅 Xcode 调试签名用，TrollStore 版不需要）                     |

### deploy\_kline\_to\_ipad.py 用法速查

**路径**：`c:\Users\sunck\home\projects\ios\TrollRestore\deploy_kline_to_ipad.py`

**默认行为（无参数）**：

- 检测 USB 连接的 iPad

- 把 `c:\Users\sunck\home\projects\ios\artifacts\Kline.ipa` 通过 AFC 推到 `/var/mobile/Media/Downloads/Kline.ipa`

- 列出 `Downloads/` 验证文件存在

- 输出用户需做的手动步骤

**可选参数**：

```bash
# 同时走 WiFi ES 上传做双保险（需 ES 文件浏览器在前台开 WiFi 传输）
python deploy_kline_to_ipad.py --es-url http://<iPadIP>:5050

# 同时输出 Safari URL Scheme（需先有 IPA 的 http URL）
python deploy_kline_to_ipad.py --url-scheme "https://gitee.com/.../Kline.ipa"
```

**调用方式**：

```bash
& "c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\python.exe" "c:\Users\sunck\home\projects\ios\TrollRestore\deploy_kline_to_ipad.py"
```

***

## 背景与约束

### 系统限制

- **TrollStore 侧载的 App 不在 Installation Lookup 注册表登记**，导致 `pymobiledevice3 house_arrest` 按 bundle\_id 查询容器路径时永远报 `AppNotInstalledError`——即使 App 的 Info.plist 里写了 `UIFileSharingEnabled=True` 也没用。这是安装方式的根本差异，不是代码能修复的。

- **TrollStore URL Scheme**：`apple-magnifier://install?url=<URL>`，其中 `url` 参数必须是 `http://` 或 `https://`（TrollStore 内部用 NSURLSession 下载），不接受 `file://`。

- **TrollStore 安装确认弹窗**：TrollStore 对所有外部发起的安装请求强制弹 `UIAlertController` 让用户确认 Install / Cancel，这是安全护栏，无法跳过。

- **iOS 后台限制**：App 切后台后 HTTP 监听 socket 被系统冻结，新连接进不来。除非有 VoIP/audio/location 等特定后台权限，否则无法维持 TCP 监听。

### 当前已注入的权限

CI 构建时通过 `codesign --entitlements Kline.entitlements` 注入：

- `com.apple.private.security.no-sandbox=true`：关闭 sandbox，Kline 可读全文件系统

- `com.apple.private.security.container-required=true`：保留自身容器映射，防止丢失沙盒写权限

> 这两个 entitlement 只在 CI（macOS runner）上注入，Xcode IDE 调试时不碰（Xcode 走自己的 CODE\_SIGN\_ENTITLEMENTS 配置，工程里是空的）。两条构建路径互不干扰。

### 双构建路径兼容性（Xcode IDE 调试 + CI TrollStore 同时支持）

**核心保证：entitlements 只在 CI 那条路径上注入，Xcode IDE 调试这条路完全不碰 entitlements。**

| 路径                                 | 签名方式                                                              | entitlements 用不用 | 谁负责                 |
| ---------------------------------- | ----------------------------------------------------------------- | ---------------- | ------------------- |
| **A. Xcode IDE 调试真机**              | Xcode 自动签名（开发者证书）                                                 | ❌ 不用             | Xcode 自己管           |
| **B. GitHub Actions → TrollStore** | `codesign -f -s -` (ad-hoc) + `--entitlements Kline.entitlements` | ✅ 用              | CI 的 build.yml step |

**为什么不会互相破坏：**

- `Kline.entitlements` 这个文件**只被 CI 的 codesign 命令读取**，Xcode IDE 编译时根本不读它（Xcode 走自己的 `.xcodeproj` 里 Build Settings 的 `CODE_SIGN_ENTITLEMENTS` 配置，工程里这个 key 是空的）

- Kline 代码里**所有新功能都用运行时降级**：

  - 读公共目录失败 → 静默 `try?` 不崩

  - 共享 IPA 失败 → 弹 alert 告诉用户"权限不足"

  - 自检按钮读 SMS 目录失败 → 显示 ❌，App 继续跑

- **沙盒版（Xcode 装上去的）就当普通 App 用**，no-sandbox 那部分功能不生效但不报错；**TrollStore 版（CI 装上去的）才解锁全部功能**。同一份代码，两种部署形态。

> ⚠️ **代码风险提醒：** `FileManager` 读 `/var/mobile/Media/Downloads` 这种路径时，**必须用** **`try?`** **+** **`catch`** **兜底**，绝对不能裸 `FileManager.default.contents(atPath:)`——沙盒 App 直接抛 `NSCocoaErrorDomain code=257`（Operation not permitted），不处理会闪退。所有跨沙盒文件操作必须包在 do-catch 里，沙盒版触发时走降级路径。

**风险评估：**

| 权限                   | 类型                    | 需要 provisioning profile | 闪退风险  | 能生效吗                                   |
| -------------------- | --------------------- | ----------------------- | ----- | -------------------------------------- |
| `no-sandbox`         | `com.apple.private.*` | ❌ 不需要                   | ❌ 不闪退 | ✅ TrollStore 社区广泛验证，iOS 15 A8 设备上大概率生效 |
| `container-required` | `com.apple.private.*` | ❌ 不需要                   | ❌ 不闪退 | ✅ 同上，搭配 no-sandbox 的标准做法               |

> **为什么不闪退：** `com.apple.private.*` 类权限不需要 provisioning profile 对应 capability，TrollStore 的 CoreTrust 签名足够让 AMFI 应用它们。不生效也只是权限不应用（权限自检显示 ❌），App 照常运行不崩溃。

### 为什么不注入后台权限（VoIP/audio/location/platform-application）

有人可能想注入后台权限让 Kline 在后台保持 HTTP 监听。**不推荐，理由如下：**

| 权限                                        | 类型                      | 需要 provisioning profile | 闪退风险        | TrollStore 上能生效 |
| ----------------------------------------- | ----------------------- | ----------------------- | ----------- | --------------- |
| `com.apple.developer.networking.voip`     | `com.apple.developer.*` | ✅ 需要                    | ❌ 不闪退但没用    | ❌ 大概率不生效        |
| `UIBackgroundModes: audio`（Info.plist）    | Info.plist 配置           | ✅ 需要 capability         | ❌ 不闪退但没用    | ❌ 大概率不生效        |
| `UIBackgroundModes: location`（Info.plist） | Info.plist 配置           | ✅ 需要 capability+用户授权    | ❌ 不闪退但耗电    | ❌ 大概率不生效        |
| `platform-application=true`               | 特殊                      | ❌ 不需要                   | 🔴 **可能闪退** | ⚠️ 可能生效但风险大     |

**关键区别：**

- `com.apple.private.*`（当前注入的）：不需要 provisioning profile，TrollStore 社区验证可用

- `com.apple.developer.*`（VoIP 等）：需要 provisioning profile 对应 capability，TrollStore 安装的 App 没有有效 profile，AMFI 大概率忽略

- `platform-application`：把进程标记为平台二进制，触发更严格签名校验链，CoreTrust 签名可能不完全匹配 → **启动闪退**

> **结论：** 接受"Kline 必须前台运行才能 HTTP 监听"的限制。三个方案里只有 🥈 需要 Kline 前台运行，且 🥈 只是备选。如果 🥇 验证通过，Kline 完全不需要后台运行。

***

## 方案总览

| 方案                                     | 改 Kline | 用户操作                       | 需要梯子 | 状态       |
| -------------------------------------- | ------- | -------------------------- | ---- | -------- |
| 🥇 pymobiledevice3 USB 直接打开 URL Scheme | ❌       | 2步（确认打开+Install）           | ❌    | 待验证      |
| 🥈 Kline HTTP 服务器 + Gitee + 自动触发       | ✅       | 3步（开Kline+确认打开+Install）    | ❌    | 待验证🥇后决定 |
| 🥉 A2 本地更新面板（已实现）                      | ✅       | 4步（开Kline+点扫描+点共享+Install） | ❌    | ✅ 已就绪    |
| A1 日志双写（解决 TRAE 读沙盒死路）                 | ✅       | 无（自动）                      | ❌    | ⏸ 待实现    |

> A1 不是独立安装方案，是解决"TRAE 通过 USB 读 Kline 沙盒日志"的 HouseArrest 死路。和 🥇/🥈/🥉 互补，可同时做。

***

## 🥇 方案一：pymobiledevice3 USB 直接打开 URL Scheme

### 原理

通过 USB 用 pymobiledevice3 的 WebInspector 服务直接在设备上打开 URL Scheme，拉起 TrollStore 从 Gitee（国内，不需要梯子）下载 IPA。

### 验证步骤

#### 第1步：确认设备连接

```bash
PM=c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pymobiledevice3.exe
%PM% usbmux list
```

#### 第2步：测试 `webinspector launch` 对 URL Scheme 的行为

```bash
# 先用简单 URL Scheme 测试会不会卡死
%PM% webinspector launch "apple-magnifier://"

# 如果不卡，再试完整安装 URL（需要一个 http URL）
%PM% webinspector launch "apple-magnifier://install?url=https://gitee.com/<user>/<repo>/releases/download/<tag>/Kline.ipa"
```

#### 第3步：如果 `launch` 卡死，改试 `js-shell`

```bash
# 进入 JS 交互 shell
%PM% webinspector js-shell

# 在 shell 里执行（JS 改 location 不等 page load，可能不卡死）
window.location.href = "apple-magnifier://install?url=https://gitee.com/.../Kline.ipa"
```

### 判断标准

- ✅ TrollStore 被拉起，开始从 Gitee 下载 IPA → 🥇 方案通了，不改 Kline

- ❌ 命令卡死 / 报错 / Safari 没反应 → 进入 🥈 方案

### 🥇 验证通过后的后续步骤（Gitee 配置）

如果 🥇 验证通过，说明 pymobiledevice3 能直接打开 URL Scheme 拉起 TrollStore。接下来需要把 IPA 的下载源从 GitHub（需梯子）换成 Gitee（国内直连）。

#### 1. 创建 Gitee 仓库

- 登录 [Gitee](https://gitee.com)（国内代码托管，不需要梯子）

- 创建一个公开仓库，如 `SunChuquin/Kline-Releases`（或用现有仓库的 Release 功能）

- 仓库用途：存放 CI 构建产出的 IPA Release，供 TrollStore URL Scheme 下载

#### 2. 获取 Access Token

- Gitee → 设置 → 私人令牌 → 生成新令牌

- 勾选 `projects` 权限

- 保存到本地（不入库）：`c:\Users\sunck\home\projects\ios\gitee_token.txt`

#### 3. 在 CI build.yml 加 Gitee Release 上传步骤

在 `build.yml` 的 `Upload .ipa artifact` 步骤后加：

```yaml
- name: Upload to Gitee Release
  if: github.ref == 'refs/heads/main'
  env:
    GITEE_TOKEN: ${{ secrets.GITEE_TOKEN }}
  run: |
    # 创建 Release
    TAG="build-${{ github.run_id }}"
    curl -s -X POST "https://gitee.com/api/v5/repos/<owner>/<repo>/releases" \
      -H "Content-Type: application/json" \
      -d "{\"tag_name\":\"$TAG\",\"name\":\"Kline $TAG\",\"body\":\"CI auto build\",\"target_commitish\":\"main\",\"access_token\":\"$GITEE_TOKEN\"}" \
      > release.json
    # 提取 Release ID，上传附件
    RELEASE_ID=$(python3 -c "import json; print(json.load(open('release.json'))['id'])")
    curl -s -X POST "https://gitee.com/api/v5/repos/<owner>/<repo>/releases/$RELEASE_ID/attach_files" \
      -H "Content-Type: multipart/form-data" \
      -F "file=@Kline.ipa" \
      -F "access_token=$GITEE_TOKEN"
    # 输出下载 URL
    echo "Download URL: https://gitee.com/<owner>/<repo>/releases/download/$TAG/Kline.ipa"
```

> ⚠️ Gitee Release 附件上传 API 和 GitHub 不同，需要实测确认 URL 格式和直接下载是否需要登录。
> ⚠️ `GITEE_TOKEN` 需要在 GitHub 仓库 Settings → Secrets 里添加。

#### 4. 写一键远程更新脚本

在 `c:\Users\sunck\home\projects\ios\TrollRestore\` 下新建 `remote_update.py`：

```python
# 伪代码
# 1. 等 GitHub Actions 构建完成（gh run watch）
# 2. 从 Gitee Release API 获取最新 IPA 下载 URL
# 3. 通过 USB 调 pymobiledevice3 webinspector launch "apple-magnifier://install?url=<Gitee URL>"
# 4. 用户在 iPad 上只需点 TrollStore 的 Install 确认
```

#### 5. 验证完整链路

```bash
# 在电脑上一条命令完成全链路
python remote_update.py
# → 自动：等构建 → 取 Gitee URL → USB 调 URL Scheme → 用户点 Install
```

***

## 🥈 方案二：Kline HTTP 服务器 + Gitee + 自动触发

### 原理

Kline 内嵌一个轻量 HTTP 服务器（前台运行时监听端口），TRAE 通过局域网 POST 指令（含 Gitee IPA URL）给 Kline，Kline 收到后调用 `UIApplication.shared.open()` 拉起 TrollStore。因为 IPA 从 Gitee 下载（外部服务器），Kline 切后台不影响下载。

### 为什么 Kline 调 URL Scheme 一定行

`UIApplication.shared.open(URL("apple-magnifier://install?url=..."))` 是 iOS **公开 API**，任何 App 都能调，不需要任何 entitlement 或特殊权限。iOS 系统收到调用后：

1. 把 URL 交给 SpringBoard
2. SpringBoard 查 `apple-magnifier://` 的 handler → TrollStore
3. TrollStore 拉起到前台，从 Gitee 下载 IPA
4. Kline 切后台——但无所谓，IPA 从 Gitee 下载，不依赖 Kline

### 如果需要实现，改动点

1. **Kline 端**：用 `Network.framework` 加一个轻量 HTTP 服务器（约几十行 Swift），前台监听一个端口（如 5051），收到 POST 请求后解析 JSON 里的 `url` 字段，调用 `UIApplication.shared.open()`
2. **TRAE 端**：写一个 `remote_update.py` 脚本，push 代码后自动：

   - 上传 IPA 到 Gitee Release

   - 通过局域网 POST 指令到 Kline
3. **Gitee 配置**：需要 Gitee 账号和 access token，仓库设为公开

### 用户操作流程

```
1. 在 iPad 上打开 Kline（HTTP 服务器开始监听）
2. TRAE 在电脑上执行 remote_update.py（全自动：push→构建→上传Gitee→POST指令到Kline）
3. Kline 收到指令，自动调 URL Scheme → 系统弹"在 TrollStore 中打开？"
4. 点确认 → TrollStore 从 Gitee 下载 IPA → 弹 Install
5. 点 Install
```

***

## 🥉 方案三：A2 本地更新面板（已实现）

### 原理

利用 no-sandbox 权限，Kline 直接扫描 `/var/mobile/Media/Downloads/*.ipa`，通过 `UIActivityViewController`（B1 系统共享面板）把 IPA 文件共享给 TrollStore。

### 相关文件

- [LocalUpdateView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/LocalUpdateView.swift)：完整的本地更新面板

- [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/ProfileDetailView.swift)：入口页面（已嵌入 LocalUpdateView）

### 功能清单

1. **扫描本地 IPA**：扫描 `/var/mobile/Media/Downloads/*.ipa`，列出文件名、大小、修改时间
2. **共享到 TrollStore**：点按钮 → 系统共享面板 → 选 TrollStore → Install
3. **权限自检**：验证 no-sandbox 是否生效（读 Downloads/、SMS 目录、根目录）
4. **当前版本显示**：显示当前 App 版本号

### 降级策略

- **TrollStore 版（no-sandbox 生效）**：完整功能，可扫描 + 共享 + 自检全绿

- **Xcode 调试版（普通沙盒）**：扫描报错"无法访问 Downloads 目录"，App 不崩溃，提示"需要 TrollStore 版"

### 用户操作流程

```
1. TRAE 通过 USB AFC 推 IPA 到 /var/mobile/Media/Downloads/
   （deploy_kline_to_ipad.py，约5秒）
2. 在 iPad 上打开 Kline → 个人中心
3. 点"扫描本地 IPA" → 列出 Kline.ipa
4. 点"共享到 TrollStore" → 系统共享面板
5. 选 TrollStore → Install
```

### B1 vs B2 共享按钮风格对比

| 风格                                                        | 实现                               | 点击数              | 能用吗       |
| --------------------------------------------------------- | -------------------------------- | ---------------- | --------- |
| **B1. 系统共享面板**（`UIActivityViewController`）                | 弹系统共享 sheet，用户在应用列表里找 TrollStore | +1（选 TrollStore） | ✅ 已实现，稳定  |
| **B2. 直接** **`UIApplication.shared.open(trollstoreURL)`** | 跳过共享面板，直接拉起 TrollStore           | +0               | ❌ **做不到** |

**B2 为什么不行：**

- TrollStore URL Scheme 实测只接受 `http://` / `https://`，**`file://`** **会被 reject**

- B2 需要先复制 IPA 到 Kline 沙盒（TrollStore URL Scheme 不接受公共区路径，必须 `file://` 沙盒路径），多一步拷贝时间

- 即使复制到沙盒，`apple-magnifier://install?url=file:///var/mobile/.../Kline.ipa` 也会被 TrollStore 拒绝

- **结论：用 B1 系统共享面板。** 流程是：开 Kline → 点「检查更新」→ 点「共享到 TrollStore」→ 系统弹面板选 TrollStore → Install（3 次点击）

***

## A1 方案：日志双写（解决 TRAE 读沙盒死路）

> 本方案不是独立安装方案，是解决"TRAE 通过 USB 读 Kline 沙盒日志"的 HouseArrest 死路。和 🥇/🥈/🥉 互补，可同时做。

### 背景

TrollStore 侧载的 App 不在 Installation Lookup 注册表登记，导致 `pymobiledevice3 house_arrest` 按 bundle\_id 查询容器路径永远报 `AppNotInstalledError`。之前 TRAE 读 Kline 沙盒日志（`Documents/debug_log.txt`）用的就是 HouseArrest，TrollStore 版这条路死了。

### 原理

把日志写到 **AFC 公共目录**（`/var/mobile/Media/Downloads/KlineLogs/`），TRAE 用 `pymobiledevice3 afc pull` 读——AFC 服务不需要 bundle\_id，USB 连上就能用。

### 改动点

1. **Kline 端** **[DebugLogger.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/DebugLogger.swift)**：

   - 原 `Documents/debug_log.txt` 写入完成后，**镜像一份**到 `/var/mobile/Media/Downloads/KlineLogs/debug_log.txt`

   - 整个包裹在 `do-catch` 里，失败静默降级（不影响 App 正常运行）

   - 需要 no-sandbox 权限（TrollStore 版生效，Xcode 调试版降级不崩）

2. **TRAE 端** **[deploy\_kline\_to\_ipad.py](file:///c:/Users/sunck/home/projects/ios/TrollRestore/deploy_kline_to_ipad.py)**：

   - 加 `--pull-logs` 参数

   - 用 `pymobiledevice3 afc pull Downloads/KlineLogs/debug_log.txt <local_path>` 代替 `pymobiledevice3 apps pull com.sunck.Kline Documents/debug_log.txt`

   - AFC pull 不经过 HouseArrest，不需要 bundle\_id 注册

### 状态

- ⏸ 待实现（等 🥇/🥉 验证完成后，作为工具链优化项实现）

- 不影响安装流程，只影响 TRAE 读日志的调试闭环

***

## Gitee Release 配置（🥇/🥈 方案需要）

> 本节内容已并入上方 🥇 方案的「验证通过后的后续步骤」，此处保留为索引。
>
> - 创建 Gitee 仓库 + 获取 token：见 🥇 后续步骤的 1、2
>
> - CI 上传到 Gitee Release：见 🥇 后续步骤的 3
>
> - Gitee API 文档：<https://gitee.com/api/v5/openapi>
>
> - ⚠️ Release 附件上传 API 和 GitHub 不同，需要实测确认 URL 格式和直接下载是否需要登录

***

## 验证优先级与操作清单

### 回到电脑前后按以下顺序验证

#### Step 1：验证 🥇 pymobiledevice3 能否直接打开 URL Scheme（5分钟）

```bash
PM=c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pymobiledevice3.exe
%PM% usbmux list                                    # 确认设备连接
%PM% webinspector launch "apple-magnifier://"      # 测试简单 URL Scheme
```

- 通了 → 进入 Step 1b

- 卡死/报错 → 试 `js-shell`，再不行跳到 Step 2

#### Step 1b：测试完整安装 URL

需要一个 http URL 的 IPA。有两种方式获取：

**方式 A：临时创建 GitHub Release（推荐，已验证可用）**

```bash
# 在电脑上创建临时 Release 上传 IPA
cd c:\Users\sunck\home\projects\ios\Kline
gh release create trollstore-test --repo SunChuquin/Kline "c:\Users\sunck\home\projects\ios\artifacts\Kline.ipa" --title "TrollStore Test" --notes "临时测试用"
# 获取下载 URL
gh release view trollstore-test --repo SunChuquin/Kline --json assets --jq '.assets[0].url'
# → 输出类似 https://github.com/SunChuquin/Kline/releases/download/trollstore-test/Kline.ipa
```

**方式 B：电脑开临时 HTTP 服务器（局域网，不需创建 Release）**

```bash
# 在 artifacts 目录开 HTTP 服务器
cd c:\Users\sunck\home\projects\ios\artifacts
python -m http.server 8080
# 获取电脑局域网 IP
ipconfig | findstr IPv4
# → IPA URL: http://<电脑IP>:8080/Kline.ipa
# 注意：此方式需 iPad 和电脑在同一局域网，且电脑 HTTP 服务器需保持运行
```

**然后用获取到的 URL 测试：**

```bash
# 方式 A 的 URL（需梯子，但已验证可用）
%PM% webinspector launch "apple-magnifier://install?url=https://github.com/SunChuquin/Kline/releases/download/trollstore-test/Kline.ipa"

# 方式 B 的 URL（局域网直连，不需梯子，但需电脑保持运行）
%PM% webinspector launch "apple-magnifier://install?url=http://<电脑IP>:8080/Kline.ipa"
```

- 通了 → 🥇 方案确认，不需要改 Kline，配置 Gitee Release 即可

- 不通 → 进入 Step 2

#### Step 2：验证 🥉 A2 本地更新面板（已就绪）

```bash
# 推送含本地更新面板的 IPA 到 iPad
%PM% afc push "c:\Users\sunck\home\projects\ios\artifacts\Kline.ipa" Downloads/Kline.ipa
```

然后在 iPad 上：

1. 打开 Kline → 个人中心
2. 点"权限自检" → 确认 no-sandbox 生效（✅ Downloads/可读 + ✅ SMS/可读 + ✅ 根目录可读）
3. 点"扫描本地 IPA" → 应列出 `Kline.ipa`
4. 点"共享到 TrollStore" → 系统共享面板 → 选 TrollStore → Install

#### Step 3（仅当 🥇 不通时）：实现 🥈 Kline HTTP 服务器

如果 Step 1 的 pymobiledevice3 方案不通，则：

1. 给 Kline 加 HTTP 服务器（`Network.framework`，前台监听端口）
2. 写 `remote_update.py` 脚本
3. 配置 Gitee Release 上传
4. Push 构建 → 安装 → 测试远程触发

***

## 关键工具与文件位置

| 工具/文件                      | 路径                                                                       | 用途                                   |
| -------------------------- | ------------------------------------------------------------------------ | ------------------------------------ |
| pymobiledevice3            | `c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\pymobiledevice3.exe` | iOS 设备通信                             |
| deploy\_kline\_to\_ipad.py | `c:\Users\sunck\home\projects\ios\TrollRestore\deploy_kline_to_ipad.py`  | USB AFC 推 IPA 到 iPad Downloads       |
| LocalUpdateView\.swift     | `Kline/Kline/LocalUpdateView.swift`                                      | A2 本地更新面板                            |
| Kline.entitlements         | `Kline/Kline.entitlements`                                               | no-sandbox + container-required 权限声明 |
| build.yml                  | `Kline/.github/workflows/build.yml`                                      | CI 构建+ad-hoc签名+entitlements注入        |
| artifacts                  | `c:\Users\sunck\home\projects\ios\artifacts\Kline.ipa`                   | 最新 IPA 产物                            |

***

## 待办事项：同步更新其他文档

> 本文档（远程/本地更新方案）确立的 TrollStore 部署形态，与项目记忆 `project_memory.md` 和 [TRAE-Windows-Build-Workflow.md](file:///c:/Users/sunck/home/projects/ios/Kline/TRAE-Windows-Build-Workflow.md) 里记录的「签名 IPA + `apps install`」旧形态有出入。以下点需要在相应文档里同步更新，避免下次会话拿到旧文档时按错路径执行（如对 TrollStore 版 IPA 跑 `apps install` 会失败）。

### A. 项目记忆（project\_memory.md）需要更新的点

| #  | 位置                           | 现状（过时）                                                                   | 应改为                                                                                                                  | 触发条件      |
| -- | ---------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- | --------- |
| A1 | "项目概况" → "iOS 安装工具链"         | "pymobiledevice3 11.2.4（经 USB 把 IPA 装到 iPad）"                            | 补充：TrollStore 版改为 AFC push 到 `/var/mobile/Media/Downloads/` + 用户在 TrollStore 手动安装；`apps install` 仅对签名版有效             | 🥇 验证后    |
| A2 | "TRAE Windows 自动构建工作流" 第 7 步 | "`apps install <ipa>` 升级式安装"                                             | 改为：TrollStore 版用 `deploy_kline_to_ipad.py`（AFC push）+ 用户手动 TrollStore 安装；签名版才用 `apps install`                        | 🥇 验证后    |
| A3 | "沙盒调试日志闭环" → "读取端"           | "拉取：`pymobiledevice3 apps pull com.sunck.Kline Documents/debug_log.txt`" | 标注：TrollStore 版此路不通（HouseArrest 死路），需等 A1 日志双写方案实现后改用 `afc pull Downloads/KlineLogs/debug_log.txt`                   | A1 方案实现后  |
| A4 | "疑难问题诊断规则" 第 4 步             | "用 `apps pull com.sunck.Kline Documents/debug_log.txt` 拉取日志"             | 同 A3，改为 AFC pull 路径                                                                                                  | A1 方案实现后  |
| A5 | "关键文件位置"                     | 缺少新文件                                                                    | 补充：`Kline.entitlements`、`Kline/LocalUpdateView.swift`、`Kline-Update-Plans.md`、`TrollRestore/deploy_kline_to_ipad.py` | 现在可做      |
| A6 | "验证记录"                       | 最后一条是 2026-09-03 本地更新面板验证                                                | 等 🥇/🥉 验证完成后补充新的验证记录                                                                                                | 🥇/🥉 验证后 |
| A7 | "Hard Constraints"           | 已有 TrollStore + HouseArrest 条目（正确）                                       | 补充：ad-hoc 签名的 IPA 不能用 `apps install` 装（iOS 拒绝非合法签名），必须走 TrollStore                                                   | 现在可做      |

### B. TRAE-Windows-Build-Workflow\.md 需要更新的点

| #  | 章节                          | 现状（过时）                                                                                          | 应改为                                                                                                          | 触发条件      |
| -- | --------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | --------- |
| B1 | "前置条件"表格 → GitHub Secrets 行 | "`CERTIFICATE_BASE64` / `CERTIFICATE_PASSWORD` / `PROVISION_PROFILE_BASE64` 已配置"                | 标注：TrollStore 版 CI 不需要证书 Secrets（未签名构建 + ad-hoc）；签名版才需要                                                      | 现在可做      |
| B2 | "工作流总览"图                    | `import cert → install prof → xcodebuild archive → xcodebuild -exportArchive → upload-artifact` | 补充 TrollStore 版分支：`xcodebuild build (unsigned) → ad-hoc sign + entitlements → package ipa → upload-artifact` | 现在可做      |
| B3 | "第五步：自动安装到 iPad" 全节         | 以 `apps install` 为核心                                                                            | 改写：TrollStore 版用 AFC push（`deploy_kline_to_ipad.py`）+ 用户手动 TrollStore 安装；保留 `apps install` 作为签名版备用路径         | 🥇 验证后    |
| B4 | "5.4 验证已安装"                 | `apps list` 查 `com.sunck.Kline` + `ProfileValidated: true`                                      | 标注：TrollStore 版不在 Installation Lookup，`apps list` 查不到；改为 AFC 看文件 + 用户在 iPad 确认                               | 🥇 验证后    |
| B5 | "完整闭环示例"                    | 2026-08-27 签名版闭环（已过时）                                                                           | 补充 2026-09-04 后的 TrollStore 版闭环记录（RUN ID、IPA 大小、安装方式）                                                        | 🥇/🥉 验证后 |
| B6 | "限制与注意事项" 第 1 条             | "免费 Apple 账号签名的 IPA 有效期仅 7 天"                                                                   | 补充：TrollStore 版永久有效，无 7 天限制                                                                                  | 现在可做      |
| B7 | "故障排查"表                     | 无 TrollStore 相关条目                                                                               | 补充：TrollStore 报错 173（IPA 未签名）→ 已由 ad-hoc 签名步骤解决；`house_arrest` 报 `AppNotInstalledError` → 改用 AFC             | 现在可做      |
| B8 | 文档版本/日期                     | "2.0 / 2026-08-31"                                                                              | 升版本号 + 更新日期，并在开头说明部署形态已切换为 TrollStore                                                                        | 各项更新完成后   |

### 执行时机

| 时机                  | 待办项               | 说明                        |
| ------------------- | ----------------- | ------------------------- |
| **现在可做**（不依赖验证结果）   | A5、A7、B1、B2、B6、B7 | 这些点的事实已确定，可直接改            |
| **🥇 验证后做**（确认路径再改） | A1、A2、B3、B4、B5    | 等 🥇 验证确认最终安装路径再改，避免改了又要改 |
| **A1 日志双写实现后做**     | A3、A4             | 等 A1 方案实现，日志读取路径确定后再同步    |
| **🥇/🥉 全部验证完成后做**  | A6、B8             | 统一收尾，升版本号                 |

> ⚠️ **不做的后果**：这些待办项是「文档同步」工作，不影响 IPA 安装功能本身。但如果不做，下次会话拿到旧文档可能按 `apps install` 路径执行，对 TrollStore 版会失败，浪费一轮构建。尤其是 B3/B4（第五步整节）和 A3/A4（日志读取路径），是最容易踩坑的点。

