//
//  TrainingSetupSheet.swift
//  Kline
//
//  「K 线单人训练」设置窗（自绘居中卡片浮层，不用系统 sheet）。
//  字段：分类（全部 / 沪深主板 / ETF 指数 / 自选 / 我的分组）→ 标的（已选 + 随机抽取 + 搜索）
//  → 起始日期（已选 + 随机 + DatePicker）→ 底部「取消 / 开始训练」。
//
//  呈现方式：要盖住底部导航栏，故由 `ContentView` 根层用 `TrainingSetupRouter` 承载
//  （首页在各档 VStack 内只占底栏以上区域，页面内 overlay 结构上盖不住底栏，
//  与布局编辑器同因，见 PageLayoutEditorView.swift）。
//

import Combine
import SwiftUI

// MARK: - 设置窗呈现路由器

/// 训练设置窗路由器：单一 `isPresented` 开关，首页四档入口只置位它；
/// 实际浮层由 `ContentView` 根层挂载（`.trainingSetupSheet(isPresented:)`）。
final class TrainingSetupRouter: ObservableObject {
    static let shared = TrainingSetupRouter()
    @Published var isPresented = false
    private init() {}
}

// MARK: - 分类

/// 训练标的分类（口径与行情页一致）
private enum TrainingCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case mainBoard = "沪深主板"
    case etfIndex = "ETF 指数"
    case favorites = "自选"
    case myGroup = "我的分组"

    var id: String { rawValue }
}

// MARK: - 日期工具（YYYYMMDD ↔ Date；固定用 Calendar.current 避免时区偏差）

private enum TrainingDateMath {
    /// YYYYMMDD → 当日 0 点 Date
    static func date(fromInt v: Int) -> Date? {
        let y = v / 10000
        let m = (v / 100) % 100
        let d = v % 100
        guard y > 0, m > 0, d > 0 else { return nil }
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        return Calendar.current.date(from: c)
    }

    /// Date → YYYYMMDD
    static func int(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// 首日（最早一根 K 线日期）
    static func minDate(of meta: MetaItem) -> Date? {
        guard let f = meta.firstDate else { return nil }
        return date(fromInt: f)
    }

    /// 上限 = 最新库日期往前推 65 个自然日
    static func maxDate(of meta: MetaItem) -> Date? {
        guard let l = meta.lastDate, let d = date(fromInt: l) else { return nil }
        return Calendar.current.date(byAdding: .day, value: -65, to: d)
    }

    /// 可训练：有首末日期且 firstDate <= 上限（O(1)，无需查库）
    static func isTrainable(_ meta: MetaItem) -> Bool {
        guard let lower = minDate(of: meta), let upper = maxDate(of: meta) else { return false }
        return lower <= upper
    }
}

// MARK: - 设置窗

/// 单人训练设置窗：居中圆角卡片 + 半透明遮罩（点遮罩关闭）。
/// 自带滚动，高度随屏幕自适应。
struct TrainingSetupSheet: View {
    @Binding var isPresented: Bool

    @ObservedObject private var db = DatabaseManager.shared
    @ObservedObject private var favorites = FavoritesStore.shared

    @State private var category: TrainingCategory = .all
    @State private var selectedGroupID: UUID = FavoritesStore.shared.visibleGroups.first?.id ?? FavoritesStore.allGroupID
    @State private var selectedMeta: MetaItem?
    @State private var startDate: Date?
    @State private var keyword: String = ""
    @State private var errorText: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // 半透明遮罩：点空白处关闭
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }

                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            categorySection
                            if category == .myGroup { groupSection }
                            targetSection
                            dateSection
                            if let errorText {
                                Text(errorText)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: contentHeight(proxy))
                    Divider()
                    footer
                }
                .frame(maxWidth: 520)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.black.opacity(0.25), radius: 24, y: 8)
                .padding(.horizontal, 24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    // MARK: - 卡片各段

    private var header: some View {
        HStack {
            Text("单人训练")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("分类")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TrainingCategory.allCases) { c in
                        chip(c.rawValue, selected: c == category) {
                            category = c
                            errorText = nil
                            if c == .myGroup { ensureGroupSelection() }
                        }
                    }
                }
            }
        }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("分组")
            if favorites.visibleGroups.isEmpty {
                Text("暂无可用分组")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(favorites.visibleGroups) { g in
                            chip(g.name, selected: g.id == selectedGroupID) {
                                selectedGroupID = g.id
                                errorText = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("标的")
            HStack(spacing: 8) {
                if let meta = selectedMeta {
                    Text("\(meta.name) \(meta.displayCode)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                } else {
                    Text("未选择")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("随机抽取") { pickRandom() }
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            }
            searchField
            if !searchResults.isEmpty { searchResultList }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            TextField("输入名称 / 代码搜索", text: $keyword)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !keyword.isEmpty {
                Button { keyword = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var searchResultList: some View {
        VStack(spacing: 0) {
            ForEach(searchResults) { meta in
                Button { select(meta) } label: {
                    HStack(spacing: 8) {
                        Text(meta.name)
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(meta.displayCode)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        if !TrainingDateMath.isTrainable(meta) {
                            Text("历史不足")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        } else if meta.id == selectedMeta?.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("起始日期")
            HStack(spacing: 8) {
                Text(dateText)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Button("随机") { randomizeDate() }
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundColor(canRandomizeDate ? .accentColor : .secondary)
                    .disabled(!canRandomizeDate)
            }
            if let meta = selectedMeta,
               let lower = TrainingDateMath.minDate(of: meta),
               let upper = TrainingDateMath.maxDate(of: meta), lower <= upper {
                Text("可选区间 \(TrainSessionRecord.dateText(TrainingDateMath.int(from: lower))) ~ \(TrainSessionRecord.dateText(TrainingDateMath.int(from: upper)))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let range = dateRange {
                DatePicker("", selection: dateBinding, in: range, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let meta = selectedMeta, !TrainingDateMath.isTrainable(meta) {
                Text("该标的历史数据不足（需至少能取到最新库日期前 65 天）")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { isPresented = false } label: {
                Text("取消")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button { startTraining() } label: {
                Text("开始训练")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(canStart ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(canStart ? Color.accentColor : Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
        }
        .padding(16)
    }

    // MARK: - 小组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : .primary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(selected ? Color.accentColor : Color(.systemBackground))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 卡片滚动区高度：随屏幕自适应，避免小屏溢出
    private func contentHeight(_ proxy: GeometryProxy) -> CGFloat {
        max(200, min(proxy.size.height * 0.62, 520))
    }

    // MARK: - 数据

    private var allMeta: [MetaItem] { db.metaList }

    /// 当前分类的候选池
    private var candidatePool: [MetaItem] {
        switch category {
        case .all:
            return allMeta
        case .mainBoard:
            return allMeta.filter { $0.type == "沪深主板" }
        case .etfIndex:
            return allMeta.filter { $0.type == "沪深京指数" || $0.type == "扩展行情指数" }
        case .favorites:
            return favorites.resolveMetaItems(groupID: FavoritesStore.allGroupID, allMeta: allMeta)
        case .myGroup:
            return favorites.resolveMetaItems(groupID: selectedGroupID, allMeta: allMeta)
        }
    }

    /// 随机池 = 当前分类下可训练的标的
    private var trainablePool: [MetaItem] {
        candidatePool.filter { TrainingDateMath.isTrainable($0) }
    }

    /// 搜索结果（输入即筛，最多 20 条）
    private var searchResults: [MetaItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        return Array(DatabaseManager.shared.searchMeta(keyword: kw).prefix(20))
    }

    private var dateRange: ClosedRange<Date>? {
        guard let meta = selectedMeta,
              let lower = TrainingDateMath.minDate(of: meta),
              let upper = TrainingDateMath.maxDate(of: meta), lower <= upper else { return nil }
        return lower...upper
    }

    /// DatePicker 绑定：越界一律钳制到 [首日, 上限]
    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                if let d = startDate, let r = dateRange, r.contains(d) { return d }
                return dateRange?.lowerBound ?? startDate ?? Date()
            },
            set: { newValue in
                if let r = dateRange {
                    startDate = min(max(newValue, r.lowerBound), r.upperBound)
                } else {
                    startDate = newValue
                }
            }
        )
    }

    private var dateText: String {
        guard let d = startDate else { return "未选择" }
        return TrainSessionRecord.dateText(TrainingDateMath.int(from: d))
    }

    private var canRandomizeDate: Bool {
        guard let meta = selectedMeta else { return false }
        return TrainingDateMath.isTrainable(meta)
    }

    /// 未选标的 / 不可训练 / 未选日期 → 置灰
    private var canStart: Bool {
        guard let meta = selectedMeta, TrainingDateMath.isTrainable(meta), startDate != nil else { return false }
        return true
    }

    // MARK: - 交互

    private func ensureGroupSelection() {
        let groups = favorites.visibleGroups
        if !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = groups.first?.id ?? FavoritesStore.allGroupID
        }
    }

    private func pickRandom() {
        guard let meta = trainablePool.randomElement() else {
            errorText = "该分类下暂无可训练的标的（需至少 65 天历史）"
            return
        }
        errorText = nil
        selectedMeta = meta
        randomizeDate(for: meta)
    }

    private func select(_ meta: MetaItem) {
        errorText = nil
        keyword = ""
        selectedMeta = meta
        if TrainingDateMath.isTrainable(meta) {
            randomizeDate(for: meta)
        } else {
            startDate = nil
        }
    }

    private func randomizeDate() {
        guard let meta = selectedMeta else { return }
        randomizeDate(for: meta)
    }

    /// 在 [首日, 上限] 内随机一个自然日（实际交易日由 begin 吸附）
    private func randomizeDate(for meta: MetaItem) {
        guard let lower = TrainingDateMath.minDate(of: meta),
              let upper = TrainingDateMath.maxDate(of: meta), lower <= upper else {
            startDate = nil
            return
        }
        let days = Calendar.current.dateComponents([.day], from: lower, to: upper).day ?? 0
        let offset = days > 0 ? Int.random(in: 0...days) : 0
        startDate = Calendar.current.date(byAdding: .day, value: offset, to: lower)
    }

    private func startTraining() {
        guard let meta = selectedMeta, let date = startDate else { return }
        errorText = nil
        if TrainingSessionController.shared.begin(meta: meta, startDate: TrainingDateMath.int(from: date)) {
            isPresented = false
        } else {
            errorText = "该标的暂无行情数据，无法开始训练"
        }
    }
}

// MARK: - 挂载修饰符

extension View {
    /// 挂载训练设置窗浮层（居中卡片 + 遮罩）。
    /// 由 `ContentView` 根层承载——要盖住底部导航栏，页面内 overlay 盖不住底栏。
    func trainingSetupSheet(isPresented: Binding<Bool>) -> some View {
        modifier(TrainingSetupSheetModifier(isPresented: isPresented))
    }
}

private struct TrainingSetupSheetModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                TrainingSetupSheet(isPresented: $isPresented)
                    .transition(.opacity)
                    .zIndex(2000)
            }
        }
    }
}
