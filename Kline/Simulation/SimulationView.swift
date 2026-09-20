//
//  SimulationView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/20 改为按布局偏好分发（A / B / C），A 为账户侧栏 + 工作区。
//

import SwiftUI

struct SimulationView: View {
    @ObservedObject private var layoutStore = TradingLayoutStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // 顶部菜单栏
            HStack {
                Spacer()
                // 当前布局指示（同时是既有 UITest 的锚点，标识不可改）
                Text("模拟页 · 方案 \(layoutStore.simulationLayout.shortTitle)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.tertiaryLabel))
                    .accessibilityIdentifier("simulation.subtitle")
            }
            .background(Color(.systemBackground))
            .frame(height: 56)
            .padding(.top, -5)
            .padding(.trailing, 16)

            // 分隔线
            Divider()

            // 主内容区域：按布局偏好分发（B / C 于阶段二替换为真实实现）
            Group {
                switch layoutStore.simulationLayout {
                case .a:
                    SimulationLayoutAView()
                case .b:
                    SimulationLayoutPlaceholderView(styleTitle: SimulationLayoutStyle.b.title)
                case .c:
                    SimulationLayoutPlaceholderView(styleTitle: SimulationLayoutStyle.c.title)
                }
            }
            .frame(maxHeight: .infinity)
        }
        // 内容延伸到物理屏幕底边 + 背景铺满（避免底部露出下层导航栏）
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear { SimStore.shared.prepareQuotes() }
    }
}

/// 方案 B/C 占位（阶段二替换为真实实现）
struct SimulationLayoutPlaceholderView: View {
    let styleTitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 30))
                .foregroundColor(Color(.tertiaryLabel))
            Text(styleTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.primary)
            Text("该布局将在下一阶段实现")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    SimulationView()
}
