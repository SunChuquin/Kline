//
//  TradeTicketKit.swift
//  Kline
//
//  共享下单组件（TradeTicketView）的纯展示原子件：seg3 分段控件、方向大分段、
//  步进按钮、仓位快捷行、「左标签 + 右控件」行容器、五档报价条与费用明细块。
//  这些视图不持有业务状态，仅由 TradeTicketView 组装，单独成文件以控制主文件体积。
//  配色约定：买入 Color(.systemRed)、卖出 Color(.systemGreen)，背景一律用语义色。
//

import SwiftUI

// MARK: - 分段控件（seg3 样式）

/// 分段选项（值类型，供 TradeSegmentedRow 渲染）
struct TradeSegOption: Identifiable {
    let id: String
    let title: String
    /// 选中时的文字色（买入红 / 卖出绿）；nil 表示用主色
    let tint: Color?
    let selected: Bool
    /// 无障碍标识（仅方向按钮需要，其余留空）
    let accessibilityID: String?

    init(id: String, title: String, tint: Color? = nil, selected: Bool, accessibilityID: String? = nil) {
        self.id = id
        self.title = title
        self.tint = tint
        self.selected = selected
        self.accessibilityID = accessibilityID
    }
}

/// seg3 样式分段：浅灰底 + 2pt 内边距，选中项白底 + 轻阴影
struct TradeSegmentedRow: View {
    let options: [TradeSegOption]
    var height: CGFloat = 30
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                if let id = option.accessibilityID {
                    optionButton(option).accessibilityIdentifier(id)
                } else {
                    optionButton(option)
                }
            }
        }
        .padding(2)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
    }

    private func optionButton(_ option: TradeSegOption) -> some View {
        Button {
            onSelect(option.id)
        } label: {
            Text(option.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(option.selected ? (option.tint ?? Color.primary) : Color(.secondaryLabel))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: max(height - 4, 22))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(option.selected ? Color(.systemBackground) : Color.clear)
                        .shadow(color: option.selected ? Color.black.opacity(0.12) : Color.clear,
                                radius: 1.5, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 方向大分段（full 形态）

/// 方向大分段：左右两大块，选中块红 / 绿填充 + 白字（高 44pt）
struct TradeBigDirSegment: View {
    let isBuy: Bool
    let onSelect: (SimOrderDirection) -> Void

    var body: some View {
        HStack(spacing: 0) {
            dirButton(.buy)
            dirButton(.sell)
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 0.5))
    }

    private func dirButton(_ dir: SimOrderDirection) -> some View {
        let on = dir.isBuy == isBuy
        return Button {
            onSelect(dir)
        } label: {
            Text(dir.title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(on ? Color.white : Color(.secondaryLabel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(on ? (dir.isBuy ? Color(.systemRed) : Color(.systemGreen))
                               : Color(.secondarySystemBackground))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(dir.isBuy ? "tradeTicket.dir.buy" : "tradeTicket.dir.sell")
    }
}

// MARK: - 步进按钮

/// 步进按钮（− / ＋）：圆角方块，禁用时置灰
struct TradeStepperButton: View {
    let symbol: String
    var size: CGFloat = 30
    var fontSize: CGFloat = 17
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(enabled ? Color.blue : Color(.tertiaryLabel))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.23)
                    .fill(Color(.secondarySystemBackground)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 仓位快捷

/// 仓位快捷行：1/4 仓 · 1/3 仓 · 半仓 · 全仓（按可买 / 可卖数量换算成整手）
struct TradePosChips: View {
    var height: CGFloat = 30
    let onPick: (Double) -> Void

    private let items: [(title: String, ratio: Double)] = [
        ("1/4 仓", 0.25), ("1/3 仓", 1.0 / 3.0), ("半仓", 0.5), ("全仓", 1.0)
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                Button {
                    onPick(items[index].ratio)
                } label: {
                    Text(items[index].title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color.blue)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.secondarySystemBackground)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 「左标签 + 右控件」行容器

/// tk-line 样式行：固定行高 + 底部 0.5pt 分隔线（full 用 46pt，panel 用 38pt）
struct TradeLineRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    let height: CGFloat
    let showsDivider: Bool
    let content: Content

    init(label: String,
         labelWidth: CGFloat = 84,
         height: CGFloat = 46,
         showsDivider: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.height = height
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 8)
            content
        }
        .frame(height: height)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 0.5)
            }
        }
    }
}

// MARK: - 五档报价条（full 形态）

/// 五档报价条：涨停 / 最新价 / 跌停 / 可买(可卖) / 持仓，五等分 + 0.5pt 分隔线 + 圆角 9 外框。
/// 涨停 / 跌停可点（回填委托价）；拿不到昨收时显示「—」且不可点。
struct TradeQuoteBar: View {
    let limitUpper: Double?
    let limitLower: Double?
    let lastPrice: Double?
    let availQty: Int
    let isBuy: Bool
    let holdQty: Int
    let onPickPrice: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            cell(title: "涨停",
                 value: limitUpper.map { SimFormat.price($0) } ?? "—",
                 color: Color(.systemRed),
                 enabled: limitUpper != nil) {
                if let upper = limitUpper { onPickPrice(upper) }
            }
            divider
            cell(title: "最新价",
                 value: lastPrice.map { SimFormat.price($0) } ?? "—",
                 color: Color.primary,
                 enabled: false, action: {})
            divider
            cell(title: "跌停",
                 value: limitLower.map { SimFormat.price($0) } ?? "—",
                 color: Color(.systemGreen),
                 enabled: limitLower != nil) {
                if let lower = limitLower { onPickPrice(lower) }
            }
            divider
            cell(title: isBuy ? "可买" : "可卖",
                 value: "\(SimFormat.shares(availQty)) 股",
                 color: Color.primary,
                 enabled: false, action: {})
            divider
            cell(title: "持仓",
                 value: "\(SimFormat.shares(holdQty)) 股",
                 color: Color.primary,
                 enabled: false, action: {})
        }
        .frame(height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(.separator), lineWidth: 0.5))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 0.5)
    }

    private func cell(title: String, value: String, color: Color, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(.secondaryLabel))
                Text(value)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 费用明细块（full 形态）

/// 费用明细块：预计成交额 / 佣金（万2.5，最低5元）/ 印花税（买入免） + 委托后可用资金预计
struct TradeFeeBlock: View {
    let amount: Double
    let commission: Double
    let stampTax: Double
    let isBuy: Bool
    let cashAfter: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text("预计成交额 ")
                + Text(SimFormat.amount(amount)).fontWeight(.semibold).foregroundColor(Color.primary)
                + Text(" 元 ｜ 佣金（万2.5，最低5元）")
                + Text(SimFormat.amount(commission)).fontWeight(.semibold).foregroundColor(Color.primary)
                + Text(" ｜ 印花税（\(isBuy ? "买入免" : "千一")）")
                + Text(SimFormat.amount(stampTax)).fontWeight(.semibold).foregroundColor(Color.primary))
            (Text("委托后可用资金预计 ")
                + Text(SimFormat.amount(cashAfter)).fontWeight(.semibold).foregroundColor(Color.primary)
                + Text(" 元 · 委托冻结，成交后多退少补"))
        }
        .font(.system(size: 11.5))
        .foregroundColor(Color(.secondaryLabel))
        .lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
    }
}
