//
//  HomeLayoutCView.swift
//  Kline
//
//  首页 C 档布局（分区列表 / 紧凑通栏）：横滑快捷入口行 + 四块通栏内容卡。
//  顺序：大盘概览 → 我的自选 → 模拟账户 → 涨幅榜（列表行）；全部紧凑（行高 40、无走势图）。
//  共享骨架：标题栏 HomeHeaderBar + 横滑入口行 HomeQuickEntryRow + 内容块 HomeContentBlocks；
//  数据由 HomePageModel 提供，入口动作由容器注入的闭包承担（本档不持状态、不发命令）。
//

import SwiftUI

struct HomeLayoutCView: View {
    @ObservedObject var model: HomePageModel
    let onSelectTab: (Int) -> Void
    let onSearch: () -> Void
    let onOpenFormula: (FormulaKind) -> Void
    let onOpenCondOrder: () -> Void
    let onOpenAlertRecords: () -> Void
    let onOpenLayoutEditor: () -> Void
    let onProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderBar(onProfile: onProfile)
            Divider()

            // 横滑快捷入口行（6 项 chip 合计约 1100pt，横屏下需左右拖动）
            HomeQuickEntryRow(onTap: perform)

            ScrollView {
                VStack(spacing: 12) {
                    HomeSectionCard(title: "大盘概览", compact: true) {
                        HomeMarketOverviewStrip(rows: model.indexQuotes, breadth: model.breadth,
                                                compact: true)
                    }

                    HomeSectionCard(title: "我的自选", compact: true) {
                        HomeFavoritesBlock(rows: model.favoriteRows, compact: true,
                                           showsSparkline: false,
                                           onOpen: openDetail, onEmptyTap: { onSelectTab(1) })
                    }

                    HomeSectionCard(title: "模拟账户", compact: true) {
                        HomeSimSummaryBlock(model: model, compact: true, onTap: { onSelectTab(3) })
                    }

                    HomeSectionCard(title: "涨幅榜", compact: true) {
                        HomeTopGainersBlock(rows: model.topGainers, style: .list, compact: true,
                                            isReady: model.isMarketReady, onOpen: openDetail)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - 入口动作映射（三档一致）

    /// 搜索进搜索模式；三个公式入口按分段打开公式管理中心；条件单 / 个人中心各自入口
    private func perform(_ kind: HomeEntryKind) {
        switch kind {
        case .search: onSearch()
        case .tech, .picker, .strategy:
            if let fk = kind.formulaKind { onOpenFormula(fk) }
        case .condOrder: onOpenCondOrder()
        case .profile: onProfile()
        case .alertRecords: onOpenAlertRecords()
        case .layoutEditor: onOpenLayoutEditor()
        }
    }

    /// 打开 K 线详情（与行情 / 自选页同机制，带上当前列表作为副图切换上下文）
    private func openDetail(_ meta: MetaItem, in context: [MetaItem]) {
        DetailRouter.shared.open(meta, in: context)
    }
}

#Preview {
    HomeLayoutCView(model: HomePageModel(), onSelectTab: { _ in }, onSearch: {},
                    onOpenFormula: { _ in }, onOpenCondOrder: {},
                    onOpenAlertRecords: {}, onOpenLayoutEditor: {}, onProfile: {})
}