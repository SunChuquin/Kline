# Checklist

## 行为零变更（用户硬约束）

- [ ] Swift 侧 diff 仅含：可见性关键字（private → internal）、纯函数抽取的逐行搬移、原方法改为委托调用；无算法改动
- [ ] 网络行为、DB 写入路径、指标计算结果、UI 行为、CI 配置零改动
- [ ] 未引入任何第三方依赖（Python 脚本纯标准库；Swift 无新包）
- [ ] 设备构建部署成功，冒烟通过（图表/指标、补缺口页面、条件单页面）

## KlineTests target

- [ ] `project.pbxproj` 新增 unit test bundle target，三个 build phase 齐备，TEST_HOST 配置正确
- [ ] `@testable import Kline` 可用（占位测试通过）
- [ ] `Fixtures/*.json` 作为 target 资源随 bundle 打包，`Bundle(for:)` 可读
- [ ] 主 Kline target 构建产物无变化

## golden 生成（src/contract_golden.py）

- [ ] 脚本纯标准库，通过 import 复用 `tdx_parser.py` / `live_db_builder.py` 既有函数，未复制口径逻辑
- [ ] 无网络调用、无随机源、无仓库外数据依赖（抓包样本内置）
- [ ] 连续运行两次输出 byte 级一致（git diff 为空）
- [ ] 产出四份 fixtures：period_aggregation / quote_parsing / secid_mapping / indicator_templates

## 周期聚合契约

- [ ] 合成序列覆盖：跨年、闰年 2/29、季切换、月末/年末最后交易日、停牌空档、单日周期
- [ ] Swift 侧与 golden 逐周期桶逐字段一致（date=周期首个交易日 / OHLC / vol / amo，容差 1e-6）
- [ ] 停牌周期两侧均无 bar

## 取数口径契约

- [ ] 东财快照：decodeChunk ↔ golden 逐字段一致（f17开/f15高/f16低/f2收/f5量/f6额/f124）
- [ ] 腾讯 newfqkline：行解析 ↔ golden 一致，**开-收-高-低顺序陷阱用例置顶**
- [ ] 量纲自校准：量比吸附 1/100、额折算、不符丢弃用例均与 golden 一致
- [ ] secid 映射：universe_secids 全量 + 特例段（62#/102#、hk）与 golden 一一相同

## 模板解析契约

- [ ] 全 corpus（Kline/Indicators/*.tdx）NAME/SCOPE/GROUP/FORMULA 一致
- [ ] 非 KIND=TECH 模板以 `swiftExpected: rejected` 显式编码，Swift 断言 parse 返回 nil

## 测试质量与验证

- [ ] 断言失败输出「字段名 + 两侧值 + fixture 键」，可定位
- [ ] `xcodebuild test`（KlineTests scheme）全绿，用例数已记录
- [ ] 既有 KlineUITests 编译不受影响
- [ ] tasks.md 所有任务已勾选
