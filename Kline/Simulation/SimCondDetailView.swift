//
//  SimCondDetailView.swift
//  Kline
//
//  条件单详情（独立全屏）：状态 / 条件定义 / 委托指令 / 有效期与进度 / 触发记录 / 关联委托。
//  约定：详情自己从 SimStore 取最新数据（列表刷新后同步）；行情无关；
//  配色一律语义色，仅实心按钮用 Color.white 作文字色；iOS 15 兼容。
//

import SwiftUI

struct SimCondDetailView: View {
    let order: SimCondOrder
    let onClose: () -> Void

    @ObservedObject private var store = SimStore.shared

    @State private var showRelated = false

    // 显式 init：本视图含 private 存储属性，合成 memberwise init 会是 private
    init(order: SimCondOrder, onClose: @escaping () -> Void) {
        self.order = order
        self.onClose = onClose
    }

    /// 始终取 store 里的最新值，保证列表刷新后详情同步
    private var current: SimCondOrder { store.condOrder(id: order.id) ?? order }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            navBar
            ScrollView {
                VStack(spacing: 10) {
                    statusCard
                    sectionCard("条件定义") {
                        rows(conditionItems(current))
                    }
                    sectionCard("委托指令") {
                        rows(directiveItems(current))
                    }
                    sectionCard("有效期与进度") {
                        rows(validityItems(current))
                        if current.isRepeatable {
                            SimCondProgressBar(done: progressDone(current),
                                               total: progressTotal(current),
                                               triggered: current.triggeredCount)
                                .padding(.vertical, 10)
                        }
                    }
                    sectionCard("触发记录") {
                        triggerRecords
                    }
                    if let related = relatedOrder {
                        relatedCard(related)
                    }
                    if current.status == .monitoring {
                        cancelButton
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: 导航栏

    private var navBar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Text("关闭")
                    .font(.system(size: 15))
                    .foregroundColor(Color.primary)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("条件单详情")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.primary)
                .frame(maxWidth: .infinity)

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(current.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                Text(current.code)
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
            }
            SimCondStatusTag(status: current.status)
            Spacer(minLength: 8)
            Text(SimCondRule.conditionSummary(current))
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 16)
    }

    // MARK: 撤销

    private var cancelButton: some View {
        Button {
            store.cancelCondOrder(id: current.id)
        } label: {
            Text("撤销该条件单")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(.secondaryLabel))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: 关联委托

    private var relatedOrder: SimOrder? {
        guard let id = current.originOrderID else { return nil }
        return store.order(id: id)
    }

    private func relatedCard(_ related: SimOrder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SimDirectionTag(direction: related.direction)
                Text("\(related.name) \(related.code)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                SimInlineButton(title: showRelated ? "收起" : "查看关联委托") {
                    showRelated.toggle()
                }
            }
            Text(relatedLine(related))
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
            if showRelated {
                Text(relatedDetail(related))
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 16)
    }

    private func relatedLine(_ related: SimOrder) -> String {
        let priceText = related.priceType == .limit
            ? (related.price.map { SimFormat.price($0) } ?? "限价")
            : "市价"
        return "\(priceText) · \(SimFormat.shares(related.qty)) 股 · \(related.status.title)"
    }

    private func relatedDetail(_ related: SimOrder) -> String {
        "#\(related.id.uuidString.prefix(8)) · 创建 \(SimFormat.dateTime(related.createdAt))"
            + " · 已成 \(SimFormat.shares(related.filledQty)) 股"
    }

    // MARK: 触发记录

    private var triggerLogs: [ActionLog] {
        let all = store.actionLogs(accountID: order.accountID)
            .filter { $0.module == .condition && $0.content.contains(order.name) }
        return Array(all.prefix(20))
    }

    @ViewBuilder
    private var triggerRecords: some View {
        if triggerLogs.isEmpty {
            Text("暂无触发记录")
                .font(.system(size: 12))
                .foregroundColor(Color(.tertiaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
        } else {
            ForEach(triggerLogs.indices, id: \.self) { index in
                logRow(triggerLogs[index], showsDivider: index < triggerLogs.count - 1)
            }
        }
    }

    private func logRow(_ log: ActionLog, showsDivider: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(SimFormat.time(log.occurredAt))
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .frame(width: 66, alignment: .leading)
            Text(log.content)
                .font(.system(size: 12))
                .foregroundColor(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(log.result)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(resultColor(log.result))
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
        }
    }

    private func resultColor(_ text: String) -> Color {
        let failure = ["失败", "拒绝", "被拒"]
        let success = ["成功", "已成交", "全部成交", "已触发", "已完成"]
        let pending = ["部成", "已报", "待报", "监控中"]
        if failure.contains(where: { text.contains($0) }) { return Color(.systemRed) }
        if success.contains(where: { text.contains($0) }) { return Color(.systemGreen) }
        if pending.contains(where: { text.contains($0) }) { return Color(.orange) }
        return Color(.secondaryLabel)
    }

    // MARK: - 内容构造

    private func conditionItems(_ o: SimCondOrder) -> [(String, String, Color)] {
        let p = o.params
        var items: [(String, String, Color)] = [
            ("类型", o.kind.title, Color.primary),
            ("条件", SimCondRule.conditionSummary(o), Color.primary)
        ]
        switch o.kind {
        case .price:
            items.append(("触发方向", (p.compareUp ?? true) ? "现价 ≥" : "现价 ≤", Color(.secondaryLabel)))
            items.append(("触发价", priceText(p.triggerPrice), Color.primary))
        case .stopLoss:
            items.append(("基准价", priceText(p.basePrice), Color.primary))
            items.append(("涨跌基准", p.baseMode.title, Color(.secondaryLabel)))
            items.append(("止盈", priceText(p.takeProfitPrice), Color.primary))
            items.append(("止损", priceText(p.stopLossPrice), Color.primary))
        case .trailing:
            items.append(("突破价", priceText(p.breakoutPrice), Color.primary))
            items.append(("回落幅度", pctText(p.trailPct), Color.primary))
            items.append(("保底价触发", p.floorEnabled ? "开" : "关", Color(.secondaryLabel)))
            items.append(("保底价", priceText(p.floorPrice), Color.primary))
        case .time:
            items.append(("触发时间", p.fireDate.map { SimFormat.dateTime($0) } ?? "—", Color.primary))
        case .changePct:
            let thresholdValue = p.changeThreshold
            let descText: String
            if let value = thresholdValue {
                descText = (value > 0 ? "涨幅 ≥ " : "跌幅 ≥ ") + pctAbsText(value)
            } else {
                descText = "—"
            }
            items.append(("触发幅度", descText, Color.primary))
        case .maCross:
            items.append(("均线周期", "MA\(p.maPeriod ?? 20)", Color.primary))
            items.append(("穿越方向", (p.maAbove ?? true) ? "上穿" : "下破", Color.primary))
        case .grid:
            items.append(("基准价", priceText(p.gridBase), Color.primary))
            items.append(("价格区间", rangeText(p.gridLower, p.gridUpper), Color.primary))
            items.append(("网格间距", pctText(p.gridStepPct), Color.primary))
            items.append(("每格数量", sharesText(p.gridQtyPerLevel), Color.primary))
            items.append(("倍数委托", multText(p.gridMultiplier), Color.primary))
        case .batch:
            items.append(("总数量", sharesText(p.batchTotalQty), Color.primary))
            items.append(("分批笔数", p.batchCount.map { "\($0) 笔" } ?? "—", Color.primary))
            items.append(("首批价格", priceText(p.batchFirstPrice), Color.primary))
            items.append(("每批价差", pctText(p.batchStepPct), Color.primary))
        }
        return items
    }

    private func directiveItems(_ o: SimCondOrder) -> [(String, String, Color)] {
        var items: [(String, String, Color)] = [
            ("委托方向", o.directive.direction.title,
             o.directive.direction.isBuy ? Color(.systemRed) : Color(.systemGreen)),
            ("报价方式", o.directive.priceType.title, Color.primary)
        ]
        if o.kind == .grid {
            items.append(("每格数量", sharesText(o.params.gridQtyPerLevel), Color.primary))
            items.append(("倍数", multText(o.params.gridMultiplier), Color.primary))
        } else {
            if o.directive.priceType == .limit {
                items.append(("触发价偏移", offsetText(o.directive), Color(.secondaryLabel)))
            }
            items.append(("数量", sharesText(o.directive.qty), Color.primary))
        }
        return items
    }

    private func validityItems(_ o: SimCondOrder) -> [(String, String, Color)] {
        [
            ("有效期", SimCondRule.validitySummary(o), Color.primary),
            ("触发次数", "\(o.triggeredCount)", Color.primary),
            ("创建时间", SimFormat.dateTime(o.createdAt), Color(.secondaryLabel))
        ]
    }

    // MARK: - 通用行 / 卡片

    @ViewBuilder
    private func rows(_ items: [(String, String, Color)]) -> some View {
        ForEach(items.indices, id: \.self) { index in
            infoRow(items[index].0, items[index].1,
                    showsDivider: index < items.count - 1,
                    color: items[index].2)
        }
    }

    private func infoRow(_ label: String, _ value: String,
                         showsDivider: Bool = true, color: Color = Color.primary) -> some View {
        TradeLineRow(label: label, labelWidth: 84, height: 46, showsDivider: showsDivider) {
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(color)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionCard<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(.secondaryLabel))
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 进度

    private func progressDone(_ o: SimCondOrder) -> Int {
        switch o.kind {
        case .grid:  return o.runtime.gridLevel ?? 0
        case .batch: return o.runtime.batchDone
        default:     return 0
        }
    }

    private func progressTotal(_ o: SimCondOrder) -> Int {
        switch o.kind {
        case .grid:  return SimCondRule.gridLevelCount(order: o)
        case .batch: return o.params.batchCount ?? 0
        default:     return 0
        }
    }

    // MARK: - 文案辅助

    private func priceText(_ value: Double?) -> String {
        value.map { SimFormat.price($0) } ?? "—"
    }

    private func sharesText(_ value: Int?) -> String {
        value.map { SimFormat.shares($0) } ?? "—"
    }

    private func pctText(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) + "%" } ?? "—"
    }

    private func pctAbsText(_ value: Double) -> String {
        String(format: "%.1f", abs(value)) + "%"
    }

    private func multText(_ value: Double?) -> String {
        String(format: "%g", value ?? 1) + "×"
    }

    private func rangeText(_ lowerBound: Double?, _ upperBound: Double?) -> String {
        guard let low = lowerBound, let high = upperBound else { return "—" }
        return "\(SimFormat.price(low)) ~ \(SimFormat.price(high))"
    }

    private func offsetText(_ directive: SimCondDirective) -> String {
        if directive.offsetTicks == 0 { return "触发价" }
        let sign = directive.offsetTicks > 0 ? "+" : "-"
        return "触发价 \(sign)\(abs(directive.offsetTicks)) 档"
    }
}