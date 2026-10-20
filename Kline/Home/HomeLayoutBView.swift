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
    let onOpenAlertRecords: () -> Void
    let onOpenLayoutEditor: () -> Void
    let onOpenLANSync: () -> Void
    let onOpenPythonLab: () -> Void
    let onProfile: () -> Void

    /// 统一紧凑判定（竖屏垂直堆栈规则 2026-10-20）：宿主注入的实测可用宽 < 600 →
    /// 「我的自选 + 模拟账户」垂直堆叠各占全宽；否则并排原样。
    @CompactWidthValue private var isCompactWidth

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

                    // 我的自选 + 模拟账户：宽屏各占一半宽并排（顶部对齐）；
                    // 竖屏垂直堆叠各占全宽——容器统一走 AdaptiveStack，与
                    // 配置驱动路径 / 模拟页共用同一套紧凑判定
                    AdaptiveStack(hAlignment: .top, hSpacing: 12, vSpacing: 12) {
                        HomeSectionCard(title: "我的自选", compact: isCompactWidth) {
                            HomeFavoritesBlock(rows: model.favoriteRows, compact: isCompactWidth,
                                               showsSparkline: !isCompactWidth,
                                               onOpen: openDetail, onEmptyTap: { onSelectTab(1) })
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        HomeSectionCard(title: "模拟账户", compact: isCompactWidth) {
                            HomeSimSummaryBlock(model: model, compact: isCompactWidth,
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
        case .alertRecords: onOpenAlertRecords()
        case .training: TrainingSetupRouter.shared.isPresented = true
        case .layoutEditor: onOpenLayoutEditor()
        case .lanSync: onOpenLANSync()
        case .pythonLab: onOpenPythonLab()
        }
    }

    /// 打开 K 线详情（与行情 / 自选页同机制，带上当前列表作为副图切换上下文）
    private func openDetail(_ meta: MetaItem, in context: [MetaItem]) {
        DetailRouter.shared.open(meta, in: context)
    }
}

#Preview {
    HomeLayoutBView(model: HomePageModel(), onSelectTab: { _ in }, onSearch: {},
                    onOpenFormula: { _ in }, onOpenCondOrder: {},
                    onOpenAlertRecords: {}, onOpenLayoutEditor: {},
                    onOpenLANSync: {}, onOpenPythonLab: {}, onProfile: {})
}