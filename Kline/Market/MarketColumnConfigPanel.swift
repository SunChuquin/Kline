//
//  MarketColumnConfigPanel.swift
//  Kline
//
//  「字段显隐/排序/恢复默认」配置面板：筛选触发按钮、筛选选项面板、底部 sheet 主体。
//

import SwiftUI



// MARK: - 「字段显隐/排序」配置面板（底部 sheet，3/4 高）

/// 字段多选筛选触发按钮。
struct ColumnFilterButton: View {
    let field: MarketField
    @Binding var filterLabels: [String]
    @Binding var isOpen: Bool

    private var isEmpty: Bool { filterLabels.isEmpty }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 12))
                Text(isEmpty ? "筛选" : "已选\(filterLabels.count)项")
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundColor(isEmpty ? .secondary : .blue)
        }
        .buttonStyle(.plain)
        .frame(height: 28)
    }
}

/// 多选筛选浮层面板（容器层居中显示，避免被 List 裁剪）。
struct FilterOptionsPanel: View {
    let options: [MarketRangeOption]
    @Binding var filterLabels: [String]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        filterLabels = []
                    } label: {
                        HStack {
                            Text("全部（不筛选）")
                                .foregroundColor(.primary)
                            Spacer()
                            if filterLabels.isEmpty {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    ForEach(options) { opt in
                        let on = filterLabels.contains(opt.label)
                        Button {
                            if on {
                                filterLabels.removeAll { $0 == opt.label }
                            } else {
                                filterLabels.append(opt.label)
                            }
                        } label: {
                            HStack {
                                Text(opt.label)
                                    .foregroundColor(.primary)
                                Spacer()
                                if on {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)

            Button {
                withAnimation(.easeOut(duration: 0.15)) { onClose() }
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 210)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

struct MarketColumnConfigPanel: View {
    @Environment(\.dismiss) private var dismiss
    let page: MarketConfigPage
    @ObservedObject var configStore: MarketConfigStore
    /// 点击「单元格宽度调整」后的回调（由调用方负责关闭面板并进入宽度调整模式）
    var onEnableEdgeAdjust: (() -> Void)? = nil

    @State private var draft: MarketPageConfig
    /// 当前展开筛选面板的字段（同时只允许一个展开；nil = 全部收起）
    @State private var openFilterField: MarketField? = nil

    init(page: MarketConfigPage, configStore: MarketConfigStore, onEnableEdgeAdjust: (() -> Void)? = nil) {
        self.page = page
        self.configStore = configStore
        self.onEnableEdgeAdjust = onEnableEdgeAdjust
        // 编辑副本：用户点取消可以直接放弃
        _draft = State(initialValue: configStore.config(for: page))
    }

    /// 表头设置里可显隐、可拖动排序的字段（固定列之外的其余可配置列）
    private var movableFields: [MarketField] {
        draft.columns.map(\.field).filter { $0.isConfigurable && !$0.isFixedColumn }
    }

    /// 取草稿中某字段对应的列绑定
    private func columnBinding(for field: MarketField) -> Binding<MarketColumnPref>? {
        guard let idx = draft.columns.firstIndex(where: { $0.field == field }) else { return nil }
        return $draft.columns[idx]
    }

    /// 拖动排序：只在「非固定列」子集内重排，固定列（代码/名称）保持置顶不动
    private func applyMove(from: IndexSet, to: Int) {
        var fields = movableFields
        fields.move(fromOffsets: from, toOffset: to)
        var byField: [MarketField: MarketColumnPref] = [:]
        for c in draft.columns { byField[c.field] = c }
        var iter = fields.compactMap { byField[$0] }.makeIterator()
        var newCols: [MarketColumnPref] = []
        for c in draft.columns {
            // 固定列 / 历史遗留的不可配置项：原位保留
            newCols.append(c.field.isConfigurable && !c.field.isFixedColumn ? (iter.next() ?? c) : c)
        }
        draft.columns = newCols
    }

    /// 表头设置单行：字段名 + （可筛选字段的）筛选按钮 + 显隐开关
    private func fieldRow(field: MarketField, col: Binding<MarketColumnPref>) -> some View {
        return HStack(spacing: 8) {
            Text(field.title)
                .font(.system(size: 15))
                .lineLimit(1)
            Spacer()
            // 可筛选字段：自定义多选下拉（点选项不收起，点「完成」或外部才收起）
            if let opts = field.rangeFilterOptions {
                ColumnFilterButton(
                    field: field,
                    filterLabels: col.filterLabels,
                    isOpen: Binding(
                        get: { openFilterField == field },
                        set: { open in
                            if open {
                                openFilterField = field
                            } else if openFilterField == field {
                                openFilterField = nil
                            }
                        }
                    )
                )
            }
            Toggle("", isOn: col.visible)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(minHeight: 36)
        .zIndex(openFilterField == field ? 100 : 0)
    }

    /// 快捷操作卡片组：进入单元格宽度调整模式（关闭面板，由右上角按钮接管）
    private var quickActionSection: some View {
        Section {
            Button {
                onEnableEdgeAdjust?()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.and.right.square")
                        .font(.system(size: 15))
                    Text("单元格宽度调整")
                        .font(.system(size: 15))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.blue)
        } header: {
            Text("快捷操作")
        } footer: {
            Text("进入后可直接左右拖动各列分隔线调整列宽；右上角按钮变为「带方框的❌」，点击即退出")
        }
    }

    /// 表格冻结卡片组：第 1 列恒冻结（不可取消），第 2/3 列可开关。
    /// 冻结为连续前 N 列（frozenCount 1~3）：打开第 3 列自动带上第 2 列；
    /// 关闭第 2 列连带解除第 3 列。列名取「草稿」的渲染列顺序，
    /// 这样在表头设置里拖动/显隐字段时，这里的列名会即时跟随（不必先点完成保存）
    private var frozenConfigSection: some View {
        let renderCols = MarketTableRow.renderedColumns(draft: draft.columns)
        return Section {
            // 第 1 列：恒冻结，开关置灰不可操作
            if renderCols.count >= 1 {
                HStack(spacing: 8) {
                    Text("第 1 列（\(renderCols[0].field.title)）")
                        .font(.system(size: 15))
                        .lineLimit(1)
                    Spacer()
                    Toggle("", isOn: .constant(true))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(true)
                }
                .frame(minHeight: 36)
            }
            // 第 2 列：可开关
            if renderCols.count >= 2 {
                HStack(spacing: 8) {
                    Text("第 2 列（\(renderCols[1].field.title)）")
                        .font(.system(size: 15))
                        .lineLimit(1)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { draft.frozenCount >= 2 },
                        set: { on in draft.frozenCount = on ? max(draft.frozenCount, 2) : 1 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .frame(minHeight: 36)
            }
            // 第 3 列：可开关
            if renderCols.count >= 3 {
                HStack(spacing: 8) {
                    Text("第 3 列（\(renderCols[2].field.title)）")
                        .font(.system(size: 15))
                        .lineLimit(1)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { draft.frozenCount >= 3 },
                        set: { on in draft.frozenCount = on ? 3 : 2 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .frame(minHeight: 36)
            }
        } header: {
            Text("表格冻结")
        } footer: {
            Text("最左侧列保持冻结不可取消；冻结为连续前 N 列，关闭某列后其右侧列同步解除")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏：标题用 ZStack 绝对居中，避免左右按钮宽度不等导致偏左
            ZStack {
                Text("行情表设置")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 12) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("重置") {
                        draft = MarketConfigStore.defaultConfig()
                    }
                    .foregroundColor(.orange)
                    Button(action: {
                        var saved = draft
                        // 冻结列数做范围收敛（1~3），防止异常值写入
                        saved.frozenCount = min(3, max(1, saved.frozenCount))
                        configStore.update(page, config: saved)
                        dismiss()
                    }) {
                        Text("完成")
                            .foregroundColor(.blue)
                            .font(.system(size: 16, weight: .bold))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            List {
                // === 卡片组 1：快捷操作（单元格宽度调整） ===
                quickActionSection

                // === 卡片组 2：表格冻结（冻结前 N 列，第 1 列恒冻结） ===
                frozenConfigSection

                // === 卡片组 3：表头设置（原表头配置功能） ===
                Section {
                    // 固定列（代码/名称）：表格里本就是合并单元格 → 面板内合成一行「名称/代码」，
                    // 无显隐开关、无拖动手柄，仅作说明
                    HStack(spacing: 8) {
                        Text("名称/代码")
                            .font(.system(size: 15))
                            .lineLimit(1)
                        Spacer()
                    }
                    .frame(minHeight: 36)
                    // 其余可配置列：可显隐、可拖动排序（只在固定列之后的范围内重排）
                    ForEach(movableFields, id: \.self) { f in
                        if let col = columnBinding(for: f) {
                            fieldRow(field: f, col: col)
                        }
                    }
                    .onMove { from, to in
                        applyMove(from: from, to: to)
                    }
                } header: {
                    Text("表头设置")
                } footer: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("• 拖动右侧手柄调整列顺序，开关控制显示/隐藏")
                        Text("• 名称/代码恒显示且固定在最前，不可隐藏或拖动")
                        Text("• 数值字段可设置范围筛选，多字段同时生效（取交集）")
                        Text("• 点击表头切换排序：降→升→取消（三击循环）")
                    }
                    .font(.footnote)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
        }
        .background(Color(.systemGroupedBackground))
        // 容器层浮层：屏幕居中显示多选筛选面板，避免被 List 行裁剪
        .overlay {
            if let field = openFilterField,
               let opts = field.rangeFilterOptions,
               let col = draft.columns.first(where: { $0.field == field }) {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { openFilterField = nil }
                    FilterOptionsPanel(
                        options: opts,
                        filterLabels: Binding(
                            get: { col.filterLabels },
                            set: { nv in
                                // 显式拷贝数组再写回，确保 @State draft 正确触发更新
                                var newCols = draft.columns
                                if let idx = newCols.firstIndex(where: { $0.field == field }) {
                                    newCols[idx].filterLabels = nv
                                    draft.columns = newCols
                                }
                            }
                        ),
                        onClose: { openFilterField = nil }
                    )
                }
                .zIndex(1000)
            }
        }
    }
}

