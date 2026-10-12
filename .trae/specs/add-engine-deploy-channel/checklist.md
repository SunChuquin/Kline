# Checklist

- [ ] opener --engine：glob Engine.app + com.sunck.KlineEngine 判定 + 双轮确认 + openApp(com.sunck.Kline)，超时自退非 0，日志带 engine 前缀
- [ ] opener 既有三模式（默认 App 版本守护 / --cp / --py）行为零改动（代码路径无交叉污染）
- [ ] installViaTrollStore 切 --engine 后：LocalUpdateView 引擎行与 /install-engine 共用，构建号不可得退回默认模式
- [ ] statusJSON 新增 engineBuild：已装 = CFBundleVersion Int；未安装/内嵌 = null；其余字段零改动（部署助手既有解析不破坏）
- [ ] POST /install-engine：bad body 400 / busy 409 / 非 .tipa URL 拒绝 / sha256 或 digest 失败 502 且删残留文件不安装 / 成功响应含 engineBuild
- [ ] 双 sha256 校验链完整（sidecar + Release digest），时间戳穿透保留
- [ ] 模拟器：KlineTests 全绿（37/37 基线）；GET / curl 冒烟含 engineBuild
- [ ] 真机：/install-engine 全流程取证（下载→TrollStore→自动回前台），debug_log + opener_log 证据链
- [ ] 部署助手契约文档落盘（编排顺序：GET / → /install-engine → 轮询 engineBuild → /install-local；错误分支处理）
- [ ] 可行性分析 §5.6 回填；git commit + push
