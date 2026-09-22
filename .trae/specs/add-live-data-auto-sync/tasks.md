# Tasks

> 交付纪律（遵循 `.trae/skills/kline-device-validation-loop`）：每阶段独立可编译、可演示、可单独真机验收；每阶段收尾用
> `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`（退出码 0/6/7 均可交付）并暂停等用户真机确认。
> 中文提交：`feat(live-sync): ...`。主库 `tdx.db` 全程不改动。

- [x] Task 1: 【生成端】产出增量库 `tdx_live.db` + `tdx_live.manifest.json`（电脑本地可验证，不需要设备）
  - [x] SubTask 1.1: 新增 `src/data/symbols.txt` 统一清单（并集标的，纯代码行，支持注释；先从用户当前关注标的开始，样例 10~30 只便于验证）
  - [x] SubTask 1.2: 新增 `src/live_db_builder.py`：建 `live_meta/live_daily/live_weekly/live_monthly/live_quarterly/live_yearly`（以 `code` 为键，与主库字段语义一致），由 `daily` 聚合出周/月/季/年线
  - [x] SubTask 1.3: 取数实现——优先批量快照接口（一次多标的，拼当日K线），首次构建时用逐标的日线接口补齐最近 N 根（默认 30，交易日）；带 User-Agent、请求间隔限速、指数退避重试≥3 次、失败降级
  - [x] SubTask 1.4: 生成 `manifest.json`（version/generated_at/trade_date/source/symbols/min_date/max_date/各表行数/sha256），并在写入前断言：清单全覆盖、每标的最新日期非空、行数与声明一致；异常不产出
  - [x] SubTask 1.5: 电脑侧自检脚本/命令：打印各表行数、每标的 min/max 日期、文件体积，确认清单 100% 覆盖
  - 验收：✅ 真实联网跑通（`--check` 逐项 OK）；额外修正「交易日必须来自行情源 f124 时间戳」——用 `--now-date 20261001` 模拟国庆假期验证不会造出假K线（`date=20261001` 计数为 0，`max_date` 仍为 20260922）

- [x] Task 2: 【App 读取】增量库叠加读取 + 热刷新（核心能力，真机验收重点）
  - [x] SubTask 2.1: 新增 `Kline/Data/LiveDataStore.swift`：打开/校验 `Documents/tdx_live.db`（缺失/损坏时静默降级）、`code → metaId` 映射缓存、按周期取该标的增量行、`mtime`/`sha256` 指纹、`reload()`（串行队列上关旧连接开新连接）
  - [x] SubTask 2.2: 改 `DatabaseManager.swift`：`fetchBars/fetchDailyData/fetchPeriodLimited` 等出口统一走"增量优先 + 主库补齐"合并（同 `date` 以增量为准），不改动任何调用方签名
  - [x] SubTask 2.3: 新增数据版本信号（`dataVersion`）与刷新联动：递增后触发 `MarketRowCache` 对应行失效/重算、`SimCondEngine.sweepConditions(trigger: .dataReload)`、K线图重新查询，避免整屏闪烁
  - [x] SubTask 2.4: 前台定时指纹检查（默认 5 分钟）+ 回前台立即检查；指纹未变则不重载
  - [x] SubTask 2.5: 热刷新日志（复用 `DebugLogger`）：记录重载前后行数/最新日期/耗时；异常回退主库并留痕
  - 验收：✅ 真机日志实证——外部写入后 `[Live] 重载完成 … 510行 → 595行 耗时=10ms 内容变化=true` → `[DB] dataVersion → 1` → `[Cache] dataVersion 变化 → 重取行 n=16`；**全程未重启**；内容相同的那次写入正确打印"指纹时间戳变化但内容一致 → 跳过热重载"；删除增量库后 `available=false` 自动降级为纯主库、重新推入后恢复（reloadCount 2）
  - 额外修正：合并规则改为**按 date 集合去重**（原 `date < 增量最小 date` 切分会在"主库比增量库更新"时丢掉较新的K线，比不合并还差）

- [x] Task 3: 【云端发布】GitHub Actions 定时产出并发布到 `data` 分支
  - [x] SubTask 3.1: 新增 `.github/workflows/sync-live-db.yml`：cron `0 3 * * 1-5` / `30 6 * * 1-5` / `5 7 * * 1-5`（UTC = 北京 11:00 / 14:30 / 15:05）+ `workflow_dispatch`（另加 symbols/生成端变更的 push 触发）
  - [x] SubTask 3.2: 复用 Task 1 的 `live_db_builder.py` 在 runner 上生成产物，提交 `tdx_live.db` + `tdx_live.manifest.json` 到 `data` 分支（孤儿提交覆盖式，避免仓库体积膨胀）
  - [x] SubTask 3.3: 生成失败/校验不通过时 jobs 失败且不覆盖 `data` 分支上一版
  - [x] SubTask 3.4: 电脑侧验证三个源可用：jsDelivr CDN、`raw.githubusercontent.com`、备用源可配置；记录实测下载耗时与校验结果
  - 验收：✅ 实测跑通 run 35681805476（29s）；`data` 分支只含两个文件，manifest 与产物一致；两个源下载均 110,592 bytes 且 sha256 = manifest（raw 1.79s / jsDelivr 3.83s）

- [x] Task 4: 【App 拉取】自动下载 + 校验 + 原子替换 + 设置 UI（真机验收重点）
  - [x] SubTask 4.1: 新增 `Kline/Infrastructure/TdxSyncConfig.swift`：UserDefaults 持久化（启用开关、源地址列表、更新时刻 11:00/14:30/15:05、交易日限制、前台检查间隔），与 `ChartConfigStore`/`KlineThemeStore` 同惯例
  - [x] SubTask 4.2: 新增 `Kline/Infrastructure/TdxSyncManager.swift`：多源顺序回退下载（`URLSession`，含超时/重试）、sha256 + manifest 行数与日期校验、临时文件校验通过后原子替换、失败保留上一版并记录原因
  - [x] SubTask 4.3: 调度：交易日按配置时刻触发 + 回到前台立即尝试（去重节流）；同步在后台队列执行，完成后调 `LiveDataStore.reloadAsync()` 走 Task 2 的刷新链路
  - [x] SubTask 4.4: 在 `LocalUpdateView.swift` 增「数据同步」分区：启用开关、源地址、更新时刻、同步状态、上次同步、数据版本、覆盖标的、本次所用源、失败原因、立即更新、快照语义说明
  - [x] SubTask 4.5: `Info.plist` 增 `NSLocalNetworkUsageDescription`（局域网通道所需）；https 源无需 ATS 例外
  - 验收：✅ 真机验证云端自动拉取（到点补跑触发 → manifest → 下载 → sha256 校验 → 原子替换 → 热刷新）；启用开关为默认开启，可随时关闭

- [x] Task 5: 【通道 A/B + 兜底】电脑在场时的一键推送与局域网直推
  - [x] SubTask 5.1: USB 一键脚本 `TrollRestore/push_live_usb.py`：封装 `usbmux forward 5051` + `PUT /sandbox/…` + `POST /sync/reload` + 回读 `/sync/status`，输出明显提示与"请保持 Kline 前台未锁屏"提醒
  - [x] SubTask 5.2: 局域网直推脚本 `TrollRestore/push_live_lan.py --host <设备IP>`：先探活再推送，失败按「IP 变了 / 不同 Wi-Fi / App 不在前台」逐项提示
  - [x] SubTask 5.3: App「数据同步」分区展示设备当前局域网 IP（`LocalNetworkAddress`，复用 `KlineHTTPServer.shared.port`，未硬编码端口）
  - [x] SubTask 5.4: 电脑侧文档：新增 `.trae/documents/Kline-增量行情库自动同步.md`（三通道使用说明、清单维护、状态核对、故障排查、硬边界）
  - 验收：✅ 两条通道都实测跑通——USB：推送 118,784 bytes → 热刷新 → 设备侧 595 行/最新 20260922；局域网：`192.168.137.52` 推送同样成功

# Task Dependencies

- Task 2 依赖 Task 1（需要产物才能验收）
- Task 3 依赖 Task 1（复用生成脚本）
- Task 4 依赖 Task 2、Task 3（需要读取层与云端源同时就绪）
- Task 5 依赖 Task 2（推送后需热刷新生效）
- 可并行：Task 1 与 Task 3 的 workflow 骨架；Task 5 的脚本可在 Task 4 期间并行开发（均只依赖 Task 1/2 的契约）

# 交付记录（真机）

| build | 内容 |
| :--- | :--- |
| v1.0.2 (363) | 增量库叠加读取 + 热刷新 + 数据版本联动（Task 2） |
| v1.0.2 (365) | 合并规则修正（按 date 去重，避免丢较新K线）+ 云端发布流水线（Task 3） |
| v1.0.2 (367) | App 侧自动拉取 + 「数据同步」设置面板（Task 4） |
| v1.0.2 (368) | 面板展示局域网地址 + 自动化文档（Task 5.3/5.4） |

**运行期证据（设备日志 `Documents/debug_log.txt`）**

```
[Live] 重载完成 reason=外部写入 覆盖=17只/日线595行 最新=20260922 耗时=10ms 指纹 …39afdfaa → …db9b2bd5 内容变化=true
[DB]   dataVersion → 1（增量库内容变化 · 外部写入 · 覆盖=17只/日线595行 · 最新=20260922）
[Cache] dataVersion 变化 → 重取行 n=16 coveredCode=17
[Live] 指纹时间戳变化但内容一致（sha256 未变）→ 跳过热重载   ← 同一文件重复推送时不重算
[TdxSync] 调度启动 enabled=true 间隔=60s 时刻=11:00,14:30,15:05 交易日限制=true 局域网地址=192.168.137.52
```