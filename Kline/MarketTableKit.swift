//
//  MarketTableKit.swift
//  Kline
//
//  Created by AI on 2026/09/01.
//
//  行情 / 自选页面共享的表格组件与配置面板。
//  - MarketTableRow: 统一的行控件（mode: .header 表头 / .data 数据行，共用同一列网格）
//  - MarketColumnConfigPanel: 底部弹出的「字段显隐 / 排序 / 恢复默认」面板
//  - AddToGroupSheet: 加自选 / 移动分组动作 sheet
//

import SwiftUI

// MARK: - 表格辅助：共享列宽与对齐

private struct ColumnLayout: Identifiable {
    let field: MarketField
    let width: CGFloat
    /// 是否由「名称 + 代码」合并而来（名称在上、代码在下双行）
    let isNameCode: Bool
    var id: String { "\(field.rawValue)_\(isNameCode ? "1" : "0")" }
}

// MARK: - 唯一列网格（表头 / 表内容共用的唯一定义）
// 统一列宽、格子对齐与右边界竖线；marker 参数区分表头/数据内容。

struct MarketTableRow: View {
    /// 行形态：表头（字段名+排序箭头）或数据行（某标的值）
    enum Mode {
        case header
        case data(meta: MetaItem)

        var isHeader: Bool {
            if case .header = self { return true }
            return false
        }
    }

    let page: MarketConfigPage
    let mode: Mode
    @ObservedObject var config: MarketConfigStore
    @ObservedObject var rowCache: MarketRowCache

    /// 数据行点击打开详情；默认打开详情页
    var onOpen: ((MetaItem) -> Void)? = nil
    /// 表头点击字段排序；默认内部切 config
    var onColumnTapped: ((MarketField) -> Void)? = nil

    // === 整表冻结 + 横向滚动 ===
    /// 冻结前 N 个可见列（固定不参与横向滚动），其余列横向 offset 平移
    var frozenCount: Int = 3
    /// 整表共享的横向滚动偏移（由外层手势驱动）
    var xOffset: CGFloat = 0
    /// 是否为自选（置顶）标：高亮整行背景 + 标的文字变红；默认 false
    var isFaved: Bool = false

    /// 自选高亮背景色：比普通行更深（浅灰底）
    private var rowBackground: Color {
        isFaved ? Color(.systemGray5) : Color(.systemBackground)
    }

    /// 统一列宽（保留当前表格样式：固定 90pt 等宽 + 竖线）
    private static let colW: CGFloat = 90
    private static let lineW: CGFloat = 0.5

    /// 把可视列转成渲染列：相邻的「代码 + 名称」合并为一个双行单元格（名称在上、代码在下），宽度=两列之和。
    private func renderColumns(_ cols: [MarketColumnPref]) -> [ColumnLayout] {
        Self.renderColumns(cols)
    }

    /// 静态版 renderColumns（供外层计算横向滚动上限等复用，保证与渲染完全一致）
    fileprivate static func renderColumns(_ cols: [MarketColumnPref]) -> [ColumnLayout] {
        var out: [ColumnLayout] = []
        var i = 0
        while i < cols.count {
            let cur = cols[i]
            // 找到相邻的 name/code 对（顺序任意）
            if cur.field == .name || cur.field == .code {
                let next = i + 1 < cols.count ? cols[i + 1] : nil
                if let n = next, n.field != cur.field, (n.field == .name || n.field == .code) {
                    out.append(ColumnLayout(field: .name, width: colW * 2, isNameCode: true))
                    i += 2
                    continue
                }
            }
            out.append(ColumnLayout(field: cur.field, width: colW, isNameCode: false))
            i += 1
        }
        return out
    }

    /// 冻结前 N 列后的其余列总宽（供外层算最大横向偏移）；收到冻结区起始分隔线宽
    static func scrollContentWidth(for page: MarketConfigPage, config: MarketConfigStore, frozenCount: Int) -> CGFloat {
        let cols = renderColumns(config.visibleColumns(for: page))
        let frozenCols = Array(cols.prefix(frozenCount))
        let scrollCols = Array(cols.dropFirst(frozenCount))
        let frozenW = frozenCols.reduce(lineW) { $0 + $1.width + lineW }
        let scrollW = scrollCols.reduce(0) { $0 + $1.width + lineW }
        return frozenW + scrollW
    }

    var body: some View {
        let rowHeight: CGFloat = mode.isHeader ? 30 : 36
        let cols = renderColumns(config.visibleColumns(for: page))
        let frozenCols = Array(cols.prefix(frozenCount))
        let scrollCols = Array(cols.dropFirst(frozenCount))
        let frozenW = frozenCols.reduce(Self.lineW) { $0 + $1.width + Self.lineW }
        let scrollW = scrollCols.reduce(0) { $0 + $1.width + Self.lineW }
        // 可视宽度：整表铺满屏幕
        let visW = UIScreen.main.bounds.width
        // 最大可左移量：滚动内容总宽 - 可视宽
        let maxX = max(0, (frozenW + scrollW) - visW)
        let rule = config.sortRule(for: page)

        ZStack(alignment: .topLeading) {
            // 滚动区：其余列（前接与冻结区等宽的占位），横向 offset 平移
            HStack(spacing: 0) {
                Color.clear.frame(width: frozenW)
                ForEach(scrollCols) { col in
                    content(col, header: mode.isHeader, meta: metaOf, rule: rule)
                        .frame(width: col.width, alignment: col.isNameCode ? .leading : (col.field.alignRight ? .trailing : .leading))
                        .padding(.horizontal, col.isNameCode ? 8 : 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    Color(.black).frame(width: Self.lineW)
                        .opacity(0.35)
                }
            }
            .frame(width: max(visW, frozenW + scrollW), height: rowHeight, alignment: .leading)
            .padding(.top, mode.isHeader ? 1 : 0)
            .background(rowBackground)
            .offset(x: xOffset)
            .zIndex(0)
            .clipped()

            // 冻结区：前 N 列固定，盖在滚动区上方，右侧竖分割线
            HStack(spacing: 0) {
                Color(.black).frame(width: Self.lineW).opacity(0.35)
                ForEach(frozenCols) { col in
                    content(col, header: mode.isHeader, meta: metaOf, rule: rule)
                        .frame(width: col.width, alignment: col.isNameCode ? .leading : (col.field.alignRight ? .trailing : .leading))
                        .padding(.horizontal, col.isNameCode ? 8 : 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    Color(.black).frame(width: Self.lineW).opacity(0.35)
                }
            }
            .frame(width: frozenW, height: rowHeight, alignment: .leading)
            .padding(.top, mode.isHeader ? 1 : 0)
            .background(rowBackground)
            .overlay(alignment: .trailing) { Color(.separator).frame(width: 0.5) }
            .zIndex(2)
            .clipped()
        }
        .frame(width: visW, height: rowHeight, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            // 数据行整行可点打开标的详情；表头 metaOf 为 nil 不触发（不拦截排序按钮）
            if let m = metaOf { onOpen?(m) }
        }
    }

    /// 当前行的 meta（数据行才有；表头为占位 nil）
    private var metaOf: MetaItem? {
        if case .data(let meta) = mode { return meta }
        return nil
    }

    /// 单元格内容：表头 = 字段名(+排序箭头)；数据 = 字段文本(红涨绿跌)。
    /// 合并列（代码+名称）渲染为双行：名称在上、代码在下。
    @ViewBuilder
    private func content(_ col: ColumnLayout, header: Bool, meta: MetaItem?, rule: MarketSortRule?) -> some View {
        if header {
            // 合并列表头：显示「名称/代码」
            let active = rule?.field == col.field
            Button(action: {
                if let cb = onColumnTapped { cb(col.field) }
                else { config.toggleSort(field: col.field, page: page) }
            }) {
                if col.isNameCode {
                    HStack(spacing: 3) {
                        Text("名称/代码")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(active ? Color.accentColor : Color(.secondaryLabel))
                            .lineLimit(1)
                        if active, let r = rule {
                            Image(systemName: r.order == .descending ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color.accentColor)
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 3) {
                        Text(col.field.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(active ? Color.accentColor : Color(.secondaryLabel))
                            .lineLimit(1)
                        if active, let r = rule {
                            Image(systemName: r.order == .descending ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color.accentColor)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .buttonStyle(.plain)
        } else if let meta = meta {
            // 自选高亮：名称/代码/板块等「标的」列文字变红（指标数值仍红涨绿跌）
            if col.isNameCode {
                let fg: Color = isFaved ? .red : .primary
                VStack(alignment: .leading, spacing: 1) {
                    Text(meta.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(fg)
                        .lineLimit(1)
                    Text(meta.displayCode)
                        .font(.system(size: 10))
                        .foregroundColor(isFaved ? fg : Color(.secondaryLabel))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                let isLabel = col.field == .name || col.field == .code || col.field == .type
                let cellFg: Color = isFaved && isLabel ? Color.red : rowCache.colorFor(meta.id, col.field)
                Text(rowCache.textFor(meta.id, col.field))
                    .font(.system(size: 12))
                    .foregroundColor(cellFg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - 「字段显隐/排序」配置面板（底部 sheet，3/4 高）

struct MarketColumnConfigPanel: View {
    @Environment(\.dismiss) private var dismiss
    let page: MarketConfigPage
    @ObservedObject var configStore: MarketConfigStore

    @State private var draft: MarketPageConfig

    init(page: MarketConfigPage, configStore: MarketConfigStore) {
        self.page = page
        self.configStore = configStore
        // 编辑副本：用户点取消可以直接放弃
        _draft = State(initialValue: configStore.config(for: page))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部栏
                HStack(spacing: 12) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("表头设置")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("重置") {
                        draft = MarketConfigStore.defaultConfig()
                    }
                    .foregroundColor(.orange)
                    Button(action: {
                        configStore.update(page, config: draft)
                        dismiss()
                    }) {
                        Text("完成")
                            .foregroundColor(.blue)
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                List {
                    Section {
                        ForEach($draft.columns) { $col in
                            HStack(spacing: 12) {
                                // 拖动手柄
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 14))
                                Toggle(isOn: $col.visible) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(col.field.title)
                                            .font(.system(size: 15))
                                        Text(col.field.rawValue)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .toggleStyle(.switch)
                                Spacer()
                                // 宽度微调
                                Stepper(value: Binding(
                                    get: { Int(col.widthOverride ?? col.field.defaultWidth) },
                                    set: { nv in
                                        let new = CGFloat(nv)
                                        if abs(new - col.field.defaultWidth) < 0.5 {
                                            col.widthOverride = nil
                                        } else {
                                            col.widthOverride = max(32, min(240, new))
                                        }
                                    }
                                ), in: 32...240, step: 2) {
                                    EmptyView()
                                }
                                Text("\(Int(col.widthOverride ?? col.field.defaultWidth))pt")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                        }
                        .onMove { from, to in
                            draft.columns.move(fromOffsets: from, toOffset: to)
                        }
                    } header: {
                        Text("拖动调整列顺序，点击开关显示/隐藏列")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• 现价/涨跌幅等数值颜色：涨红跌绿")
                            Text("• 点击「完成」保存后立即生效，行情/自选页面各自独立")
                            Text("• 点击表头可切换排序：降→升→取消（三击循环）")
                        }
                        .font(.footnote)
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(.active))
            }
            .background(Color(.systemGroupedBackground))
        }
    }
}

// MARK: - 加自选/选分组 sheet（从行情行或详情页右上角按钮触发）

struct AddToGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let meta: MetaItem
    @ObservedObject var fav: FavoritesStore
    /// 完成后刷新调用侧的按钮状态
    var onDone: (() -> Void)? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部栏
                HStack(spacing: 12) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("加入自选分组")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button(action: { onDone?(); dismiss() }) {
                        Text("完成")
                            .foregroundColor(.blue)
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()

                // 标的信息
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meta.name).font(.system(size: 16, weight: .medium))
                        Text(meta.displayCode).font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        fav.toggleFavorite(meta.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: fav.isFavorited(meta.id) ? "star.fill" : "star")
                                .foregroundColor(fav.isFavorited(meta.id) ? .yellow : .secondary)
                            Text(fav.isFavorited(meta.id) ? "已自选" : "一键加自选")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()

                // 新增分组快捷按钮
                HStack {
                    Button {
                        presentAddGroupAlert()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill").foregroundColor(.green)
                            Text("新建自定义分组")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                List {
                    Section {
                        let manualGroups = fav.groups.filter { $0.kind == .manual }
                        if manualGroups.isEmpty {
                            HStack {
                                Spacer()
                                Text("暂无自定义分组，点击上方「新建自定义分组」")
                                    .foregroundColor(.secondary).font(.footnote)
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 16)
                        } else {
                            ForEach(manualGroups) { g in
                                let member = g.manualMetaIDs.contains(meta.id)
                                Button {
                                    if member {
                                        fav.removeFromGroup(id: g.id, metaID: meta.id)
                                    } else {
                                        fav.addToGroup(id: g.id, metaID: meta.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(g.name).font(.system(size: 15))
                                            Text("\(g.manualMetaIDs.count) 只")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: member ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(member ? .green : .gray)
                                            .font(.system(size: 20))
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Text("自定义分组（多选）")
                    }
                }
                .listStyle(.insetGrouped)
            }
            .background(Color(.systemGroupedBackground))
        }
        // 用 @State 控 UIAlertController 弹窗
        .onAppear(perform: {})  // keep
    }

    /// 弹出"新建分组"输入框（用 UIKit bridge 更稳）
    private func presentAddGroupAlert() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first else { return }
        let vc = UIAlertController(title: "新建自定义分组", message: nil, preferredStyle: .alert)
        vc.addTextField { tf in
            tf.placeholder = "例如：科技龙头"
            tf.clearButtonMode = .whileEditing
        }
        vc.addAction(UIAlertAction(title: "取消", style: .cancel))
        vc.addAction(UIAlertAction(title: "创建", style: .default, handler: { _ in
            let name = (vc.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            fav.addGroup(.manual(name: name))
        }))
        root.present(vc, animated: true)
    }
}

// MARK: - 通用「空态/加载态」视图（给行情/自选共用）

struct MarketEmptyStateView: View {
    let icon: String
    let message: String
    var subtitle: String? = nil
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46)).foregroundColor(.gray)
            Text(message).font(.system(size: 15)).foregroundColor(.primary)
            if let s = subtitle {
                Text(s).font(.system(size: 13)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
