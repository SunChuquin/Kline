//
//  HomeLayoutBView.swift
//  Kline
//
//  首页 B 档布局（默认档，卡片网格）：横滑快捷入口行 + 内容区卡片网格。
//  - 大盘概览卡（非紧凑）
//  - 我的自选 + 模拟账户：各占一半宽、顶部对齐（带迷你走势）
//  - 涨幅榜通栏卡（列表行）
//  共享骨架：标题栏 HomeHeaderBar + 横滑入口行 HomeQuickEntryRow + 内容块 HomeContentBlocks；
//  数据由 HomePageModel 提供，入口动作由容器注入的闭包承担（本档不持状态、不发命令）。
//

import SwiftUI

struct HomeLayoutBView: View {
    @ObservedObject var model: HomePageModel
    let onSelectTab: (Int) -> Void
    let onSearch: () -> Void
    let onOpenFormula: (FormulaKind) -> Void
    let onOpenCondOrder: () -> Void
    let onProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderBar(onProfile: onProfile)
            Divider()

            // 横滑快捷入口行（6 项 chip 合计约 1100pt，横屏下需左右拖动）
            HomeQuickEntryRow(onTap: perform)

            ScrollView {
                VStack(spacing: 12) {
                    HomeSectionCard(title: "大盘概览") {
                        HomeMarketOverviewStrip(rows: model.indexQuotes, breadth: model.breadth,
                                                compact: false)
                    }

                    // 我的自选 + 模拟账户：各占一半宽、顶部对齐（内容行数不同不强行等高）
                    HStack(alignment: .top, spacing: 12) {
                        HomeSectionCard(title: "我的自选") {
                            HomeFavoritesBlock(rows: model.favoriteRows, compact: false,
                                               showsSparkline: true,
                                               onOpen: openDetail, onEmptyTap: { onSelectTab(1) })
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        HomeSectionCard(title: "模拟账户") {
                            HomeSimSummaryBlock(model: model, compact: false,
                                                onTap: { onSelectTab(3) })
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }

                    HomeSectionCard(title: "涨幅榜") {
                        HomeTopGainersBlock(rows: model.topGainers, style: .list, compact: false,
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
        }
    }

    /// 打开 K 线详情（与行情 / 自选页同机制，带上当前列表作为副图切换上下文）
    private func openDetail(_ meta: MetaItem, in context: [MetaItem]) {
        DetailRouter.shared.open(meta, in: context)
    }
}

#Preview {
    HomeLayoutBView(model: HomePageModel(), onSelectTab: { _ in }, onSearch: {},
                    onOpenFormula: { _ in }, onOpenCondOrder: {}, onProfile: {})
}