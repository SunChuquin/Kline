//
//  TradeTicketView.swift
//  Kline
//
//  共享下单组件：方向 / 报价类型 / 委托价 / 数量 / 仓位快捷 / 费用预览全部参数化，
//  快捷面板（panel）、闪电下单条（bolt）、全屏下单卡（full）三处入口复用同一套内核，
//  提交统一走 SimStore.submit 的校验与写入；失败原因就地展示（红色小字，不弹 alert，
//  避免与面板遮罩冲突）。纯展示原子件（分段控件 / 步进按钮 / 五档报价条 / 费用明细块）
//  见同目录 TradeTicketKit.swift。
//  配色：买入 Color(.systemRed)、卖出 Color(.systemGreen)；背景一律语义色，支持深色模式。
//

import SwiftUI

// MARK: - 形态

/// 下单组件形态
enum TradeTicketStyle {
    case panel   // 快捷面板内嵌紧凑态
    case bolt    // 闪电下单条（大字号数量 + 买入/卖出两个大按钮）
    case full    // 全屏下单卡片
}

// MARK: - 组件

/// 共享下单组件：三处入口（快捷面板、模拟页底部买卖条、全屏下单页）复用同一套内核
struct TradeTicketView: View {
    let style: TradeTicketStyle
    /// 具体账户 id（不能是「全部账户汇总」）
    let accountID: UUID
    /// 标的
    let metaID: Int
    let code: String
    let name: String
    /// 初始方向 / 报价类型 / 数量
    var initialDirection: SimOrderDirection = .buy
    var initialPriceType: SimPriceType = .limit
    var initialQty: Int = 100
    /// 非 nil 时在头部右侧显示「展开」入口（方案 C 用）
    var onExpand: (() -> Void)? = nil
    /// 提交成功回调（返回已生成的委托）
    let onSubmit: (SimOrder) -> Void

    // MARK: 数据源（账户资金 / 持仓 / 最新价实时反映）

    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var rowCache = MarketRowCache.shared

    // MARK: 交互状态

    @State private var direction: SimOrderDirection
    @State private var priceType: SimPriceType
    @State private var qty: Int
    @State private var price: Double = 0
    @State private var priceText: String = ""
    @State private var qtyText: String = ""
    /// 用户是否手动改过委托价（改过之后不再跟随最新价）
    @State private var didEditPrice = false
    /// 组件内展示的拒绝原因（不弹 alert）
    @State private var errorText: String?
    /// 卖出二次确认（bolt / full）
    @State private var showSellConfirm = false
    /// 程序化回填文本时记录的值，用于区分「用户编辑」与「代码回填」
    @State private var programmaticPriceText = ""
    @State private var programmaticQtyText = ""

    // MARK: - 初始化

    init(style: TradeTicketStyle,
         accountID: UUID,
         metaID: Int,
         code: String,
         name: String,
         initialDirection: SimOrderDirection = .buy,
         initialPriceType: SimPriceType = .limit,
         initialQty: Int = 100,
         onExpand: (() -> Void)? = nil,
         onSubmit: @escaping (SimOrder) -> Void) {
        self.style = style
        self.accountID = accountID
        self.metaID = metaID
        self.code = code
        self.name = name
        self.initialDirection = initialDirection
        self.initialPriceType = initialPriceType
        self.initialQty = initialQty
        self.onExpand = onExpand
        self.onSubmit = onSubmit
        _direction = State(initialValue: initialDirection)
        // bolt 形态只做市价，忽略传入的报价类型
        _priceType = State(initialValue: style == .bolt ? .market : initialPriceType)
        _qty = State(initialValue: max(0, initialQty))
    }

    // MARK: - Body

    var body: some View {
        Group {
            switch style {
            case .panel: panelBody
            case .bolt:  boltBody
            case .full:  fullBody
            }
        }
        .onAppear(perform: handleAppear)
        // 最新价变化：仅在用户未手动改过价格时跟随（iOS 15 onChange 为单参数闭包）
        .onChange(of: rowCache.numberFor(metaID, .latestPrice)) { newValue in
            if !didEditPrice, let newValue = newValue { price = newValue }
            refreshPriceText()
        }
        .onChange(of: priceType) { _ in
            refreshPriceText()
        }
        .confirmationDialog("确认卖出 \(name) \(SimFormat.shares(qty)) 股？",
                            isPresented: $showSellConfirm,
                            titleVisibility: .visible) {
            Button("确认卖出", role: .destructive) { performSubmit(.sell) }
            Button("取消", role: .cancel) { }
        }
    }

    // MARK: - 形态：紧凑面板

    private var panelBody: some View {
        VStack(spacing: 0) {
            header(priceSize: 19, horizontalPadding: 16)

            TradeSegmentedRow(options: [
                TradeSegOption(id: "buy", title: "买入", tint: Color(.systemRed),
                               selected: direction.isBuy, accessibilityID: "tradeTicket.dir.buy"),
                TradeSegOption(id: "sell", title: "卖出", tint: Color(.systemGreen),
                               selected: !direction.isBuy, accessibilityID: "tradeTicket.dir.sell"),
                TradeSegOption(id: "type", title: priceType.title, selected: false)
            ], height: 30) { id in
                handleSegmentTap(id)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack(spacing: 0) {
                priceControlRow(label: "委托价", height: 38, unit: "元")
                qtyControlRow(label: "数量", height: 38, unit: "股", showsDivider: false)
            }
            .padding(.horizontal, 16)

            TradePosChips(height: 30) { ratio in applyPosition(ratio) }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)

            metaRow(padding: 16)

            // 提交按钮上方一行小字：合计费用
            Text("预计费用合计 \(SimFormat.amount(totalFee))")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.top, 2)

            submitButton(height: 46, horizontalPadding: 16, topPadding: 8, bottomPadding: 6)
            errorLine(padding: 16)
        }
    }

    // MARK: - 形态：闪电下单条

    private var boltBody: some View {
        VStack(spacing: 0) {
            header(priceSize: 22, horizontalPadding: 18)
            boltQtyRow
            metaRow(padding: 18)
            boltButtons
            errorLine(padding: 18)
            Text("默认市价即时成交 · 限价 / 仓位比例 / 撤单请点「展开」")
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
    }

    private var boltQtyRow: some View {
        HStack(spacing: 10) {
            Text("市价 · 数量")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            TradeStepperButton(symbol: "−", size: 36, fontSize: 20) { stepQty(-rules.lotSize) }
            TextField("0", text: $qtyText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                .onChange(of: qtyText) { newValue in
                    handleQtyTextChange(newValue)
                }
                .accessibilityIdentifier("tradeTicket.qty")
            TradeStepperButton(symbol: "＋", size: 36, fontSize: 20) { stepQty(rules.lotSize) }
            Text("股")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var boltButtons: some View {
        HStack(spacing: 12) {
            Button {
                performSubmit(.buy)
            } label: {
                bigButtonLabel("买入 \(SimFormat.shares(qty)) 股", color: Color(.systemRed))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tradeTicket.submit")

            Button {
                showSellConfirm = true
            } label: {
                bigButtonLabel("卖出 \(SimFormat.shares(qty)) 股", color: Color(.systemGreen))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tradeTicket.dir.sell")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private func bigButtonLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 19, weight: .heavy))
            .foregroundColor(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 10).fill(color))
            .contentShape(Rectangle())
    }

    // MARK: - 形态：全屏下单卡

    private var fullBody: some View {
        VStack(spacing: 0) {
            header(priceSize: 19, horizontalPadding: 18)

            TradeBigDirSegment(isBuy: direction.isBuy) { dir in
                direction = dir
                errorText = nil
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)

            TradeSegmentedRow(options: [
                TradeSegOption(id: "limit", title: "限价委托", selected: priceType == .limit),
                TradeSegOption(id: "market", title: "市价委托", selected: priceType == .market)
            ], height: 30) { id in
                priceType = (id == "limit") ? .limit : .market
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)

            VStack(spacing: 0) {
                priceControlRow(label: "委托价格", labelWidth: 84, height: 46, unit: "元")
                qtyControlRow(label: "委托数量", labelWidth: 84, height: 46,
                              unit: "股（\(rules.lotSize) 整数倍）", showsDivider: false)
            }
            .padding(.horizontal, 18)

            metaRow(padding: 18)

            TradePosChips(height: 30) { ratio in applyPosition(ratio) }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 10)

            TradeQuoteBar(limitUpper: limitRange?.upperBound,
                          limitLower: limitRange?.lowerBound,
                          lastPrice: lastPrice,
                          availQty: availQty,
                          isBuy: direction.isBuy,
                          holdQty: holdQty) { picked in
                priceType = .limit
                didEditPrice = true
                price = picked
                writePriceText(SimFormat.price(picked))
            }
            .padding(.horizontal, 18)

            TradeFeeBlock(amount: amount,
                          commission: commission,
                          stampTax: stampTax,
                          isBuy: direction.isBuy,
                          cashAfter: cashAfterTrade)
                .padding(.horizontal, 18)
                .padding(.top, 12)

            submitButton(height: 50, horizontalPadding: 18, topPadding: 12, bottomPadding: 10)
            errorLine(padding: 18)
        }
    }

    // MARK: - 共用子块

    /// 头部：标的名称 + 代码 + 最新价 + 涨跌幅（右侧可选「展开」入口）
    @ViewBuilder
    private func header(priceSize: CGFloat, horizontalPadding: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color.primary)
                .lineLimit(1)
            Text(code)
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(lastPrice.map { SimFormat.price($0) } ?? "—")
                .font(.system(size: priceSize, weight: .bold))
                .foregroundColor(changeColor)
            Text(changeText)
                .font(.system(size: 11))
                .foregroundColor(changeColor)
            if let expand = onExpand {
                Button(action: expand) {
                    Text("展开")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
    }

    /// 委托价行：− / 输入框 / ＋（步长 = 最小报价档位；市价时整行禁用并显示灰色最新价）
    @ViewBuilder
    private func priceControlRow(label: String, labelWidth: CGFloat = 56, height: CGFloat,
                                 unit: String, showsDivider: Bool = true) -> some View {
        let editable = priceType == .limit
        TradeLineRow(label: label, labelWidth: labelWidth, height: height, showsDivider: showsDivider) {
            HStack(spacing: 6) {
                TradeStepperButton(symbol: "−", enabled: editable) { stepPrice(-rules.priceTick) }
                TextField("0.00", text: $priceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(editable ? Color.primary : Color(.secondaryLabel))
                    .frame(width: 96)
                    .disabled(!editable)
                    .onChange(of: priceText) { newValue in
                        handlePriceTextChange(newValue)
                    }
                    .accessibilityIdentifier("tradeTicket.price")
                TradeStepperButton(symbol: "＋", enabled: editable) { stepPrice(rules.priceTick) }
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
            }
        }
    }

    /// 数量行：− / 输入框 / ＋（步长 = 每手股数，最小 0）
    @ViewBuilder
    private func qtyControlRow(label: String, labelWidth: CGFloat = 56, height: CGFloat,
                               unit: String, showsDivider: Bool = true) -> some View {
        TradeLineRow(label: label, labelWidth: labelWidth, height: height, showsDivider: showsDivider) {
            HStack(spacing: 6) {
                TradeStepperButton(symbol: "−") { stepQty(-rules.lotSize) }
                TextField("0", text: $qtyText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color.primary)
                    .frame(width: 80)
                    .onChange(of: qtyText) { newValue in
                        handleQtyTextChange(newValue)
                    }
                    .accessibilityIdentifier("tradeTicket.qty")
                TradeStepperButton(symbol: "＋") { stepQty(rules.lotSize) }
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
            }
        }
    }

    /// 元信息行：左侧整手 / 可买可卖股数，右侧预计金额（三种形态共用）
    private func metaRow(padding: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(direction.isBuy
                 ? "\(rules.lotSize) 股整数倍 · 可买 \(SimFormat.shares(buyAvail)) 股"
                 : "可卖 \(SimFormat.shares(sellAvail)) 股")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("预计金额 \(SimFormat.amount(amount))")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
        }
        .padding(.horizontal, padding)
        .padding(.vertical, 4)
    }

    /// 拒绝原因（红色小字，展示在提交按钮下方；不用 alert，避免与面板遮罩冲突）
    @ViewBuilder
    private func errorLine(padding: CGFloat) -> some View {
        if let message = errorText {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Color(.systemRed))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, padding)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
    }

    /// 主提交按钮（买入红底白字 / 卖出绿底白字，含实时金额）
    private func submitButton(height: CGFloat, horizontalPadding: CGFloat,
                              topPadding: CGFloat, bottomPadding: CGFloat) -> some View {
        Button(action: handleSubmitTap) {
            Text(submitTitle)
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 10).fill(dirColor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tradeTicket.submit")
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }

    private var submitTitle: String {
        "\(direction.title)下单 · \(SimFormat.amount(amount))"
    }

    // MARK: - 派生数据

    private var rules: SimTradingRules { SimTradingRules.default }
    private var lastPrice: Double? { rowCache.numberFor(metaID, .latestPrice) }
    private var prevClose: Double? { rowCache.numberFor(metaID, .prevClose) }
    private var changeText: String { rowCache.textFor(metaID, .changePct) }
    private var changeColor: Color { rowCache.colorFor(metaID, .changePct) }
    private var limitRange: ClosedRange<Double>? { rules.limitRange(prevClose: prevClose) }

    /// 参与计算与展示的委托价（市价取最新价）
    private var effectivePrice: Double {
        priceType == .market ? (lastPrice ?? 0) : price
    }

    private var account: SimAccount? { store.account(id: accountID) }
    private var position: SimPosition? { store.position(accountID: accountID, metaID: metaID) }
    private var holdQty: Int { position?.qty ?? 0 }
    private var buyAvail: Int { rules.affordableQty(cash: account?.cash ?? 0, price: effectivePrice) }
    private var sellAvail: Int { rules.sellableQty(position: position) }
    private var availQty: Int { direction.isBuy ? buyAvail : sellAvail }
    private var amount: Double { effectivePrice * Double(qty) }
    private var commission: Double { rules.commission(amount: amount) }
    private var stampTax: Double { rules.stampTax(amount: amount, direction: direction) }
    private var totalFee: Double { rules.fee(amount: amount, direction: direction) }
    private var dirColor: Color { direction.isBuy ? Color(.systemRed) : Color(.systemGreen) }

    /// 委托后可用资金预计
    private var cashAfterTrade: Double {
        let cash = account?.cash ?? 0
        return direction.isBuy ? cash - amount - totalFee : cash + amount - totalFee
    }

    // MARK: - 行为

    private func handleAppear() {
        // 触发一次行情预取，避免最新价长期为空导致委托价恒为 0
        if let meta = SimQuoteCenter.meta(metaID: metaID) {
            _ = rowCache.row(for: meta)
        }
        if price == 0, let last = lastPrice { price = last }
        writeQtyText("\(qty)")
        refreshPriceText()
    }

    /// 分段点击：买入 / 卖出 / 报价类型切换
    private func handleSegmentTap(_ id: String) {
        switch id {
        case "buy":
            direction = .buy
            errorText = nil
        case "sell":
            direction = .sell
            errorText = nil
        default:
            priceType = (priceType == .limit) ? .market : .limit
        }
    }

    /// 程序化回填委托价文本（并记录，供 onChange 区分用户编辑）
    private func writePriceText(_ text: String) {
        programmaticPriceText = text
        priceText = text
    }

    /// 程序化回填数量文本
    private func writeQtyText(_ text: String) {
        programmaticQtyText = text
        qtyText = text
    }

    /// 按当前报价类型刷新委托价文本；用户手动改过价格后（限价）不再覆盖
    private func refreshPriceText() {
        if priceType == .market {
            writePriceText(lastPrice.map { SimFormat.price($0) } ?? "0.00")
        } else {
            guard !didEditPrice else { return }
            writePriceText(SimFormat.price(price))
        }
    }

    private func handlePriceTextChange(_ newValue: String) {
        guard newValue != programmaticPriceText else { return }
        didEditPrice = true
        let cleaned = newValue.filter { $0.isNumber || $0 == "." }
        if cleaned != newValue { writePriceText(cleaned) }
        price = Double(cleaned) ?? 0
    }

    private func handleQtyTextChange(_ newValue: String) {
        guard newValue != programmaticQtyText else { return }
        let cleaned = newValue.filter { $0.isNumber }
        if cleaned != newValue { writeQtyText(cleaned) }
        qty = max(0, Int(cleaned) ?? 0)
    }

    private func stepPrice(_ delta: Double) {
        didEditPrice = true
        price = max(0.01, ((price + delta) * 100).rounded() / 100)
        writePriceText(SimFormat.price(price))
    }

    private func stepQty(_ delta: Int) {
        qty = max(0, qty + delta)
        writeQtyText("\(qty)")
    }

    /// 仓位快捷：按当前方向的可买 / 可卖数量换算成整手
    private func applyPosition(_ ratio: Double) {
        let lot = max(rules.lotSize, 1)
        qty = max(0, Int(Double(availQty) * ratio) / lot * lot)
        writeQtyText("\(qty)")
    }

    /// 主按钮点击：full 形态的卖出走二次确认，其余直接提交
    private func handleSubmitTap() {
        if direction == .sell, style == .full {
            showSellConfirm = true
        } else {
            performSubmit(direction)
        }
    }

    /// 组装草稿并提交；成功回调 onSubmit，失败就地展示拒绝原因
    private func performSubmit(_ dir: SimOrderDirection) {
        errorText = nil
        let draft = SimOrderDraft(accountID: accountID,
                                  metaID: metaID,
                                  code: code,
                                  name: name,
                                  direction: dir,
                                  priceType: priceType,
                                  price: priceType == .limit ? price : nil,
                                  qty: qty)
        switch store.submit(draft) {
        case .success(let order):
            onSubmit(order)
        case .failure(let rejection):
            errorText = rejection.message
        }
    }
}
