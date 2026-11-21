# LAN 同步新增「指标缓存」按组合细粒度同步

## Context

联机同步（设备↔设备拉取模型）现有 6 类内容（favorites/sim/layouts/indicators/live/main）都是**文件级**同步。指标缓存（indicator_cache.db，期3/4 交付）是单库多组合结构，用户需要：**同步时可勾选指定组合的缓存，且必须同时覆盖对应的指标组合定义**——否则对端组合内容与本机不同，指纹（mode=pN+组合内容）不匹配，同步来的缓存行级校验全部不命中。

架构约束（已侦察确认）：
- 服务端 = KlineHTTPServer（前台 HTTP 服务，/sync/status 暴露清单 + /sandbox 文件下载 + request-pair token 门禁）；客户端 = LANSyncTransfer（URLSession 仅拉取：计划→配对→备份→下载+sha→合并/覆盖→生效）。
- 已有两个细粒度先例：**自选分组合并**（下载整档→按组名合并写回）与 indicators **整目录镜像**；Web 端 LanSyncPanel.vue 的 children 勾选渲染是**通用的**（按对端 items/children 动态渲染，selections 提交 {category, mode, childKeys}），UI 改动极小。

## 方案：新增第 7 类 `indicatorCache`，导出/合并走专用 sqlite 通道

### 数据流

```
对端 /sync/status
  └─ items += indicatorCache：files=[]，children = 6 组合
     （key=local/p1..p5，name=组合名，size=该组合 payload 总字节，count=行数）
  └─ 懒生成 Documents/SyncCache/presets.json（ChartPresetStore.presets JSON，本机全部 5 槽）

本机勾选组合（如 p1 + local）→ lan.start selections
  → Transfer：
     1. 备份本机 indicator_cache.db → Documents/Backups/<ts>/SyncCache/
     2. GET /sync/cache-export?combos=...（token 门禁）
        → 对端 IndicatorCacheDB.exportCombos 流式导出选中组合行为临时 sqlite
        → 下载到临时文件 + X-Kline-Sha header 校验（复用 downloadTask/重试/速率统计）
     3. IndicatorCacheDB.mergeFrom(path:comboKeys:)——ATTACH 临时库 +
        INSERT OR REPLACE INTO cache SELECT * WHERE combo_key IN (选中) + DETACH
     4. 组合定义跟随：GET /sandbox/SyncCache/presets.json（现有文件通道）
        → sha 校验 → ChartPresetStore.mergeRemote：按 id 槽位替换本机选中组合
        （local 无定义不涉及；未选槽位不动）+ persistPresets + bumpConfigModeRevision
     5. 生效：ChartCacheStore.clearAll()（内存对齐；磁盘行级校验兜底）
```

### 为什么导出为临时 sqlite 而非 JSON
payload 是二进制 BLOB（单行最大 3MB+）：直拷零转换、ATTACH 合并一条 SQL、复用现有流式下载+sha+重试机制、避免 base64 膨胀 1.33×。

## 实施步骤（依赖序）

### 1. LANSyncModels.swift — 新类别
`LANSyncCategory` 加 `case indicatorCache`：title「指标缓存」、subtitle「indicator_cache.db 按组合（同步时自动覆盖对应组合定义）」；`isDirectoryMirror=false`、`needsConfigReload=false`（生效走 Transfer 专用分支）。

### 2. IndicatorCacheDB.swift — 统计/导出/合并（3 个新方法）
- `comboStats() -> [(key: String, rows: Int, bytes: Int64)]`：`SELECT combo_key, COUNT(*), SUM(LENGTH(payload)) GROUP BY combo_key`（queue.sync）
- `exportCombos(combos: [String], to url: URL) throws`：queue.sync 内新建同构临时库（CREATE TABLE cache 同 schema + 索引）→ 逐行 SELECT 本库选中组合行 → INSERT（payload BLOB 直拷）；完成校验行数一致
- `mergeFrom(path: URL, combos: [String]) throws`：queue.sync 内 `ATTACH DATABASE ? AS peer` → `INSERT OR REPLACE INTO cache SELECT * FROM peer.cache WHERE combo_key IN (...)` → `DETACH peer`；临时库由调用方删除

### 3. ChartPresetStore.swift — 组合定义导出/合并
- `exportJSON() -> Data`（presets 数组 JSONEncoder，复用 persistPresets 同编码）
- `mergeRemoteJSON(_ data: Data, selectedIDs: Set<String>) throws`：解码对端 5 槽 → **只替换 selectedIDs 中的槽位**（保持本机槽位顺序/名称不变的部分原样）→ persistPresets + bumpConfigModeRevision

### 4. LANSyncSupport.swift — inventory 扩展
- `files(for:)` 加 indicatorCache 分支：files=[]（db 本体不作为文件暴露）
- `children(for:)` 加 indicatorCache 分支：`IndicatorCacheDB.shared.comboStats()` 映射为 children（key=combo_key、name=「局部独立配置」/组合名、size=bytes、count=rows）；**同时懒生成** `Documents/SyncCache/presets.json`（ChartPresetStore.exportJSON 原子写盘——status 被请求时刷新，保证对端拉到最新定义）

### 5. KlineHTTPServer.swift — 新端点
路由 switch 加 `case ("GET", "/sync/cache-export")`：
- 门禁复用沙盒读门禁（同 GET /sandbox：暴露态/token/loopback）
- query `combos`（逗号分隔，校验合法槽位 local/p1..p5）
- `IndicatorCacheDB.shared.exportCombos` 生成 `Documents/SyncCache/export-<ts>.db` → 流式返回（Content-Length）+ `X-Kline-Sha` header（streamSHA256 复用 LANSyncTransfer 同款？——服务端独立实现一次 1MB 分块 sha256，或把该 helper 提为共享；完成后删除临时文件）

### 6. LANSyncTransfer.swift — 拉取/合并路径
- `buildPlan` 加 `(.indicatorCache, .children)` 分支：files=[] + 保留 childKeys（不进通用文件计划）
- `transferFiles` 加 indicatorCache 分支：
  1. `pullCacheExport(peer:token:combos:)`：GET /sync/download-cache → 下载临时文件（download 通用流式+进度）→ 本地 sha256 == 响应 header X-Kline-Sha → `IndicatorCacheDB.shared.mergeFrom` → 删临时
  2. **组合定义跟随**（勾选了任意 cache 子项即自动附带）：对端 `/sandbox/SyncCache/presets.json` 走现有 `downloadPeerFavorites` 同款下载+sha 流程 → `ChartPresetStore.mergeRemoteJSON(data, selectedIDs: childKeys 去掉 local)` → 汇总注明「已覆盖 N 个组合定义」
- `backupLocally` 加 indicatorCache 分支：本机 indicator_cache.db 存在则复制备份
- `applyEffects` 加 `.indicatorCache` → `ChartCacheStore.shared.clearAll()`（@MainActor）
- `finishDone` 汇总注明合并结果（组合数/行数）

### 7. LanSyncPanel.vue — 文案（结构零改动）
children 通用渲染自动出现组合勾选列表；补充 indicatorCache 类目说明（「同步选中组合的缓存，将同时覆盖对应的组合定义」）；检查 `snap.configure.categories` 渲染对第 7 类的兼容（icon 缺省 fallback）。

### 8. 契约与协议
- protocol.ts：lan.snapshot 类型注释补 indicatorCache；fixtures（bridge_protocol.json）若含 lan 样例补 children 示例
- WebBridgeProtocolTests：lan snapshot 形状测试（若有）同步

## 验证

1. **编译 + 契约测试**：xcodebuild + `-only-testing:KlineTests/WebBridgeProtocolTests`
2. **单机 loopback 冒烟**（模拟器本机 server）：curl /sync/status 看 indicatorCache children（6 组合行数/字节与 db 一致）→ curl /sync/cache-export?combos=local 下载 → python 验证临时库行数/指纹 → mergeFrom 幂等（自合并行数不变）→ presets.json 内容与 UserDefaults 一致
3. **UI 截图**：LanSyncPanel 出现「指标缓存」类 + 6 组合勾选列表
4. **双模拟器端到端**（可选加强）：simctl boot 第二台模拟器装 App → A 暴露、B 扫描连接 → 勾选 p1 同步 → B 端 db 行数/指纹/组合定义与 A 一致 → B 打开同标的验证「磁盘注水」命中
5. UITest 纪律：只跑相关域（LANSyncUITests 若覆盖 children 渲染）

## 风险与边界

- **指纹一致性是功能成立的前提**：组合定义跟随覆盖保证同槽位内容一致 → 指纹一致 → 注水命中。用户若只同步缓存不同步定义（本方案强制附带，无此暴露面）。
- local 行同步：本机局部配置**不被覆盖**（local 是「各标的各周期本机记忆配置」，语义上属于接收端本地态）；仅同步 local 的**缓存行**（行级校验按本机局部配置指纹自然过滤错行——若两端局部配置不同，同步来的 local 行校验不过、保留不命中，无副作用）。
- 大库导出：单组合全市场 ~450MB（full），流式导出+下载，memory 安全（chunk 读写）。
- 导出临时文件并发：/sync/cache-export 用时间戳文件名 + 完成即删；串行队列内执行防并发写。
