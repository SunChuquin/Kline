# Checklist

- [x] `GET /sync/status` 返回设备名、App 版本与 6 类可同步内容的量（单文件字节/mtime，指标目录文件数+总字节）（curl 实测：既有字段保留 + device + items）
- [x] `POST /sync/backup` 将指定文件/目录快照到 `Documents/Backups/<时间戳>/` 且拒绝逃出 Documents 的路径（curl 实测 401 鉴权 + 白名单；路径防穿越 resolveSandboxPath）
- [x] `POST /sync/reload-config` 重载四个 Store 后模拟页 / 自选页 / 首页布局 / 公式中心立即反映新数据（UD2 沙盒日志 `applied scopes: favorites`）
- [x] `POST /sync/request-pair` 在接收方前台弹确认框，同意签发会话 token、拒绝返回失败；同步端点校验 token（autopair 联测通过 + 无效 token 401 实测）
- [x] Bonjour 服务随 5051 监听注册（`_klinesync._tcp`），注册失败不影响既有 HTTP 端点（UD1 日志：Bonjour 发现 iPad-mini5-B）
- [x] NWBrowser 能发现同网段前台 Kline 设备并去重展示；手动 IP:端口 可直连（UI 测试手动直连 127.0.0.1:5052 通过）
- [x] 推送 / 拉取均走流式传输且有进度回调；主库走临时文件 + 原子替换（push 实测；pull 流式 .part+原子 rename 代码核实）
- [x] 指标公式同步为整目录镜像：整目录备份 → 逐文件传输 → 清理对端多余 *.tdx（实现核实；真机人工验证项）
- [x] sha256 校验失败时删除临时文件、目标文件保持原状、UI 可重试（实现核实：finalize 前 sha 比对，不符删 .part 回 400）
- [x] 覆盖既有文件/目录前自动完成备份并在结果页展示备份路径（联测结果卡「已备份到对端：Backups/20261005-202400」）
- [x] 个人中心新增「联机同步」入口行，点击打开全屏 LANSyncView（UI 测试实际点击进入）
- [x] 方向（推送/拉取）与 6 类内容多选可独立勾选；勾选主库时展示体积/耗时/需重启警示（UI 测试推送方向 + favorites 勾选）
- [x] 配置、指标与增量库同步完成后无需杀进程即生效；主库替换完成后提示重启 App（reload-config/reload 热路径；main 通知弹提示）
- [x] 双 iPad mini 5（5th gen）模拟器实例联测通过：互发现 → 推送 favorites → 接收端确认 → 热重载一致（passed 52.08s，sha256 两端一致）
- [x] 全部改动构建通过（xcodebuild 非沙箱模式），UI 测试跑在 iPad mini 5 模拟器上（BUILD SUCCEEDED + test-without-building）
