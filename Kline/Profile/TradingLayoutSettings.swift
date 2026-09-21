//
//  TradingLayoutSettings.swift
//  Kline
//
//  个人中心的布局偏好设置：快捷面板布局（QuickPanelLayoutStyle）、
//  模拟页布局（SimulationLayoutStyle）、自选页布局（FavoritesLayoutStyle）、
//  行情页布局（MarketLayoutStyle）四行设置共用的下拉触发按钮
//  （LayoutDropdownButton）与泛型选择浮层面板（LayoutOptionsPanel）。
//  样式逐项对齐 KlineTheme.swift 的
//  KlineThemeDropdownButton / KlineThemeOptionsPanel，只换文案与数据源。
//

import SwiftUI
import Combine

// MARK: - 下拉触发按钮（对齐 KlineThemeDropdownButton 的字号/高度/配色）

/// 布局下拉触发按钮（对齐 KlineThemeDropdownButton 的字号/高度/配色）
struct LayoutDropdownButton: View {
    /// 显示当前方案短名，如 "A"
    let title: String
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundColor(.blue)
        }
        .buttonStyle(.plain)
        .frame(height: 28)
    }
}

// MARK: - 选择浮层面板（泛型，四行布局共用）

/// 布局选择浮层面板（容器层居中显示，样式对齐 KlineThemeOptionsPanel）
struct LayoutOptionsPanel<Style: CaseIterable & Hashable & Identifiable>: View
where Style.AllCases == [Style] {
    let options: [Style]
    @Binding var selection: Style
    let titleFor: (Style) -> String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { item in
                        let on = selection == item
                        Button {
                            // 立即生效，不关闭面板
                            selection = item
                        } label: {
                            HStack {
                                Text(titleFor(item))
                                    .foregroundColor(.primary)
                                Spacer()
                                if on {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)

            Button {
                withAnimation(.easeOut(duration: 0.15)) { onClose() }
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 210)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

// MARK: - 个人中心的四行布局设置

/// 「快捷面板布局」设置行
struct QuickPanelLayoutSettingRow: View {
    @ObservedObject private var store = TradingLayoutStore.shared
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("快捷面板布局")
                .font(.system(size: 16))
            Spacer(minLength: 12)
            LayoutDropdownButton(title: store.panelLayout.shortTitle, isOpen: $isOpen)
        }
        .frame(minHeight: 36)
    }
}

/// 「模拟页布局」设置行
struct SimulationLayoutSettingRow: View {
    @ObservedObject private var store = TradingLayoutStore.shared
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("模拟页布局")
                .font(.system(size: 16))
            Spacer(minLength: 12)
            LayoutDropdownButton(title: store.simulationLayout.shortTitle, isOpen: $isOpen)
        }
        .frame(minHeight: 36)
    }
}

/// 「自选页布局」设置行
struct FavoritesLayoutSettingRow: View {
    @ObservedObject private var store = PageLayoutStore.shared
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("自选页布局")
                .font(.system(size: 16))
            Spacer(minLength: 12)
            LayoutDropdownButton(title: store.favoritesLayout.shortTitle, isOpen: $isOpen)
        }
        .frame(minHeight: 36)
    }
}

/// 「行情页布局」设置行
struct MarketLayoutSettingRow: View {
    @ObservedObject private var store = PageLayoutStore.shared
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("行情页布局")
                .font(.system(size: 16))
            Spacer(minLength: 12)
            LayoutDropdownButton(title: store.marketLayout.shortTitle, isOpen: $isOpen)
        }
        .frame(minHeight: 36)
    }
}
