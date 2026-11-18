# iPhone 11（iOS 27.2）+ 常开 Mac mini：免费 Apple ID 自签名 App「7 天自动续签」落地方案

> 核查时间：2026-11-14　适用设备：iPhone 11（iPhone12,1，iOS 27.2 / 24B119）+ Mac mini M1（macOS 26.5.1 / Xcode 26.6）
> 本文所有版本号、限制、菜单路径均按核查当日官方资料与实机只读排查结果编写；来源见附录 A。

---

## 0. 一句话结论

**首选路径：Mac mini 装官方 AltServer 1.8 并设为登录自启 + iPhone 装 AltStore Classic（当前 2.3.3）**，让 AltStore 在后台通过同一局域网向 AltServer 请求重签，7 天倒计时自动重置；再用「快捷指令 → 个人自动化」每天定时跑一次 `Refresh All` 作为兜底。
你这台机器的常开条件已经天然满足（不会睡眠、断电自动开机、FileVault 关闭可开自动登录），所以**只需要装两个官方软件 + 改 4 个设置**，不需要 Docker、不需要越狱、不需要付费开发者账号。

---

## 1. 你这台机器的实际现状（实机只读排查，2026-11-14）

| 项目 | 实测结果 | 对本方案的影响 |
|---|---|---|
| Mac 型号 | Mac mini（Macmini9,1，Apple M1，8GB），macOS 26.5.1（25F80） | 满足 AltServer 要求（macOS 11+） |
| Xcode | Xcode 26.6（17F113），`xcode-select` 正常 | 可选：以后也能用 Xcode 直接装，但只有 7 天 |
| 网络 | Wi-Fi（en1）192.168.2.8 / 掩码 255.255.255.0 / 网关 192.168.2.1 | iPhone 需连同一网段 Wi-Fi |
| 电源 | `pmset`：`sleep 0`、`displaysleep 0`、`womp 1`、`tcpkeepalive 1`、`autorestart 1` | **已满足常开**：不睡眠、支持网络唤醒、断电恢复后自动开机 |
| FileVault | Off | 可以开「自动登录」，重启后无人值守也能跑 AltServer |
| 已装侧载工具 | **没有** AltServer、SideStore、Sideloadly、AltStore（/Applications 与 ~/Applications 都没有） | 需要从零安装 |
| Docker | 只有 `/usr/local/bin/docker` 这个 CLI，**Docker.app 不存在、daemon 没运行** | 「用 Docker 常驻续签」当前不可行 |
| 登录项 | 向日葵、Snipaste、BetterDisplay、网易有道翻译 | 需新增 AltServer |
| iPhone | iPhone 11（iPhone12,1），**iOS 27.2（24B119）**，UDID `00008030-001158362EA0402E`，已 USB 配对（wired），**开发者模式已开启** | 少一步：不用再开开发者模式 |
| iPhone 已装自签名 App | `Kline 1.0.2`（com.sunck.Kline） | 它已经占掉 3 个名额中的 1 个，并且同样 7 天过期 |

> 注意：`iPhone 11` 这个名字下面还有一条 `simulated` 的模拟器记录，别在 AltServer/Xcode 里选错；真机在 `devicectl` 里显示为 **sunchuquin**。

---

## 2. 方案原理（一句话版）

免费 Apple ID 的签名证书 **7 天后过期**，过期后 App 点开就闪退/无法验证。AltStore 的「续签」= 让 AltServer 用同一个 Apple ID 向 Apple 重新申请描述文件并覆盖安装（**不删数据**），从而把 7 天重置。所以链条是：

```
iPhone(AltStore, 后台/定时唤醒) ──同一局域网(Bonjour)──> Mac mini(AltServer 1.8, 常驻)
                                     └─> 向 Apple 重新签名 ─> 覆盖安装到 iPhone（数据保留）
```

链条上任一环断掉（Mac 关机/睡眠、不同网段、VPN/防火墙隔离、Apple ID 登录态失效），续签就失败，所以第 5 章给了三层兜底。

---

## 3. 第一部分：Mac 端配置（按顺序做，A1→A8）

### A1. 下载 AltServer（官方来源）

- 打开 <https://altstore.io/> → 页面底部 **Downloads** → 点 **AltServer macOS**（直链 `https://cdn.altstore.io/file/altstore/altserver.zip`）。
- 当前版本实测为 **AltServer 1.8（build 97）**，要求 macOS 11 或更高。
- 只从上面这个官方域名下载。网上流传的「AltServer macOS 1.8.2」查不到出处，不要用第三方站点的安装包。

### A2. 安装并首次启动

1. 解压 zip，把 `AltServer.app` 拖进 `/Applications`（**必须放这里**，后面登录项要用这个路径）。
2. 首次打开：在 `/Applications` 里 **右键 AltServer → 打开** → 弹窗点「打开」（未公证提示用右键打开即可绕过 Gatekeeper）。
3. 成功后菜单栏出现 AltServer 图标（一个酒杯/圆圈图标）。**没有窗口**，这是正常的。

### A3. 设为「登录时自动启动」（关键，重启后不用管）

优先做法：
- 点菜单栏 **AltServer 图标 → Launch at Login**（勾选）。

如果没有这一项或勾了不生效，用系统登录项：
1. 打开 **系统设置 → 通用 → 登录项与扩展**（macOS 26 里叫「登录项与扩展」）。
2. 在「登录时打开」区域点 **+**。
3. 选择 `/Applications/AltServer.app` → 添加。
4. 确认它出现在列表里，且未被「允许在后台」开关关闭。

> 验证：重启一次 Mac，登录后看菜单栏是否有 AltServer 图标（这是最可靠的验证，别只看设置界面）。

### A4. 电源设置（本机已满足，核对一遍即可）

**系统设置 → 能源**（Mac mini 是台式机，有「能源」页）：
- 勾选 **「防止电脑在显示器关闭时自动进入睡眠」**；
- 「唤醒以供网络访问」保持开启（对应 `womp 1`）。

命令行核对（只读）：
```bash
pmset -g custom
# 期望：sleep 0 / displaysleep 0 / womp 1 / autorestart 1
```
本机当前已是 `sleep 0`，无需改动。

### A5.（可选但推荐）开启自动登录，让重启后完全无人值守

**系统设置 → 用户与群组 → 自动登录：选择你的账户**（会要求输入一次开机密码）。
- 前提：**FileVault 必须是关闭状态**（本机已 Off✅）。若你以后开启 FileVault，自动登录会自动失效，重启后需人工登录一次。
- 若不想关 FileVault，也可以保持手动登录：登录后 AltServer 会自动起来，只是「重启到登录」这段需要人。

### A6. 打开 Finder 的 Wi-Fi 同步（AltStore 靠它走无线）

1. USB 连上 iPhone，解锁，iPhone 弹「要信任此电脑吗」→ **信任** → 输入锁屏密码。
2. Mac 打开 **访达（Finder）**，左侧栏点你的 iPhone。
3. 在「通用」页勾选 **「在 Wi-Fi 上显示此 iPhone」**（macOS 26 上就是这一项，旧文案是「连接 Wi-Fi 时显示此 iPhone」）。
4. 点「应用」。

> 这一步等价于老教程里的「iTunes 开启 Wi-Fi 同步」。**不做这步，AltServer 只能 USB 工作，后台自动续签会失效。**

### A7. 网络要求（最容易踩的坑）

- Mac（192.168.2.8）与 iPhone 必须在**同一子网**。若路由器开了「AP 隔离/Guest 网络隔离」，Bonjour 发现会失败 → 把两者放到同一主网络。
- 公司/学校/酒店 Wi-Fi 常禁止设备互访，这种情况只能 USB。
- Mac 用 **有线网 + iPhone 用 Wi-Fi** 且在同一路由器下通常没问题（同网段即可，不要求都走 Wi-Fi）。

### A8. 防火墙放行（如果开了防火墙）

**系统设置 → 网络 → 防火墙 → 选项**：确认 `AltServer` 在列表里且允许「传入连接」。若列表里没有，先启动 AltServer 再来这里看。

---

## 4. 第二部分：把 AltStore 装到 iPhone（B1→B7）

> ⚠️ **B3 的 Apple ID 密码与 B3 的 6 位验证码必须由你本人输入**，任何工具（包括我）都不应代做。

### B1. 连接

USB 线连 Mac，iPhone **解锁**，弹窗选「信任」，输锁屏密码。

### B2. 从 AltServer 安装

点菜单栏 **AltServer 图标 → Install AltStore → sunchuquin**（选真机那条，不要选带「模拟器」的 iPad/iPhone 条目）。

### B3. 登录 Apple ID（你亲自操作）

1. 弹窗里填 **Apple ID 邮箱** + **密码**。
2. 密码只发给 Apple（AltStore 官方声明：凭据仅用于向 Apple 认证，不经过第三方服务器）。
3. 若开了双重认证，iPhone 会弹出 6 位验证码 → 在 Mac 的弹窗里输入。**2.3.3 已修复「2FA 验证码不弹窗」的老 bug**，若你装的是 2.3/2.3.1 之前版本，可能卡在这一步。
4. 建议：**为侧载单独准备一个免费 Apple ID**，与主账号隔离，降低主账号被风控的概率（AltStore 官方 troubleshooting 也这么建议）。用同一个 ID 也能用，但风险集中。

### B4. 等待安装完成

Mac 右上角应出现 AltServer 通知「AltStore was successfully installed」。
- 没收到通知：**系统设置 → 通知 → AltServer → 允许通知**。
- iPhone 桌面没图标：**重启 iPhone**（官方文档明确提到这一点）。

### B5. iPhone 信任开发者证书

**设置 → 通用 → VPN 与设备管理 → 「开发者 App」→ 点你的 Apple ID → 信任「<你的 Apple ID>」→ 允许**。

### B6. 开发者模式（本机已开启，跳过；换机/刷机时才需要）

**设置 → 隐私与安全性 → 滑到「安全性」区域 → 开发者模式 → 打开 → 重启 → 重启后确认开启**。
- 说明：这个开关通常在你**第一次尝试运行开发签名的 App** 之后才会出现。
- iOS 27 与 iOS 16–26 路径一致（Apple 官方文档仍是「设置 > 隐私与安全性 > 开发者模式」）；本机 `devicectl` 显示 `Developer Mode: Enabled`，无需再操作。

### B7. 确认账号类型

打开 **AltStore → Settings → Account**，应显示为 **Free / 免费开发者账号**（而非 Paid）。

---

## 5. 第三部分：iPhone 端必要设置（C1→C5）

| # | 设置 | 路径 | 作用 |
|---|---|---|---|
| C1 | 允许通知 | **设置 → 通知 → AltStore → 允许通知** | 续签失败/即将过期时能收到提醒 |
| C2 | 打开后台刷新 | **AltStore → Settings（设置）→ Refreshing Apps → Background Refresh 打开** | 让 AltStore 在后台自动找 AltServer 续签 |
| C3 | 生成 Siri 快捷指令 | **AltStore → Settings → Refreshing Apps → Add to Siri...** → 添加 | 给「快捷指令」提供 `Refresh All` 动作，是自动化的前提 |
| C4 | 允许后台 App 刷新 | **设置 → 通用 → 后台 App 刷新 → 确认「后台 App 刷新」总开关为开，且 AltStore 为开** | 系统级放行 |
| C5 | 关闭低电量模式 | **设置 → 电池 → 低电量模式：关闭** | 低电量模式会压制后台任务，导致续签不触发 |

补充两条「不要做」：
- **不要**在「设置 → 通用 → VPN 与设备管理」里删除你的 Apple ID 描述文件（删了就相当于注销签名）。
- **不要**开「专注模式」把 AltStore 的通知完全静音到看不见（失败提醒是你唯一的早期信号）。

**iOS 27 差异小结**：开发者模式、信任证书、「VPN 与设备管理」这三条路径与 iOS 26 一致，没有公开的路径变更记录；iOS 27 上真正需要注意的是 **Remote AltServer（免电脑）功能有未修复的报错**（见 6.4），本地 AltServer 方案不受影响。

---

## 6. 第四部分：触发与容错（三层兜底）

### 6.1 正常机制（什么都不用做）

AltStore 在后台被系统唤醒 → 经同一局域网找到 AltServer → 请求重签 → 覆盖安装 → 7 天倒计时重置。

**关于「提前多少天开始重试」（已核实，别指望有固定窗口）**：
- 官方文档只写「apps expire after 7 days… AltStore 会尝试在后台刷新」，**没有承诺任何固定的提前天数**；
- 后台刷新用的是 iOS 后台任务（机会式调度），具体何时执行由系统按电量、使用习惯、Wi-Fi 状态决定，可能一天多次，也可能连续几天不给机会；
- 代码里能查到的唯一确定时间点是：**到期前 24 小时**推一条本地通知提醒（`AppManager.swift` 中 `expirationDate - 24h`）——那是「提醒窗口」，不是「保证刷新窗口」。
- 结论：**不要依赖系统自动刷**，用 6.3 的每日定时自动化 + 每周人工抽查来兜住。

### 6.2 先手动验证一次（装完必做，否则你不知道链条通不通）

1. iPhone 打开 **AltStore → My Apps**，看每个 App 右侧的「N DAYS」。
2. 点右上角 **Refresh All**（或点天数本身刷新单个）。
3. 看 Mac 菜单栏 AltServer 是否弹出刷新通知；iPhone 上倒计时应回到 7。
4. 若失败：见 6.6 错误码表。

> 这一步**必须在 USB 拔掉、只用 Wi-Fi 的情况下做一次**，才能证明无线链路（A6、A7）真的通了。

### 6.3 兜底 1：快捷指令「个人自动化」每天定时刷新（推荐，最省心）

1. 打开 **快捷指令** App → 底部 **自动化** → 右上角 **＋**。
2. 如果是首次：屏幕上会出现「**个人自动化**」与「家庭自动化」两个大按钮 → 选 **个人自动化**。
3. 事件列表里选 **「特定时间」**（有的版本叫「时间」）。
4. 把时间设成 **09:00** → 下方「重复」选 **每天** → 右上 **下一步**。
5. 在「添加操作」搜索框里输入 **Refresh**（或 **AltStore**）→ 选中 **「Refresh All」**（图标是 AltStore 的，副标题类似 "Refreshes your sideloaded apps"）→ 右上 **下一步**。
6. 在最后一页把 **「运行前询问」关掉**（新系统里可能显示为「立即运行 / Run Immediately」，选它）。iOS 会要求确认一次「不要询问」。
7. 点 **完成**。
8. **重复 1–7 再做一条 21:00 的**（同样的操作、只改时间）。

**找不到「Refresh All」动作时怎么办（按顺序试）**
1. 先回 AltStore：**AltStore → Settings → Refreshing Apps → Add to Siri...** → 添加一次并给它起名，然后退出 AltStore 再回快捷指令搜索（该动作只有注册过才会出现在搜索里）。
2. 换关键词搜：`Refresh All Apps` / `AltStore` / `刷新`。
3. 仍搜不到就用**替代触发方式：把「打开 App」当作动作** ——
   - 操作搜索 **「打开 App」** → 选 **AltStore** → 后面加一个 **「等待」2 秒**；
   - 原理：AltStore 每次被切到前台都会自己发起一轮刷新（`AppManager` 在进入前台时触发 backgroundRefresh），效果等价，只是会让屏幕亮一下、AltStore 闪现 2 秒。
4. 再不行就用**半自动提醒**：做一条「提醒事项/闹钟」，到点提醒你手动打开 AltStore 点一次 **Refresh All**（点一下就能把 7 天重置，成本极低）。

**额外可选（很实用）**：再做一条自动化 —— 触发条件选 **「Wi-Fi」→ 连接到「你的家庭 Wi-Fi」时** → 动作同样是 `Refresh All`。这样你一进家门就自动续签一次，成功率比定时高（因为一定满足"同网段"这个硬条件）。

说明与限制（已核实到源码层面）：
- 动作本身是真实存在的 App Intent **`Refresh All Apps`**（iOS 17+，`RefreshAllAppsIntent.swift`），`openAppWhenRun` 未开启 → **可以由个人自动化在后台直接执行，不必打开 AltStore 界面**。
- 但它有 **约 27 秒的后台预算**：超过后会走 `requestToContinueInForeground()`，此时系统可能把 AltStore 拉到前台继续（屏幕亮起/切 App）。所以自动化「基本无感」，但不是绝对静默。
- 自动化触发时 **iPhone 要在同一 Wi-Fi**，且 iOS 对后台自动化有调度延迟（几分钟到几十分钟），所以它是兜底，不能替代 6.1。
- 建议设 **两个** 自动化（如 09:00 与 21:00），双保险；每周仍人工看一眼剩余天数。

### 6.4 兜底 2：Remote AltServer（想摆脱「Mac 必须常开」时）

AltStore Classic 2.3 起支持 Remote AltServer（App 内设置，借用社区服务器，不需要你自己电脑在线）：
1. iPhone **AltStore → Settings → Remote AltServer → Set up Remote AltServer...**。
2. 按引导 **「Pair with a PC」**：仍需 USB 连一次 Mac 做配对。
3. 按引导安装 **LocalDevVPN**（App Store 免费）→ 打开并 **Connect**（首次要允许 VPN 配置 + 输锁屏密码）。
4. 日常要求：**开着 LocalDevVPN + 连着 Wi-Fi（不能用蜂窝）**。

⚠️ **iOS 27 已知问题**：AltStore 仓库 issue **#1803「iOS 27 Remote server setup error」**（2026-09-15 提出，至今 open）。社区反馈里有人通过**卸载重装 AltStore** 绕过，也有人重装后仍报错。
因此：**它是备选，不要作为首选**；等官方修复或 iOS 27.x 更新后再考虑切换。

### 6.5 兜底 3：彻底失效时的人工恢复（每 5 分钟能搞定）

- **刷新（App 还没过期）**：连同一 Wi-Fi → 打开 AltStore → My Apps → Refresh All。
- **已经过期（App 打不开）**：**不要删除 App**。插上 USB → Mac 打开 AltServer → 菜单栏 **Install AltStore → 你的设备** 重装 AltStore，然后在 AltStore 里对目标 App 点刷新/重装；数据一般保留（覆盖安装不清数据）。
- **证书/描述文件被 Apple 撤销**（报 `provisioning profile is banned`）：AltStore 2.3.1+ 有实验功能 **Settings → Randomize Bundle IDs**（随机化 Bundle ID，规避被封的 profile）；仍不行就换一个 Apple ID（这就是建议用小号的原因）。

### 6.5.1 续签到底做了什么？会不会重装、会不会丢数据？

- **续签 = 重新签名 + 覆盖安装**：AltStore 用同一 Bundle ID 向 Apple 申请新的 7 天描述文件，然后覆盖装到原 App 上，**不删除 App 容器**（UserDefaults / Documents / Keychain 里的数据都保留）。
- **代价**：刷新那一瞬间 App 会被终止（若正在用），几秒到几十秒不可用，然后恢复正常。
- **和「停用（Deactivate）」区分**：停用才会备份数据并把 App 从设备移除（为了腾出 3 个名额），日常续签不要用停用。
- **例外 1：AltStore 自身过期**。它自己过期后既不能刷新自己、也不能刷新别人 → 只能 USB 连 Mac，用 AltServer 菜单 **Install AltStore…** 重装 AltStore；你已安装的其它 App 不会被删，数据也还在，但需要在 AltStore 里重新点一次刷新。
- **例外 2：描述文件被 Apple 封禁/撤销**（报 `provisioning profile is banned`）。需要吊销旧证书重新签发，可能触发一次实际重装，但 App 数据仍保留。
- **例外 3：换 Apple ID 重新签名**。签名 Team 变了，iOS 视为不同开发者 → 必须卸载重装，**数据会丢**（所以一开始就选定一个用于侧载的 Apple ID，别中途换）。

---

### 6.6 常见错误码速查

| 现象/错误 | 含义 | 处理 |
|---|---|---|
| `-80045` | Apple 认证/续签失败（2026-10 起 Apple 侧变更导致的大面积故障） | **升级到 AltStore Classic 2.3.1+（当前 2.3.3）**；退出 Apple ID 重新登录 |
| `415` | 签名/请求被拒（2026-11 修复） | **升级到 2.3.3** |
| `-22410` / `1100` | 登录或刷新失败（Windows 端常见） | 升级 AltServer/AltStore；重登 Apple ID |
| `Could not find AltServer` | 局域网发现失败 | 同网段、关 AP 隔离、放行防火墙、临时插 USB |
| `Unable to Verify App` | 证书未信任或已过期 | B5 重新信任；或刷新重签 |
| `provisioning profile is banned` | Apple 风控封了描述文件 | 开 Randomize Bundle IDs；换 Apple ID |

### 6.7 Mac 重启后自检（30 秒）

1. 菜单栏有 AltServer 图标？
2. iPhone 与 Mac 同网段？
3. AltStore 里点一次 Refresh All 能成功？
三项都 OK 就不用管了。

---

## 7. 第五部分：限制与风险（必须知道的硬约束）

| 限制 | 官方口径 | 对你的实际影响 |
|---|---|---|
| 每设备最多 3 个 App | Apple 官方免费账号限制 | **AltStore 自身占 1 个名额**，所以你还能装 **2 个**第三方 App；已装的 `Kline 1.0.2` 也占名额 |
| 描述文件 7 天过期 | Apple 官方 | 必须每周至少成功续签一次 |
| 10 个 App ID / 7 天 | Apple 官方 | 频繁重装不同 App 会撞额度 |
| 3 台设备 / 7 天 | Apple 官方 | 同一 Apple ID 别在多台设备间反复切换 |
| AltStore 自己也 7 天过期 | 官方 FAQ | 它过期时你无法用它刷新别的 App → 必须 USB + AltServer 重装（见 6.5） |
| 证书被撤销/账号被风控 | 社区高频问题 | 用小号、开 Randomize Bundle IDs、别频繁改签名 |
| 局域网隔离 | 官方 FAQ | 公共 Wi-Fi/AP 隔离会让无线续签必然失败 |
| iOS 大版本升级 | — | 历史上每次 iOS 大版本都会有 1–3 周适配期（如 iOS 26 的「Unable to Verify App」、iOS 27 的 Remote AltServer 报错）；**升级 iOS 前先确认 AltStore/AltServer 已更新** |
| 隐私 | 官方声明 | Apple ID 凭据只发往 Apple；但 AltStore 会把设备信息用于向 Apple 申请签名 |
| 合规 | — | 免费账号签名仅供个人设备自用，不得分发 |

---

## 8. 第六部分：备选方案对比（均为 2026-11-14 核查状态）

| 方案 | 日常是否要电脑常开 | 额外门槛 | 当前可用性 | 评价 |
|---|---|---|---|---|
| **① AltStore Classic 2.3.3 + AltServer 1.8（本方案首选）** | 要（你这台已常开） | 同一 Wi-Fi、USB 首装一次 | ✅ 官方维护，2.3.3 已修 -80045/415 | **最稳，坑最少** |
| ② AltStore + Remote AltServer（免电脑） | 不要 | LocalDevVPN 常开 + Wi-Fi（不能蜂窝） | ⚠️ iOS 27 上有 issue #1803 未修 | 等修复再切；适合 Mac 不能常开的人 |
| ③ SideStore（on-device 续签） | 首装要电脑，之后不要 | iloader 首装 + **LocalDevVPN 必须常开** + pairing file（升级/重置会失效需重配） | ⚠️ 依赖 pairing file 与 VPN，iOS 27 有扩展签名相关 issue（#1724） | 门槛比 AltStore 高，VPN 常驻耗电；但确实能脱离电脑 |
| ④ AltKeeper（自托管/Docker） | 要自托管宿主 | 自建 Anisette V3、Bonjour/host networking；作者自述 experimental | ⚠️ 2026-09-21 才创建、87 star，**未在真机端到端验证**；Docker 只推荐 Linux 宿主 | **不推荐**用于「求稳」；本机还没有 Docker 运行时 |
| ⑤ 付费 Apple Developer（$99/年） | 不要 | 花钱 | ✅ 描述文件 1 年有效，无 3 App 限制 | 想彻底不折腾就这个；但「免费」前提不成立 |
| ⑥ Sideloadly / Xcode 直接 Run | 每周要插线 | 每周手动 | ✅ | 只适合「偶尔用」 |

结论：**在「免费 + 不折腾」的目标下，① 是唯一同时满足「官方维护 + 坑最少 + 你这台机器已具备硬件条件」的组合**；②③ 是「不想让 Mac 常开」时的备选，但都有明确的额外门槛（VPN 常驻 / pairing file 失效 / iOS 27 已知 bug），④ 现阶段不建议。

---

## 9. 第七部分：日常运维清单

## 8.5 让 Kline 也自动续签（覆盖安装，数据保留）

**先搞清三件事**
1. **AltStore 不能"接管"它没装过的 App**。My Apps 里只显示 AltStore 自己安装并记录过的 App；Xcode 装进去的 Kline 不会出现在里面，Refresh All 也刷不到它。
2. **所以必须用 AltStore 再装一次同一个 .ipa（覆盖安装）**。
3. **会不会丢数据，只取决于签名 Team 是否相同**：
   - 同 Team + 同 Bundle ID 覆盖安装 → **数据保留**（这就是 Xcode 反复调试安装的行为，容器不重建）；
   - 跨 Team → application-identifier 变了，iOS 视为另一个开发者的 App，**必须先卸载重装，数据丢失**。

**确认 Team 一致（30 秒，必做）**
- iPhone：**设置 → 通用 → VPN 与设备管理 → 开发者 App**，看 Kline 与 AltStore 是否挂在**同一个 Apple ID** 下；同时点开 AltStore → 确认它和 Kline 显示同一个开发者。
- 若 Kline 挂在**另一个账号**下 → **停手**，先备份/导出数据再决定，否则覆盖安装会丢数据。

**.ipa 从哪来（两条路，任选）**
- **推荐：GitHub Release**（已验证可用）
  ```
  gh release download latest -R SunChuquin/Kline -p Kline.ipa -D ~/Downloads --clobber
  ```
  实测：`Kline.ipa` 9.0 MB，`CFBundleShortVersionString=1.0.2`、`CFBundleVersion=610`、`com.sunck.Kline`，签名是 **adhoc、无 embedded.mobileprovision、无 TeamIdentifier** —— 正是给 AltStore 重签用的裸包，正好。
- **要最新代码：本地打包**
  - Xcode → Product → Archive → Distribute App → **Development** → Export → 得到 `Kline.ipa`；
  - Team 已是 `4G3V8W86TN`（工程里写死），导出的包同样由 AltStore 重签。
- 注意：GitHub 的 `latest` 是 **CI Build #610（2026-09-16）**，内容比你本地最新代码旧；手机当前那份是 build `1`。用 CI 包覆盖后版本号仍是 1.0.2，但 build 变 610。

**安装步骤（手机上做，2 分钟）**
1. Mac 上 `AirDrop` 把 `Kline-1.0.2-build610.ipa` 投到 iPhone → 存到「文件」App（如"下载"）。
2. iPhone 打开 **AltStore → My Apps → 左上角/右上角 `+`** → 选那个 .ipa。
3. 首次会让你输入 Apple ID 密码（AltStore 需要拿它重签），然后开始安装。
4. 装完 **My Apps 里出现 Kline，显示 `7 DAYS`**。
5. 拔掉 USB，保持同一 Wi-Fi，点一次 **Refresh All** → 观察 Kline 与 AltStore 的天数是否一起回到 7。

**名额提醒（纠正一个常见误解）**
- 免费账号每设备 3 个 App，AltStore 自己占 1 个。
- 现在设备上是 AltStore + Kline = **2/3**；用 AltStore **覆盖安装同一个 Kline 不会新增名额**，装完仍是 2/3，**还剩 1 个空位**给别的 App（不是"正好装满 3 个"）。

**验证清单**
- [ ] My Apps 里出现 Kline，且显示天数而不是报错；
- [ ] Refresh All 后 Kline 天数回到 7；
- [ ] 明天早上再看仍是 7（说明定时自动化把 Kline 一起带上了）。

**每周（其实只需 30 秒抽查）**
- 打开 AltStore → My Apps，看剩余天数是否 ≥ 5；否则点 Refresh All。
- 看菜单栏 AltServer 图标是否还在（Mac 重启后尤其要确认）。

**每月**
- AltStore → My Apps 检查是否有版本更新（AltStore 自身也要更新，才能拿到 -80045/415 这类修复）。
- Mac 上确认 **系统设置 → 通用 → 登录项与扩展** 里 AltServer 仍在且未被系统禁用。

**iPhone 系统升级前**
- 先更新 AltStore 到最新，再升级 iOS；升级后第一时间做一次「拔线 + Wi-Fi 刷新」验证。

**换 Apple ID / 换机 / 重置手机时**
- 需要重新走 B2–B5（USB + AltServer 安装 + 信任 + 开发者模式）。

---

## 10. 构建 → 出包 → 装机的两条流水线（2026-11-14 实测）

脚本（新增，未提交）：
- `scripts/kline_build_install_dev.sh` —— 流水线 A：构建 + 直装（全自动）
- `scripts/kline_export_ipa.sh` —— 流水线 B：构建 + 导出 ipa（末尾一次人工装 AltStore）

### 10.1 实测数据

| 环节 | 命令 | 耗时 | 结果 |
|---|---|---|---|
| 构建 | `xcodebuild -scheme Kline -configuration Debug -destination 'id=<UDID>' -derivedDataPath /tmp/kline_cli_dd build` | **44.78s**（全新 DerivedData） | 成功（仅有既存 warning） |
| 直装 | `xcrun devicectl device install app --device <UDID> <Kline.app>` | **20.19s** | `App installed`，bundle 容器路径 UUID 变化（说明真的覆盖了） |
| 导出 ipa | `xcodebuild archive` + `-exportArchive -exportOptionsPlist …` | ~1–2 min | `build/ipa/Kline-1.0.2-1.ipa`（33 MB，development 签名） |

### 10.2 流水线 A：全自动（推荐日常迭代用）

```bash
bash scripts/kline_build_install_dev.sh            # 自动挑第一台已连接真机
UDID=00008030-001158362EA0402E CONFIG=Release bash scripts/kline_build_install_dev.sh
LAUNCH=0 bash scripts/kline_build_install_dev.sh   # 只装不启动
```

**边界（必须知道）**：`devicectl` 装出来的是**开发签名** App —— 不进 AltStore 的 My Apps、不被 Refresh All 续签；免费账号 **7 天后失效，重跑脚本即可**（数据保留）。

### 10.3 流水线 B：由 AltStore 托管自动续签（推荐长期挂着用）

```bash
bash scripts/kline_export_ipa.sh                   # 产出 build/ipa/Kline-<ver>-<build>.ipa
```
然后**人工一次**：AirDrop ipa 到 iPhone → AltStore → My Apps → `+` → 选 ipa → 装完后它才进入 Refresh All 的续签范围。

**为什么 B 的最后一步不能自动化（实测结论，不是推测）**：
1. AltStore / AltServer **都没有 CLI**（AltServer.app 里只有 GUI 可执行文件）。
2. AltServer 的 `Info.plist` **没有 `CFBundleURLTypes`** → 无 URL scheme，无法用 `open altserver://…` 触发安装。
3. AltStore **不会"收养"外部安装的 App**：My Apps 只列它自己写入记录的那些，Xcode/devicectl 装的同一 Bundle ID App 不会自动出现。
4. 唯一剩下的自动化路径是 **menu bar UI scripting**，但本机实测**不稳定**：一次 `osascript` 点菜单成功、另一次直接报 `-25211 osascript 不允许辅助访问`。把它当生产流程会随时断。

### 10.4 选哪个

- 天天改代码、当天要看到效果 → **A**（一条命令，~65s 装好并启动）。
- 想让 App 长期留在手机上不被 7 天掐死 → **B**（每次发版导 ipa、手机上装一次，之后全自动续签）。
- A 和 B 可以共存：用 A 迭代，发稳定版时用 B 覆盖一次，AltStore 里记录的仍是同一个 Bundle ID。

## 11. 用 Kline 内置局域网服务把 ipa 推上手机（实测，推荐）

> 比「Mac 起 HTTP 服务 + Safari 下载」更省事：ipa 直接落进 Kline 的沙盒 Documents，
> 而 Kline 开了 `UIFileSharingEnabled`，所以「文件」App 里能直接选到，不用下载、不用 AirDrop。

### 11.1 设备端实现（以代码为准）

| 项 | 事实 | 出处 |
|---|---|---|
| 端口 | 默认 **5051**，可用启动环境变量 `KLINE_HTTP_PORT` 覆盖 | `KlineHTTPServer.swift:29-37` |
| 写路由 | `PUT /sandbox/<相对路径>` → 写入 App 沙盒 **Documents**（先写 `.part`，收完 rename） | `:297-314` |
| 路径穿越防护 | `resolveSandboxPath` 强制结果落在 Documents 内 | `:558-566` |
| 鉴权 | 沙盒写门禁 = 回环 / 已「暴露」/ `X-Kline-Client: pipeline` **三者之一**；**不需要配对 token** | `:753-762` |
| 大小限制 | 服务端**没有** body 上限（实测 34.3 MB / 2.27s 通过） | 实测 |
| 403 语义 | 未暴露且没带 pipeline 头 → `{"error":"not exposed"}` | `:758-761` |
| 取消暴露 | 只挡局域网访问，不影响 USB/回环（`isLoopbackConnection`） | `:730-741` |
| 「文件」可见性 | 工程 `Info.plist` 有 `UIFileSharingEnabled`，且 build setting `LSSupportsOpeningDocumentsInPlace = YES` | 仓库 `Info.plist:6`、`project.pbxproj:495/542` |

### 11.2 实测记录（2026-11-14）

```
# 设备地址：扫本网段 5051（Mac 上同时跑着模拟器实例，也在 5051，必须排除本机 IP）
$ nc -z -G 1 192.168.2.9 5051 && curl -s -H 'X-Kline-Client: pipeline' http://192.168.2.9:5051/sandbox/
[{"dir":false,"name":"py_stderr.log",...},{"name":"Market","dir":true,...}]

# 推送 33 MB ipa
$ curl -X PUT --data-binary @Kline-latest.ipa -H 'X-Kline-Client: pipeline' \
    http://192.168.2.9:5051/sandbox/Kline-latest.ipa
{"ok":true}        # HTTP 200，size_up=34338963，real 2.27s

# 回读校验
$ curl -s -H 'X-Kline-Client: pipeline' http://192.168.2.9:5051/sandbox/
... "Kline-latest.ipa" 32.7MB  ← 与本地字节数一致
```

### 11.3 脚本

```bash
bash scripts/kline_push_ipa_lan.sh                # 自动发现设备 → 推送 build/ipa 里最新 ipa → 校验大小
bash scripts/kline_push_ipa_lan.sh discover       # 只找设备地址
HOST=192.168.2.9 IPA_SRC=~/Downloads/Kline.ipa bash scripts/kline_push_ipa_lan.sh
```

自动发现顺序：① Bonjour `_klinesync._tcp`（只在 App 内打开「暴露」时广播）→ ② 扫本网段 5051 并用 `/sandbox/` 探活，**排除本机所有 IP**（避免连到 Mac 上的模拟器）。若扫到多台会报错并要求 `HOST=` 指定。

接进现有流水线（**默认行为不变**）：

```bash
bash scripts/kline_build_install_dev.sh --with-ipa   # 构建+直装+导出+推送到手机沙盒
```

### 11.4 手机端手动安装（点哪个按钮）

1. **文件** App → 底部「浏览」→「我的 iPhone」→ **Kline** → 看到 `Kline-latest.ipa`。
2. **AltStore** → 底部 **My Apps** → 左上角 **＋** → 「选择文件」→ 浏览到上面的位置 → 选中 ipa。
3. 首次会让你**输入 Apple ID 密码**（重签用），输完等待安装完成。
4. 装完回到 **My Apps**，能看到 **Kline** 和右侧 **N DAYS** —— 到这一步 Kline 才进入 Refresh All 的续签范围。

### 11.5 副作用与自锁风险（如实说）

- **覆盖安装 Kline 不会丢沙盒里的 ipa**：同 Team + 同 Bundle ID，数据容器保留（前提：一直用同一个 Apple ID 签名）。
- **会短暂失效**：AltStore 装 Kline 时旧进程被杀，内置 HTTP 服务随之停止 → 此时再推送会失败，脚本会回退 USB 并打印原因；重开 Kline 即可恢复。
- **真正会丢的情况**：① 卸载 Kline（容器删除）② 换 Apple ID 签名（跨 Team，必须卸载重装）。
- 每次推的是**同文件名** `Kline-latest.ipa`，覆盖旧的，不会越堆越多。

## 12. 双包共存：正式版归 AltStore，日常直装用 Kline-dbg（实测通过）

### 12.1 实测结论

```
$ xcodebuild -project Kline.xcodeproj -scheme Kline -configuration Debug \
    -destination 'id=<UDID>' -derivedDataPath build/cli-dbg -allowProvisioningUpdates -quiet \
    PRODUCT_BUNDLE_IDENTIFIER=com.sunck.Kline.dbg \
    INFOPLIST_KEY_CFBundleDisplayName=Kline-dbg build
real 52.37            # 首次要联网建 App ID + 描述文件；之后增量十几秒

$ /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleDisplayName" Kline.app/Info.plist
com.sunck.Kline.dbg
Kline-dbg

$ xcrun devicectl device info apps | grep -i kline
Kline      1.0.2  1
Kline-dbg  1.0.2  1        ← 两个 App 并存，桌面出现两个图标
```

**关键前提**：换新 Bundle ID 必须带 **`-allowProvisioningUpdates`**，否则报
`No profiles for 'com.sunck.Kline.dbg' were found … Automatic signing is disabled`（第一次实测就是这么失败的）。

**容器独立已确认**：`com.sunck.Kline.dbg` 的 Documents 是全新的（只有 `Favorites/favorites.json`），
与正式包容器（含 `Market`、`Simulation`、`Kline-latest.ipa`）互不相通。

### 12.2 跟着 Bundle ID 走的东西（逐项核对结果）

| 项目 | 工程里的实际情况 | 是否需额外处理 |
|---|---|---|
| entitlements | `Kline.entitlements` 里是 TrollStore 用的私有 entitlement（no-sandbox / platform-application / AppDataContainers / persona-mgmt），**但 pbxproj 里没有 `CODE_SIGN_ENTITLEMENTS`，构建时根本没引用** | 不用管 |
| App Group | 无 | 无 |
| Keychain access group | 无（代码里搜不到 `kSecAttrAccessGroup`） | 无 |
| URL scheme | `Info.plist` 无 `CFBundleURLTypes` | 无冲突 |
| UserDefaults suite | 无 `suiteName:` | 无 |
| 推送 / 后台模式 | 未使用 | 无 |
| Info.plist 占位 | 用 `GENERATE_INFOPLIST_FILE=YES` + `INFOPLIST_FILE=Info.plist`，所以 `INFOPLIST_KEY_*` 能覆盖进去（实测 `CFBundleDisplayName` 生效） | 无需改源码 |
| 代码里用 bundleIdentifier 的地方 | `KlineHTTPServer.swift:1154`（日志）、`UITestStateReset.swift:44`（UI 测试重置） | 纯信息用途，不影响运行 |

### 12.3 用法

```bash
bash scripts/kline_build_install_dev.sh --variant dbg     # 构建 + 安装为 Kline-dbg
BUNDLE_ID=com.sunck.Kline.qa DISPLAY_NAME=Kline-qa bash scripts/kline_build_install_dev.sh   # 自定义身份
```
默认（不加参数）行为完全不变，仍是 `com.sunck.Kline`。

### 12.4 代价与坑（必须知道）

1. **名额 3/3 满了**：免费账号每设备最多 3 个 App —— AltStore 自己 + 正式 Kline + Kline-dbg。再想装第四个必须删一个。
2. **数据不互通**：两份容器独立，自选股/配置等互不影响（这既是好处也是坑：调试期改的东西不会带到正式包）。
3. **两份都会 7 天过期**：AltStore 那份靠续签，Kline-dbg 靠重跑脚本。
4. **内置 HTTP 服务端口冲突**：两个包都监听 5051，同一时刻只有前台那个能绑定成功（代码里有 bind 重试）。**后果**：`kline_push_ipa_lan.sh` 只按端口发现，会命中当前在前台的那个实例 —— 如果当时前台是 Kline-dbg，ipa 就被推进 dbg 的容器，AltStore 里选不到。**推送前先把正式版 Kline 切到前台（并退出 Kline-dbg）**。
5. 变体模式下 `--with-ipa` 会被跳过并提示，避免把 dbg 身份的包装给 AltStore。

## 附录 A：事实核查记录（2026-11-14）

**核实通过的版本与限制**
- AltStore Classic 最新 **2.3.3（build 87，2026-11-09，修复 415 错误）**；2.3.1（2026-10-21）修复 `-80045`、后台刷新失效、2FA 不弹窗，并新增 Randomize Bundle IDs。
  来源：AltStore 官方源/新闻（altshelf 镜像显示 2.3.3 与 2.3.1 条目）、<https://faq.altstore.io/release-notes/altstore>、<https://github.com/altstoreio/AltStore/releases>（公开 tag 仍为 v2.3，2.3.1+ 走 App 内更新）。
- **AltServer macOS 最新 1.8（build 97）**，最低 macOS 11.0 —— 实测下载官方 zip 读取 `Info.plist` 得到：`CFBundleShortVersionString=1.8`、`CFBundleVersion=97`、`LSMinimumSystemVersion=11.0`。
- 免费账号限制（Apple 官方）：最多注册 10 个 App ID/7 天、3 台设备/7 天、**每设备最多 3 个 App**、描述文件 7 天后过期。
  来源：<https://developer.apple.com/help/account/basics/about-your-developer-account>
- 开发者模式路径：**设置 → 隐私与安全性 → 开发者模式**（Security 区域，需重启）。
  来源：<https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device>
- iOS 27 已知问题：<https://github.com/altstoreio/AltStore/issues/1803>（Remote server setup error，2026-09-15，open）；<https://github.com/altstoreio/AltStore/issues/1751>（iOS 27 machineID）。
- SideStore 门槛：需 iOS 15+ 且**有锁屏密码**、电脑仅首装、**必须开 LocalDevVPN**、配对文件在系统升级/重置后会失效；来源 <https://docs.sidestore.io/docs/installation/prerequisites> 与 <https://docs.sidestore.io/docs/installation/install>。
- Remote AltServer 要求 LocalDevVPN + Wi-Fi（非蜂窝）；来源 <https://faq.altstore.io/altstore-classic/remote-altservers>。

**被证伪 / 需修正的说法**
1. ❌「AltServer macOS 1.8.2」——官方渠道查不到该版本，最新为 **1.8**。
2. ⚠️「AltKeeper 用 Docker 跑」——项目**真实存在**（GitHub `BartolomeoRusso9/altkeeper`，Rust，87 star，创建于 2026-09-21），但 README 自述 **"Experimental software"**、「JIT 与部分安装流程未在真机端到端验证」，且 **Docker 仅面向 Linux 宿主**（需 host networking + Bonjour）。此外你这台 Mac 上**没有 Docker 运行时**（只有 CLI），所以「Docker 常驻续签」当前不成立。
3. ⚠️「免费账号可以装 3 个自签 App」——准确说是「**每设备最多 3 个**，且 AltStore 自身占 1 个」，实际你可用的第三方 App 只有 2 个；已有的 `Kline 1.0.2` 也算在内。
4. ⚠️「装了 AltStore 就完全不用管」——只在「Mac 常开 + 同网段 + 未开 AP 隔离 + AltStore 自身未过期」四条同时成立时成立；否则需要第 6 章的兜底。

**本次实测进度（2026-11-14，Mac 端已就绪，停在等待 Apple ID）**
- AltServer **1.8（build 97）** 已装入 `/Applications`；签名 `Developer ID Application: Yvette Testut (6XVY5G3U44)`，`Notarization Ticket=stapled`，`spctl -a` 结果 `accepted / Notarized Developer ID`；无 `com.apple.quarantine`（curl 下载，不触发 Gatekeeper 拦截）。
- 运行态：PID 69130，`lsappinfo` 显示 `type="UIElement"`（纯菜单栏常驻）；菜单项实测为 `Install AltStore… / Sideload .ipa… / Enable JIT / Launch at Login / Check for Updates… / Quit`。
- 登录项：已写入（`osascript` 枚举可见 AltServer）；AltServer 菜单内 `Launch at Login` 保持未勾选，避免同一 App 注册两次。
- 网络：AltServer 监听 `TCP *:50877`；Bonjour 已广播 `_altserver._tcp.local`，实例名「孙楚昆的Mac mini」。
- 防火墙：已启用，但「自动允许下载的已签名软件」= ENABLED → AltServer 无需手动加白名单。
- 截图：`screencapture` 报 `could not create image from display`（终端没有屏幕录制权限），故改用进程/端口/菜单枚举代替截图。
- **安装结果（已远程确认）**：iPhone 上已出现 **AltStore 2.3.3（bundle version 75）**，Bundle ID `com.4G3V8W86TN.com.rileytestut.AltStore`；`xcrun devicectl device process launch` 成功拉起 → 说明**开发者模式已开、开发者证书已被信任**（未信任的 App 无法被拉起）。
- **名额占用**：当前 2/3 —— `AltStore 2.3.3` + `Kline 1.0.2`（com.sunck.Kline），**只剩 1 个空位**。

**仍需用户手动点（命令无法可靠代做）**
- Finder「在 Wi-Fi 上显示此 iPhone」：这是 Finder 设备页的勾选框，无可信 CLI/defaults 键（`com.apple.iPod.plist` 里没有任何设备条目，说明从未开启过）。
- 本地网络授权：TCC 数据库无完全磁盘访问权限读不到；首次连接若弹「AltServer 想要查找并连接到本地网络上的设备」，选**允许**；否则去 **系统设置 → 隐私与安全性 → 本地网络** 手动打开。

**A/B 两问的证据链**
- **后台刷新没有固定提前窗口**：官方只写「will attempt to refresh … in the background」；代码里唯一确定的时间点是到期前 **24 小时**的本地通知（`AppManager.swift`：`expirationDate.addingTimeInterval(-24 * 60 * 60)`）。后台任务由 iOS 机会式调度，不保证在到期前几天执行。
- **手动 Refresh All 会重置 7 天**：Apple 规定描述文件「自签发起 7 天过期」，成功刷新即签发新描述文件，计时从刷新那一刻重新开始。
- **快捷指令动作真实存在且可后台跑**：`AltStore/Intents/App Intents/RefreshAllAppsIntent.swift` 中 `struct RefreshAllAppsIntent: AppIntent, …, ForegroundContinuableIntent`，未设置 `openAppWhenRun`；内部 27 秒 deadline，超时调用 `requestToContinueInForeground()`（可能短暂转前台）。

**本机排查命令（只读，可复现）**
```bash
sw_vers; xcodebuild -version; xcode-select -p
xcrun devicectl list devices
xcrun devicectl device info details --device 7B3DAD25-E37B-570D-BADD-64676D1EF2CB
xcrun devicectl device info apps    --device 7B3DAD25-E37B-570D-BADD-64676D1EF2CB
pmset -g custom; fdesetup status
osascript -e 'tell application "System Events" to get the name of every login item'
networksetup -getinfo Wi-Fi
```

---

## 附录 B：必须你本人完成的步骤（工具/代理不要代做）

1. **B3-1**：在 AltServer 弹窗输入 **Apple ID 邮箱与密码**（可考虑用专门注册的小号）。
2. **B3-2**：输入 iPhone 上弹出的 **双重认证 6 位验证码**。
3. **B5**：在 iPhone 上点 **信任** 你的 Apple ID 证书。
4. **A5**：若开自动登录，需输入一次 **Mac 开机密码**。
5. **A2**：首次打开 AltServer 时，右键「打开」确认 Gatekeeper 提示。
6. 若系统弹「AltServer 想要接收传入网络连接」→ 点 **允许**。
7. 若弹「AltServer 想要发送通知」→ 点 **允许**（否则你看不到续签结果）。
