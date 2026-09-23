//
//  SearchPageView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/24.
//  2026/09/23 搜索页整改：热门搜索改为本地搜索历史；股票类型改类型筛选；
//  结果行支持长按管理（与行情页同一套面板/MetaRowMenuKit）；整页补系统底避免透出背后页面。
//

import SwiftUI

// MARK: - 搜索页状态模型

/// 搜索页状态模型：关键字结果快照 / 类型筛选快照 / 长按面板与弹窗目标。
/// 快照只在事件里算好（芯片点击、搜索回调），`body` 内不遍历 `metaList`（全市场 3600+ 只）。
@MainActor
final class SearchPageModel: ObservableObject {

    /// 关键字搜索结果快照（搜索回调写入）
    @Published var searchResults: [MetaItem] = []
    /// 本次关键字搜索是否已回调（决定空态是「搜索中…」还是「未找到匹配的标的」）
    @Published var keywordSearched = false
    /// 当前「股票类型」筛选（nil = 未筛选）
    @Published var typeFilter: String? = nil
    /// 该类型全部标的快照（点芯片时一次性过滤）
    @Published var typeResults: [MetaItem] = []

    // 长按面板 / 弹窗目标（与行情页同一套组件与动作口径）
    @Published var rowMenuTarget: FavoritesRowMenuTarget? = nil
    @Published var noteEditorTarget: FavoritesRowMenuTarget? = nil
    @Published var alertSheetTargets: [MetaItem] = []
    @Published var addGroupTarget: MetaItem? = nil

    private let db = DatabaseManager.shared
    private let history = SearchHistoryStore.shared
    /// 搜索序号：丢弃过期回调（快速输入时后发的查询可能先返回）
    private var searchToken = 0

    // MARK: 关键字搜索

    /// 关键字搜索：空关键字即清结果与完成标记
    func search(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        searchToken += 1
        let token = searchToken
        guard !kw.isEmpty else {
            searchResults = []
            keywordSearched = false
            return
        }
        keywordSearched = false
        db.searchMetaAsync(keyword: kw) { [weak self] results in
            // 回调本身在主线程，但模型是 @MainActor：显式跳回主 actor 再写状态
            Task { @MainActor in
                guard let self = self, token == self.searchToken else { return }
                self.searchResults = results
                self.keywordSearched = true
            }
        }
    }

    // MARK: 类型筛选

    /// 类型芯片：再点同一个 = 取消筛选（回到热门搜索页）
    func toggleType(_ type: String) {
        if typeFilter == type {
            typeFilter = nil
            typeResults = []
        } else {
            typeFilter = type
            typeResults = db.metaList.filter { $0.type == type }
        }
    }

    /// 数据库刚加载完时补算一次：避免冷启动下先点类型芯片拿到空快照
    func reloadTypeResults() {
        guard let type = typeFilter else { return }
        typeResults = db.metaList.filter { $0.type == type }
    }

    // MARK: 打开结果

    /// 打开结果：先记搜索历史（热门搜索的唯一写入点），再开全屏详情
    func open(_ meta: MetaItem, in list: [MetaItem]) {
        history.record(meta)
        DetailRouter.shared.open(meta, in: list)
    }

    // MARK: 长按操作面板（口径与行情页共用 MetaRowMenuKit）

    func openRowMenu(_ meta: MetaItem) {
        let target = FavoritesRowMenuTarget(meta: meta, groupID: nil, isMarketPage: true)
        if rowMenuTarget != target { rowMenuTarget = target }
    }

    func rowMenuItems(for target: FavoritesRowMenuTarget) -> [FavoritesRowMenuItem] {
        MetaRowMenuKit.items(for: target.meta)
    }

    func performRowMenu(_ action: FavoritesRowMenuAction, for target: FavoritesRowMenuTarget) {
        guard let outcome = MetaRowMenuKit.perform(action, for: target) else { return }
        switch outcome {
        case .addToGroup(let meta):
            addGroupTarget = meta
        case .note(let noteTarget):
            noteEditorTarget = noteTarget
        case .alert(let meta):
            alertSheetTargets = [meta]
        }
    }
}

// MARK: - 搜索页

/// 搜索页：默认态（热门搜索 + 股票类型）/ 关键字结果 / 类型筛选结果三态互斥。
/// 由首页搜索模式（A/B/C/D 与 JSON 配置档共用）与行情页搜索浮层（四档共用）共用，
/// 故整页自带系统底色：作为浮层呈现时不会透出背后的行情表，也不会让点击穿透过去。
struct SearchPageView: View {
    @Binding var searchText: String

    @StateObject private var model = SearchPageModel()
    /// 热门搜索的数据源（点开结果写入后，chips 立即刷新）
    @ObservedObject private var historyStore = SearchHistoryStore.shared
    /// 只用于「数据库刚就绪」时补算类型筛选快照
    @ObservedObject private var databaseManager = DatabaseManager.shared

    /// 无搜索历史时的回落清单（首启即用得着，不显空区块）
    private static let fallbackHotNames = ["贵州茅台", "比亚迪", "宁德时代", "东方财富", "药明康德"]
    /// 「股票类型」取值与 tdx `meta.type` 一致
    private static let typeNames = ["沪深主板", "沪深京指数", "扩展行情指数"]

    /// 热门搜索 chips 文案：优先本地历史（最近点开的标的），无历史回落固定清单
    private var hotNames: [String] {
        let names = historyStore.entries.map(\.name)
        return names.isEmpty ? Self.fallbackHotNames : names
    }

    var body: some View {
        VStack(spacing: 0) {
            if !searchText.isEmpty {
                keywordResultsView
            } else if let type = model.typeFilter {
                typeResultsView(type)
            } else {
                defaultView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .onChange(of: searchText) { newValue in
            model.search(newValue)
        }
        .onReceive(databaseManager.$isLoaded) { loaded in
            if loaded { model.reloadTypeResults() }
        }
        .overlay { rowMenuLayers }
        .sheet(item: Binding(
            get: { model.addGroupTarget.map(SearchIdentifiableMeta.init) },
            set: { model.addGroupTarget = $0?.meta }
        )) { wrap in
            AddToGroupSheet(meta: wrap.meta, fav: FavoritesStore.shared)
        }
    }

    // MARK: - 默认态（热门搜索 + 股票类型）

    private var defaultView: some View {
        VStack(spacing: 16) {
            chipSection(title: "热门搜索") {
                ForEach(hotNames, id: \.self) { name in
                    chip(name) { searchText = name }
                }
            }

            chipSection(title: "股票类型") {
                ForEach(Self.typeNames, id: \.self) { type in
                    chip(type, selected: model.typeFilter == type) {
                        model.toggleType(type)
                    }
                }
            }

            Spacer()
        }
    }

    /// 分区：标题 + 一行横滑芯片（热门搜索 / 股票类型共用同一规格）
    private func chipSection<Content: View>(title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.leading, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    content()
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// 单个芯片：视觉高约 33pt（与整改前逐值一致），命中区补到 44pt；
    /// 选中态用于「股票类型」（蓝底白字），热门搜索恒为未选中态。
    private func chip(_ title: String, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundColor(selected ? .white : .primary)
                .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .background(selected ? Color.accentColor : Color(.systemGray5))
                .cornerRadius(20)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 关键字结果

    private var keywordResultsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.searchResults.isEmpty {
                    emptyState(model.keywordSearched ? "未找到匹配的标的" : "搜索中…",
                               showsSpinner: !model.keywordSearched)
                } else {
                    ForEach(model.searchResults) { item in
                        resultRow(item, list: model.searchResults)
                    }
                }
            }
        }
    }

    // MARK: - 类型筛选结果

    private func typeResultsView(_ type: String) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // 列表标题：避免「这是什么列表」无上下文
                HStack(spacing: 0) {
                    Text("\(type) · 共 \(model.typeResults.count) 只")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: 32)

                if model.typeResults.isEmpty {
                    emptyState(databaseManager.isLoaded ? "该类型暂无标的" : "数据加载中…",
                               showsSpinner: !databaseManager.isLoaded)
                } else {
                    ForEach(model.typeResults) { item in
                        resultRow(item, list: model.typeResults)
                    }
                }
            }
        }
    }

    // MARK: - 结果行（关键字结果 / 类型筛选结果共用）

    /// 结果行：内层点击开详情，外层长按出操作面板 —— 与行情页 `rowCard` 同款结构
    /// （点击在行内容上、长按在行容器上），两种手势互不吞。
    private func resultRow(_ item: MetaItem, list: [MetaItem]) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 16, weight: .medium))

                    Text(item.code)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.type)
                        .font(.system(size: 12))
                        .foregroundColor(.blue)

                    if let lastDate = item.lastDate {
                        Text(String(lastDate))
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { model.open(item, in: list) }

            Divider()
                .padding(.leading, 80)
        }
        .background(Color(.systemBackground))
        // 长按出操作面板：面板挂在页面自身容器层 overlay，行自身无样式改动
        // （不用 .contextMenu —— 它走 UIContextMenuInteraction 抬升快照管线，会把行换宿主重排）
        .onLongPressGesture(minimumDuration: 0.5) {
            withAnimation(.easeOut(duration: 0.15)) {
                model.openRowMenu(item)
            }
        }
    }

    /// 空态：加载中给转圈，已完成给纯文案
    private func emptyState(_ text: String, showsSpinner: Bool) -> some View {
        VStack(spacing: 16) {
            if showsSpinner {
                ProgressView()
                    .padding()
            }
            Text(text)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    // MARK: - 长按面板 / 弹窗（与行情页同一套组件与文案）

    @ViewBuilder
    private var rowMenuLayers: some View {
        if let target = model.rowMenuTarget {
            FavoritesOverlayCard(onDismiss: { closeRowMenu() }) {
                FavoritesRowMenuPanel(title: target.meta.name,
                                      subtitle: target.meta.displayCode,
                                      items: model.rowMenuItems(for: target),
                                      onSelect: { action in
                                          closeRowMenu()
                                          model.performRowMenu(action, for: target)
                                      },
                                      onCancel: { closeRowMenu() })
            }
        }
        if let target = model.noteEditorTarget {
            FavoritesOverlayCard(onDismiss: { closeNoteEditor() }) {
                FavoritesNoteSheet(meta: target.meta,
                                   initialText: FavoritesStore.shared.note(for: target.meta.id) ?? "",
                                   onSave: { text in
                                       FavoritesStore.shared.setNote(metaID: target.meta.id, text: text)
                                       closeNoteEditor()
                                   },
                                   onClear: {
                                       FavoritesStore.shared.setNote(metaID: target.meta.id, text: "")
                                       closeNoteEditor()
                                   },
                                   onCancel: { closeNoteEditor() })
            }
        }
        if !model.alertSheetTargets.isEmpty {
            FavoritesOverlayCard(onDismiss: { closeAlertSheet() }) {
                FavoritesBatchAlertSheet(metas: model.alertSheetTargets,
                                         onApply: { compareUp, price in
                                             let targets = model.alertSheetTargets
                                             closeAlertSheet()
                                             FavoritesAlertKit.setAlerts(metas: targets,
                                                                         compareUp: compareUp,
                                                                         triggerPrice: price)
                                         },
                                         onCancel: { closeAlertSheet() })
            }
        }
    }

    private func closeRowMenu() {
        guard model.rowMenuTarget != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.rowMenuTarget = nil }
    }

    private func closeNoteEditor() {
        guard model.noteEditorTarget != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.noteEditorTarget = nil }
    }

    private func closeAlertSheet() {
        guard !model.alertSheetTargets.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.alertSheetTargets = [] }
    }
}

// MARK: - AddToGroupSheet 的 Binding(item:) 需要 Identifiable 包装 MetaItem

private struct SearchIdentifiableMeta: Identifiable {
    let meta: MetaItem
    var id: Int { meta.id }
}

#Preview {
    SearchPageView(searchText: .constant(""))
}