//
//  HomeBridge.swift
//  Kline
//
//  Home 域的桥接动作实现（协议 v2 home.*）：首页 Web 化的 Swift 侧。
//  数据全部来自原生（HomePageModel 聚合快照 / SimStore / FavoritesStore / DatabaseManager），
//  Web 侧零状态。数据流对齐 MarketBridge：动作写状态 → home.changed（节流 ~0.8s）→ Web 回读快照。
//
//  入口动作（home.openEntry）桥接到原生全屏浮层（搜索 / 公式中心分段 / 条件单 / 触发记录 /
//  训练 / 联机同步 / 引擎实验室 / 个人中心），由 HomeWebShellView overlay 挂载呈现。
//  「布局编辑」入口随 JSON 布局引擎退役，Web 版快照不返回该入口、动作显式报错。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import SwiftUI

@MainActor
final class HomeBridge: ObservableObject {

    static let shared = HomeBridge()

    /// Web 模式专用的首页数据模型（聚合快照由模型内部 250ms 防抖维护）
    let model = HomePageModel()

    // MARK: 原生全屏浮层桥（HomeWebShellView overlay 挂载呈现）

    /// 搜索态（HomeSearchModeView 覆盖层，对齐原生 HomeView 的 isSearching）
    @Published var isSearching = false
    /// 个人中心（ProfileDetailView，对齐 ContentView 根层 isProfilePresented）
    @Published var isProfilePresented = false
    /// 浮层单一呈现目标（公式管理中心分段 / 条件单 / 触发记录 / 联机同步 / 引擎实验室）
    @Published var overlayTarget: HomeOverlayTarget? = nil

    // MARK: 变化信号 → home.changed 节流推送

    private var cancellables = Set<AnyCancellable>()
    private var changedItem: DispatchWorkItem? = nil
    private var pendingReason = "data"
    /// 节流窗口（与 MarketBridge 同口径；实测后调参）
    private let changedThrottle: TimeInterval = 0.8

    private init() {
        // 聚合快照变化（模型内部 250ms 防抖合并，高频信号已在其内部收敛）
        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged(reason: "data") }
            .store(in: &cancellables)

        // 行缓存变化（指数/自选/涨幅榜行的数值与迷你走势更新）
        MarketRowCache.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged(reason: "data") }
            .store(in: &cancellables)

        // 自选增删改
        FavoritesStore.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged(reason: "edit") }
            .store(in: &cancellables)

        // 模拟账户 / 持仓 / 条件单变化
        SimStore.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged(reason: "sim") }
            .store(in: &cancellables)

        // 库就绪 → HomePageModel 自己的 sink 会安排 250ms 防抖重算（防抖异步执行时
        // isLoaded 已实际写入，天然避开 willSet 时序坑）→ 这里只补一次推送
        DatabaseManager.shared.$isLoaded
            .dropFirst()
            .sink { [weak self] loaded in
                guard loaded else { return }
                DispatchQueue.main.async { self?.scheduleChanged(reason: "data") }
            }
            .store(in: &cancellables)
    }

    /// 节流合并推送（对齐 MarketBridge.scheduleChanged）
    private func scheduleChanged(reason: String) {
        pendingReason = reason
        guard changedItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedItem = nil
            WebMessageRouter.shared.pushEvent("home.changed",
                                              payload: ["reason": self.pendingReason])
        }
        changedItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + changedThrottle, execute: item)
    }

    /// 写回/入口动作后立即推送（不经节流）
    private func notifyChangedNow(reason: String) {
        changedItem?.cancel()
        changedItem = nil
        WebMessageRouter.shared.pushEvent("home.changed", payload: ["reason": reason])
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "openEntry":
            return openEntry(request)
        case "openDetail":
            return openDetail(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "home.\(request.action) 未实现")
        }
    }

    // MARK: - 快照组装

    /// 语义色 hex（对齐 HomeEntryKind.tint；语义色 → 深浅色自适应由 Web 端 CSS 变量承接）
    private static func tintHex(_ kind: HomeEntryKind) -> String {
        switch kind {
        case .search: return "#007aff"
        case .tech: return "#af52de"
        case .picker: return "#ff9500"
        case .strategy: return "#30b0c7"
        case .condOrder: return "#ff3b30"
        case .profile: return "#007aff"
        case .alertRecords: return "#ff2d92"
        case .training: return "#34c759"
        case .layoutEditor: return "#5856d6"
        case .lanSync: return "#32ade6"
        case .pythonLab: return "#00c7be"
        }
    }

    /// 行 → 快照字典（price/pct 未就绪发 null；closes = 迷你走势最近 20 根收盘价）
    private static func quoteData(_ row: MarketRow, closes: Bool) -> [String: Any] {
        var d: [String: Any] = [
            "file": row.meta.file,
            "code": row.meta.displayCode,
            "name": row.meta.name,
            "price": row.number(.latestPrice) ?? NSNull(),
            "pct": row.number(.changePct) ?? NSNull(),
        ]
        if closes {
            d["closes"] = Array(row.recentCloses.suffix(20))
        }
        return d
    }

    /// home.snapshot：入口清单（layoutEditor 退役不返回）+ 指数行 + 涨跌家数 +
    /// 自选 Top5（带迷你走势）+ 模拟摘要/持仓 + 涨幅榜 Top5
    static func snapshotData() -> [String: Any] {
        let bridge = HomeBridge.shared
        let model = bridge.model
        let dbm = DatabaseManager.shared

        let entriesAny: [[String: Any]] = HomeEntryKind.allCases
            .filter { $0 != .layoutEditor }
            .map { kind in
                ["id": kind.rawValue,
                 "title": kind.title,
                 "subtitle": kind.subtitle,
                 "tint": tintHex(kind)]
            }

        let indicesAny: [[String: Any]] = model.indexQuotes.map { quoteData($0, closes: false) }

        var breadthAny: Any = NSNull()
        if let b = model.breadth {
            breadthAny = ["up": b.up, "down": b.down, "flat": b.flat,
                          "limitUp": b.limitUp, "limitDown": b.limitDown]
        }

        let favoritesAny: [[String: Any]] = model.favoriteRows.map { quoteData($0, closes: true) }

        let s = model.simSummary(accountIDString: nil)
        let simAny: [String: Any] = ["totalAssets": s.totalAssets,
                                     "dayProfit": s.dayProfit,
                                     "dayProfitPct": s.dayProfitPct,
                                     "positionPct": s.positionPct]
        let positionsAny: [[String: Any]] = model.topPositions(accountIDString: nil).map { p in
            let snap = model.simSnapshot(for: p)
            return ["code": p.code, "name": p.name,
                    "lastPrice": snap.lastPrice,
                    "profit": snap.profit, "profitPct": snap.profitPct]
        }

        let gainersAny: [[String: Any]] = model.gainersRows(board: nil).map { quoteData($0, closes: false) }

        return [
            "loaded": dbm.isLoaded,
            "hasMainBoard": dbm.metaList.contains { $0.type == "沪深主板" },
            "entries": entriesAny,
            "indices": indicesAny,
            "breadth": breadthAny,
            "favorites": favoritesAny,
            "sim": simAny,
            "simPositions": positionsAny,
            "gainers": gainersAny,
            "gainersReady": model.gainersReady(board: nil),
        ]
    }

    // MARK: - 入口桥接

    /// home.openEntry {kind}：入口动作桥接（浮层由 HomeWebShellView overlay 呈现）。
    /// 切 Tab 类入口（自选/行情/模拟）不在入口清单（与底栏重复，原生已剔除）。
    private static func openEntry(_ request: WebBridgeRequest) -> [String: Any] {
        guard let raw = request.payload["kind"] as? String,
              let kind = HomeEntryKind(rawValue: raw) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "需要有效 kind")
        }
        let bridge = HomeBridge.shared
        switch kind {
        case .search:
            bridge.isSearching = true
        case .tech:
            // P2-6b：公式中心 tech 段迁 Web 面板（picker/strategy 段桥接原生全屏中心）
            SheetBridge.shared.openFormulaCenter(.tech)
        case .picker:
            SheetBridge.shared.openFormulaCenter(.picker)
        case .strategy:
            SheetBridge.shared.openFormulaCenter(.strategy)
        case .condOrder:
            bridge.overlayTarget = .condOrder
        case .alertRecords:
            bridge.overlayTarget = .alertRecords
        case .lanSync:
            // P2-6c-1：迁 Web 全屏页（原生 overlayTarget 分支保留可回退）
            WebPageBridge.shared.open("lanSync")
        case .pythonLab:
            WebPageBridge.shared.open("pythonLab")
        case .training:
            // P2-6c-3：训练设置浮层迁 Web（sheet.open("training")，SheetPage 居中卡片面板）。
            // closeHandler 回写 TrainingSetupRouter（保持 false，原生浮层不出现）；原生链路保留可回退
            SheetBridge.shared.closeHandler = { _ in TrainingSetupRouter.shared.isPresented = false }
            SheetBridge.shared.sync("training", active: true)
        case .profile:
            bridge.isProfilePresented = true
        case .layoutEditor:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "布局编辑入口已随 JSON 布局引擎退役")
        }
        DebugLogger.shared.log("[HomeBridge] openEntry \(raw)")
        return WebBridgeResponse.ok(request.id)
    }

    /// home.openDetail {file, context?}：进 K 线详情（context = 副图左右切换上下文）
    private static func openDetail(_ request: WebBridgeRequest) -> [String: Any] {
        let dbm = DatabaseManager.shared
        guard let file = request.payload["file"] as? String,
              let meta = dbm.metaList.first(where: { $0.file == file }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "未找到标的 \(request.payload["file"] ?? "")")
        }
        // context：file 列表 → metas（含目标自身，保持 Web 端传入顺序）
        var context: [MetaItem] = []
        if let files = request.payload["context"] as? [String] {
            let byFile = Dictionary(files.compactMap { m in dbm.metaList.first(where: { $0.file == m }).map { ($0.file, $0) } },
                                    uniquingKeysWith: { a, _ in a })
            for f in files {
                if let m = byFile[f] { context.append(m) }
            }
        }
        if context.isEmpty {
            DetailRouter.shared.item = meta
        } else {
            DetailRouter.shared.open(meta, in: context)
        }
        DebugLogger.shared.log("[HomeBridge] openDetail \(file) context=\(context.count)")
        return WebBridgeResponse.ok(request.id)
    }
}

// MARK: - 首页 Tab 的 Web 宿主（WebTabHostView + 原生浮层挂载）

/// 首页 Tab 内容的混合宿主：Web 页主体 + 原生全屏浮层（搜索 / 个人中心 / 公式中心 /
/// 条件单 / 触发记录 / 联机同步 / 引擎实验室）。浮层状态由 HomeBridge 持有，
/// home.openEntry 写入，关闭走浮层内返回按钮写回。P2-6 才将这些页面 Vant 化。
struct HomeWebShellView: View {
    @ObservedObject private var bridge = HomeBridge.shared
    @State private var searchText = ""

    var body: some View {
        WebTabHostView(route: "home")
            .overlay {
                // 搜索态：复用 HomeSearchModeView（返回按钮 + 搜索框 + 搜索结果页）
                if bridge.isSearching {
                    HomeSearchModeView(searchText: $searchText,
                                       isSearching: $bridge.isSearching)
                        .transition(.opacity)
                }
                // 个人中心：对齐 ContentView 根层呈现
                if bridge.isProfilePresented {
                    ProfileDetailView(isPresented: $bridge.isProfilePresented)
                        .transition(.opacity)
                }
                // 公式中心 / 条件单 / 触发记录 / 联机同步 / 引擎实验室
                if let t = bridge.overlayTarget {
                    ZStack {
                        switch t {
                        case .formula(let kind):
                            FormulaCenterView(initialKind: kind,
                                              onClose: { bridge.overlayTarget = nil })
                                .id(t.id)
                        case .condOrder:
                            SimCondListView(accountID: nil, onClose: { bridge.overlayTarget = nil })
                        case .alertRecords:
                            AlertRecordView(onClose: { bridge.overlayTarget = nil })
                        case .lanSync:
                            // P2-6c-1 起入口走 WebPageBridge（本原生分支仅回退用：恢复
                            // openEntry 的 overlayTarget 赋值即可重新启用）
                            LANSyncView(onClose: { bridge.overlayTarget = nil })
                        case .pythonLab:
                            PythonEngineLabView(onClose: { bridge.overlayTarget = nil })
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
                // P2-6c-1：全屏 Web 页宿主（联机同步/本地更新/引擎实验室）。
                // zIndex 1002 盖过原生 overlay 组（1000）与个人中心；不盖底部 Tab 栏（对齐原生 UX）
                WebFullscreenPageHost()
                    .zIndex(1002)
            }
    }
}
