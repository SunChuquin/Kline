//
//  StrategyFormulaEditorView.swift
//  Kline
//
//  交易策略公式编辑器（全屏页面）：名称 + 选股条件（内嵌 / 引用二选一）+ 交易规则 + 预览与校验。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import SwiftUI
import UIKit

// MARK: - 编辑器内部模型

/// 一条规则行的可辨识模型：编辑器内部以结构化方式持有参数，写库时才序列化成 RULES 文本
private struct RuleRow: Identifiable {
    var id = UUID()
    var kind: StrategyRuleKind
    var params: [String: String]
}

/// 选股条件来源：内嵌公式 / 引用选股公式（二选一，切换时两侧内容都保留）
private enum PickMode: String, CaseIterable, Identifiable {
    case inline       // 内嵌选股公式正文
    case reference    // 引用公式库中的选股公式

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inline: return "内嵌公式"
        case .reference: return "引用选股公式"
        }
    }
}

/// 交易指令的「数量 / 金额」输入口径（二选一，切换时清掉另一侧，保证字段互斥）
private enum TradeSizeMode {
    case qty       // 按数量（股，整手）
    case amount    // 按金额（元，生成条件单时按最新价折算整手）
}

/// 交易指令里的分段项（用字符串 id 驱动回调，避免多处写泛型控件）
private struct TradeChipOption: Identifiable {
    let id: String
    let title: String
    /// 选中态文字色（nil 表示用语义 primary）
    var tint: Color? = nil
    var selected: Bool = false
}

// MARK: - 策略公式编辑器

/// 交易策略公式编辑器（全屏 overlay 页面）
///
/// 本阶段只做「定义与校验」：把策略文档（选股条件 + 交易指令 + 绑定账户 + 交易规则）
/// 写入公式库（Documents/formula/strategy/*.tdx）。绑定账户只读 SimStore.accounts，
/// 不生成条件单、不写任何模拟账户数据；条件单生成与回测留待执行阶段接入。
struct StrategyFormulaEditorView: View {
    /// 编辑中的策略文档；id 为空串表示新建
    var initialDoc: FormulaDoc
    /// 测试用行情数据（样例标的 K 线）
    var data: [KlineItem]
    var onClose: () -> Void
    /// 保存成功回调（回传已落盘的文档）
    var onSaved: (FormulaDoc) -> Void

    /// 公式库（引用模式下单选列表的数据源，保存也走它）
    @ObservedObject private var library = FormulaLibraryStore.shared
    /// 模拟交易总仓库（只读 accounts，列出可绑定账户；本页不写入任何模拟数据）
    @ObservedObject private var sim = SimStore.shared

    @State private var name: String
    /// 选股条件来源（内嵌 / 引用），切换只改显示，不清数据
    @State private var mode: PickMode
    /// 内嵌选股公式正文（与 pickRef 各自独立保存，切换分段不丢）
    @State private var pickBody: String
    /// 引用的选股公式 id（空串表示未选）
    @State private var pickRef: String
    /// 交易指令（方向 / 数量或金额 / 报价方式 / 有效期 / 绑定账户），实时写回
    @State private var trade: StrategyTradeSpec
    /// 数量 / 金额 的输入口径（切换时清掉另一侧字段）
    @State private var sizeMode: TradeSizeMode
    /// 数量输入框原文（与 trade.qty 双向同步，避免输入中间态被截断）
    @State private var qtyText: String
    /// 金额输入框原文（与 trade.amount 双向同步）
    @State private var amountText: String
    /// 偏移档次输入框原文（与 trade.offsetTicks 双向同步）
    @State private var offsetText: String
    /// 指定日期有效期的到期日（与 trade.expiresAt 双向同步）
    @State private var expiryDate: Date
    /// 规则行模型（每次改动都会序列化回 doc.rules 文本）
    @State private var rows: [RuleRow]
    /// 初始 RULES 文本的解析报错（在规则区上方就地红字提示，仍允许继续编辑）
    @State private var parseErrors: [String]
    /// 测试选股公式的结果文案
    @State private var testMessage: String?
    @State private var testIsError = false
    /// 保存失败文案（就地展示在校验区，不弹 alert）
    @State private var saveError: String?

    /// 内嵌选股公式输入框控制器（向光标处插入 / 全选）
    private let pickInputController = FormulaInputController()

    init(initialDoc: FormulaDoc, data: [KlineItem], onClose: @escaping () -> Void, onSaved: @escaping (FormulaDoc) -> Void) {
        self.initialDoc = initialDoc
        self.data = data
        self.onClose = onClose
        self.onSaved = onSaved

        let ref = initialDoc.pickRef ?? ""
        _name = State(initialValue: initialDoc.name)
        // 已填了引用则默认停在「引用」分段，否则停在「内嵌」
        _mode = State(initialValue: ref.isEmpty ? .inline : .reference)
        _pickBody = State(initialValue: initialDoc.pickBody)
        _pickRef = State(initialValue: ref)
        let parsed = StrategyRuleParser.parse(lines: initialDoc.rules)
        _rows = State(initialValue: parsed.rules.map { RuleRow(kind: $0.kind, params: $0.params) })
        _parseErrors = State(initialValue: parsed.errors)
        // 交易指令回显：数量优先（QTY 与 AMOUNT 互斥），未配置时两侧都空
        _trade = State(initialValue: initialDoc.trade)
        _sizeMode = State(initialValue: initialDoc.trade.qty != nil ? .qty
                          : (initialDoc.trade.amount != nil ? .amount : .qty))
        _qtyText = State(initialValue: initialDoc.trade.qty.map(String.init) ?? "")
        _amountText = State(initialValue: initialDoc.trade.amount.map { Self.plainNumber($0) } ?? "")
        _offsetText = State(initialValue: initialDoc.trade.offsetTicks.map(String.init) ?? "")
        _expiryDate = State(initialValue: initialDoc.trade.expiresAt
                            ?? (Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()))
    }

    // MARK: - 文档投影（保存与校验都只面对 FormulaDoc）

    /// 当前编辑内容对应的策略文档；id 沿用 initialDoc.id（空串 = 新建）
    private var doc: FormulaDoc {
        FormulaDoc(id: initialDoc.id,
                   kind: .strategy,
                   name: name.trimmingCharacters(in: .whitespaces),
                   pickBody: mode == .inline ? pickBody : "",
                   pickRef: mode == .reference ? pickRef : nil,
                   rules: rulesText,
                   trade: trade)
    }

    /// 规则行 → RULES 文本（逐行按 specs 顺序拼 KEY=VAL，行间换行）
    private var rulesText: String {
        rows.map { row in
            StrategyRuleParser.line(for: StrategyRuleCall(kind: row.kind, params: row.params, raw: ""))
        }
        .joined(separator: "\n")
    }

    /// 引用模式下选中的选股公式名（预览用）
    private var referencedPickerName: String? {
        let ref = doc.pickRef ?? ""
        guard !ref.isEmpty else { return nil }
        return library.pickerName(id: ref)
    }

    /// PICKREF 指向的选股公式是否还存在
    private var pickerExists: Bool {
        let ref = doc.pickRef ?? ""
        guard !ref.isEmpty else { return false }
        return library.doc(kind: .picker, id: ref) != nil
    }

    /// 内嵌选股公式的语法错误（用行情数据试算得到；无数据 / 非内嵌 / 已删除的引用都不试算）
    private var pickSyntaxError: String? {
        guard mode == .inline, !data.isEmpty else { return nil }
        let body = pickBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        do {
            _ = try TDXFormulaEngine.evaluate(formula: pickBody, data: data)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 校验结论（每次字段变化即时重算）：名称 + 静态校验，静态校验不做任何求值 / 下单
    private var issues: [String] {
        var list: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            list.append("请填写策略名称")
        }
        list.append(contentsOf: StrategyValidator.validate(doc: doc,
                                                           pickerExists: pickerExists,
                                                           pickSyntaxError: pickSyntaxError))
        return list
    }

    // MARK: - 页面

    var body: some View {
        // 校验结论每帧只算一次（内嵌选股公式需要试算，避免同一帧里重复求值）
        let issues = self.issues
        return VStack(spacing: 0) {
            header(canSave: issues.isEmpty)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameField
                    pickSection
                    tradeSection
                    accountsSection
                    rulesSection
                    previewCard
                    validationSection(issues)

                    Button {
                        save()
                    } label: {
                        Text("保存策略公式")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(issues.isEmpty ? Color.blue : Color.gray)
                            .cornerRadius(10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!issues.isEmpty)

                    Color.clear.frame(height: 8)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // 表单贴物理屏幕底边（全 App 统一贴底为 0）；仅忽略 container 区，键盘行为不变
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// 页头：取消 / 标题 / 保存（字号沿用 IndicatorEditSheet 的页头令牌）
    private func header(canSave: Bool) -> some View {
        HStack(spacing: 10) {
            Button("取消") { onClose() }
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())

            Spacer(minLength: 4)

            Text("策略公式")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.primary)

            Spacer(minLength: 4)

            Button("保存") { save() }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(canSave ? Color.blue : Color.gray)
                .cornerRadius(6)
                .frame(minHeight: 44)
                .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 名称

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("名称")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            TextField("例如：趋势回踩策略", text: $name)
                .font(.system(size: 14))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(uiColor: .systemGray6))
                .cornerRadius(6)
        }
    }

    // MARK: - 选股条件（内嵌 / 引用 二选一）

    private var pickSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选股条件")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            // 二选一分段：切换只改显示，pickBody / pickRef 各自的内容都保留
            HStack(spacing: 4) {
                ForEach(PickMode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        Text(m.title)
                            .font(.system(size: 13, weight: mode == m ? .semibold : .regular))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(mode == m ? Color(.systemBackground) : Color.clear)
                            .cornerRadius(8)
                            .shadow(color: mode == m ? Color.black.opacity(0.1) : Color.clear,
                                    radius: 2, y: 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color(uiColor: .systemGray6))
            .cornerRadius(8)

            if mode == .inline {
                inlinePickEditor
            } else {
                referencePickerList
            }
        }
    }

    /// 内嵌模式：公式输入框 + 全选 / 清空 / 测试
    private var inlinePickEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormulaTextView(text: $pickBody, controller: pickInputController)
                .frame(minHeight: 140)
                .padding(8)
                .background(Color(uiColor: .systemGray6))
                .cornerRadius(6)

            HStack(spacing: 12) {
                smallButton("全选") { pickInputController.selectAll() }
                smallButton("清空") {
                    pickBody = ""
                    testMessage = nil
                    testIsError = false
                }
                smallButton("测试选股公式") { runTest() }
                Spacer(minLength: 0)
            }

            // 样例行情未就绪时提示：此时语法校验被旁路，待行情到达后才会试算拦截
            if mode == .inline
                && !pickBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && data.isEmpty {
                Text("样例行情未就绪，语法校验待行情到达后进行")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let testMessage {
                Text(testMessage)
                    .font(.system(size: 12))
                    .foregroundColor(testIsError ? .red : .primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((testIsError ? Color.red : Color.green).opacity(0.1))
                    .cornerRadius(6)
            }
        }
    }

    /// 引用模式：单选列表（左侧勾选态 + 名称 + 公式单行摘要）
    @ViewBuilder
    private var referencePickerList: some View {
        if library.pickers.isEmpty {
            Text("公式库还没有选股公式，请先到「选股指标」段新建")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
        } else {
            VStack(spacing: 0) {
                ForEach(library.pickers) { p in
                    referenceRow(p)
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
    }

    private func referenceRow(_ picker: FormulaDoc) -> some View {
        let selected = (pickRef == picker.id)
        return Button {
            pickRef = picker.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(selected ? .blue : .gray)
                VStack(alignment: .leading, spacing: 3) {
                    Text(picker.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Text(oneLine(picker.pickBody))
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

    // MARK: - 交易指令（方向 / 数量或金额 / 报价方式 / 有效期）

    /// 交易指令区块：所有选择实时写回 trade，未选的方向保持 nil
    private var tradeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("交易指令")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 14) {
                directionControl
                sizeControl
                priceTypeControl
                validityControl
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
    }

    /// 方向：买入（红）/ 卖出（绿）二选一；未选时提示「请选择」
    private var directionControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("方向")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                if trade.direction == nil {
                    Text("请选择")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            tradeSegment([
                TradeChipOption(id: "buy", title: "买入", tint: Color(.systemRed), selected: trade.direction == .buy),
                TradeChipOption(id: "sell", title: "卖出", tint: Color(.systemGreen), selected: trade.direction == .sell)
            ]) { id in
                let picked: SimOrderDirection = (id == "buy") ? .buy : .sell
                // 再点一次已选项 = 取消选择（回到 nil）
                trade.direction = (trade.direction == picked) ? nil : picked
            }
        }
    }

    /// 数量 / 金额：先选口径，再显示对应输入框（切换时清掉另一侧，保证互斥）
    private var sizeControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("数量 / 金额")
                .font(.system(size: 13))
                .foregroundColor(.primary)
            tradeSegment([
                TradeChipOption(id: "qty", title: "按数量", selected: sizeMode == .qty),
                TradeChipOption(id: "amount", title: "按金额", selected: sizeMode == .amount)
            ]) { id in
                if id == "qty" {
                    sizeMode = .qty
                    trade.amount = nil
                    amountText = ""
                } else {
                    sizeMode = .amount
                    trade.qty = nil
                    qtyText = ""
                }
            }
            if sizeMode == .qty {
                qtyInput
            } else {
                amountInput
            }
        }
    }

    /// 按数量：数字键盘 + 单位「股」+ 右侧整手快捷 chips
    private var qtyInput: some View {
        HStack(spacing: 8) {
            TextField("100", text: $qtyText)
                .font(.system(size: 14))
                .keyboardType(.numberPad)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color(uiColor: .systemGray6))
                .cornerRadius(6)
                .frame(maxWidth: 84)
                .onChange(of: qtyText) { text in
                    let digits = text.filter { $0.isNumber }
                    trade.qty = digits.isEmpty ? nil : Int(digits)
                }

            Text("股")
                .font(.system(size: 13))
                .foregroundColor(.gray)

            Spacer(minLength: 4)

            ForEach([100, 500, 1000], id: \.self) { value in
                chip("\(value)", selected: trade.qty == value) {
                    // 快捷填入：点击顺序 = 选择顺序，值恒为 100 的整数倍
                    trade.qty = value
                    qtyText = "\(value)"
                }
            }
        }
    }

    /// 按金额：小数键盘 + 单位「元」+ 折算说明
    private var amountInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("50000", text: $amountText)
                    .font(.system(size: 14))
                    .keyboardType(.decimalPad)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Color(uiColor: .systemGray6))
                    .cornerRadius(6)
                    .frame(maxWidth: 140)
                    .onChange(of: amountText) { text in
                        let value = Double(text)
                        trade.amount = (value ?? 0) > 0 ? value : nil
                    }

                Text("元")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)

                Spacer(minLength: 0)
            }
            Text("生成条件单时按最新价折算并向下取整到 100 股")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
    }

    /// 报价方式：市价 / 限价；限价时多一行偏移档次
    private var priceTypeControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("报价方式")
                .font(.system(size: 13))
                .foregroundColor(.primary)
            tradeSegment([
                TradeChipOption(id: "market", title: "市价", selected: trade.priceType == .market),
                TradeChipOption(id: "limit", title: "限价", selected: trade.priceType == .limit)
            ]) { id in
                if id == "market" {
                    trade.priceType = .market
                    trade.offsetTicks = nil
                    offsetText = ""
                } else {
                    trade.priceType = .limit
                    // 限价默认触发价本身（0 档），避免选完限价却缺偏移被拦
                    if trade.offsetTicks == nil {
                        trade.offsetTicks = 0
                        offsetText = "0"
                    }
                }
            }

            if trade.priceType == .limit {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("偏移档次")
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                        TextField("0", text: $offsetText)
                            .font(.system(size: 14))
                            .keyboardType(.numbersAndPunctuation)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(Color(uiColor: .systemGray6))
                            .cornerRadius(6)
                            .frame(maxWidth: 96)
                            .onChange(of: offsetText) { text in
                                let trimmed = text.trimmingCharacters(in: .whitespaces)
                                trade.offsetTicks = trimmed.isEmpty ? nil : Int(trimmed)
                            }
                        Text("档")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Spacer(minLength: 0)
                    }
                    Text("触达触发价 ± N 档委托")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }
        }
    }

    /// 有效期：当日 / 长期 / 指定日期 三段 chips；指定日期时显示到期日选择
    private var validityControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("有效期")
                .font(.system(size: 13))
                .foregroundColor(.primary)
            HStack(spacing: 8) {
                chip("当日", selected: trade.validity == .day) {
                    trade.validity = .day
                    trade.expiresAt = nil
                }
                chip("长期", selected: trade.validity == .longTerm) {
                    trade.validity = .longTerm
                    trade.expiresAt = nil
                }
                chip("指定日期", selected: trade.validity == .untilDate) {
                    trade.validity = .untilDate
                    trade.expiresAt = expiryDate
                }
                Spacer(minLength: 0)
            }

            if trade.validity == .untilDate {
                DatePicker("到期日", selection: expiryBinding, displayedComponents: .date)
                    .font(.system(size: 14))
            }
        }
    }

    /// 到期日双向绑定：选日期时同时写回 trade.expiresAt，保证可往返
    private var expiryBinding: Binding<Date> {
        Binding(get: { expiryDate }, set: { newValue in
            expiryDate = newValue
            trade.expiresAt = newValue
        })
    }

    // MARK: - 绑定账户（可多选）

    /// 绑定账户区块：列出全部账户，多选（选择顺序 = 点击顺序），已归档不可选
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("绑定账户（可多选）")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            if staleAccountCount > 0 {
                Text("\(staleAccountCount) 个已归档/失效账户已自动跳过")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            if sim.accounts.isEmpty {
                Text("还没有模拟账户，请先到模拟页创建")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
            } else {
                VStack(spacing: 0) {
                    ForEach(sim.accounts) { account in
                        accountRow(account)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
            }

            Text("生成条件单时会为每个账户各生成一套；多账户并行执行")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 单个账户行：色点 + badge + 名称 + 可买资金 + 多选标记
    private func accountRow(_ account: SimAccount) -> some View {
        let selected = trade.accountIDs.contains(account.id)
        let archived = account.isArchived
        return Button {
            toggleAccount(account.id)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hex: account.colorHex) ?? Color(.systemGray))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Text(account.badge)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.system(size: 15))
                        .foregroundColor(archived ? Color(.secondaryLabel) : Color.primary)
                    Text("可买资金 \(SimFormat.amount(account.cash))")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                Spacer(minLength: 8)
                if archived {
                    Text("已归档")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundColor(selected ? .blue : .gray)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(archived)
        .opacity(archived ? 0.6 : 1)
    }

    /// 切换某账户的选中态（保留点击顺序，即执行顺序）
    private func toggleAccount(_ id: UUID) {
        if let idx = trade.accountIDs.firstIndex(of: id) {
            trade.accountIDs.remove(at: idx)
        } else {
            trade.accountIDs.append(id)
        }
    }

    /// 已绑定但已归档 / 已不存在的账户数（生成条件单时会被跳过）
    private var staleAccountCount: Int {
        trade.accountIDs.filter { id in
            guard let account = sim.accounts.first(where: { $0.id == id }) else { return true }
            return account.isArchived
        }.count
    }

    // MARK: - 交易规则（RULES）

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("交易规则（RULES）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                Button {
                    addRow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("添加规则").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.blue)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // 初始 RULES 文本解析报错：就地提示，仍允许继续编辑（改动后按新内容序列化）
            if !parseErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(parseErrors.enumerated()), id: \.offset) { _, e in
                        Text("✗ \(e)")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if rows.isEmpty {
                Text("还没有交易规则，点击右上「添加规则」新增一条")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
            } else {
                VStack(spacing: 0) {
                    ForEach($rows) { $row in
                        ruleRow($row)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
            }
        }
    }

    /// 一条规则行：左侧类型下拉 + 条件单中文名，右侧按 specs 动态渲染的参数，末尾删除
    private func ruleRow(_ row: Binding<RuleRow>) -> some View {
        let kind = row.wrappedValue.kind
        let specs = StrategyRuleCatalog.specs(for: kind)
        let rowID = row.wrappedValue.id
        // 规则行内的指令覆盖（ORD* 保留键）；只读展示，绝不改动 params，保证编辑其它参数时不丢
        let directiveOverride = StrategyTradeParser.override(in: StrategyRuleCall(kind: kind,
                                                                                 params: row.wrappedValue.params,
                                                                                 raw: ""))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    kindMenu(row, kind)
                    // 该规则对应的条件单中文名（帮助理解映射关系）
                    Text(kind.conditionOrderTitle)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    // 该规则自带的指令覆盖（优先于交易指令区块）
                    if !directiveOverride.isEmpty, let summary = directiveOverride.summary {
                        Text("指令：\(summary)")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    deleteRow(rowID)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(specs, id: \.key) { spec in
                paramControl(row: row, spec: spec)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 规则类型下拉（8 种）；切换时只重置本行参数
    private func kindMenu(_ row: Binding<RuleRow>, _ kind: StrategyRuleKind) -> some View {
        Menu {
            ForEach(StrategyRuleKind.allCases) { k in
                Button(k.title) { changeKind(row, to: k) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(kind.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(Color(uiColor: .systemGray6))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
    }

    /// 单个参数输入：按 specs 的 type 渲染下拉 / 数值框（带单位）/ 文本框
    @ViewBuilder
    private func paramControl(row: Binding<RuleRow>, spec: StrategyParamSpec) -> some View {
        HStack(spacing: 8) {
            Text(spec.title)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .frame(width: 68, alignment: .leading)

            switch spec.type {
            case .option:
                optionMenu(row: row, spec: spec)
            case .number, .percent:
                valueField(row: row, spec: spec, keyboard: .decimalPad)
                unitText(spec)
            case .integer:
                valueField(row: row, spec: spec, keyboard: .numberPad)
                unitText(spec)
            case .text:
                valueField(row: row, spec: spec, keyboard: .default)
                unitText(spec)
            }

            Spacer(minLength: 0)
        }
    }

    /// 枚举参数下拉：显示值本身（未设置时显示 specs 的默认值作为占位）
    private func optionMenu(row: Binding<RuleRow>, spec: StrategyParamSpec) -> some View {
        let current = row.wrappedValue.params[spec.key] ?? ""
        let display = current.isEmpty ? spec.placeholder : current
        return Menu {
            ForEach(spec.options, id: \.self) { opt in
                Button(opt) { setParam(row, spec.key, opt) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(display)
                    .font(.system(size: 13))
                    .foregroundColor(current.isEmpty ? .gray : .primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(Color(uiColor: .systemGray6))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
    }

    /// 数值 / 文本参数输入框
    private func valueField(row: Binding<RuleRow>, spec: StrategyParamSpec, keyboard: UIKeyboardType) -> some View {
        TextField(spec.placeholder, text: paramBinding(row, spec.key))
            .font(.system(size: 13))
            .keyboardType(keyboard)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(Color(uiColor: .systemGray6))
            .cornerRadius(6)
            .frame(maxWidth: 140)
    }

    @ViewBuilder
    private func unitText(_ spec: StrategyParamSpec) -> some View {
        if !spec.unit.isEmpty {
            Text(spec.unit)
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
    }

    // MARK: - 预览卡

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StrategyPreview.tradeSummary(doc: doc))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(StrategyPreview.summary(doc: doc, pickerName: referencedPickerName))
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(StrategyPreview.executionNotice)
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    // MARK: - 校验红字（就地展示，不弹 alert）

    @ViewBuilder
    private func validationSection(_ list: [String]) -> some View {
        if !list.isEmpty || saveError != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, e in
                    Text("✗ \(e)")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let saveError {
                    Text("✗ \(saveError)")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 动作

    /// 测试选股公式：内嵌正文在样例行情上试算，结论就地显示
    private func runTest() {
        testMessage = nil
        testIsError = false
        let result = FormulaLibraryStore.shared.testPicker(formula: pickBody, data: data)
        if let err = result.error {
            testMessage = "✗ \(err)"
            testIsError = true
        } else {
            let verdict = result.hit ? "命中：最后一根输出值 > 0" : "未命中：最后一根输出值 ≤ 0"
            testMessage = "✓ 解析成功\n\(result.display)\n\(verdict)"
        }
    }

    /// 保存：写公式库；成功即回调 + 关闭，失败就地红字（本阶段不生成任何条件单）
    private func save() {
        saveError = nil
        guard issues.isEmpty else { return }
        guard let saved = library.save(doc) else {
            saveError = "保存失败，请检查公式内容"
            return
        }
        onSaved(saved)
        onClose()
    }

    private func addRow() {
        // 新行默认第一条规则类型，参数留空由 placeholder 提示
        rows.append(RuleRow(kind: .price, params: [:]))
    }

    /// 切换规则类型：只重置本行参数（必填留空由校验兜底，可选留空即不写该键）
    private func changeKind(_ row: Binding<RuleRow>, to newKind: StrategyRuleKind) {
        guard row.wrappedValue.kind != newKind else { return }
        row.wrappedValue.kind = newKind
        row.wrappedValue.params = [:]
    }

    private func deleteRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }

    /// 某参数键的双向绑定（读写都落在行模型上，最终序列化进 doc.rules）
    private func paramBinding(_ row: Binding<RuleRow>, _ key: String) -> Binding<String> {
        Binding(
            get: { row.wrappedValue.params[key] ?? "" },
            set: { row.wrappedValue.params[key] = $0 }
        )
    }

    private func setParam(_ row: Binding<RuleRow>, _ key: String, _ value: String) {
        row.wrappedValue.params[key] = value
    }

    /// 小按钮（命中区 ≥44×44pt）
    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.blue)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 单行摘要：去掉换行并裁剪空白
    private func oneLine(_ body: String) -> String {
        let s = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "（空公式）" : s
    }

    /// 交易指令里的二/三选一分段（选中态白色药丸 + 选中色文字，命中区 ≥44pt）
    private func tradeSegment(_ options: [TradeChipOption], onTap: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(options) { opt in
                Button {
                    onTap(opt.id)
                } label: {
                    Text(opt.title)
                        .font(.system(size: 13, weight: opt.selected ? .semibold : .regular))
                        .foregroundColor(opt.selected ? (opt.tint ?? Color.primary) : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(opt.selected ? Color(.systemBackground) : Color.clear)
                        .cornerRadius(8)
                        .shadow(color: opt.selected ? Color.black.opacity(0.1) : Color.clear,
                                radius: 2, y: 1)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(uiColor: .systemGray6))
        .cornerRadius(8)
    }

    /// 小 chip（选中蓝底白字，命中区 ≥44pt）
    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(selected ? Color.blue : Color(uiColor: .systemGray6))
                .cornerRadius(8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 纯数值文案：整数不带小数，非整数最多两位且去掉尾随 0（金额输入框回显用）
    private static func plainNumber(_ v: Double) -> String {
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%g", v)
    }
}