//
//  LinkedKlineTile.swift
//  Kline
//
//  联动多视图中的单个视图块：持有独立(标的,周期)，自行加载该标的该周期的数据，
//  并渲染 KlineChartView。副图一滑动切周期、副图二滑动切标的（与常规一致），
//  副图二指标栏最右侧提供 🔍 搜索（覆盖式搜索栏 + 系统键盘）。
//
//  Created by 孙楚昆 on 2026/8/31.
//

import SwiftUI
import UIKit
import Combine

/// 联动单视图块：负责加载数据 + 渲染图表 + 副图搜索
struct LinkedKlineTile: View {
    /// 当前视图的配置（标的 + 周期），父层驱动；变化时本视图重新加载
    var view: LinkedViewConfig
    /// 所属主标的（用于把本视图的周期/标的变更持久化到该标的名下）
    let ownerMetaID: Int
    /// 是否第一个视图，仅保留用作身份标记（光标联动新语义下所有视图一律居中，不再依赖左右不对称）
    let linkAutoCenter: Bool
    /// 当前是否处于「边」边线调节（禁止十字光标）
    let suppressCrosshair: Bool
    /// 光标联动总开关：true → 本视图 publish/applyLink；false → 各视图光标独立
    let cursorLinkEnabled: Bool
    /// 清光标广播令牌（外层切换光标联动开关/退出联动时更新）
    let cursorClearToken: UUID
    /// 信息栏「主图指标按钮」桥接（由详情页持有并渲染，本视图转交给图表同步标题/点击行为）
    let mainLegendPortal: MainLegendPortal
    /// 多视图共享的 DualLinkSync 联动同步对象：所有 tile 共用同一个，光标 publish/apply 才能真正互通
    let sharedLinkSync: DualLinkSync

    @Binding var showCustomEditor: Bool
    @Binding var showSystemEditor: Bool

    let onCursorChange: (Bool) -> Void

    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var linkedStore = LinkedViewStore.shared
    @ObservedObject private var config = ChartConfigStore.shared

    /// ⚠️ 历史遗留（保留字段，实际 series/isLoading 现在统一走 linkedStore.tileData 共享槽）
    /// 旧 @State chartSeries / isLoading 因 .id 重建时跨实例生命周期丢失，造成
    /// 「SWIPE_IMMEDIATE_LOAD 在旧实例写入正确 series → onAppear 新实例读不到 → 再次查 DB」
    /// 的竞态。保留这些字段只为兼容可能存在的引用点；实际读写均通过 currentSlot/currentSeries。
    @State private var chartSeries: ChartSeries? = nil
    @State private var isLoading = true
    /// 递增加载序号：丢弃过期异步结果，避免快速切周期时旧结果覆盖新周期数据
    @State private var loadTicket = 0

    /// 当前视图对应的共享数据槽（读写全部走这里）
    private var currentSlot: LinkedTileDataSlot {
        linkedStore.slot(ownerMetaID: ownerMetaID, tileIndex: view.index)
    }
    /// 当前用于渲染的 series：共享槽最新值，无则 fallback 到本地 @State
    private var currentSeries: ChartSeries? {
        let s = currentSlot
        if s.loadedMetaID == view.metaID, s.loadedPeriod == view.period {
            return s.series  // 槽中是本次(metaID,period)的结果：直接采用
        }
        // 槽中目标对不上（比如刚切完还没写入，或遗留旧结果）：退回到本地 @State
        return chartSeries
    }
    /// 当前用于显示加载占位的 isLoading：共享槽值（含在途/加载中标记）OR 本地值
    private var currentLoading: Bool {
        let s = currentSlot
        if s.loadedMetaID == view.metaID, s.loadedPeriod == view.period {
            return s.isLoading  // 目标匹配 → 以槽为准
        }
        return s.isLoading || isLoading
    }

    /// 副图二 🔍 搜索栏是否展开
    @State private var showSearch = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if currentLoading {
                Color.white
                    .overlay(ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .gray)))
            } else if let series = currentSeries {
                kline(series: series)
            } else {
                emptyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 身份绑定：同一 owner 下，每一格 (index, metaID, period) 有唯一 SwiftUI identity。
        //
        // 必须把 metaID 和 period 也纳入 identity 的原因：iOS 16 的 onChange(of:) 对 struct let
        // 形参属性的"回调里读 self.view.* 永远是旧快照"这个坑不可修（Task.yield/async 之后
        // self.view 仍然指向调用 onChange 前的旧 view 值，日志已反复实锤）。与其继续在 onChange
        // 上绕弯路，不如直接让 SwiftUI 在「视图的语义 (标的,周期,职责 index, owner)」发生任何
        // 变化时**销毁老 tile、创建全新实例**。
        //
        // 配合共享数据槽 (linkedStore.tileData)：老实例发起的查询、写入的 series，
        // 新实例 onAppear 时直接从槽里拿到（只要目标 metaID/period 对得上），彻底不用重复查。
        .id("\(ownerMetaID)-\(view.index)-\(view.metaID)-\(view.period.rawValue)")
        // onAppear 入口：优先查共享槽 → 已有命中或已在飞 → 0 次 DB 查询；无则发起一次。
        // 完全绕开 onChange/self.view 旧快照坑。
        .onAppear { tryLoadOnAppear() }
    }

    /// onAppear 阶段的加载决策（共享槽 + 在途登记 → 绝大多数命中后根本不查 DB）
    private func tryLoadOnAppear() {
        let s = currentSlot
        // 1) 命中已成功缓存过的同目标 → 直接用，根本不碰 DB
        if s.loadedMetaID == view.metaID, s.loadedPeriod == view.period {
            DebugLogger.shared.log("[LinkedTile#\(view.index)] onAppear⤵️ 命中缓存 meta=\(view.metaID) period=\(view.period.rawValue) rows=\(s.series?.sorted.count ?? 0)")
            // 即便已缓存，若 DB 未就绪仍保持 loading 外观
            if !databaseManager.isLoaded {
                linkedStore.markLoading(ownerMetaID: ownerMetaID, tileIndex: view.index)
                return
            }
            return
        }
        // 2) 已有相同目标在飞（前一个实例 SWIPE_IMMEDIATE_LOAD 发起的）→ 直接等待结果
        if s.inFlightMetaID == view.metaID, s.inFlightPeriod == view.period {
            DebugLogger.shared.log("[LinkedTile#\(view.index)] onAppear⏳ 发现已在途 meta=\(view.metaID) period=\(view.period.rawValue) → 跳过重复查询")
            linkedStore.markLoading(ownerMetaID: ownerMetaID, tileIndex: view.index)
            return
        }
        // 3) DB 未就绪 → 等 loaded 后再次由外部 onChange(databaseManager.isLoaded) 触发
        guard databaseManager.isLoaded else {
            linkedStore.markLoading(ownerMetaID: ownerMetaID, tileIndex: view.index)
            return
        }
        // 4) 以上都不满足 → 真正发起一次加载
        loadData(targetMetaID: view.metaID, targetPeriod: view.period, initiator: "onAppear")
    }

    // MARK: - 数据加载

    /// 加载当前 (targetMetaID, targetPeriod) 的 K 线数据。
    ///
    /// ⚠️ **参数必须显式传入**，绝不允许在函数体内部再读 `self.view.metaID / self.view.period` 作为目标。
    ///
    /// - Parameters:
    ///   - targetMetaID: 本次必须去查的标的 ID
    ///   - targetPeriod: 本次必须去查的周期
    ///   - initiator: 日志标记（"onAppear" / "SWIPE_IMMEDIATE_LOAD" / "SWITCH_ITEM" / "SEARCH"）
    private func loadData(targetMetaID: Int, targetPeriod: KlinePeriod,
                          initiator: String = "caller") {
        let idx = view.index
        // 0) DB 未就绪：只把该格标记为加载中，返回后由 isLoaded.onChange 驱动真查询
        guard databaseManager.isLoaded else {
            linkedStore.markLoading(ownerMetaID: ownerMetaID, tileIndex: idx)
            return
        }
        // 1) 全局在途登记：同 (owner,index,metaID,period) 只允许一次在飞；已经有在飞的直接跳过。
        //    这样 SWIPE_IMMEDIATE_LOAD 在旧实例先登记 → 新实例 onAppear 随后到达时发现已在飞，
        //    根本不重复查，也就不会出现 "新实例的ticket把旧实例正确结果作废" 的反向竞态。
        let started = linkedStore.tryBeginFlight(ownerMetaID: ownerMetaID, tileIndex: idx,
                                                 metaID: targetMetaID, period: targetPeriod)
        // 2) 本地 @State ticket 也同步递增：即便仍有旧异步回调回来，也能被本地 ticket 淘汰。
        let ticket = loadTicket + 1
        loadTicket = ticket
        DebugLogger.shared.log("[LinkedTile#\(idx)] loadData⤴️ [\(initiator)] ticket=\(ticket) \(started ? "START" : "SKIP(inFlight)") targetMeta=\(targetMetaID) targetPeriod=\(targetPeriod.rawValue) owner=\(ownerMetaID)")
        guard started else {
            // 已经有完全相同目标在飞：仅把本地 UI 显示为 loading，其余交给在途结果写入共享槽。
            linkedStore.markLoading(ownerMetaID: ownerMetaID, tileIndex: idx)
            return
        }
        // 3) 本地兜底 @State 也做一次清空（共享槽不会主动清空旧 series，保留旧周期视觉占位）。
        chartSeries = nil
        isLoading = true
        mainLegendPortal.title = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = databaseManager.fetchBars(metaId: targetMetaID, period: targetPeriod)
            DispatchQueue.main.async {
                // ─── 两层守卫（本地实例 ticket + 共享 inFlight 匹配）─────────────────────
                // ① 本地 @State ticket 对不上 → 本地实例生命周期已经跑到更新一轮的 loadData，
                //    但因为我们已经把真正的"写入权威"切到共享槽，所以这里仅当辅助淘汰判断。
                guard self.loadTicket == ticket else {
                    DebugLogger.shared.log("[LinkedTile#\(idx)] loadData⏭️ [\(initiator)] 丢弃过期结果 ticket=\(ticket) current=\(self.loadTicket) rows=\(rows.count) target=\(targetPeriod.rawValue)")
                    // 注意：不清共享槽 inFlight（因为那一轮 inFlight 可能属于更新一轮的查询，
                    // 只有 commitSlot 成功写入时才会"同目标匹配后才清"，天然安全）。
                    return
                }
                // ② 共享槽当前 inFlight 目标必须仍就是本次查询目标 → 快速连切两次周期时，
                //    第一次的查询结果返回，但 inFlight 已经被第二次覆盖，此时第一次结果必须作废，
                //    绝对不能把旧周期/旧标的的 series 写进共享槽覆盖用户最新选择。
                let s = self.currentSlot
                guard s.inFlightMetaID == targetMetaID, s.inFlightPeriod == targetPeriod else {
                    DebugLogger.shared.log("[LinkedTile#\(idx)] loadData⏭️ [\(initiator)] 共享槽 inFlight 不匹配 current=\(s.inFlightMetaID.map(String.init) ?? "-")/\(s.inFlightPeriod?.rawValue ?? "-") vs target=\(targetMetaID)/\(targetPeriod.rawValue) rows=\(rows.count)")
                    return
                }
                // ─── 写入：以共享槽为权威，同时同步到本地 @State 作 fallback 兼容 ──────────
                if rows.isEmpty {
                    self.linkedStore.commitSlot(ownerMetaID: self.ownerMetaID, tileIndex: idx,
                                                metaID: targetMetaID, period: targetPeriod,
                                                series: nil, isLoading: false)
                    self.chartSeries = nil
                    self.isLoading = false
                    DebugLogger.shared.log("[LinkedTile#\(idx)] loadData✅ [\(initiator)] ticket=\(ticket) rows=0 → empty period=\(targetPeriod.rawValue)")
                } else {
                    let newSeries = ChartSeries(data: rows)
                    self.linkedStore.commitSlot(ownerMetaID: self.ownerMetaID, tileIndex: idx,
                                                metaID: targetMetaID, period: targetPeriod,
                                                series: newSeries, isLoading: false)
                    // 周期签名校验（写共享槽成功后，真正唯一可靠的校验点）
                    KlineChartView.verifyPeriodSignature(series: newSeries,
                                                         declared: targetPeriod,
                                                         metaId: targetMetaID)
                    self.chartSeries = newSeries
                    self.isLoading = false
                    DebugLogger.shared.log("[LinkedTile#\(idx)] loadData✅ [\(initiator)] ticket=\(ticket) rows=\(rows.count) period=\(targetPeriod.rawValue) firstDate=\(newSeries.sorted.first?.date ?? 0) lastDate=\(newSeries.sorted.last?.date ?? 0)")
                }
            }
        }
    }

    // MARK: - 子视图

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundColor(.gray.opacity(0.5))
            Text("暂无\(view.displayCode) \(view.period.rawValue)数据")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    /// 渲染单个 K 线图，并把副图二搜索栏作为 overlay 覆盖
    private func kline(series: ChartSeries) -> some View {
        KlineChartView(series: series, chartStyle: $config.chartStyle, displaySettings: $config.displaySettings,
                       showCustomEditor: $showCustomEditor, showSystemEditor: $showSystemEditor,
                       // metaId 传 nil：联动多视图不使用共享 ChartCacheStore，
                       // 避免多个 tile 用相同 metaID 并行预计算互相污染缓存（方向相关的副图空白根因）。
                       // 每次周期/标的切换，.id 变化触发全新图表状态，前台完整重算主图+副图。
                       metaId: nil, period: view.period,
                       isolatedSubs: true, hideMainZoomButton: true, isLinkedTile: true, linkAutoCenter: linkAutoCenter,
                       cursorLinkEnabled: cursorLinkEnabled,
                       cursorClearToken: cursorClearToken,
                       // 联动：时间轴上一行 + 时间轴 pinned 覆盖 都不显示"额"（成交额）
                       hideQuoteTurnover: true,
                       onPeriodSwitch: { newPeriod in
                           // 副图二切周期（联动态）：只改本视图周期，持久化到 owner
                           pinReservedHelper()
                           let idx = view.index
                           let oldPeriod = view.period
                           // 诊断日志：外层滑动回调触发的那一刻，把新/旧周期都记下来。
                           DebugLogger.shared.log("[LinkedTile#\(idx)] SWIPE_CALLBACK \(oldPeriod.rawValue) → \(newPeriod.rawValue) owner=\(ownerMetaID)")
                           guard newPeriod != oldPeriod else { return }
                           var v = view
                           v.period = newPeriod
                           let afterList = replace(v, in: ownerMetaID)
                           linkedStore.setConfigs(afterList, for: ownerMetaID)
                           // 写后回读：绝不能相信"写入就成功了"。如果 setConfigs 内部有任何
                           // 缓存/排序/重写逻辑把 period 拉回旧值，这里立刻会打红级日志，
                           // 直接钉死根因在 store 层而不是 tile/chart 层。
                           let hint = (name: view.name, code: view.code, type: view.type)
                           let reread = linkedStore.configs(for: ownerMetaID, nameHint: hint)
                           if let match = reread.first(where: { $0.index == idx }) {
                               if match.period != newPeriod {
                                   DebugLogger.shared.log("🛑 [LinkedTile#\(idx)] 写后回读不一致！ 期望=\(newPeriod.rawValue) 实际=\(match.period.rawValue) 强制修正")
                                   var list2 = reread
                                   if let i2 = list2.firstIndex(where: { $0.index == idx }) {
                                       list2[i2].period = newPeriod
                                       linkedStore.setConfigs(list2, for: ownerMetaID)
                                   }
                               } else {
                                   // ✅ 写入成功。立刻显式触发一次 loadData，
                                   // 不再依赖 SwiftUI body 重算 / .id 重建后的 onAppear。
                                   // 关键：直接把 newPeriod（本次回调参数的新周期）显式传入，
                                   // 完全绕开「onChange 里 self.view 是旧快照」的语义坑，
                                   // 且 tryBeginFlight 保证后面新实例 onAppear 到达时
                                   // 发现已登记 inFlight → SKIP，不会重复查 / 反向覆盖。
                                   DebugLogger.shared.log("[LinkedTile#\(idx)] SWIPE_IMMEDIATE_LOAD meta=\(v.metaID) period=\(newPeriod.rawValue)（不依赖 onChange）")
                                   loadData(targetMetaID: v.metaID, targetPeriod: newPeriod,
                                            initiator: "SWIPE_IMMEDIATE_LOAD")
                               }
                           } else {
                               DebugLogger.shared.log("🛑 [LinkedTile#\(idx)] 写后回读找不到第 \(idx) 格视图！ reread.count=\(reread.count)")
                           }
                       },
                       onPeriodPrefetched: { _ in },
                       onSwitchItem: { dir in
                           // 副图一切标的（联动态）
                           pinReservedHelper()
                           switchItem(dir)
                       },
                       canSwitchItem: { dir in
                           linkedStore.canSwitchItem(current: view, dir: dir)
                       },
                       pinEnabled: .constant(false),
                       onHasCursorChange: onCursorChange,
                       suppressCrosshair: suppressCrosshair,
                       swapSubSwipeRoles: false,
                       showSubTwoSearchButton: true,
                       onSubTwoSearch: {
                           showSearch = true
                           // 打开搜索栏时弹起系统键盘
                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                               searchFocused = true
                           }
                       },
                       mainLegendPortal: mainLegendPortal,
                       linkSync: sharedLinkSync)
            .overlay {
                if showSearch {
                    chartSearchBar
                }
            }
            .id(chartIdentity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 图表身份：绑定(标的,周期)。配合 metaId=nil，周期/标的切换必定创建全新图表状态
    /// （全新隔离副图 @StateObject + 前台完整重算），避免折返复用残留或共享缓存串扰。
    private var chartIdentity: String {
        "\(view.metaID)-\(view.period.rawValue)"
    }

    /// 占位（原详情页在切周期/标的时会重置 pin；本 tile 已无全局 pin，保留空实现保证类型一致）
    private func pinReservedHelper() {}

    /// 在本 owner 的配置里替换第 view.index 个视图（按元素的 index 字段查找，不信任数组下标）。
    /// 历史上文件读写/重排可能导致 JSON 数组顺序与 LinkedViewConfig.index 字段不一致，
    /// 此时继续用 list[newView.index] 替换会把新周期写到另一视图的位置，造成"信息栏显示周期A、
    /// 实际加载周期B的数据"。改为精确匹配 element.index 字段，彻底消除顺序漂移风险。
    private func replace(_ newView: LinkedViewConfig, in metaID: Int) -> [LinkedViewConfig] {
        let hint = (name: view.name, code: view.code, type: view.type)
        var list = linkedStore.configs(for: metaID, nameHint: hint)
        if let matchIdx = list.firstIndex(where: { $0.index == newView.index }) {
            list[matchIdx] = newView
        } else {
            list.append(newView)
        }
        return list
    }

    /// 本视图按候选列表切换标的（dir = -1 上一个 / +1 下一个）
    private func switchItem(_ dir: Int) {
        guard let routerItem = DetailRouter.shared.item else { return }
        let candidates = DetailRouter.shared.navItems
        guard !candidates.isEmpty else { return }
        guard let curIdx = candidates.firstIndex(where: { $0.id == view.metaID }) else { return }
        let t = curIdx + dir
        guard t >= 0, t < candidates.count else { return }
        let next = candidates[t]
        var v = view
        v.metaID = next.id
        v.name = next.name
        v.code = next.code
        v.type = next.type
        let p = v.period
        DebugLogger.shared.log("[LinkedTile#\(v.index)] SWITCH_ITEM meta=\(view.metaID)→\(next.id) keep period=\(p.rawValue)")
        linkedStore.setConfigs(replace(v, in: ownerMetaID), for: ownerMetaID)
        // 写后立刻显式取一次（新 metaID / 原周期）。tryBeginFlight 会防止 .id 重建后的
        // 新实例 onAppear 再重复发起一次查询。
        loadData(targetMetaID: next.id, targetPeriod: p, initiator: "SWITCH_ITEM")
    }

    // MARK: - 副图二搜索栏（覆盖式）

    private var chartSearchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    showSearch = false
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                TextField("搜索\(view.name)", text: $searchText)
                    .font(.system(size: 14))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(6)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white)

            if !searchText.isEmpty {
                searchResultList
            }
        }
        .background(Color.white)
        .transition(.opacity)
    }

    private var searchResultList: some View {
        SearchContentView(searchText: $searchText) { result in
            // 副图二搜索：把选中标的应用到本视图（只改本视图，选中后关闭搜索栏）
            var v = view
            v.metaID = result.id
            v.name = result.name
            v.code = result.code
            v.type = result.type
            let p = v.period
            DebugLogger.shared.log("[LinkedTile#\(v.index)] SEARCH_SELECT meta=\(view.metaID)→\(result.id) keep period=\(p.rawValue) name=\(result.name) code=\(result.code)")
            linkedStore.setConfigs(replace(v, in: ownerMetaID), for: ownerMetaID)
            showSearch = false
            searchText = ""
            searchFocused = false
            // 写后立刻显式取一次（新 metaID / 原周期）。tryBeginFlight 防止新实例 onAppear 重复查。
            loadData(targetMetaID: result.id, targetPeriod: p, initiator: "SEARCH")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 搜索候选项列表（复用行情页搜索逻辑）

/// 搜索候选结果容器：内部执行与行情页相同的模糊搜索，把命中项回调给父层
struct SearchContentView: View {
    @Binding var searchText: String
    /// 点击某条时回调选中标的
    let onSelect: (MetaItem) -> Void
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @State private var results: [MetaItem] = []
    @State private var searchTask: DispatchWorkItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if results.isEmpty {
                    Text("没有匹配的标的")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .padding(12)
                } else {
                    ForEach(results) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            row(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: searchText) { newValue in
            performSearch(keyword: newValue)
        }
        .onAppear { performSearch(keyword: searchText) }
    }

    private func row(_ item: MetaItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name)
                    .font(.system(size: 14))
                    .foregroundColor(.black)
                    .lineLimit(1)
                Spacer()
                Text(item.displayCode)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            Divider().padding(.leading, 12)
        }
    }

    private func performSearch(keyword: String) {
        searchTask?.cancel()
        let task = DispatchWorkItem {
            let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kw.isEmpty else {
                DispatchQueue.main.async { self.results = [] }
                return
            }
            let hits = databaseManager.searchMeta(keyword: kw)
            DispatchQueue.main.async { self.results = hits }
        }
        searchTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }
}