# Tasks

- [x] Task 1: opener.m 新增 --engine 模式
  - [x] 1.1 参数解析：`--engine <curBuild> <maxWait> [extraLog]` 分支（在 --cp/--py 分发之后）；glob `Engine.app` + 比对 `com.sunck.KlineEngine`；双轮确认后 `openApp("com.sunck.Kline")`；日志前缀 `engine `
  - [x] 1.2 本机 clang 编译冒烟（macOS 可编译 ObjC 语法检查即可，iOS 链接由 CI 承担）——`-fsyntax-only` 过
- [x] Task 2: App 侧接线
  - [x] 2.1 PythonEngineHost.installViaTrollStore：spawn 参数切 `--engine <installedEngineBuildNumber ?? curAppVer> 600 <log>`（构建号不可得退回默认模式）；记录 engineBuild 快照日志
  - [x] 2.2 KlineHTTPServer.statusJSON 增加 `engineBuild`（复用 installedEngineBuildNumber，主线程读 Info.plist）
  - [x] 2.3 新增 POST /install-engine：downloadTipa + digest 复核 → spawn opener --engine → triggerTrollStoreInstall；409 busy / 502 校验失败删文件；响应含 engineBuild（busy 检查用 @Published isBusy 镜像；digest 不可达时记日志继续装——GitHub 抖动不阻断 sidecar 已过的链路）
- [x] Task 3: 模拟器验证（iPad mini 5th gen，GUI 可见）
  - [x] 3.1 xcodebuild 构建 + KlineTests 全绿（37/37 基线不回归）——Test SUCCEEDED，xcresult 2026.10.07_16-10-10
  - [x] 3.2 curl 冒烟：GET / 含 `"engineBuild":null`（模拟器内嵌引擎）；POST /install-engine `{}` → 400 bad body；`{"url":"…Kline.ipa"}` → 400 not a tipa url（注意：本机 5051 若被 usbmux 转发占用，curl 打到的是真机——先 pkill pymobiledevice3）
- [ ] Task 4: 真机验证（用户配合，iPad mini 4 USB）
  - [ ] 4.1 curl POST /install-engine（走 klinehttp 5051 转发）→ 观察自动下载→TrollStore→装完自动回前台；klinehttp 拉 debug_log + opener_log 取证
  - [ ] 4.2 部署助手契约文档落盘（.trae/documents/ 或 scripts/ 内 README 级注释：GET / engineBuild → /install-engine → /install-local 编排顺序与错误处理）
- [ ] Task 5: 文档回填 + 提交
  - [ ] 5.1 可行性分析 §5.6 回填「部署助手引擎通道」；checklist 勾选
  - [ ] 5.2 git commit + push

# Task Dependencies

- Task 2 依赖 Task 1（opener --engine 先落地才能接线）
- Task 3 依赖 Task 2；Task 4 依赖 Task 3（真机用 CI 新包或本地真机构建含新 opener——opener 编译在 CI build.yml，本地真机构建若缺 opener 需先补编译步骤或走 CI 包）
- Task 5 依赖 Task 4（真机取证后才算完成）
