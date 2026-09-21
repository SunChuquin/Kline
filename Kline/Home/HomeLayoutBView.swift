//
//  HomeLayoutBView.swift
//  Kline
//
//  首页 B 档布局（宫格快捷入口，默认档）：
//  标题栏 + 只读搜索条 + 「快捷入口」分组标题 + 自适应列数的入口宫格。
//  入口文案 / 图标 / 语义色全部来自共享骨架 HomePageKit（HomeEntryKind + HomeEntryTile），
//  本档只做组合、列数自适应与入口动作映射，不复制任何入口实现。
//

import SwiftUI

struct HomeLayoutBView: View {
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

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderBar(onProfile: onProfile)
            Divider()

            // 只读搜索条：点击进入搜索模式（与搜索态的搜索框同款外观）
            HomeSearchBar(onTap: onSearch)

            // 「快捷入口」分组标题
            HStack {
                Text("快捷入口")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // 宫格：列数按可用宽度自适应（≥960 四列 / ≥640 三列 / 否则两列）
            GeometryReader { geo in
                ScrollView {
                    LazyVGrid(columns: Self.gridColumns(for: geo.size.width), spacing: 12) {
                        ForEach(HomeEntryKind.allCases) { kind in
                            HomeEntryTile(kind: kind, action: { perform(kind) })
                        }
                    }
                    .padding(16)
                }
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

    /// 列数按可用宽度自适应（口径与行情页 C 档一致）
    private static func gridColumns(for width: CGFloat) -> [GridItem] {
        let count: Int
        if width >= 960 {
            count = 4
        } else if width >= 640 {
            count = 3
        } else {
            count = 2
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }
}

#Preview {
    HomeLayoutBView(onSelectTab: { _ in }, onSearch: {}, onProfile: {}, onFormula: {})
}