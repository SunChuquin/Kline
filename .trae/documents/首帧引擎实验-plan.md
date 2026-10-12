# 首帧指标计算切换 Python 引擎 —— 真机体验验证轮计划

> 日期：2026-10-12 · 背景：真机实验④实测稳态 median 72.5ms ≥ 33ms，按分档表结论为「红线维持」；
> 用户拍板**覆盖该结论做真机体验验证轮**：首帧计算切引擎、原 Swift 实现注释禁用（不删除），
> 待用户真机反馈后再决定原 Swift 首帧计算代码的最终去留。

## Context

- 首帧指标计算链路：`KlineChartView` → `recomputeMainCurves`（主图）/`recomputeSub`（副图）前台近似求值，
  内部调 `TDXFormulaEngine.evaluate`（lexer→parser→TDXEvaluator，TDX 公式 DSL，~25 个函数）。
  注意：**走的是 TDX DSL，不是 MyTT 固定函数**；实验④的 mytt 路径只代表同量级的桥接开销。
- 后台正确预计算（`startPrefetch`→`evaluatePrefetch`→`commitPrefetch`，增量状态机）**保持 Swift 不动**：
  它不是首帧链路，且天然兜底——引擎路径任何失败，指标仍由后台 Swift 补齐（稳定性保障）。
- 缓存恢复路径（ChartCacheStore 命中）不动：那是缓存不是计算。
- VOL/AMO 副图分支不动：纯数据切片 + ChartSeries.ma，非公式求值。
- 桥接约束：`blockingCall` 主线程 assert 崩溃 → 前台求值必须改为「主线程收集请求 → Task.detached 后台
  blockingCall → 主线程回填」，用代数 token 防过期。

## 方案

**Swift 保留解析与样式组装（渲染保真零风险），Python 侧只做数值求值**：

1. `Kline/PyScripts/tdx_eval.py`（新增，纯标准库、不 import numpy——避免 A8 上 ~2s 的 numpy import 进用户链路）：
   输入 `{bars:{c,h,l,o,v,a}, requests:[{id, stmts:[{n,o,e}]}]}`（e=AST 序列化节点），
   输出 `{ok, results:[{id, ok, lines:[{n, v(非有限值→null), d(SAR方向)]}], error}`。
   逐函数镜像 TDXEvaluator 非增量语义：除零→0、比较 NaN→0、and/or NaN≠0→真、
   EMA/SMA/DMA/SAR 递归 NaN 跳过播种、MA/HHV/LLV/STD/COUNT/AVEDEV 窗口 NaN 跳过、SUM(X,0) NaN 不推进。
2. `Kline/Python/PyTDXFormulaBridge.swift`（新增）：TDXExpr→JSON AST 序列化；后台线程
   `blockingCall(tdx_eval)`；解码回 `[TDXOutputLine]`，样式（DOTLINE/POINTDOT/STICK/COLORSTICK/NODRAW/
   COLORXXX/LINETHICKn/Ln）与 NOTEXT_ 前缀、SAR markerDirections 全部 Swift 侧组装（规则与原
   TDXEvaluator.applyOptions 一致，Python 不感知样式）。
3. `Kline/Chart/IndicatorPipeline.swift`（改造）：
   - `recomputeMainCurves`：原 `for entry in entries { curves += mainRows(...) }` 前台 Swift 求值**注释禁用**，
     换引擎路径——同步复用 mainRows 的单元缓存结构收集过期单元 → 一次 Python 批量 call →
     完成回调回填 `mainCache.rows` → 重新组装 → `commitMainCurves`（原提交+写回逻辑抽公共函数，
     内容逐行保留）。引擎未就绪 → ensureOnce + 0.25s 轮询重试（上限 10s）。
   - `recomputeSub`：custom/system 两分支的 `TDXFormulaEngine.evaluate` **注释禁用**换引擎路径；
     VOL/AMO 分支保持 Swift 同步路径。完成回调走 `commitSubCurves`（防空保护+写回，逐行保留）。
   - 代数 token：`engineMainGen` + `engineSubGens[ObjectIdentifier(m)]`，完成时校验防配置中途变更的旧结果覆盖。
   - 拖拽中完成回调只回填缓存不提交曲线（拖拽结束后 recompute 自动从缓存组装）。
4. `Kline/App/KlineApp.swift`：`init` 追加 `KlinePythonBridge.shared.ensureOnce()`——启动后台预热
   （A8：dlopen ~20ms + Py_Initialize ~130ms，在用户打开图表前完成；纯 stdlib 无 numpy 长等待）。

## 边界与稳定性

- 引擎未安装/损坏/超时/脚本报错 → 指标短暂空缺，**Swift 后台预计算照常补齐正确曲线**（既有机制不动）；
  缓存命中的 (标的, 周期) 完全不受影响。
- 引擎失败单元的缓存 key 不写入 → 下次 recompute 自动重试（比原 Swift 失败即标记略强，防呆）。
- 后台 Swift 预计算覆盖末端推进后仍会用「正确值」替换前台引擎结果（EMA 等递归指标
  前台近似与全量正确值本就有微小差异）——与改造前行为语义一致。
- 副图 custom 公式解析失败：走防空保留旧曲线（原实现会 fallthrough 到系统公式分支，语义略收紧、更安全）。
- 全量 force 重算（联动隔离首算 / bgCovered+force）区间可能达全历史，纯 Python 循环比 Swift 慢，
  A8 上可能数百 ms~秒级——本实验轮可接受，真实感受即实验目的。

## 验收清单

- [x] tdx_eval.py PC 冒烟：MA/EMA/SMA/REF/HHV/CROSS/IF/SAR/除零/NaN 语义逐例断言通过
- [ ] CI 构建成功 + TrollStore 部署（build_and_deploy.py 退出码 0/6/7）
- [ ] 真机体验：重启 App → 打开标的 → 指标曲线由引擎算出（[PyBridge] tdx_eval.py 完成日志 + 延迟感受）
- [ ] 用户反馈后决定原 Swift 首帧计算代码去留

## Critical Files

- `Kline/PyScripts/tdx_eval.py`（新增）
- `Kline/Python/PyTDXFormulaBridge.swift`（新增）
- `Kline/Chart/IndicatorPipeline.swift`（recomputeMainCurves / recomputeSub 改造）
- `Kline/App/KlineApp.swift`（预热）
- `scripts/verify_tdx_eval.py`（PC 冒烟，新增）
