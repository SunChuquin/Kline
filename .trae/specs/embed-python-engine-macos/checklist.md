# Checklist

- [x] 引擎缓存脚本单源双变体：一次 beeware 下载产出 device/ + sim/ 两份合并树；幂等、`--force` 可重做、landmark 冒烟不过不进缓存
- [x] Run Script 构建阶段平台→变体映射正确（iphoneos→device、iphonesimulator→sim），缓存存在即嵌入，GUI 构建同样生效
- [x] `KLINE_SKIP_ENGINE_EMBED=1` 可强制跳过；条件不满足时跳过且构建不失败
- [x] 拷贝幂等（先清后拷），重复构建不留脏文件
- [x] Windows 路径硬约束保持：CI（build.yml）产物结构性不含引擎；engine.yml / build.yml 未改动
- [x] 模拟器构建嵌入模拟器 slice：iPad mini 5 模拟器上加载成功（dlopen + Py_Initialize + sys.version 回读，冒烟测试程序化验证）
- [x] 模拟器上实验①（dlopen/init）、②（冷启动 + 150 根 MA/EMA 计时）、③（吞吐）进程内跑通，数字可读（实验按钮 = 同一宿主方法 runScriptCapturingOutput，链路已程序化验证；页面现象用户已复核确认 2026-10-06）
- [ ] 真机构建嵌入真机 slice：部署启动正常，加载链路同模拟器验证通过（结构性验证已过：device 变体嵌入正确、arm64 dylib；物理真机端到端待用户连接真机验收）
- [x] 内嵌引擎状态机四态正确，来源识别为内嵌（随包）且优先于 Engine.app
- [x] apiVersion 配对校验对内嵌引擎生效（区间 [1,1]）
- [x] 内嵌引擎损坏（manifest 不可读 / dylib 缺失）时文案正确（提示重新构建部署，非 TrollStore 卸载重装）
- [x] 无内嵌环境回退 Engine.app 行为与 Phase-0 完全一致；无引擎时 App 全功能无感
- [x] KlineTests 单测通过（resolve 路径解析 / manifest 解码 / 内嵌布局定位 / 加载冒烟；7 通过 / 0 失败 / 0 跳过）
- [x] macOS 闭环部署成功：构建 → 安装 → 启动 → git 提交推送一条龙非零退出检查
- [x] 引擎版本常量核对一致（prepare_engine_cache.sh 常量 / PythonEngineHost.tipaFileName / beeware Release tag）
- [x] EngineCache/ 已入 .gitignore，引擎产物不入库
