# Checklist

- [x] engine.yml 仅 workflow_dispatch 手动触发（不得被 push 触发），与 build.yml 的 IPA latest Release 互不干扰
- [x] wheel 下载使用固定 URL + sha256 校验，校验失败即 CI 失败不产包（engine.yml run 37508185511 实证：sha256 不符即 fail-fast）
- [x] numpy 解包落点为 `lib/python3.14/site-packages/`，且 CI 打包冒烟通过（结构冒烟 vtool 验 .so 平台 + numpy/__init__.py 存在；import + 运算断言由模拟器 KlineTests 承担——CI macos runner 无法执行 iOS .so，Task 2.3 已注明调整）
- [x] 全部 numpy Mach-O（.so）经 ldid ad-hoc 重签（engine.yml 步骤顺序：装 wheel → ldid 全签 find Mach-O 一次覆盖；tipa 内 19 个 .so 全部在签）
- [x] files.sha256 覆盖 numpy 全部新增文件（实测 CI 产物：923 条 numpy 条目，抽查 `_multiarray_umath.cpython-314-iphoneos.so` sha256 命中）
- [x] manifest schema/apiVersion/layout 字段零改动；仅 build 字段追加 numpy 版本标记（实测 CI 产物 manifest.json：`"build": "beeware-3.14-b11+numpy-2.5.3"`，其余字段与旧包逐字一致）
- [x] App 生产代码改动最小化（numpy 基建本身零改动；另含用户指令的独立 feature「更新引擎」行 = GitHubRemoteUpdate.swift 通用 fetchRelease 抽取 + LocalUpdateView.swift 第三行 + PythonEngineHost.installedEngineBuildNumber，已模拟器验证 + 37/37 全绿）；降级矩阵天然覆盖「脚本 import numpy 失败 → scriptError → Swift 降级」
- [x] 模拟器（iPad mini 5th gen，54291852，GUI 可见）：含 numpy 引擎 KlineTests 37/37 全绿（含 PyBridgeNumpySmokeTests import numpy + mean/dot/max/dtype 断言，Passed 0.56s）；无 numpy 环境 XCTSkip 逻辑见用例实现（版本钉 2.5.3）
- [x] 体积增量实测记录（KlineEngine .tipa 22.0MB → 28.4MB，+6.4MB；IPA 不含引擎，体积不变——#501 8,170,128 vs #500 8,160,234 字节，差异为更新引擎行代码）
- [x] 真机：用户经 TrollStore 更新 Engine.app，App 沙盒日志取证（iPad mini 4 klinehttp：`发现新引擎 #9（当前 #7）` → 双 sha256 校验通过 → TrollStore 完整流式送装 28MB → 引擎加载 dlopen 24.2ms / Py_Initialize 112.2ms；numpy 标记终验 = 更新引擎行绿勾 `最新#9 当前 #9` / Python Engine Lab `v3.14.7（beeware-3.14-b11+numpy-2.5.3，api=1）`）
- [x] 可行性分析 §8.1 第 8 条回填完成（mobile-forge 半退役/PyPI 无 iOS wheel 证伪 → cibuildwheel 4.3.0 + PR#28759 补丁自建定案；12 轮本机 + 3 轮 CI 实证坑；体积实测 +6.4MB 远小于预估）
