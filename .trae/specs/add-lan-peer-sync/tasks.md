# Tasks

- [x] Task 1: 服务端端点扩展（KlineHTTPServer）
  - [x] 1.1 扩展 `GET /sync/status`：附加设备名（UIDevice.name）、App 版本、6 类可同步内容清单（单文件：路径/字节/mtime；指标目录：聚合文件数与总字节）
  - [x] 1.2 新增 `POST /sync/backup`：body 列出将被覆盖的相对路径（支持目录快照），复制到 `Documents/Backups/<时间戳>/`，返回备份目录；校验路径不得逃出 Documents
  - [x] 1.3 新增 `POST /sync/reload-config`：重载 FavoritesStore / SimStore / PageLayoutConfigStore / SystemIndicatorStore 并发布更新（主线程）
  - [x] 1.4 新增 `POST /sync/request-pair`：接收方前台弹确认框，同意签发会话 token、拒绝返回失败；后续同步端点校验 token
  - [x] 1.5 `NWListener` 注册 Bonjour 服务 `_klinesync._tcp`（服务名 = 设备名），失败不影响既有 HTTP 功能
- [x] Task 2: 发现与连接层（LANSyncDiscovery.swift）
  - [x] 2.1 `NWBrowser` 浏览 `_klinesync._tcp`，去重后产出对端列表（名称 / IP / 端口）
  - [x] 2.2 手动 `IP:端口` 直连兜底输入框
  - [x] 2.3 连接校验：`GET /sync/status` 确认对端为 Kline、取回版本与内容清单
- [x] Task 3: 传输引擎（LANSyncTransfer.swift）
  - [x] 3.1 会话流：request-pair 取 token → 传输 header 携带 → 结束释放
  - [x] 3.2 推送：逐文件流式 `PUT /sandbox/<rel>`（临时名落盘 → 对端原子改名），URLSession 上传进度回调
  - [x] 3.3 拉取：流式 `GET /sandbox/<path>` 下载到本机临时文件，进度回调
  - [x] 3.4 指标目录镜像：先 `/sync/backup` 整目录快照，再逐文件传输，最后清理对端多余 *.tdx
  - [x] 3.5 sha256 校验（源端计算随文件附带，接收端比对）+ 失败重试（≤2 次）+ 覆盖前调用 `/sync/backup`
  - [x] 3.6 完成后调用 `/sync/reload-config`（配置与指标）或 `/sync/reload`（增量库）；主库仅提示重启
- [x] Task 4: 联机同步页面 UI（ProfileDetailView + LANSyncView.swift）
  - [x] 4.1 ProfileDetailView 新增「联机同步」入口行（样式同"Python 引擎实验室"）
  - [x] 4.2 设备列表页：本机服务状态（真实探测）、发现中 / 已发现设备卡片、手动 IP 入口
  - [x] 4.3 同步配置页：方向切换（推送 / 拉取）、6 类内容勾选 + 双端大小 / mtime / 文件数对比、主库警示文案
  - [x] 4.4 传输进度页：总进度 + 当前文件 + 速率，成功 / 失败 / 已备份路径的结果态
- [x] Task 5: 双模拟器联测（KlineUITests + 设备验证循环）
  - [x] 5.1 新增 `LANSyncUITests.swift`：同一 Mac 启动两台 iPad mini 5（5th gen）模拟器实例，验证互发现、推送 favorites、接收端确认框、热重载后模拟页数据一致（testPushFavoritesToManualPeer passed 52s；UD2 favorites.json 由 absent 变为与 UD1 sha256 一致）
  - [x] 5.2 按 kline-device-validation-loop 技能流程构建到模拟器并请用户在真机上人工验证（Bonjour 真机发现 + 指标公式镜像 + 主库整库拉取耗时）（App 已构建安装到两台 GUI 模拟器并运行；真机人工验证项已交付用户）
- [x] Task 6: 按用户反馈重构为「手动扫描/暴露 + 仅拉取」模型（2026-10-05）
  - [x] 6.1 删除监听即广播：KlineHTTPServer 不再自动注册 Bonjour，新增 LANSyncAdvertiser（NetService publish/unpublish）
  - [x] 6.2 浏览改单次 scanOnce（4s 窗口自动停止），进页面不再自动扫描；UI 新增「暴露」开关（默认关，退出页面自动取消）与「扫描一次」按钮
  - [x] 6.3 删除推送能力：LANSyncDirection/push 分支/上传 delegate/对端备份与对端重载调用全部移除，仅保留拉取（本机备份→下载→sha 校验→原子覆盖→本机热重载）
  - [x] 6.4 配对改「暴露即授权」：对端暴露态自动签发 token（或 KLINE_EXPOSED/KLINE_AUTOPAIR），未暴露 403；删除对端确认弹窗
  - [x] 6.5 UI 测试改 testPullFavoritesFromManualPeer 并回归通过（45.8s，sha256 marker→对端内容翻转验证）

# Task Dependencies

- Task 2、3 依赖 Task 1（服务端端点与 Bonjour 注册）
- Task 4 依赖 Task 2、3（UI 消费发现与传输能力）
- Task 5 依赖 Task 1-4 全部完成
- Task 1 内 1.1-1.5 相互独立；Task 2 与 Task 3.2/3.3/3.5 相互独立，可并行开发
