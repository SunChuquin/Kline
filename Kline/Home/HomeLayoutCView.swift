//
//  HomeLayoutCView.swift
//  Kline
//
//  首页 C 档布局（分区列表入口）：
//  标题栏 + 三组分区卡片（行情 / 研究 / 账户），组内是共享的入口行 HomeEntryRow。
//  入口文案 / 图标 / 语义色全部来自共享骨架 HomePageKit（HomeEntryKind + HomeEntryRow），
//  本档只做分组定义与入口动作映射，不复制任何入口实现。
//

import SwiftUI

// MARK: - 分组定义（固定顺序：行情 / 研究 / 账户）

/// 首页入口分组：组名 + 组内入口（顺序即渲染顺序）
private struct HomeEntryGroup: Identifiable {
    let title: String
    let kinds: [HomeEntryKind]

    var id: String { title }
}

struct HomeLayoutCView: View {
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

    /// 三组固定顺序（与 Figma 原型一致）
    private static let groups: [HomeEntryGroup] = [
        HomeEntryGroup(title: "行情", kinds: [.market, .favorites]),
        HomeEntryGroup(title: "研究", kinds: [.search, .formula]),
        HomeEntryGroup(title: "账户", kinds: [.simulation, .profile])
    ]

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderBar(onProfile: onProfile)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Self.groups) { group in
                        groupCard(group)
                    }
                }
                // 末组下方留白（首组上方与组间 14 由每组自身的 .padding(.top, 14) 提供）
                .padding(.bottom, 14)
            }
        }
    }

    /// 单个分区卡片：组标题 + 组内入口行（行间细分隔线，缩进 56 避开图标方块）
    private func groupCard(_ group: HomeEntryGroup) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(group.title)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ForEach(Array(group.kinds.enumerated()), id: \.offset) { index, kind in
                if index > 0 {
                    Divider().padding(.leading, 56)
                }
                HomeEntryRow(kind: kind, action: { perform(kind) })
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 14)
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
    HomeLayoutCView(onSelectTab: { _ in }, onSearch: {}, onProfile: {}, onFormula: {})
}