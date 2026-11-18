# AltStore 自动核查清单（2026-11-14，只读核查）

> 核查方式：`pgrep` / `lsof` / `dns-sd` / `devicectl`（apps、lockState、processes、process launch、files、copy from）/ macOS `log show` / 钥匙串查询。
> 未安装任何第三方工具，未改动设备内容（只做了 launch 尝试与只读拷贝偏好文件）。

## 一、已验证通过（有证据）

| # | 项目 | 证据 |
|---|---|---|
| 1 | AltServer 进程存活 | `pgrep` → `72917 /Applications/AltServer.app/Contents/MacOS/AltServer` |
| 2 | 登录项存在 | System Events 枚举：贝锐向日葵、Snipaste、BetterDisplay、网易有道翻译、**AltServer** |
| 3 | 监听端口 | `lsof -a -c AltServer -iTCP -sTCP:LISTEN` → `TCP *:50878 (LISTEN)`（**端口每次启动会变**，上一轮是 50877，不要写死） |
| 4 | Bonjour 广播 | `dns-sd -B _altserver._tcp local` → `Add ... _altserver._tcp. 孙楚昆的Mac mini` |
| 5 | AltStore 已安装 | `devicectl device info apps` → `AltStore  com.4G3V8W86TN.com.rileytestut.AltStore  2.3.3  75` |
| 6 | AltStore 曾成功首启 | 从设备拷出的 `Library/Preferences/...plist` → `firstLaunch = 2026-11-14 02:00:22 +0000`（即本地 10:00:22） |
| 7 | Mac 侧曾成功完成 Apple ID 认证并拿到签名证书 | `~/Library/Application Support/com.rileytestut.AltServer/Certificates/4G3V8W86TN.p12`，创建于 `2026-11-14 09:58:45`（只看文件属性，未读取内容） |
| 8 | 设备当前可调试、已解锁 | `devicectl device info lockState` → `passcodeRequired=false`、`unlockedSinceBoot=true` |

## 二、发现问题（附证据与下一步）

### P1　AltStore 现在无法启动：签名档案未被信任

证据（2026-11-14 10:52 与 10:53 两次复现一致）：
```
ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002)
  FBSOpenApplicationServiceErrorDomain error 1, RequestDenied
  NSLocalizedFailureReason = Unable to launch com.4G3V8W86TN.com.rileytestut.AltStore
    because it has an invalid code signature, inadequate entitlements
    or its profile has not been explicitly trusted by the user
```
含义：不是"过期"（过期会报 Unable to Verify / profile expired），而是**信任状态不成立**。用户在手机上点 AltStore 很可能也会看到「未受信任的开发者」提示。

### P1-b　同一 Team 下存在 2 张 Apple Development 证书

证据：钥匙串里 `Apple Development: <该 Apple ID>` 有两条不同 SHA-1（`3DC07ACD…` 与 `C7975643…`）。
含义：**很可能发生过一次重签/换证书**（AltStore 在证书额度用尽时会吊销旧证书重建）。iOS 的"信任"是挂在证书上的，换证书后原信任失效 → 与 P1 现象吻合。
（远程无法 100% 区分"换证书导致信任失效"与"用户没点信任"，但修法相同。）

**下一步（需用户操作）**
1. iPhone：**设置 → 通用 → VPN 与设备管理 → 开发者 App → 选中该 Apple ID → 信任「…」→ 允许**。
2. 若该列表里**没有**这个 Apple ID 条目 → 说明档案已被替换/移除：USB 连 Mac，AltServer 菜单 `Install AltStore…` 重装，装完立刻做第 1 步。
3. 完成后告诉我，我重跑一次 `devicectl device process launch` 复验；能拉起才算真修好。

## 三、无法远程验证（不要当成已通过）

| 项目 | 为什么读不到 | 替代自检 |
|---|---|---|
| 描述文件到期时间 / 剩余天数 | `devicectl` 没有读取 installed provisioning profiles 的子命令；本机未装 libimobiledevice（`ideviceprovision`），按要求不擅自安装 | 看 AltStore → My Apps 里的 `N DAYS` |
| AltStore 内是否已登录同一 Apple ID | 账号态在 Keychain / Core Data；app 容器里没有可读的数据库（`Library/Application Support` 为空，app group 容器 devicectl 无法列举） | AltStore → Settings → Account 是否显示免费账号、非 `Sign in` |
| 后台刷新是否真的跑过 | AltServer **不写 unified log**（`log show --last 6h --predicate 'process == "AltServer"'` 返回空）；设备侧无刷新日志 | 见下方触发验证 |
| 两条快捷指令自动化是否存在、是否关闭"运行前询问" | iOS 不允许外部读取快捷指令库/自动化列表 | 打开快捷指令 → 自动化，逐条点开看「立即运行」 |
| 设置 → 通用 → 后台 App 刷新 → AltStore 开关 | 无公开 API 可读 | 手动看一眼 |

**间接线索（不等于证明）**：`Library/Caches/.../Cache.db-wal` 与 `Library/Caches/io.altstore.Nuke/*` 的写入时间为 `10:51`，说明 AltStore 在 10:51 仍在前台活动过；但这不能证明发生过"续签"。

## 四、触发验证（一次性证明链路通不通）

1. 先修好 P1 的信任问题（否则一切免谈）。
2. 手机与 Mac 同一 Wi-Fi、AltServer 在跑。
3. 打开 AltStore → My Apps，记录当前 `N DAYS`。
4. 点 **Refresh All**（或等 09:00 / 21:00 的自动化跑一次）。
5. 再看 `N DAYS`：若回到 7 → 链路成立；若报错，把错误码（`-80045` / `415` / `banned` / `unsigned`）发我。
6. 想验证"自动化确实在跑"：把手机放家里 Wi-Fi 上，第二天早上直接看 My Apps 天数是否仍是 7（或截图 AltStore 的 Apps 页面给我）。

## 五、结论

Mac 侧四项（进程/登录项/端口/Bonjour）全部正常；**唯一硬故障是 iPhone 端的签名信任失效**，必须先修它，否则自动化即使跑起来也会失败。

## 六、复验记录（2026-11-14 10:55，P1 已修复）

用户手动信任后复跑同一命令：
```
$ xcrun devicectl device process launch --device 00008030-001158362EA0402E \
    com.4G3V8W86TN.com.rileytestut.AltStore
Launched application with com.4G3V8W86TN.com.rileytestut.AltStore bundle identifier.

$ xcrun devicectl device info processes --device 00008030-001158362EA0402E | grep AltStore
42712  /private/var/containers/Bundle/Application/40DE6743-.../AltStore.app/AltStore
```
→ **P1 已解除**：证书信任生效，AltStore 正常启动并驻留（设备内 PID 42712）。
同步复核 Mac 侧：AltServer PID 72917 存活；监听 `TCP *:50878`；Bonjour `_altserver._tcp.local`「孙楚昆的Mac mini」仍在广播。

**状态：可进入真实刷新验证（My Apps → N DAYS）。**
