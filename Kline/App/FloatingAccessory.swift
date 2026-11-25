//
//  FloatingAccessory.swift
//  Kline
//
//  快捷交易面板（FloatingAccessoryPanel）：由 K 线详情页工具栏「快捷交易」入口打开，
//  样式与内容沿用原悬浮按钮承载的底部面板（A / B / C 三套布局 + 训练态面板）。
//  原小悬浮按钮已移除；大悬浮按钮（FloatingAccessoryWheel）与共用几何见
//  FloatingAccessoryWheel.swift / FloatingAccessoryShared.swift。
//

import SwiftUI
import Combine

// MARK: - 底部面板

/// 悬浮按钮点开的底部面板：样式对齐「指标选择面板」——35% 黑色遮罩（点击关闭）、
/// 贴底面板（只圆顶部两角，底边直达物理屏幕底边）、头部标题 + 关闭按钮。
/// 内容区按 TradingLayoutStore.shared.panelLayout 分发：A 上下文自适应交易卡
/// （QuickPanelLayouts.swift）、B 分页式面板 / C 闪电下单条（QuickPanelLayoutsBC.swift）。
struct FloatingAccessoryPanel: View {
    let onClose: () -> Void

    /// 布局偏好：面板打开期间在个人中心切换方案时实时换布局与高度
    @ObservedObject private var layoutStore = TradingLayoutStore.shared
    /// 训练态：面板整体切到训练下单面板，标题与内容随之变化
    @ObservedObject private var training = TrainingSessionController.shared

    /// 面板高度占屏幕高度比例（按方案不同：A 0.67 / B 0.60 / C 0.35）
    private var heightFraction: CGFloat {
        // 训练态：内容固定为「训练信息 + 持仓 + 条件单入口 + 紧凑票面 + 成交记录」，
        // 与模拟交易三套布局无关，统一给足高度，避免票面/成交记录被裁
        if training.isActive { return 0.8 }
        switch layoutStore.panelLayout {
        case .a: return 0.67
        case .b: return 0.60
        case .c: return 0.35
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                VStack(spacing: 0) {
                    // 头部：标题 + 关闭（字号/间距对齐 sheetHeader）
                    HStack {
                        Text(training.isActive ? "训练下单" : "快捷面板")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Button("关闭") { close() }
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.accent)
                            .accessibilityIdentifier("accessory.close")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider()
                    // 内容区：内容高度可能超过面板高度，统一包一层纵向滚动
                    ScrollView(.vertical, showsIndicators: false) {
                        panelContent
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .frame(width: geo.size.width, height: min(geo.size.height * heightFraction, 660))
                .background(AppColors.cardBackground)
                // 只圆顶部两角：底边贴紧物理屏幕底边后，底部若保留圆角，两角会露出深色遮罩
                .clipShape(TopRoundedCornerRect(radius: 16))
                // ⚠️ 固定高度面板直接加 .ignoresSafeArea 无效：容器内默认居中放置，
                // 面板只下移半个 inset、底部仍留灰缝（露出遮罩）。必须用贪婪 frame(alignment:.bottom)
                // 把面板钉在容器底边（与 bottomSheet 同一处理）
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 按布局偏好分发面板内容；训练态下整块走训练面板（不渲染 A/B/C，避免误触模拟账户）
    @ViewBuilder
    private var panelContent: some View {
        if training.isActive {
            QuickTrainingPanelView(onClose: onClose)
        } else {
            switch layoutStore.panelLayout {
            case .a:
                QuickPanelAView(onClose: onClose)
            case .b:
                QuickPanelBView(onClose: onClose)
            case .c:
                QuickPanelCView(onClose: onClose)
            }
        }
    }

    /// 关闭统一走淡出动画（遮罩点击与「关闭」按钮一致）
    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { onClose() }
    }
}

// MARK: - 训练下单面板

/// 训练态下的快捷面板内容：训练信息行 + 训练持仓行 + 复用下单票面。
/// 成交只经 TrainingSessionController.placeTrade 落训练 sqlite，全程不触碰模拟账户。
private struct QuickTrainingPanelView: View {
    let onClose: () -> Void

    @ObservedObject private var training = TrainingSessionController.shared

    var body: some View {
        VStack(spacing: 0) {
            if let meta = training.meta {
                infoRow(meta: meta)
                positionRow
                conditionEntryRow
                pendingSection
                TradeTicketView(style: .panel,
                                // 训练无模拟账户：用「全部账户汇总」占位 id（store.account 取不到真实账户）
                                accountID: SimStore.allAccountID,
                                metaID: meta.id,
                                code: meta.code,
                                name: meta.name,
                                initialDirection: .buy,
                                initialPriceType: .limit,
                                initialQty: 100,
                                onSubmit: { _ in })
                    .id("quickTraining.ticket.\(meta.id)")
                // 成交记录：紧跟票面下方，每笔含方向/价格/数量/已实现盈亏，顶部汇总已实现盈亏
                tradeHistorySection
            } else {
                Text("暂无进行中的训练")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 训练信息行：标的名 + 代码、训练日、已交易笔数，结束态追加「训练已完成」
    private func infoRow(meta: MetaItem) -> some View {
        HStack(spacing: 8) {
            Text(meta.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
            Text(meta.code)
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(1)
            Text(training.settlementRule.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(AppColors.cardHoverBackground))
            Text("训练日 \(TrainSessionRecord.dateText(training.trainingDate))")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(1)
            Text("已交易 \(training.trades.count) 笔")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(1)
            if training.isFinished {
                Text("训练已完成")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppColors.marketDown)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    /// 训练持仓行：持仓 / 均价 / 浮盈浮亏（金额 + 相对持仓均价的百分比）+ 可卖数量；无持仓显示「空仓」
    private var positionRow: some View {
        HStack(spacing: 8) {
            if training.positionQty > 0 {
                let floating = training.floatingPnl ?? 0
                let avg = training.avgCost
                let rate = avg > 0 ? ((training.currentClose ?? avg) / avg * 100 - 100) : 0
                Text("持仓 \(SimFormat.shares(training.positionQty)) 股 · 均价 \(SimFormat.price(avg))")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(1)
                Text("浮盈 \(SimFormat.signed(floating))（\(String(format: "%+.2f%%", rate))）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(floating >= 0 ? AppColors.marketUp : AppColors.marketDown)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(training.lockedQty > 0
                     ? "可卖 \(SimFormat.shares(training.sellableQty))（锁定 \(SimFormat.shares(training.lockedQty))）"
                     : "可卖 \(SimFormat.shares(training.sellableQty))")
                    .font(.system(size: 11))
                    .foregroundColor(training.lockedQty > 0 ? Color(.systemOrange) : AppColors.textSecondary)
                    .lineLimit(1)
                if training.accountType == .fixedAmount {
                    Text("可用 \(SimFormat.amount(training.cash))")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(1)
                }
            } else {
                Text("空仓")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(training.accountType == .percent
                     ? "百分比账户 · 按仓位比例"
                     : "金额账户 · 可用 \(SimFormat.amount(training.cash))")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(AppColors.cardBackground)
    }

    /// 成交记录：本标的本次训练的逐笔成交（新 → 旧），卖出笔显示已实现盈亏并着色；
    /// 顶部一行汇总「已实现盈亏」，与持仓行的「浮盈浮亏」配合即可看到账户盈亏全貌
    private var tradeHistorySection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("成交记录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Text("\(training.trades.count) 笔")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
                Spacer(minLength: 8)
                // 已实现盈亏 = 卖出笔盈亏之和 − 买入笔费用之和（与顶栏「盈」的分子同源）
                let realized = training.trades.reduce(0.0) { $0 + ($1.pnl ?? -$1.fee) }
                Text("已实现 \(SimFormat.signed(realized))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(realized >= 0 ? AppColors.marketUp : AppColors.marketDown)
            }
            .padding(.horizontal, 16)
            .frame(height: 26)
            .background(AppColors.cardBackground)

            if training.trades.isEmpty {
                Text("本次训练暂无成交")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                // 单次训练成交量为几十笔量级，直接铺开，由外层面板 ScrollView 统一滚动（避免嵌套滚动冲突）
                LazyVStack(spacing: 0) {
                    ForEach(training.trades.reversed()) { t in
                        tradeRow(t)
                    }
                }
            }
        }
    }

    /// 隔日委托队列：展示「已挂单、待下一训练日收盘价成交」的手动委托（当日成交模式恒为空，不渲染）
    @ViewBuilder
    private var pendingSection: some View {
        if !training.pendingOrders.isEmpty || training.pendingRejectText != nil {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("隔日委托")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                    Text("\(training.pendingOrders.count) 笔待成交")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                    Spacer(minLength: 8)
                    Text("下一训练日判定 · 触及委托价成交")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 26)
                .background(AppColors.cardBackground)

                ForEach(training.pendingOrders) { o in
                    HStack(spacing: 8) {
                        Text(TrainSessionRecord.dateText(o.placedDate))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppColors.textSecondary)
                        Text(o.direction == .buy ? "买" : "卖")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color.white)
                            .frame(width: 16, height: 14)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(o.direction == .buy ? AppColors.marketUp : AppColors.marketDown))
                        Text(SimFormat.price(o.price))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppColors.textSecondary)
                        Text("×\(SimFormat.shares(o.qty))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppColors.textSecondary)
                        Spacer(minLength: 8)
                        Text("待成交")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(.systemOrange))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 22)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(AppColors.separator)
                            .frame(height: 0.5)
                            .padding(.leading, 16)
                    }
                }

                if let reject = training.pendingRejectText {
                    Text(reject)
                        .font(.system(size: 11))
                        .foregroundColor(Color(.systemOrange))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    /// 单笔成交行：日期 · 买卖标记 · 成交价 × 数量 · 触发来源（条件单）· 已实现盈亏（买入为「—」）
    private func tradeRow(_ t: TrainTradeRecord) -> some View {
        HStack(spacing: 8) {
            Text(t.tradeDateText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColors.textSecondary)
            Text(t.direction == .buy ? "买" : "卖")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color.white)
                .frame(width: 16, height: 14)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(t.direction == .buy ? AppColors.marketUp : AppColors.marketDown))
            Text(SimFormat.price(t.price))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(AppColors.textPrimary)
            Text("×\(SimFormat.shares(t.qty))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColors.textSecondary)
            if t.trigger == .cond {
                Text(t.condKind ?? "条件单")
                    .font(.system(size: 9))
                    .foregroundColor(Color(.systemOrange))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let pnl = t.pnl {
                Text(SimFormat.signed(pnl))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(pnl >= 0 ? AppColors.marketUp : AppColors.marketDown)
            } else {
                Text("—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 24)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColors.separator)
                .frame(height: 0.5)
                .padding(.leading, 16)
        }
    }

    /// 条件单 / 预警入口：关面板后打开训练条件单管理页（浮层由 ContentView 根层承载）
    private var conditionEntryRow: some View {
        HStack(spacing: 10) {
            Button {
                onClose()
                TrainingCondRouter.shared.isPresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 12))
                    Text("条件单 / 预警")
                        .font(.system(size: 12.5, weight: .semibold))
                    if !training.monitoringConditions.isEmpty {
                        Text("\(training.monitoringConditions.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(AppColors.accent))
                    }
                }
                .foregroundColor(AppColors.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.accent.opacity(0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("quickTraining.conds")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}