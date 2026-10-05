# Tasks

- [ ] Task 1: PythonEngineHost 引擎来源抽象（embedded 优先、Engine.app 回退）
  - [ ] 1.1 新增 `PythonEngineSource { embedded, engineApp }` 枚举与 `locateEngineDir() -> (path, source)?`：内嵌判定 = `Bundle.main` 下 `KlineEngine/manifest.json` 存在；否则走现有 `/var/containers/Bundle/Application` 扫描
  - [ ] 1.2 `status()` / `engineManifest()` / `loadEngine()` / `runScriptIsolated()` 切换到 `locateEngineDir()`；`corrupted` / `notInstalled` 文案按来源参数化（内嵌 → 提示重新构建部署；Engine.app → 保持 TrollStore 卸载重装提示）；`apiVersion` 区间校验两种来源一致
  - [ ] 1.3 KlineTests 新增单测：`resolve()` 路径解析（无前缀直拼 + `Engine.app/` 前缀剥离）、`EngineManifest` 解码、内嵌布局定位（临时目录注入模拟 bundle 布局）
- [ ] Task 2: PythonEngineLabView 状态区展示引擎来源
  - [ ] 2.1 状态区新增「引擎来源」行：内嵌（随包）/ Engine.app / —；引擎路径行随来源展示实际目录
- [ ] Task 3: pbxproj 新增 "Embed Python Engine" Run Script 构建阶段
  - [ ] 3.1 新增 `PBXShellScriptBuildPhase`（新 UUID）并追加到 Kline target `buildPhases` 末尾（Resources 之后，Xcode 签名之前执行）；`alwaysOutOfDate = 1`
  - [ ] 3.2 脚本逻辑：`iphoneos → ${SRCROOT}/EngineCache/device`、`iphonesimulator → ${SRCROOT}/EngineCache/sim`、其余平台跳过；门禁 = 变体目录存在 且 `KLINE_SKIP_ENGINE_EMBED != 1`（缓存存在即嵌入，GUI 构建同样生效）；先 `rm -rf` 目标再 `cp -R`（幂等）；不满足条件输出跳过原因并 exit 0
- [ ] Task 4: 引擎缓存准备与部署闭环集成
  - [ ] 4.1 新增 `scripts/prepare_engine_cache.sh`：置顶常量 BEEWARE_TAG=3.14-b11 / PYTHON_VERSION=3.14.7 → 拼出 beeware Release URL 下载缓存到 `EngineCache/beeware/` → 真机与模拟器各产出一份合并树（`EngineCache/device/`、`EngineCache/sim/`：slice 内 `lib-*/python3.14` 防御式定位，合并共享 stdlib，镜像 engine.yml 逻辑）→ 生成 schema v1 manifest（layout 相对 KlineEngine/ 无前缀）→ stdlib landmark 冒烟（encodings/__init__.py、os.py、lib-dynload）→ 清理 beeware 残留 `_CodeSignature`；幂等（变体目录存在跳过）、`--force` 重做
  - [ ] 4.2 `kline_deploy_mac.sh` 集成：构建前（模拟器与真机目标都）执行准备脚本；失败 → 警告 + 继续无引擎部署（不阻断）；未设 `KLINE_SKIP_ENGINE_EMBED` 才执行
  - [ ] 4.3 `.gitignore` 追加 `EngineCache/`
- [ ] Task 5: 验证闭环
  - [ ] 5.1 `prepare_engine_cache.sh` 单独跑通：双变体就位、幂等跳过、`--force` 可重做、landmark 冒烟
  - [ ] 5.2 模拟器验证（iPad mini 5 模拟器）：构建产物含 `KlineEngine/`（sim 变体）；实验室页状态=已安装（来源=内嵌（随包））→ 加载引擎（dlopen + Py_Initialize 计时数字可读、sys.version 回读）→ 实验①②③进程内跑通
  - [ ] 5.3 真机部署（`kline_deploy_mac.sh` 真机目标）：产物含 `KlineEngine/`（device 变体）、安装启动正常、加载链路同 5.2 验证
  - [ ] 5.4 回归检查：KlineTests 全绿；无引擎环境（未跑准备脚本）构建降级无感；CI 结构性检查（无 EngineCache 的构建产物不含 `KlineEngine/`）；engine.yml / build.yml 零改动

# Task Dependencies

- Task 2 依赖 Task 1（UI 读取来源抽象）
- Task 3、Task 4 相互独立，且与 Task 1/2 独立可并行
- Task 5 依赖 Task 1~4 全部完成
