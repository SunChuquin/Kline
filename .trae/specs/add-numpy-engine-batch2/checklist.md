# Checklist

- [ ] engine.yml 仅 workflow_dispatch 手动触发（不得被 push 触发），与 build.yml 的 IPA latest Release 互不干扰
- [ ] wheel 下载使用固定 URL + sha256 校验，校验失败即 CI 失败不产包
- [ ] numpy 解包落点为 `lib/python3.14/site-packages/`，且 CI 打包冒烟（import numpy + 运算断言）通过
- [ ] 全部 numpy Mach-O（.so）经 ldid ad-hoc 重签（与既有引擎 Mach-O 同等授信）
- [ ] files.sha256 覆盖 numpy 全部新增文件（既有 find 全量生成逻辑天然覆盖，抽查确认）
- [ ] manifest schema/apiVersion/layout 字段零改动；仅 build 字段追加 numpy 版本标记
- [ ] App 生产代码零改动（git diff 仅 engine.yml + KlineTests + 文档）；降级矩阵天然覆盖「脚本 import numpy 失败 → scriptError → Swift 降级」
- [ ] 模拟器（iPad mini 5th gen）：含 numpy 引擎时 KlineTests 全绿（含新增冒烟用例）；无 numpy 环境时新用例 XCTSkip、其余全绿
- [ ] 体积增量实测记录（.tipa 更新前后对比 + IPA 体积不变确认）
- [ ] 真机：用户经 TrollStore 更新 Engine.app 后，App 沙盒日志取证 numpy 可用（[PyBridge] 冒烟）
- [ ] 可行性分析 §8.1 第 8 条回填完成（mobile-forge 链路评估结论 + 实测体积）
