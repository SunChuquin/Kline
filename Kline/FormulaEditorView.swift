//
//  FormulaEditorView.swift
//  Kline
//
//  通达信公式编辑器：新增/编辑/删除/测试自定义指标。
//
//  Created by 孙楚昆 on 2026/8/16.
//

import SwiftUI

/// 通达信公式编辑器（全屏 overlay 页面）
struct FormulaEditorView: View {
    @ObservedObject private var store = CustomIndicatorStore.shared
    let data: [KlineItem]
    var onClose: () -> Void
    /// 保存成功后的回调（用于自动激活到对应图表）
    var onSaved: ((CustomIndicator) -> Void)? = nil

    /// 正在编辑的指标（nil 且 showEditor 时表示新增）
    @State private var showEditor = false
    @State private var editing: CustomIndicator?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.indicators.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(store.indicators) { item in
                        indicatorRow(item)
                    }
                    .onDelete { offsets in
                        for i in offsets { store.delete(store.indicators[i].id) }
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .overlay {
            if showEditor {
                IndicatorEditSheet(
                    indicator: editing,
                    data: data,
                    onCancel: { showEditor = false; editing = nil },
                    onSave: { ind in
                        let saved = ind
                        if editing == nil {
                            store.add(ind)
                        } else {
                            store.update(ind)
                        }
                        onSaved?(saved)
                        showEditor = false
                        editing = nil
                    }
                )
                .transition(.move(edge: .bottom))
                .zIndex(10)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    Text("返回").font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.gray.opacity(0.12)).cornerRadius(8)
            }
            .padding(.leading, 16)

            Spacer()

            Text("自定义指标")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.black)

            Spacer()

            Button {
                editing = nil
                showEditor = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 34, height: 34)
                    .background(Color.gray.opacity(0.12)).cornerRadius(8)
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color.white)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "function")
                .font(.system(size: 40)).foregroundColor(.gray.opacity(0.5))
            Text("还没有自定义指标")
                .font(.system(size: 15)).foregroundColor(.gray)
            Text("点击右上角 + 新建指标，支持通达信公式语法")
                .font(.system(size: 12)).foregroundColor(.gray.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func indicatorRow(_ item: CustomIndicator) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(item.color)
                .frame(width: 22, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 15, weight: .medium)).foregroundColor(.black)
                Text(item.formula.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11)).foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12)).foregroundColor(.gray)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            editing = item
            showEditor = true
        }
    }
}

/// 新建/编辑指标表单
private struct IndicatorEditSheet: View {
    let indicator: CustomIndicator?
    let data: [KlineItem]
    var onCancel: () -> Void
    var onSave: (CustomIndicator) -> Void

    @State private var name: String
    @State private var formula: String
    @State private var color: Color
    @State private var scope: IndicatorScope = .sub
    @State private var style: TDXLineStyle = .solid
    @State private var thickness: Int = 1
    @State private var testMessage: String?
    @State private var testError: Bool = false

    private let palette: [String] = [
        "1E88E5", "E53935", "43A047", "FB8C00", "8E24AA", "00ACC1", "5D4037", "757575"
    ]

    init(indicator: CustomIndicator?, data: [KlineItem], onCancel: @escaping () -> Void, onSave: @escaping (CustomIndicator) -> Void) {
        self.indicator = indicator
        self.data = data
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: indicator?.name ?? "")
        _formula = State(initialValue: indicator?.formula ?? "")
        _color = State(initialValue: indicator?.color ?? Color(hex: "1E88E5")!)
        _scope = State(initialValue: indicator?.scope ?? .sub)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部占位，点击关闭
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            VStack(spacing: 0) {
                HStack {
                    Text(indicator == nil ? "新建指标" : "编辑指标")
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                    Spacer()
                    Button("取消") { onCancel() }
                        .font(.system(size: 14)).foregroundColor(.gray)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        field("名称") {
                            TextField("例如：双均线", text: $name)
                                .font(.system(size: 14))
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color(uiColor: .systemGray6)).cornerRadius(6)
                        }
                        field("作用域") {
                            HStack(spacing: 8) {
                                ForEach(IndicatorScope.allCases) { s in
                                    Button {
                                        scope = s
                                    } label: {
                                        Text(s.rawValue)
                                            .font(.system(size: 12))
                                            .foregroundColor(scope == s ? .white : .black)
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(scope == s ? Color.blue : Color(uiColor: .systemGray6))
                                            .cornerRadius(6)
                                    }
                                }
                            }
                        }
                        field("公式") {
                            TextEditor(text: $formula)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(Color(uiColor: .systemGray6)).cornerRadius(6)
                            Text("支持：MA/EMA/SMA/REF/HHV/LLV/ABS/MAX/MIN/SUM/STD/COUNT/IF/CROSS/BARSLAST/AND/OR/NOT，数据 C/H/L/O/V/AMOUNT，运算符 + - * / < > <= >= == != ")
                                .font(.system(size: 10)).foregroundColor(.gray)
                        }
                        field("输出线条样式（通达信选项）") {
                            // 线条类型
                            HStack(spacing: 8) {
                                styleChip("实线", opt: "", selected: style == .solid) { style = .solid }
                                styleChip("虚线", opt: ",DOTLINE", selected: style == .dotline) { appendOption(",DOTLINE"); style = .dotline }
                                styleChip("圆点", opt: ",POINTDOT", selected: style == .pointdot) { appendOption(",POINTDOT"); style = .pointdot }
                                styleChip("柱状", opt: ",STICK", selected: style == .stick) { appendOption(",STICK"); style = .stick }
                                styleChip("不绘制", opt: ",NODRAW", selected: style == .nodraw) { appendOption(",NODRAW"); style = .nodraw }
                            }
                            // 线条粗细
                            HStack(spacing: 8) {
                                ForEach([1, 2, 3, 4], id: \.self) { t in
                                    styleChip("×\(t)", opt: t == 1 ? "" : ",LINETHICK\(t)", selected: thickness == t) {
                                        if t != 1 { appendOption(",LINETHICK\(t)") }
                                        thickness = t
                                    }
                                }
                            }
                            // 颜色
                            HStack(spacing: 8) {
                                ForEach(TDXFormulaColor.palette, id: \.1) { item in
                                    colorChip(name: item.0, hex: item.1, option: ",COLOR\(itemOption(for: item.0))")
                                }
                            }
                            Text("点击样式/粗细/颜色会将该选项追加到公式末尾，例如：MA5:MA(C,5),COLORRED,LINETHICK2;")
                                .font(.system(size: 10)).foregroundColor(.gray)
                        }
                        field("指标默认颜色") {
                            HStack(spacing: 10) {
                                ForEach(palette, id: \.self) { hex in
                                    Circle()
                                        .fill(Color(hex: hex)!)
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            Circle().stroke(Color.black.opacity(color == Color(hex: hex) ? 0.6 : 0.1), lineWidth: 2)
                                        )
                                        .onTapGesture { color = Color(hex: hex)! }
                                }
                            }
                        }
                        if let message = testMessage {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundColor(testError ? .red : .black)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background((testError ? Color.red : Color.green).opacity(0.1)).cornerRadius(6)
                        }
                        Button {
                            runTest()
                        } label: {
                            Text("测试公式")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.08)).cornerRadius(8)
                        }
                        Button {
                            save()
                        } label: {
                            Text("保存")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(name.trimmingCharacters(in: .whitespaces).isEmpty || formula.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.blue)
                                .cornerRadius(8)
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || formula.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(16)
                }

                // 底部安全区
                Color.clear.frame(height: 8)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: UIScreen.main.bounds.height * 0.85)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(.black)
            content()
        }
    }

    private func runTest() {
        testMessage = nil
        testError = false
        guard !data.isEmpty else {
            testMessage = "暂无行情数据用于测试"
            testError = true
            return
        }
        do {
            let lines = try TDXFormulaEngine.evaluate(formula: formula, data: data)
            let desc = lines.map { line in
                let last = line.values.last(where: { !$0.isNaN }).map { String(format: "%.3f", $0) } ?? "-"
                return "\(line.name): \(last)"
            }.joined(separator: "   ")
            testMessage = "✓ 解析成功\n\(desc)"
        } catch {
            testMessage = "✗ \(error.localizedDescription)"
            testError = true
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        var ind = indicator ?? CustomIndicator(name: trimmedName, formula: formula)
        ind.name = trimmedName
        ind.formula = formula
        ind.scope = scope
        ind.colorHex = color.hexString
        onSave(ind)
    }

    private func appendOption(_ opt: String) {
        if !formula.trimmingCharacters(in: .whitespaces).hasSuffix(";") {
            formula += ";"
        }
        formula += opt
    }

    /// 中文颜色名 → 通达信 COLORXXX 选项名（与 IndicatorStyle 的 palette 对应）
    private func itemOption(for cnName: String) -> String {
        let map: [String: String] = [
            "黑色": "BLACK", "蓝色": "BLUE", "绿色": "GREEN", "青色": "CYAN", "红色": "RED",
            "洋红": "MAGENTA", "橙色": "ORANGE", "棕色": "BROWN", "淡灰": "LIGRAY",
            "深灰": "GRAY", "淡蓝": "LILUE", "淡绿": "LIGREEN", "淡青": "LICYAN",
            "淡红": "LIRED", "淡洋红": "LIMAGENTA", "黄色": "YELLOW", "白色": "WHITE",
        ]
        return map[cnName] ?? "RED"
    }

    private func styleChip(_ text: String, opt: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(selected ? .white : .black)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? Color.blue : Color(uiColor: .systemGray6))
                .cornerRadius(6)
        }
    }

    private func colorChip(name: String, hex: String, option: String) -> some View {
        Button {
            appendOption(option)
        } label: {
            HStack(spacing: 3) {
                Circle().fill(Color(hex: hex)!).frame(width: 8, height: 8)
                Text(name).font(.system(size: 11)).foregroundColor(.black)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(uiColor: .systemGray6)).cornerRadius(6)
        }
    }
}