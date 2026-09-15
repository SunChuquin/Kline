//
//  LinkedReplaySupport.swift
//  Kline
//
//  联动「历史时点复盘」支撑类型与后台求值。
//  从 KlineChartView.swift 拆分而来，KlineChartView 与 SubChartCanvas 共享这些类型；
//  依赖 FormulaEngine.swift（TDXOutputLine / TDXFormulaEngine / tdxAllNaN）。
//

import Foundation
import SwiftUI
import Combine

// MARK: - 主/副图单点合成替换结构

/// 主图 Canvas 的单点合成K线替换：index 为可见切片(slice)本地索引，item 已按镜像需要取负。
/// 联动复盘态下，光标所在的大周期 K 线用来源周期数据实时合成，由该结构在绘制时单点替换。
struct SyntheticBar: Equatable {
    let index: Int
    let item: KlineItem

    // 自定义相等：忽略 KlineItem 每次合成新生成的 UUID（仅比 OHLCV 内容），
    // 保证 MainChartCanvas.equatable() 在合成内容未变时不做无意义重绘
    static func == (l: SyntheticBar, r: SyntheticBar) -> Bool {
        l.index == r.index
            && l.item.date == r.item.date
            && l.item.open == r.item.open
            && l.item.high == r.item.high
            && l.item.low == r.item.low
            && l.item.close == r.item.close
            && l.item.volume == r.item.volume
            && l.item.turnover == r.item.turnover
    }
}

/// 副图 Canvas 的单点合成柱替换（VOL/AMO）：index 为可见切片本地索引，value 已按镜像需要取负。
struct SyntheticStick: Equatable {
    let index: Int
    let value: Double
    let isUp: Bool

    static func == (l: SyntheticStick, r: SyntheticStick) -> Bool {
        l.index == r.index && l.value == r.value && l.isUp == r.isUp
    }
}

// MARK: - 来源周期 K 线懒加载缓存

/// 联动复盘用：按 (标的, 来源周期) 懒加载来源周期K线（升序），同进程多个 tile 共享
/// （月线、季线视图合成同一标的的周线时只查一次 DB）。行情库在会话内不变，进程内缓存不做失效；
/// 切换周期/标的导致图表 .id 重建后，新实例直接命中。
final class LinkSourceBarCache: ObservableObject {
    static let shared = LinkSourceBarCache()

    struct Key: Hashable {
        let metaID: Int
        let period: KlinePeriod
    }

    /// 每次有新的一组数据加载完成即递增，驱动各图表重新派生合成K线
    @Published private(set) var revision = 0

    private var storage: [Key: [KlineItem]] = [:]
    private var inflight = Set<Key>()
    private let lock = NSLock()

    /// 同步读取已缓存的来源周期K线（升序）；未加载返回空数组（不区分"无数据"与"加载中"，
    /// 两种情况下调用方都先按真实K线绘制，request 完成后经 revision 刷新为合成形态）
    func bars(metaID: Int, period: KlinePeriod) -> [KlineItem] {
        lock.lock(); defer { lock.unlock() }
        return storage[Key(metaID: metaID, period: period)] ?? []
    }

    /// 命中缓存或已在途时无操作；否则后台查询一次，完成后在主线程递增 revision
    func request(metaID: Int, period: KlinePeriod) {
        let key = Key(metaID: metaID, period: period)
        lock.lock()
        if storage[key] != nil || inflight.contains(key) { lock.unlock(); return }
        inflight.insert(key)
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            // fetchBars 返回 date DESC，统一排序为升序供二分与聚合
            let sorted = DatabaseManager.shared.fetchBars(metaId: metaID, period: period)
                .sorted { $0.date < $1.date }
            DispatchQueue.main.async {
                self.lock.lock()
                self.storage[key] = sorted
                self.inflight.remove(key)
                self.lock.unlock()
                self.revision += 1
            }
        }
    }
}

// MARK: - 联动复盘：合成点指标 as-of 单点重算（后台异步 + 进程内缓存）

/// 一次 as-of 结果的缓存键：同一(标的,目标周期,来源周期,光标日期,指标配置)只算一次，
/// 拖回去时零开销；配置/周期/标的变化自动 miss
struct AsOfKey: Hashable {
    let metaID: Int
    let targetPeriod: KlinePeriod
    let sourcePeriod: KlinePeriod
    let date: Int
    let fingerprint: String
}

/// as-of 求值结果：主图与三个副图分别按「曲线数组下标 → 合成点值」存储。
/// 下标与 mainCurves / SubChartModel.curves 的行顺序严格同源（同过滤规则），只覆盖合成点一个值。
struct AsOfResult {
    var main: [Int: Double] = [:]
    var subs: [[Int: Double]] = [[:], [:], [:]]
}

/// as-of 结果进程内缓存（LRU 上限保护，光标来回拖动命中零计算；不写入 ChartCacheStore，
/// 避免污染正常指标体系与后台预计算）
final class AsOfValueCache {
    static let shared = AsOfValueCache()
    private var storage: [AsOfKey: AsOfResult] = [:]
    private var order: [AsOfKey] = []
    private let limit = 240
    private let lock = NSLock()

    func get(_ key: AsOfKey) -> AsOfResult? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func put(_ key: AsOfKey, _ result: AsOfResult) {
        lock.lock(); defer { lock.unlock() }
        if storage[key] == nil {
            order.append(key)
            while order.count > limit, let old = order.first {
                order.removeFirst()
                storage[old] = nil
            }
        }
        storage[key] = result
    }
}

/// as-of 后台求值请求（主线程构造：公式文本与数据在此取齐，后台只做纯计算，不碰任何 ObservableObject）
struct AsOfRequest {
    let key: AsOfKey
    /// [0...合成索引] 的K线，末项已替换为合成K线
    let data: [KlineItem]
    /// 主图启用指标公式（顺序与 mainIndicatorEntries 一致：.tdx defs → 自定义）
    let mainFormulas: [String]
    /// 副图三槽：VOL/AMO/无指标为 nil；自定义/系统公式带 isCustom 标记
    struct Sub {
        let formula: String
        let isCustom: Bool
    }
    let subs: [Sub?]
}

/// 后台执行 as-of 求值：逐指标用截断（末项替换）序列重算，**只取每条输出行末点值**。
/// 行的保留/跳过规则必须与前台 recomputeMainCurves / recomputeSub 严格一致，
/// 结果下标才能与当前 curves 数组一一对齐：
/// - 主图：formula → splitOutputUnits → 逐单元 evaluate，out 非全 NaN（buildMainLine 的唯一过滤条件）才占一个曲线位；
/// - 副图自定义：evaluate(formula:) 的全部输出行；
/// - 副图系统指标：过滤全 NaN 行（recomputeSub 的 guard !allNaN）；
/// - VOL/AMO：不入此通道（合成量/额在阶段 A 处理）。
func evaluateAsOf(_ req: AsOfRequest) -> AsOfResult {
    var result = AsOfResult()

    // 主图
    var mainIndex = 0
    for formula in req.mainFormulas {
        guard let units = try? TDXFormulaEngine.splitOutputUnits(formula: formula) else { continue }
        for unit in units {
            // 与 mainRows 同源：每个 unit 成功（out 非全 NaN）才占一个 mainCurves 位，失败不占位
            if let outs = try? TDXFormulaEngine.evaluate(statements: unit.statements, data: req.data),
               let out = outs.last,
               !tdxAllNaN(out.values),
               let v = out.values.last, !v.isNaN {
                result.main[mainIndex] = v
                mainIndex += 1
            }
        }
    }

    // 副图三槽
    for (slot, sub) in req.subs.enumerated() {
        guard let sub, let lines = try? TDXFormulaEngine.evaluate(formula: sub.formula, data: req.data) else { continue }
        var curveIndex = 0
        for line in lines {
            // 自定义行全部保留；系统行过滤全 NaN（与前台同一规则）
            guard sub.isCustom || !tdxAllNaN(line.values) else { continue }
            if let v = line.values.last, !v.isNaN {
                result.subs[slot][curveIndex] = v
            }
            curveIndex += 1
        }
    }
    return result
}
