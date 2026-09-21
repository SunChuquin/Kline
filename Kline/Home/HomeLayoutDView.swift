//
//  HomeLayoutDView.swift
//  Kline
//
//  首页 D 档布局（工作台混排）：横滑快捷入口行 + 内容区混排。
//  - 大盘概览条（非紧凑，作大卡）
//  - 模拟账户 + 我的自选（均紧凑；自选只取前 3 条、无走势图），各占一半宽、顶部对齐
//  - 涨幅榜卡（横滑 chips）
//  共享骨架：标题栏 HomeHeaderBar + 横滑入口行 HomeQuickEntryRow + 内容块 HomeContentBlocks；
//  数据由 HomePageModel 提供，入口动作由容器注入的闭包承担（本档不持状态、不发命令）。
//

import SwiftUI

struct HomeLayoutDView: View {
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
                    // 大盘概览条：非紧凑，作「大卡」
                    HomeSectionCard(title: "大盘概览") {
                        HomeMarketOverviewStrip(rows: model.indexQuotes, breadth: model.breadth,
                                                compact: false)
                    }

                    // 模拟账户 + 我的自选（前 3 条）：各占一半宽、顶部对齐
                    HStack(alignment: .top, spacing: 12) {
                        HomeSectionCard(title: "模拟账户", compact: true) {
                            HomeSimSummaryBlock(model: model, compact: true,
                                                onTap: { onSelectTab(3) })
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        HomeSectionCard(title: "我的自选", compact: true) {
                            HomeFavoritesBlock(rows: Array(model.favoriteRows.prefix(3)),
                                               compact: true, showsSparkline: false,
                                               onOpen: openDetail, onEmptyTap: { onSelectTab(1) })
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }

                    // 涨幅榜：横滑 chips
                    HomeSectionCard(title: "涨幅榜") {
                        HomeTopGainersBlock(rows: model.topGainers, style: .chips, compact: false,
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
    HomeLayoutDView(model: HomePageModel(), onSelectTab: { _ in }, onSearch: {},
                    onOpenFormula: { _ in }, onOpenCondOrder: {}, onProfile: {})
}