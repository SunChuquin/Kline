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
    var id: String { field.rawValue }
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

    var body: some View {
        // 表头 / 数据高度不同，其余网格逻辑完全共用
        let rowHeight: CGFloat = mode.isHeader ? 30 : 36
        let rule = config.sortRule(for: page)

        // 表头加一条顶部分隔线（贴合上一行卡片），数据行不加
        if mode.isHeader {
            VStack(spacing: 0) {
                // 顶部分隔线（贴合上一行卡片），其下 HStack 左侧留 28pt 星标占位对齐内容行
                Color(.separator).frame(height: 1).offset(y: -2)
                HStack(spacing: 0) {
                    // 与内容行左侧星标/减号按钮同宽（28pt）的空占位，保证表头第一列不从 0 开始
                    Color.clear.frame(width: 28, height: rowHeight)
                    ScrollView(.horizontal, showsIndicators: false) {
                        MarketColumnGridRow(page: page, config: config,
                                            alignment: { field in
                            field.alignRight ? .trailing : .leading
                        }) { field in
                            let active = rule?.field == field
                            Button(action: {
                                if let cb = onColumnTapped { cb(field) }
                                else { config.toggleSort(field: field, page: page) }
                            }) {
                                HStack(spacing: 3) {
                                    Text(field.title)
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
                            .buttonStyle(.plain)
                        }
                        .frame(height: rowHeight)
                    }
                    .frame(height: rowHeight)
                }
                .background(Color(.systemBackground))
            }
            .background(Color(.systemBackground))
        } else if case .data(let meta) = mode {
            Button(action: { onOpen?(meta) }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    MarketColumnGridRow(page: page, config: config, alignment: { field in
                        field.alignRight ? .trailing : .leading
                    }) { field in
                        Text(rowCache.textFor(meta.id, field))
                            .font(.system(size: 12))
                            .foregroundColor(rowCache.colorFor(meta.id, field))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// 网格行渲染器（内部实现，两形态共用）
private struct MarketColumnGridRow<Content: View>: View {
    let page: MarketConfigPage
    @ObservedObject var config: MarketConfigStore
    var alignment: ((MarketField) -> Alignment)? = nil
    @ViewBuilder var content: (MarketField) -> Content

    var body: some View {
        // 所有列统一固定像素宽度（表头/表内容共用同一常量，天然同列）
        let fixedColumnWidth: CGFloat = 90
        let cols = config.visibleColumns(for: page)
        HStack(spacing: 0) {
            // 起始竖线：与每一列右边界竖线同工艺，保证表头/内容的第一列左侧也有分界线
            Color(.black)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
                .opacity(0.35)
            ForEach(cols) { col in
                let align = alignment?(col.field) ?? .center
                content(col.field)
                    .frame(width: fixedColumnWidth, alignment: align)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                // 列宽分界线：画在格子右边界，X 坐标 = 前一格宽度累加（唯一来源）
                Color(.black)
                    .frame(width: 0.5)
                    .frame(maxHeight: .infinity)
                    .opacity(0.35)
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
