//
//  HomeLayoutDView.swift
//  Kline
//
//  首页 D 档布局（卡片工作台）：
//  标题栏 + 顶部大卡（搜索标的）+ 2×2 中卡（自选 / 行情 / 模拟交易 / 公式管理）+ 底部整行小卡（个人中心）。
//  卡片全部是共享骨架 HomePageKit 的 HomeEntryCard（只参数化高度与排版），
//  入口文案 / 图标 / 语义色来自 HomeEntryKind，本档只做组合与入口动作映射。
//

import SwiftUI

struct HomeLayoutDView: View {
    let onSelectTab: (Int) -> Void
    let onSearch: () -> Void
    let onProfile: () -> Void
    let onFormula: () -> Void

    init(onSelectTab: @escaping (Int) -> Void,
         onSearch: @escaping () -> Void,
         onProfile: @escaping () -> Void,
         onFormula: @escaping () -> Void) {
        self.onSelectTab = onSelectTab
        self.onSearch = onSearch
        self.onProfile = onProfile
        self.onFormula = onFormula
    }

    /// 2×2 中卡列定义（两列等宽，间距 12）
    private static let cardColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    /// 中卡顺序：自选 / 行情 / 模拟交易 / 公式管理
    private static let middleKinds: [HomeEntryKind] = [.favorites, .market, .simulation, .formula]

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderBar(onProfile: onProfile)
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // 顶部大卡：搜索标的（一行说明）
                    HomeEntryCard(kind: .search, height: 76, big: true, action: onSearch)

                    // 2×2 中卡
                    LazyVGrid(columns: Self.cardColumns, spacing: 12) {
                        ForEach(Self.middleKinds, id: \.rawValue) { kind in
                            HomeEntryCard(kind: kind, height: 104, action: { perform(kind) })
                        }
                    }

                    // 底部整行小卡：个人中心
                    HomeEntryCard(kind: .profile, height: 64, showsChevron: true, action: onProfile)
                }
                .padding(16)
            }
        }
    }

    // MARK: - 入口动作映射（三档一致：搜索进搜索模式；自选 / 行情 / 模拟切底部 Tab；公式 / 个人中心各自入口）

    private func perform(_ kind: HomeEntryKind) {
        switch kind {
        case .search: onSearch()
        case .favorites: onSelectTab(1)
        case .market: onSelectTab(2)
        case .simulation: onSelectTab(3)
        case .formula: onFormula()
        case .profile: onProfile()
        }
    }
}

#Preview {
    HomeLayoutDView(onSelectTab: { _ in }, onSearch: {}, onProfile: {}, onFormula: {})
}