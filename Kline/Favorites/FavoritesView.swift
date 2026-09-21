//
//  FavoritesView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/01 重写为：持久自选 + 自定义分组 + 指标公式自动分组
//  2026/09/20 改为按布局偏好分发的容器（A/B/C/D），共享骨架见 FavoritesPageKit.swift
//

import SwiftUI

// MARK: - 主页面（按布局偏好分发的容器）

/// 自选页容器：按 `PageLayoutStore.favoritesLayout` 分发到四档布局。
/// 页面状态（分组 Tab / 当前分组标的 / 排序快照 / 浮层 / 横向滚动）统一由 `FavoritesPageModel` 持有，
/// 容器层只保留数据源观测（触发重算）与浮层挂载。
struct FavoritesView: View {
    @StateObject private var model = FavoritesPageModel()
    @ObservedObject private var layoutStore = PageLayoutStore.shared

    // 容器层保留的观测对象：数据源变化（分组增删改 / 加载完毕 / 行数据到达 / 列配置变更）时
    // 触发容器重绘，进而让各布局视图重算派生数据（写法与行情页 MarketView 同惯例）
    @ObservedObject private var dbm = DatabaseManager.shared
    @ObservedObject private var fav = FavoritesStore.shared
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var colCfg = MarketConfigStore.shared

    var body: some View {
        Group {
            switch layoutStore.favoritesLayout {
            case .a:
                FavoritesLayoutAView(model: model)
            case .b, .c, .d:
                // TODO: 后续阶段接入 B / C / D 三套布局，当前暂回落 A
                FavoritesLayoutAView(model: model)
            }
        }
        // 异形屏横屏贴边已由 ContentView 根布局统一处理，此处仅实测宿主宽度
        // （贴边后的真实可视宽），供 maxHOffset 计算横向滚动上限
        .marketTableHostWidth(to: $model.tableVisibleWidth)
        .onAppear { if dbm.isLoaded { model.prefetchAllGroups() } }
        .onChange(of: dbm.isLoaded) { loaded in
            if loaded { model.prefetchAllGroups() }
        }
        // 5 个呈现层（列配置 / 管理分组 / 新建分组 / 公式编辑 / 加入分组）挂在容器层，四档共用
        .favoritesSheets(model: model)
    }
}

// MARK: - 辅助 Identifiable 包装

struct FavIdentifiableMeta: Identifiable {
    let meta: MetaItem
    var id: Int { meta.id }
}
struct IdentifiableGroup: Identifiable {
    let group: FavoritesGroup
    var id: UUID { group.id }
}

// MARK: - 管理分组 sheet（删除/重命名/排序/隐藏）

struct FavManageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var fav: FavoritesStore
    /// 点「重新选择」时打开的公式分组编辑浮层
    @State private var formulaEditorTarget: FavoritesGroup? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("取消") { dismiss() }.foregroundColor(.secondary)
                Spacer()
                Text("管理分组").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Text("完成").foregroundColor(.blue).fontWeight(.bold)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            List {
                Section("分组顺序与显隐（长按拖动排序）") {
                    ForEach(Array(fav.groups.enumerated()), id: \.element.id) { i, _ in
                        let g = fav.groups[i]
                        let issue = fav.formulaIssue(groupID: g.id)
                        HStack(spacing: 10) {
                            Image(systemName: g.kind == .manual ? "folder.fill" : "function")
                                .foregroundColor(g.kind == .manual ? .orange : .purple)
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("分组名",
                                          text: Binding(
                                            get: { fav.groups[i].name },
                                            set: { nv in fav.groups[i].name = nv }
                                          ))
                                    .onSubmit { fav.saveToDisk() }
                                HStack(spacing: 8) {
                                    Text(g.kind == .manual ? "自定义" : "公式选股")
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(g.kind == .manual ? Color.orange.opacity(0.15) : Color.purple.opacity(0.15))
                                        .foregroundColor(g.kind == .manual ? .orange : .purple)
                                        .cornerRadius(4)
                                    // 公式分组显示引用到的选股公式名；引用失效时用橙字提示
                                    if g.kind == .formula {
                                        Text(fav.formulaName(groupID: g.id) ?? "未选择公式")
                                            .font(.system(size: 11))
                                            .foregroundColor(issue == nil ? .secondary : .orange)
                                            .lineLimit(1)
                                    }
                                    Text("\(g.manualMetaIDs.count) 只")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                }
                                // 引用失效：橙字提示 + 「重新选择」入口（打开公式分组编辑浮层）
                                if let issue = issue {
                                    HStack(spacing: 6) {
                                        Text(issue)
                                            .font(.system(size: 11))
                                            .foregroundColor(.orange)
                                        Button("重新选择") { formulaEditorTarget = g }
                                            .font(.system(size: 11))
                                            .foregroundColor(.blue)
                                            .contentShape(Rectangle())
                                    }
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !fav.groups[i].isHidden },
                                set: { nv in
                                    fav.groups[i].isHidden = !nv
                                    fav.saveToDisk()
                                }
                            )).labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in
                        fav.moveGroup(fromOffsets: from, toOffset: to)
                    }
                    .onDelete { idx in
                        idx.forEach { i in
                            fav.removeGroup(id: fav.groups[i].id)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
        }
        .background(Color(.systemGroupedBackground))
        // sheet 是独立呈现图层，需单独禁用键盘避让，保证弹出键盘时面板布局不被挤压
        .ignoresSafeArea(.keyboard)
        // 「重新选择」：打开公式分组编辑浮层（改引用 / 换公式）
        .sheet(item: $formulaEditorTarget) { g in
            FavFormulaEditorSheet(group: g, fav: fav)
        }
    }
}

// MARK: - 新建分组 sheet（自定义/公式）

struct FavAddGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var fav: FavoritesStore
    @State private var name: String = ""
    @State private var kind: FavoritesGroupKind = .manual
    /// 选中的选股公式库条目 id（nil = 未选择，公式分组此时不可创建）
    @State private var selectedPickerID: String?
    /// 全屏打开公式管理页（新建选股公式）
    @State private var showFormulaCenter = false

    /// 名称非空；公式分组还要求已选中一条选股公式
    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind == .formula { return selectedPickerID != nil }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("取消") { dismiss() }.foregroundColor(.secondary)
                Spacer()
                Text("新建分组").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: {
                    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanName.isEmpty else { return }
                    switch kind {
                    case .manual:
                        fav.addGroup(.manual(name: cleanName))
                    case .formula:
                        guard let pickerID = selectedPickerID else { return }
                        fav.addGroup(.formula(name: cleanName, formulaID: pickerID))
                    }
                    dismiss()
                }) {
                    Text("创建").foregroundColor(.blue).fontWeight(.bold)
                }
                .disabled(!canCreate)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            Form {
                Section {
                    TextField("分组名称（如：科技龙头）", text: $name)
                        .font(.system(size: 16))
                    Picker("分组类型", selection: $kind) {
                        Text("自定义分组").tag(FavoritesGroupKind.manual)
                        Text("指标公式自动分组").tag(FavoritesGroupKind.formula)
                    }
                    .pickerStyle(.segmented)
                } header: { Text("基本信息") }

                if kind == .formula {
                    Section(header: Text("选择选股公式")) {
                        FavPickerFormulaChooser(selectedID: $selectedPickerID) {
                            showFormulaCenter = true
                        }
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        // sheet 是独立呈现图层，需单独禁用键盘避让，保证弹出键盘时面板布局不被挤压
        .ignoresSafeArea(.keyboard)
        // 去公式管理新建选股公式（关闭后列表因 @Published 自动刷新）
        .fullScreenCover(isPresented: $showFormulaCenter) {
            FormulaCenterView(initialKind: .picker, onClose: { showFormulaCenter = false })
        }
    }
}

// MARK: - 选股公式选择器（新建 / 编辑公式分组共用）

/// 从公式库的选股公式中选择一条引用：单选列表 + 「去公式管理新建」入口。
/// 公式文本只在公式管理里维护，这里只做选择。
private struct FavPickerFormulaChooser: View {
    @Binding var selectedID: String?
    var onOpenLibrary: () -> Void

    @ObservedObject private var library = FormulaLibraryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if library.pickers.isEmpty {
                Text("公式库还没有选股公式")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(library.pickers) { doc in
                        pickerRow(doc)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
            }

            Button(action: onOpenLibrary) {
                HStack(spacing: 6) {
                    Image(systemName: "function").font(.system(size: 13, weight: .semibold))
                    Text("去公式管理新建").font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .background(Color.blue.opacity(0.08))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            Text("选股公式统一在公式管理里维护；这里只选择引用。分组刷新时最后一根输出值 > 0 视为命中")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickerRow(_ doc: FormulaDoc) -> some View {
        let selected = selectedID == doc.id
        return Button {
            selectedID = doc.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(selected ? .blue : .gray)
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.name)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Text(summary(doc.pickBody))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 单行摘要：去掉换行并裁剪空白
    private func summary(_ body: String) -> String {
        let one = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? "（空公式）" : one
    }
}

// MARK: - 公式分组编辑器（已有公式分组的修改）

struct FavFormulaEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: FavoritesGroup
    @ObservedObject var fav: FavoritesStore

    @State private var name: String
    /// 选中的选股公式库条目 id（初始 = 分组当前引用）
    @State private var selectedPickerID: String?
    /// 全屏打开公式管理页（新建选股公式）
    @State private var showFormulaCenter = false

    init(group: FavoritesGroup, fav: FavoritesStore) {
        self.group = group
        self.fav = fav
        _name = State(initialValue: group.name)
        _selectedPickerID = State(initialValue: group.formulaID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("取消") { dismiss() }.foregroundColor(.secondary)
                Spacer()
                Text("公式分组：\(group.name)")
                    .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: {
                    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !n.isEmpty else { return }
                    // 改名 + 重绑公式引用（内部会落盘并清空旧结果）
                    fav.renameGroup(id: group.id, name: n)
                    fav.bindFormula(groupID: group.id, formulaID: selectedPickerID)
                    dismiss()
                }) {
                    Text("保存").foregroundColor(.blue).fontWeight(.bold)
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            // 引用失效提示（引用的选股公式已被删除）
            if let issue = fav.formulaIssue(groupID: group.id) {
                Text(issue)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 10)
            }

            Form {
                Section(header: Text("分组名称")) {
                    TextField("名称", text: $name)
                }
                Section(header: Text("选择选股公式"),
                        footer: Text("点击保存后会清空旧结果；回到自选页点「刷新选股」后台跑全市场，输出线最后一根值 > 0 即入选")) {
                    FavPickerFormulaChooser(selectedID: $selectedPickerID) {
                        showFormulaCenter = true
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        // sheet 是独立呈现图层，需单独禁用键盘避让，保证弹出键盘时面板布局不被挤压
        .ignoresSafeArea(.keyboard)
        // 去公式管理新建选股公式（关闭后列表因 @Published 自动刷新）
        .fullScreenCover(isPresented: $showFormulaCenter) {
            FormulaCenterView(initialKind: .picker, onClose: { showFormulaCenter = false })
        }
    }
}

// MARK: - 扩展：让 FavManageSheet 能触发保存（因为它直接对 $fav.groups 绑定写）

extension FavoritesStore {
    // saveToDisk 已在 FavoritesStore 暴露，无需再扩展
}

extension FavoritesStore {
    /// 对外暴露的 groups 下标修改（FavManageSheet 绑定写元素属性时调用）
    func updateGroupProperty(id: UUID, mutate: (inout FavoritesGroup) -> Void) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&groups[idx])
        saveToDisk()
    }
}

#Preview {
    FavoritesView()
}
