//
//  SimCondEditorView.swift
//  Kline
//
//  条件单编辑器：新建 / 编辑 8 种条件单（独立全屏）。
//  结构（严格对齐 spec.md 线框）：导航栏 → 标的头卡 → 方向大分段 → 类型 chips →
//  类型参数卡 → 触发后委托指令卡 → 有效期卡 → 预览摘要 → 提交。
//  约定：复用 TradeTicketKit 的原子件（不重写）；校验失败就地红字、不弹 alert；
//  切换类型只重置类型参数，方向 / 委托指令 / 有效期保持不变；
//  iOS 15 兼容（不用 NavigationStack / Table / Chart / @Observable，onChange 为单参数闭包）；
//  配色一律语义色，仅实心红绿按钮用 Color.white 作文字色。
//

import SwiftUI
import UIKit

// MARK: - 数值字段键（收敛编辑器内全部数字输入，便于统一清洗 / 回填）

private enum CondNumKey: String, Hashable {
    case triggerPrice, basePrice, takeProfit, stopLoss
    case breakout, trailPct, floorPrice
    case changeThreshold
    case gridBase, gridLower, gridUpper, gridStepPct, gridQtyPerLevel
    case batchTotalQty, batchFirstPrice, batchStepPct
    case qty

    var id: String { rawValue }
}

// MARK: - 编辑器

struct SimCondEditorView: View {
    let accountID: UUID
    let metaID: Int
    let code: String
    let name: String
    var initialKind: SimCondKind = .price
    var initialDirection: SimOrderDirection = .sell
    var initialQty: Int = 100
    var initialPrice: Double? = nil
    var editing: SimCondOrder? = nil
    let onFinish: () -> Void

    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var rowCache = MarketRowCache.shared

    // MARK: 草稿状态

    @State private var kind: SimCondKind = .price
    @State private var direction: SimOrderDirection = .sell
    @State private var priceType: SimPriceType = .market
    @State private var offsetTicks: Int = 0
    @State private var qty: Int = 100
    @State private var params = SimCondParams()
    @State private var validity: SimCondValidity = .longTerm
    @State private var expiresAt: Date = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var fireDate: Date = Date().addingTimeInterval(3600)
    @State private var takeProfitOn: Bool = true
    @State private var stopLossOn: Bool = true
    /// 文本型数字的展示值（区分「程序化回填」与「用户编辑」由清洗后回写完成）
    @State private var numText: [CondNumKey: String] = [:]
    @State private var errorText: String?
    @State private var didSetup = false

    // MARK: - 初始化（显式 init：本视图含 private 存储属性，合成 memberwise init 会是 private）

    init(accountID: UUID,
         metaID: Int,
         code: String,
         name: String,
         initialKind: SimCondKind = .price,
         initialDirection: SimOrderDirection = .sell,
         initialQty: Int = 100,
         initialPrice: Double? = nil,
         editing: SimCondOrder? = nil,
         onFinish: @escaping () -> Void) {
        self.accountID = accountID
        self.metaID = metaID
        self.code = code
        self.name = name
        self.initialKind = initialKind
        self.initialDirection = initialDirection
        self.initialQty = initialQty
        self.initialPrice = initialPrice
        self.editing = editing
        self.onFinish = onFinish

        let editingQty = editing?.directive.qty ?? 0
        _kind = State(initialValue: editing?.kind ?? initialKind)
        _direction = State(initialValue: editing?.directive.direction ?? initialDirection)
        _priceType = State(initialValue: editing?.directive.priceType ?? .market)
        _offsetTicks = State(initialValue: editing?.directive.offsetTicks ?? 0)
        _qty = State(initialValue: editingQty > 0 ? editingQty : max(0, initialQty))
        _params = State(initialValue: editing?.params ?? SimCondParams())
        _validity = State(initialValue: editing?.validity ?? .longTerm)
        _expiresAt = State(initialValue: editing?.expiresAt ?? Date().addingTimeInterval(7 * 24 * 3600))
        _fireDate = State(initialValue: editing?.params.fireDate ?? Date().addingTimeInterval(3600))
        _takeProfitOn = State(initialValue: editing.map { $0.params.takeProfitPrice != nil } ?? true)
        _stopLossOn = State(initialValue: editing.map { $0.params.stopLossPrice != nil } ?? true)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            navBar
            ScrollView {
                VStack(spacing: 10) {
                    headerCard
                    directionSection
                    kindChips
                    paramCard
                    directiveCard
                    validityCard
                    previewCard
                }
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
            submitFooter
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear(perform: handleAppear)
    }

    // MARK: 导航栏

    private var navBar: some View {
        HStack(spacing: 8) {
            Button(action: onFinish) {
                Text("取消")
                    .font(.system(size: 15))
                    .foregroundColor(Color.primary)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(editing == nil ? "新建条件单" : "编辑条件单")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.primary)
                .frame(maxWidth: .infinity)

            Button(action: handleSave) {
                Text("保存")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(canSave ? Color.blue : Color(.tertiaryLabel))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: 标的头卡

    private var headerCard: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                Text(code)
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(lastPriceText)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(changeColor)
                Text(rowCache.textFor(metaID, .changePct))
                    .font(.system(size: 11))
                    .foregroundColor(changeColor)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: 方向大分段（网格类型禁用）

    private var directionSection: some View {
        VStack(spacing: 6) {
            TradeBigDirSegment(isBuy: direction.isBuy) { dir in
                direction = dir
                errorText = nil
            }
            .disabled(kind == .grid)
            .opacity(kind == .grid ? 0.4 : 1)

            if kind == .grid {
                Text("网格交易按档位自动双向：下跌买入、上涨卖出")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: 类型 chips（横向可滑）

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SimCondKind.allCases, id: \.self) { item in
                    Button {
                        selectKind(item)
                    } label: {
                        kindChip(item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func kindChip(_ item: SimCondKind) -> some View {
        let on = item == kind
        return Text(item.title)
            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
            .foregroundColor(on ? Color.blue : Color(.secondaryLabel))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(on ? Color.blue.opacity(0.08) : Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(on ? Color.blue : Color(.separator), lineWidth: on ? 1 : 0.5))
            .frame(height: 44)
            .contentShape(Rectangle())
    }

    // MARK: 类型参数卡（按 kind 切换）

    @ViewBuilder
    private var paramCard: some View {
        card {
            switch kind {
            case .price:     priceRows
            case .stopLoss:  stopLossRows
            case .trailing:  trailingRows
            case .time:      timeRows
            case .changePct: changePctRows
            case .maCross:   maCrossRows
            case .grid:      gridRows
            case .batch:     batchRows
            }
        }
    }

    @ViewBuilder
    private var priceRows: some View {
        segmentedRow("触发方向", options: [
            TradeSegOption(id: "up", title: "现价 ≥", selected: params.compareUp ?? true),
            TradeSegOption(id: "down", title: "现价 ≤", selected: !(params.compareUp ?? true))
        ]) { id in
            params.compareUp = (id == "up")
        }
        numRow("触发价", key: .triggerPrice, unitText: "元",
               stepDelta: rules.priceTick, showsDivider: false)
    }

    @ViewBuilder
    private var stopLossRows: some View {
        numRow("基准价", key: .basePrice, unitText: "元",
               trailingText: direction == .sell ? "· 成本价" : nil, showsDivider: true)
        segmentedRow("涨跌基准", options: baseModeOptions) { id in
            params.baseMode = SimCondBaseMode(rawValue: id) ?? .price
        }
        toggleRow("止盈", key: .takeProfit, isOn: takeProfitOn, showsDivider: true) {
            takeProfitOn.toggle()
            errorText = nil
        }
        toggleRow("止损", key: .stopLoss, isOn: stopLossOn, showsDivider: true) {
            stopLossOn.toggle()
            errorText = nil
        }
        hintRow("两条同时设置时以先触发为准，另一条自动失效")
    }

    @ViewBuilder
    private var trailingRows: some View {
        numRow("突破价", key: .breakout, unitText: "元",
               stepDelta: rules.priceTick, showsDivider: true)
        numRow(direction == .sell ? "回落幅度" : "反弹幅度", key: .trailPct,
               unitText: "%", showsDivider: true)
        TradeLineRow(label: "保底价触发", labelWidth: 84, height: 46, showsDivider: true) {
            toggleButton(isOn: params.floorEnabled) {
                params.floorEnabled.toggle()
                errorText = nil
            }
        }
        numRow("保底价", key: .floorPrice, unitText: "元",
               enabled: params.floorEnabled, showsDivider: false)
    }

    @ViewBuilder
    private var timeRows: some View {
        TradeLineRow(label: "触发时间", labelWidth: 84, height: 46, showsDivider: true) {
            DatePicker("", selection: $fireDate, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        hintRow("仅在交易日时段内提交，非交易时段会落为待报")
    }

    @ViewBuilder
    private var changePctRows: some View {
        numRow("触发幅度", key: .changeThreshold, unitText: "%", showsDivider: true)
        segmentedRow("方向", options: [
            TradeSegOption(id: "rise", title: "日涨幅 ≥", selected: changeIsRise),
            TradeSegOption(id: "fall", title: "日跌幅 ≤", selected: !changeIsRise)
        ], showsDivider: false) { id in
            setChangeDirection(rise: id == "rise")
        }
    }

    @ViewBuilder
    private var maCrossRows: some View {
        segmentedRow("均线周期", options: [
            TradeSegOption(id: "5", title: "MA5", selected: params.maPeriod == 5),
            TradeSegOption(id: "10", title: "MA10", selected: params.maPeriod == 10),
            TradeSegOption(id: "20", title: "MA20", selected: params.maPeriod == 20),
            TradeSegOption(id: "60", title: "MA60", selected: params.maPeriod == 60)
        ]) { id in
            params.maPeriod = Int(id)
        }
        segmentedRow("穿越方向", options: [
            TradeSegOption(id: "up", title: "上穿", selected: params.maAbove ?? true),
            TradeSegOption(id: "down", title: "下破", selected: !(params.maAbove ?? true))
        ], width: 150, trailingText: maValueText, showsDivider: false) { id in
            params.maAbove = (id == "up")
        }
    }

    @ViewBuilder
    private var gridRows: some View {
        numRow("基准价", key: .gridBase, unitText: "元",
               stepDelta: rules.priceTick, showsDivider: true)
        TradeLineRow(label: "价格区间", labelWidth: 84, height: 46, showsDivider: true) {
            HStack(spacing: 6) {
                field(.gridLower)
                Text("~")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                field(.gridUpper)
                Text("元")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
            }
        }
        numRow("网格间距", key: .gridStepPct, unitText: "%", showsDivider: true)
        numRow("每格数量", key: .gridQtyPerLevel, unitText: "股",
               stepDelta: Double(rules.lotSize), showsDivider: true)
        segmentedRow("倍数委托", options: [
            TradeSegOption(id: "1", title: "1×", selected: gridMultiplier == 1),
            TradeSegOption(id: "2", title: "2×", selected: gridMultiplier == 2),
            TradeSegOption(id: "3", title: "3×", selected: gridMultiplier == 3),
            TradeSegOption(id: "5", title: "5×", selected: gridMultiplier == 5)
        ], showsDivider: true) { id in
            params.gridMultiplier = Double(id)
        }
        hintRow("区间内约 \(SimCondRule.gridLevelCount(order: draftOrder())) 档")
    }

    @ViewBuilder
    private var batchRows: some View {
        numRow("总数量", key: .batchTotalQty, unitText: "股",
               stepDelta: Double(rules.lotSize), showsDivider: true)
        segmentedRow("分批笔数", options: [
            TradeSegOption(id: "2", title: "2 笔", selected: params.batchCount == 2),
            TradeSegOption(id: "3", title: "3 笔", selected: params.batchCount == 3),
            TradeSegOption(id: "4", title: "4 笔", selected: params.batchCount == 4),
            TradeSegOption(id: "5", title: "5 笔", selected: params.batchCount == 5)
        ], showsDivider: true) { id in
            params.batchCount = Int(id)
        }
        numRow("首批价格", key: .batchFirstPrice, unitText: "元",
               stepDelta: rules.priceTick, showsDivider: true)
        numRow("每批价差", key: .batchStepPct, unitText: "%", showsDivider: true)
        hintRow(batchPreviewText)
    }

    // MARK: 触发后委托指令卡

    @ViewBuilder
    private var directiveCard: some View {
        card {
            TradeLineRow(label: "触发后报价", labelWidth: 84, height: 46, showsDivider: true) {
                TradeSegmentedRow(options: [
                    TradeSegOption(id: "market", title: "市价", selected: priceType == .market),
                    TradeSegOption(id: "limit", title: "触发价限价", selected: priceType == .limit)
                ], height: 30) { id in
                    priceType = (id == "limit") ? .limit : .market
                    if priceType == .market { offsetTicks = 0 }
                    errorText = nil
                }
                .frame(width: 240)
            }

            if showOffsetRow {
                segmentedRow("价格偏移", options: offsetOptions, showsDivider: true) { id in
                    offsetTicks = Int(id) ?? 0
                }
            }

            if kind == .grid {
                hintRow("网格按「每格数量」下单")
            } else {
                numRow("数量", key: .qty, unitText: "股",
                       stepDelta: Double(rules.lotSize), showsDivider: true)
                TradeLineRow(label: "仓位快捷", labelWidth: 84, height: 46, showsDivider: false) {
                    TradePosChips(height: 30) { ratio in
                        applyPosition(ratio)
                    }
                    .frame(width: 240)
                }
            }
        }
    }

    // MARK: 有效期卡

    @ViewBuilder
    private var validityCard: some View {
        card {
            segmentedRow("有效期", options: [
                TradeSegOption(id: "day", title: "当日", selected: validity == .day),
                TradeSegOption(id: "untilDate", title: "指定日期", selected: validity == .untilDate),
                TradeSegOption(id: "longTerm", title: "长期", selected: validity == .longTerm)
            ], showsDivider: validity == .untilDate) { id in
                validity = SimCondValidity(rawValue: id) ?? .longTerm
            }

            if validity == .untilDate {
                TradeLineRow(label: "到期日期", labelWidth: 84, height: 46, showsDivider: false) {
                    DatePicker("", selection: $expiresAt, displayedComponents: [.date])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                }
            }
        }
    }

    // MARK: 预览摘要卡

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("预览")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
            Text(SimCondRule.previewSentence(draftOrder()))
                .font(.system(size: 12))
                .foregroundColor(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 16)
    }

    // MARK: 提交

    private var submitFooter: some View {
        VStack(spacing: 0) {
            Button(action: handleSave) {
                Text(editing == nil ? "创建条件单" : "保存修改")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 10).fill(dirColor))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("condEditor.submit")

            if let message = errorText {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(Color(.systemRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: - 通用行容器 / 输入控件

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
            .padding(.horizontal, 16)
    }

    private func hintRow(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(Color(.tertiaryLabel))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private func segmentedRow(_ label: String, options: [TradeSegOption], width: CGFloat = 240,
                              trailingText: String? = nil, showsDivider: Bool = true,
                              onSelect: @escaping (String) -> Void) -> some View {
        TradeLineRow(label: label, labelWidth: 84, height: 46, showsDivider: showsDivider) {
            HStack(spacing: 6) {
                TradeSegmentedRow(options: options, height: 30, onSelect: onSelect)
                    .frame(width: width)
                if let tail = trailingText {
                    Text(tail)
                        .font(.system(size: 11))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }
            }
        }
    }

    private func numRow(_ label: String, key: CondNumKey, unitText: String? = nil,
                        trailingText: String? = nil, enabled: Bool = true,
                        stepDelta: Double? = nil, showsDivider: Bool = true,
                        color: Color = Color.primary) -> some View {
        TradeLineRow(label: label, labelWidth: 84, height: 46, showsDivider: showsDivider) {
            HStack(spacing: 6) {
                if let delta = stepDelta {
                    TradeStepperButton(symbol: "−", enabled: enabled) { stepNum(key, -delta) }
                }
                field(key, enabled: enabled, color: color)
                if let delta = stepDelta {
                    TradeStepperButton(symbol: "＋", enabled: enabled) { stepNum(key, delta) }
                }
                if let unit = unitText {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundColor(Color(.secondaryLabel))
                }
                if let tail = trailingText {
                    Text(tail)
                        .font(.system(size: 11))
                        .foregroundColor(Color(.secondaryLabel))
                }
            }
        }
    }

    private func toggleRow(_ label: String, key: CondNumKey, isOn: Bool,
                           unitText: String? = "元", showsDivider: Bool = true,
                           onToggle: @escaping () -> Void) -> some View {
        TradeLineRow(label: label, labelWidth: 84, height: 46, showsDivider: showsDivider) {
            HStack(spacing: 6) {
                field(key, enabled: isOn)
                if let unit = unitText {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundColor(Color(.secondaryLabel))
                }
                toggleButton(isOn: isOn, action: onToggle)
            }
        }
    }

    private func toggleButton(isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(isOn ? "开" : "关")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isOn ? Color.blue : Color(.tertiaryLabel))
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field(_ key: CondNumKey, enabled: Bool = true,
                       color: Color = Color.primary) -> some View {
        TextField("0", text: numBinding(key))
            .keyboardType(keyboardFor(key))
            .multilineTextAlignment(.trailing)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(enabled ? color : Color(.secondaryLabel))
            .frame(width: 96)
            .disabled(!enabled)
            .accessibilityIdentifier("condEditor.\(key.id)")
    }

    private func keyboardFor(_ key: CondNumKey) -> UIKeyboardType {
        switch key {
        case .gridQtyPerLevel, .batchTotalQty, .qty:
            return .numberPad
        case .changeThreshold:
            return .numbersAndPunctuation
        default:
            return .decimalPad
        }
    }

    // MARK: - 文本 <-> params 双向

    private func numBinding(_ key: CondNumKey) -> Binding<String> {
        Binding(get: {
            numText[key] ?? ""
        }, set: { raw in
            let cleaned = sanitize(raw, key: key)
            numText[key] = cleaned
            applyNum(key, cleaned)
        })
    }

    private func sanitize(_ raw: String, key: CondNumKey) -> String {
        switch key {
        case .gridQtyPerLevel, .batchTotalQty, .qty:
            return raw.filter { $0.isNumber }
        case .changeThreshold:
            let filtered = raw.filter { $0.isNumber || $0 == "." || $0 == "-" }
            let negative = filtered.hasPrefix("-")
            let body = filtered.replacingOccurrences(of: "-", with: "")
            return negative ? "-" + body : body
        default:
            return raw.filter { $0.isNumber || $0 == "." }
        }
    }

    private func applyNum(_ key: CondNumKey, _ str: String) {
        switch key {
        case .triggerPrice:     params.triggerPrice = Double(str)
        case .basePrice:        params.basePrice = Double(str)
        case .takeProfit:       params.takeProfitPrice = Double(str)
        case .stopLoss:         params.stopLossPrice = Double(str)
        case .breakout:         params.breakoutPrice = Double(str)
        case .trailPct:         params.trailPct = Double(str)
        case .floorPrice:       params.floorPrice = Double(str)
        case .changeThreshold:  params.changeThreshold = Double(str)
        case .gridBase:         params.gridBase = Double(str)
        case .gridLower:        params.gridLower = Double(str)
        case .gridUpper:        params.gridUpper = Double(str)
        case .gridStepPct:      params.gridStepPct = Double(str)
        case .gridQtyPerLevel:  params.gridQtyPerLevel = Int(str)
        case .batchTotalQty:    params.batchTotalQty = Int(str)
        case .batchFirstPrice:  params.batchFirstPrice = Double(str)
        case .batchStepPct:     params.batchStepPct = Double(str)
        case .qty:              qty = Int(str) ?? 0
        }
    }

    private func text(for key: CondNumKey, value: Double) -> String {
        switch key {
        case .gridQtyPerLevel, .batchTotalQty, .qty:
            return "\(Int(value))"
        case .trailPct, .gridStepPct, .batchStepPct, .changeThreshold:
            return String(format: "%g", value)
        default:
            return String(format: "%.2f", value)
        }
    }

    /// 程序化写入某字段（同时回填文本与 params），用于初始化 / 步进 / 方向规范化
    private func setNum(_ key: CondNumKey, _ value: Double?) {
        let str = value.map { text(for: key, value: $0) } ?? ""
        numText[key] = str
        applyNum(key, str)
    }

    /// 用当前 params 全量回填文本
    private func syncAllTexts() {
        var map: [CondNumKey: String] = [:]
        put(&map, .triggerPrice, params.triggerPrice)
        put(&map, .basePrice, params.basePrice)
        put(&map, .takeProfit, params.takeProfitPrice)
        put(&map, .stopLoss, params.stopLossPrice)
        put(&map, .breakout, params.breakoutPrice)
        put(&map, .trailPct, params.trailPct)
        put(&map, .floorPrice, params.floorPrice)
        put(&map, .changeThreshold, params.changeThreshold)
        put(&map, .gridBase, params.gridBase)
        put(&map, .gridLower, params.gridLower)
        put(&map, .gridUpper, params.gridUpper)
        put(&map, .gridStepPct, params.gridStepPct)
        put(&map, .gridQtyPerLevel, params.gridQtyPerLevel.map { Double($0) })
        put(&map, .batchTotalQty, params.batchTotalQty.map { Double($0) })
        put(&map, .batchFirstPrice, params.batchFirstPrice)
        put(&map, .batchStepPct, params.batchStepPct)
        put(&map, .qty, Double(qty))
        numText = map
    }

    private func put(_ map: inout [CondNumKey: String], _ key: CondNumKey, _ value: Double?) {
        map[key] = value.map { text(for: key, value: $0) } ?? ""
    }

    private func stepNum(_ key: CondNumKey, _ delta: Double) {
        switch key {
        case .gridQtyPerLevel, .batchTotalQty, .qty:
            let current = Int(numText[key] ?? "") ?? 0
            setNum(key, Double(max(0, current + Int(delta))))
        default:
            let current = Double(numText[key] ?? "") ?? 0
            let next = max(0, ((current + delta) * 100).rounded() / 100)
            setNum(key, next)
        }
    }

    // MARK: - 派生数据

    private var rules: SimTradingRules { SimTradingRules.default }
    private var account: SimAccount? { store.account(id: accountID) }
    private var position: SimPosition? { store.position(accountID: accountID, metaID: metaID) }
    private var lastPrice: Double? { rowCache.numberFor(metaID, .latestPrice) }
    private var lastPriceText: String { lastPrice.map { SimFormat.price($0) } ?? "—" }
    private var changeColor: Color { rowCache.colorFor(metaID, .changePct) }
    private var dirColor: Color { direction.isBuy ? Color(.systemRed) : Color(.systemGreen) }
    private var isGrid: Bool { kind == .grid }
    private var showOffsetRow: Bool { priceType == .limit && !isGrid }
    private var gridMultiplier: Double { params.gridMultiplier ?? 1 }
    private var changeIsRise: Bool { (params.changeThreshold ?? 0) >= 0 }

    /// 委托指令参考价（可买数量换算用）
    private var referencePrice: Double {
        lastPrice ?? params.triggerPrice ?? params.breakoutPrice ?? 0
    }

    private var availQty: Int {
        if direction.isBuy {
            return rules.affordableQty(cash: account?.cash ?? 0, price: referencePrice)
        }
        return rules.sellableQty(position: position)
    }

    private var baseModeOptions: [TradeSegOption] {
        [SimCondBaseMode.price, .percent, .diff].map { mode in
            TradeSegOption(id: mode.rawValue, title: mode.title, selected: params.baseMode == mode)
        }
    }

    private var offsetOptions: [TradeSegOption] {
        let items: [(String, String)] = [
            ("-2", "−2 档"), ("-1", "−1 档"), ("0", "触发价"), ("1", "+1 档"), ("2", "+2 档")
        ]
        return items.map { pair in
            TradeSegOption(id: pair.0, title: pair.1, selected: offsetTicks == (Int(pair.0) ?? 0))
        }
    }

    private var maValueText: String {
        guard let period = params.maPeriod else { return "—" }
        let maFieldValue = maField(period)
        guard let value = rowCache.numberFor(metaID, maFieldValue) else { return "—" }
        return "MA\(period) \(SimFormat.price(value))"
    }

    private func maField(_ period: Int) -> MarketField {
        switch period {
        case 5:  return .ma5
        case 10: return .ma10
        case 20: return .ma20
        case 60: return .ma60
        default: return .ma20
        }
    }

    private var batchPreviewText: String {
        let count = params.batchCount ?? 0
        let total = params.batchTotalQty ?? 0
        guard count >= 2, total > 0,
              let first = params.batchFirstPrice,
              let stepPct = params.batchStepPct, stepPct > 0 else {
            return "填齐参数后显示每批数量与末批目标价"
        }
        let lot = max(rules.lotSize, 1)
        let per = total / count / lot * lot
        let offset = stepPct / 100 * Double(count - 1)
        let last = direction.isBuy ? first * (1 - offset) : first * (1 + offset)
        return "每批约 \(SimFormat.shares(per)) 股 · 末批目标 \(SimFormat.price(last)) 元"
    }

    // MARK: - 草稿组装

    private func normalizedParams() -> SimCondParams {
        var p = params
        switch kind {
        case .price:
            if p.compareUp == nil { p.compareUp = true }
        case .stopLoss:
            if !takeProfitOn { p.takeProfitPrice = nil }
            if !stopLossOn { p.stopLossPrice = nil }
        case .trailing:
            if !p.floorEnabled { p.floorPrice = nil }
        case .time:
            p.fireDate = fireDate
        case .changePct:
            break
        case .maCross:
            if p.maPeriod == nil { p.maPeriod = 20 }
            if p.maAbove == nil { p.maAbove = true }
        case .grid:
            if p.gridMultiplier == nil { p.gridMultiplier = 1 }
        case .batch:
            if p.batchCount == nil { p.batchCount = 3 }
        }
        return p
    }

    private func draftOrder() -> SimCondOrder {
        let now = Date()
        let p = normalizedParams()
        let directiveQty = isGrid ? (p.gridQtyPerLevel ?? 0) : qty
        let directive = SimCondDirective(direction: direction,
                                         priceType: priceType,
                                         offsetTicks: priceType == .limit ? offsetTicks : 0,
                                         qty: directiveQty)
        return SimCondOrder(id: editing?.id ?? UUID(),
                            accountID: accountID,
                            metaID: metaID,
                            code: code,
                            name: name,
                            kind: kind,
                            params: p,
                            directive: directive,
                            validity: validity,
                            expiresAt: validity == .untilDate ? expiresAt : nil,
                            createdAt: editing?.createdAt ?? now,
                            updatedAt: now,
                            status: editing?.status ?? .monitoring,
                            runtime: editing?.runtime ?? SimCondRuntime(),
                            triggeredCount: editing?.triggeredCount ?? 0,
                            triggeredAt: editing?.triggeredAt,
                            originOrderID: editing?.originOrderID)
    }

    private func validateDraft(_ draft: SimCondOrder) -> SimCondRejection? {
        guard let account = store.account(id: accountID) else { return .accountUnavailable }
        let position = store.position(accountID: accountID, metaID: metaID)
        let snapshot = SimCondSnapshotCenter.snapshot(for: draft)
        return SimCondRule.validateCreate(order: draft, account: account,
                                          position: position, snapshot: snapshot)
    }

    private var canSave: Bool { validateDraft(draftOrder()) == nil }

    // MARK: - 行为

    private func handleAppear() {
        // 触发一次行情预取，避免最新价长期为空
        if let meta = SimQuoteCenter.meta(metaID: metaID) {
            _ = rowCache.row(for: meta)
        }
        guard !didSetup else { return }
        didSetup = true

        if let existing = editing {
            kind = existing.kind
            direction = existing.directive.direction
            priceType = existing.directive.priceType
            offsetTicks = existing.directive.offsetTicks
            qty = existing.directive.qty > 0 ? existing.directive.qty : initialQty
            validity = existing.validity
            expiresAt = existing.expiresAt ?? Date().addingTimeInterval(7 * 24 * 3600)
            params = existing.params
            fireDate = existing.params.fireDate ?? Date().addingTimeInterval(3600)
            takeProfitOn = existing.params.takeProfitPrice != nil
            stopLossOn = existing.params.stopLossPrice != nil
        } else {
            kind = initialKind
            direction = initialDirection
            qty = max(0, initialQty)
            params = SimCondParams()
            applyKindDefaults()
            takeProfitOn = true
            stopLossOn = true
            fireDate = Date().addingTimeInterval(3600)
        }
        syncAllTexts()
    }

    /// 仅按当前类型填入合理初值与带入价（初始 priceType / offset / validity 已由状态默认值决定）
    private func applyKindDefaults() {
        switch kind {
        case .price:
            params.compareUp = true
            if let price = initialPrice { params.triggerPrice = price }
        case .stopLoss:
            params.baseMode = .price
            params.basePrice = position?.costPrice ?? initialPrice
        case .trailing:
            params.breakoutPrice = initialPrice
            params.floorEnabled = false
        case .time:
            params.fireDate = fireDate
        case .changePct:
            break
        case .maCross:
            params.maPeriod = 20
            params.maAbove = true
        case .grid:
            params.gridBase = initialPrice
            params.gridMultiplier = 1
            params.gridQtyPerLevel = qty > 0 ? qty : nil
        case .batch:
            params.batchCount = 3
            params.batchTotalQty = qty > 0 ? qty : nil
            params.batchFirstPrice = initialPrice
        }
    }

    private func selectKind(_ newKind: SimCondKind) {
        guard newKind != kind else { return }
        kind = newKind
        errorText = nil
        params = SimCondParams()
        takeProfitOn = true
        stopLossOn = true
        applyKindDefaults()
        syncAllTexts()
    }

    private func setChangeDirection(rise: Bool) {
        let magnitude = abs(params.changeThreshold ?? 0)
        setNum(.changeThreshold, rise ? magnitude : -magnitude)
    }

    private func applyPosition(_ ratio: Double) {
        let lot = max(rules.lotSize, 1)
        qty = max(0, Int(Double(availQty) * ratio) / lot * lot)
        setNum(.qty, Double(qty))
    }

    private func handleSave() {
        errorText = nil
        let draft = draftOrder()
        if let rejection = validateDraft(draft) {
            errorText = rejection.message
            return
        }
        store.upsertCondOrder(draft)
        onFinish()
    }
}