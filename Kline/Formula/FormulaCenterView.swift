//
//  FormulaCenterView.swift
//  Kline
//
//  公式管理中心：技术指标 / 选股指标 / 交易策略 三类公式的分域入口与管理列表。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import SwiftUI
import UIKit

// MARK: - 个人中心入口设置行

/// 公式管理设置行（个人中心用）：标题「公式管理」+ 右侧 chevron.right，命中区 ≥44pt
struct FormulaCenterSettingRow: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("公式管理")
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 公式管理中心页

/// 公式管理中心页（全屏 overlay 页面）：三分段切换 技术指标 / 选股指标 / 交易策略。
/// 三段都接入各自编辑器：技术指标（自定义 / 系统）、选股公式、策略公式。
struct FormulaCenterView: View {
    /// 初始分段
    var initialKind: FormulaKind = .tech
    var onClose: () -> Void

    @ObservedObject private var library = FormulaLibraryStore.shared
    @ObservedObject private var customStore = CustomIndicatorStore.shared
    @ObservedObject private var systemStore = SystemIndicatorStore.shared
    @ObservedObject private var chartStore = ChartConfigStore.shared
    /// 自选仓库：用于统计选股公式被哪些自选分组引用（删除确认 / 引用数展示）
    @ObservedObject private var favorites = FavoritesStore.shared

    /// 当前分段
    @State private var kind: FormulaKind
    /// 自定义技术指标新建 / 编辑浮层
    @State private var showCustomSheet = false
    @State private var editingCustom: CustomIndicator?
    /// 系统技术指标编辑浮层
    @State private var editingSystem: SystemIndicatorDef?
    /// 选股公式新建 / 编辑浮层
    @State private var showPickerSheet = false
    @State private var editingPicker: FormulaDoc?
    /// 策略公式新建 / 编辑浮层
    @State private var showStrategySheet = false
    @State private var editingStrategy: FormulaDoc?
    /// 待删除的选股公式：被自选分组引用时先弹确认，确认后再解绑 + 删除
    @State private var pendingDeletePicker: FormulaDoc?
    /// 页面样例行情数据（候选池首只标的的 K 线），供三个编辑器的「测试公式」使用
    @State private var sampleData: [KlineItem] = []

    init(initialKind: FormulaKind = .tech, onClose: @escaping () -> Void) {
        self.initialKind = initialKind
        self.onClose = onClose
        _kind = State(initialValue: initialKind)
    }

    /// 技术指标段的工作周期（取图表当前选中周期）
    private var period: KlinePeriod { chartStore.selectedPeriod }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    segmented
                    switch kind {
                    case .tech: techSection
                    case .picker: pickerSection
                    case .strategy: strategySection
                    }
                }
                .padding(16)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        // 内容贴物理屏幕底边（全 App 统一贴底为 0）
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay { editorOverlay }
        // 进入页面时异步加载样例行情数据（供编辑器「测试公式」使用）
        .onAppear { loadSampleDataIfNeeded() }
        // 删除被引用的选股公式前先确认（列出引用分组名，删除后分组保留但变空）
        .alert("删除选股公式",
               isPresented: Binding(get: { pendingDeletePicker != nil },
                                    set: { if !$0 { pendingDeletePicker = nil } })) {
            Button("删除", role: .destructive) { confirmDeletePendingPicker() }
            Button("取消", role: .cancel) { pendingDeletePicker = nil }
        } message: {
            if let doc = pendingDeletePicker {
                Text(pickerDeleteMessage(doc))
            }
        }
    }

    // MARK: - 页头（照抄 FormulaEditorView 页头视觉令牌）

    private var header: some View {
        HStack {
            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    Text("返回").font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.gray.opacity(0.12)).cornerRadius(8)
            }
            .padding(.leading, 16)

            Spacer()

            Text("公式管理")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button {
                newAction()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text("新建").font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.gray.opacity(0.12)).cornerRadius(8)
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 三分段控件

    private var segmented: some View {
        HStack(spacing: 4) {
            ForEach(FormulaKind.allCases) { k in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { kind = k }
                } label: {
                    Text(k.title)
                        .font(.system(size: 13, weight: kind == k ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(kind == k ? Color(.systemBackground) : Color.clear)
                        .cornerRadius(8)
                        .shadow(color: kind == k ? Color.black.opacity(0.1) : Color.clear,
                                radius: 2, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(uiColor: .systemGray6))
        .cornerRadius(8)
    }

    // MARK: - 技术指标段

    private var techSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            infoBanner("仅出现在 K 线图主图 / 副图指标选择中")

            sectionTitle("系统指标")
            systemCard

            sectionTitle("自定义技术指标")
            if customStore.indicators.isEmpty {
                emptyCard("还没有自定义指标", "点击下方「新建技术指标」创建，支持通达信公式语法")
            } else {
                VStack(spacing: 0) {
                    ForEach(customStore.indicators) { ind in
                        customRow(ind)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            newButton("新建技术指标") {
                editingCustom = nil
                showCustomSheet = true
            }
        }
    }

    /// 系统指标卡片：主图 + 副图两组合并成一张卡
    private var systemCard: some View {
        let mainDefs = systemStore.mainIndicatorDefs(period: period)
        let subDefs = systemStore.subIndicatorDefs(period: period)
        return Group {
            if mainDefs.isEmpty && subDefs.isEmpty {
                emptyCard("当前周期没有系统指标", "请在 K 线图内确认指标文件是否完整")
            } else {
                VStack(spacing: 0) {
                    ForEach(mainDefs, id: \.id) { def in
                        systemRow(def, isMain: true)
                    }
                    ForEach(subDefs, id: \.id) { def in
                        systemRow(def, isMain: false)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
        }
    }

    private func systemRow(_ def: SystemIndicatorDef, isMain: Bool) -> some View {
        Button {
            editingSystem = def
        } label: {
            HStack(spacing: 10) {
                Text(def.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                Text(systemDetail(def, isMain: isMain))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func customRow(_ ind: CustomIndicator) -> some View {
        Button {
            editingCustom = ind
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ind.color)
                    .frame(width: 14, height: 5)
                Text(ind.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                Text(customDetail(ind))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 选股指标段（列表骨架）

    private var pickerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            infoBanner("选股公式：用于自选分组的公式选股，不出现在 K 线图指标选择中")

            if library.pickers.isEmpty {
                emptyCard("还没有选股公式", "点击下方「新建选股公式」创建，支持通达信语法；最后一根输出值 > 0 视为命中")
            } else {
                VStack(spacing: 0) {
                    ForEach(library.pickers) { doc in
                        pickerRow(doc)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            newButton("新建选股公式") {
                editingPicker = nil
                showPickerSheet = true
            }
        }
    }

    private func pickerRow(_ doc: FormulaDoc) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text(summary(doc.pickBody))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Text("被 \(pickerRefCount(doc.id)) 个自选分组引用")
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
            }
            Spacer(minLength: 8)
            Button {
                editingPicker = doc
                showPickerSheet = true
            } label: {
                Text("编辑")
                    .font(.system(size: 13))
                    .foregroundColor(.blue)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                // 无引用直接删除；有引用先弹确认（确认后解绑引用分组再删除）
                if favorites.groups.contains(where: { $0.formulaID == doc.id }) {
                    pendingDeletePicker = doc
                } else {
                    library.delete(kind: .picker, id: doc.id)
                }
            } label: {
                Text("删除")
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - 交易策略段

    private var strategySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            infoBanner("交易策略公式：由选股条件 + 交易规则组成，用于策略回测与信号提示")

            if library.strategies.isEmpty {
                emptyCard("还没有策略公式", "点击下方「新建策略公式」创建：选股条件（内嵌或引用）+ 交易规则")
            } else {
                VStack(spacing: 0) {
                    ForEach(library.strategies) { doc in
                        strategyRow(doc)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            newButton("新建策略公式") {
                editingStrategy = nil
                showStrategySheet = true
            }
        }
    }

    private func strategyRow(_ doc: FormulaDoc) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text(strategyPickSummary(doc))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Text("\(ruleCount(doc.rules)) 条规则")
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
            }
            Spacer(minLength: 8)
            Button {
                editingStrategy = doc
                showStrategySheet = true
            } label: {
                Text("编辑")
                    .font(.system(size: 13))
                    .foregroundColor(.blue)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                library.delete(kind: .strategy, id: doc.id)
            } label: {
                Text("删除")
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - 子编辑器浮层（iOS 15：只用 overlay + zIndex）

    @ViewBuilder
    private var editorOverlay: some View {
        if showCustomSheet || editingCustom != nil {
            // 测试数据：用样例标的（候选池首只）的 K 线，进入页面时异步加载
            IndicatorEditSheet(
                indicator: editingCustom,
                data: sampleData,
                onCancel: {
                    showCustomSheet = false
                    editingCustom = nil
                },
                onSave: { ind in
                    if editingCustom == nil {
                        customStore.add(ind)
                    } else {
                        customStore.update(ind)
                    }
                    showCustomSheet = false
                    editingCustom = nil
                }
            )
            .transition(.opacity)
            .zIndex(1000)
        }
        if let def = editingSystem {
            // 主图 / 副图选择进入既有系统指标编辑器；测试数据同用样例标的的 K 线
            SystemIndicatorEditorContainer(
                data: sampleData,
                isMain: def.scope == .main,
                period: period,
                initialSubId: def.id,
                onClose: { editingSystem = nil },
                onSaved: { _ in }
            )
            .transition(.opacity)
            .zIndex(1000)
        }
        if showPickerSheet || editingPicker != nil {
            // 选股公式编辑器：复用 IndicatorEditSheet 的选股模式（只编辑名称 + 公式）
            IndicatorEditSheet(
                indicator: nil, data: sampleData,
                onCancel: {
                    showPickerSheet = false
                    editingPicker = nil
                },
                onSave: { _ in },
                isPicker: true,
                pickerInitialName: editingPicker?.name ?? "",
                pickerInitialFormula: editingPicker?.pickBody ?? "",
                onSavePicker: { name, formula in
                    // id 为空串视为新增；保存后 FormulaLibraryStore.reload 会通过 @Published 刷新列表
                    let id = editingPicker?.id ?? ""
                    _ = library.save(FormulaDoc(id: id, kind: .picker, name: name, pickBody: formula))
                    showPickerSheet = false
                    editingPicker = nil
                }
            )
            .transition(.opacity)
            .zIndex(1000)
        }
        if showStrategySheet || editingStrategy != nil {
            // 策略公式编辑器：名称 + 选股条件（内嵌 / 引用二选一）+ 交易规则 + 预览校验
            StrategyFormulaEditorView(
                initialDoc: editingStrategy ?? FormulaDoc(id: "", kind: .strategy, name: ""),
                data: sampleData,
                onClose: {
                    showStrategySheet = false
                    editingStrategy = nil
                },
                onSaved: { _ in
                    showStrategySheet = false
                    editingStrategy = nil
                }
            )
            .transition(.opacity)
            .zIndex(1000)
        }
    }

    // MARK: - 动作

    /// 页头「+ 新建」：按当前分段执行对应新建动作
    private func newAction() {
        switch kind {
        case .tech:
            editingCustom = nil
            showCustomSheet = true
        case .picker:
            editingPicker = nil
            showPickerSheet = true
        case .strategy:
            editingStrategy = nil
            showStrategySheet = true
        }
    }

    // MARK: - 摘要计算（不在 body 里做重计算）

    /// 单行摘要：去掉换行并裁剪空白
    private func summary(_ body: String) -> String {
        let one = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? "（空公式）" : one
    }

    /// 策略的选股条件摘要：优先显示引用的选股公式名，否则显示内嵌选股正文
    private func strategyPickSummary(_ doc: FormulaDoc) -> String {
        if let ref = doc.pickRef, !ref.isEmpty, let name = library.pickerName(id: ref) {
            return "引用：\(name)"
        }
        return summary(doc.pickBody)
    }

    /// 系统指标右侧说明：主图显示周期，副图显示分组
    private func systemDetail(_ def: SystemIndicatorDef, isMain: Bool) -> String {
        if isMain { return "主图 · \(period.rawValue)" }
        return def.group.isEmpty ? "副图" : "副图 · \(def.group)"
    }

    /// 自定义技术指标右侧说明：作用域 + 适用范围
    private func customDetail(_ ind: CustomIndicator) -> String {
        let scope = ind.scope == .main ? "主图" : "副图"
        let periods = CustomIndicatorStore.applicablePeriods(of: ind)
        let applicable = periods.count == KlinePeriod.allCases.count ? "全周期" : "\(periods.count) 个周期"
        return "\(scope) · 适用范围 \(applicable)"
    }

    /// 策略规则条数：按非空行计
    private func ruleCount(_ rules: String) -> Int {
        rules.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// 被自选分组引用数：统计 formulaID 指向该选股公式的自选分组数量
    private func pickerRefCount(_ id: String) -> Int {
        favorites.groups.filter { $0.formulaID == id }.count
    }

    /// 删除确认正文：列出引用该公式的自选分组名（无引用时给出通用提示）
    private func pickerDeleteMessage(_ doc: FormulaDoc) -> String {
        let refs = favorites.groups.filter { $0.formulaID == doc.id }
        guard !refs.isEmpty else { return "删除后不可恢复。" }
        let names = refs.map { $0.name }.joined(separator: "、")
        return "该公式被 \(refs.count) 个自选分组引用：\(names)。删除后这些分组将变为空（分组本身保留）。"
    }

    /// 确认删除：先解绑所有引用该公式的自选分组（分组保留、变空），再从公式库删除
    private func confirmDeletePendingPicker() {
        guard let doc = pendingDeletePicker else { return }
        for g in favorites.groups where g.formulaID == doc.id {
            favorites.bindFormula(groupID: g.id, formulaID: nil)
        }
        library.delete(kind: .picker, id: doc.id)
        pendingDeletePicker = nil
    }

    // MARK: - 样例行情数据（编辑器「测试公式」用）

    /// 加载样例行情数据：取候选池首只标的，按当前周期读全量 K 线并升序排序。
    /// 已加载 / 候选池为空则直接返回；查询与排序放到后台队列，避免阻塞首屏。
    private func loadSampleDataIfNeeded() {
        guard sampleData.isEmpty else { return }
        guard let meta = DatabaseManager.shared.metaList.first else { return }
        let p = period
        DispatchQueue.global(qos: .userInitiated).async {
            // fetchBars 返回 date DESC，按既有惯例排序为升序
            let bars = DatabaseManager.shared.fetchBars(metaId: meta.id, period: p)
                .sorted { $0.date < $1.date }
            DispatchQueue.main.async {
                sampleData = bars
            }
        }
    }

    // MARK: - 通用小组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.gray)
    }

    private func infoBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
    }

    private func emptyCard(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "function")
                .font(.system(size: 32)).foregroundColor(.gray.opacity(0.5))
            Text(title)
                .font(.system(size: 15)).foregroundColor(.gray)
            Text(subtitle)
                .font(.system(size: 12)).foregroundColor(.gray.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func newButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .medium))
            }
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}