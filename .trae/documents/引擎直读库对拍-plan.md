# Python 引擎直读库（主库+增量库）对拍与切换 —— 分阶段计划

> 日期：2026-10-12 · 背景：波次合并后单轮引擎求值 ~360ms，其中约一半是 bars 的
> 「序列化→写盘→读盘→解析」搬运。用户确认方向：**Python 直读主库+增量库，
> 尾部差异补传，对拍硬验证后再切换**。用户明确否决「热复用序列化 payload」方案
> （key 失效错误是静默的）；直读库方案的错误可由对拍暴露，符合项目数据一致性红线。

## Context

- 现状数据流：`KlineChartView.series`（上层从 DatabaseManager 查询构造）→ 波次提交时
  Swift 把 calcData 切片 JSON 序列化 → 临时文件 → 进程内 Python 读回解析 → 求值 → 结果文件 → Swift。
- **Python 必须镜像的 Swift 读库语义**（DatabaseManager.swift）：
  - 主库 `Documents/tdx.db`：`SELECT date, open, high, low, close, vol, amo FROM <表> WHERE meta_id = ? ORDER BY date DESC`
    （[runBarsQuery DatabaseManager.swift:461](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/DatabaseManager.swift#L461-L483)）
  - 增量库 `Documents/tdx_live.db`：`SELECT date, open, high, low, close, vol, amo FROM live_<表> WHERE file = ? ORDER BY date DESC`；
    vol/amo 列**非浮点 → 0**（[LiveDataStore.swift:685-698](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/LiveDataStore.swift#L685-L698)）
  - file ↔ meta_id 映射：主库 `SELECT id, file FROM meta`（file 全库唯一）
  - 合并规则（[fetchPeriodTable DatabaseManager.swift:423-443](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/DatabaseManager.swift#L423-L443)）：
    增量库该 file 全部行 ∪ 主库该 meta_id 中「增量没有该 date」的行；**同 date 增量优先**；整体 date 降序。
  - 增量库不可用 / 未覆盖该 file / 该表无行 → 纯主库路径。
  - 周期表：daily/weekly/monthly/quarterly/yearly（增量库 `live_` 前缀，LiveDataStore.periodTables）。
- 已知一致性问题（对拍要暴露的对象）：内存 `series` 可能比库新（当日实时 bar 落库时序、
  热刷新窗口）。阶段1不猜、实测差异；阶段2按差异形态决定补传内容。

## 阶段1：对拍模式（本轮交付，不动生产求值路径）

1. `Kline/PyScripts/tdx_eval.py`：
   - 新增 `load_bars_from_db(cfg)`：sqlite3 标准库直读，逐条镜像上述语义
     （只读打开 `file:...?mode=ro`；主库缺表 → 空；增量库缺失/缺表 → 纯主库）。
   - 新增对拍：`input["db"]` 存在时，读库组装 vs Swift 传入 `input["bars"]` 逐字段对比
     （容差 1e-9），结果挂 `kline_result["audit"]`：`{db_rows, swift_rows, equal, first_diff, date_span}`。
   - **求值输入不变**（仍用 input["bars"]）——阶段1只观测，不影响任何曲线。
2. `Kline/Data/DatabaseManager.swift`：新增 `dbAuditContext(metaId:table:)` →
   `{main: 主库路径, live: 增量库路径|null, file: file|null}`（复用 private fileForMetaId）。
3. `Kline/Python/PyTDXFormulaBridge.swift` + `Kline/Chart/IndicatorPipeline.swift`：
   波次提交附带 dbAudit 段（组级别：metaId + 周期表名）；decode 读 audit →
   `DebugLogger` 落一行 `[PyTDXBridge] 对拍 <表> 行数X/Y 一致/首差…`。
4. `scripts/verify_tdx_eval.py`：PC 端造 mini main.db + live.db（含同 date 冲突、
   主库较新行、增量缺失回落）断言 Python 组装 == 期望 && audit.equal == true。

## 阶段2：切换（对拍真机全绿后另开工单）

- 求值输入改为「Python 读库组装 ⊕ Swift 补传尾部实时 bar（tail）」；
  Swift 不再传全量 bars（序列化仅剩 tail 几根）。
- 预期单轮 360ms → ~100ms。

## 边界与稳定性

- 对拍失败（audit.equal=false）**不阻断求值**：曲线照常（输入仍是 Swift bars），
  仅日志标红——阶段1零风险。
- 引擎未装/库缺失 → db 段缺路径，Python 跳过对拍（audit 缺省），行为同现状。
- 对拍日志量：每 call 一行标量（行数/布尔/首差下标），无库内容。

## 验收清单

- [x] PC 冒烟：合并语义用例全过（含同 date 冲突、主库较新、增量缺失）
- [ ] CI 构建成功 + 真机部署（前台阻塞闭环）
- [ ] 真机日志：正常浏览/切周期/实时更新后 audit 全绿；如有差异逐条归因（预期：实时 bar 尾差）

## Critical Files

- `Kline/PyScripts/tdx_eval.py`（db reader + audit）
- `Kline/Data/DatabaseManager.swift`（dbAuditContext）
- `Kline/Python/PyTDXFormulaBridge.swift` / `Kline/Chart/IndicatorPipeline.swift`（波次附 db 段）
- `scripts/verify_tdx_eval.py`（PC 合并语义用例）
