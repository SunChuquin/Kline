//
//  ChartSheetKit.swift
//  Kline
//
//  指标选择面板域：底部面板容器、主/副图指标格子与自定义指标行、参数入口、
//  面板头尾组件与内置指标重置。从 KlineChartView.swift 拆分（方法平移）。
//

import SwiftUI

extension KlineChartView {

    // MARK: - 底部面板容器

    func bottomSheet<Content: View>(geometry: GeometryProxy, heightFraction: CGFloat,
                                            @ViewBuilder content: () -> Content,
                                            onClose: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea().frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { onClose() } }
            VStack(spacing: 0) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geometry.size.width, height: min(geometry.size.height * heightFraction, 660))
            .background(Color.white)
            // 只圆顶部两角：底边贴紧物理屏幕底边后，底部若保留圆角，两角会露出深色遮罩
            .clipShape(TopRoundedCornerRect(radius: 16))
            // ⚠️ 固定高度面板直接加 .ignoresSafeArea 无效：扩展容器内默认居中放置，
            // 面板只下移半个 inset、底部仍留灰缝（露出遮罩）。
            // 必须用贪婪 frame(alignment:.bottom) 把面板钉在容器底边，
            // 扩展后容器底边 = 物理屏幕底边，面板才真正贴底
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 主图选择页（紧凑分组 + 编辑图标）

    var mainSheetContent: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "主图指标") { editorUI.showMainSheet = false }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 系统主图指标（数据驱动，集合来自 .tdx SCOPE=main）
                    groupHeader("主图指标")
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        ForEach(mainIndicatorDefsForSheet, id: \.id) { def in
                            mainTile(def.name, on: config.mainIndicators(for: self.period).contains(def.id)) { toggleMain(def.id) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)

                    // 系统指标公式编辑入口
                    if !mainIndicatorDefsForSheet.isEmpty {
                        paramEntryRow(title: "公式编辑") {
                            editorUI.showMainSheet = false
                            editorUI.systemEditorIsMain = true
                            showSystemEditor = true
                        }
                    }

                    groupHeader("自定义指标（主图）")
                    HStack {
                        Button("+ 新增/管理") { editorUI.showMainSheet = false; editorUI.editorTarget = .main; showCustomEditor = true }
                            .font(.system(size: 13)).foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    if mainCustoms.isEmpty {
                        Text("暂无主图自定义指标").font(.system(size: 12)).foregroundColor(.gray)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    } else {
                        ForEach(mainCustoms) { ind in mainCustomRow(ind) }
                    }
                    Spacer(minLength: 24)
                }
            }
        }
    }

    var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: 80), spacing: 8)] }

    /// 主图选择页数据驱动指标列表（来自 .tdx SCOPE=main）
    var mainIndicatorDefsForSheet: [SystemIndicatorDef] { SystemIndicatorStore.shared.mainIndicatorDefs(period: self.period) }
    var mainCustoms: [CustomIndicator] { customStore.indicators.filter { $0.scope == .main && availableInCurrentPeriod($0) } }

    /// 该自定义指标是否适用于当前周期（适用范围为全周期 nil 也包含当前周期）
    func availableInCurrentPeriod(_ ind: CustomIndicator) -> Bool {
        let applicable = CustomIndicatorStore.applicablePeriods(of: ind)
        return applicable.contains(period)
    }

    func toggleMain(_ id: String) {
        config.toggleMainIndicator(id, period: self.period)
        recomputeMainCurves(force: true)
    }

    /// 主图指标格：复选框（多选）
    func mainTile(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(on ? .blue : .gray.opacity(0.6))
                Text(title).font(.system(size: 13)).foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(uiColor: .systemGray6).opacity(on ? 1 : 0.45))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.blue : Color.gray.opacity(0.25), lineWidth: on ? 1.5 : 1))
        }
    }

    func mainCustomRow(_ ind: CustomIndicator) -> some View {
        HStack {
            Button {
                if activeCustomIndicator?.id == ind.id { activateCustom(nil) } else { activateCustom(ind) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: activeCustomIndicator?.id == ind.id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(activeCustomIndicator?.id == ind.id ? .blue : .gray)
                    RoundedRectangle(cornerRadius: 2).fill(ind.color).frame(width: 14, height: 5)
                    Text(ind.name).font(.system(size: 14)).foregroundColor(.black)
                }
            }
            Spacer()
            Button {
                editorUI.showMainSheet = false; editorUI.editorTarget = .main; showCustomEditor = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 13)).foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: - 副图选择页（紧凑分组 + 编辑图标）

    var subSheetContent: some View {
        let m = model(for: editorUI.editingSlot)
        return VStack(spacing: 0) {
            sheetHeader(title: "选择副图指标 · \(slotTitle(editorUI.editingSlot))") { editorUI.showSubSheet = false }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subSelectionGroups, id: \.0) { g, kinds in
                        groupHeader(g)
                        LazyVGrid(columns: gridColumns, spacing: 8) {
                            ForEach(kinds, id: \.self) { k in
                                subTile(k, selected: !m.isCustom && m.kind == k) {
                                    m.activeCustomID = nil
                                    m.kind = k
                                    ChartConfigStore.shared.recordSubKinds(for: self.period)
                                    recomputeSub(m, force: true)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 6)
                    }

                    // 公式式系统指标（有 .tdx 模板，如 MACD/KDJ）才提供公式编辑；VOL/AMO 无模板不提供
                    if !m.isCustom,
                       SystemIndicatorStore.shared.template(for: m.kind, period: self.period) != nil {
                        paramEntryRow(title: "\(m.kind) 公式编辑") {
                            editorUI.showSubSheet = false
                            editorUI.systemEditorIsMain = false
                            editorUI.systemEditorSubId = m.kind
                            showSystemEditor = true
                        }
                    }

                    groupHeader("自定义指标（副图）")
                    HStack {
                        Button("+ 新增/管理") { editorUI.showSubSheet = false; editorUI.editorTarget = .sub; showCustomEditor = true }
                            .font(.system(size: 13)).foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    if subCustoms.isEmpty {
                        Text("暂无副图自定义指标").font(.system(size: 12)).foregroundColor(.gray)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    } else {
                        ForEach(subCustoms) { ind in subCustomRow(ind, model: m) }
                    }
                    Spacer(minLength: 24)
                }
            }
        }
    }

    /// 副图选择分组（数据驱动）：内置无模板的 VOL/AMO + 所有 SCOPE=sub 的 .tdx，按 GROUP 分组
    var subSelectionGroups: [(String, [String])] {
        let store = SystemIndicatorStore.shared
        var map: [String: [String]] = [:]
        // 内置无模板项：VOL/AMO 走专用成交量柱绘制，不在 .tdx 中
        map["量能", default: []].append("VOL")
        map["量能", default: []].append("AMO")
        // .tdx 副图：GROUP 取自定义的 tdx 字段
        for def in store.subIndicatorDefs(period: self.period) {
            let g = def.group.isEmpty ? "其他" : def.group
            map[g, default: []].append(def.id)
        }
        var result: [(String, [String])] = []
        for g in SystemIndicatorStore.subGroupOrder where map[g] != nil {
            result.append((g, map[g]!))
        }
        for g in map.keys where !SystemIndicatorStore.subGroupOrder.contains(g) {
            result.append((g, map[g]!))
        }
        return result
    }

    /// 副图指标格：单选，选中名称蓝色
    func subTile(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .blue : .black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(uiColor: .systemGray6).opacity(selected ? 1 : 0.45))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.blue : Color.gray.opacity(0.25), lineWidth: selected ? 1.5 : 1))
        }
    }

    var subCustoms: [CustomIndicator] { customStore.indicators.filter { $0.scope == .sub && availableInCurrentPeriod($0) } }
    func slotTitle(_ slot: SubSlot) -> String {
        switch slot {
        case .top: return "副图一"
        case .bottom: return "副图二"
        case .third: return "副图三"
        }
    }

    func subCustomRow(_ ind: CustomIndicator, model m: SubChartModel) -> some View {
        HStack {
            Button {
                activateSubCustom(m, ind)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: m.activeCustomID == ind.id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(m.activeCustomID == ind.id ? .blue : .gray)
                    RoundedRectangle(cornerRadius: 2).fill(ind.color).frame(width: 14, height: 5)
                    Text(ind.name).font(.system(size: 14)).foregroundColor(.black)
                    if m.activeCustomID == ind.id {
                        Text("当前").font(.system(size: 10)).foregroundColor(.blue)
                    }
                }
            }
            Spacer()
            Button {
                editorUI.showSubSheet = false; editorUI.editorTarget = .sub; showCustomEditor = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 13)).foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: - 主体 UI 组件

    /// 全宽参数入口按钮行（打开全屏参数编辑页）
    func paramEntryRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.blue.opacity(0.06))
            .cornerRadius(8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.gray)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    func sheetHeader(title: String, onClose: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(.black)
            Spacer()
            Button("重置内置指标") { editorUI.showResetBuiltinConfirm = true }
                .font(.system(size: 13)).foregroundColor(.red)
            Button("完成") { onClose() }.font(.system(size: 14)).foregroundColor(.blue)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .alert("重置内置指标", isPresented: Binding(get: { editorUI.showResetBuiltinConfirm },
                                              set: { editorUI.showResetBuiltinConfirm = $0 })) {
            Button("重置", role: .destructive) { performResetBuiltin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把所有内置指标恢复为编译时的内容，确定重置吗？")
        }
    }

    /// 重置所有内置指标为编译时内容，并立即重算主图与三个副图
    func performResetBuiltin() {
        SystemIndicatorStore.shared.restoreAllBuiltin(period: self.period)
        recomputeMainCurves(force: true)
        for m in [subTop, subBottom, subThird] { recomputeSub(m, force: true) }
    }


}
