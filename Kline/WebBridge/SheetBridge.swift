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

    // MARK: - 打开 / 关闭（宿主同步入口）

    /// 宿主弹层状态 → 桥（onChange 同步）。同值 no-op 防环。
    func sync(_ name: String, active: Bool) {
        if active {
            guard activeSheet != name else { return }
            activeSheet = name
            WebMessageRouter.shared.pushEvent("sheet.open", payload: ["name": name])
            DebugLogger.shared.log("[SheetBridge] open \(name)")
        } else {
            guard activeSheet == name else { return }
            activeSheet = nil
        }
    }

    /// Web sheet.close → 关闭当前弹层并回写宿主状态
    private func close() {
        guard let name = activeSheet else { return }
        activeSheet = nil
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
                WebTabHostView(route: "sheet")
                    .opacity(bridge.activeSheet != nil ? 1 : 0)
                    .allowsHitTesting(bridge.activeSheet != nil)
                    .animation(.easeInOut(duration: 0.15), value: bridge.activeSheet != nil)
                    .zIndex(2)
            }
        }
        .onChange(of: bridge.activeSheet) { sheet in
            if sheet != nil, !webCreated { webCreated = true }
        }
    }
}
