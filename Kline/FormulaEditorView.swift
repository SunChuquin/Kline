//
//  FormulaEditorView.swift
//  Kline
//
//  通达信公式编辑器：新增/编辑/删除/测试自定义指标。
//
//  Created by 孙楚昆 on 2026/8/16.
//

import SwiftUI
import UIKit

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
                .transition(.opacity)
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
struct IndicatorEditSheet: View {
    let indicator: CustomIndicator?
    let data: [KlineItem]
    var onCancel: () -> Void
    var onSave: (CustomIndicator) -> Void

    // ---- 系统指标公式编辑模式 ----
    /// 是否为系统指标（此时不编辑名称/作用域，保存写回 .tdx）
    let isSystemIndicator: Bool
    /// 系统指标初始公式模板（用于初始化输入框 & 判断是否有修改）
    let systemInitialFormula: String
    /// 是否可「恢复编译时内容」（系统指标 true，自定义指标 false）
    let canRestoreBuiltin: Bool
    /// 恢复编译时内容回调：返回恢复后的模板（nil 表示恢复失败）
    var onRestoreBuiltin: (() -> String?)?
    /// 系统指标保存回调（传入编辑后的公式模板）
    var onSaveSystem: ((String) -> Void)?

    @State private var name: String
    @State private var formula: String
    @State private var color: Color
    @State private var scope: IndicatorScope = .sub
    /// 适用范围（选中的周期集合）；全周期与 Set(KlinePeriod.allCases) 等价，保存时统一记为 nil
    @State private var applicablePeriods: Set<KlinePeriod> = Set(KlinePeriod.allCases)
    @State private var style: TDXLineStyle = .solid
    @State private var thickness: Int = 1
    @State private var testMessage: String?
    @State private var testError: Bool = false
    @State private var showCancelConfirm = false
    /// 公式输入框控制器：支持向光标处插入 / 全选
    private let inputController = FormulaInputController()

    /// 名称与公式都非空才允许保存
    private var canSave: Bool {
        if isSystemIndicator {
            return !formula.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && !formula.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 相对原始指标是否有未保存的修改
    private var hasChanges: Bool {
        if isSystemIndicator {
            return formula != systemInitialFormula
        }
        if let ind = indicator {
            return name != ind.name
                || formula != ind.formula
                || scope != ind.scope
                || color.hexString != ind.colorHex
                || applicablePeriods != Set(ind.applicablePeriods ?? KlinePeriod.allCases)
        } else {
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                || !formula.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    init(indicator: CustomIndicator?, data: [KlineItem], onCancel: @escaping () -> Void, onSave: @escaping (CustomIndicator) -> Void,
         isSystemIndicator: Bool = false,
         systemInitialFormula: String = "",
         canRestoreBuiltin: Bool = false,
         onRestoreBuiltin: (() -> String?)? = nil,
         onSaveSystem: ((String) -> Void)? = nil) {
        self.indicator = indicator
        self.data = data
        self.onCancel = onCancel
        self.onSave = onSave
        self.isSystemIndicator = isSystemIndicator
        self.systemInitialFormula = systemInitialFormula
        self.canRestoreBuiltin = canRestoreBuiltin
        self.onRestoreBuiltin = onRestoreBuiltin
        self.onSaveSystem = onSaveSystem
        _name = State(initialValue: indicator?.name ?? "")
        _formula = State(initialValue: isSystemIndicator ? systemInitialFormula : (indicator?.formula ?? ""))
        _color = State(initialValue: indicator?.color ?? Color(hex: "1E88E5")!)
        _scope = State(initialValue: indicator?.scope ?? .sub)
        _applicablePeriods = State(initialValue: Set(indicator?.applicablePeriods ?? KlinePeriod.allCases))
    }

    var body: some View {
        VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(isSystemIndicator ? "编辑系统指标公式" : (indicator == nil ? "新建指标" : "编辑指标"))
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                    Spacer(minLength: 4)
                    Button("全选") { inputController.selectAll() }
                        .font(.system(size: 12)).foregroundColor(.blue)
                    Button("清空") { formula = "" }
                        .font(.system(size: 12)).foregroundColor(.blue)
                    Button("测试公式") { runTest() }
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.blue)
                    // 恢复编译时内容：仅系统指标可点（自定义指标禁用）
                    Button("恢复编译时内容") { restoreBuiltin() }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(canRestoreBuiltin ? .orange : .gray)
                        .disabled(!canRestoreBuiltin)
                    Button("保存") { save() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(canSave ? Color.blue : Color.gray)
                        .cornerRadius(6)
                        .disabled(!canSave)
                    Button("取消") {
                        if hasChanges {
                            showCancelConfirm = true
                        } else {
                            onCancel()
                        }
                    }
                    .font(.system(size: 12)).foregroundColor(.gray)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 名称 + 作用域 合在一行（系统指标不编辑名称/作用域，隐藏）
                        if !isSystemIndicator {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("名称").font(.system(size: 13, weight: .medium)).foregroundColor(.black)
                                TextField("例如：双均线", text: $name)
                                    .font(.system(size: 14))
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(Color(uiColor: .systemGray6)).cornerRadius(6)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("作用域").font(.system(size: 13, weight: .medium)).foregroundColor(.black)
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        }
                        // 适用范围（仅自定义指标）：全周期 or 单/多周期
                        field("适用范围") {
                            HStack(spacing: 8) {
                                styleChip("全周期", opt: "", selected: applicablePeriods == Set(KlinePeriod.allCases)) {
                                    applicablePeriods = Set(KlinePeriod.allCases)
                                }
                                ForEach(KlinePeriod.allCases) { p in
                                    styleChip(p.rawValue, opt: "", selected: applicablePeriods.contains(p)) {
                                        toggleApplicable(p)
                                    }
                                }
                            }
                            Text("选择该指标可用的周期。不同周期各有一份独立参数副本（USER_<名称>.tdx），可单独编辑")
                                .font(.system(size: 10)).foregroundColor(.gray)
                        }
                        field("公式") {
                            FormulaTextView(text: Binding(
                                get: { formula },
                                set: { formula = $0 }
                            ), controller: inputController)
                            .frame(minHeight: 180)
                            .padding(8)
                            .background(Color(uiColor: .systemGray6)).cornerRadius(6)
                            Text("支持：MA/EMA/SMA/REF/HHV/LLV/ABS/MAX/MIN/SUM/STD/COUNT/IF/CROSS/BARSLAST/AND/OR/NOT，数据 C/H/L/O/V/AMOUNT，运算符 + - * / < > <= >= == != ")
                                .font(.system(size: 10)).foregroundColor(.gray)
                        }
                        field("常用符号") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], alignment: .leading, spacing: 6) {
                                symbolChip(":=")
                                symbolChip(";")
                                symbolChip(",")
                                symbolChip("：")
                                symbolChip("（")
                                symbolChip("）")
                                symbolChip("{")
                                symbolChip("}")
                                symbolChip("=")
                                symbolChip("+")
                                symbolChip("-")
                                symbolChip("!")
                                symbolChip("*")
                                symbolChip("/")
                                symbolChip("<")
                                symbolChip(">")
                                symbolChip("AND")
                                symbolChip("OR")
                            }
                        }
                        field("输出线条样式（通达信选项）") {
                            // 线条类型：全宽单行，避免"不绘制"换行
                            HStack(spacing: 8) {
                                Text("样式").font(.system(size: 11)).foregroundColor(.gray)
                                styleChip("实线", opt: "", selected: style == .solid) { style = .solid }
                                styleChip("虚线", opt: ",DOTLINE", selected: style == .dotline) { appendOption(",DOTLINE"); style = .dotline }
                                styleChip("圆点", opt: ",POINTDOT", selected: style == .pointdot) { appendOption(",POINTDOT"); style = .pointdot }
                                styleChip("柱状", opt: ",STICK", selected: style == .stick) { appendOption(",STICK"); style = .stick }
                                styleChip("不绘制", opt: ",NODRAW", selected: style == .nodraw) { appendOption(",NODRAW"); style = .nodraw }
                                Spacer(minLength: 0)
                            }
                            // 线条粗细：全宽单行
                            HStack(spacing: 8) {
                                Text("粗细").font(.system(size: 11)).foregroundColor(.gray)
                                ForEach([1, 2, 3, 4], id: \.self) { t in
                                    styleChip("×\(t)", opt: t == 1 ? "" : ",LINETHICK\(t)", selected: thickness == t) {
                                        if t != 1 { appendOption(",LINETHICK\(t)") }
                                        thickness = t
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            // 颜色（只显示色块，9 列排成两行）
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
                                ForEach(TDXFormulaColor.palette, id: \.1) { item in
                                    colorChip(name: item.0, hex: item.1, option: ",COLOR\(itemOption(for: item.0))")
                                }
                            }
                            Text("点击样式/粗细/颜色会在光标处插入对应关键字，例如插入 DOTLINE / LINETHICK2 / COLORRED")
                                .font(.system(size: 10)).foregroundColor(.gray)
                        }
                        if let message = testMessage {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundColor(testError ? .red : .black)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background((testError ? Color.red : Color.green).opacity(0.1)).cornerRadius(6)
                        }
                    }
                    .padding(16)
                }

                // 底部安全区
                Color.clear.frame(height: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .alert("存在修改未保存，是否取消修改？", isPresented: $showCancelConfirm) {
            Button("继续编辑", role: .cancel) { }
            Button("取消修改", role: .destructive) { onCancel() }
        }
    }

    private func toggleApplicable(_ period: KlinePeriod) {
        if applicablePeriods == Set(KlinePeriod.allCases) {
            // 从全周期开始单点：改为仅选中该周期
            applicablePeriods = [period]
        } else if applicablePeriods.contains(period) {
            applicablePeriods.remove(period)
        } else {
            applicablePeriods.insert(period)
        }
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
        // 系统指标：直接回调保存公式模板（由外部写回 .tdx）
        if isSystemIndicator {
            onSaveSystem?(formula)
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        var ind = indicator ?? CustomIndicator(name: trimmedName, formula: formula)
        ind.name = trimmedName
        ind.formula = formula
        ind.scope = scope
        ind.colorHex = color.hexString
        ind.applicablePeriods = applicablePeriods == Set(KlinePeriod.allCases) ? nil : Array(applicablePeriods)
        onSave(ind)
    }

    /// 恢复编译时内容：从内置模板恢复当前编辑的系统指标公式
    private func restoreBuiltin() {
        guard let onRestoreBuiltin, let restored = onRestoreBuiltin() else { return }
        formula = restored
        testMessage = nil
        testError = false
    }

    private func appendOption(_ opt: String) {
        // 只插入关键字（去掉前导逗号），插入到公式编辑器中光标所在位置
        let keyword = opt.trimmingCharacters(in: CharacterSet(charactersIn: ","))
        guard !keyword.isEmpty else { return }
        inputController.insert(keyword)
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(selected ? .white : .black)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(selected ? Color.blue : Color(uiColor: .systemGray6))
                .cornerRadius(6)
        }
    }

    private func colorChip(name: String, hex: String, option: String) -> some View {
        Button {
            appendOption(option)
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(hex: hex)!)
                .frame(height: 24)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.black.opacity(0.15), lineWidth: 1)
                )
        }
    }

    /// 常用符号快捷输入：点击即插入到公式光标处
    private func symbolChip(_ s: String) -> some View {
        Button {
            inputController.insert(s)
        } label: {
            Text(s)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.black)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color(uiColor: .systemGray6)).cornerRadius(6)
        }
    }
}

// MARK: - 公式输入框（UITextView 封装）

/// 公式输入框控制器：向光标处插入内容 / 全选公式
final class FormulaInputController {
    weak var textView: UITextView?

    /// 在公式光标处插入文本（会自动触发绑定同步）
    func insert(_ s: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        FormulaTextView.replace(range: range, with: s, in: tv)
    }

    /// 全选公式内容
    func selectAll() {
        guard let tv = textView else { return }
        tv.becomeFirstResponder()
        tv.selectAll(nil)
    }
}

/// 公式输入框：UITextView 封装，输入自动转大写，且支持在光标处插入、全选
struct FormulaTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: FormulaInputController

    /// 把 NSRange 替换转换为 UITextView 的 UITextRange 替换
    static func replace(range: NSRange, with replacement: String, in tv: UITextView) {
        guard let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: range.length),
              let r = tv.textRange(from: start, to: end) else { return }
        tv.replace(r, withText: replacement)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = .clear
        tv.autocapitalizationType = .allCharacters
        tv.autocorrectionType = .no
        tv.spellCheckingType = .no
        tv.delegate = context.coordinator
        controller.textView = tv
        tv.text = text
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // 仅当外部状态与输入框不一致时才写回，避免打断光标
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FormulaTextView

        init(_ p: FormulaTextView) { parent = p }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text.uppercased()
        }

        /// 输入时把小写字母就地转大写，保持光标不跳动
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let up = text.uppercased()
            if up != text {
                FormulaTextView.replace(range: range, with: up, in: textView)
                return false
            }
            return true
        }
    }
}

// MARK: - 系统指标公式编辑器（复用 IndicatorEditSheet 的系统指标模式）

/// 系统指标公式编辑容器：主图可切换指标，副图固定当前指标。
/// 保存写回对该周期目录的 .tdx；「恢复编译时内容」仅系统指标可用。
struct SystemIndicatorEditorContainer: View {
    let data: [KlineItem]
    /// true = 主图（可在所有 SCOPE=main 的 .tdx 指标间切换），false = 副图（固定 initialSubId）
    let isMain: Bool
    /// 当前编辑的行情周期：写回/读取 Documents/indicator/<周期目录>/*.tdx
    let period: KlinePeriod
    var onClose: () -> Void
    /// 保存成功回调：传入保存的指标 id（供外部重算）
    var onSaved: (String) -> Void

    /// 主图系统指标列表（数据驱动，来自 .tdx SCOPE=main），仅显示当前勾选启用的指标
    private var mainIds: [String] {
        let enabled = ChartConfigStore.shared.mainIndicators
        return SystemIndicatorStore.shared.mainIndicatorDefs(period: period)
            .map { $0.id }
            .filter { enabled.contains($0) }
    }

    @State private var mainId: String = "MA"
    @State private var subId: String

    init(data: [KlineItem], isMain: Bool, period: KlinePeriod, initialSubId: String = "",
         onClose: @escaping () -> Void, onSaved: @escaping (String) -> Void) {
        self.data = data
        self.isMain = isMain
        self.period = period
        self.onClose = onClose
        self.onSaved = onSaved
        _subId = State(initialValue: initialSubId)
        // 默认选勾选启用的第一个主图指标；若列表已不含 "MA"，兜底用列表首个
        let enabled = ChartConfigStore.shared.mainIndicators
        let ids = SystemIndicatorStore.shared.mainIndicatorDefs(period: period).map { $0.id }.filter { enabled.contains($0) }
        if !ids.isEmpty && !ids.contains("MA") {
            _mainId = State(initialValue: ids[0])
        }
    }

    private var currentId: String { isMain ? mainId : subId }

    var body: some View {
        let id = currentId
        VStack(spacing: 0) {
            if isMain {
                // 主图系统指标切换栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mainIds, id: \.self) { mid in
                            Button(mid) { mainId = mid }
                                .font(.system(size: 13, weight: mainId == mid ? .semibold : .regular))
                                .foregroundColor(mainId == mid ? .white : .black)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(mainId == mid ? Color.blue : Color(uiColor: .systemGray6))
                                .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Divider()
            }
            IndicatorEditSheet(
                indicator: nil,
                data: data,
                onCancel: onClose,
                onSave: { _ in },
                isSystemIndicator: true,
                systemInitialFormula: SystemIndicatorStore.shared.template(for: id, period: period) ?? "",
                canRestoreBuiltin: true,
                onRestoreBuiltin: {
                    guard SystemIndicatorStore.shared.restoreBuiltin(for: id, period: period) else { return nil }
                    return SystemIndicatorStore.shared.template(for: id, period: period)
                },
                onSaveSystem: { template in
                    if SystemIndicatorStore.shared.saveTemplate(template, for: id, period: period) {
                        onSaved(id)
                    }
                    onClose()
                }
            )
            .id(id)
        }
        .background(Color.white)
    }
}