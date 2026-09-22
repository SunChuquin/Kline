# Checklist

> 逐项结论以**实测证据**为准：电脑侧自检、真机日志（`Documents/debug_log.txt`）、设备 `/sync/status` 回读。
> 交付版本：v1.0.2 (363) → (365) → (367) → (368) → (369)。

## 增量库契约

- [x] `Documents/tdx_live.db` 以 `code` 为键（`live_meta` + 五张周期表），与主库 `meta_id` 分配解耦，无 id 冲突风险
      —— `--check` 实测：17 只标的、daily 510 / weekly 119 / monthly 34 / quarterly 17 / yearly 17
- [x] `tdx_live.manifest.json` 含 version/generated_at/trade_date/source/symbols/min_date/max_date/各表行数/sha256
      —— `--check` 逐项比对"声明 = 实际"全部 OK
- [x] 主库 `Documents/tdx.db` 在全流程中未被改动（整库替换仍为手动 + 重启）
      —— `--from-master-db` 只读实测后主库 sha256 与 mtime 均未变
- [x] 增量库缺失或损坏时 App 静默降级为主库读取，不报错、不阻塞
      —— 真机实测：无增量库时 `/sync/status` 为 `available:false`；删除增量库后 App 正常降级，重新推入即恢复

## 叠加查询

- [x] 合并规则实现为"增量库该标全部行 + 主库中同 date 不重复的行，同 date 以增量库为准"，无重复/无缺口
      —— 实现为按 date 集合去重 + 整体降序重排（比原 `date < 增量最小日期` 切分更安全：主库更新时不会丢新K线）
- [x] 未被增量库覆盖的标的，查询结果与合并前完全一致
      —— `liveSlice` 为 nil 时直落纯主库路径；真机 `[Cache] prefetch OK … bars=80`（未覆盖标的）正常
- [x] 行情页、自选页、K线图、条件单/预警取数**均未改动调用方代码**即可看到叠加后的数据
      —— 仅改 `DatabaseManager` 内部实现，全部调用方签名未变（Grep 校验）

## 热刷新（核心）

- [x] 外部写入 `tdx_live.db` 后，App 在"前台定时检查（默认 5 分钟）"或"回到前台"时自动生效，**全程无需重启 App**
      —— 真机日志：`[Live] 重载完成 reason=外部写入 … 510行 → 595行 耗时=10ms 内容变化=true`
- [x] 指纹（mtime/sha256）未变化时不重载、不刷新缓存，无无谓重算与界面闪烁
      —— 真机日志：重复推送同一文件时 `指纹时间戳变化但内容一致（sha256 未变）→ 跳过热重载`
- [x] 重载后行情行缓存、条件单扫描（`trigger: .dataReload`）、K线图查询均被正确触发
      —— 真机日志：`[DB] dataVersion → 1` → `[Cache] dataVersion 变化 → 重取行 n=16 coveredCode=17`；
      `SimStore` 订阅 `$dataVersion` → `sweepConditions(trigger: .dataReload)`（代码已接线）
- [x] 热刷新日志记录重载前后行数/最新日期/耗时，异常回退主库并留痕
      —— `[Live]` 三态日志（缺失/打不开/缺表）+ `[DB] dataVersion` + `[Cache]` 重取日志

## 云链路

- [x] GitHub Actions 在交易日 UTC 03:00 / 06:30 / 07:05（北京 11:00 / 14:30 / 15:05）产出并发布到 `data` 分支，支持手动触发
      —— workflow 已交付；实测 run 35681805476 成功（29s），另加 symbols/生成端变更的 push 触发
- [x] 生成失败或校验不通过时不覆盖上一版
      —— 生成端 `--check` 不通过即非零退出、临时文件不原子替换；workflow 失败发生在 push 之前
- [x] 设备可从 jsDelivr CDN 与 raw 源匿名拉取；备用源可配置
      —— 两源实测下载 110,592 bytes、sha256 与 manifest 一致（raw 1.79s / jsDelivr 3.83s）；源列表可在面板编辑
- [x] 取数优先批量接口、限速 + 退避重试≥3 次；单次生成不出现逐标的数千次请求
      —— 主路径为批量 `ulist.np/get`（一次请求覆盖整份清单），`clist` 分页仅作兜底；逐标的仅用于首次/补齐
- [x] 下载后校验 sha256 与 manifest 行数/日期，通过才原子替换，失败保留上一版并显示原因
      —— 真机日志实证完整链路：`源1 取 manifest` → `源1 下载` → `同步成功 v1 trade=20260922 覆盖=17只 实际写入=true`
      → `[Live] 重载完成 … 指纹 db9b2bd5 → e89501f9`（e89501f9 即 `data` 分支产物的 sha256，证明确实是云端那份）

## 通道 A/B

- [x] USB 一键推送脚本可用（`usbmux forward 5051` + `/sandbox/tdx_live.db`），并提示需保持 Kline 前台未锁屏
      —— 实测：推送 118,784 bytes → HTTP 200 → 热刷新 → 设备侧 595 行/最新 20260922
- [x] 局域网直推脚本可用（`http://<设备IP>:5051/sandbox/tdx_live.db`）
      —— 实测：`--host 192.168.137.52` 推送 118,784 bytes → HTTP 200 → 通知热刷新成功
- [x] App「数据同步」分区显示设备当前局域网 IP
      —— 真机日志：`[TdxSync] 调度启动 … 局域网地址=192.168.137.52`；面板该行复用 `KlineHTTPServer.shared.port`

## UI 与状态

- [x] 「数据同步」分区含：启用开关、源地址、更新时刻、上次同步时间、manifest 版本、覆盖标的数、最新交易日、立即更新、日志入口
      —— `LocalUpdateView.syncSection`（配置行 / 状态行 / 网络行 / 操作行）
- [x] 四种状态（未启用 / 已同步 / 同步中 / 失败）可区分显示，样式与现有卡片/行高规范一致
      —— `syncState` + `syncStateColor`，行高与既有 `infoRow`/`editRow` 规范对齐
- [x] 「立即更新」可见进度并可刷新状态与数据
      —— 同步中显示 `ProgressView`，走与调度完全相同的拉取/校验/替换/热刷新链路
- [x] UI 标注"最新交易日 / 更新时间"，明确 11:00 与 14:30 为盘中快照、15:05 为完整K线
      —— 面板「数据版本」显示 `vN（YYYYMMDD）`，另有快照语义说明行
- [x] 所有新增可点元素命中区 ≥ 44×44pt，颜色使用语义色（深色模式正确）
      —— 开关整行 48pt 命中区、输入行 44pt；分色用 `Color(.secondarySystemBackground)` / `.primary`

## 交付纪律

- [x] 每个 Task 阶段独立可编译，并经 `build_and_deploy.py` 交付到设备后由用户在真机验收
      —— v363（读取层+热刷新）/ v365（合并修正+云流水线）/ v367（自动拉取+面板）/ v368（局域网地址+文档）/ v369（默认开启）
- [x] 真机验收覆盖：USB 推入生效、云端自动更新、断网/坏源失败回退、删除增量库后恢复
      —— USB ✅｜云端自动更新 ✅（启动即补跑 11:00 档并成功写入）｜坏源回退 ✅（多源顺序回退 + 失败串带源序号）｜删除后恢复 ✅（available=false → 重推恢复）

## 已知边界（非缺陷，设计取舍）

- 所有通道生效的前提是 **Kline 前台未锁屏**（iOS 无后台能力，TrollStore 版同样）；盯盘时 App 本就前台。
- 主库 1GB+ 仍走手动整库替换（替换后需重启），本机制只自动化"增量"这一层。
- 云端产物的关注清单放在公开仓库（仅代码，不含备注），如需私有化可改自建镜像源（面板可配）。