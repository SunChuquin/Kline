# Kline P2-6c-1：LANSync / LocalUpdate / Debug 实验室 Web 化计划

> 日期：2026-11-19
> 批次：P2-6c 第一个子批（简单表单页三件套）；后续 P2-6c-2 Backtest、P2-6c-3 Training
> 用户拍板：LocalUpdateView 从个人中心内嵌卡片组**提取为全屏页**（入口行样式，与联机同步一致）

---

## 1. Context

「全页面 Vant 化」P2-6 功能页批次开始。本批迁移三个简单表单页到 Vue3+Vant：

| 页面 | 现状 | 入口 | 迁移要点 |
| --- | --- | --- | --- |
| LANSyncView（联机同步） | HomeWebShellView overlay 原生挂载（`overlayTarget = .lanSync`） | 首页入口宫格 + 个人中心入口行 | 三态页（devices/configure/running）状态机；传输进度实时推；关闭时取消暴露/吊销 token；busy 禁止关闭 |
| LocalUpdateView（本地更新） | **内嵌在 ProfileDetailView** 滚动查看 | 个人中心内嵌卡片组 | 提取为全屏 Web 页；App 行/引擎行远程更新状态机 + 清单自动更新 + 补缺口 + 基准缺失弹层 |
| PythonEngineLabView（Debug 实验室） | HomeWebShellView overlay 原生挂载（`overlayTarget = .pythonLab`） | 首页入口宫格 + 个人中心入口行 | 引擎状态 + 9 个操作行 + 实验①-④（脚本/编排逻辑原样迁入桥）+ 输出控制台 |

原生三个 View 类**保留不删**（回退 = 改回一行分支）。状态/引擎全部留原生（LANSyncTransfer / GitHubUpdateService / PythonEngineHost / WatchlistSyncManager / GapBackfill），Web 只发动作与消费快照（协议 v2 写回模式）。

## 2. 新技术点：全屏 Web 页容器（WebPageBridge + WebFullscreenPageHost）

模式对齐 SheetWebOverlayHost（Kline/WebBridge/SheetBridge.swift:490），三点差异：

1. **不透明**：`WebTabHostView(route: "page", isOpaque: true)`（弹层浮层是透明遮罩+面板，全屏页是整页白底）。
2. **懒创建 + 关闭即销毁**：首次 open 创建 WebView，close 时置 `webCreated = false` 整体销毁（对齐原生页生命周期，省 2GB 设备内存；弹层是常驻复用，因为打开频率高）。每次打开走 `page.ready` 就绪拉取补推（SheetBridge.handle "ready" 同款时序坑修复）。
3. **挂载点在 HomeWebShellView overlay**（zIndex 1002，盖过原生 overlay 组 1000 与个人中心）——保持原生 UX：底部 Tab 栏不被盖住。ProfileDetailView（内嵌个人中心）在此 overlay 内打开 Web 页也能正确覆盖。

新文件 `Kline/WebBridge/WebPageBridge.swift`：

```
@MainActor final class WebPageBridge: ObservableObject {
    static let shared = WebPageBridge()
    @Published private(set) var activePage: String?   // "lanSync" | "localUpdate" | "pythonLab"
    func open(_ name: String)          // activePage = name + pushEvent("page.open", {name}, route:"page")
    func close(force: Bool = false)    // busy 钩子拒绝（lanSync 传输中）→ 各页 onCloseHook
    var closeHooks: [String: () -> Bool]   // 每页关闭钩子（返回 false = 拒绝关闭）
    static func handle(_ request)      // page.close / page.ready（ready 补推 page.open）
}
struct WebFullscreenPageHost: View { ... }   // 懒创建+opacity+销毁
```

## 3. 协议登记（module: page / lan / update / lab）

protocol.ts 注释清单 + KnownActions/KnownEvents + 接口；fixtures `bridge_protocol.json` requests/responses/events 直接进正式区块（本批即实装）；WebBridgeProtocolTests 扩展。

### page 模块
- `page.close {} → {}` Web 请求关闭全屏页（busy 时 fail）
- `page.ready {} → {}` WebView 就绪拉取（补推 page.open）
- 事件 `page.open {name}`（Swift→Web，route:"page" 定向）

### lan 模块（LANSyncBridge.swift）
- `lan.snapshot {} → LANSSnapshot`：
  `serverOnline/probing/port/deviceName/isExposed/isBrowsing/peers[{id,name,host,port}]/connecting`
  `busy`（transfer pairing/transferring）
  `transfer{phase: idle|pairing|transferring|done|failed, progress, bytesPerSecond, currentFile, resultSummary, backupDir, needsRestart, failMessage}`
  `configure: null | {peer{name,host,port,appVersion}, categories[{key,title,localSummary,remoteSummary,children[{key,name,quantity}], hasChildren}]}`（summary/quantity/字节/时间文案**原生格式化**）
- 动作：`probe`（服务探测）/ `setExposed {on}` / `scan`（扫描一次）/ `connect {peerId? | address?}`（成功进 configure；失败 fail 返回中文文案：不能连接本机/对端已取消暴露/对端不可同步/无法连接）/ `start {selections:[{category, mode: "all"|"children", childKeys?}]}`
- 事件 `lan.changed {reason}`：discovery/pairing/transfer objectWillChange 节流 0.3s 合并推送；`reason: "mainDBReplaced"`（.lansyncMainDBReplaced 通知→Web 弹重启提示）
- **Web 本地态**（不进桥）：子页切换（devices/configure/running）、各类勾选粒度（none/all/子项集合）、展开集合、手动地址输入
- 生命周期：open → `KlineHTTPServer.start()` + probe；close → busy 拒绝；否则 `unpublish() + isExposed=false + revokeAllTokens()`（对齐原生 onDisappear）

### update 模块（LocalUpdateBridge.swift）
- `update.snapshot {} → UpdateSnapshot`：
  `server{ok, probing}`
  `app{state: idle|checking|latest|outdated|downloading|failed, remoteBuild, currentBuild, percent, title}`（title 原生拼「检查新版（最新#N 当前 #M）」）
  `engine{同构，title=更新引擎行}`
  `watchlist{enabled, isRunning, stateText, stateTone: gray|yellow|green|red, lastResultText, unionCount, requestText, lastTradeDate, slots[{time,title,value}], note}`
  `gap{statusText, coverageText, baselineText, baselineStale, fetchText, verdictText, isRunning, detailLines[]}`
  `baseline{mainLatest, items[{name,code,file,cause}]} | null`（queryBaselineMissing 结果）
- 动作：`probeServer` / `reconnectServer`（restart + 1.5s 后复探）/ `checkApp` / `installApp`（归档 IPA + 下载 + TrollStore 链路）/ `checkEngine` / `installEngine` / `syncNow`（watchlistSync.sync(reason:"手动")）/ `runGapBackfill` / `queryBaselineMissing`（异步→结果进快照，推 reason:"baselineReady"）
- 事件 `update.changed {reason: server|remote|engine|watchlist|gap|baselineReady}`
- 订阅：watchlistSync / gapBackfill / syncConfig objectWillChange + dbManager.$isLoaded（节流 0.5s）+ UIApplication.didBecomeActiveNotification（对齐 scenePhase 回前台重探测）；下载进度回调节流 0.3s 推送
- onOpen 语义对齐原生 onAppear：探测服务 + idle/failed/latest 态自动检查一次

### lab 模块（EngineLabBridge.swift）
- `lab.snapshot {} → LabSnapshot`：
  `status: notInstalled|installed|versionMismatch|corrupted`（+ `apiVersion`/`reason`）, `statusText`（原生文案）, `source`, `appPath`, `manifest`, `isLoaded`, `isBusy`, `busyText`, `downloadPercent`, `runningExp`, `outputLines[]`
- 动作：`refresh`（响应直接带快照）/ `download` / `install` / `loadEngine` / `runExp {id: 1..4}` / `cleanDownloads` / `exportCrash`
- 事件 `lab.changed {reason: status|output|progress}`：host.objectWillChange 节流 0.2s
- 实验①-④的脚本常量与编排（exp1Script/exp2Body/makeBarLiteral/exp3Script/exp4 的 ensureReady+稳态 20 次+内存足迹）从视图**原样迁入桥**（含 physFootprintMB/makePerfBars 辅助）

路由注册：`WebMessageRouter.dispatch` 增加 `page/lan/update/lab` 四个 case。

## 4. 呈现链接入（原生分支保留可回退）

1. `HomeBridge.openEntry`：`.lanSync` → `WebPageBridge.shared.open("lanSync")`；`.pythonLab` → `open("pythonLab")`（原 overlayTarget 两行保留为回退注释级说明）。
2. `ProfileDetailView`：
   - 联机同步入口行 → `WebPageBridge.shared.open("lanSync")`（showLANSync 原生分支保留）
   - Python 实验室入口行 → `open("pythonLab")`
   - **内嵌 `LocalUpdateView()`（L131-132）替换为入口行**（样式对齐联机同步行，identifier `profile.localUpdate.entry`）→ `open("localUpdate")`
3. `HomeWebShellView` overlay 尾部加 `WebFullscreenPageHost()`（zIndex 1002）。
4. 原生 LANSyncView/LocalUpdateView/PythonEngineLabView 类与 overlay 分支全部保留（P2-7 才清除）。

## 5. Web 端

- `web/src/router/index.ts`：加 `{ path: '/page', component: WebPage }`
- `web/src/pages/WebPage.vue`（壳）：监听 `page.open`/发 `page.ready`（mounted 时，对齐 SheetPage）；activeName 路由三个面板
- `web/src/components/page/`：
  - `LanSyncPanel.vue`：devices（本机服务卡/暴露开关 van-switch/扫描/设备卡/手动直连 van-field）→ configure（对端信息/6 类勾选行+子项展开/主库警示/开始拉取）→ running（配对/进度 van-progress+百分比+速率/完成/失败重试）；子页切换与勾选全本地；快照驱动渲染；连接失败 van-dialog
  - `LocalUpdatePanel.vue`：四卡片组（本地更新 3 行/清单自动更新 N 行/补缺口 N 行/基准缺失 van-popup 名单）；行图标语义对齐原生（黄=/绿勾/红叉/进度圈）
  - `EngineLabPanel.vue`：状态卡 + 操作 9 行（busy 禁用/下载进度圈）+ 输出控制台（等宽自动滚底）
- 样式沿用 SheetPage 的 .grouped/.sel-row/.toggle-row/section-title 体系 + theme.css 变量

### UITest 锚点迁移（保住既有自动化）
- **LANSyncUITests**（双模拟器联测）继续可用：Web LANSync 页保留同名 aria-label：`lansync.local.status`、`lansync.expose.toggle`、`lansync.scan.once`、`lansync.peer.0`、`lansync.manual.field`（input）、`lansync.manual.connect`、`lansync.category.favorites`、`lansync.start`、`lansync.result.summary`、`lansync.fail.message`、`lansync.done.button`
- 值行锚点用**复合 aria-label**（`anchor|值文本`，label=aria-label）：`gapBackfill.status|尚未运行` 等；`gapBackfill.run`/`gapBackfill.detail.N`/`lansync.fail.message` 同规则
- **GapBackfillUITests 更新**：readText/reveal 改前缀匹配（`label BEGINSWITH 'anchor'`）取 `|` 后的值；导航加「点 profile.localUpdate.entry → 等 Web 页打开」步骤
- **HomePage.vue 补锚**（修复 P2-3 起 KlineUITests/LANSyncUITests/GapBackfillUITests 导航步骤已断的遗留）：brand span `aria-label="home.page"`、登录胶囊 `aria-label="home.profileButton"`
- `SheetOverlayUITests` 增 2 用例：个人中心 → 本地更新页打开（标题可达）→ 返回；个人中心 → 联机同步页打开 → 返回

## 6. 测试与验证

1. `cd web && npm run build` 绿（必须在 web/ 下跑）
2. fixtures 契约测试：`WebBridgeProtocolTests`（knownEvents 集合扩展 + 新增 lan/update/lab snapshot 形状锁定 + page/lan/update/lab 请求样例）
3. `xcodebuild test -only-testing:KlineUITests/SheetOverlayUITests`（3 旧 + 2 新全绿）
4. 模拟器调试桥冒烟：`curl http://127.0.0.1:5051/bridge` 逐动作打 lan.snapshot/update.snapshot/lab.snapshot/写回动作
5. `bash scripts/kline_deploy_mac.sh "<commit msg>"` 构建装机 + git 提交推送（失败不提交）
6. 真机验收清单：三页深浅色跟随、全功能对齐（扫描/手动直连真机联机走 LANSyncUITests 可选）、本地更新检查/补缺口、实验室实验①、返回键/关闭、LANSyncUITests/GapBackfillUITests 后续可跑

## 7. 变更文件清单

**新增（7）**：
- `Kline/WebBridge/WebPageBridge.swift`（容器 + page 模块）
- `Kline/WebBridge/LANSyncBridge.swift`
- `Kline/WebBridge/LocalUpdateBridge.swift`
- `Kline/WebBridge/EngineLabBridge.swift`
- `web/src/pages/WebPage.vue`
- `web/src/components/page/LanSyncPanel.vue` / `LocalUpdatePanel.vue` / `EngineLabPanel.vue`（4 个）

**修改（10）**：
- `Kline/WebBridge/WebMessageRouter.swift`（+4 模块注册）
- `Kline/WebBridge/HomeBridge.swift`（openEntry 两行 + overlay 挂 host）
- `Kline/Profile/ProfileDetailView.swift`（三入口改桥 + LocalUpdate 内嵌→入口行）
- `web/src/router/index.ts`、`web/src/types/protocol.ts`
- `KlineTests/Fixtures/bridge_protocol.json`、`KlineTests/WebBridgeProtocolTests.swift`
- `web/src/pages/HomePage.vue`（补锚）、`KlineUITests/GapBackfillUITests.swift`、`KlineUITests/SheetOverlayUITests.swift`（+2 用例）

## 8. 风险与边界

| 风险 | 缓解 |
| --- | --- |
| page.open 事件早于 WebView 就绪（首开时序） | page.ready 就绪拉取补推（SheetBridge 实测过的同款修复） |
| 关闭销毁 WebView 后重开延迟（Vue 重新 boot ~0.5s） | 全屏页打开频率低，可接受；不常驻省内存（2GB 设备优先） |
| LANSync 传输进度高频推送 | 0.3s 节流合并 |
| 双模拟器 LANSyncUITests 联测依赖原生输入框 typeText | input 用 aria-label 同名；不可用时退化报错清晰（联测本就需外部脚本准备对端） |
| WKWebView 值行 aria-label 覆盖文本 label | 复合锚点 `anchor|值` + 测试前缀匹配读值（本批同步改测试） |
| HomeEntryKind.layoutEditor 已退役分支不动 | 不涉及 |
