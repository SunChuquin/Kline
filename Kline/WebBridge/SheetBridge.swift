//
//  SheetBridge.swift
//  Kline
//
//  图表弹层浮层桥（协议 v2 sheet.* + chart.*）：弹层三件套 P2-5 的 Swift 侧。
//
//  弹层浮层模式（P2 计划 §3.3）：
//   - 弹层打开时由宿主（KlineDetailView）插入全屏 WKWebView 浮层（route="sheet"），
//     body 渲染「遮罩 + 面板」；首次打开创建 WebView 实例，之后 opacity 切换复用
//     （同一详情页内弹层打开零实例化成本；详情退出随宿主释放，内存友好）。
//   - Swift→Web：sheet.open {name} 事件路由到对应面板；Web→Swift：sheet.close 动作
//     移除浮层遮罩并经 closeHandler 回写宿主弹层状态（showSettings/showSearch）。
//   - 弹层打开期间图表手势被 WebView 挡住 = 符合既有交互（弹层打开本就不操作图表）。
//   - KlineDetailView 的弹层状态机（isAnyPopupActive 等）保留：宿主 @State 弹层状态
//     经 onChange 双向同步到本桥，原生弹层 UI 由 Web 面板替代（回退 = 恢复原渲染分支）。
//
//  面板数据（P2-5a 实装两个）：
//   - chart.settings.*：K线设置页（ChartConfigStore 显示组 + LinkedViewStore 联动视图），
//     写回走既有 @Published didSet 持久化链路，图表即时生效。
//   - chart.search.*：图表搜索面板（DatabaseManager.searchMeta 同口径；pick 回调宿主切标的）。
//   - 指标控制面板 / 快捷面板属 P2-5b（fixtures reserved 已锁形状）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import SwiftUI

@MainActor
final class SheetBridge: ObservableObject {

    static let shared = SheetBridge()

    /// 当前打开的弹层名（nil = 无弹层；浮层 WebView 常驻由宿主按此值切 opacity）
    @Published private(set) var activeSheet: String? = nil
    /// chart.search.pick 回调：KlineDetailView 注入（切标的 + loadData）
    var pickHandler: ((MetaItem) -> Void)? = nil

    // MARK: 指标面板（P2-5b）宿主处理器（per-tile 动态注册，与 closeHandler 同款模式）

    /// 指标写回后的重算闭包（当前面板所属 tile 注册：主图 + 三副图全量重算）
    var recomputeHandler: (() -> Void)? = nil

    /// 指标编辑器打开请求（关面板 + 原生编辑器呈现；per-tile 注册）
    enum ChartEditorRequest {
        case system(isMain: Bool, subId: String?)
        case custom(target: EditorTarget)
    }
    var editorHandler: ((ChartEditorRequest) -> Void)? = nil

    /// 公式中心（P2-6b）原生全屏呈现请求：Web 面板点「编辑/新建」→ 关 Web 面板 →
    /// 原生 FormulaCenterView 全屏打开（编辑器完整可用）；关闭后重开 Web 面板即见最新。
    /// picker/strategy 段（选股/策略公式）本版仍整体桥接原生中心（Web 仅实装 tech 段）。
    @Published var formulaCenterRequest: String? = nil

    /// 各页公式中心入口 → Web tech 段面板（picker/strategy 直接桥原生中心）
    func openFormulaCenter(_ kind: FormulaKind) {
        if kind == .tech {
            guard activeSheet != "formulaCenter" else { return }
            activeSheet = "formulaCenter"
            WebMessageRouter.shared.pushEvent("sheet.open",
                                              payload: ["name": "formulaCenter", "kind": kind.rawValue],
                                              route: "sheet")
            DebugLogger.shared.log("[SheetBridge] open formulaCenter(tech)")
        } else {
            formulaCenterRequest = kind.rawValue
        }
    }

    // MARK: - 打开 / 关闭（宿主同步入口）

    /// 宿主弹层状态 → 桥（onChange 同步）。同值 no-op 防环。
    /// - Parameter slot: 副图指标面板的槽位上下文（payload 携带，快照定位编辑对象）
    func sync(_ name: String, active: Bool, slot: SubSlot? = nil) {
        if active {
            guard activeSheet != name else { return }
            activeSheet = name
            var payload: [String: Any] = ["name": name]
            if let slot { payload["slot"] = subSlotKey(slot) }
            // 定向推弹层浮层 WebView（Tab 宿主并存时 allObjects.last 会推错实例）
            WebMessageRouter.shared.pushEvent("sheet.open", payload: payload, route: "sheet")
            DebugLogger.shared.log("[SheetBridge] open \(name)")
        } else {
            guard activeSheet == name else { return }
            activeSheet = nil
        }
    }

    /// SubSlot → 协议字符串（无 rawValue，显式映射）
    private func subSlotKey(_ slot: SubSlot) -> String {
        switch slot {
        case .top: return "top"
        case .bottom: return "bottom"
        case .third: return "third"
        }
    }

    /// 协议字符串 → SubSlot
    static func subSlot(_ key: String) -> SubSlot? {
        switch key {
        case "top": return .top
        case "bottom": return .bottom
        case "third": return .third
        default: return nil
        }
    }

    /// Web sheet.close → 关闭当前弹层并回写宿主状态
    private func close() {
        guard let name = activeSheet else { return }
        activeSheet = nil
        if name == "formulaCenter" { formulaCenterRequest = nil }
        closeHandler?(name)
        DebugLogger.shared.log("[SheetBridge] close \(name)")
    }

    /// 宿主注入的关闭回调（回写 showSettings / showSearch 等 @State）
    var closeHandler: ((String) -> Void)? = nil

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "close":
            shared.close()
            return WebBridgeResponse.ok(request.id)
        case "ready":
            // ⚠️ 浮层 WebView 就绪拉取：sheet.open 事件可能早于 WebView 创建/加载完成发出
            // （首次打开时序：activeSheet 设置 → 事件立即推送 → 下一帧才创建 WebView →
            // 数百毫秒后 didFinish）→ 事件丢失导致面板永不渲染（2026-11-19 真机白屏）。
            // Web 端 mounted 后调本动作，宿主若有待展示弹层则补推 sheet.open。
            if let name = shared.activeSheet {
                WebMessageRouter.shared.pushEvent("sheet.open", payload: ["name": name], route: "sheet")
            }
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "sheet.\(request.action) 未实现")
        }
    }

    // MARK: - chart 模块（设置页 / 搜索面板）

    static func handleChart(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "settings.snapshot":
            return WebBridgeResponse.ok(request.id, data: settingsSnapshotData())
        case "settings.set":
            return settingsSet(request)
        case "settings.resetLinked":
            return settingsResetLinked(request)
        case "search.query":
            return searchQuery(request)
        case "search.pick":
            return searchPick(request)
        case "indicators.snapshot":
            return WebBridgeResponse.ok(request.id, data: indicatorsSnapshotData())
        case "indicators.toggleMain":
            return indicatorsToggleMain(request)
        case "indicators.selectSub":
            return indicatorsSelectSub(request)
        case "indicators.activateMainCustom":
            return indicatorsActivateMainCustom(request)
        case "indicators.resetBuiltin":
            return indicatorsResetBuiltin(request)
        case "indicators.openSystemEditor":
            return indicatorsOpenSystemEditor(request)
        case "indicators.openCustomEditor":
            return indicatorsOpenCustomEditor(request)
        case "formula.snapshot":
            return formulaSnapshotData()
        case "formula.deleteCustom":
            return formulaDeleteCustom(request)
        case "formula.openCenter":
            // 编辑/新建入口：关 Web 面板 → 原生公式中心全屏打开（编辑器完整可用）
            shared.close()
            shared.formulaCenterRequest = FormulaKind.tech.rawValue
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "chart.\(request.action) 未实现")
        }
    }

    // MARK: 设置页快照与写回

    /// chart.settings.snapshot：周期 / K线类型 / 联动视图数 / 显示组 / 裸K（选项带原生 label）
    static func settingsSnapshotData() -> [String: Any] {
        let config = ChartConfigStore.shared
        let item = currentDetailItem()
        let count = LinkedViewCount(rawValue: item.map {
            LinkedViewStore.shared.configs(for: $0.id, nameHint: (name: $0.name, code: $0.displayCode, type: $0.type)).count
        } ?? 2) ?? .two

        func options<T: CaseIterable & RawRepresentable>(_: T.Type) -> [[String: Any]] where T.RawValue == String {
            T.allCases.map { ["value": $0.rawValue, "label": $0.rawValue] }
        }
        let viewOptions: [[String: Any]] = LinkedViewCount.allCases.map {
            ["value": $0.rawValue, "label": $0.label]
        }
        return [
            "period": config.selectedPeriod.rawValue,
            "periodOptions": options(KlinePeriod.self),
            "chartStyle": config.chartStyle.rawValue,
            "styleOptions": options(ChartStyle.self),
            "linkedViewCount": count.rawValue,
            "viewCountOptions": viewOptions,
            "showGap": config.displaySettings.showGap,
            "gapDisappearAfterFill": config.displaySettings.gapDisappearAfterFill,
            "showLatestPriceLine": config.displaySettings.showLatestPriceLine,
            "indicatorNotSqueezeKline": config.displaySettings.indicatorNotSqueezeKline,
            "showBareK": config.showBareK,
        ]
    }

    /// 当前详情页标的（search.pick / linkedViewCount 需要；由 KlineDetailView 注入）
    static var currentDetailItem: () -> MetaItem? = { nil }

    /// chart.settings.set {period?, chartStyle?, linkedViewCount?, showGap?, ...}：幂等目标态写回。
    /// 走既有 @Published didSet 持久化链路 → 图表即时生效（原生 onChange 链路不变）。
    static func settingsSet(_ request: WebBridgeRequest) -> [String: Any] {
        let config = ChartConfigStore.shared
        let p = request.payload

        if let raw = p["period"] as? String, let period = KlinePeriod(rawValue: raw) {
            DebugLogger.shared.log("设置面板切换周期: \(period.rawValue)")
            config.selectedPeriod = period
        }
        if let raw = p["chartStyle"] as? String, let style = ChartStyle(rawValue: raw) {
            config.chartStyle = style
        }
        if let n = (p["linkedViewCount"] as? NSNumber)?.intValue,
           let count = LinkedViewCount(rawValue: n) {
            if let item = currentDetailItem() {
                LinkedViewStore.shared.setViewCount(count, for: item.id,
                                                    nameHint: (name: item.name, code: item.displayCode, type: item.type))
            }
        }

        var ds = config.displaySettings
        if let v = p["showGap"] as? Bool { ds.showGap = v }
        if let v = p["gapDisappearAfterFill"] as? Bool { ds.gapDisappearAfterFill = v }
        if let v = p["showLatestPriceLine"] as? Bool { ds.showLatestPriceLine = v }
        if let v = p["indicatorNotSqueezeKline"] as? Bool { ds.indicatorNotSqueezeKline = v }
        if ds != config.displaySettings { config.displaySettings = ds }

        if let v = p["showBareK"] as? Bool { config.showBareK = v }

        return WebBridgeResponse.ok(request.id)
    }

    /// chart.settings.resetLinked {}：重置当前标的联动视图配置（对齐原生确认对话框「重置」行为）
    static func settingsResetLinked(_ request: WebBridgeRequest) -> [String: Any] {
        guard let item = currentDetailItem() else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "详情页未就绪，无法重置联动视图")
        }
        LinkedViewStore.shared.reset(for: item.id,
                                     nameHint: (name: item.name, code: item.displayCode, type: item.type))
        DebugLogger.shared.log("[SheetBridge] 重置联动视图配置 \(item.file)")
        return WebBridgeResponse.ok(request.id)
    }

    // MARK: 图表搜索

    /// chart.search.query {keyword}：DatabaseManager.searchMeta 同口径（代码/名称模糊搜索）
    static func searchQuery(_ request: WebBridgeRequest) -> [String: Any] {
        let kw = ((request.payload["keyword"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            return WebBridgeResponse.ok(request.id, data: ["results": []])
        }
        let hits = DatabaseManager.shared.searchMeta(keyword: kw)
        let results: [[String: Any]] = hits.map { m in
            ["file": m.file, "code": m.displayCode, "name": m.name, "type": m.type]
        }
        return WebBridgeResponse.ok(request.id, data: ["results": results])
    }

    /// chart.search.pick {file}：选中结果 → 回调宿主切标的并重新加载
    static func searchPick(_ request: WebBridgeRequest) -> [String: Any] {
        guard let file = request.payload["file"] as? String,
              let meta = DatabaseManager.shared.metaList.first(where: { $0.file == file }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "未找到标的 \(request.payload["file"] ?? "")")
        }
        shared.close()   // 选完即关（对齐原生 onSelect：关闭搜索栏 + 清空输入）
        shared.pickHandler?(meta)
        DebugLogger.shared.log("[SheetBridge] searchPick \(file)")
        return WebBridgeResponse.ok(request.id)
    }

    // MARK: 指标面板（P2-5b）：快照与写回

    /// chart.indicators.snapshot：主图指标（启用态）+ 主图自定义 + 三副图槽位（分组/选中/自定义）。
    /// 周期上下文 = ChartConfigStore.selectedPeriod（面板打开期间与原生同款）。
    static func indicatorsSnapshotData() -> [String: Any] {
        let config = ChartConfigStore.shared
        let sys = SystemIndicatorStore.shared
        let customs = CustomIndicatorStore.shared
        let period = config.selectedPeriod

        let mainOn = config.mainIndicators(for: period)
        let mainDefsAny: [[String: Any]] = sys.mainIndicatorDefs(period: period).map {
            ["id": $0.id, "name": $0.name, "on": mainOn.contains($0.id)]
        }
        let mainCustomsAny: [[String: Any]] = customs.indicators
            .filter { $0.scope == .main && CustomIndicatorStore.applicablePeriods(of: $0).contains(period) }
            .map {
                ["id": $0.id.uuidString, "name": $0.name, "colorHex": $0.colorHex,
                 "active": config.activeCustomIndicatorID(for: period)?.uuidString == $0.id.uuidString]
            }

        func slotData(_ slot: SubSlot, _ model: SubChartModel, _ title: String) -> [String: Any] {
            var map: [String: [String]] = ["量能": ["VOL", "AMO"]]
            for def in sys.subIndicatorDefs(period: period) {
                let g = def.group.isEmpty ? "其他" : def.group
                map[g, default: []].append(def.id)
            }
            var groupsAny: [[String: Any]] = []
            for g in SystemIndicatorStore.subGroupOrder where map[g] != nil {
                groupsAny.append(["group": g, "kinds": map[g]!])
            }
            for (g, kinds) in map where !SystemIndicatorStore.subGroupOrder.contains(g) {
                groupsAny.append(["group": g, "kinds": kinds])
            }
            let customsAny: [[String: Any]] = customs.indicators
                .filter { $0.scope == .sub && CustomIndicatorStore.applicablePeriods(of: $0).contains(period) }
                .map {
                    ["id": $0.id.uuidString, "name": $0.name, "colorHex": $0.colorHex,
                     "active": model.activeCustomID?.uuidString == $0.id.uuidString]
                }
            return ["slot": shared.subSlotKey(slot), "title": title,
                    "kind": model.isCustom ? NSNull() : model.kind,
                    "customID": model.activeCustomID?.uuidString ?? NSNull(),
                    "hasTemplate": !model.isCustom && sys.template(for: model.kind, period: period) != nil,
                    "groups": groupsAny, "customs": customsAny]
        }

        let subSlotsAny: [[String: Any]] = [
            slotData(.top, config.subTop, "副图一"),
            slotData(.bottom, config.subBottom, "副图二"),
            slotData(.third, config.subThird, "副图三"),
        ]

        return ["period": period.rawValue, "mainDefs": mainDefsAny,
                "mainCustoms": mainCustomsAny, "subSlots": subSlotsAny]
    }

    /// chart.indicators.toggleMain {id, on}：主图指标开关（目标态幂等）→ 重算
    static func indicatorsToggleMain(_ request: WebBridgeRequest) -> [String: Any] {
        guard let id = request.payload["id"] as? String,
              let on = request.payload["on"] as? Bool else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要 id 与 on")
        }
        let config = ChartConfigStore.shared
        var cur = config.mainIndicators(for: config.selectedPeriod)
        if on { cur.insert(id) } else { cur.remove(id) }
        var copy = config.mainIndicatorsByPeriod
        copy[config.selectedPeriod] = cur
        config.mainIndicatorsByPeriod = copy
        shared.recomputeHandler?()
        return WebBridgeResponse.ok(request.id)
    }

    /// chart.indicators.selectSub {slot, kind?|customID?}：副图槽位选择（二选一）→ 记忆 + 重算
    static func indicatorsSelectSub(_ request: WebBridgeRequest) -> [String: Any] {
        guard let slotKey = request.payload["slot"] as? String,
              let slot = subSlot(slotKey) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 slot")
        }
        let config = ChartConfigStore.shared
        let model: SubChartModel
        switch slot {
        case .top: model = config.subTop
        case .bottom: model = config.subBottom
        case .third: model = config.subThird
        }
        if let customRaw = request.payload["customID"] as? String, let customID = UUID(uuidString: customRaw) {
            model.activeCustomID = customID
        } else if let kind = request.payload["kind"] as? String {
            model.activeCustomID = nil
            model.kind = kind
        } else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "需要 kind 或 customID")
        }
        config.recordSubKinds(for: config.selectedPeriod)
        shared.recomputeHandler?()
        return WebBridgeResponse.ok(request.id)
    }

    /// chart.indicators.activateMainCustom {customID|null}：激活/取消主图自定义指标 → 重算
    static func indicatorsActivateMainCustom(_ request: WebBridgeRequest) -> [String: Any] {
        let config = ChartConfigStore.shared
        if let raw = request.payload["customID"] as? String {
            guard let id = UUID(uuidString: raw) else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "customID 无效")
            }
            config.setActiveCustom(id, for: config.selectedPeriod)
        } else {
            config.setActiveCustom(nil, for: config.selectedPeriod)
        }
        shared.recomputeHandler?()
        return WebBridgeResponse.ok(request.id)
    }

    /// chart.indicators.resetBuiltin {}：重置内置指标为编译时内容 → 重算（对齐原生 performResetBuiltin）
    static func indicatorsResetBuiltin(_ request: WebBridgeRequest) -> [String: Any] {
        let ok = SystemIndicatorStore.shared.restoreAllBuiltin(period: ChartConfigStore.shared.selectedPeriod)
        shared.recomputeHandler?()
        if ok {
            return WebBridgeResponse.ok(request.id)
        }
        return WebBridgeResponse.fail(request.id, code: "internal_error", message: "重置内置指标部分失败")
    }

    /// chart.indicators.openSystemEditor {isMain, subId?}：关闭面板 → 桥接原生系统指标编辑器
    static func indicatorsOpenSystemEditor(_ request: WebBridgeRequest) -> [String: Any] {
        let isMain = (request.payload["isMain"] as? Bool) ?? true
        let subId = request.payload["subId"] as? String
        shared.close()
        shared.editorHandler?(.system(isMain: isMain, subId: subId))
        return WebBridgeResponse.ok(request.id)
    }

    /// chart.indicators.openCustomEditor {target}：关闭面板 → 桥接原生自定义指标编辑器
    static func indicatorsOpenCustomEditor(_ request: WebBridgeRequest) -> [String: Any] {
        guard let targetRaw = request.payload["target"] as? String,
              let target: EditorTarget = targetRaw == "main" ? .main : (targetRaw == "sub" ? .sub : nil) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "target 必须为 main / sub")
        }
        shared.close()
        shared.editorHandler?(.custom(target: target))
        return WebBridgeResponse.ok(request.id)
    }

    // MARK: 公式中心（P2-6b）：tech 段快照与删除

    /// chart.formula.snapshot：tech 段三节（系统主图 / 系统副图按 group / 自定义指标）。
    /// 系统指标含当前周期公式模板有无（可编辑判断）；自定义含适用周期与色条。
    static func formulaSnapshotData() -> [String: Any] {
        let sys = SystemIndicatorStore.shared
        let customs = CustomIndicatorStore.shared
        let period = ChartConfigStore.shared.selectedPeriod

        let mainItems: [[String: Any]] = sys.mainIndicatorDefs(period: period).map {
            ["id": $0.id, "name": $0.name, "isSystem": true,
             "hasTemplate": sys.template(for: $0.id, period: period) != nil]
        }
        var subGroups: [[String: Any]] = []
        var map: [String: [String]] = ["量能": ["VOL", "AMO"]]
        for def in sys.subIndicatorDefs(period: period) {
            let g = def.group.isEmpty ? "其他" : def.group
            map[g, default: []].append(def.id)
        }
        for g in SystemIndicatorStore.subGroupOrder where map[g] != nil {
            subGroups.append(["group": g, "kinds": map[g]!])
        }
        for (g, kinds) in map where !SystemIndicatorStore.subGroupOrder.contains(g) {
            subGroups.append(["group": g, "kinds": kinds])
        }
        let customsAny: [[String: Any]] = customs.indicators
            .filter { $0.scope == .main || $0.scope == .sub }
            .map {
                ["id": $0.id.uuidString, "name": $0.name, "colorHex": $0.colorHex,
                 "scope": $0.scope == .main ? "main" : "sub",
                 "periods": CustomIndicatorStore.applicablePeriods(of: $0).map(\.rawValue)]
            }
        return ["period": period.rawValue,
                "mainItems": mainItems, "subGroups": subGroups, "customs": customsAny]
    }

    /// chart.formula.deleteCustom {id}：删除自定义指标（原生同步落地/删文件/持久化）
    static func formulaDeleteCustom(_ request: WebBridgeRequest) -> [String: Any] {
        guard let raw = request.payload["id"] as? String, let id = UUID(uuidString: raw) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 id")
        }
        CustomIndicatorStore.shared.delete(id)
        DebugLogger.shared.log("[SheetBridge] deleteCustom \(raw)")
        return WebBridgeResponse.ok(request.id)
    }
}

// MARK: - 图表弹层浮层宿主（KlineDetailView 顶层 overlay 挂载）

/// 弹层浮层宿主：遮罩（点击关闭）+ 常驻弹层 WebView（route="sheet"）。
/// WebView 首次打开弹层时创建，之后 opacity 切换复用（同一详情页内零实例化成本）；
/// 关闭只切 opacity（sheet.close 已由 Web 端在面板内发起，遮罩点击同样发 sheet.close）。
struct SheetWebOverlayHost: View {
    @ObservedObject private var bridge = SheetBridge.shared
    /// WebView 是否已创建（创建后保留复用，不再销毁）
    @State private var webCreated = false

    var body: some View {
        ZStack {
            if bridge.activeSheet != nil {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 遮罩点击 = 关闭（走 Web 端同一条 sheet.close 链路）
                        if let sheet = bridge.activeSheet {
                            bridge.sync(sheet, active: false)
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
            }
            if webCreated {
                WebTabHostView(route: "sheet", isOpaque: false)
                    .opacity(bridge.activeSheet != nil ? 1 : 0)
                    .allowsHitTesting(bridge.activeSheet != nil)
                    .animation(.easeInOut(duration: 0.15), value: bridge.activeSheet != nil)
                    .zIndex(2)
            }
            // P2-6b：原生公式中心全屏呈现（Web tech 面板的编辑/新建桥接落点；
            // picker/strategy 段入口直桥原生——编辑器在原生中心内完整可用）
            if let kindRaw = bridge.formulaCenterRequest, let kind = FormulaKind(rawValue: kindRaw) {
                ZStack {
                    FormulaCenterView(initialKind: kind,
                                      onClose: { bridge.formulaCenterRequest = nil })
                }
                .transition(.opacity)
                .zIndex(1001)   // 盖住弹层浮层 WebView
            }
        }
        .onChange(of: bridge.activeSheet) { sheet in
            if sheet != nil, !webCreated { webCreated = true }
        }
    }
}
