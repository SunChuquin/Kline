//
//  SimRulesProjection.swift
//  Kline
//
//  阶段 A5-3：交易判定「引擎投影层」——让 GUI 仍能**同步**读到引擎算出的文案/判定。
//
//  背景（《Python引擎下沉可行性分析.md》§10.10 闸门 6）：条件单文案族（conditionSummary /
//  validitySummary / directiveSummary / gridLevelCount / previewSentence）原本是 SwiftUI
//  每帧同步计算的纯函数；下沉到引擎后变成异步 → 直接把「视图每帧等引擎」搬进 UI 会卡。
//  本层即闸门 6 定的「**防抖 + 投影**」：
//    · 状态变更 → `request(...)` 收快照（防抖合并，默认 50ms）；
//    · 到点后对**文案相关字段有变化的**单据批量调一次引擎 op `cond_texts`（一次取全 6 字段）；
//    · 结果按 `order.id` 缓存进 `@Published`，视图同步读缓存（未就绪给占位）。
//
//  A5-5 起默认 `.engine`：本层常态生效（`request` 入队 → 防抖合并 → 引擎取文案）。
//  仅当显式回退 `.swift`（单测对拍 / Debug 页）时本层完全惰性、取值直通 `SimCondRule` 现状。
//  A6 删 Swift 实现后，取值只剩「读缓存 / 占位」两条路。
//

import Foundation
import Combine

@MainActor
final class SimRulesProjection: ObservableObject {

    static let shared = SimRulesProjection()

    /// 条件单文案族（与 `cond_texts` op 输出一一对应）
    struct CondText: Equatable {
        var condition: String
        var directiveCore: String
        var directive: String
        var validity: String
        var preview: String
        var gridLevelCount: Int
    }

    /// 每单可用性（供视图区分「计算中」与「失败」）
    enum Availability: Equatable { case computing, ready, failed }

    /// 未就绪占位（显式空态，§9.10：不静默用 Swift 兜底）
    static let placeholderText = "…"

    @Published private(set) var condTexts: [UUID: CondText] = [:]
    @Published private(set) var availability: [UUID: Availability] = [:]

    /// 防抖间隔（合并连续变更，编辑输入时不致每次击键都打引擎）
    var debounce: TimeInterval = 0.05

    private var snapshots: [UUID: SimCondOrder] = [:]     // 待刷新单据（最新快照）
    private var requestedJSON: [UUID: Data] = [:]         // 上次已请求内容（去重：内容未变不重复打引擎）
    private var scheduled = false

    private init() {}

    // MARK: - 请求（防抖合并 + 内容去重）

    func request(_ orders: [SimCondOrder]) {
        guard SimRulesBridge.mode == .engine else { return }   // 仅 `.swift` 回退时零开销
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var changed = false
        for o in orders {
            let json = (try? enc.encode(o)) ?? Data()
            if requestedJSON[o.id] == json, condTexts[o.id] != nil { continue }
            requestedJSON[o.id] = json
            snapshots[o.id] = o
            if condTexts[o.id] == nil { availability[o.id] = .computing }
            changed = true
        }
        guard changed, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.scheduled = false
            self?.flush()
        }
    }

    func request(_ order: SimCondOrder) { request([order]) }

    /// 全量刷新（引擎就绪 / 信任链重算后调用：补上「列表未变但引擎刚可用」的场景）。
    func requestAll() { request(SimStore.shared.condOrders(accountID: nil)) }

    /// 丢弃某单缓存（删除后调用）
    func forget(_ id: UUID) {
        condTexts[id] = nil; availability[id] = nil
        snapshots[id] = nil; requestedJSON[id] = nil
    }

    private func flush() {
        let batch = snapshots
        snapshots.removeAll()
        for (id, order) in batch {
            guard let json = SimRulesCodec.condOrderJSON(order) else {
                availability[id] = .failed
                continue
            }
            let input: [String: Any] = ["order": json,
                                        "tzOffsetSeconds": TimeZone.current.secondsFromGMT()]
            SimRulesBridge.payload(op: "cond_texts", input: input) { [weak self] r in
                guard let self else { return }
                guard case .success(let payload) = r,
                      let t = payload["text"] as? [String: Any],
                      let condition = SimRulesCodec.str(t["condition"]),
                      let core = SimRulesCodec.str(t["directiveCore"]),
                      let directive = SimRulesCodec.str(t["directive"]),
                      let validity = SimRulesCodec.str(t["validity"]),
                      let preview = SimRulesCodec.str(t["preview"]) else {
                    self.availability[id] = .failed
                    return
                }
                self.condTexts[id] = CondText(condition: condition, directiveCore: core,
                                              directive: directive, validity: validity,
                                              preview: preview,
                                              gridLevelCount: SimRulesCodec.int(t["gridLevelCount"]) ?? 0)
                self.availability[id] = .ready
            }
        }
    }

    // MARK: - 取值（与 `SimCondRule` 静态方法同名同义；视图改调本层）

    func conditionSummary(_ order: SimCondOrder) -> String {
        if SimRulesBridge.mode == .swift { return SimCondRule.conditionSummary(order) }
        return condTexts[order.id]?.condition ?? Self.placeholderText
    }

    func directiveSummary(_ order: SimCondOrder) -> String {
        if SimRulesBridge.mode == .swift { return SimCondRule.directiveSummary(order) }
        return condTexts[order.id]?.directive ?? Self.placeholderText
    }

    func directiveCore(_ order: SimCondOrder) -> String {
        if SimRulesBridge.mode == .swift { return SimCondRule.directiveCore(order) }
        return condTexts[order.id]?.directiveCore ?? Self.placeholderText
    }

    func validitySummary(_ order: SimCondOrder) -> String {
        if SimRulesBridge.mode == .swift { return SimCondRule.validitySummary(order) }
        return condTexts[order.id]?.validity ?? Self.placeholderText
    }

    func previewSentence(_ order: SimCondOrder) -> String {
        if SimRulesBridge.mode == .swift { return SimCondRule.previewSentence(order) }
        return condTexts[order.id]?.preview ?? Self.placeholderText
    }

    /// 网格档位数。⚠️ 未就绪返回 `0`；视图请改用 `gridLevelCountIfReady`（未就绪即不渲染，
    /// 避免「约 0 档」误导——A5-5 已落地）。
    func gridLevelCount(_ order: SimCondOrder) -> Int {
        if SimRulesBridge.mode == .swift { return SimCondRule.gridLevelCount(order: order) }
        return condTexts[order.id]?.gridLevelCount ?? 0
    }

    /// 网格档位数（`nil` = 未就绪）：供进度行 / 档位文案决定「是否渲染」，
    /// 避免 `.engine` 首帧显示「约 0 档」误导（§11.23 已知取舍 → A5-5）。`.swift` 模式恒有值。
    func gridLevelCountIfReady(_ order: SimCondOrder) -> Int? {
        if SimRulesBridge.mode == .swift { return SimCondRule.gridLevelCount(order: order) }
        return condTexts[order.id]?.gridLevelCount
    }
}
