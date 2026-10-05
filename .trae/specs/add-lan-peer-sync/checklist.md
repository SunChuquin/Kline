# Checklist

- [x] `GET /sync/status` 返回设备名、App 版本与 6 类可同步内容的量（单文件字节/mtime，指标目录文件数+总字节）
- [x] 默认隐身：App 启动/进页面不注册 Bonjour 广播、不启动浏览（监听 service 注册代码已删除）
- [x] 「暴露」开关：开启即广播 `_klinesync._tcp` 并自动授权配对；退出页面/再次点击即取消（onDisappear unpublish + isExposed=false）
- [x] 「扫描一次」：4s 窗口单次浏览自动停止、结果保留、防重入（scanOnce）
- [x] `POST /sync/request-pair`：对端暴露态自动签发 token，未暴露 403「对端未开启暴露」；backup/reload-config 校验 token
- [x] 手动 `IP:端口` 直连兜底（UI 测试用 127.0.0.1:5052 直连）
- [x] 仅拉取：代码中不存在同步流程向对端写文件的路径（push 分支/上传 delegate 全部删除）
- [x] 拉取走流式传输 + 进度/速率回调；主库走临时文件 + 原子替换
- [x] 指标公式同步为整目录镜像：本机整目录备份 → 逐文件拉取 → 清理本机多余 *.tdx
- [x] sha256 校验失败时删除临时文件、本机文件保持原状、UI 可重试
- [x] 覆盖本机文件/目录前自动备份到 `Documents/Backups/<时间戳>/` 并在结果页展示备份路径
- [x] 个人中心新增「联机同步」入口行，点击打开全屏 LANSyncView
- [x] 6 类内容多选可独立勾选；勾选主库时展示体积/耗时/需重启警示
- [x] 配置、指标与增量库拉取后无需杀进程即生效；主库替换后提示重启 App
- [x] 双 iPad mini 5（5th gen）模拟器联测通过：对端暴露 → 手动直连拉取 favorites → 本机备份 → sha256 翻转验证（marker 1dfe… → 对端 b6f6…）+ 热重载（passed 45.8s）
- [x] 全部改动构建通过（xcodebuild 非沙箱模式），UI 测试跑在 iPad mini 5 模拟器上
