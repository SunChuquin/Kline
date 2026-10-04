# Checklist

## 行为零变更（用户硬约束）

- [x] Swift 侧 diff 仅含：可见性关键字（private → internal）、纯函数抽取的逐行搬移、原方法改为委托调用；无算法改动（含 ProbeItem 逐字收编，云构建证实编译通过）
- [x] 网络行为、DB 写入路径、指标计算结果、UI 行为、CI 配置零改动
- [x] 未引入任何第三方依赖（Python 脚本纯标准库；Swift 无新包）
- [x] 设备构建部署成功，冒烟通过（图表/指标、补缺口页面、条件单页面）—— v1.0.2 build 448，用户真机冒烟确认无问题

## KlineTests target

- [x] `project.pbxproj` 新增 unit test bundle target，三个 build phase 齐备，TEST_HOST 配置正确（静态自检：括号配平、GUID 唯一、区段归属逐项对照 KlineUITests）
- [x] `@testable import Kline` 可用（占位测试通过）—— CI 模拟器 run=37181794110，2 tests 0 failures
- [x] `Fixtures/*.json` 作为 target 资源随 bundle 打包，`Bundle(for:)` 可读 —— testPlaceholderFixtureIsBundled 通过
- [x] 主 Kline target 构建产物无变化（GitHub Actions run=37177824000 编译通过并部署成功）

## golden 生成（src/contract_golden.py）

- [x] 脚本纯标准库，通过 import 复用 `tdx_parser.py` / `live_db_builder.py` / `check_indicators.py` 既有函数，未复制口径逻辑（唯一例外：calibration 无 Python 侧实现，按 GapBackfill.calibrate 常量镜像并在脚本头注释声明）
- [x] 无网络调用、无随机源、无仓库外数据依赖（东财/腾讯真实抓包样本于 2026-10-04 内置）
- [x] 连续运行两次输出 byte 级一致（四份 fixtures MD5 一致）
- [x] 产出四份 fixtures：period_aggregation（7 组）/ quote_parsing（东财 5 标的 + 腾讯 2 段 + calibration 9 组）/ secid_mapping（276 条 + knownDivergence）/ indicator_templates（31 份）

## 周期聚合契约

- [x] 合成序列覆盖：跨年、闰年 2/29、季切换、月末/年末最后交易日、停牌空档、单日周期
- [x] Swift 侧与 golden 逐周期桶逐字段一致断言已就位（date=周期首个交易日 / OHLC / vol / amo；amo 1e-6 绝对容差，vol 精确相等）—— 运行验证待 Mac
- [x] 停牌周期两侧均无 bar 断言已就位 —— 运行验证待 Mac

## 取数口径契约

- [x] 东财快照：decodeChunk ↔ golden 逐字段一致断言就位（f17开/f15高/f16低/f2收/f5量/f6额/f124）
- [x] 腾讯 newfqkline：行解析 ↔ golden 断言就位，**开-收-高-低顺序陷阱用例置顶**
- [x] 量纲自校准：量比吸附 1/100、额折算、不符丢弃用例均与 golden 对拍就位
- [x] secid 映射：universe_secids 全量与 golden 一一相同；knownDivergence 条目（27#/62#/102# Python=None vs Swift 覆盖表）以「分歧持续可见」断言编码

## 模板解析契约

- [x] 全 corpus（31 份 .tdx）NAME/SCOPE/GROUP/FORMULA 一致断言就位
- [x] 非 KIND=TECH 模板以 `swiftExpected: rejected` 显式编码；corpus 无非 TECH 条目，附加 2 条合成负控守住拒载分支（已标注非 fixture 数据）

## 测试质量与验证

- [x] 断言失败输出「字段名 + 两侧值 + fixture 键」
- [x] `xcodebuild test`（KlineTests scheme）全绿，用例数已记录 —— **26 tests, 0 failures**（24 契约 + 2 占位），GitHub Actions 模拟器 run=37181794110
- [x] 既有 KlineUITests 编译不受影响 —— 测试构建中该 target 编译通过（-skip-testing 仅跳过执行）
- [x] tasks.md 所有任务已勾选
