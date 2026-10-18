//
//  SimTradeRulesProjection.swift
//  Kline
//
//  阶段 A5-5 前置（C 组展示面 ·《Python引擎下沉可行性分析.md》§10.10 闸门 6 / §11.18.3）：
//  交易规则派生值的「引擎投影层」。
//
//  背景：`SimTradingRules` 的派生值（可买 / 可卖 / 佣金 / 印花税 / 合计费用 / 涨跌停区间 /
//  交易时段）在 `.swift` 现状里都是**视图每帧同步算**的纯函数。A5-4 已把**裁决路径**
//  （`SimStore.submit` / `sweepConditions`）切到引擎，但**展示路径**仍留在 Swift —— 于是
//  `.engine` 模式下会出现「界面口径 ≠ 引擎口径」。本层即闸门 6 的「防抖 + 投影」在 C 组的落点：
//    · 视图按当前入参取值：命中缓存 → 同步返回（`body` 里可安全调用）；
//    · 未命中 → 只入队（`pending` / `scheduled` 均非 `@Published`，在 `body` 里改不会触发发布）
//      ，防抖 50ms 后批量打引擎；
//    · 结果按「函数 + 参数」为键写进 `@Published` 缓存，视图自然重绘。
//
//  A5-5 起默认 `.engine`：本层常态生效（防抖入队 → 引擎取即时派生值）。
//  仅当显式回退 `.swift`（单测对拍 / Debug 页）时本层完全直通 `SimTradingRules.default` 现状
//  （零行为变化、零引擎请求）。
//
//  与 `SimTradeRuleConstants`（§11.22）的分工：整手 / 最小报价档位 / 费率 / 涨跌停幅是
//  **配置常量**，已由信任链镜像到 Swift、同步可读，故不走本层请求；本层只处理后者的
//  **即时派生值**（依赖资金 / 报价 / 持仓 / 时刻等运行期入参）。
//
//  降级（§9.10 / §11.7）：未就绪 / 引擎失败 → 取值给 `nil`，由视图呈现显式空态
//  （占位文案见 `placeholderText`），**不静默用 Swift 兜底**。需要「确定值」的动作路径
//  （开条件单默认数量 / 带量下单）用 `sellableQtyAsync(...)` 直接 `await` 引擎。
//

import Foundation
import Combine

@MainActor
final class SimTradeRulesProjection: ObservableObject {

    static let shared = SimTradeRulesProjection()

    /// 未就绪占位（显式空态，§9.10）
    static let placeholderText = "—"

    /// 每键可用性。`.failed` 之后**不自动重试**（否则未就绪期每帧都会刷一轮请求），
    /// 等引擎就绪 / 信任链重算时的 `reset()`。
    enum Availability: Equatable { case ready, failed }

    // MARK: - 配置常量（信任链镜像，两种模式同步可读，见 §11.22）

    /// 每手股数（引擎 `_LOT_SIZE` 镜像）
    var lotSize: Int { SimTradeRuleConstants.lotSize }
    /// 最小报价档位（引擎 `_PRICE_TICK` 镜像）
    var priceTick: Double { SimTradeRuleConstants.priceTick }

    // MARK: - 投影缓存

    /// 投影缓存值（`@Published values` 的元素类型，故为 internal）
    enum Value: Equatable {
        case int(Int)
        case double(Double)
        case flag(Bool)
        case range(lower: Double, upper: Double)
        /// 合法空结果（如 `limitRange` 无昨收 → 不设限），与「未就绪」区分开
        case none
    }

    @Published private(set) var values: [String: Value] = [:]
    @Published private(set) var availability: [String: Availability] = [:]

    /// 防抖间隔（合并连续变更：逐字符改价 / 每秒时钟都不致每次渲染都打引擎）
    var debounce: TimeInterval = 0.05

    private var pending: [String: () async throws -> Value] = [:]
    private var scheduled = false
    private var inflight = 0

    private init() {}

    // MARK: - 生命周期

    /// 引擎就绪 / 信任链重算后调用（与 `SimRulesProjection.requestAll()` 同处）：
    /// 清失败标记与缓存，让仍在屏上的取值重新发起请求。
    func reset() {
        values.removeAll()
        availability.removeAll()
        pending.removeAll()
    }

    /// 测试辅助：立刻冲一次防抖队列，并等到本轮请求全部落地。
    func flushAndWait(timeout: TimeInterval = 5) async {
        flush()
        let deadline = Date().addingTimeInterval(timeout)
        while inflight > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - 取值（与 `SimTradingRules` 同名同义；视图改调本层）

    /// 可买整手数量（`trade_calc.affordableQty`）。未就绪 → `nil`。
    func affordableQty(cash: Double, price: Double) -> Int? {
        let key = "affordableQty|\(cash)|\(price)"
        if let v = cachedInt(key) { return v }
        enqueue(key) { .int(try await SimRulesBridge.tradeAffordableQty(cash: cash, price: price)) }
        return nil
    }

    /// 可卖整手数量（`trade_calc.sellableQty`，T+1 开启，同 `SimTradingRules.default`）。
    /// 未就绪 → `nil`。`position == nil` → `0`。
    func sellableQty(position: SimPosition?) -> Int? {
        guard let position = position else { return 0 }
        let key = sellableKey(position)
        if let v = cachedInt(key) { return v }
        enqueue(key) { .int(try await SimRulesBridge.tradeSellableQty(position: position)) }
        return nil
    }

    /// 动作路径专用：直接 `await` 引擎取可卖整手数量（并写缓存）——用于需要**确定值**的场合
    /// （开条件单默认数量、持仓页「卖」带量）。失败 → `nil`（调用方按「未知」处理；
    /// 真正下单仍由引擎终审，不会因预填值误成交）。
    func sellableQtyAsync(position: SimPosition) async -> Int? {
        let key = sellableKey(position)
        if let v = cachedInt(key) { return v }
        do {
            let v = try await SimRulesBridge.tradeSellableQty(position: position)
            values[key] = .int(v)
            availability[key] = .ready
            return v
        } catch {
            DebugLogger.shared.log("[TradeProjection] sellableQtyAsync 失败：\(error)")
            availability[key] = .failed
            return nil
        }
    }

    /// 动作路径专用：直接 `await` 引擎取可买整手数量（并写缓存）。失败 → `nil`。
    func affordableQtyAsync(cash: Double, price: Double) async -> Int? {
        let key = "affordableQty|\(cash)|\(price)"
        if let v = cachedInt(key) { return v }
        do {
            let v = try await SimRulesBridge.tradeAffordableQty(cash: cash, price: price)
            values[key] = .int(v)
            availability[key] = .ready
            return v
        } catch {
            DebugLogger.shared.log("[TradeProjection] affordableQtyAsync 失败：\(error)")
            availability[key] = .failed
            return nil
        }
    }

    /// 佣金（`trade_calc.commission`）。未就绪 → `nil`。
    func commission(amount: Double) -> Double? {
        let key = "commission|\(amount)"
        if let v = cachedDouble(key) { return v }
        enqueue(key) { .double(try await SimRulesBridge.tradeCommission(amount: amount)) }
        return nil
    }

    /// 印花税（`trade_calc.stampTax`）。未就绪 → `nil`。
    func stampTax(amount: Double, direction: SimOrderDirection) -> Double? {
        let key = "stampTax|\(amount)|\(direction.rawValue)"
        if let v = cachedDouble(key) { return v }
        enqueue(key) {
            .double(try await SimRulesBridge.tradeStampTax(amount: amount, direction: direction))
        }
        return nil
    }

    /// 合计费用（`trade_calc.fee` = 佣金 + 印花税）。未就绪 → `nil`。
    func fee(amount: Double, direction: SimOrderDirection) -> Double? {
        let key = "fee|\(amount)|\(direction.rawValue)"
        if let v = cachedDouble(key) { return v }
        enqueue(key) {
            .double(try await SimRulesBridge.tradeFee(amount: amount, direction: direction))
        }
        return nil
    }

    /// 涨跌停区间（`trade_calc.limitRange`）。未就绪 / 无昨收 → `nil`（视图不显示区间）。
    func limitRange(prevClose: Double?) -> ClosedRange<Double>? {
        let key = "limitRange|\(prevClose.map { "\($0)" } ?? "nil")"
        if let cached = values[key] {
            switch cached {
            case .range(let lower, let upper): return lower...upper
            case .none: return nil
            default: break
            }
        }
        enqueue(key) {
            let r = try await SimRulesBridge.tradeLimitRange(prevClose: prevClose)
            return r.map { .range(lower: $0.lower, upper: $0.upper) } ?? .none
        }
        return nil
    }

    /// 是否交易时段（`trade_calc.isTradingSession`）。未就绪 → `nil`（视图给占位，不臆断开市）。
    ///
    /// 键按**分钟**归并：调用点是每秒刷新的时钟（`TimelineView(.periodic(by: 1))`），
    /// 若按秒为键会每秒打一次引擎；交易时段以分钟为粒度判定，故一分钟内复用同一结果。
    /// `tzOffsetSeconds` 进键：DST 切换会改变同一时刻的本机偏移（引擎按固定偏移判定）。
    func isTradingSession(at date: Date) -> Bool? {
        let tz = TimeZone.current.secondsFromGMT(for: date)
        let key = "isTradingSession|\(Int(date.timeIntervalSince1970 / 60))|\(tz)"
        if let v = cachedFlag(key) { return v }
        enqueue(key) { .flag(try await SimRulesBridge.tradeIsTradingSession(at: date)) }
        return nil
    }

    // MARK: - 展示辅助（`nil` → 显式占位，§9.10）

    /// 金额文案。⚠️ 本层为 GUI 服务，故直接给占位文案（`SimFormat` 归 GUI 层，见 D5 / §9.7）。
    static func moneyText(_ v: Double?) -> String {
        v.map(SimFormat.amount) ?? placeholderText
    }

    /// 股数文案。
    static func sharesText(_ v: Int?) -> String {
        v.map(SimFormat.shares) ?? placeholderText
    }

    // MARK: - 内部：键 / 缓存 / 请求

    private func sellableKey(_ position: SimPosition) -> String {
        "sellableQty|\(position.qty)|\(position.availableQty)"
    }

    private func cachedInt(_ key: String) -> Int? {
        if let v = values[key], case .int(let n) = v { return n }
        return nil
    }

    private func cachedDouble(_ key: String) -> Double? {
        if let v = values[key], case .double(let d) = v { return d }
        return nil
    }

    private func cachedFlag(_ key: String) -> Bool? {
        if let v = values[key], case .flag(let b) = v { return b }
        return nil
    }

    /// 入队一次请求（同键去重）+ 起防抖定时。⚠️ 本方法**只改非 `@Published` 状态**，
    /// 故可安全地在视图 `body` 里调用。
    private func enqueue(_ key: String, _ run: @escaping () async throws -> Value) {
        if availability[key] == .failed { return }
        pending[key] = run
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.scheduled = false
            self?.flush()
        }
    }

    private func flush() {
        let batch = pending
        pending.removeAll()
        guard !batch.isEmpty else { return }
        inflight += batch.count
        for (key, run) in batch {
            Task { @MainActor [weak self] in
                do {
                    let v = try await run()
                    self?.values[key] = v
                    self?.availability[key] = .ready
                } catch {
                    DebugLogger.shared.log("[TradeProjection] \(key) 失败：\(error)")
                    self?.availability[key] = .failed
                }
                self?.inflight -= 1
            }
        }
    }
}
