# 方案 C（缠论计算截到可见右缘 endIndex）A/B 实测报告

日期：2026-11-14　目录：`2026-11-14/chan-lookahead/work/`
脚本：`ab_test_v2.py`（固定截断点 + 追加改写）、`k_sweep.py`（每标的上百随机截断点）、`export_series.py`
产物：`reportv2_*.json`、`ksweep.json`、`v2_out.txt`

## 0. 结论速览

1. **笔（bi）的内部前缀 100% 稳定**：536 个截断点上，凡是完全落在 `[0..k]` 内的笔，逐字段（fromKlc/toKlc/beginVal/endVal/fromKlu/toKlu）与全量结果**完全一致，最大偏差 0.000**。
2. **段与中枢不是 100% 稳定**：段 14/536（2.6%）、中枢 21/536（3.9%）的截断点会出现"内部项丢失/改写"，实测影响区域最深达 **58 笔 / 606 根 K 线**。但这些差异**全部落在「最后一个 confirmed=False 的段」之后**（17/17 反例验证通过）。
3. **因此「全量一次 + 纯裁剪 + 尾部 UC」不等价**：
   - 笔：56.9% 的截断点完全一致；36.3% 需要在右缘**多补一笔半截笔**；6.9% 需要**丢掉最后一笔**。
   - 段/中枢：在 399001 早期数据上最多 10% 的截断点，尾部一整段会被重新划分，段内中枢整体重构。
4. **但差异严格限制在尾部**：安全的增量边界 = **最后一个 `confirmed=True` 的段**。截断点之后的区域需要重算，区域大小 = 尾部未确认段（实测 4~58 笔），不是全历史。
5. **结论**：方案 C **不能**用"纯裁剪全量结果"实现；但可以用"全量算一次 + 只重算尾部未确认段"实现，成本 **O(尾部)** 而非 O(n)。若不想改 chan.py 的增量接口，则每次 endIndex 变化仍需 O(n) 重算（实测 Mac 上 9k 根 ≈ 20.5 ms，线性 ≈ 2.25 µs/根；App 内拖拽已延后到抬手才重算，一次手势只付一次）。

## 1. 数据与方法

真实行情来自模拟器 App 容器 `Documents/tdx.db`（日线），导出为 `daily_<meta_id>.json`：

| 标的 | meta_id | 根数 | 区间 |
|---|---|---|---|
| HSI 恒生指数 | 11 | 9099 | 19900102–20261113 |
| 999999 上证指数 | 2085 | 8763 | 1991–2026 |
| 000002 万科Ａ | 2087 | 8517 | 1991–2026 |
| 399001 深证成指 | 3581 | 8718 | 1991–2026 |

计算配置与 App 完全一致（`tdx_eval._CHAN_CLV1`）：`bi_algo=clv1, bi_min_gap=3, bi_fx_check=skip, bi_end_is_peak=False, bi_last_unconfirmed=True, include_segments/centers/seg_centers=True`。

对比口径：**按内容键匹配**（笔=`fromKlu`，段=`startBi`，中枢=`beginLine`），避免"某个中枢消失导致后续序号整体前移"被误判成大面积改写。逐字段比对：

- 笔：`dir, fromKlc, toKlc, beginVal, endVal, fromKlu, toKlu`
- 段：`dir, startBi, endBi, beginVal, endVal, biCount`
- 中枢：`beginLine, endLine, beginKlu, endKlu, zg, zd, gg, dd, lineCount`

## 2. 问题一：截断等价性

### 2.1 内部项不一致统计（480 个随机 k + 56 个固定 k）

| 标的 | 笔 异常 | 段 异常 | 中枢 异常 | 段/中枢最大偏差 |
|---|---|---|---|---|
| HSI | 0/120 | 0/120 | 1/120 | 0（仅"缺失"，无值偏差） |
| 999999 | 0/120 | 2/120 | 4/120 | 段 141.13，中枢 179.32 |
| 000002 | 0/120 | 0/120 | 3/120 | 中枢 15.00（仅坐标差） |
| 399001 | 0/120 | 12/120 | 12/120 | 段 3940.87，中枢 741.80 |
| **合计** | **0/480** | **14/480 (2.9%)** | **20/480 (4.2%)** | — |

固定 14 个 k/标的（60%、80%、n-1 + 11 个随机）：笔 0、段 0、中枢 1（999999 k=7223，一个中枢缺失，影响跨度 74 根）。

**结论：笔的内部前缀完全稳定；段/中枢的失败集中在"尾部未确认区域"。**

### 2.2 差异是否都在尾部

对 17 个有异常的中枢/段截断点逐一验证：取**截断侧最后一个 `confirmed=True` 的段**，其 `endBi+1` 记为 `safe_bi`；所有受影响段 `startBi` / 中枢 `beginLine` 均 ≥ `safe_bi`，**17/17 成立**。

实测影响跨度（从 `safe_bi` 到右缘）：

- 段：6~58 笔（399001 早期数据最坏 58 笔）
- 中枢：4~30 笔，换算成 K 线为 **22~606 根**

### 2.3 尾部那一笔的三种形态（480 个 k）

| 形态 | 占比 | 说明 |
|---|---|---|
| `same_bi` | 273/480 (56.9%) | 截断侧末笔 = 全量末笔（含 8 例顺延 1~3 根） |
| `partial_new_bi` | 174/480 (36.3%) | 全量里那一笔跨过右缘，截断侧只有"半截"：起点 100% 一致，终点是全量最终终点的左方（最多差 51 根 / 4592 点） |
| `lost_last_bi` | 33/480 (6.9%) | 全量末笔在 k 处尚未成立（末分型因末根合并K线仍在吸收新 bar 而不存在）；截断侧末笔 = 全量的**前一笔**，100% 成立 |

**对方案 C 的直接含义**：只裁剪全量结果而不重算尾部，会在 43.2% 的截断点上把"右缘那一笔"画错（多一笔 / 少一笔 / 端点位置不同）。

## 3. 问题二：追加新 bar 会改写多大范围

### 3.1 批量追加（7 个 n0 × 追加 1/2/5/20/50/200/500 根 × 4 标的）

| 结构 | 最多改写 | 内部（非末位）改写 | 消失 |
|---|---|---|---|
| 笔 | **1 笔** | 0 组 | 0 |
| 段 | 2 段 | 3~9 组（均为倒数第二段，深度=1） | 3~7 组（尾部段合并） |
| 中枢 | 1 个 | 0 组 | 0~3 组（尾部段重构时成批消失） |

典型量级（n0 取中位、追加 50 根）：

- HSI：425 笔 → 432 笔，改写 0；段 67 → 66，改写 1 + 消失 1；中枢 44 → 45，改写 0。
- 999999：352 → 358 笔，改写 0；段 52 → 52，改写 1；中枢 37 → 38，改写 0。
- 000002：252 → 257 笔，改写 1（仅 `toKlc`）；段改写 1；中枢 34 → 34，改写 0。
- 399001：386 → 389 笔，改写 0；段 52 → 51，改写 1 + 消失 1；中枢 45 → 46，改写 0。

### 3.2 逐根追加（3 个起始点 × 200 步 × 4 标的 = 2400 步）

- 笔：24.5%~42.5% 的步会改写，**永远只改 1 笔，从不同时改 2 笔，内部 0 次**。
- 段：16.5%~33.5% 的步会改写，**最大深度 1**（只涉及最后两段）；消失即"尾部段合并"。
- 中枢：0~0.5% 的步会改写，**最大深度 0**（只改最后一个）。

### 3.3 改写的字段（全量样本，覆盖所有 changed 项）

| 结构 | 改动字段频次 | **从未改动** |
|---|---|---|
| 笔（813） | endVal 633、toKlu 648、toKlc 241 | **fromKlu / beginVal / fromKlc / dir** |
| 段（646） | endVal 645、endBi 188、biCount 188 | **startBi / beginVal / dir** |
| 中枢（23） | endLine 23、endKlu 23、lineCount 23、gg 8、dd 12 | **beginLine / beginKlu / zg / zd** |

即：**时间前进时，存量结构的"起点/骨架"永不改写，只有尾部项的末端顺延**（`toKlc` 是合并K线序号，也是纯尾部派生量）。

### 3.4 反例：尾部未确认段被重新划分，导致多个中枢整体重构

399001，`n0=1569`（上市初期），追加 50 根：

- 旧段 idx12：`startBi=72, endBi=132`，61 笔，`reason=collectleft_find_high`，`confirmed=False`
- 新段：同一区间被拆成 idx12(72-74)、13(75-89)、14(90-96)、15(97-105)、16(106-132)，前四段变为 `confirmed=True`
- 结果：旧中枢 idx5~idx10（`beginLine=75/79/83/93/97/105`）**全部消失**，替换为 `beginLine=78/82/91/98` 的 4 个新中枢（另在右缘新增 1 个 `beginLine=134` 的新中枢），且内部边界改变。例如：
  - 旧 idx7：`beginLine 83..91, klu 992..1097, zg 1283.42, zd 1171.67, ln 9`
  - 新 idx6：`beginLine 82..86, klu 976..1044, zg 1283.42, zd 1228.43, ln 5`（ZD 从 1171.67 变 1228.43）

**触发条件**：最后一根段 `confirmed=False` 且跨度很长（此处 61 笔）；新数据让它被重新切分为多个 confirmed 段，段内中枢全部重建。这是目前唯一会"一次改掉多个中枢"的情形。

## 4. 代码事实核查

### 4.1 `check_fx_valid` / `_clv1_fx_valid`

- 普通路径：[chan.py L369](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L369) `if self.cfg["bi_fx_check"] != "skip" and not last_end.check_fx_valid(klc)`
- CL-V1 路径：[chan.py L526-L528](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L526-L528)
- App 配置 `bi_fx_check="skip"` → **两条分支都不会执行**，所以分型/笔端点不依赖 STRICT 校验。

### 4.2 `_clv1_last_unconfirmed`（末笔顺延）

[chan.py L536-L558](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L536-L558)：从**最后一根 bar 向前**扫，遇到第一根"超过当前端点"的极值就停；只把**最后一笔**的 `toKlu/endVal` 移到那里，并把 `confirmed` 置 False。

- 只动终点、不动起点；只向右移；只作用于最后一笔。
- 与实测吻合：笔的内部项 0 不一致；gap=0 时 8/273 出现 ≤3 根顺延。

### 4.3 `confirmed` 语义：**每次全量重算重新判定，不是"一旦写下就不回退"**

- 笔：[chan.py L605-L608](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L605-L608) 先把所有笔置 `True`，再由 `_clv1_last_unconfirmed` 把最后一笔置 `False` → **纯位置标记**，倒数第二笔在下一根 bar 到来时就会变 `True`。
- 段：`is_sure` 由 `_SegListChan` 构建时决定（`_segments_json` L1296 输出）；`_build_segs` L1283-L1285 **每次新建 `_SegListChan` 全量重建**，没有跨调用状态。
- 中枢：`_zs_lst_of` L1518-L1521 **每次新建 `_ZSList`**，`last_sure_pos=-1, last_seg_idx=0` → `cal` 从第一段重算；`confirmed = zs.is_sure`，由段 `is_sure` 在构造时传入。

### 4.4 chan.py 是否存在"回退/重算前 K 笔"的路径

有，但都是**单次构建内部的尾部回退**，且边界就是"最后一个 confirmed 段"：

- 笔端点：[L516-L519](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L516-L519) 同向更极端分型**替换** `ends[-1]`；从不删除更早的 end。
- 段：[L1114](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1114)、[L1118](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1118) `self.lst.pop()`（`do_init` 丢弃未确认段）；[L1265](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1265) `self.lst = self.lst[:-1]`（`collect_left_seg` 弹掉最后一个未确认段并递归重建）。
- 中枢：[L1503-L1504](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1503-L1504) 弹掉 `begin_bi.idx >= last_sure_pos` 的尾部中枢；`try_combine` L1497-L1500 合并后弹掉。
- 结论：**算法内部的回退边界 = 最后一个 sure 段**，与实测 17/17 一致。

### 4.5 `_chan_cache` / `_bars_fingerprint`

[tdx_eval.py L451-L462](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/tdx_eval.py#L451-L462)：指纹含每列的 `len(seq)` + 和 + 加权和 + 首末值 → **不同截断点一定不同指纹**（4 标的各 5 个 k 实测 `fp_differs=True`）。

[tdx_eval.py L655-L660](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/tdx_eval.py#L655-L660)：缓存是**单槽** `{fp, data}`，`fp` 一变就整段重算 → 方案 C 下每个新的 endIndex 都是一次 O(n) 全量重算。

Swift 侧 [IndicatorPipeline.swift L835](file:///Volumes/home/repositories/Kline2/Kline/Chart/IndicatorPipeline.swift#L835)、[L867](file:///Volumes/home/repositories/Kline2/Kline/Chart/IndicatorPipeline.swift#L867) 的 key 已含 `calcStart|calcEnd`，能区分不同区间（但会累积缓存条目）。

### 4.6 计算耗时（Mac，python3，`tdx_eval._compute_chan` 端到端，含摊平）

| n | 500 | 1000 | 2000 | 4000 | 6000 | 8000 | 9099 |
|---|---|---|---|---|---|---|---|
| ms | 0.97 | 2.06 | 4.06 | 8.56 | 13.29 | 18.02 | 20.49 |

线性 ≈ 2.25 µs/根。App 内拖拽期间不重算（[IndicatorPipeline.swift L689](file:///Volumes/home/repositories/Kline2/Kline/Chart/IndicatorPipeline.swift#L689)），抬手才 `refreshCurves()`（[ChartGestureHandlers.swift L224-L228](file:///Volumes/home/repositories/Kline2/Kline/Chart/ChartGestureHandlers.swift#L224-L228)）。

## 5. 方案 C 最终结论

### 5.1 能否 O(1) 平移

**不能"纯裁剪"，但可以做到 O(尾部)。** 精确等价的重建规则：

1. 基座 = 全量结果中 `toKlu <= k` 的笔 / `endBi <= n_in-1` 的段 / `endLine <= n_in-1` 的中枢。
2. 安全边界 = **最后一个 `confirmed=True` 的段**；该边界之前的结构可直接复用（实测 17/17 反例都在其后）。
3. 边界之后必须重算：
   - 重算末根合并K线（从它自己的 `i0` 到现在，`_clv1_merge` 是流式的）；
   - 重算末尾 1~2 个分型（末根 MK 变化只影响 `len-2` 位置）；
   - 用 `_clv1_build_ends` 从最后一个 sure end 继续，得到 gap ∈ {-1,0,+1}；
   - 对末笔跑 `_clv1_last_unconfirmed`；
   - 用 `_SegListChan` / `_ZSList` 从最后一个 sure 段重建段与段内中枢。
4. 成本 = O(尾段笔数 + 末根 MK 的 bar 数)。实测尾段 6~58 笔；中枢影响 4~30 笔 / 22~606 根。

**若不做增量**：每次 endIndex 变化调用一次 O(n) 全量（就是当前实现的成本），Mac 9k 根约 20 ms；需要真机实测后才能判断是否可接受。

### 5.2 「截断渲染」vs「真截断重算」的具体差异边界

| 情形 | 频率 | 差异 | 需要怎么补 |
|---|---|---|---|
| gap=0 | 56.9% | 一致（8/273 顺延 ≤3 根） | 对末笔跑 `_clv1_last_unconfirmed` |
| gap=+1 | 36.3% | 少一笔"半截笔"；其起点与全量跨缘笔完全一致 | 新增半截笔：起点取全量跨缘笔起点，终点取 `[0..k]` 内最后一个分型再顺延 |
| gap=-1 | 6.9% | 多画一笔（该笔在 k 处尚未成立） | 丢掉全量最后一个 `toKlu <= k` 的笔 |
| 段（尾部） | ≤10%（399001 早期） | 最后未确认段可能被重新切分，最长影响 58 笔 | 从最后一个 sure 段重建 |
| 中枢（尾部） | ≤10% | 未确认段内中枢可能整体重构，最长影响 606 根 / 30 笔 | 随段重建一起重算 |

**纯裁剪方案会出问题的唯一区域就是上表后两行 + 尾部那一笔**；`[0..safe_bi]` 区域在 536 个截断点上零不一致。

### 5.3 实现要点与风险（若走 O(尾部) 增量）

要点：
- 缓存"全量结果 + 最后一个 sure 段的位置"，而不是缓存每个 endIndex 的结果（否则缓存条目按平移步数增长）。
- 需要 chan.py 暴露一个"从 seed 继续"的入口，或至少把 `_clv1_merge` 的末根 MK 状态（`i0/i1/h/l/hi/li`）和 `ends` 末尾暴露给调用方；当前 JSON 已返回 `klc`（含每根 MK 的 fromKlu/toKlu/high/low）与 `segments.confirmed`，信息足够，但重建逻辑要复制一份，**两边必须严格同源**，否则重建结果与全量重算会漂移。
- 渲染侧无需额外钳位：输入截到 k 后，`_chan_line` / `_chan_rails` 的 `min(n-1, …)` 自然落在 endIndex。

风险：
1. **尾笔抖动**：`partial_new_bi` 的终点会随后续 bar 持续右移（实测每次追加 24.5%~42.5% 概率变化 1 笔），这是 UC 的固有语义，不是 bug；但要接受"右缘那根灰色虚线会动"。
2. **段/中枢尾部重构**：一旦尾部未确认段被重新切分，右缘附近可能同时变化多个中枢（实例：399001 n0=1569+50，3 个旧中枢被 1 个新中枢替换，其后中枢前移）。若用纯裁剪，会显示过期结构。
3. **缓存一致性**：`_chan_cache` 单槽 + Swift 侧按区间缓存两套机制并存；增量方案必须保证"缓存基座"与"重算尾部"来自同一次数据版本，否则会出现跨版本拼接。
4. **单调性假设**：本次只测了日线、只测了"向前追加"和"截断"两个方向；换周期（周/月）或换复权口径未验证，结论不能外推。

## 6. 补充：为什么段会动两段、中枢会动多个（机制追问）

### 6.1 段的"最后一段"永远不可能 confirmed

- `_seg_bis_clv1` [L757-L759](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L757-L759)：构造内部笔视图时，把**最后一笔**置 `is_sure=False, used_to_be_sure=False`。
- `_EigenFX.all_bi_is_sure` [L979-L982](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L979-L982)：只要特征序列里有一笔不是 `used_to_be_sure`，整段就不是 sure。
- 因此任何"包含末笔"的特征序列都不可能确认 → `treat_fx_eigen` [L1152-L1153](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1152-L1153) 传入的 `is_sure` 必为 False → **最后一段永远 `confirmed=False`**。

**推论**：稳定边界不可能是"最后一段"，只能是"最后一个 confirmed 段"。这不是实现偏好，是 `confirmed` 的定义决定的。

### 6.2 "动两段"= 末两段（均为未确认）合并成一段

- `_SegListChan.update` [L1101-L1107](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1101-L1107)：`do_init` → `cal_seg_sure` → `collect_left_seg`。
- `collect_left_seg` [L1257-L1266](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1257-L1266)：若最后一段 `confirmed=False` 且其后还有 >2 笔，就 `self.lst = self.lst[:-1]` 弹掉并递归重建。
- `collect_left_as_seg` [L1268-L1278](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1268-L1278)：用 `collect_left_0/1` 造一个 1 笔的尾部 stub（`is_sure=False`）。
- `try_add_new_seg` [L1182](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1182)：只 `append`，**从不原地修改前一段**。

真实实例（HSI `n0=4094, +50`）：

| | idx | dir | startBi | endBi | endVal | confirmed | reason | biCount |
|---|---|---|---|---|---|---|---|---|
| 改前 | 65 | +1 | 415 | 421 | 17328.43 | False | normal | 7 |
| 改前 | 66 | -1 | 422 | 424 | 15948.76 | False | collect_left_0 | 3 |
| 改后 | 65 | +1 | 415 | **431** | **17683.45** | False | collectleft_find_high | **17** |

→ 旧 idx66（3 笔 stub）**并入**旧 idx65；前一段只改 `endBi/endVal/biCount`，`startBi/beginVal/dir` 不变。**是"后一段并入前一段"，不是"前一段被覆盖"。**

同类实例（399001 `n0=3923, +50`）：旧 idx50（380-384，5 笔）+ idx51（385-385，1 笔 stub）→ 新 idx50（380-388，9 笔）。

字段频次（646 个段改写样本）：`endVal 645 / endBi 188 / biCount 188`；`startBi / beginVal / dir` **0 次**。

### 6.3 中枢为什么"动多个"：中枢依附于段，段重切则整段中枢重建

- `_zs_lst_of` [L1518-L1522](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1518-L1522)：每次新建 `_ZSList`；`__init__` [L1435-L1439](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1435-L1439) 里 `last_sure_pos=-1, last_seg_idx=0` → `cal` 的弹尾循环 [L1503-L1504](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1503-L1504) 在全新实例上是空操作，**每次都从第一段重算**。
- `_ZSList.cal` [L1505-L1514](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1505-L1514)：**以"段"为单位**，对每段执行 `clear_free_lst()` + `add_from_line_range(bi_lst[seg.startBi.idx : seg.endBi.idx+1], seg.dir, seg.is_sure)`。
- `_centers_json` [L1525-L1546](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/chan.py#L1525-L1546)：`beginLine/endLine` 是**笔索引**，`confirmed = zs.is_sure`。

**所以中枢不是"跟着笔走"，而是"跟着段的边界走"**：一段的 `startBi/endBi` 一变，该段区间的中枢就从空列表重建一次 → 旧中枢消失、新中枢出现；后续段的段号再整体前移。

399001 `n0=1569, +50` 实例：旧段 idx12（`startBi=72, endBi=132`，61 笔，`collectleft_find_high`，unsure）在 50 根后被切成 idx12(72-74)、13(75-89)、14(90-96)、15(97-105)、16(106-132) 四个 confirmed 段 + 尾部 unsure 段；对应旧中枢 `beginLine=75/79/83/93/97/105` 全部消失，替换为 `78/82/91/98` 四个新中枢（如 ZD 1171.67 → 1228.43），另在右缘新增 `beginLine=134`。

**统计（4 标的 × 333~346 个 n0 × 追加 50 根 = 1333 组）**：

- 多中枢改写（≥2 个）**23 次，占 1.73%**；分布：2 个 15 次、3 个 4 次、5 个 2 次、6 个 2 次。
- 多中枢时：`max_unsure_bi` 中位 13、未确认区总长 `unsure_bars` 中位 **454 根**。
- 条件概率：`max_unsure_bi ≥ 20` → 10/87（**11.5%**）；`≥ 40` → 2/10（**20%**）。
- 逐根追加 600 步/标的：多中枢改写 **0/2400**（只在追加 50 根这种"确认点跨过一整段"时触发）。

### 6.4 能否"确认即冻结、严格只改最后一个"

实测"confirmed=True 的项是否真的不变"（4 标的，追加方向 600 步/标的 + 截断方向 120 个 k/标的）：

| 方向 | confirmed 段异常 | confirmed 中枢异常 |
|---|---|---|
| **时间前进（追加）** | **0 / 144,471** | **0 / 118,213** |
| **截断（k < n）** | 66 / 26,062（0.25%） | 109 / 21,323（0.51%） |

结论：

1. **时间前进方向，"确认即冻结"与参考实现 100% 等价**（17 万+ 次比对零偏差）。冻结本身不会引入偏差。
2. **截断方向不成立**：`confirmed` 是相对"数据末端"判定的。全量里 `confirmed=True` 的段，在 `bars[0..k]` 上可能只是 `collectleft_find_high`、`confirmed=False`（实例：HSI `k=7929`，`full` 段 startBi=801 confirmed=True；`trunc` 同一起点 confirmed=False、endBi 803）。所以 Plan C 的冻结边界必须用"**在 k 处**已 confirmed 的段"，而这个信息只能由 k 处（或至少到确认点）的计算得到。
3. **"动两段"是算法结构必然**（最后一段永不 confirmed，其边界随数据推进被重新确认）；**"动多个中枢"是结构（中枢依附段边界）+ 实现（每段 `clear_free_list` 重建）共同结果**。改成增量也只能把边界压到"最后一个 sure 段之后"，压不到"最后一个中枢"。

---

## 7. 为什么同一时刻会有多个「未确认段」

### 7.1 所有追加段的入口（唯一原语 `try_add_new_seg` L1162-L1186，`lst.append` 在 L1182）

| 入口 | 行号 | is_sure | 说明 |
|---|---|---|---|
| A 特征序列确认 | L1147-L1160（L1152-L1153） | `is_true and fx_eigen.all_bi_is_sure()` | 正常路径；特征序列含未确认笔时 false |
| B `split_first` 首段拆分 | L1164-L1176 | 一次 append **两个 false** | 仅 `len(lst)==0 and end_bi_idx>=3` 且 L1168-L1171 成立；头部 2 个占位段的唯一来源，全程只触发一次 |
| C `collect_first_seg` | L1199-L1215 | false | `0seg_find_high/low` + `collect_left_as_seg`，最多 1 实 + 1 占位 |
| D `collect_left_seg_peak_method` | L1217-L1235（L1222/L1228，递归 L1235） | false | 每轮推进 ≥3 笔（L1221/L1227 门槛），**可连续追加多个** |
| E `collect_segs` 强制分支 | L1242-L1253 | false | `collectleft_find_high_force / low_force` |
| F `collect_left_as_seg` | L1268-L1278 | false | 末尾占位 `collect_left_0 / collect_left_1`，每次最多 1 个 |

收缩路径：`do_init` L1109-L1118（每次 update 开头弹掉**所有尾部**未确认）、`collect_left_seg` L1262-L1266（弹掉最后一段后递归）。
L516-L519 的 `ends[-1]` 替换属于**笔级** `_clv1_build_ends`，不构造段对象，只改变线段的输入端点。

### 7.2 不变量

- **未确认段 = 头部连续段 ∪ 尾部连续段，中间为 0**。依据：`do_init` L1110-L1114 在每次重建前弹光尾部未确认；重建期间只 `append`（L1182）；头部只有 `len==0` 时的 B/C 两条路径能产生，之后只在其后追加已确认段。实测 0/2612 例外。
- **头部 ≤2 是硬上界**（B 路径一次两个；C 路径最多 1 实 + 1 占位），且创建后永不转 true（`do_init` 只弹尾部）。
- **尾部没有常数上界**：D 路径每轮把 `last_seg_end_bi` 至少推进 3 笔，理论上限 ≈ floor(剩余笔数/3)+1，随数据线性增长。
- **实测最大 |未确认段| = 6**：999999 `batch n0=3067+1` 尾部 6 段；399001 `batch n0=3051+1` 尾部 6 段；HSI `batch n0=909+200` 头部 2 + 尾部 4 = 6。

### 7.3 HSI n0=4094 实例（探针 `probe_seg.py`，425 笔 / 67 段）

| 段 | dir | startBi | endBi | biCount | beginVal | endVal | confirmed | reason |
|---|---|---|---|---|---|---|---|---|
| idx65 | +1 | 415 | 421 | 7 | 15240.95 | 17328.43 | false | `normal` |
| idx66 | -1 | 422 | 424 | 3 | 17328.43 | 15948.76 | false | `collect_left_0` |

- **idx65 是真实段候选**：`eigen dir=1`，元素为 `[416,418 | 420,422(gap=True) | 424]`；`ele[2]` 的笔 424 `is_sure=false / used_to_be_sure=false`（CL-V1 L757-L759）→ `all_bi_is_sure()` L979-L982 为 false → `is_sure=false`。它 false 的原因是特征序列**外延到了未确认末笔**，不是段本身不成立。
- **idx66 是占位段**：`eigen_fx=None`，由 L1269-L1278 直接造出。`startBi = 421+1 = 422`；因 421(up) 与 424(down) 方向相反走 L1277，`endBi = last_bi.idx = 424`；`dir = end_bi.dir = -1`（L1028）；`biCount = 424-422+1 = 3`。它不代表独立行情结构，只为给 422-424 三笔一个段归属。
- **+50 根后（bars[:4144]）**：idx66 消失，idx65 变为 `415-431 / 17 笔 / endVal=17683.45 / reason=collectleft_find_high` —— 占位段被吸收进重建后的真实段。

### 7.4 为什么必须造占位段

1. `segments` 需要覆盖 `[0, lastBi]`；否则 422-424 三笔无归属。
2. `_assign_seg_idx` L1314-L1320：超出最后一段的笔被赋 `seg_idx = len(segs)` 哨兵；`_ZS.combine` L1393 用 `begin_bi.seg_idx` 判定能否合并，哨兵让这些笔只能互相合并（隐式伪容器）。
3. `_seg_centers_json` L1551-L1556 以"段"为线构建段段；无占位段时最后容器 `endBi` 停在 421，尾部笔落在容器外。
4. 笔级中枢另有兜底：`_ZSList.cal` L1513-L1514 对 `line_lst[last_seg.end_bi.idx+1:]` 单独 `add_from_line_range(..., False)`。所以缺占位段不会让 `centers` 崩，但段级容器与绘制会出现"尾部无段"。

### 7.5 频率（4 标的，每标的 653 样本 = 全量 1 + 逐根 3×201 + 批量 7×7）

| 标的 | 头部未确认 | 逐根 尾=2 | 逐根 尾≥3 | 逐根最大尾 | 批量 尾=2 | 批量 尾≥3 | 批量最大尾 |
|---|---|---|---|---|---|---|---|
| HSI | 2 | 76.0% | 5.6% | 3 | 42.9% | 42.9% | 4 |
| 999999 | 0 | 69.0% | 12.8% | 4 | 71.4% | 18.4% | 6 |
| 000002 | 2 | 74.0% | 14.8% | 3 | 55.1% | 30.6% | 4 |
| 399001 | 0 | 68.8% | 21.4% | 3 | 46.9% | 44.9% | 6 |

- **出现过 3 个及以上**，且不罕见。例：999999 `batch n0=3067+1` 尾部 5 段 `[normal, collectleft_find_high, collectleft_find_low, collectleft_find_high, collect_left_1]`，biCount `[3,9,13,5,3]`。
- 中间未确认：**0 / 2612**。
- HSI / 000002 头部恒 2（`split_first_1st/2nd`）且永不转 true，所以这两标的"总未确认数"最小是 3，不会出现 0/1/2。

---

## 8. 核实「尾部 5～6 个未确认段」

### 8.1 实例（`probe_tail.py` → `tail_probe.txt`）

**999999 `batch n0=3067+1`（bi=276, seg=45, tail=5）**

| idx | dir | startBi | endBi | biCount | beginVal | endVal | reason | confirmed | eigen_fx |
|---|---|---|---|---|---|---|---|---|---|
| 40 | -1 | 242 | 244 | 3 | 1776.02 | 1339.20 | `normal` | false | 有（gap=[F,T,F]） |
| 41 | +1 | 245 | 253 | 9 | 1339.20 | 1748.89 | `collectleft_find_high` | false | None |
| 42 | -1 | 254 | 266 | 13 | 1748.89 | 1311.68 | `collectleft_find_low` | false | None |
| 43 | +1 | 267 | 271 | 5 | 1311.68 | 1649.60 | `collectleft_find_high` | false | None |
| 44 | -1 | 272 | 274 | 3 | 1649.60 | 1522.19 | `collect_left_1` | false | None |

**399001 `batch n0=3051+1`（bi=297, seg=39, tail=6）**：`normal`(257-259,3) + `find_high`(260-272,13) + `find_low`(273-283,11) + `find_high`(284-288,5) + `find_low`(289-295,7) + `collect_left_0`(296,1)。
**HSI `batch n0=909+200`（tail=3）**：`normal`(91-105,15) + `find_low`(106-112,7) + `collect_left_1`(113,1)，末笔 114 未覆盖。
**000002 `batch n0=4258+1`（tail=3）**：`normal`(257-271,15) + `find_low`(272-296,25) + `collect_left_0`(297,1)。

### 8.2 合法性（`legality_scan.py`，4 标的 ×653 样本 = 2612）

- gap=0、overlap=0、same_dir=0：所有尾部段**首尾相接、严格右移、方向交替**。
- `biCount<3` 只出现在**最后一个占位段**（`collect_left_0/1`，1~2 笔）：HSI 350/653、999999 344/653、000002 331/653、399001 292/653。`_Seg.__init__` L1035-L1036 会把这种段强制 `is_sure=False`；`check()` L1040-L1052 对 `is_sure=True` 且差<2 直接抛 `_SegLenErr` —— 所以"1 笔段"在结构上只可能是未确认段。
- `collect_left_1` 会**漏掉最后 1 笔**（L1274 `last_bi.idx-1`）：HSI 180/653、999999 142/653、000002 202/653、399001 164/653。这是为了不与上一段同向，属设计行为（上游一致）。
- 没有"同向相邻可合并"的情况（same_dir=0），因此不存在"该合并未合并"；中间那些 `collectleft_*` 是**交替的峰到峰切分**，合法但属临时。

### 8.3 成因：上游原样，不是移植偏差

- 已核对上游 `Seg/SegListComm.py`、`Seg/SegListChan.py`、`Seg/SegConfig.py`：`collect_left_seg_peak_method`、`collect_left_as_seg`、`collect_segs`、`try_add_new_seg`、`do_init`、`cal_seg_sure`、`treat_fx_eigen` 与移植版逐行等价；上游 `CSegConfig` 默认 `left_method="peak"`。
- 递归条件（L1219-L1235）：`last_seg_end_bi` 与下一个反向峰 `FindPeakBi` 的 `idx` 差 ≥3（L1221/L1227）就 append 一个 `collectleft_*`，然后递归；找不到峰才 `collect_left_as_seg`。**没有** `can_be_end`/特征序列确认，也没有 `left_bi_break` 复查（上游定义了该方法但此路径未调用）。
- 触发条件：尾部 ≥6 笔、存在一串间隔 ≥3 笔的交替局部极值，且尾部尚未突破最后确认段的极值（L1242/L1248 两个 force 分支都不成立）。
- 这些段的性质是「几何填充」，不是「待特征序列确认」：999999 +1 时 tail=5，+20 仍是 5 但成分变了（最后一段变成 `find_low 272-278`），+200 后整体换成 `normal(287-291) + collect_left_0(292-296)`，原 5 段**全部被重建替换**，不是逐段晋升。

### 8.4 结论与最小修复点

- **合法，但不是"待确认切分"**：它们是上游 `left_method=peak` 对未定尾部的临时铺满；其中只有 `normal` 那一条是特征序列候选，其余是峰到峰临时段，最后一条是占位段。
- **不是实现缺陷**（与上游逐行一致）。若产品要求"尾部只显示 1 条待确认段"，那是对上游 CL-V1 参考结果的有意偏离，应改**输出/绘制层**而不是段算法：
  - 最小点 1：`_segments_json`（chan.py L1288-L1299）输出 `reason`，由客户端按 `reason` 分级；
  - 最小点 2：`_build_chan` [tdx_eval.py L556](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/tdx_eval.py#L556) 把 `pos == len(segs)-1 and confirmed is False` 改成"所有尾部 `confirmed=false` 的段"，即把它们一起送进 `CHANSEGUC`。
  - 影响：仅尾部渲染；`chan.py` 结果、已确认历史段/中枢 0 变化（append 方向实测段 0/144,471、中枢 0/118,213）。若改 `collect_left_seg_peak_method` 只留一段，则会改变尾部 `segments`/`segCenters`/尾部中枢，与上游参考不一致。

### 8.5 绘制影响

- [tdx_eval.py L533-L536](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/tdx_eval.py#L533-L536) 与 [L556](file:///Volumes/home/repositories/Kline2/Kline/PyScripts/tdx_eval.py#L556) 只把**最后一个**未确认项送入 `*UC`；其余尾部临时段全部进 `CHANSEG` 实线。
- `CHANSEG.tdx` L5：`CHANSEGUC` 为 `DOTLINE`（虚线），`CHANSEG` 为实线。
- 因此 tail=5 时用户看到 **4 条实线 + 1 条虚线**，tail=6 时 **5 实 + 1 虚**；最多多出 5 条实线段。典型情形 tail=2（逐根 68.8%~76.0%），即 1 实 + 1 虚，与"1～2 条"的直觉一致；≥3 在逐根占 5.6%~21.4%、批量占 18.4%~44.9%。
