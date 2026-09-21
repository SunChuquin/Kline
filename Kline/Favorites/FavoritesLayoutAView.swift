//
//  FavoritesLayoutAView.swift
//  Kline
//
//  自选页 A 档布局（经典表格式）：现有实现的等价搬运。
//  由共享骨架组合而成：工具条 + 分组 Tab 条 + 分隔线 + 表格主体。
//  呈现、间距、颜色、命中区、无障碍标识与改造前完全一致（A 档行为零变化）。
//

import SwiftUI

struct FavoritesLayoutAView: View {
    @ObservedObject var model: FavoritesPageModel

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具 + 分组 Tab
            FavoritesToolbar(model: model)
            FavoritesGroupTabs(model: model)
            Divider()

            // 加载态 / 空态 / (吸顶表头 + 列表) 的切换由共享表格主体负责
            FavoritesTableBody(model: model)
        }
    }
}

#Preview {
    FavoritesLayoutAView(model: FavoritesPageModel())
}
